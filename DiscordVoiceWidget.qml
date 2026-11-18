import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "discord-voice"

    property bool authenticated: false
    property string authError: ""
    property bool discordConnected: false

    property var currentChannel: null
    property var voiceUsers: []
    property var voiceSettings: ({mute: false, deaf: false})
    property var speakingUsers: ({})

    readonly property int maxBarAvatars: parseInt(pluginData.maxBarAvatars) || 5

    readonly property bool inVoice: currentChannel !== null && currentChannel !== undefined
    readonly property bool isMuted: voiceSettings.mute || false
    readonly property bool isDeafened: voiceSettings.deaf || false

    readonly property var barUsers: inVoice
        ? (voiceUsers.length > maxBarAvatars
            ? voiceUsers.slice(0, maxBarAvatars)
            : voiceUsers)
        : []

    readonly property int userListMaxHeight: {
        const rowHeight = 44 + Theme.spacingS
        const byRows = 20 * rowHeight
        const screenH = (root.parentScreen ? root.parentScreen.height : Screen.height) || 0
        const byScreen = screenH * 0.5
        return Math.min(byRows, byScreen)
    }

    readonly property string bridgeSocketPath: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
        return runtime + "/dms-discord-voice.sock"
    }

    function avatarUrl(userId, avatarHash) {
        if (!avatarHash) return ""
        return "https://cdn.discordapp.com/avatars/" + userId + "/" + avatarHash + ".png?size=64"
    }

    function initialOf(name) {
        return name ? name.charAt(0).toUpperCase() : "?"
    }

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

    // DSocket connection to bridge (the daemon surface owns the process)
    // Never log OAuth tokens: on systemd setups console output lands in
    // the journal, where any journal reader could lift a live token.

    DSocket {
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
    // socket file. DSocket retries with backoff until the bridge is up,
    // so a fixed delay is safe.
    Timer {
        id: socketConnectTimer
        interval: 800
        running: true
        onTriggered: bridgeSocket.connected = true
    }

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

    // Bar pills (the daemon surface registers the "discord" IpcHandler)

    // One avatar per user, shared by both pill orientations. The item is
    // square and the largest child, so it defines the pill's cross-axis
    // size and needs no axis anchoring.
    property Component barAvatar: Component {
        Item {
            width: root.widgetThickness
            height: root.widgetThickness

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
                    DColorAnim {
                        duration: Theme.shorterDuration
                    }
                }
            }

            DCircularImage {
                anchors.fill: parent
                anchors.margins: 2
                imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                fallbackText: root.initialOf(modelData.username)
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

                DIcon {
                    anchors.centerIn: parent
                    name: (modelData.self_deaf || modelData.deaf) ? "headset_off" : "mic_off"
                    size: parent.width - 2
                    color: Theme.onError || "white"
                }
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: -4

            DIcon {
                visible: !root.authenticated
                anchors.verticalCenter: parent.verticalCenter
                name: "headset_mic"
                size: Math.min(root.widgetThickness, 18)
                color: root.authError ? Theme.error : Theme.surfaceVariantText
            }

            Repeater {
                model: root.barUsers
                delegate: barAvatar
            }

            StyledText {
                visible: root.inVoice && root.voiceUsers.length > root.maxBarAvatars
                text: "+" + (root.voiceUsers.length - root.maxBarAvatars)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: -4

            DIcon {
                visible: !root.authenticated
                anchors.horizontalCenter: parent.horizontalCenter
                name: "headset_mic"
                size: Math.min(root.widgetThickness, 18)
                color: root.authError ? Theme.error : Theme.surfaceVariantText
            }

            Repeater {
                model: root.barUsers
                delegate: barAvatar
            }

            StyledText {
                visible: root.inVoice && root.voiceUsers.length > root.maxBarAvatars
                text: "+" + (root.voiceUsers.length - root.maxBarAvatars)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

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

                Column {
                    visible: !root.authenticated
                    width: parent.width
                    spacing: Theme.spacingM

                    DIcon {
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

                            DIcon {
                                name: "login"
                                size: Theme.fontSizeMedium
                                color: Theme.onPrimary
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                text: "Authorize Discord"
                                color: Theme.onPrimary
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bridgeSocket.send({cmd: "authorize"})
                        }
                    }
                }

                Column {
                    visible: root.authenticated && root.inVoice
                    width: parent.width
                    spacing: Theme.spacingS

                    Item {
                        id: userListContainer
                        width: parent.width
                        implicitHeight: Math.min(participantList.contentHeight, root.userListMaxHeight)
                        height: implicitHeight

                        DListView {
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

                                    DCircularImage {
                                        width: 32
                                        height: 32
                                        anchors.verticalCenter: parent.verticalCenter
                                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                                        fallbackText: root.initialOf(modelData.username)
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

                                        DIcon {
                                            visible: modelData.self_mute || modelData.mute
                                            name: "mic_off"
                                            size: 16
                                            color: Theme.error
                                        }
                                        DIcon {
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

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        topPadding: Theme.spacingS

                        Repeater {
                            model: [
                                {active: root.isMuted,     iconOn: "mic_off",     iconOff: "mic",     labelOn: "Unmute",   labelOff: "Mute",   key: "mute"},
                                {active: root.isDeafened,  iconOn: "headset_off", iconOff: "headset", labelOn: "Undeafen", labelOff: "Deafen", key: "deaf"}
                            ]

                            Rectangle {
                                width: (parent.width - Theme.spacingS) / 2
                                height: 40
                                radius: Theme.cornerRadius
                                color: modelData.active ? Theme.error : Theme.surfaceContainerHigh

                                Row {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingXS

                                    DIcon {
                                        name: modelData.active ? modelData.iconOn : modelData.iconOff
                                        size: 18
                                        color: modelData.active ? (Theme.onError || "white") : Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    StyledText {
                                        text: modelData.active ? modelData.labelOn : modelData.labelOff
                                        color: modelData.active ? (Theme.onError || "white") : Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeSmall
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const cmd = {cmd: "set_voice_settings"}
                                        cmd[modelData.key] = !modelData.active
                                        bridgeSocket.send(cmd)
                                    }
                                }
                            }
                        }
                    }
                }

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
