# Third-party notices and provenance

## Agent Zero identity assets

Source: https://github.com/agent0ai/agent-zero, inspected revision `ff2a5b9c9c4e490ba38dd7c313e779510bb2071a`.

Bundled originals/derivatives: `darkSymbol.svg`, `a0-fullDark.svg`, `icon.svg`, the corresponding AgentZero PNGs and `app/A0Notch.icns`. The complete upstream MIT notice is bundled at `app/Sources/A0Notch/Resources/Branding/AgentZero-MIT.txt`. See `docs/branding.md` for exact source paths and transformation methods. `SHA256SUMS` records resource integrity.

Repository licensing is not a grant of trademark ownership or an endorsement. This app is community-maintained and must not be marketed as an official Agent Zero release.

## Fonts

Rubik and Roboto Mono variable fonts are distributed with their complete SIL Open Font License 1.1 notices in the Branding resource directory (`rubik-OFL.txt` and `roboto-mono-OFL.txt`). The fonts are bundled, not installed system-wide, and retain their original notices.

## Zero and related artwork

Zero's Canvas implementation was generated in this project as original project artwork/code and is covered by the project MIT license. It is not a copied third-party character asset. The requested reference prototype is unavailable, so reference-perfect visual fidelity cannot be verified; that absence is not evidence of infringement or an unresolved third-party license for Zero. No Space Agent astronaut/helmet files, research downloads, or optional skins are included; no redistribution rights are asserted for those excluded assets.

## Packaging implementation

`scripts/package-app.sh` is a simplified adaptation of the `guide-macos-spm-packaging` template from https://github.com/Dimillian/Skills by Thomas Ricouard. The upstream MIT notice follows (retrieved from the upstream LICENSE). The app has no third-party Swift package dependency. Apple frameworks and developer tooling remain subject to their own terms.

MIT License

Copyright (c) 2026 Thomas Ricouard

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The project MIT license covers project contributions only; it does not replace third-party notices or assert ownership over third-party assets. Maintainer sign-off on licensing and provenance is part of the publication gate.
