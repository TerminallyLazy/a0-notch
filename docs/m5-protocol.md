# Notch protocol schema 2 — plugin 0.8.0

## Authentication and transport

Use the deployment's existing WebUI HTTP origin. The app uses an ephemeral cookie jar, explicit WebUI username/password login and session CSRF; no shared browser cookies, anonymous or bearer fallback. HTTPS is mandatory except loopback. Redirects are rejected. Each response is capped at 2 MiB. No new listening port or Unix socket is installed by this implementation.

Plugin routes retain `ApiHandler` authentication and CSRF and recheck enabled scope. Status is `POST /api/plugins/a0_notch/status`. Metadata exchange is `POST /api/plugins/a0_notch/events`, with actions `connect`, `poll`, `disconnect`; the consumer supplies UUID `client_id`, epoch and cursor. One 15-second lease is respected, never stolen. Capture offers metadata to a bounded 64-event ring without waiting; overflow drops oldest, contention/no consumer drops incoming.

## Discovery and identity

Status advertises `discovery`, `metadata`, `poll`, `exact_target_actions`, `incarnation_actions`, `attachments`, `paged_discovery`, `error_fifo`, `file_diff`, and `model_presets` as provided by the server. Authoritative capability values come from `helpers/http.py`; consumers must check capabilities rather than infer them from version strings.

Every schema-2 row carries an opaque context ID and UUID `incarnation`, plus bounded name/activity metadata. Incarnation changes when the underlying context object is replaced; ID/name equality alone does not authorize an action. Server epoch changes invalidate the session. The app additionally captures connection generation and selection revision before asynchronous work.

Discovery is all eligible chats, not a pin allowlist. Each immutable catalog transaction carries `page_token`, `page_offset`, `catalog_count`, and optional `next_offset`. Follow-up requests send token/offset to the same route. The app validates offsets, duplicate IDs, epoch/cursor/count and returns only a fully assembled catalog. Page loss/expiry fails closed. No fixed five-chat product cap.

Events contain sequence, context ID/incarnation, kind, activity, tool and observation time; optional bounded diff metadata is workspace-relative path plus added/removed counts. Events are not transcript data. The app keeps metadata alerts FIFO without auto-selecting or fetching another chat. Paused state is not a question. Structured option questions/intervention requests are not invented when upstream has no authoritative source.

## Selected content and actions

- `POST /api/plugins/a0_notch/selected`: `context`, `incarnation`, nonnegative `log_from`. The server returns at most the latest 80 update-cursor entries, deduplicated in normal first-seen order, under the per-log lock. Text is bounded by JSON-escaped wire bytes. It never calls the localization-changing core snapshot builder. The app probes the log version; main-agent responses only are selected as the last response. This narrow projection omits arbitrary log key/value payloads.
- `POST /api/plugins/a0_notch/action`: `action` (`send`, `pause`, `resume`, `stop`), `context`, `incarnation`. Send adds `text` (up to 64 KiB UTF-8) and UUID `message_id`.
- Explicit new-chat creation uses the ordinary `chat_create` API with a generated UUID and empty project. Existing-target operations never create implicitly or redirect to a parent/first chat.

Actions resolve the current eligible context object, check the captured incarnation, use ordinary message hook/log/communicate ordering and revalidate object/token/scope after asynchronous preprocessing. No await is held under the registry lock. Dispatch is not a general transaction across all reentrant extension/settings behavior. Message IDs are not assumed idempotent; ambiguous actions are never automatically retried.

## Attachments

`POST /api/plugins/a0_notch/attachment` uses bounded multipart fields `context`, `incarnation`, `text`, `message_id`, and 1–8 `attachments`. Each file is at most 8 MiB, whole request at most 16 MiB. Safe basenames and approved text/PDF/PNG/JPEG extensions/content are required. Native reads reject symlink components, directories and special files; no path is uploaded. Security-scoped access is used only for the bounded read.

Files are saved with generated names in the normal A0 upload location, passed through `user_message_ui`, logged and communicated as normal attachments. This is not an arbitrary work-directory write. Before dispatch failure, generated files are cleaned; once delivery may have occurred they are preserved. No malware-scan claim is made.

A successful response returns exact `context`, `message`, `attachment_count`, and an `attachments` array of opaque generated basenames, in request order. Native transfer state accepts only a full receipt for its captured operation/target. No full server path or caller path is returned. Upload progress is indeterminate because the current transport exposes no byte callbacks; receipt alone means delivery. Local cancellation cannot promise remote rollback.

## Lifecycle and privacy

`hooks.py` owns install/update/uninstall reset. Upgrade with the supported plugin manager and preserve configuration/activation. The source plugin has no dependencies or daemon. Disconnect/replacement/staleness clears selected content and queued metadata. Pins/aliases/colors are local presentation preferences scoped by authenticated origin/account, not access control. The upstream WebUI account is deployment-wide, not tenant-isolated.

See [integration](plugin-integration.md), [acceptance evidence](verification.md), and the actual tests for boundaries and verification commands.

## 0.8 safety and model presets

The generic encoder fails without resetting telemetry. Catalogs are all-or-nothing, with server context and client aggregate page/byte/deadline budgets; expired transactions are pruned. Eligibility is still rechecked against the registry on continuations, not assumed from a cached authorization result. This bounds accepted catalogs but does not establish a constant-time registry scan.

`POST /api/plugins/a0_notch/model_presets` accepts `context`, `incarnation`, and `action` (`list`, `set`, `clear`); `set` also requires the opaque `preset_id` returned by list. The response includes `allowed`, safe current/preset labels and public model names only. Known-secret masking precedes truncation; failure rejects the projection. No model configuration, provider kwargs, keys, URLs or global-setting write is exposed. The adapter revalidates object/incarnation/scope after asynchronous catalog preparation and invokes the existing core `ModelOverride` per-chat preset/clear path. That upstream method is currently non-suspending; a future yielding implementation is refused and requires compatibility review. Presets may affect utility/embedding slots as well as chat models.

Multipart input has an actual-byte cap independent of the claimed Content-Length; every parser spool closes on failure. A preprocessing hook that removes, reorders or substitutes saved attachments is rejected and files are cleaned before dispatch. The native worker reads files with a running aggregate budget, then rechecks target and staging revision. Local preparation failure means not sent; transport failure after dispatch may be uncertain. Every native mutation has an operation UUID, so canceled old work cannot clear a newer task/status/busy state.

## Docker and remote deployment

Unix-domain sockets cannot cross the Linux VM/macOS kernel boundary through a bind-mounted pathname. Supported Docker Desktop access uses a genuinely loopback-bound published WebUI endpoint or secured loopback tunnel. Remote access uses authenticated HTTPS with normal certificate validation. Authentication and CSRF remain mandatory; no host bridge, cross-kernel socket, anonymous relay or trust-all TLS workaround is supplied.
