# a0_notch

A native macOS companion for [Agent Zero](https://github.com/agent0ai/agent-zero). Keep Zero at the top of your display, see real chat activity, and deliberately send messages or control the selected chat without living in a browser tab.

**Community project, not an official Agent Zero release.** This is a development preview. See [verification and release gates](docs/verification.md) before relying on a build; local ad-hoc signing is not notarized distribution.

## Connected companion

- Three appearances: **Notch**, **Floating Capsule**, and **Slim Bar**, with independent display selection.
- Automatic discovery of eligible chats visible to the authenticated WebUI session—no context-ID entry or five-chat product cap. Separately created subordinate chats remain separate; in-chat agents appear as activity.
- Searchable chat selection, actual recent activity, and explicit chat actions. Selecting a chat never sends a message.
- Metadata-only FIFO alerts and completion presentation without automatic chat selection, configurable absence/close timers, and explicit launch-at-login controls (OS acceptance still requires validation).
- Honest disconnected/stale states; mutations require a fresh authenticated connection.
- App-owned WebUI login and CSRF session; optional account-and-origin-scoped Keychain password storage. No browser cookies, anonymous fallback, or separate public relay port.
- Original Zero character, 13 outfits, desktop drag/return and alert retraction, 28 synthesized sounds, Carbon global shortcuts with recorder/conflict settings, and editing-safe local commands.
- Explicit selected-chat file staging/upload/cancellation, indeterminate progress and authoritative receipts; bounded diff metadata, not fabricated full diffs.
- Explicit per-chat **Model preset** selector using A0’s existing override API; no global model-setting mutation.
- Consent-first Apple dictation, on-device by default, bounded recording and explicit draft insertion; never auto-send.
- Event-driven island wake policy, persistent avatar transitions and real drag ghost.
- Origin/account-scoped main/pin/alias/color preferences never restrict all-chat discovery.
- Agent Zero identity assets, Rubik, Roboto Mono, and the dark A0 palette.

Production demo playback and fake-context menus are removed. Synthetic data lives only in tests.

## Requirements

- macOS 14 or later, Swift 6/Xcode, and a logged-in graphical session for launch checks.
- An Agent Zero deployment with WebUI username/password authentication enabled and the compatible `a0_notch` plugin installed.
- HTTPS for remote servers. Plain HTTP is limited to loopback. Discover your deployment's actual published port; do not assume the examples' port.
- No third-party runtime Swift packages or new Python dependencies are required. XcodeGen is optional for the SwiftPM path and required for the separate Xcode path.

## Build the Mac app

From the checkout root on the Mac:

```sh
./scripts/test-display-choice.sh
./scripts/package-app.sh release
open -g build/A0Notch.app
```

Optional Xcode build:

```sh
./scripts/build-xcode.sh
```

The Xcode output is `build/DerivedData/Build/Products/Debug/A0Notch.app`. Both paths bundle fonts, identity assets, their notices, and a concrete `Info.plist`. Neither installs dependencies or enables launch at login. See [native development](app/README.md).

## Install the companion plugin

```sh
./scripts/package-plugin.sh
```

Install `build/a0_notch-plugin.zip` with Agent Zero's normal plugin ZIP installer and enable **Agent Zero Notch**. The archive contains a standalone plugin root; the monorepo itself is not a standalone Plugin Index package. Do not point the Git plugin installer at this monorepo root.

For an existing installation, preserve plugin configuration/activation and use the runtime's supported update workflow. Older ZIP installations may require an explicit backed-up replacement plan; do not manually overwrite loaded code or restart active chats. The native app and plugin should be upgraded together. Old allowlist/name-sharing keys no longer restrict discovery in the connected revision. See [integration](docs/plugin-integration.md).

## Connect

1. Open the menu-bar icon → **Settings → Connection**.
2. Enter the actual server origin and WebUI account. A browser login is intentionally not shared.
3. Leave password saving off unless you want the app to retain it in Keychain.
4. Test or connect, then choose a chat. A successful connection with no eligible chats is an empty account/registry, not fabricated activity.
5. Use the visible composer or chat controls deliberately. Check the selected chat name before sending. A timed-out write may have reached the server: inspect the chat before resending.

Disconnect stops polling. Quit does not pause or terminate Agent Zero work. Disable/uninstall the plugin through Agent Zero's plugin manager to remove the integration; it owns no daemon or extra listening port.

## Verification

```sh
# In an Agent Zero framework checkout/container, using its framework interpreter:
PYTHONPATH=/a0 /opt/venv-a0/bin/python -m pytest tests -q
# On the Mac:
./scripts/test-display-choice.sh
./scripts/test-packaging.sh
```

HTTP fixtures use synthetic credentials and disposable loopback servers. They do **not** prove a live native login, Keychain integration, real lifecycle hooks, visual fidelity, or performance. Live write checks must use a dedicated disposable chat, never an existing user's work. [Current evidence](docs/verification.md) separates these gates.

## Security, licensing, and contribution

Read [SECURITY.md](SECURITY.md) before deploying and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for asset provenance. Project code is offered under [MIT](LICENSE); third-party notices remain applicable. Agent Zero marks do not imply endorsement or trademark ownership. No Space Agent artwork is shipped.

A safe source archive can be prepared with `./scripts/export-source.sh`. It uses the reviewed file-level `scripts/public-source-files.txt` manifest and refuses unexpected files in owned source trees. Adding files requires deliberate manifest review; exporting is not a security audit. Never publish `.a0proj`, build/research directories, logs, credentials, or runtime chats. Review the archive and run the release gates before publishing.
