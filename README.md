# macOS Mic Switch (`mic-lock`)

Keep your Mac's **built-in microphone** as the default audio input — automatically — so connecting AirPods or any Bluetooth headset never hijacks your mic again.

## The problem

When you connect Bluetooth headphones (AirPods, etc.), macOS happily switches the **audio input** to the headset's microphone. Two things go wrong:

1. **The mic sounds terrible.** A Bluetooth headset mic runs over the Hands-Free Profile (HFP), i.e. "phone-call" quality.
2. **Your audio output degrades too.** The moment the headset is used as an input, the whole device drops out of high-quality A2DP into HFP — so the music/sound you *hear* gets worse as well.

So every time you put your AirPods in, you have to open System Settings → Sound → Input and manually switch back to the built-in mic. This tool does it for you — instantly, every time.

## How it works

`mic-lock` is a tiny (~60 KB) native helper written in Swift. It:

- Registers two **CoreAudio property listeners** (`AudioObjectAddPropertyListenerBlock`): one for "default input device changed", one for "device list changed".
- Sits at **0% CPU** until one of those events fires — fully event-driven, **no polling**.
- When the default input drifts off the built-in mic, it switches it right back.
- Identifies the built-in mic by **hardware transport type** (`kAudioDeviceTransportTypeBuiltIn`), not by name — so it works on any Mac, in any system language.

It runs as a per-user `launchd` agent: starts at login and restarts itself if it ever dies.

## Requirements

- macOS (Apple Silicon or Intel)
- Xcode Command Line Tools (for the `swiftc` compiler). If you don't have them: `xcode-select --install`

## Install

```sh
git clone https://github.com/Lycnkd/Macos_mic_switch.git
cd Macos_mic_switch
./install.sh
```

The installer compiles the helper into `~/.local/bin/mic-lock`, writes a `launchd` agent, and starts it. Your input is pinned to the built-in mic immediately. No `sudo` required.

## Usage

Once installed it just works in the background. Manage it with `launchctl`:

```sh
# Temporarily stop it (e.g. to use an external USB mic)
launchctl bootout gui/$(id -u)/com.miclock

# Start it again
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.miclock.plist

# Is it running?
launchctl list | grep miclock

# See what it's doing
tail -f ~/Library/Logs/miclock.log
```

> **Note:** while running, it *locks* the input to the built-in mic — any attempt to select a different input is reverted. That's the whole point. To use another mic, stop it first with the `bootout` command above.

### Pinning a specific device instead of the built-in mic

By default it pins the built-in mic. To pin a different input device by name, pass the exact device name as `argv[1]`. Edit `~/Library/LaunchAgents/com.miclock.plist`, add the name as a second `<string>` inside `ProgramArguments`, then reload the agent (`bootout` then `bootstrap`).

## Uninstall

```sh
./uninstall.sh
```

…or manually:

```sh
launchctl bootout gui/$(id -u)/com.miclock
rm -f ~/.local/bin/mic-lock ~/Library/LaunchAgents/com.miclock.plist ~/Library/Logs/miclock.log
rm -rf ~/.local/share/mic-lock
```

## Why no `sudo`?

Everything is per-user: the binary lives in `~/.local/bin`, the agent in `~/Library/LaunchAgents`, and it changes only *your* default input device. No root, no system-wide modification.

## License

[MIT](LICENSE)
