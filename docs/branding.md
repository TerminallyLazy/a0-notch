# a0_notch branding contract

## Requirement and scope

“Make sure to use proper logos and Agent Zero style and feel.” This is binding for the connected companion app. It is a community project, not an official Agent Zero release. The current connected-product contract supersedes historical demo-only restrictions. The official brand mark is not the Zero character: `ZeroView.swift` remains a provisional Canvas avatar pending the M2 prototype port. Do not substitute that avatar, a hand-drawn logo, or an SF Symbol for brand identity.

## Canonical local assets and provenance

Source: upstream Agent Zero revision `ff2a5b9c9c4e490ba38dd7c313e779510bb2071a`, inspected 2026-10-20. Upstream project: https://github.com/agent0ai/agent-zero . Copies and derivatives live in `app/Sources/A0Notch/Resources/Branding/`.

| Source | Bundled original / derivative | Role |
| --- | --- | --- |
| `webui/public/darkSymbol.svg` | original + `AgentZeroSymbol.png` (128×128) | Official triangular A0 mark; 18 pt monochrome NSStatusItem template |
| `webui/public/a0-fullDark.svg` | original + `AgentZeroWordmark.png` (652×104) | Official outlined wordmark; white alpha template in dark island header |
| `webui/public/icon.svg` | original + `AgentZeroIcon.png` (1024×1024), `app/A0Notch.icns` | Canonical navy-square Agent Zero application icon; original colors retained |
| `webui/vendor/fonts/rubik-variable.ttf` | unmodified font + `rubik-OFL.txt` | Rubik UI, process-local Core Text registration |
| `webui/vendor/fonts/roboto-mono-variable.ttf` | unmodified font + `roboto-mono-OFL.txt` | Roboto Mono code/status labels, process-local registration |
| repository `LICENSE` | `AgentZero-MIT.txt` | Agent Zero repository MIT notice |

SVG artwork was visually inspected before selection. PNGs were rendered directly with librsvg `rsvg-convert` 2.62.1; no traced/redrawn paths, AI-generated marks, or re-typeset wordmark. Runtime template rendering changes only monochrome foreground color. The ICNS was generated on macOS using `sips` at 16/32/128/256/512 pt with 1×/2× representations and `iconutil`. `SHA256SUMS` records original assets, notices, and PNG derivatives. The fonts retain their SIL Open Font License 1.1 notices. The MIT notice records the repository license; it is not a claim of trademark ownership, endorsement, or permission to market this as an official app.

## Durable visual rules

- Island black `#000000`; detached background `#131313`; panels `#1A1A1A`; secondary surfaces `#2D2D2D`; border `#444444` at 66%.
- White primary text; muted `#D4D4D4` at 90%; accent/needs-you `#CF6679`; links `#2B5AB9`; error `#E72323`; warning `#E79C23`.
- Positive actions `#4248F1`, hover `#353BC5`, pressed `#2B309C`; dismissive actions accent outline. Preserve the spec's 18 pt card and 8 pt small-control radii.
- UI uses Rubik, code/status identifiers Roboto Mono. System fallback is a resilience mechanism, not the accepted packaged appearance. Native AppKit menus retain system typography.
- Status colors remain semantic: GEN `#38BDF8`, USE/MCP `#FBBF24`, WWW `#818CF8`, SUB/RES `#14B8A6`, END `#22C55E`, HDL `#94A3B8`.
- Preserve mark proportions and transparency. Keep the wordmark subordinate to current activity, with clear space; no glow, outlines, stretching, or decorative substitutions.
- The approved focused-activity redesign in DESIGN.md supersedes the old M0 dashboard geometry, but preserves the state machine, nonactivation and independent display selection. Remove production demo controls and fake content. Show actual connection freshness and chat activity; never manufacture live traffic.

## Resource and packaging ownership

`A0Brand.swift` owns bundle selection, font registration, images and font helpers. Packaged `.app` execution uses only `Bundle.main`; raw SwiftPM execution uses `Bundle.module`. `Package.swift` copies the Branding folder; `project.yml` adds it as a folder resource plus the ICNS. The SwiftPM packager copies compiled resources into `Contents/Resources/Branding` and the ICNS into `Contents/Resources` before signing. Resources must never depend on an absolute developer path.

Keep `app/Info.plist` concrete and hand-maintained. XcodeGen must use `INFOPLIST_FILE`, not `info.path`. Build a clean temporary app bundle, validate it before replacing the old package, and preserve source-plist mutation checks. `check-app-bundle.sh` validates icon metadata, required resources, hashes, launch metadata and signing. Runtime smoke diagnostics require fonts to resolve to Rubik/Roboto Mono and images to decode successfully. `test-app-launch.sh` verifies LaunchServices, not just direct executable launch; `test-packaging.sh` verifies both build orders.

## Verification and remaining fidelity work

Run `./scripts/test-packaging.sh` and `./scripts/test-display-choice.sh` on the connected Mac. A screenshot comparison of the running app is a separate visual gate; no desktop screenshots are taken by this branding task. Final reference-perfect character rendering, all views/emotes, motion, accessibility sizing, and performance budgets remain later milestones. Asset inspection and successful resource loading alone do not establish pixel-perfect UI fidelity.
