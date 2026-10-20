# Connected companion design contract

## Current scope
The user requests a working native read/write companion, not a demo. This supersedes the historical M0/M5 demo, metadata-only, five-root and explicit-ID restrictions. Preserve canonical branding, original Zero, bundled fonts, three layouts and user settings.

## Ownership
- `IslandPresentation` and `IslandGeometry`: persisted appearance values, dimensions, offsets, circular paths and exact hit tests; presentation is independent of display choice.
- `IslandStore`: connection generations, freshness, selected chat, current content, pending explicit operations and user feedback.
- `LiveHTTPClient`: app-owned ephemeral session, login/CSRF, same-origin bounded requests and existing WebUI chat APIs; no browser-session fallback.
- `ConnectionSettings`: clear server/account form, secure password entry and opt-in origin/username Keychain behavior.
- Plugin: automatically discover the authenticated WebUI's eligible chat contexts, preserve distinct child contexts and actual relationships, bounded nonblocking lifecycle telemetry. The small exact-target adapter reuses normal framework message/control semantics; no separate command queue.
- `ZeroView` and Branding resources: preserve existing character and identity; no unlicensed Space Agent substitution.

## Required behavior
Selecting/searching chats never sends input. Mutations require explicit actions and a live fresh session; operations retain their original context identity despite selection changes. No silent send retry after an ambiguous network outcome. Stop/destructive operations require confirmation. Disconnection/staleness/errors are visible and honest.

No production seeds, demo playback, debug fake-state menus, allowlist entry or arbitrary chat-count cap. Test fixtures are isolated from production and use synthetic credentials/data.

## Verification
Run Python tests in the Agent Zero framework interpreter. Run native Swift tests and both SwiftPM/Xcode packaging paths on the connected Mac. Verify resources, signatures, source Info.plist immutability and isolated LaunchServices checks for all three appearances. Exercise actual native settings and live integration separately using only disposable test chats for mutations. Never infer native integration from fixture tests.

Reviewed sources may be delivered to the private repository with maintainer authorization. Public visibility and release completion remain gated on the unresolved acceptance checks. Public export excludes `.a0proj`, build/research data, logs, caches and private runtime material. Record substantive gaps, not milestone-completion claims unsupported by evidence.
