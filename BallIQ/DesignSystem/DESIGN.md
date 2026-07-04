# Playbook design system — "Prime Time"

Playbook's look is **arcade-pop energy with sports-broadcast athleticism** (ESPN-not-Vox). Bright,
loud, high-contrast, kinetic — a game, not a dashboard. This deliberately *replaces* the earlier
CDS-flat aesthetic, which read as generic "AI slop" (the exact failure mode Anthropic's
frontend-design guidance warns about). The fix it prescribes — and what we do here — is to **commit
to one bold, specific direction** with characterful type, a dominant+accent palette, real depth, and
one orchestrated motion moment per screen.

**Reference anchor:** live sports broadcast graphics + arcade scoreboards — color blocks, huge
condensed numerals, hard edges, kinetic reveals, confetti.

## Type (`Typography.swift`, OFL fonts, runtime-registered)
- **Anton** — hero/scoreboard numerals (`Font.hero(_:)`, `heroNumber`, `scoreReveal`). Huge, 56–88pt.
- **Saira Condensed** (Bold/Black) — headlines, labels, buttons (`display1`, `title`, `heading`). Caps.
- **Saira** (Regular/SemiBold/ExtraBold) — body, stats (`body14`, `bodyStrong`, `statValue`).
- Use **weight extremes** (Saira 400 vs Anton/Black) and **3×+ size jumps**. Caps display is on-brand.

## Color (`Theme.swift`)
- **Bright pop, light-first** ("paper" canvas `surface0`), inverts to a bold night palette in dark mode.
- **One dominant + one sharp accent:** dominant **accent** = electric blue `#1E50FF`; sharp **volt** =
  lime `#C2F03A`. Neon `success`/`danger`, hot-orange `warning` (streak flame), `pro` purple.
- Roles expose `fill / bg / text / on` (e.g. `accentFill` + `onAccent`, `voltFill` + `onVolt`).
- `ink` / `borderInk` is the outline color and **flips** (near-black on paper, paper-white on night).

## Depth (`Theme.swift`, `Backgrounds.swift`)
- Bold, tactile depth — **not** flat. `cardSurface()` = surface + 1px border + a hard "ledge" shadow.
- `blockCard(fill:)` = the loud hero block: colored fill, **thick ink outline**, **hard offset shadow**
  (sticker/comic pop). Used for result heroes and the daily "matchup" cards' header bands.
- `SpeedLines`, `DiagonalBlock`, `HeroGlow` add broadcast atmosphere.

## Motion & juice (`Motion.swift`, `Juice/`)
- **One orchestrated reveal per screen:** `.heroReveal(index)` staggers sections in on load.
- **Celebration:** `.celebrate(on:)` fires a confetti burst (vendored **ConfettiSwiftUI**, MIT) on
  perfect sorts, first-clue solves, and rating gains. `CountUpText` rolls big numbers up.
- Everything gates on **Reduce Motion** (no particles, instant reveal).

## Open-source
- Fonts: Anton + Saira (SIL OFL) vendored in `Resources/Fonts` (+ license), registered at launch via
  `FontRegistration` (`CTFontManagerRegisterGraphicsFont`).
- Confetti: **ConfettiSwiftUI** (MIT) vendored as source under `ThirdParty/` (compiles in-module via
  synchronized file groups — no SPM needed).
- Components themselves stay **custom-tokenized** — there's no good drop-in SwiftUI kit, and a generic
  one would erase this identity.

## What we intentionally override from CDS
ALL-CAPS condensed display, bold saturated color, gradients/glows, hard shadows, and weight extremes
are all *on-brand here* and deliberately diverge from CDS's flat/quiet chat-surface rules. Keep AA
contrast on the bright canvas; don't trade legibility for pop.
