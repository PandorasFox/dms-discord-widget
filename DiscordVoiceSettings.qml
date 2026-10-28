import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "discordVoice"

    StyledText {
        width: parent.width
        text: "Discord Voice Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Show Discord voice channel participants in DankBar with speaking and mute indicators."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "maxBarAvatars"
        label: "Max Bar Avatars"
        description: "Maximum number of user avatars shown in the bar"
        defaultValue: 5
        minimum: 1
        maximum: 10
        leftIcon: "group"
    }

    StyledText {
        width: parent.width
        text: "Keybind integration via 'dms ipc call discord <command>' — see the README for the full command list."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
