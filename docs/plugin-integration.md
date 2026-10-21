# Agent Zero Notch integration — 0.8.0

## Ownership and compatibility

`plugin/` is the authoritative installable community plugin; production location is `usr/plugins/a0_notch/`. No core edits, new dependencies, daemon, separate port or Execute step are required. Imports use `usr.plugins.a0_notch`. `hooks.py` owns install/update/uninstall telemetry reset. Use the supported plugin manager and preserve configuration/activation; never overwrite loaded modules.

Schema 2 adds incarnation-bound selected snapshots, actions and attachments, immutable catalog pagination and bounded diff metadata. The native client requires `incarnation_actions` for selected content/actions and `attachments` for uploads. There is no unsafe direct-core mutation fallback. See [protocol](m5-protocol.md) and [verification](verification.md).

## Framework grounding

Inspected framework revision: `ff2a5b9c9c4e490ba38dd7c313e779510bb2071a`. Recheck these owners on upgrades:

| Owner | Contract used |
| --- | --- |
| `agent.AgentContext.all/get/_contexts_lock` | Exact registry identities and removal/replacement synchronization; never create a target during control actions |
| `helpers.state_snapshot.build_snapshot` | Ordinary chats exclude BACKGROUND and scheduler-owned contexts |
| `tools.call_subordinate` | Separate child identity plus `parent_context_id` / `parent_context_kind=subordinate`; agent number is not context identity |
| `helpers.plugins.get_enabled_plugins` | Global and effective context/ancestor plugin scope |
| `helpers.api.ApiHandler` | Normal session and CSRF route guards |
| `helpers.secrets.get_secrets_manager` | Known-secret masking before name truncation, not general PII removal |
| `helpers.extension` | Explicit/implicit lifecycle hooks and async `user_message_ui` preprocessing |
| `api.message.Message.communicate` | Hook → user-message log → `UserMessage` → `context.communicate` sequence |
| `api.stop.stop_context` | Shared stop semantics, preserving history |
| `api.chat_create`, `helpers.log.Log` | Explicit creation and read-only bounded selected-chat log projection |
| `plugins._model_config.api.model_override.ModelOverride` | Existing per-chat preset set/clear, persistence and notifications |

The integration documents describe the local contract; upstream API/plugin contracts remain authoritative.

## Discovery and telemetry

`helpers/http.py` recomputes eligible registry rows for authenticated status/events requests. It follows WebUI chat classification and enforces plugin scope through ancestry. Missing/cyclic/malformed ancestry fails closed. Traversal is memoized by node, with no arbitrary ancestry-depth or five-chat product limit; oversized catalog transactions fail explicitly. Known-secret-masked names, actual creation/activity timestamps, optional immediate parent IDs and fixed activity metadata are projected; arbitrary output data is never serialized.

Separate subordinate contexts stay separate. Agents sharing a context emit delegating activity in that context. Child completion never marks a parent finished. Captures use `before_main_llm_call`, `tool_execute_before/after`, implicit `AgentContext.run_task/end` future completion and Agent/AgentContext exception-start hooks. Cancellation/intervention exceptions are not fabricated errors; successful futures are completion evidence, not a guarantee of a user-visible response.

Capture is a non-waiting offer to a 64-event ring: overflow drops oldest, contention drops incoming, no consumer means no enqueue. There is one 15-second consumer lease. Registry projection, settings lookup, JSON and HTTP work happen outside capture. No spool, automatic reconnect or command delivery through the ring.

All eligible chats are returned through immutable bounded catalog pages; each encoded response stays within the 2 MiB limit. Missing/invalid pages fail closed and no partial catalog is accepted. This is a wire-byte bound, not constant process memory. Synthetic tests include 2,500 contexts and 300-level reverse ancestry; live performance is unmeasured.

## Exact-target actions

`api/action.py` retains normal auth/CSRF decorators and delegates bounded parsing to `helpers/actions.py`. Mandatory configured WebUI login is checked again, as is global plugin enablement. Actions are text-only send, pause, resume and stop. Explicit target IDs are required, including for empty registries. There is no first-chat fallback, implicit creation, parent redirection, automatic retry.

The adapter mirrors the small normal message sequence because the core API has an await between resolving a create-capable target and dispatch. It resolves an existing eligible object, binds current context, awaits the normal `user_message_ui` hook once, then rechecks identity and effective scope. Under the existing registry RLock it logs once and calls normal `communicate(UserMessage(...))` once. It never awaits the agent result. Pause/resume retain the normal boolean assignment; stop calls the shared `stop_context` helper.

**Concurrency boundary:** no await is held under the registry lock. Removal/replacement that wins before final dispatch is rejected; dispatch that wins first can subsequently be cancelled by removal. This does not make plugin settings, scheduler changes, synchronous reentrant extensions or the reset-before-remove portion of `chat_remove` transactional. Preprocessing hook side effects cannot be rolled back. Do not claim a general core transaction guarantee. Recheck adapter fidelity on framework upgrades.

## Native integration

The app owns an ephemeral authenticated session, with no browser cookies, anonymous/bearer fallback or redirects. HTTPS is required except loopback. Explicit creation uses the ordinary API; selected content, text/control and file delivery use incarnation-bound plugin adapters. Client-side connection generation, selection revision, freshness, exact discovery/preflight and confirmation guards remain in place. `message_id` is not assumed idempotent; ambiguous writes are never replayed.

Connecting does not automatically select/read the first existing chat. Deleting the selected chat clears selection/content; it never selects a replacement. A new chat is auto-selected only if the user has not changed selection while creation was in flight. Selected-chat history examines the latest 80 log updates, not arbitrary historical responses. The telemetry lease remains single-consumer, and conflicts are not stolen.

The inspected WebUI account is deployment-wide, not a per-user ACL. This plugin does not provide multi-tenant isolation. If upstream adds user-specific visibility, use that authoritative policy before release against the changed runtime.

## Verification

Run `PYTHONPATH=/a0 /opt/venv-a0/bin/python -m pytest tests -q` in the framework environment. Tests include real Flask auth/CSRF decorators with synthetic sessions, registry/ancestry/bounds cases, absent-target rejection, async preprocessing deletion/replacement/scope races, and actual registry-lock removal ordering across threads. Native HTTP fixtures verify capability gating and lack of fallback. These do not prove deployed native interoperability, signing approval or live performance. See [current evidence](verification.md).
