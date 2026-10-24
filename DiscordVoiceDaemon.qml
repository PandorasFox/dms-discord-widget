import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// Daemon surface: instantiated exactly once by DMSShell, independent of
// bar windows. Owns the bridge process, token persistence, and the IPC
// handler so `dms ipc call discord ...` keeps working across monitor
// sleep/wake and bar reloads (a per-widget IpcHandler dies with its bar
// window, leaving a stale registration behind).
Item {
    id: root

    // --- Voice state (tracked for the IPC handler) ---
    property bool authenticated: false
    property var currentChannel: null
    property var voiceUsers: []
    property var voiceSettings: ({mute: false, deaf: false})

    readonly property bool inVoice: currentChannel !== null && currentChannel !== undefined
    readonly property bool isMuted: voiceSettings.mute || false
    readonly property bool isDeafened: voiceSettings.deaf || false

    readonly property string clientId: "207646673902501888"

    readonly property string bridgeSocketPath: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
        return runtime + "/dms-discord-voice.sock"
    }

    function sendBridgeCommand(cmd) {
        bridgeSocket.send(cmd)
    }

    // =====================================================================
    // Bridge process (single owner; extra spawns exit if socket is live)
    // =====================================================================

    Process {
        id: bridgeProcess
        command: ["python3", Qt.resolvedUrl("discord_bridge.py").toString().replace("file://", ""), root.bridgeSocketPath, root.clientId]
        running: false

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("DiscordVoice bridge:", text.trim())
                }
            }
        }

        onExited: (exitCode) => {
            if (exitCode !== 0) {
                console.warn("DiscordVoice bridge exited:", exitCode)
                bridgeRestartTimer.start()
            }
        }
    }

    Timer {
        id: bridgeStartTimer
        interval: 100
        running: true
        onTriggered: bridgeProcess.running = true
    }

    Timer {
        id: bridgeRestartTimer
        interval: 3000
        onTriggered: bridgeProcess.running = true
    }

    // Watchdog: if the socket stays down and no bridge is running, start one.
    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: {
            if (!bridgeSocket.linkUp && !bridgeProcess.running) {
                bridgeProcess.running = true
            }
        }
    }

    // The bridge is a plain relay: it doesn't retry on its own. DMS commonly
    // starts before Discord is running, so while unauthenticated we keep
    // asking it to try. `quiet` stops the bridge broadcasting an error per
    // failed attempt; `connect` is idempotent in the bridge.
    Timer {
        interval: 5000
        repeat: true
        running: bridgeSocket.linkUp && !root.authenticated
        onTriggered: root.sendBridgeCommand({cmd: "connect", quiet: true})
    }

    // =====================================================================
    // Socket client (DankSocket reconnects with backoff on its own)
    // =====================================================================

    DankSocket {
        id: bridgeSocket
        path: root.bridgeSocketPath
        connected: false

        parser: SplitParser {
            onRead: message => {
                if (!message || message.length === 0) return
                try {
                    root.handleBridgeMessage(JSON.parse(message))
                } catch (e) {
                    console.warn("DiscordVoice daemon: parse error:", e)
                }
            }
        }
    }

    Timer {
        interval: 800
        running: true
        onTriggered: bridgeSocket.connected = true
    }

    function handleBridgeMessage(msg) {
        switch (msg.type) {
        case "ready": {
            bridgeSocket.send({cmd: "connect"})
            break
        }

        case "auth_complete":
            authenticated = true
            break

        case "auth_error":
            authenticated = false
            break

        case "auth_required":
            authenticated = false
            break

        case "voice_channel":
            currentChannel = msg.channel || null
            if (!msg.channel) {
                voiceUsers = []
            }
            break

        case "voice_state":
            voiceUsers = msg.users || []
            break

        case "voice_settings":
            voiceSettings = {mute: msg.mute || false, deaf: msg.deaf || false}
            break

        case "disconnected":
            authenticated = false
            currentChannel = null
            voiceUsers = []
            voiceSettings = {mute: false, deaf: false}
            break
        }
    }

    // =====================================================================
    // IPC handler (for keybinds: dms ipc call discord ...)
    // =====================================================================

    IpcHandler {
        target: "discord"

        function toggleMute(): string {
            root.sendBridgeCommand({cmd: "set_voice_settings", mute: !root.isMuted})
            return root.isMuted ? "UNMUTED" : "MUTED"
        }

        function toggleDeafen(): string {
            root.sendBridgeCommand({cmd: "set_voice_settings", deaf: !root.isDeafened})
            return root.isDeafened ? "UNDEAFENED" : "DEAFENED"
        }

        function muteOn(): string {
            root.sendBridgeCommand({cmd: "set_voice_settings", mute: true})
            return "MUTE_ON"
        }

        function muteOff(): string {
            root.sendBridgeCommand({cmd: "set_voice_settings", mute: false})
            return "MUTE_OFF"
        }

        function deafenOn(): string {
            root.sendBridgeCommand({cmd: "set_voice_settings", deaf: true})
            return "DEAFEN_ON"
        }

        function deafenOff(): string {
            root.sendBridgeCommand({cmd: "set_voice_settings", deaf: false})
            return "DEAFEN_OFF"
        }

        function status(): string {
            if (!root.authenticated) return "NOT_AUTHENTICATED"
            if (!root.inVoice) return "NOT_IN_VOICE"
            return JSON.stringify({
                channel: root.currentChannel ? root.currentChannel.name : "",
                users: root.voiceUsers.length,
                muted: root.isMuted,
                deafened: root.isDeafened
            })
        }
    }
}
