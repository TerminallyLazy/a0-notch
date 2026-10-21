> Integration update (0.7.0): these modules are now wired by `AppDelegate`, `IslandStore`, `ProductViews`, `ProductSettings` and `AppCommands`. The standalone-scope statements below describe the original lane handoff, not current app wiring. See [current acceptance](verification.md).

# Standalone sound and global-hotkey modules

## Scope and ownership

New independent sources only:

- `app/Sources/A0Notch/NotchSoundPlayer.swift`
- `app/Sources/A0Notch/GlobalHotkeys.swift`
- `app/Tests/SoundHotkeyStandalone/SoundHotkeyModuleChecks.swift`
- `scripts/test-sound-hotkey-modules.sh`

No application/store wiring, Zero/wardrobe/desktop changes, manifests, bundled binaries,
dependencies, deployment, or shared builds are included. Creating `GlobalHotkeys` does
not register shortcuts; the owner must explicitly call `start()`. This module implements
the requested global Carbon behavior without changing existing app-local shortcuts.

## Audio APIs

`NotchSound: String, CaseIterable, Codable, Sendable` has all 28 cases:
`peek greet open close hover blip slap annoyed dizzy work think search attention question
error finish approve gulp tick send attach love pop proud wink yawn sleep happy`.

`NotchSoundSynthesis` is independent of actor/audio state:

```swift
static let sampleRate: Int // 48_000
static let channels: Int // 2
static let bitsPerSample: Int // 16
static let recipeVersion: Int // 1
static func duration(of sound: NotchSound) -> TimeInterval
static func wavData(for sound: NotchSound) -> Data
static func writeWAVs(to directory: URL) throws
```

Recipes are original sine/harmonic/chirp cues with a fixed-seed noise generator,
per-note envelopes and subtle stereo panning. Output is RIFF/WAVE PCM16 little-endian,
48 kHz stereo, no external recordings or random/time inputs. Repeated calls on the same
platform produce identical bytes; cross-architecture floating-point math is not promised
bit-for-bit identical. Export writes `<sound>.wav` and refuses to overwrite existing files.
An export can leave earlier successfully written files if a later write fails.
Normal playback uses in-memory WAV data, so packaging needs no additional resources.

`@MainActor public final class NotchSoundPlayer`:

```swift
init(defaults: UserDefaults = .standard,
     keyPrefix: String = "a0_notch.sound",
     maximumConcurrentVoices: Int = 8,
     voicesPerSound: Int = 2,
     voiceFactory: VoiceFactory = { try AVAudioPlayer(data: $0) }) throws

// VoiceFactory = @MainActor (Data) throws -> any NotchSoundVoice
func play(_ sound: NotchSound) -> PlaybackResult
func play(_ sounds: [NotchSound]) -> [PlaybackResult]
func setMuted(_ muted: Bool)
func toggleMute()
func setVolume(_ value: Double)
func stopAll()
func shutdown()
```

Read-only state: `isMuted`, `volume`, `maximumConcurrentVoices`, `voicesPerSound`,
`activeVoiceCount`, `preloadedVoiceCount`. Callback: `onPlaybackFailure: ((NotchSound) -> Void)?`.
`PlaybackResult` is `.played`, `.muted`, or `.unavailable`.
`LoadError.preparationFailed(NotchSound)` identifies failed preloading; AVFoundation
construction errors also propagate. The owner may catch these and keep the app silent.

Default volume is **0.12**, persisted volume clamped to **0...0.2**; nonfinite inputs use
0.12. Mute is persisted separately. Keys are `<prefix>.muted` and `<prefix>.volume`.
Mute and zero volume stop existing voices immediately. No sound starts automatically.
All 28 cues are synthesized and prepared at construction, with 2 players per sound by
default. Per-sound voices clamp to 1...4; global concurrently playing voices clamp to
1...16. Saturation replaces the oldest relevant voice instead of queueing. `play` creates
no new AVAudioPlayer or WAV data. Call initialization once at startup, not per frame.
`shutdown` stops playback and releases all pooled players; subsequent audible calls return
`.unavailable`. Releasing the owner also releases its players.

