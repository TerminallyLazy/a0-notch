# Native macOS companion

The connected revision replaces the historical demo/read-only foundation. The app starts disconnected, owns its authenticated WebUI session, automatically discovers eligible chats and offers explicit operations on the selected chat. Canonical assets and Rubik/Roboto Mono remain bundled; Zero remains the original Canvas character, not a Space Agent replacement.

## Build and verify

Requires macOS 14+, Swift 6/Xcode; no third-party Swift package dependencies. Run in the project root on a Mac:

```sh
./scripts/test-display-choice.sh
./scripts/package-app.sh debug
./scripts/build-xcode.sh
./scripts/test-packaging.sh
```

SwiftPM output: `build/A0Notch.app`. Xcode output: `build/DerivedData/Build/Products/Debug/A0Notch.app`. The packager uses ad-hoc signing for local development, not notarized distribution. XcodeGen is optional for ordinary SwiftPM packaging; the dual-path regression requires it already installed.

Both paths consume hand-maintained `app/Info.plist`. Use `INFOPLIST_FILE`, never XcodeGen `info.path`, and keep generated-plist mode disabled. Resource checks verify fonts, identity images, notices, hashes and icon; LaunchServices checks require the app's explicit pass marker, not only a zero `open` exit. Smoke processes are uniquely tagged and terminated without stopping an existing user app.

HTTP tests start disposable loopback servers with synthetic credentials. They do not read Keychain, borrow browser sessions, or establish native live integration. Framework Python checks run separately with the Agent Zero framework interpreter. See [current evidence](../docs/verification.md).

## Ownership

- `NotchCore`: deterministic display/geometry/policy, validated wire DTOs, freshness/generation logic, isolated URLSession client and normal chat API operations.
- `IslandStore`: main-actor UI state, selected identity, polling, explicit operations and feedback; never silently retry ambiguous sends.
- `IslandWindowController`: nonactivating borderless host, display/notch geometry, click-through and pointer lifecycle. Text entry may deliberately receive focus; ordinary hover must not steal it.
- `IslandView`: real activity and searchable chat interaction in three layouts.
- `ConnectionSettings`: labeled server/account fields, secure entry, progress/errors, captured-account Keychain controls, persisted behavior settings and explicit SMAppService login-item registration (OS acceptance unverified).
- `A0Brand`: self-contained resources and process-local font registration.
- `ZeroView`: retained character; prototype-perfect fidelity is unverified.
- `A0NotchApp`: menu/settings lifecycle and isolated structural smoke checks, without demo playback/fake-state menus.

## Appearances

Appearance and Display are independently persisted. Notch, Floating Capsule and Slim Bar expand to 640, 560 and 440 points respectively. Attached content clears measured hardware-notch height; detached styles sit below the menu bar. Shared geometry drives rendering and mouse interception. Invalid preferences fall back safely without erasing saved disconnected-display choices.

## Manual acceptance

Verify settings are readable and unclipped, password storage remains opt-in, stale/disconnected controls cannot mutate chats, search scales, selection never sends, explicit sends retain their target across selection changes, Stop requires confirmation, and entry focus/Escape work without stealing unrelated input. Use a disposable chat for writes. Check transparent-margin click-through, all three layouts, Reduce Motion, Spaces/fullscreen, hardware notch, multiple displays and screen sleep separately.

The missing `reference/a0-notch.html` prevents reference-perfect character/motion claims. File upload, wardrobe, desktop avatar, sound assets, global hotkeys, complete view/emote choreography and measured CPU/RAM budgets are not established by this connected upgrade. Do not represent this as all original milestones complete.

## 0.6.1 interaction changes

The app no longer automatically selects and downloads the first existing chat on connection. Choose one deliberately; deletion of the selected chat clears selection/content rather than choosing another. Submitted password fields and the save choice are cleared immediately after credentials are captured for Connect or Test. Selection changes dismiss an outstanding Stop confirmation; draft bindings are tied to the displayed chat ID. A newly created chat auto-selects only if selection has not changed while the request was in flight.

App-local shortcuts: Command-N opens Chats from the menu, Command-Shift-N creates a new chat while the chat workspace is active, Command-Return sends the composer, and Command-comma opens settings through the app menu. These are not global Carbon shortcuts and require hardware/UI acceptance. No global shortcuts are installed.

Behavior settings persist auto-close (15–300 seconds), mouse absence (1–30 minutes), and selected-chat event opening. Actual error events hold the island open until dismissal, including while absent; completion opens for 5.2 seconds, with interaction returning to ordinary timeout. Events never switch the selected chat. This is not a FIFO intervention/question workflow.

Launch at login uses explicit SMAppService register/unregister controls and displays approval/error states. It is not enabled by packaging or launch. Installation location, signing and macOS approval still determine whether it works; this revision has not changed the user's login items.
