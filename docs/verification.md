# 0.8.0 development-preview verification

The app and plugin are version **0.8.0**, protocol schema **2**. This is a private development preview, not complete M0–M9 acceptance or notarized distribution. The original HTML prototype is unavailable, so exact visual/motion fidelity cannot be established. Production fake-context/demo playback is intentionally absent under the revised product contract.

## Implemented and integrated

- Authenticated, paginated all-chat discovery; explicit selection; incarnation, connection-generation and selection-revision guards. Pins/aliases/colors are scoped presentation preferences, not authorization or discovery filters.
- Selected recent activity without changing core localization/timezone or downloading unbounded history. Explicit send, pause, resume, stop and create use ordinary Agent Zero semantics. No automatic mutation retry.
- FIFO metadata alerts and timed completion presentation without silently selecting or fetching other chats. Paused is not a fabricated question; upstream structured question/intervention options are not invented.
- Native staged attachments with bounded off-main regular-file reads, aggregate budgets, captured target, cancellation and authoritative opaque receipts. Multipart actual bytes are capped; hook-substituted attachment paths fail closed. Progress is indeterminate, not fabricated. Diff display is masked path/+− metadata, not a full diff.
- Operation UUID ownership prevents late cancelled operations from clearing a newer task, status or busy state. Serialization overflow does not reset telemetry; pagination arithmetic avoids integer overflow.
- Explicit per-chat **Model preset** selection through the existing core override API. Presets can affect chat, utility and embedding models; no global model settings are changed.
- Consent-first Apple dictation in both composers, on-device by default, bounded recording, explicit draft insertion and no auto-send. Both signing paths include the audio-input entitlement. Tests never start real microphone capture or request permission.
- Original Zero engine, wardrobe, sounds, desktop handoff, scoped shortcut recording, and settings are integrated. Keychain read/write/delete failures are surfaced separately from WebUI authentication failure. Unchanged decoded preferences are not rewritten because JSON key order changed.
- Persistent avatar nodes, native drag ghost/file tray, shared geometry and event-driven island wake policy replace permanent 60 Hz island polling. Bounded transitions still animate; desktop and live network activity have separate costs.

## Verified automated evidence

Completed 0.8.0 logs were inspected against source chronology; unchanged components were not needlessly rerun. These are saved checks, not a cryptographic attestation of their historical inputs.

| Check | Result |
| --- | --- |
| Full Python suite in Agent Zero framework interpreter | **244 passed** |
| Full SwiftPM core suite | **242 tests, zero failures** |
| Xcode test suite | **TEST SUCCEEDED** |
| Real Store integration | Passed discovery/selection/send/upload, cross-chat isolation, replacement, cancellation ownership and disconnect; rerun after the final Store/Keychain changes |
| New preference regression | Failed first on unnecessary rewrite; passed after semantic persistence comparison |
| Keychain status classification | Synthetic read/write failure codes tested without accessing actual credentials |
| Dictation | Consent, denial, privacy mode, stale callbacks, cancellation, deadlines and scoped settings passed with injected drivers; real adapter compiled only |
| Model presets | Backend list/set/clear tests and integrated native fixture selection passed |
| Zero renderer | Saved real six-module run: **12,200 checks**, including rendered states/outfits/emotes |
| Motion/native driver | Focus eligibility, drag threshold/ghost/return, desktop handoff, nested suspension and renderer lifecycle checks passed |
| Sound/hotkeys | Saved standalone suite passed |
| Desktop standalone | Latest standalone run: **35 checks**; renderer stubs there are not rendering evidence |
| Packaging | Saved both-build-order regression and four Launch Services launches passed |
| Final native builds | SwiftPM release and Xcode debug rebuilt successfully after final Store/Keychain changes |
| Final launch matrix | Both final products × Notch/Capsule/Slim: **six passes**, bundle/resource/signature and layout smoke checks |

The SDK emits an audio-tap API deprecation warning on macOS 27; the adapter targets macOS 14 compatibility. Compilation does not prove real speech service or microphone behavior.

