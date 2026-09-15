# macOS Mic Switch (`mic-lock`)

A menu-bar helper that keeps your Mac's default audio **input** on the device you actually want — and never lets a Bluetooth headset quietly hijack it.

## The problems it solves

**1. Bluetooth headsets hijack your mic, and wreck your audio while doing it.**
When you connect AirPods or any Bluetooth headphones, macOS switches the audio *input* to the headset mic. That mic runs over the Hands-Free Profile — phone-call quality. Worse, the moment the headset is used as an input, the whole device drops out of high-quality A2DP into HFP, so the music you *hear* degrades too.

**2. With the lid closed, the built-in mic is completely deaf.**
On a MacBook in clamshell mode (lid shut, external display), the built-in microphone does not merely sound muffled — it delivers *pure digital silence*. Measured over six seconds: 264,600 samples, every one of them exactly zero. A tool that stubbornly pins the input to the built-in mic will happily leave you on a dead microphone for an entire meeting without either you or your call software noticing.

**3. An iPhone mic takes seconds to wake up, and stutters your headphones when it does.**
Continuity is the natural answer to problem 2, but bringing up the session costs about 3.5 seconds, and the BLE + AWDL handshake it performs is a burst of 2.4 GHz traffic that starves the A2DP stream to your Bluetooth headphones — an audible dropout every single time.

`mic-lock` handles all three.

## What it does

- **Pins the default input** to your chosen device, reverting anything that moves it.
- **Menu-bar control.** Pick the target from a list of live input devices, or leave it on *Auto*.
- **Clamshell aware.** In *Auto*, a closed lid switches to an iPhone (Continuity) mic if one is available, and switches back to the built-in mic when you open it.
- **Manual picks stick.** Selecting any non-Bluetooth device — in System Settings, in a call app, anywhere — is adopted as the new pin.
- **Bluetooth always bounces.** A headset that grabs the input is sent straight back. You can still pin one deliberately from the menu, but that choice is never remembered and is dropped when the device disconnects.
- **Graceful fallback.** If the pinned device disappears, the input falls back temporarily and returns to your choice the moment the device is back. Continuity mics are remembered by *kind*, not by UID, because iPhones get a fresh UID on every reconnect.
- **Dead-mic warning.** If the pinned device cannot actually hear anything (built-in mic, lid shut), the menu-bar icon turns into a red warning triangle.
- **Session keep-warm**, in three modes. *Automatic* holds the session once some app has used the iPhone mic and lets go after a long idle stretch, so the *next* app gets it instantly with no handshake and no headphone stutter. *Always on* holds it from the moment the device is pinned and never times out, for stretches of work that run for hours. *Off* never opens the mic at all.

## Measurements

Taken on a MacBook Air in clamshell mode, iPhone connected wirelessly, Sennheiser MOMENTUM 4 on A2DP. Your numbers will differ, but the shape should hold.

| Time from opening the mic to the first real audio sample | |
| --- | --- |
| Cold Continuity session | **3.3 – 4.3 s** |
| Session used seconds ago | 0.5 – 0.6 s |
| Session held by keep-warm | **0.36 s** |

The Continuity session goes cold after well under a minute of disuse, so "just use it often" is not a workaround.

The headphone stutter was checked by ear against a sustained chord, triggering the mic at a fixed point: clearly audible on a cold session, entirely absent with keep-warm holding. That half is subjective by nature — the latency figures above are the measurable part.

## How it works

Event-driven, and idle at 0% CPU:

