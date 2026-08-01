# OSCSlider

A Windows desktop app for controlling VRChat avatar parameters over OSC - sliders, toggles, and custom values, with live discovery of your current avatar's parameters via OSCQuery.
> [!NOTE]
> Sonnet 5 Ultracode was used to assist in making this, mostly the compiling stuff and ironing out a bunch of bugs I couldn't wrap my head around.

## Features

- Sliders (float/int) and toggles for `/avatar/parameters/*`, plus a custom type for anything else OSC supports
- Auto-discovery of the current avatar's parameters via VRChat's OSCQuery service, with search
- Drag-to-reorder, categories, and a right-click context menu for quick edits
- Profiles - a separate parameter set per avatar, with an opt-in auto mode that switches profiles when VRChat reports an avatar change
- A Material You theme picker (preset colors or a custom HSV wheel, with per-role overrides in advanced mode)

## Getting the app

Grab the latest installer from [Releases](../../releases) - `OSCSlider-Setup-x64.exe` for regular PCs, `OSCSlider-Setup-arm64.exe` for ARM64 Windows devices (Surface-style tablets). It installs to `Program Files` and stores its config in `%APPDATA%\OSCSlider\config.json`.

## Building from source

Requires the Flutter SDK with Windows desktop support enabled.

```bash
flutter pub get
flutter build windows --release
```

The build output is at `build/windows/x64/runner/Release/`.