## Live plugin deployment

The running plugin was upgraded to **0.8.0/schema 2** through supported plugin-manager uninstall/ZIP-install lifecycle APIs, with private rollback backup and **no service restart, core edits or dependency installation**. Configuration bytes and activation were preserved. All **28 packaged plugin files** matched installed source.

A dedicated disposable chat verified authenticated paginated discovery, incarnation-bound selected content, model preset list/set/current/clear, pause/resume/stop, real multipart delivery, ordinary message logging, opaque receipt and 0600 uploaded-file permissions. Real thinking/tool-start/tool-end/finished events were observed. Recreating the same disposable ID changed incarnation; old-token send/pause/resume/stop/snapshot/upload and model list/set/clear all returned 409. Content/write routes rejected anonymous and missing-CSRF requests. Test chat, uploaded bytes, temporary event lease and automation session file were removed. Existing user chats were not deliberately acted upon.

These are real server API checks, separate from native authenticated end-to-end acceptance.

## Native UI observations

Authorized Computer Use visually confirmed the final app's expanded idle island, Zero, branding, disconnected state, opening the real chat window from **Open chats**, and opening connection settings. The settings showed an unchecked save-password option. No speech capture, login-item enrollment or credential saving was attempted.

Targeted Accessibility lookup returned `WINDOW_NOT_FOUND`; bounded screenshot/coordinate interaction succeeded instead. An initial click before pointer entry did not establish delivery; subsequent pointer entry and click opened the chat window. This is limited UI evidence, not universal click-through/focus or Accessibility acceptance.

Native authenticated login remains unverified. The inspected Docker host publication was wildcard-bound rather than exclusively loopback-bound. Deployment networking was not changed, and no native credential-entry test was performed through that endpoint. Use an explicitly secured loopback tunnel/binding or HTTPS for the remaining authenticated UI acceptance.

## Measured performance, not guarantees

Saved optimized native harness measurement on an arm64 Mac, macOS 27.0.1, notch-less display: three-second warmup and twelve one-second samples per mode, actual NSApplication event loop, stationary pointer, no network/sounds/hotkeys.

| Mode | Mean CPU (100% = one core) | Peak sampled RSS | Island controller timer wakes |
| --- | ---: | ---: | ---: |
| Hidden/disconnected | 0.0222% | 48.81 MiB | 0 |
| Compact/model-seeded | 2.6472% | 51.36 MiB | 0 |

Includes sampling overhead, excludes WindowServer/GPU, and is not physical footprint. Earlier valid compact samples were above 3%. No literal zero-CPU claim or live four-busy-context/full-app budget acceptance follows from this harness. Final preference-write changes were functionally tested but this performance sample was not repeated.

## Remaining release gates and limitations

1. Native authenticated end-to-end login, selection, send/upload/model workflows against a secured host endpoint; real optional Keychain behavior and launch-at-login OS approval.
2. Physical Finder drop, rapid cross-app click-through, multiple displays/reconnection, actual lock/unlock, shortcut delivery, audible review and accessibility acceptance.
3. Explicitly opted-in real microphone/speech acceptance; no automated permission or capture test was performed.
4. Representative connected/full-app CPU, memory/physical-footprint and long-running workload measurement; exact reference comparison requires the missing prototype.
5. Catalog acceptance has a 30-second deadline checked before/after pages plus per-request timeouts, not a hard cancellation at exactly 30 seconds. An in-flight page can extend wall time. Aggregate/page budgets still bound accepted results.
6. Some provably local mutation failures are conservatively reported as uncertain (notably preset dispatch and validation races). This is a UX precision limitation, not an automatic replay path; inspect state before explicitly retrying.
7. Developer ID signing/notarization and distribution/install acceptance. Local packages are ad-hoc signed.

Keep GitHub **private** until feature completion and acceptance satisfy the user's publication condition. Source exports use the reviewed file-level manifest, excluding runtime state, logs, private research, credentials and project metadata. A private source delivery is not a public release or a claim that these gates passed.
