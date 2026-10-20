# Security and privacy

## Trust boundary

The companion is an authenticated WebUI client. Access follows the deployment's WebUI account model; it does not add multi-tenant authorization to a single-account Agent Zero server. Eligible chat names and activity become visible on the Mac after connection. Use a trusted Mac and server. Keep Agent Zero updated and authentication enabled.

The plugin uses existing authenticated/CSRF-protected HTTP routes and exports bounded lifecycle metadata. It does not export prompts, tool arguments, or full transcripts. The native selected-chat view additionally reads recent content through ordinary Agent Zero APIs. This content can contain private information: screen sharing and screenshots can expose it. Do not attach private logs or transcripts to public issues.

## Credentials and requests

- A dedicated ephemeral URLSession owns the application's cookies. No browser-cookie import or anonymous fallback.
- Password saving is opt-in, scoped to normalized origin and username in Keychain. Preferences retain origin/username, not a plaintext password. Changing accounts must not reuse another origin's session.
- TLS is required except for loopback HTTP. Redirects are not followed with credentials. Origin validation rejects embedded credentials and ambiguous server URLs.
- CSRF remains enforced on normal APIs and plugin routes. No new bearer-token bypass or public socket/port.
- Responses and requests have size limits. Oversized snapshots fail visibly instead of silently hiding chats.
- Errors shown to users are bounded; credentials, session cookies, CSRF tokens, chat contents, and raw server errors must not be logged.

## Explicit actions

Chat selection/search is read-only. Creation uses the existing Agent Zero API. Send/intervene, pause/resume and stop use a plugin-owned exact-target adapter with the same session/CSRF protections and normal framework message/control semantics. It checks effective scope and object identity again after message preprocessing and dispatches under the existing registry lock; it never creates missing targets. A fresh connection and exact selected identity are required. Stop requires confirmation. The app does not silently retry writes after ambiguous failures; server acceptance is not task completion.

Telemetry capture uses a bounded nonblocking ring. A slow or absent app must not block the agent loop. No plugin-owned background daemon, durable message backlog, or dependency installation is needed.

## Reporting

Do not post credentials, private chats, exploit payloads against other users, or live session material in public issues. Use the repository's private vulnerability-reporting channel if enabled. If no private channel is available, request a private contact from the maintainer without disclosing the vulnerability publicly. This document does not assert that GitHub private reporting is already enabled.

## Release review

Before publishing: review source and the export manifest; run tests, package/resource/signature checks and isolated launches; verify native authenticated integration against disposable chats; review the dependency and asset notices; and obtain an intentional code-signing/notarization strategy for binary distribution. Development ad-hoc signatures do not identify a trusted publisher. See `docs/verification.md` for gaps.
