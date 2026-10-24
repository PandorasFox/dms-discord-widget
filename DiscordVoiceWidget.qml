import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "discord-voice"

    // --- Bridge state ---
    property bool authenticated: false
    property string authError: ""
    property bool discordConnected: false

    // --- Voice state ---
    property var currentChannel: null
    property var voiceUsers: []
    property var voiceSettings: ({mute: false, deaf: false})
    property var speakingUsers: ({})

    // --- Settings ---
    readonly property int maxBarAvatars: parseInt(pluginData.maxBarAvatars) || 5

    // --- Computed ---
    readonly property bool inVoice: currentChannel !== null && currentChannel !== undefined
    readonly property bool isMuted: voiceSettings.mute || false
    readonly property bool isDeafened: voiceSettings.deaf || false

    readonly property int userListMaxHeight: {
        const rowHeight = 44 + Theme.spacingS
        const byRows = 20 * rowHeight
        const screenH = (root.parentScreen ? root.parentScreen.height : Screen.height) || 0
        const byScreen = screenH * 0.5
        return Math.min(byRows, byScreen)
    }

    // --- Socket path ---
    readonly property string bridgeSocketPath: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
        return runtime + "/dms-discord-voice.sock"
    }

    // --- Helpers (accessible from popout via root.xxx) ---
    function avatarUrl(userId, avatarHash) {
        if (!avatarHash) return ""
        return "https://cdn.discordapp.com/avatars/" + userId + "/" + avatarHash + ".png?size=64"
    }

    // Never log OAuth tokens: on systemd setups console output lands in
    // the journal, where any journal reader could lift a live token.
    function sendBridgeCommand(cmd) {
        bridgeSocket.send(cmd)
    }

    // --- Visibility ---
    // Show the pill when in a voice call (participants), or when not
    // authenticated (login placeholder so the popout is reachable).
    // Hide only in the steady state: authenticated + idle.
    function updateVisibility() {
        if (inVoice || !authenticated) {
            clearVisibilityOverride()
        } else {
            setVisibilityOverride(false)
        }
    }

    Component.onCompleted: updateVisibility()
    onInVoiceChanged: updateVisibility()
    onAuthenticatedChanged: updateVisibility()

    // =====================================================================
    // DankSocket connection to bridge (the daemon surface owns the process)
    // =====================================================================

    DankSocket {
        id: bridgeSocket
        path: root.bridgeSocketPath
        connected: false

        parser: SplitParser {
            onRead: message => {
                if (!message || message.length === 0) return
                try {
                    const msg = JSON.parse(message)
                    root.handleBridgeMessage(msg)
                } catch (e) {
                    console.warn("DiscordVoice: parse error:", e)
                }
            }
        }
    }

    // Connect socket after the daemon's bridge has had time to create its
    // socket file. DankSocket retries with backoff until the bridge is up,
    // so a fixed delay is safe.
    Timer {
        id: socketConnectTimer
        interval: 800
        running: true
        onTriggered: {
            console.warn("DiscordVoice: connecting socket to bridge")
            bridgeSocket.connected = true
        }
    }

    // =====================================================================
    // Message handler
    // =====================================================================

    function handleBridgeMessage(msg) {
        switch (msg.type) {
        case "ready":
            bridgeSocket.send({cmd: "connect"})
            break

        case "auth_required":
            authenticated = false
            authError = ""
            break

        case "auth_complete":
            authenticated = true
            authError = ""
            discordConnected = true
            break

        case "discord_status":
            discordConnected = msg.connected === true
            break

        case "auth_error":
            authError = msg.error || "Authentication failed"
            authenticated = false
            break

        case "voice_channel":
            currentChannel = msg.channel || null
            if (!msg.channel) {
                voiceUsers = []
                speakingUsers = {}
            }
            break

        case "voice_state":
            voiceUsers = msg.users || []
            break

        case "speaking":
            let updated = Object.assign({}, speakingUsers)
            updated[msg.user_id] = msg.speaking
            speakingUsers = updated
            break

        case "voice_settings":
            voiceSettings = {
                mute: msg.mute || false,
                deaf: msg.deaf || false
            }
            break

        case "disconnected":
            authenticated = false
            discordConnected = false
            currentChannel = null
            voiceUsers = []
            speakingUsers = {}
            break

        case "error":
            console.warn("DiscordVoice bridge error:", msg.error)
            break
        }
    }

    // =====================================================================
    // Bar pills (the daemon surface registers the "discord" IpcHandler)
    // =====================================================================

    horizontalBarPill: Component {
        Row {
            spacing: -4

            DankIcon {
                visible: !root.authenticated
                anchors.verticalCenter: parent.verticalCenter
                name: "headset_mic"
                size: Math.min(root.widgetThickness, 18)
                color: root.authError ? Theme.error : Theme.surfaceVariantText
            }

            Repeater {
                model: {
                    if (!root.inVoice) return []
                    const users = root.voiceUsers
                    return users.length > root.maxBarAvatars
                        ? users.slice(0, root.maxBarAvatars)
                        : users
                }

                Item {
                    width: root.widgetThickness
                    height: root.widgetThickness
                    anchors.verticalCenter: parent.verticalCenter

                    // Speaking / mute ring
                    Rectangle {
                        id: avatarRing
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: 2
                        border.color: {
                            const isMuted = modelData.self_mute || modelData.mute
                            const isDeaf = modelData.self_deaf || modelData.deaf
                            const isSpeaking = root.speakingUsers[modelData.id] === true

                            if (isDeaf || isMuted) return Theme.error
                            if (isSpeaking) return Theme.success || "#4CAF50"
                            return "transparent"
                        }

                        Behavior on border.color {
                            DankColorAnim {
                                duration: Theme.shorterDuration
                            }
                        }
                    }

                    // Avatar image
                    DankCircularImage {
                        anchors.fill: parent
                        anchors.margins: 2
                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                        fallbackText: modelData.username ? modelData.username.charAt(0).toUpperCase() : "?"
                        fallbackIcon: ""
                    }

                    // Mute/deafen badge
                    Rectangle {
                        visible: modelData.self_mute || modelData.mute || modelData.self_deaf || modelData.deaf
                        width: Math.max(10, root.widgetThickness * 0.35)
                        height: width
                        radius: width / 2
                        color: Theme.error
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right

                        DankIcon {
                            anchors.centerIn: parent
                            name: (modelData.self_deaf || modelData.deaf) ? "headset_off" : "mic_off"
                            size: parent.width - 2
                            color: Theme.onError || "white"
                        }
                    }
                }
            }

            // Overflow count
            StyledText {
                visible: root.inVoice && root.voiceUsers.length > root.maxBarAvatars
                text: "+" + (root.voiceUsers.length - root.maxBarAvatars)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: -4

            DankIcon {
                visible: !root.authenticated
                anchors.horizontalCenter: parent.horizontalCenter
                name: "headset_mic"
                size: Math.min(root.widgetThickness, 18)
                color: root.authError ? Theme.error : Theme.surfaceVariantText
            }

            Repeater {
                model: {
                    if (!root.inVoice) return []
                    const users = root.voiceUsers
                    return users.length > root.maxBarAvatars
                        ? users.slice(0, root.maxBarAvatars)
                        : users
                }

                Item {
                    width: root.widgetThickness
                    height: root.widgetThickness
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: 2
                        border.color: {
                            const isMuted = modelData.self_mute || modelData.mute
                            const isDeaf = modelData.self_deaf || modelData.deaf
                            const isSpeaking = root.speakingUsers[modelData.id] === true

                            if (isDeaf || isMuted) return Theme.error
                            if (isSpeaking) return Theme.success || "#4CAF50"
                            return "transparent"
                        }

                        Behavior on border.color {
                            DankColorAnim {
                                duration: Theme.shorterDuration
                            }
                        }
                    }

                    DankCircularImage {
                        anchors.fill: parent
                        anchors.margins: 2
                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                        fallbackText: modelData.username ? modelData.username.charAt(0).toUpperCase() : "?"
                        fallbackIcon: ""
                    }

                    Rectangle {
                        visible: modelData.self_mute || modelData.mute || modelData.self_deaf || modelData.deaf
                        width: Math.max(10, root.widgetThickness * 0.35)
                        height: width
                        radius: width / 2
                        color: Theme.error
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right

                        DankIcon {
                            anchors.centerIn: parent
                            name: (modelData.self_deaf || modelData.deaf) ? "headset_off" : "mic_off"
                            size: parent.width - 2
                            color: Theme.onError || "white"
                        }
                    }
                }
            }

            StyledText {
                visible: root.inVoice && root.voiceUsers.length > root.maxBarAvatars
                text: "+" + (root.voiceUsers.length - root.maxBarAvatars)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // =====================================================================
    // Popout
    // =====================================================================

    popoutWidth: 320
    popoutHeight: 400

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: root.inVoice ? (root.currentChannel ? root.currentChannel.name : "Voice Channel") : "Discord Call Overlay"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // --- Not authenticated ---
                Column {
                    visible: !root.authenticated
                    width: parent.width
                    spacing: Theme.spacingM

                    DankIcon {
                        id: authIcon
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: root.discordConnected || root.authError.length > 0 ? "link" : "sync"
                        size: 48
                        color: root.authError ? Theme.error : Theme.surfaceVariantText

                        RotationAnimator on rotation {
                            from: 0
                            to: 360
                            duration: 1000
                            loops: Animation.Infinite
                            running: !root.discordConnected && root.authError.length === 0

                            onRunningChanged: {
                                if (!running)
                                    authIcon.rotation = 0;
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: {
                            if (root.authError) return root.authError
                            if (!root.discordConnected) return "Discord isn't running. It will connect automatically once Discord starts."
                            return "Connect to Discord to see voice channel participants and control mute/deafen."
                        }
                        color: root.authError ? Theme.error : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        visible: root.discordConnected || root.authError.length > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: authRow.width + Theme.spacingL * 2
                        height: authRow.height + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.primary

                        Row {
                            id: authRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            DankIcon {
                                name: "login"
                                size: Theme.fontSizeMedium
                                color: Theme.onPrimary || "white"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                text: "Authorize Discord"
                                color: Theme.onPrimary || "white"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                console.warn("DiscordVoice: authorize button clicked")
                                root.sendBridgeCommand({cmd: "authorize"})
                            }
                        }
                    }
                }

                // --- Authenticated, in voice ---
                Column {
                    visible: root.authenticated && root.inVoice
                    width: parent.width
                    spacing: Theme.spacingS

                    // Participant list
                    Item {
                        id: userListContainer
                        width: parent.width
                        implicitHeight: Math.min(participantList.contentHeight, root.userListMaxHeight)
                        height: implicitHeight

                        DankListView {
                            id: participantList
                            anchors.fill: parent
                            clip: true
                            model: root.voiceUsers
                            spacing: Theme.spacingS

                            delegate: Rectangle {
                                width: ListView.view.width
                                height: 44
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                required property var modelData

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS

                                    DankCircularImage {
                                        width: 32
                                        height: 32
                                        anchors.verticalCenter: parent.verticalCenter
                                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                                        fallbackText: modelData.username ? modelData.username.charAt(0).toUpperCase() : "?"
                                        fallbackIcon: ""
                                        border.width: root.speakingUsers[modelData.id] === true ? 2 : 0
                                        border.color: Theme.success || "#4CAF50"
                                    }

                                    StyledText {
                                        text: modelData.nick || modelData.username || "Unknown"
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                        width: parent.width - 32 - statusRow.width - Theme.spacingS * 3
                                    }

                                    Row {
                                        id: statusRow
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        DankIcon {
                                            visible: modelData.self_mute || modelData.mute
                                            name: "mic_off"
                                            size: 16
                                            color: Theme.error
                                        }
                                        DankIcon {
                                            visible: modelData.self_deaf || modelData.deaf
                                            name: "headset_off"
                                            size: 16
                                            color: Theme.error
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Mute / deafen controls
                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        topPadding: Theme.spacingS

                        Rectangle {
                            width: (parent.width - Theme.spacingS) / 2
                            height: 40
                            radius: Theme.cornerRadius
                            color: root.isMuted ? Theme.error : Theme.surfaceContainerHigh

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                DankIcon {
                                    name: root.isMuted ? "mic_off" : "mic"
                                    size: 18
                                    color: root.isMuted ? (Theme.onError || "white") : Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: root.isMuted ? "Unmute" : "Mute"
                                    color: root.isMuted ? (Theme.onError || "white") : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.sendBridgeCommand({cmd: "set_voice_settings", mute: !root.isMuted})
                            }
                        }

                        Rectangle {
                            width: (parent.width - Theme.spacingS) / 2
                            height: 40
                            radius: Theme.cornerRadius
                            color: root.isDeafened ? Theme.error : Theme.surfaceContainerHigh

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                DankIcon {
                                    name: root.isDeafened ? "headset_off" : "headset"
                                    size: 18
                                    color: root.isDeafened ? (Theme.onError || "white") : Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: root.isDeafened ? "Undeafen" : "Deafen"
                                    color: root.isDeafened ? (Theme.onError || "white") : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.sendBridgeCommand({cmd: "set_voice_settings", deaf: !root.isDeafened})
                            }
                        }
                    }
                }

                // --- Authenticated, not in voice ---
                Column {
                    visible: root.authenticated && !root.inVoice
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: "No active Discord call found"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }
}
