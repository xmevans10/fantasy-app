# M14 — Accessibility & localization

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.
> Read [DESIGN.md](../BallIQ/DesignSystem/DESIGN.md) before touching any UI — Prime Time's bold
> condensed type and hard-shadow depth must survive this pass, not get flattened into something
> generic in the name of accessibility.

## Goal

Make Playbook usable with VoiceOver and at larger Dynamic Type sizes, and ship the app's first
non-English locale. Today there is **zero** infrastructure for either: no `@ScaledMetric`/
`dynamicTypeSize` handling anywhere in the codebase, no `Localizable.strings`, and every string in
every view is an English literal.

## Why now

The app is feature-complete enough (6 tabs, 2 formats, real content, community, progression) that
accessibility and localization gaps are now the largest remaining barrier to App Store reach and
App Review scrutiny — not missing product surface. Fixing this later means re-touching every view a
second time instead of building it in once.

## Current state to build on

- Type is centralized in [Typography.swift](../BallIQ/DesignSystem/Typography.swift) (`Font.hero`,
  `.title`, `.heading`, `.body14`, `.label11/12`, etc.) — a single place to make font sizes
  Dynamic-Type-aware (`@ScaledMetric` or `.font(...).dynamicTypeSize(...)`) touches every screen at
  once rather than requiring a per-view audit.
- Most custom controls already carry `.lineLimit`/`.minimumScaleFactor` (added defensively for the
  scoring-kind badges this session) — a reasonable pattern to extend, but scale-factor compression
  is not a substitute for real Dynamic Type support at accessibility sizes (AX1–AX5).
- `Keep4CardView`'s primary interaction is a drag gesture, but a tap-based Keep/Cut segmented
  control already exists alongside it (`segmentedControl`) — the accessible path likely already
  exists and mainly needs correct labels/traits, not a new interaction model.
- Every user-facing string is an inline literal (`Text("...")`, `Label("...", ...)`) — no
  `Localizable.strings` catalog, no `String(localized:)` usage anywhere.

## Scope

1. **VoiceOver audit, all 6 tabs + both formats.** Every interactive element needs an accurate
   `accessibilityLabel`/`accessibilityValue`/`accessibilityHint`; every decorative element
   (background art, `SpeedLines`, confetti) needs `.accessibilityHidden(true)`. Keep4's drag gesture
   needs a confirmed accessible alternative (the tap segments) with correct `accessibilityAction`s
   so a card's Keep/Cut state is announced and actionable without a drag. Group compound elements
   (a stat + its label, a badge icon + text — some of this shipped already for `ScoringKind`
   badges this session; extend the pattern everywhere else).
2. **Dynamic Type support.** Audit `Typography.swift`'s fixed-pt custom fonts (Anton/Saira) and
   make them scale with the user's text-size setting up through at least the top accessibility
   sizes, without breaking Prime Time's oversized-numeral aesthetic at default size. Card layouts
   that assume a fixed height (`Keep4CardView`'s stat grid, `DailyGameCard`) need to reflow instead
   of truncating at larger sizes.
3. **Localization infrastructure.** Extract every user-facing string into a `Localizable.xcstrings`
   (Xcode 15+ String Catalog — no separate `.strings`/`.stringsdict` files to hand-maintain) via
   `String(localized:)`. This is mechanical but touches nearly every view — budget real time for it.
4. **First locale: Spanish.** Translate the extracted strings (NFL/NBA fandom has heavy overlap with
   Spanish-speaking markets — the highest-leverage first locale for a US sports-trivia app).
   Player names/team abbreviations/stat labels sourced from the pipeline stay in English (they're
   data, not UI chrome) unless the user says otherwise.

## Key decisions (recommend, then confirm)

- Don't attempt full RTL support in this milestone — just don't hard-code left-to-right assumptions
  (fixed `.leading`/`.trailing` alignment is usually already RTL-safe in SwiftUI; anything using raw
  `.left`/`.right` needs a look). Confirm RTL is genuinely out of scope before spending time on it.
- Dynamic Type: recommend supporting up to the standard accessibility range but confirm whether the
  hero numerals (`Font.hero`, used for grade reveals) should scale at all — a broadcast-scoreboard
  aesthetic may intentionally want to cap how large those get, which is a design call, not an
  accessibility requirement (the *information* still needs to be perceivable some other way, e.g.
  VoiceOver announcing the value regardless of visual size).

## Deliverables

- VoiceOver-navigable app across all 6 tabs and both game formats, with correct labels/traits/hints.
- Dynamic Type support through the accessibility size range without broken layouts.
- `Localizable.xcstrings` covering all UI chrome strings.
- Spanish translation shipped as a selectable locale.

## Verification / success criteria

- Manual VoiceOver pass (simulator Accessibility Inspector or a real device) through: Home → play a
  Keep4 → result → Community → publish flow → Leagues → Versus. Document any element that doesn't
  announce correctly.
- Screenshot the app at the largest Dynamic Type accessibility size on at least Home and the Keep4
  game screen — no truncated/overlapping text.
- Switch the simulator's language to Spanish and screenshot the same two screens.
- All existing tests green (this milestone shouldn't change logic, only labels/layout/strings).

## Hand-offs (cannot be done by the agent)

- A native Spanish speaker's review pass on the translation quality (machine/agent translation
  should be treated as a first draft, not final copy).
