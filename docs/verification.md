# 0.6.1 delivery verification

Updated 2026-10-20. **Plugin source/package and verified deployment: 0.6.1.** This is a development preview, not completion of the original M0–M9 scope. The repository must remain private pending the remaining acceptance work.

## Verified in this delivery

| Gate | Result and boundary |
| --- | --- |
| Framework Python suite | **112 passed** with the Agent Zero framework interpreter; includes 23 action-boundary tests and nine delivery/privacy source-boundary checks |
| Native Swift suite | **131 passed**, zero failures, on macOS |
| Native builds | SwiftPM debug package and Xcode debug build passed; resources, font hashes, plist and ad-hoc signatures checked |
| Clean packaging | An intentionally stale resource in the prior app was absent from the new package; the new bundle is validated before replacing the old one |
| LaunchServices | Both final build paths passed isolated disconnected launch checks; the earlier candidate also passed all three appearances on both paths |
| Supported plugin deployment | Authenticated plugin uninstall/ZIP-install lifecycle, **19/19 package files matching installed source**, configuration bytes preserved, activation unchanged |
| Live authentication | Unauthenticated action request rejected; authenticated request without CSRF rejected |
| Live disposable chat | Explicit independent creation, exact-target send/pause/resume/stop, and real `thinking`, `tool_start`, `tool_end`, `finished` hook observations passed |
| Live deletion guard | After disposable-chat deletion, all four action kinds returned 409 without recreating it; registry and persisted chat directory absence verified |
| Cleanup | Disposable chat and temporary telemetry lease removed; no existing chats deliberately mutated, no service restart/core edit/dependency installation |
| Export boundary | Explicit reviewed file-level manifest; unknown files in source trees, missing approved files and linked inputs are rejected; source and plugin archives use only that manifest |

## Privacy and identity behavior

Connecting does not select an existing chat or fetch its response. Deleting the selected chat clears selection/content instead of selecting another chat. Only explicit selection or an explicit new-chat operation can choose a chat; creation completion respects intervening selection changes. Events never choose a different chat. Discovery still exposes eligible chat names and metadata to the authenticated companion; this is not a screen-sharing privacy mode.

Submitted credentials are captured synchronously by the connection operation, then the transient password field and save choice are cleared for both Connect and Test, including failed/cancelled outcomes. Origin/account edits also clear them. Keychain persistence remains opt-in; no credentials are written to logs or public source.

Source checks cover the selection and password-clearing structure; they are not a substitute for native UI tests. Action tests cover deletion/replacement/scope/parent changes during a real async preprocessing wait and actual registry-lock ordering across threads. Stale completion from a removed/rediscovered context incarnation is covered by isolated relay tests. These race tests are not live runtime replacement experiments.

**Identity limitation:** the action adapter checks object identity from request resolution through dispatch. It does not expose a client-supplied incarnation token: an ID already replaced before request resolution is not distinguishable from an intentional request for the new object. Registry locking is not a transaction over scope settings, scheduler changes, reset-before-remove, or reentrant hooks. Preprocessing side effects cannot be rolled back. Recheck the small normal-message adapter on framework upgrades.

## Native acceptance attempt

Computer Use was enabled and fresh macOS window observations/backend guidance were used. The rebuilt app launched, but its targeted Accessibility snapshot returned `COMPUTER_USE_WINDOW_NOT_FOUND`. The attempt stopped rather than repeatedly retrying or substituting shell desktop automation. Only the uniquely tagged acceptance process was terminated after verifying its command.

**No native authenticated create/send/pause/resume/confirmed-stop acceptance is claimed.** The successful live HTTP checks above do not establish SwiftUI interaction, focus, or Keychain behavior.

## Remaining release gates

1. Native authenticated disposable-chat workflow, selection/focus races, stale controls, connection errors, settings scrolling, keyboard bindings and Keychain save/forget lifecycle.
2. SMAppService approval/reboot behavior; launch-at-login is implemented but has not been OS-verified or enabled by this delivery.
3. Live separate-subordinate and large-registry performance. Synthetic 2,500-context/deep-ancestry checks are not runtime benchmarks. Snapshots above 2 MiB fail closed; pagination is absent. One telemetry consumer lease remains.
4. Recent response retrieval covers the latest 80 log updates, not arbitrary history. Stronger client-visible incarnation binding remains future hardening.
5. Hardware notch/notch-less/multi-display visuals and click-through, Spaces/fullscreen, Reduce Motion, sleep, accessibility and CPU/RAM budgets. No measured performance or full accessibility conformance claim.
6. The missing `reference/a0-notch.html` prevents reference-perfect motion/character comparison. Upload/diffs, wardrobe, desktop Zero, sound assets, global hotkeys, full original view/emote choreography and intervention/question queue remain incomplete.
7. Intentional distribution signing/notarization and final maintainer release review. Development builds are ad-hoc signed. Zero is original project-generated artwork/code under the project MIT license; missing reference material does not imply infringement. Bundled upstream identity assets/fonts retain their separate notices.

Build logs, runtime identifiers, authenticated session material and rollback/configuration backups are intentionally excluded from the source export. Passing these delivery checks is not authorization to change repository visibility or label the product complete.
