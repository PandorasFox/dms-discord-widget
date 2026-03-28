# Discord Voice Widget for DankMaterialShell

A DankBar plugin that shows Discord voice channel participants as circular avatars with real-time speaking, mute, and deafen indicators.

## Installation

Install from the DMS Plugin Browser (Settings > Plugins), or manually:

```bash
git clone https://github.com/PandorasFox/dms-discord-widget.git \
  ~/.config/DankMaterialShell/plugins/discordVoice
```

Requires `python3` (3.10+).

## Setup

1. Add the **Discord Voice** widget to your DankBar
2. Click the widget to open the popout
3. Click **Authorize Discord** — Discord will show a consent dialog
4. Once authorized, the widget auto-connects on future launches

## Keybind Integration

The plugin registers an IPC handler at target `discord`:

| Command | Description |
|---------|-------------|
| `dms ipc call discord toggleMute` | Toggle microphone mute |
| `dms ipc call discord toggleDeafen` | Toggle deafen |
| `dms ipc call discord muteOn` | Mute microphone |
| `dms ipc call discord muteOff` | Unmute microphone |
| `dms ipc call discord deafenOn` | Enable deafen |
| `dms ipc call discord deafenOff` | Disable deafen |
| `dms ipc call discord status` | Get current voice state as JSON |

`muteOn`/`muteOff` are useful for push-to-talk setups — bind them to a key press and release in your compositor.

## Settings

Available in DMS Settings > Plugins > Discord Voice:

| Setting | Default | Description |
|---------|---------|-------------|
| Max Bar Avatars | 5 | Maximum avatars shown in the bar |

## License

Same license as DankMaterialShell.
