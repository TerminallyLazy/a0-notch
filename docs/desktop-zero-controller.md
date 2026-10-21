> Integration update (0.7.0): these modules are now wired by `AppDelegate`, `IslandStore`, `ProductViews`, `ProductSettings` and `AppCommands`. The standalone-scope statements below describe the original lane handoff, not current app wiring. See [current acceptance](verification.md).

# Desktop Zero controller (independent module)

## Ownership and boundaries

`app/Sources/A0Notch/DesktopZeroController.swift` owns the 120 × 120 passive desktop panel, pointer interaction, geometry, desktop preference, alert retraction, and suspension lifecycle. It imports only AppKit, Observation, and SwiftUI. It does not reference IslandStore, a sound player, transport, global shortcuts, or a plugin.

No existing source, manifest, project file, or integration wiring is changed. The owner must retain the controller and call `shutdown()` before releasing it. Recreate it rather than restarting after shutdown. All APIs and callbacks run on the main actor; callback implementations should be short and use weak captures of owners to avoid retain cycles.

## Integration API

```swift
let desktop = DesktopZeroController(
    wardrobe: wardrobe,
    defaults: .standard,
    tint: .white,
    callbacks: .init(
        islandFrame: { /* actual visible island bounds in global AppKit coordinates */ nil },
        returnedHome: { reason in /* .user or .alert; restore island avatar */ },
        visibilityChanged: { visible in /* suppress island avatar while visible */ },
        wardrobeRequested: { /* present your wardrobe UI */ },
        soundToggleRequested: { /* toggle your sound preference */ },
        sound: { cue in /* map DesktopZeroController.SoundCue to your sound system */ },
        interaction: { interaction in /* optional telemetry/UI synchronization */ }
    )
)
desktop.start() // Restores zeroOnDesktop, otherwise remains hidden.
```

- `show(at: CGPoint? = nil)`: opt into desktop mode, optionally placing its center at a global screen point. Suitable for an island drag handoff. This controller creates its own panel; it does not adopt a ghost window or implement the island-side drag.
- `flyHome()`: explicit user return; clears `zeroOnDesktop`. Flies toward `islandFrame()` over 420 ms, then calls `returnedHome(.user)`. Missing geometry or Reduce Motion returns immediately.
- `agentActivity(state:tint:happy:)`: updates character inputs and resets the two-minute agent-idle clock. Feed ongoing activity pulses; this controller has no knowledge of live sessions. Finished implies happy but does not retract.
- `beginAlert(id:)` / `resolveAlert(id:)`: use stable unique IDs for interventions/errors. First alert shows surprise and starts a 450 ms grace period. Flight then begins; completion calls `returnedHome(.alert)`. The desired preference stays true. Duplicate IDs do not extend the deadline; the last resolution restores the desktop, including cancellation during a pending/in-progress flight. Explicit user return wins over automatic restoration.
- `shutdown()`: terminal, idempotent cleanup of timer, observers, pending gestures, rendering, panel, and callbacks. Preferences survive.
- Read-only properties: `isVisible`, `wantsDesktop`, `isSleeping`, `isSuspended`, `frame`, `framesPerSecond` (actual controller polling cadence).

Callbacks: `SoundCue` contains `pop`, `happy`, `slap`, `annoyed`, `yawn`, `sleep`; `Interaction` contains `dragBegan`, `dragEnded`, `slap`, `wardrobe`, `soundToggle`. Sound playback/muting is entirely the owner's responsibility.

## Behavior contracts