- Two **CoreAudio property listeners** — default-input-device changed, and device-list changed.
- A listener on `kAudioDevicePropertyDeviceIsRunningSomewhere` for the pinned device, which is how it learns that an app opened the mic. (Per-process `kAudioProcessPropertyIsRunningInput` listeners register successfully but never fire — don't build on them.)
- **`AppleClamshellState`** read from IOKit's `IOPMrootDomain` for lid state, re-checked when the display configuration changes.
- Devices are identified by **hardware transport type**, never by name, so it works on any Mac in any system language.

The one exception to "no polling": while keep-warm is actively holding the session, occupying the device pins its `IsRunningSomewhere` flag at 1, so it can no longer report whether anyone else is using the mic. During that window only, `mic-lock` checks the audio process list every 10 seconds to decide when things have gone idle. When it is not holding, it polls nothing.

It runs as a per-user `launchd` agent: starts at login, restarts itself if it dies.

## Privacy

Keep-warm genuinely opens the microphone — that is the entire point, since a stream of zeros would keep nothing alive. So:

- macOS shows the **orange microphone indicator** the whole time it is holding. That indicator is telling you the truth, and nothing here tries to work around it.
- Captured buffers are **discarded in the tap callback**. Nothing is written anywhere, ever.
- It only holds sessions for **Continuity devices**, which are the only ones expensive enough to be worth it. Built-in and USB mics are never held open.
- In *Automatic* mode it releases after **10 minutes** of nobody using the mic, and in every mode it releases immediately when you open the lid, pause it, or switch to a non-Continuity device.
- *Always on* is the one mode that keeps the mic open indefinitely, and therefore the indicator lit, until you switch it back. Pick it deliberately.
- Turn it off entirely from the menu, and it will never open the mic at all.

## Requirements

- **macOS 14.4 or later** (the audio process-object API used to detect capture)
- Xcode Command Line Tools, for `swiftc` — `xcode-select --install`

## Install

```sh
git clone https://github.com/Lycnkd/Macos_mic_switch.git
cd Macos_mic_switch
./install.sh
```

Builds `~/.local/share/mic-lock/MicLock.app`, writes a `launchd` agent and starts it. A microphone icon appears in your menu bar. No `sudo` required.

The first time keep-warm engages, macOS asks for microphone permission. Decline it and everything else still works — you just keep paying the cold-start cost.

## The menu

| Item | Meaning |
| --- | --- |
| **Current input** | The device the input is on right now, plus warnings if it is deaf or if the pinned device is missing |
| **Auto (follow lid)** | Built-in mic normally; iPhone mic when the lid is shut |
| *device list* | Pick one to pin it. Bluetooth entries are marked as not remembered |
| **Keep-warm mode** | Status line, plus a submenu: Automatic, Always on, or Off |
| **Pause** | Stop enforcing entirely, without unloading the agent |
| **Quit** | Unloads the launchd job too, so `KeepAlive` doesn't just restart it. Comes back at next login |

## Preferences

Stored in the `com.miclock` defaults domain.

```sh
# How long to hold an idle session, in seconds (default 600)
defaults write com.miclock keepWarmIdleSeconds -float 1800

# Keep-warm mode: auto (default), always, or off
defaults write com.miclock keepWarmMode -string always

# Forget the pinned device and go back to Auto
defaults delete com.miclock pinnedDeviceUID

# Force the menu language, if your preferred-language order disagrees
defaults write com.miclock language zh    # or: en
```

Reload after editing: `launchctl bootout gui/$(id -u)/com.miclock && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.miclock.plist`

## Managing it

```sh
launchctl bootout   gui/$(id -u)/com.miclock                                  # stop
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.miclock.plist     # start
launchctl list | grep miclock                                                 # running?
tail -f ~/Library/Logs/miclock.log                                            # what is it doing
```

## Notes

- **Rebuilding re-triggers the permission prompt.** The ad-hoc signature changes on every build, so macOS sees a different app and asks for microphone access again. Only affects you if you are hacking on it.
- **Continuity transport types are not a link indicator.** The same iPhone, never plugged in, reported `ccwd` ("Continuity Capture Wired") at one moment and `ccwl` ("Wireless") at another. Match on both; don't infer the physical link from either.
- **CoreAudio publishes a private `CADefaultDeviceAggregate-<pid>-<n>` device** whenever an engine follows the default device, including this one's. It reports `IsHidden = false` and lingers briefly after the engine stops, so it is filtered out by name — otherwise it shows up in the device list and can be adopted as a pin.

## Uninstall

```sh
./uninstall.sh
```

The microphone permission entry is left in System Settings → Privacy & Security → Microphone; remove it there if you want it gone.

## License

[MIT](LICENSE)
