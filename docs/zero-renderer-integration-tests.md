# Real Zero renderer integration checks

## Scope

Run `bash scripts/test-zero-integration.sh` on the connected Mac. The runner compiles these six **real production sources together** with Swift 6 complete strict-concurrency checking, targeting macOS 14:

- ZeroView.swift
- ZeroCharacter.swift
- ZeroWardrobe.swift
- DesktopZeroController.swift
- NotchSoundPlayer.swift
- GlobalHotkeys.swift

No application build, manifest change, dependency install, audio playback, hotkey registration, external assets, or deployment is involved. The executable and module caches live in a unique temporary directory removed on exit. Unsupported hosts exit 77.

`app/Tests/ZeroIntegrationStandalone/ZeroPaletteSupport.swift` is the only app-support fixture: three A0Theme colors and Color(hex:), copied from their actual owner **IslandStore.swift**. There are no replacement Zero enums, ZeroView, wardrobe, motion, or interaction classes. `OriginalZeroShell.swift` is a frozen shell-only reference renderer, not a replacement for ZeroView. Do not add any standalone test source to the application target.

## Exact renderer handoff

The public initializer keeps its existing arguments and defaults, ending in:

```swift
paused: Bool = false,
waving: Bool = false,
frameTime: TimeInterval? = nil
```

The desktop owns an outer TimelineView with `minimumInterval: sleeping ? 0.1 : 1.0 / 30`, paused while hidden/suspended. Each frame passes:

```swift
ZeroView(tint: render.tint, gaze: render.gaze,
         animated: true, happy: render.happy,
         state: render.state, emote: render.emote,
         outfit: wardrobe.resolved(at: timeline.date),
         paused: render.paused,
         frameTime: timeline.date.timeIntervalSinceReferenceDate)
```

When frameTime is present and motion enabled, ZeroView directly renders that time without constructing its internal TimelineView. `animated: true` is essential: disabling it freezes breathing rather than merely disabling a scheduler. With no external clock, ZeroView retains its own 30 Hz active / 10 Hz sleeping schedule. Paused and Reduce Motion render statically. Epoch is Date's reference date, not system uptime; ZeroInteraction deliberately uses monotonic system uptime instead.

Requested intervals do not prove measured FPS or CPU budgets. Screen-lock/sleep state still belongs to the controller. Wardrobe selection stays in the injected ZeroWardrobe; the desktop resolves it at the same frame date.

## Fixes and regression evidence

Before production changes, the six-source native compile succeeded, but tests reproduced six failing assertions: non-finite smoothing, repeated love during continuous hover, its consequent incorrect re-entry count, content sound mapping, neutral surprise eyes, and neutral waiting eyes.

- ZeroMotion.smooth sanitizes invalid components to zero, clamps normalized coordinates, and treats invalid elapsed time as zero.
- ZeroInteraction keeps a love-triggered boolean latch. Only leaving clears it; repeated inside events do not replay love. `.content` emits `approve`, `.surprised` emits `pop`.
- Surprised eyes are small dots; waiting eyes are wider ellipses. Original shell path and materials remain unchanged.
- Desktop now passes the external frameTime with animation enabled; the older desktop-only fixture also declares waving/frameTime for compatibility.
- ZeroWardrobe required no production edits. All stable IDs, migrations, and seasonal boundaries passed against its real implementation.

## Coverage

The real suite checks:

- Exact 13 outfit IDs; restore/select persistence; invalid, missing, deprecated-like and non-string selections migrating to auto; explicit selections overriding seasons.
- 26 seasonal boundary dates, exact midnight transition, supplied-timezone edge, and automatic current-timezone resolution.
- Finite/normalized gaze and smoothing, invalid times, 12,001 blink samples over 60 seconds, deterministic blink output, finished/dizzy roll midpoints and duration boundaries.
- Love at 1.9 seconds, continuous-hover latch and leave/re-enter reset, greeting wave duration, slap/annoyed expiry, three-click 1.7-second boundary, 3.3-second dizzy duration, cue mapping.
- Actual SwiftUI ImageRenderer Canvas output for 32 primary frames: neutral plus every outfit, state and emote individually. These are not a Cartesian-product test of every possible combination.
- Eye-region pixel differences, external 100.0→100.1-second sleeping animation, and paused clock invariance.
- Original shell source equality (drawShell and shellPath), plus rendered exterior bands against the frozen original reference (750 opaque sample pixels on the tested Mac).

ImageRenderer's default display-space mode showed tiny differences even for repeated identical input. Tests use linear rendering and allow at most one 8-bit level per RGBA channel for raster quantization. The repeat-render control checks that bound. Meaningful-expression/animation checks require more than 100 changed channels **beyond** that tolerance, avoiding false passes from raster noise. The original shell source comparison remains exact.

The first successful real-suite run reported **12,200 checks, zero failures**, with zero repeat-render byte differences in linear mode. `scripts/test-desktop-zero-controller.sh --panel` remains a separate native lifecycle/accessibility check using clearly disclosed contract stubs; it must not be cited as real-renderer evidence.

Not validated here: whole-app integration, packaging, actual cross-app click-through/drag/drop, VoiceOver navigation, physical monitor reconnect, real lock/unlock notifications, CPU/RAM budgets, sound output, global key delivery, or prototype-perfect motion. Compilation includes the real sound/hotkey sources but this suite does not exercise their runtime behavior.