- Borderless nonactivating `.floating` NSPanel; neither key nor main; no shadow. No application activation or permission request.
- The body hit target is a centered circle of radius 28.8 points (24% of panel width). Transparent corners return nil from native hit testing, and cursor polling toggles `ignoresMouseEvents`. A captured drag continues receiving mouse events outside the body until release.
- Drag begins only beyond seven points of Euclidean movement. The initial pointer offset is retained. Drop with the cursor inside the supplied island frame returns home. Other drops stay on the desktop and persist position.
- Double-click returns home. Single-click slap waits for `NSEvent.doubleClickInterval`, so a double-click is not also a slap.
- Right-click menu and named accessibility actions provide Return to notch, Wardrobe, and Toggle sound. The primary accessibility press returns home. Accessibility action closures capture the controller weakly.
- Position keys `desktopZeroX` / `desktopZeroY` store the panel's lower-left origin in AppKit global coordinates. `zeroOnDesktop` stores desired placement, not transient visibility.
- Clamp the entire panel inside the closest display's `visibleFrame` expanded by 24 points. Restore and screen-change handling account for negative display coordinates, disconnected displays, and non-finite saved values.
- At least 120 seconds without agent activity **and** cursor distance greater than 150 points causes sleeping. Mouse interaction/approach or activity wakes it. Sampling is 30 Hz active, 10 Hz sleeping, and stopped while retracted/disabled/suspended.
- Screen sleep, system sleep, inactive session, and distributed screen-lock notifications are independent suspension reasons. Clearing one cannot override another. Render input `paused` is true and the panel is hidden during suspension. An alert whose deadline elapsed while locked is processed before desktop presentation on wake.
- Shutdown unregisters all observers and invalidates the weak-capture timer. The resource bag additionally removes observers/timer on deallocation; explicit shutdown is still required for deterministic native window teardown.

## Renderer contract and limitations

Uses the requested `ZeroView(tint:gaze:animated:happy:state:emote:outfit:paused:)` initializer and an injected `ZeroWardrobe.resolved(at:)`; no second wardrobe preference is introduced. The supplied state/emote/outfit enums and wardrobe type must be accessible to this public controller.

Desktop rendering now owns one external TimelineView: minimum interval 1/30 second active, 1/10 second sleeping, paused while hidden/suspended. It passes `animated: true`, `paused: render.paused`, and `frameTime: timeline.date.timeIntervalSinceReferenceDate` into the real ZeroView. A supplied frameTime selects ZeroView's direct Canvas path, so no nested internal schedule runs. Sleeping breathing and particles continue at the external clock cadence; paused/Reduce Motion rendering remains static. `waving: Bool = false` and `frameTime: TimeInterval? = nil` follow `paused` in the public initializer. Timeline intervals are requested scheduling cadences, not measured frame-rate/CPU guarantees. See [zero-renderer-integration-tests.md](zero-renderer-integration-tests.md) for real-module compile and ImageRenderer results.

Other manual/integration checks remain: rapid boundary crossing/click delivery to underlying apps, actual mouse drag/double-click/drop, physical multimonitor reconnect, real lock/unlock delivery, VoiceOver navigation, appearance/motion matching, and CPU/RAM profiling. Polling-based click-through can have up to one sampling interval of lag; native hit tests alone do not prove cross-application click delivery. Initial construction after an already-issued lock notification is not a lock-state query.

## Independent verification

```bash
bash scripts/test-desktop-zero-controller.sh
bash scripts/test-desktop-zero-controller.sh --panel
```

The script compiles only DesktopZeroController plus `app/Tests/DesktopZeroStandalone/DesktopZeroContractChecks.swift`, with Swift 6 complete concurrency checks, macOS 14 target, and private temporary module caches. It never runs SwiftPM/Xcode builds, modifies manifests, or installs dependencies. Temporary build products are removed on exit. Non-macOS hosts return exit 77 (skip).

**The test file defines explicit test-only ZeroView/ZeroWardrobe/enums. Do not include it in the application target.** Stub compilation proves AppKit/SwiftUI/API usage and the declared interface shape, not compatibility with the owner's final renderer or wardrobe implementation. The stub draws nothing. The optional `--panel` run creates a transient native panel and isolated temporary preference suite; it does not build or launch the shared application.

Verified on the connected Mac: standalone Swift 6 compile and 60 checks passed, including deterministic geometry/thresholds/idle boundaries/overlapping alerts and native panel properties, hit tests, accessibility callbacks, timer-driven alert delay/cancellation, persistence, synthetic screen sleep/wake notifications, and weak-reference teardown. Native checks exposed an accessibility-target retention bug; weak handlers fixed it and the same deallocation assertion passed afterward. That desktop-only run did not validate the production renderer. The subsequent independent real-module suite compiles all six modules and validates real ImageRenderer output; see [zero-renderer-integration-tests.md](zero-renderer-integration-tests.md). No production app build, deployment, or screenshot comparison was performed.
