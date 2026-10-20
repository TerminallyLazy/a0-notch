# Agent Zero Notch plugin

Companion metadata service for the community a0_notch macOS app. Requires an Agent Zero runtime with the plugin API and implicit extension hooks; tested against framework revision `ff2a5b9c9c4e490ba38dd7c313e779510bb2071a`. No additional Python dependencies, daemon, or listening port.

Install this standalone directory using Agent Zero's normal plugin installer, then enable Agent Zero Notch. The monorepo provides `scripts/package-plugin.sh` to build an installable ZIP. Use the matching 0.6 connected macOS companion; legacy five-chat/read-only clients are incompatible.

## Authentication and privacy

Configured WebUI login, a matching session, and CSRF are mandatory. The plugin intentionally refuses anonymous deployments. It automatically discovers eligible WebUI chats within effective plugin scope, including separately created subordinate chats with parent links. Background/scheduler-only contexts are excluded consistently with WebUI chat discovery. Old `allowed_context_ids` and `share_context_names` settings are ignored: authenticated companion users can now see eligible chat names. Known-secret masking is not general PII removal.

The existing WebUI service exposes POST `/api/plugins/a0_notch/status` and `/api/plugins/a0_notch/events`. Events contain bounded state/tool metadata, never prompts, reasoning, arguments, full responses or raw error details. A single short-lived consumer lease and a 64-event nonblocking ring prevent an absent/slow companion from blocking agent work. Full snapshots exceeding 2 MiB fail visibly rather than silently truncate chats.

Explicit chat creation uses the normal authenticated API. Send/pause/resume/stop use the authenticated exact-target action adapter described in the companion protocol. It retains normal message preprocessing, logging and intervention semantics, but rejects missing or replaced targets instead of implicitly creating chats. The app's selected-chat recent content is retrieved separately through normal APIs and can contain private data.

## Lifecycle

`hooks.py` owns install/update/uninstall cleanup. There is no Execute step and no dependencies to install. Disable or uninstall through the plugin manager. Existing ZIP installations need a backed-up supported replacement plan; do not overwrite loaded modules or restart active tasks casually. Preserve `config.json` and activation settings when upgrading.

## Verification and licensing

Framework tests live in the companion repository's `tests/`; run them with the framework Python interpreter and `PYTHONPATH` set to its root. Source tests do not prove a live native connection. Exercise writes only against disposable chats. This plugin's code is MIT licensed; see LICENSE. It is a community integration, not an official Agent Zero release.
