> Integration update (0.7.0): these modules are now wired by `AppDelegate`, `IslandStore`, `ProductViews`, `ProductSettings` and `AppCommands`. The standalone-scope statements below describe the original lane handoff, not current app wiring. See [current acceptance](verification.md).

# Zero feature modules — integration handoff

## Scope and ownership

This change implements standalone character, wardrobe, desktop, sound and global-shortcut modules. It intentionally does **not** wire application/store/settings behavior or change Package.swift, project.yml, Xcode project files, export lists or other manifests. The final integrator owns those changes. No dependencies, external artwork/audio, plugin deployment or Git operations are required by these modules.

The existing original asymmetrical pale pebble shell, inset dark visor, white eyes, colored lower rim and small signal marks are retained. State effects and accessories extend that identity, rather than substituting another mascot. `reference/a0-notch.html` is unavailable: no exact-copy or reference-perfect motion claim is made.

## Production source files

All live under `app/Sources/A0Notch/`:

1. `ZeroView.swift` — existing renderer, extended with compatible defaults.
2. `ZeroCharacter.swift` — public state/emote enums, pure motion helpers, optional interaction adapter.
3. `ZeroWardrobe.swift` — persisted selection, calendar, wardrobe UI, original vector accessories.
4. `DesktopZeroController.swift` — native passive desktop window and lifecycle.
5. `NotchSoundPlayer.swift` — original deterministic WAV synthesis and layered AVAudioPlayer pool.
6. `GlobalHotkeys.swift` — explicit-start Carbon registrar and recording/settings API.

Include all six in the macOS app target. Existing `A0Theme` / `Color(hex:)` support remains provided by `IslandStore.swift`; no changes to that owner are needed. No new resource bundles are necessary: accessories are vectors and 48 kHz stereo PCM16 sounds are synthesized/preloaded in memory. Optional WAV exports are for review or later packaging, not a runtime requirement. Never add standalone test sources to the application target (some have test-only declarations and executable entry points).

## Renderer and wardrobe

```swift
ZeroView(tint: contextColor,
         gaze: normalizedGaze,
         animated: true,
         happy: false,
         state: .thinking,
         emote: nil,
         outfit: wardrobe.resolved(),
         paused: false,
         waving: false,
         frameTime: nil)
```

The original `tint:gaze:animated:happy:` call sites remain valid. New parameters have defaults. Use `ZeroMotion.gaze(dx:dy:)` to convert cursor deltas (positive y downward) to bounded normalized input. `state` controls canonical A0 activity colors; idle uses the supplied context tint. Miniatures use the same renderer with smaller dimensions; details are bounded by render size.

