<div align="center">

# OSCSlider

**A control panel for your VRChat avatar's parameters over OSC.**
Sliders, toggles, automations and sequences, with your avatar's parameters discovered for you.

[![Latest release](https://img.shields.io/github/v/release/estrogencat/OSCSlider?label=download)](../../releases/latest)
[![Downloads](https://img.shields.io/github/downloads/estrogencat/OSCSlider/total)](../../releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)
![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20Linux%20%7C%20macOS-555)

</div>

> [!NOTE]
> Sonnet 5 Ultracode was used to assist in making this, mostly the compiling stuff and ironing out a bunch of bugs I couldn't wrap my head around.

## Getting started

1. Grab a build from the [latest release](../../releases/latest):

   | Platform | Download |
   | --- | --- |
   | Windows | `OSCSlider-Setup.exe`, or the portable `.zip` |
   | Linux (x64) | **`OSCSlider-x86_64.AppImage`**: one file, just make it executable and run it<br>`oscslider_<version>_amd64.deb` for Debian/Ubuntu<br>`OSCSlider-linux-x64.tar.gz`: a plain folder, with `./install.sh` to add it to your app menu |
   | macOS (Intel + Apple Silicon) | **`OSCSlider-macos.dmg`**: open it and drag OSCSlider into Applications<br>`OSCSlider-macos.zip` if you'd rather skip the disk image<br>(see the [FAQ](#faq) for opening an unsigned app) |

2. In VRChat, turn on OSC: **Action Menu → Options → OSC → Enabled**.
3. Open OSCSlider and hit **Discover** (the wifi-search icon in the title bar) to pull in your current avatar's parameters.

The chip in the title bar turns green once VRChat is found.

> [!TIP]
> OSCSlider works alongside face tracking, VRCOSC and other OSC apps. It gets VRChat's output through its own OSCQuery service instead of fighting over port 9001.

## Features

### Controls
- **Sliders** (float or int) and **toggles** for any avatar parameter. Int sliders snap to whole numbers, floats can snap to a step, and sliders can **spring back** when released, like a joystick.
- **Buttons**: hold them down, or tap for a quick press and release.
- **Chatbox**: type into your VRChat chatbox, with the typing bubble while you write and a 144-character counter.
- **VRChat controls library**: VRChat's own OSC controls, ready to add without typing addresses. Movement and look axes, jump, run, grab/use/drop, voice, Quick Menu, Safe Mode, chatbox, and avatar height.
- **Custom** parameters for any OSC type (int64, double, string, color, MIDI, blob, time tag...) and any address. Start a name with `/` to send somewhere other than `/avatar/parameters/`.
- **Live sync** from VRChat. Changes made in-game (radial menu, contacts, physbones) show up on the dashboard as they happen.
- A grid that uses the space on a wide window, collapsible categories, and a <kbd>⋮</kbd> / right-click menu on every parameter.

### Discovery
- Lists your current avatar's parameters **with their types and current values**. Add one at a time or all at once.
- **Highlight active**: move something in-game and its parameter jumps to the top of the list. A noise filter keeps always-changing parameters (Voice, Velocity...) from hogging the top.
- VRChat's read-only built-ins (`Grounded`, `AFK`...) are hidden by default. They can't be set, but you can still add them to use as triggers.
- If VRChat's OSCQuery server hangs (it does on some heavy avatars), discovery falls back to the avatar config VRChat saves on disk.

### Automations
Give any slider or toggle a life of its own:

| Type | What it does |
| --- | --- |
| **Ramp** | Glides between two values. Once, loop or ping-pong, with a repeat count, per-repeat speed change, and linear / ease / sine / hand-drawn easing curves |
| **Random** | Picks a new value (or flips a toggle) at random intervals, optionally drifting smoothly |
| **Blink** | Cycles a toggle on and off |
| **Schedule** | Fires at a time of day (on chosen weekdays), every N seconds, after you've been idle, or once after a countdown. Can auto-revert for a pulse |

Any automation can be **triggered by another parameter**: when a toggle turns on or off, while it's on, when a slider crosses a threshold, and more. It can also fire only every N activations.

### Sequences
Script changes across several parameters: *set a value, wait, glide another, press a button, say something in the chatbox, loop*. Sequences can be triggered like automations, and can run their own per-parameter automations that only live while the sequence runs. The app keeps sequences and automations from fighting over the same parameter.

### Profiles & snapshots
- A separate parameter set per avatar. **Auto mode** switches profiles when you change avatar, picking up the one you're already wearing. It can also create profiles for new avatars, named after the avatar, or only switch between ones you've already linked.
- Duplicate profiles, or share them as JSON via the clipboard.
- **Snapshots** freeze the current values under a name so you can apply them again later.

### Other OSC apps
- **Forwarding**: relay VRChat's output to apps that can't use OSCQuery, so they don't need port 9001 to themselves. You can also copy everything OSCSlider sends to another device.
- A configurable fallback listen port, for when VRChat is launched with a custom `--osc` output port.

### Everything else
- A Material You theme picker, with presets or a custom colour wheel.
- A connection chip that shows whether VRChat is found, whether data is arriving, and any send errors. It also offers a one-click fix if VRChat is listening on a different port than you're sending to.
- Crash-safe config: saves can't corrupt `config.json`, and a broken one can be restored from the last good copy.
- Opt-in extras under *Settings → Features that are disabled by default*, such as the **Automation Master Switch** for bulk enabling/disabling automations.

<details>
<summary><strong>Developer Mode</strong></summary>

Tap the version number at the bottom of Settings 5 times to unlock it, and 5 more times to hide it again. It adds full-precision slider values, a configurable OSCQuery timeout, and discovery from *any* OSCQuery service instead of only VRChat, which is handy for testing other OSC tools.

</details>

## FAQ

<details>
<summary><strong>The chip says "Not detected"</strong></summary>

- Make sure OSC is enabled in VRChat (Action Menu → Options → OSC).
- Windows may ask whether to allow OSCSlider on your network the first time it runs. It needs that to find VRChat, so allow it.
- VRChat only sends parameter changes when something changes, so the chip can say "found" before anything is received.

</details>

<details>
<summary><strong>My sliders don't do anything in-game</strong></summary>

- Check the chip for a send error, or a port-mismatch warning if you launched VRChat with a custom `--osc` port.
- Parameters marked **read-only** (VRChat's built-ins) can't be set by any OSC app.
- Parameter names are case-sensitive, and nested names like `Folder/Param` are part of the address.

</details>

<details>
<summary><strong>Can I use it with VRChat on Quest?</strong></summary>

Set **Send to host** in Settings to your Quest's IP address. Sending works, but receiving VRChat's output on a standalone Quest relies on the classic port 9001 fallback rather than OSCQuery.

</details>

<details>
<summary><strong>Where are my settings stored?</strong></summary>

| Platform | Folder |
| --- | --- |
| Windows | `%APPDATA%\OSCSlider\` |
| Linux | `~/.config/OSCSlider/` (or `$XDG_CONFIG_HOME/OSCSlider/`) |
| macOS | `~/Library/Containers/com.estrogencat.oscslider/Data/Library/Application Support/OSCSlider/` |

Inside are `config.json`, a `config.json.bak` from the last launch where the config loaded fine, and `crash.log` if anything went wrong. *⋮ → Open config folder* takes you there.

</details>

<details>
<summary><strong>Does it work with VRChat on Linux (Proton)?</strong></summary>

Yes, run the native Linux build alongside VRChat. Sending works like it does on Windows. Discovery also reads VRChat's saved avatar configs from its Proton prefix, in any Steam library, including Flatpak and Snap Steam. Whether VRChat under Proton finds the app over OSCQuery depends on Wine's networking; if it doesn't, the app falls back to port 9001 for receiving.

</details>

<details>
<summary><strong>macOS says the app can't be opened</strong></summary>

The macOS build isn't signed with an Apple developer certificate. Right-click the app and choose **Open** the first time, or run `xattr -dr com.apple.quarantine /path/to/OSCSlider.app`. It needs macOS 12 or newer, which includes older Macs running [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/). Since VRChat itself doesn't run on macOS, it's mostly useful for controlling VRChat on another PC or Quest on your network, or other OSC software.

</details>

<details>
<summary><strong>Does it run on ARM64 Windows?</strong></summary>

Yes. The x64 build runs through Windows' built-in emulation. Flutter doesn't offer a native ARM64 Windows toolchain yet, so there's no separate build.

</details>

## Building from source

<details>
<summary>Build, installer, project layout and protocol notes</summary>

### Build

Requires the Flutter SDK. Build on the platform you're targeting:

```bash
flutter pub get
flutter build windows --release   # build/windows/x64/runner/Release/
flutter build linux --release     # build/linux/x64/release/bundle/
flutter build macos --release     # build/macos/Build/Products/Release/OSCSlider.app
flutter test                      # optional
```

On Linux you'll also need the GTK toolchain: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev` (or your distro's equivalent). macOS needs Xcode.

### Installer

Requires [Inno Setup 6](https://jrsoftware.org/isinfo.php). Build the release binary first, then from the repo root:

```powershell
& "C:\Users\<you>\AppData\Local\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 installer\oscslider.iss
```

> [!IMPORTANT]
> Run that from PowerShell, not Git Bash or `cmd`. Bash's path translation mangles the `/D` define, and Inno Setup fails with a confusing "you may not specify more than one script filename" error.

The installer lands in `installer/Output/`.

### Releases & CI

- Every push and pull request runs `flutter analyze` and `flutter test` ([CI](.github/workflows/ci.yml)).
- Pushing a `v*` tag builds Windows (installer + zip), Linux (AppImage, `.deb`, tarball) and macOS (`.dmg` + zip), then publishes a release with generated notes and a `SHA256SUMS.txt` ([Release](.github/workflows/release.yml)). Tags with a suffix, like `v1.2.0-beta.1`, become pre-releases, which the in-app update check ignores.
- Running the Release workflow by hand builds everything as downloadable artifacts, without publishing.

### Project layout

| Path | Purpose |
| --- | --- |
| `lib/param_control.dart` | The data model (parameters, profiles, automations, sequences, triggers, `AppConfig`) and its JSON |
| `lib/live_controller.dart` | Live state shared by every screen, plus the tick loop that drives the engines, value sync and auto mode |
| `lib/*_engine.dart` | One engine each for automations, schedules, sequences and triggers. All are based on elapsed time, so they don't depend on the tick rate |
| `lib/osc_client.dart`, `osc_listener.dart` | Hand-rolled OSC encoder/decoder: UTF-8 addresses, bundles |
| `lib/oscquery_service.dart`, `mdns_codec.dart` | The app's own OSCQuery service: loopback HTTP + UDP, and a small mDNS responder |
| `lib/osc_input_hub.dart` | All incoming OSC in one stream, plus the connection status |
| `lib/oscquery_client.dart`, `discovery_flow.dart`, `vrchat_files.dart` | Finding VRChat, reading its parameter tree, and the saved-config fallback |
| `lib/vrchat_controls.dart` | The library of VRChat's built-in OSC controls (from docs.vrchat.com) |
| `lib/osc_relay.dart` | Forwarding to other OSC apps |
| `lib/platform_paths.dart` | Per-OS folders (config, VRChat's files under Proton) and socket options |
| `lib/main.dart`, `*_page.dart`, `*_dialog.dart`, `param_card.dart` | UI |
| `windows/`, `linux/`, `macos/`, `installer/` | Platform runners, packaging (`linux/packaging/package.sh` for AppImage/`.deb`/tarball, `macos/packaging/` for the `.dmg`), and the Inno Setup script |

### How receiving works

The app advertises `_oscjson._tcp` and `_osc._udp` over mDNS and serves an OSCQuery tree containing `/avatar/change`. VRChat sees that and sends its output straight to the app's own loopback port. For OSC software without OSCQuery, the classic `port + 1` (9001) is used as a fallback. It's bound exclusively, so it never steals packets from another app, and it's released as soon as VRChat is found over OSCQuery.

### OSC coverage

Automations, schedules and sequences use VRChat's own types (float, int, bool). Custom parameters cover the rest of the OSC 1.0/1.1 type tags, except arrays, which don't fit the one-parameter-one-value model.

### Config format

One `AppConfig` holding a list of `Profile`s. Each profile has parameters and sequences, and snapshots are profiles with `isSnapshot` set. Parameters can carry `automation` / `schedule` blocks, and automations and sequences can carry a `trigger`. New fields fall back to defaults when missing, so older configs keep loading.

</details>

## License

[MIT](LICENSE)
