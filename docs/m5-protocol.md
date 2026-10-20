# Notch discovery protocol v1 — plugin 0.6.1

This is the current source contract, superseding the M5 0.5.0 allowlist, name toggle, five-context limit and parent-folding policy. Schema version remains **1**; capabilities negotiate the changed behavior. See verification.md for source versus deployment evidence.

## Authorization and transport

Use the existing WebUI HTTP service only. Plugin API handlers retain `ApiHandler` session-authentication and CSRF defaults and additionally require configured WebUI login and a matching authenticated session. Anonymous WebUI configurations are refused. There is no bearer-token fallback, new port, UNIX socket, daemon or dependency.

Native clients use their own cookie session: POST `/login`, GET `/api/csrf_token`, then protected requests with `X-CSRF-Token`. A login redirect or CSRF response alone is not proof of authentication; require a valid protected status response. Do not follow cross-origin redirects or log credentials, cookies, CSRF tokens or response bodies. Remote origins require HTTPS; discover the actual published service URL rather than assume a port. Keychain and native session policy are client-owned.

Discovery checks global plugin enablement and each chat's effective project/profile enablement through `get_enabled_plugins(context.agent0)`. All ancestors must also be enabled and visible. Installed-but-disabled routes fail closed; child scope cannot override a disabled ancestor. No caller-supplied context list is accepted.

## Discovery and context DTO

Discovery uses `AgentContext.all()` with the same chat-versus-background/task distinction as normal `build_snapshot`: omit BACKGROUND contexts and entries owned by scheduler tasks. The inspected runtime has a deployment-wide WebUI session, not per-user chat ACLs. Do not interpret this implementation as a multi-tenant authorization layer.

All eligible chats are returned, with no product-level count cap or pagination. Separately created subordinate contexts retain their own IDs; ordinary agents sharing a context remain activity in that context. Missing parents, cycles, malformed parent IDs and unexpected parent kinds fail closed. Parent relationships come from `output_data.parent_context_id` with `parent_context_kind == "subordinate"`; no arbitrary output data is exported. Traversal is memoized, with no hierarchy-depth cap.

Every row retains:

| Field | Meaning |
| --- | --- |
| `id` | Actual opaque nonempty A0 context ID, up to 128 characters; not an agent number or prefixed alias |
| `name` | Chat name masked with the framework secret manager, printable-only, capped at 80 characters; fallback `Untitled chat` |
| `state` | `idle`, `working`, `thinking`, `browsing`, `delegating`, `finished`, `error`, `paused` |
| `tool` | Known tool identifier, empty for non-tool events, `tool` for unknown tools |
| `running` | Boolean from actual `context.is_running()` |
| `parent_id` | Optional immediate visible parent context ID; absent on roots |
| `last_activity_at` | Optional finite nonnegative Unix seconds from actual `context.last_message`, never poll time |
| `created_at` | Optional finite nonnegative Unix seconds from actual `context.created_at` |

Known-secret masking is not a PII detector; authenticated chat names can still be private. Names exceeding 4096 input characters use the fallback. No transcript, prompt, reasoning, tool arguments/results, attachment, filename, arbitrary error text or response preview is in plugin telemetry. Selected-chat last-response retrieval belongs to the client's normal poll/history workflow.

## Routes and limits

POST `/api/plugins/a0_notch/status`, JSON `{}`:

- `ok: true`, `schema_version: 1`, `plugin_version: "0.6.1"`
- `server_epoch`: UUID
- `capabilities: ["discovery", "metadata", "poll", "exact_target_actions"]` — replaces `read_only`
- `auth: "session_csrf"`, `contexts`: complete eligible snapshot
- Does not acquire a consumer lease.

POST `/api/plugins/a0_notch/events` accepts exactly:

- Connect: `{ "action": "connect", "client_id": "<UUID>" }`
- Poll: `{ "action": "poll", "client_id": "<UUID>", "server_epoch": "<UUID>", "cursor": 0 }`
- Disconnect: `{ "action": "disconnect", "client_id": "<UUID>", "server_epoch": "<UUID>" }`

There is one consumer lease, renewed for 15 seconds by accepted connect/poll. Connect starts from current state without replay. Response fields remain `ok`, `schema_version`, `server_epoch`, `cursor`, `reset`, `contexts`, `events`, `dropped`. Events contain `sequence`, actual `context_id`, `kind`, `state`, `tool`, `observed_at`. Kinds: `thinking`, `tool_start`, `tool_end`, `finished`, `error`, `idle`. Counters: `overflow`, `contention`, `no_consumer`, `invalid`.

Telemetry input is JSON with known Content-Length, at most **4096 bytes**. Unknown keys/actions/types are rejected; cursors are integers from zero through `2**53-1`, not booleans. UUID identifiers are 36-character strings.

Every plugin response is at most **2,097,152 encoded JSON bytes**. Full snapshots never silently truncate. Oversize returns HTTP **503** with `{"ok":false,"error":"snapshot_too_large"}` and invalidates the lease/epoch. This is a response-size bound, not a constant-memory registry bound. No pagination token is supported. Clients must accept 2 MiB, remove five-row limits, and handle discovery capabilities and optional metadata.

