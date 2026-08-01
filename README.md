# OSCSlider

A Windows desktop app for controlling VRChat avatar parameters over OSC - sliders, toggles, and custom values, with live discovery of your current avatar's parameters via OSCQuery.
> [!NOTE]
> Sonnet 5 Ultracode was used to assist in making this, mostly the compiling stuff and ironing out a bunch of bugs I couldn't wrap my head around.

## Features

- Sliders (float/int) and toggles for `/avatar/parameters/*`, plus a custom type covering the full OSC 1.0/1.1 type set (int64, double, symbol, char, RGBA color, MIDI message, blob, time tag, nil/infinitum) for anything VRChat itself doesn't use but other OSC software might
- Auto-discovery of the current avatar's parameters via VRChat's OSCQuery service, with search
- Drag-to-reorder, categories, and a right-click context menu for quick edits
- Profiles - a separate parameter set per avatar, with an opt-in auto mode that switches profiles when VRChat reports an avatar change
- A Material You theme picker (preset colors or a custom HSV wheel, with full per-role overrides in advanced mode)
- **Automations** - give any slider or toggle its own animation:
  - **Ramp**: glides between two values, with once/loop/ping-pong repeat, a repeat count, a per-repeat speed change (each cycle faster or slower than the last), and a choice of easing - linear, ease in/out, sine, or a hand-drawn custom curve (with optional spline smoothing and its own editable graph range)
  - **Random**: picks a new value (or flips a toggle) on a randomized interval, with optional smooth drift between values
  - **Blink**: cycles a toggle on/off on a fixed schedule
- **Schedules** - trigger a parameter change on a timer: at a specific time of day, on a repeating interval, after the app's been idle for a while, or once after a countdown - optionally auto-reverting after N seconds for a "pulse" instead of a permanent change
- **Sequences** - script several parameters to change one after another (a little visual program: set a value, wait, set another value...), with once or looping playback

## Getting the app

Grab the latest installer from [Releases](../../releases) - `OSCSlider-Setup.exe`. It installs to `Program Files` and stores its config in `%APPDATA%\OSCSlider\config.json`. There's also a portable `.zip` if you'd rather not install anything.

This is a single x64 build - it also runs great on ARM64 Windows (Surface-style devices) through Windows' built-in x64 emulation, since Flutter doesn't currently offer a native ARM64 Windows toolchain to build a separate binary from.

<details>
<summary><strong>Technical details</strong> (building from source, project layout, protocol notes)</summary>

### Building from source

Requires the Flutter SDK with Windows desktop support enabled.

```bash
flutter pub get
flutter build windows --release
```

The build output is at `build/windows/x64/runner/Release/`.

### Project layout

- `lib/param_control.dart` - the data model: parameters, profiles, automations, schedules, and sequences, plus their JSON (de)serialization
- `lib/main.dart` - the main screen and the single `Timer.periodic` tick loop that drives every engine
- `lib/automation_engine.dart`, `lib/schedule_engine.dart`, `lib/sequence_engine.dart` - one engine per feature, each computing its next state from elapsed wall-clock time (not stepped incrementally) so they're not sensitive to the exact tick rate
- `lib/osc_client.dart` / `lib/osc_listener.dart` - a minimal hand-rolled OSC 1.0 UDP encoder/decoder (no dependency pulls in the full spec)
- `lib/oscquery_client.dart` - OSCQuery discovery over mDNS + HTTP, used to find a running VRChat instance and read its current avatar's parameter tree
- `lib/settings_page.dart`, `lib/*_dialog.dart`, `lib/sequence_editor_page.dart` - the editor UI for each feature

### OSC coverage

Automations/schedules/sequences all operate on `/avatar/parameters/<name>` as float, int, or bool - VRChat's own supported types. The "Custom" parameter type additionally covers the rest of the OSC 1.0/1.1 type tag set for talking to non-VRChat OSC software; the one thing deliberately left out is arrays (`[`/`]`), since they group multiple values into a single argument slot and don't fit this app's one-parameter-one-value model.

### Config format

`%APPDATA%\OSCSlider\config.json` - one `AppConfig` with a list of `Profile`s (each with its own parameters and sequences); every `ParamControl` can carry an optional `automation` and/or `schedule` block. There's no schema migration system beyond a couple of `?? default` fallbacks in the `fromJson` constructors, so old configs load forward-compatibly as fields get added.

</details>
