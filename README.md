# OSCSlider

A Windows desktop app for controlling VRChat avatar parameters over OSC - sliders, toggles, and custom values, with live discovery of your current avatar's parameters via OSCQuery.
> [!NOTE]
> Sonnet 5 Ultracode was used to assist in making this, mostly the compiling stuff and ironing out a bunch of bugs I couldn't wrap my head around.

## Features

- Sliders (float/int) and toggles for `/avatar/parameters/*`, plus a custom type covering the full OSC 1.0/1.1 type set (int64, double, symbol, char, RGBA color, MIDI message, blob, time tag, nil/infinitum) for anything VRChat itself doesn't use but other OSC software might - manually-added parameters can also target a full OSC address outside `/avatar/parameters/` by typing a leading `/`
- Auto-discovery of the current avatar's parameters via VRChat's OSCQuery service - typed (toggle / int / float, with ints set up as 0-255 sliders), showing each one's current value, with search, "Add all", a manual "add a custom parameter path" option, and a "Fetch value" option that pulls a single parameter's current live value from the avatar into the app. VRChat's read-only built-ins (Grounded, AFK, Velocity...) are hidden behind a chip by default - they can't be set, but can still be added to use as trigger sources
  - If VRChat's OSCQuery server hangs (it does on some complex avatars), discovery falls back to the avatar's saved OSC config that VRChat keeps in `LocalLow\VRChat\VRChat\OSC`, so you still get the full list
  - **Highlight active parameters**: surfaces parameters as they actually change in VRChat - wiggle a physbone or trigger a contact and its parameter jumps to the top (and gets added to the list if it wasn't there). A noise filter keeps constantly-firing parameters (Voice, Velocity...) and anything that keeps recurring on its own cycle from hogging the top spot, without also swallowing a real physbone wiggle - its rate threshold (changes/sec) is adjustable in Settings > Miscellaneous
- **Plays nicely with other OSC apps**: the app runs its own OSCQuery service (the same thing VRCFaceTracking, VRCOSC etc. do), so VRChat sends its output to a port only this app uses. Nothing has to bind the shared 9001 port anymore, so face tracking and other tools keep working alongside it. The classic port is only used as a fallback for non-OSCQuery software, is never shared/stolen from another app, and is released as soon as VRChat is found
- **Sync values from VRChat** (on by default): changes made in-game - radial menu, contacts, physbones - show up on the dashboard live, and triggers can react to them. "Pull current values from VRChat" in the ⋮ menu grabs everything at once
- A live connection chip in the title bar: whether VRChat is found, whether its output is arriving, send errors (e.g. an unresolvable host), and a warning with a one-click fix if VRChat is listening on a different port than you're sending to. Errors show the *exact* underlying message in a copyable dialog instead of a generic "not found"
- A responsive grid (more columns on a wide window), collapsible categories, drag-to-reorder in Settings, and a ⋮ / right-click menu on every parameter (edit, automation, fetch, resend, delete). Int sliders snap to whole numbers
- Profiles - a separate parameter set per avatar, with an opt-in auto mode that switches profiles when VRChat reports an avatar change (named after the avatar). Profiles can be duplicated, and exported/imported as JSON via the clipboard for sharing
  - **Save Parameters / Snapshots**: freeze the currently active profile's live values into a static, named save that's never auto-switched to and never touched by avatar changes. Apply pushes a snapshot's saved values onto whatever profile is active now, adding any parameters it's missing; snapshots get their own editor for renaming, editing membership, and re-fetching individual saved values
- A Material You theme picker (preset colors or a custom HSV wheel, with full per-role overrides in advanced mode)
- **Automations** - give any slider or toggle its own animation:
  - **Ramp**: glides between two values, with once/loop/ping-pong repeat, a repeat count, a per-repeat speed change (each cycle faster or slower than the last), and a choice of easing - linear, ease in/out, sine, or a hand-drawn custom curve (with optional spline smoothing and its own editable graph range)
  - **Random**: picks a new value (or flips a toggle) on a randomized interval, with optional smooth drift between values
  - **Blink**: cycles a toggle on/off on a fixed schedule
  - Ramp/random/blink timing fields have no artificial minimum - set a duration as small as you want (the engine itself still guards against a literal zero causing a divide-by-zero)
  - Optionally **triggered by another parameter** instead of (or alongside) the manual switch: watch a toggle (turns on/off, or while on/off) or a slider (above/below/crosses a threshold, or inside/outside a range) to start it automatically - the "fires once" conditions (turns on/off, crosses above/below) can also require a configurable number of activations before actually firing, not just the first one
  - **Schedules** are folded into the same editor as just another automation "Type": fire at a specific time of day, on a repeating interval, after the app's been idle for a while, or once after a countdown - optionally auto-reverting after N seconds for a "pulse" instead of a permanent change
- **Sequences** - script several parameters to change one after another (a little visual program: set a value, wait, set another value...), with once or looping playback, and the same parameter-trigger option as automations (including the activation-count requirement above). Instant (0s) steps run together in the same moment, and the editor highlights the step that's currently running
  - A sequence can also give any of its parameters their **own automation** that runs only while the sequence itself is running - fully separate from that parameter's regular (global) automation, with its own enable/resume switch (so it can be paused within the sequence without losing its settings) and an optional start delay to stagger several automations in the same sequence instead of starting them all in lockstep. The main screen surfaces when a parameter is actually being driven by a sequence this way (with a management popup to pause, open the sequence, or unlink it), and the app automatically keeps a parameter's global automation, a sequence's per-parameter automation, and a sequence's own step script from ever fighting each other over the same value if more than one happens to target it at once
- **Hidden features** - a "Features that are disabled by default" button in Settings (next to Theme Color) unlocks opt-in extras. Currently: the **Automation Master Switch**, which adds a switch (in Settings, and next to the main search bar) to bulk enable/disable a chosen set of automations (or all of them) at once, as a one-time action rather than a persistent override - it automatically excludes anything currently driven by a sequence or continuously held by a "while on/off"-style trigger, since bulk-toggling either would just get overridden right back
- **Developer Mode** - hidden until you tap the version number in Settings 5 times (tap it 5 more times while it's visible to hide it again). Adds full-precision slider values, a configurable OSCQuery timeout, and lets parameter discovery/fetching find any OSCQuery-advertising program instead of requiring one that identifies as VRChat, for testing against other OSC tools
- **Safe config**: saves are atomic (a crash mid-save can't corrupt config.json), and if config.json ever fails to load you get options to restore the last working copy or start fresh - the broken file is always kept
- **Miscellaneous** settings - currently just the highlight-active-parameters noise filter's threshold (see above)

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

### Building the installer

Requires [Inno Setup 6](https://jrsoftware.org/isinfo.php). Build the release binary first (above), then compile `installer/oscslider.iss` from the repo root:

```powershell
& "C:\Users\<you>\AppData\Local\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 installer\oscslider.iss
```

Run this via PowerShell, not Git Bash/`cmd` - Bash's POSIX-path translation mangles the leading `/D` on the version define and Inno Setup fails with a confusing "you may not specify more than one script filename" error. The finished installer lands at `installer/Output/OSCSlider-Setup.exe`.

### Project layout

- `lib/param_control.dart` - the data model: parameters, profiles (including static "Save Parameters" snapshots), automations, schedules, sequences (including their own per-parameter automation overrides), parameter triggers, and `AppConfig` itself, plus their JSON (de)serialization
- `lib/main.dart` - the main screen
- `lib/live_controller.dart` - the live state shared by every screen (current values, text fields, the OSC client) and the single `Timer.periodic` tick loop that drives every engine; also applies values VRChat reports back and handles Auto Profile Mode
- `lib/automation_engine.dart`, `lib/schedule_engine.dart`, `lib/sequence_engine.dart`, `lib/trigger_engine.dart` - one engine per feature, each computing its next state from elapsed wall-clock time (not stepped incrementally) so they're not sensitive to the exact tick rate; `trigger_engine.dart` evaluates parameter triggers (including the required-activation-count for "fires once" conditions) and flips `enabled` on the automations/sequences they cover before the other engines tick. The tick loop also resolves conflicts up front each tick - a sequence actively driving a parameter always wins over that parameter's own global automation, and a sequence's own step script always wins over that same sequence's per-parameter automation override for the same parameter - so at most one source ever actually drives a given parameter's value
- `lib/osc_client.dart` / `lib/osc_listener.dart` - a minimal hand-rolled OSC 1.0 UDP encoder/decoder (no dependency pulls in the full spec), UTF-8 addresses, bundles on the receive side
- `lib/oscquery_service.dart` / `lib/mdns_codec.dart` - this app's own OSCQuery service: a loopback HTTP server (HOST_INFO + an `/avatar` tree), a loopback UDP port for VRChat's output, and a small mDNS responder that advertises both and passively notes other OSCQuery services (VRChat's included)
- `lib/osc_input_hub.dart` - every incoming OSC message in one stream, from the OSCQuery port (or the classic fixed port as a fallback), plus the connection status shown in the title bar
- `lib/live_param_listener.dart` - the discover popup's "highlight active parameters" listener and its noise-filtering tracker (a rate-based changes/sec threshold plus a total-promotions cap, so both continuously-firing and slowly-recurring parameters eventually stop monopolizing the top of the list)
- `lib/oscquery_client.dart` - finds a running VRChat (or, in Developer Mode, any) instance - last known endpoint first, then services the app already heard about, then a fresh mDNS search, each confirmed over HTTP - reads its current avatar's parameter tree, and fetches single live values on demand
- `lib/discovery_flow.dart` / `lib/vrchat_files.dart` - the shared Discover pipeline (OSCQuery tree, falling back to VRChat's saved per-avatar OSC config file) and the reader for those files
- `lib/param_card.dart` / `lib/connection_status.dart` - the parameter card shared by the main screen and sequence editor, and the connection chip/dialog
- `lib/error_dialog.dart` - shows a full, unabridged, selectable error in a dialog (used by discovery/fetch/connection-check failures) instead of a snackbar, which would clip or wrap long technical text
- `lib/app_updater.dart` - checks GitHub's "latest release" API against the running version
- `lib/settings_page.dart`, `lib/*_dialog.dart`, `lib/trigger_fields.dart`, `lib/sequences_page.dart`, `lib/sequence_editor_page.dart`, `lib/snapshot_editor_page.dart` - the editor UI for each feature; `trigger_fields.dart` is the watched-parameter/condition picker shared by the automation dialog and the sequence editor; `sequences_page.dart` is the sequence list hub, `sequence_editor_page.dart` is one sequence's full editor (steps, trigger, and its embedded parameter/automation panel), `snapshot_editor_page.dart` is the equivalent editor for a saved snapshot

### OSC coverage

Automations/schedules/sequences all operate on `/avatar/parameters/<name>` as float, int, or bool - VRChat's own supported types. The "Custom" parameter type additionally covers the rest of the OSC 1.0/1.1 type tag set for talking to non-VRChat OSC software; the one thing deliberately left out is arrays (`[`/`]`), since they group multiple values into a single argument slot and don't fit this app's one-parameter-one-value model. Manually-added parameters aren't actually restricted to `/avatar/parameters/` either - a name starting with `/` is sent to that exact address instead of being treated as a suffix.

Everything that reads VRChat's *outgoing* OSC (value sync, the "highlight active parameters" listener, Auto Profile Mode's `/avatar/change` watcher) gets it through the app's own OSCQuery service: it advertises `_oscjson._tcp` and `_osc._udp` over mDNS, serves a tree containing `/avatar/change`, and VRChat sends its output to the advertised loopback port. When something needs input before VRChat has been found that way (e.g. non-VRChat OSC software), the app also tries the classic `port + 1` (VRChat's default 9000-in/9001-out pairing) - bound exclusively, so it never steals packets from another app on that port, and released once OSCQuery traffic arrives.

### Config format

`%APPDATA%\OSCSlider\config.json` (plus `config.json.bak`, the last copy that loaded cleanly, and `crash.log`) - one `AppConfig` with a list of `Profile`s (each with its own parameters and sequences, plus a flag marking a profile as a static snapshot instead of a regular avatar-linked one); every `ParamControl` can carry an optional `automation` and/or `schedule` block, and both `Automation` and `AutomationSequence` can carry an optional `trigger` block. An `AutomationSequence` can additionally carry a `paramAutomations` map (parameter name → `Automation`) for its own per-parameter overrides. There's no schema migration system beyond a couple of `?? default` fallbacks in the `fromJson` constructors, so old configs load forward-compatibly as fields get added.

</details>