Other errors: 409 `lease_conflict`; 403 `plugin_disabled` or `authentication_required`; 400 `invalid_request` / `invalid_request_or_configuration`; 503 `unavailable`. Framework auth/CSRF guards may reject first (including login redirects). Responses use `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. Internal exceptions are not returned or logged by plugin handlers.

## Capture and lifecycle truth

Verified hook owners: `before_main_llm_call`, `tool_execute_before`, `tool_execute_after`, `_functions/agent/AgentContext/run_task/end`, and exception-start hooks on Agent/AgentContext. Stream-end and per-iteration completion are not task completion. Successful task futures emit finished; cancelled futures emit idle. Intervention/cancellation exceptions are not error alerts. Run tokens reject stale completion, including removal and rediscovery of an ID.

A separate child's root agent may have a nonzero agent number; identity is `agent is context.agent0`, not `number == 0`. Its completion changes only its own row. In-context subordinate activity is tagged delegating.

Hooks project known scalars into one **64-event** try-lock ring. Overflow drops oldest; lock contention drops incoming. No networking, serialization, history traversal, settings reads, disk spool or per-event task creation occurs on capture. Registry reconciliation and HTTP serialization run in the API path, not the agent execution path. No additional worker is required for short polling. Slow HTTP writes do not retain the capture lock.

No consumer means no enqueue. Lease expiry is detected on the next hook/API operation, clearing retained telemetry; an inactive process can retain at most 64 stale events until then. State/run maps scale with discovered contexts. New/removed chats reconcile without revoking the active lease; removed rows, state, runs and queued events are purged. Polls return authoritative snapshots; event loss is expected and not a command-delivery mechanism. Loss counters are best-effort under concurrent contention.

Lifecycle `install`, `pre_update`, `uninstall` reset plugin-owned lease/state only. No shared dependency or user data is removed.

## Native actions and response history

All actions use the app-owned session and CSRF, never the telemetry ring. Version 0.6.1 advertises `exact_target_actions`; the companion refuses send/pause/resume/stop if it is absent, with no direct-core fallback.

POST `/api/plugins/a0_notch/action` accepts exactly one of:

- `{action:"send", context:"<existing ID>", text:"<message>", message_id:"<ID>"}`
- `{action:"pause", context:"<existing ID>"}`
- `{action:"resume", context:"<existing ID>"}`
- `{action:"stop", context:"<existing ID>"}`

These notation examples describe JSON fields; real wire payloads require quoted keys. IDs use the existing printable 128-character bound and cannot be blank. Text must be nonblank and at most 65,536 UTF-8 bytes. The JSON body requires a known Content-Length and is capped at 409,600 bytes to accommodate escaping. Multipart, attachments, unknown fields and implicit targets are rejected.

Send returns `{context,message}` acceptance, pause/resume `{context,pause}`, and stop the normal `{context,stopped,message}` response. Missing or ineligible targets, and objects replaced between request resolution and dispatch, return 409 `target_unavailable`; validation failures return 400 `invalid_request`; unexpected failures return fixed 503 `unavailable`. Auth/CSRF guards can reject first, including redirects. No response promises task completion or continued target existence. There is no client-supplied incarnation token: replacement before request resolution is outside this identity guard.

The adapter reuses normal `user_message_ui` preprocessing, message logging, `UserMessage` and `communicate` semantics; stop reuses `stop_context`. It rechecks object identity and scope after the async hook and performs the synchronous dispatch under the real registry lock. No create-capable lookup is called. Scope settings, scheduler mutations and reentrant hooks are not made transactional by this lock; see the integration document for boundaries. Preprocessing effects cannot be rolled back.

Explicit creation remains POST `/api/chat_create` with a fresh `new_context` UUID and empty `project_name`; selected-chat content remains POST `/api/poll` with exact `context`, `log_from`, `notifications_from` and `timezone`. The native preview examines the latest 80 log updates, not arbitrary old history. Connecting never automatically selects or reads an existing chat.

Never automatically retry ambiguous writes: `message_id` is not a proven idempotency key. Sending can unpause/intervene through normal core behavior. Selection alone never sends anything. Do not log response contents.

## Compatibility and verification

`allowed_context_ids` and `share_context_names` are obsolete and ignored, including saved overrides. Defaults are `{}`; no runtime config rewrite is required. Old 0.5.0 clients require a coordinated upgrade despite schema_version remaining 1. Upgrading exposes eligible chat names to the authenticated companion without the old toggle; communicate that change before deployment.

Run plugin checks with the framework interpreter:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/a0 /opt/venv-a0/bin/python -m pytest -q -p no:cacheprovider tests/test_m5.py tests/test_plugin_discovery.py
```

Tests use synthetic registries/futures and the real framework Flask route/decorator implementation with fixture sessions and patched discovery. They do not prove deployed hooks, native interoperability or live performance. See `plugin-integration.md` for source grounding and deployment boundaries; old M5 verification reports describe earlier releases, not 0.6 acceptance.
