# Playbook — M9: Gameplay quality + UX polish

Self-contained prompt for a fresh agent. Read [prompts/README.md](README.md) for shared context.
Assumes the repo as of **2026-06-29 after M6 Phase A** (feed clobber fixed, daily determinism,
grades 0–100). `fantasy-app` is **Playbook**, a native SwiftUI iOS sports-trivia app.

A grab-bag of smaller, high-signal quality fixes surfaced during the M6 review. Each is independently
shippable — do them in any order, smallest blast radius first.

---

## 1. Keep/Cut boundary fairness (the "coin-flip #4 vs #5" problem)

Keep4 ranks 8 seasons by grade; the top 4 are the answer. When seasons #4 and #5 are nearly tied,
distinguishing them is unknowable — e.g. the "Elite WR seasons" puzzle had Calvin Johnson (grade
75.2, a Keep) vs Brandon Marshall (74.0, a Cut), a ~1-point gap. That feels arbitrary and punishing.

**Options (pick one, scope it):** (a) at generation time, reject/regrade puzzles whose #4–#5 grade gap
is below a threshold (enforce a "clean break"); (b) award partial credit for near-boundary misses;
(c) surface the margin in the result UI so a close call reads as close, not as a flat wrong.
Generation-side enforcement (a) is the simplest and most defensible. Puzzle generation lives in
`tools/ingest/assemble.py` + `themes.py`; community generation in `CreateKeep4View`.

**Success:** generated Keep4 puzzles have a minimum boundary gap (or partial credit lands correctly);
parity tests + both suites green.

---

## 2. Kill the Google sign-in dead-end

`ProfileView` (and `OnboardingView`) show a "Continue with Google" button, but the provider is
**disabled** in the Supabase project (`GET /auth/v1/settings` → `"google": false`), so tapping it
fails silently (`try?`). Same for Apple. Either **hide** the provider buttons until the provider is
enabled, or surface the failure with a real message. Don't leave a button that does nothing.

(Enabling the providers — entering OAuth client IDs/secrets in the Supabase dashboard — is a **user
hand-off**, not an agent task. Surface it; don't attempt it.)

**Success:** no auth button silently no-ops; if a provider is off, the user either doesn't see it or
gets told why.

---

## 3. Placeholder tabs read as broken

`Leagues` and `Stats` are `PlaceholderView`s in the tab bar ([ContentView.swift](../BallIQ/ContentView.swift)).
To a user they look like dead features. Until M4 (social) and a real Stats screen ship, make them feel
**intentional** — a polished "coming soon" with what's planned, or remove them from the tab bar so the
app only shows finished surfaces. (Note: a real Stats screen overlaps the M-Profile build-out work —
coordinate so they don't collide.)

**Success:** every visible tab is either finished or clearly, deliberately "coming soon."

---

## Guardrails
- Match the "Prime Time" design system (`BallIQ/DesignSystem/DESIGN.md`); gate motion on Reduce Motion.
- Keep grade parity (`grade.py` / `GradeFormula.swift` / `ScoringRule.swift`) if you touch scoring.
- Both suites green + a screenshot before claiming done.
