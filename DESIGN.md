# a0_notch visual direction

## Product
A native, connected Agent Zero companion: original Zero character, real chat activity, and explicit controls for the selected chat. The October 2026 connected-product revision supersedes all historical demo-only, read-only, explicit-ID and five-chat restrictions. No production fake activity or demo controls.

## Identity and surfaces
Use [branding.md](docs/branding.md): black attached island, detached background `#131313`, panels `#1A1A1A`, secondary surfaces `#2D2D2D`, border `#444444` at 66%. White and muted `#D4D4D4` text; `#CF6679` accent; `#4248F1` positive actions. Status colors encode real GEN/USE/WWW/SUB/END activity. Do not recolor or redraw canonical marks. Zero is a character, not the official logo.

## Typography
Bundle Rubik for UI and Roboto Mono for status/code. Native AppKit menus use the system font. System fallback is recovery only, not the packaged design target.

## Presentations
Preserve three independently persisted appearances: Notch, Floating Capsule and Slim Bar. Their expanded widths are 640, 560 and 440 points; attached content clears measured hardware-notch height, detached styles sit below the menu-bar region. Display selection remains independent. Shared geometry owns visual and click-through bounds.

## Connected interaction
Show connection state, selected chat identity and actual recent activity. Selecting a chat is read-only. Search and scrolling replace a fixed-size chat roster. Independently created child chats remain distinct and may show their actual parent; ordinary agents inside a chat remain activity.

An explicit composer sends to its visibly selected chat. Create, send/intervene, pause/resume and stop are deliberate operations. Destructive actions require confirmation. Stale or disconnected state disables mutations and stops representing old activity as current. Never manufacture waiting, success, progress or a response.

## Connection settings
Separate Server, Account and connection status. Use persistent labels, secure password entry, opt-in Keychain storage, visible progress, useful bounded errors and coherent disabled states. Preserve existing origin, username and origin/username-scoped saved passwords. The app owns its ephemeral authenticated session; browser cookies are never borrowed.

## Motion and focus
Keep bounded shared geometry interpolation and Reduce Motion. Transparent pixels must not capture clicks. Opening/hovering the island does not steal focus; text entry may deliberately receive focus. No global keystroke interception or Accessibility requirement for ordinary operation.

## Evidence boundaries
No reference-perfect claim without the missing `reference/a0-notch.html`. Native build/resource/launch checks do not establish visual fidelity, click-through on every display, or CPU/RAM budgets. See the current verification report for measured results and remaining gates.