`NotchSoundVoice` is a public main-actor protocol for silent tests. It exposes
`isPlaying`, writable `volume`/`currentTime`, and `prepareToPlay()`, `play()`, `pause()`, `stop()`.
The default implementation is `AVAudioPlayer`.

Example integration (retain `sounds` for the lifetime of the app):

```swift
let sounds = try NotchSoundPlayer()
sounds.play([.peek, .greet])
sounds.play(.attention)
sounds.setMuted(true)
// At termination:
sounds.shutdown()
```

## Hotkey APIs

All controller and registrar operations/callbacks are main-actor isolated.
`NotchHotkeyAction` cases: `toggleIsland`, `openPrompt`, `goToAlert`, `openWebUI`,
`attachWindow`, `nextContext`, `previousContext`, `mute`, `desktopZero`, `wardrobe`.

| Action | Default | Enabled |
| --- | --- | --- |
| toggleIsland | Command Shift N | no |
| openPrompt | Control Option Space | yes |
| goToAlert | Control Option A | yes |
| openWebUI | Control Option U | yes |
| attachWindow | Control Option W | yes |
| nextContext / previousContext | Control Option ] / [ | yes |
| mute | Control Option M | yes |
| desktopZero | Control Option D | yes |
| wardrobe | Control Option G | yes |

`NotchHotkeyModifiers` is a Codable/Hashable/Sendable OptionSet with `.command`,
`.option`, `.control`, `.shift`, `.supported`, `init(rawValue:)`, `init(eventFlags:)`,
and `carbonFlags`.
`NotchHotkeyChord(keyCode:modifiers:)` exposes `keyCode`, `modifiers`, `isValid`,
and `displayName`. Physical virtual keycodes are persisted; bracket defaults use ANSI
positions, not layout-dependent characters. Unknown display labels show `Key N`.
Validation rejects modifier-only keys, codes >=128, unsupported modifier bits, and chords
without Command/Control/Option. Keycode validation is structural, not a keyboard inventory.

`NotchHotkeyBinding(action:chord:isEnabled:)` is Codable/Equatable/Sendable and exposes
`defaults`. `GlobalHotkeys` owns the persisted bindings:

```swift
init(defaults: UserDefaults = .standard,
     storageKey: String = "a0_notch.hotkeys.v1",
     registrar: (any NotchHotkeyRegistering)? = nil)
func binding(for action: NotchHotkeyAction) -> NotchHotkeyBinding
func status(for action: NotchHotkeyAction) -> NotchHotkeyStatus
func start()
func stop()
func setEnabled(_ enabled: Bool, for action: NotchHotkeyAction)
func setShortcut(_ chord: NotchHotkeyChord, for action: NotchHotkeyAction) -> Bool
func resetAll()
func retryRegistration()
func beginRecording(for action: NotchHotkeyAction)
func record(keyCode: UInt32, modifiers: NotchHotkeyModifiers) -> Bool
func cancelRecording()
func shutdown()
```

Read-only state: `bindings`, `statuses`, `isRunning`, `recordingAction`.
Callbacks: `onAction: ((NotchHotkeyAction) -> Void)?`, `onChange: (() -> Void)?`,
`onRecordingResult: ((RecordingResult) -> Void)?`.
Callbacks should update presentation or dispatch commands, not recursively mutate the
controller in response to `onChange`. Use weak captures where the owner retains the module.

`RecordingResult` cases:
- `.saved(NotchHotkeyAction, NotchHotkeyChord, NotchHotkeyStatus)`
- `.rejected(NotchHotkeyAction, String)`
- `.cancelled(NotchHotkeyAction)`

`NotchHotkeyStatus` cases:
- `.disabled`, `.stopped`, `.recording`, `.registered`, `.invalidShortcut`
- `.internalConflict([NotchHotkeyAction])`: show red; neither enabled duplicate registers.
- `.systemConflict(Int32)`: show orange; Carbon returned `eventHotKeyExistsErr`.
- `.registrationFailed(Int32)`: another actual OS error, not falsely labeled a conflict.

OS conflicts are detected when enabled keys are registered, not exhaustively predicted.
Some macOS-reserved keys may not produce `eventHotKeyExistsErr`; `.registered` means
Carbon accepted the registration, not that every OS mode will deliver the shortcut.
Disabled bindings retain preferences without owning keys. Invalid replacement chords are
rejected without changing preferences. JSON load merges valid records over defaults;
corrupt JSON falls back to defaults. `resetAll()` resets shortcuts/enablement only.

Recording uses an AppKit **local** key-down monitor while the owner is recording.
It suspends this controller's global registrations, consumes captured keys, ignores
repeats, cancels on Escape or app deactivation, and restores registrations on exit.
It does not activate the app; the owner should start it from a focused Settings recorder
and call `cancelRecording()` when that UI closes. Invalid input leaves recording active.
Valid conflicts are saved and reported so Settings can show the actual chosen shortcut.
The `record` method supports custom recorder UI and deterministic testing.

`NotchHotkeyRegistering` is an injectable main-actor interface with `onAction`,
`register(_:) -> Int32`, `unregisterAll()`, `shutdown()`.
`CarbonNotchHotkeyRegistrar()` is the production implementation, using
`RegisterEventHotKey`, `InstallEventHandler`, `UnregisterEventHotKey` and
`RemoveEventHandler`; no Accessibility permission or global keyboard interception.
Identifiers are unique across registrar instances in-process. The callback accepts only
this module's signature and registered IDs. Own one registrar per controller.

`stop()` releases keys and allows `start()` to resume. `shutdown()` is final teardown,
clearing callbacks and recorder resources. Deinitialization schedules fallback cleanup
on the main actor; call `shutdown()` explicitly before ending the application event loop
for deterministic immediate release. No actions run during registration/initialization.

```swift
let hotkeys = GlobalHotkeys()
hotkeys.onAction = { action in
    // Route to app-owned commands; no store is imported by the module.
    if action == .mute { sounds.toggleMute() }
}
hotkeys.onChange = { /* update Settings from bindings/statuses */ }
hotkeys.start()
// At termination:
hotkeys.shutdown()
```

## Independent verification

```sh
./scripts/test-sound-hotkey-modules.sh
# Optional, logged-in macOS session; temporarily registers a rare F18 chord:
./scripts/test-sound-hotkey-modules.sh --carbon-smoke
# Optional, deliberately audible greeting:
./scripts/test-sound-hotkey-modules.sh --audio-smoke
# Optional, explicit new export location (never overwrites):
./scripts/test-sound-hotkey-modules.sh --export-wavs /tmp/a0-original-sounds
```

The runner compiles only these two modules and the standalone test entrypoint using
Swift 6 strict concurrency. The executable and compiler caches live in an automatically
removed `mktemp` directory, never `.build`, `build`, Xcode DerivedData or SwiftPM outputs.
No manifest changes are needed. Preference tests use a unique suite and remove it.
Unsupported hosts or missing Swift return **77 (SKIP)** rather than false success.

The harness covers all sound names, repeatable/distinct WAVs, headers, sample counts,
non-silent/unclipped stereo payloads, silent endpoints, AVFoundation decoding, export
protection, fake voice layering/stealing/preload, mute/volume/persistence, playback and
preload failures, shortcut defaults, fake registrar callbacks, duplicate and OS-error
classification, recording validation/cancel/deactivation, persistence/corruption, reset,
stop/restart, and shutdown. Optional Carbon smoke checks actual registration, duplicate
conflict, and release; it does not simulate physical keyboard delivery.

### Native validation results

The connected Mac checkout matched the container source and runner SHA-256 hashes.
The default isolated script passed on Apple Silicon with Apple Swift 6.4, Swift 6
language mode, complete strict concurrency, and macOS 14 deployment target. Final
exit status: 0, with no compiler warnings or errors. All WAV synthesis, decoder, export,
fake audio lifecycle, and fake-registrar hotkey checks passed.

Native fixes: Carbon buffer size uses Int; the recorder returns Bool rather than
non-Sendable NSEvent across assumeIsolated; the main-actor registrar protocol explicitly
conforms to Sendable for deferred cleanup. The test helper uses #file to avoid a warning.

No audio-smoke or carbon-smoke flags were used. Audible playback, actual global key
registration and physical delivery, real recorder keystrokes, UI integration, and CPU/RAM
remain unverified. WAV decoding used AVFoundation; playback and registration used fakes.
No shared build, dependencies, deployment, or app integration was performed.