- No internal animation schedule for `animated: false`, `paused: true`, or accessibility Reduce Motion.
- With normal animation, active states use 30 Hz and sleeping uses 10 Hz.
- An optional `frameTime` (seconds in Date's reference-date epoch) lets an owner drive rendering without a nested TimelineView. Keep `animated: true` with an external clock; pause still disables motion.
- Owners must forward hidden, screen-sleep and screen-lock state as `paused`; a standalone visual view does not install global observers.
- The renderer is decorative/accessibility-hidden. Label the containing interactive avatar and provide semantic actions (the desktop controller already does).

Create and retain `ZeroWardrobe(defaults:key:)`, default key `zeroOutfit`. Read `selected`, call `select(_:)`, and use `resolved(at:)` for automatic seasonal resolution. Unknown/deprecated persisted IDs migrate to `auto`. All specified outfit IDs are supported. The documented calendar uses Gregorian seasonal windows, including a fixed spring window rather than a computed religious holiday. Use `WardrobeView(wardrobe:onSelection:)` inside an integrator-owned popover/settings surface; attach the right-click action at the owning avatar hit target.

`ZeroInteraction` is an optional timer-free input adapter. Feed `hover(_:now:)`, `greet(now:)`, `slap(now:)`, `play(_:duration:now:)`, and `update(now:)` using system uptime. Bind `emote`, `waving`, and `dizzy` to renderer/presentation. `onCue` emits sound names. The owner decides when a compact click opens versus an expanded click slaps, and whether dizzy changes the island view. It does not receive gestures or mutate the store by itself.

## Desktop

Retain `DesktopZeroController(wardrobe:defaults:tint:callbacks:)`. Required callback `islandFrame` returns current global **AppKit** screen geometry. Call `start()` to restore a saved desktop preference; `show(at:)` installs at a global cursor point; `flyHome()` is an explicit user return and clears the desktop preference.

Forward real activity via `agentActivity(state:tint:happy:)`. Use stable unique alert IDs for `beginAlert(id:)` / `resolveAlert(id:)`; overlapping alerts are tracked independently. Alert retraction preserves the user's desktop preference and restores after all alerts resolve. It never sends agent messages.

Connect callbacks for returned-home/visibility, wardrobe, sound toggle, sound cues and interactions. `visibilityChanged` lets the integrator hide the island duplicate. The controller handles native drag, island drop, delayed slap/double-click discrimination, display bounds, idle sleep, suspension and accessibility/context-menu actions. `shutdown()` is terminal and should be called explicitly before releasing the controller.

Preferences: `desktopZeroX`, `desktopZeroY`, `zeroOnDesktop`. These are independent of connection, appearance and display preferences. App-window attachment is left to the owning island drag coordinator; the desktop module does not inspect or control another application's windows.

See [desktop-zero-controller.md](desktop-zero-controller.md) for complete callbacks, timing and limitations.

## Audio

Retain one `try NotchSoundPlayer()` (main actor). Construction preloads original generated sounds, and can throw if audio initialization fails; keep the companion usable when it does. `play(_:)` accepts one `NotchSound` or an array for layered effects. The default volume is 0.12; `setVolume(_:)` clamps to 0...0.2. Use `setMuted(_:)` / `toggleMute()`, and `shutdown()` on teardown. Connect `onPlaybackFailure` to bounded diagnostic feedback, not an agent loop failure.

Map renderer interaction cue names with `NotchSound(rawValue:)`. Desktop `.happy` is a supported sound; map typed cues explicitly. Do not play sounds for ticker-only updates or unrelated mini-context changes. Call `stopAll()` when the application suspends if appropriate. `NotchSoundSynthesis.writeWAVs(to:)` supports reproducible review export without external assets and refuses overwriting existing WAVs.

## Global shortcuts

The module is **opt-in and unwired**. Construction does not register system-wide keys. Local shortcut handling remains the integrator's responsibility and must preserve native editing/IME behavior. Where current product policy keeps shortcuts local, leave this module unstarted; its presence does not change policy.

Retain `GlobalHotkeys()`, set `onAction` and `onChange`, then explicitly call `start()` only when approved. Call `stop()` or `shutdown()` to unregister. Use `binding(for:)`, `status(for:)`, `setEnabled(_:for:)`, `setShortcut(_:for:)`, `resetAll()`, `retryRegistration()` to build settings. Recording is explicit through `beginRecording(for:)`, `record(keyCode:modifiers:)`, `cancelRecording()` and `onRecordingResult`. It uses a local foreground event monitor, not global keystroke capture.

Defaults are Command-Shift-N disabled; Control-Option Space/A/U/W/right bracket/left bracket/M/D/G enabled. Show internal conflicts distinctly from Carbon/system registration conflicts; never silently steal a binding. Callback actions must flow through normal application authorization, connection freshness and confirmation checks. A hotkey must not bypass mutation safety.

See [sound-hotkey-modules.md](sound-hotkey-modules.md) for exact signatures, statuses and preference keys.

## Validation boundaries

Independent runners use disposable compiler caches/build output and do not build or launch the shared application:

```sh
./scripts/test-zero-integration.sh
./scripts/test-sound-hotkey-modules.sh
./scripts/test-desktop-zero-controller.sh --panel
```

Native sound/hotkey checks compile Swift 6 with complete concurrency checking and verify original WAV layout/decoding, deterministic output, bounded playback via fakes, persistence and registration/recording state via fakes. Default runs do not audibly play sounds or register global shortcuts. Optional real-device smoke flags require deliberate invocation.

Desktop standalone checks include contract stubs and do not alone prove production renderer compatibility. Consult the separate real-character test runner/report when present. Whole-app build, all presentation integration, real interaction/VoiceOver/cross-app click-through, physical display reconnection, actual global key delivery, listening review, exact reference comparison and CPU/RAM budgets remain final integration gates.
