# M21-4 — Localize every new Moments string (they currently ship English to Spanish users)

**Agent type:** `balliq-swift-feature`
**Depends on:** M21-1 (green suite). Runs in parallel with M21-2, M21-3, M21-5 — but see the
coordination note about M21-3 below.
**Repo:** `/Users/xanderevans/Documents/fantasy-app`

---

## Goal

Every user-facing string added by the Moments feature resolves to Spanish in `es`, and the
catalog test proves it.

## The gap, verified

The app ships Spanish (`BallIQ/Localizable.xcstrings`, **635 keys**, compiled to `es.lproj`).
The Moments strings were written with `String(localized:)` and `LocalizedStringKey` — the calls
are correct — but **the keys were never added to the catalog**. Verified by direct inspection:

```
MISSING  'LOCK IN YOUR NAME'
MISSING  'WHO DO YOU RIDE WITH?'
MISSING  'BETTER WITH A RIVAL'
MISSING  'CLAIM MY USERNAME'
MISSING  'PICK MY TEAM'
MISSING  'ADD A FRIEND'
MISSING  'CREATE MY ACCOUNT'
MISSING  'My Playbook profile'
PRESENT  'SHARE MY CARD'
PRESENT  'Not now'
PRESENT  'Dismiss'
```

`LocalizationTests` documents exactly this failure mode and why it's quiet:

> A failure here means someone added a literal without `String(localized:)`, **or added the call
> but never added the key to `Localizable.xcstrings` — the second being the quieter of the two,
> since the lookup then just falls back to the English literal.**

That is precisely what happened. A Spanish user sees "LOCK IN YOUR NAME". Nothing crashes,
nothing fails, nothing is logged.

## Step 1 — Find every new string, don't trust the list above

The list above is a spot-check, not an audit. Sweep the M21 files yourself:

```
BallIQ/Features/Onboarding/Moments.swift
BallIQ/Features/Onboarding/MomentPresenter.swift
BallIQ/Features/Onboarding/MomentSheet.swift
BallIQ/DesignSystem/SignInButtons.swift
```

Look for **both** shapes, because they behave differently:
- `String(localized: "…")` — an explicit lookup. Grep for it.
- `LocalizedStringKey` — implicit. `Text("literal")` performs a lookup; `Text(someString)` does
  **not**. In `MomentCopy` the `headline` and `cta` fields are `LocalizedStringKey` (so they look
  up) while `detail` is a plain `String` built with `String(localized:)` (so it looks up at
  construction). Both need catalog entries; check you've caught every one.
- Anything passed to `.accessibilityLabel(…)`, `SharePreview(…)`, `EmptyStateView(title:message:)`.

Then check them all against the catalog rather than eyeballing:

```bash
python3 - <<'PY'
import json
d = json.load(open('BallIQ/Localizable.xcstrings'))['strings']
for s in ["<paste each candidate here>"]:
    print(("PRESENT " if s in d else "MISSING ") + repr(s))
PY
```

**Interpolated strings** need the catalog's positional form, not the Swift source form. For
example `String(localized: "\(played) \(sport.displayName) rounds in. …")` becomes a key
containing `%lld` / `%@` placeholders. Get this right by building once and inspecting what Xcode
extracts, or by matching an existing interpolated key already in the catalog — there are several;
grep the file for `%lld` and `%@` to see the house pattern.

## Step 2 — Add the entries

Match the existing file's exact JSON shape. Open `BallIQ/Localizable.xcstrings` and copy the
structure of a neighbouring entry — do not invent a shape. Each entry needs an `es`
`stringUnit` with `state` and `value`.

Note the two conventions already in the file:
- **Every key is its own English source string** (verified: no `en` stringUnit differs from its
  key), so English resolution is key fallback and there is no `en.lproj`. Don't add `en` units.
- **Branded names carry `"shouldTranslate": false`** and must render identically in every locale
  (`K4C4`, `THE GRID`). Judgement call for you: `Playbook` is the product name and appears in
  `"My Playbook profile"` — the *sentence* should translate, the product name inside it must not.
  Look at how existing entries containing the app name handle this and follow that.

### Translation quality

These are loud, condensed, sports-broadcast headlines, not neutral UI labels. The Spanish must
carry the same register and must stay short enough for `.display1` at `lineLimit(2)` with
`minimumScaleFactor(0.6)`. Spanish typically runs ~20% longer than English — a headline that
scales down to 0.6 to fit is a visible defect.

Suggested starting points (revise if you can do better; you own this call):
- `LOCK IN YOUR NAME` → `ASEGURA TU NOMBRE`
- `WHO DO YOU RIDE WITH?` → `¿CON QUIÉN VAS?`
- `BETTER WITH A RIVAL` → `MEJOR CON UN RIVAL`
- `CLAIM MY USERNAME` → `RECLAMAR MI NOMBRE`
- `PICK MY TEAM` → `ELEGIR MI EQUIPO`
- `CREATE MY ACCOUNT` → `CREAR MI CUENTA`
- `ADD A FRIEND` → `AÑADIR UN AMIGO`

Check each against the existing catalog for consistency — `My Team` is already translated as
`Mi Equipo`, so "team" should stay `equipo`; find the established rendering of "friend",
"username" and "account" in the file and match them rather than introducing synonyms.

## Step 3 — Prove it

Add assertions to `BallIQTests/LocalizationTests.swift` in the style already there:

```swift
func testMomentStringsAreLocalized() {
    XCTAssertEqual(es("LOCK IN YOUR NAME"), "ASEGURA TU NOMBRE")
    // … one per new key
}
```

`es(_:)` is a helper already in that file; it goes through the `es.lproj` sub-bundle directly,
because `String(localized:locale:)`'s `locale` parameter only affects interpolation formatting,
not which localization the bundle picks. Don't reinvent it.

A test that passes because the lookup *fell back to the English key* is worthless — that's the
whole bug. So assert the **Spanish** value, never `XCTAssertEqual(es(k), k)`, except deliberately
for a `shouldTranslate: false` entry (the file has a precedent test for exactly that:
`testBrandedFormatNamesStayEnglish`).

## File ownership (absolute)

You own exactly:
- `BallIQ/Localizable.xcstrings`
- `BallIQTests/LocalizationTests.swift`

You do **not** own any `.swift` file under `BallIQ/Features/` or `BallIQ/DesignSystem/`. If you
find a string that is **not** wrapped in `String(localized:)` / is passed as a plain `String`
where a lookup can't happen, **do not fix it yourself** — report it with file and line. That is
`MomentSheet.swift`, which M21-3 owns.

**Coordination:** M21-3 is verifying these same surfaces visually and *may adjust copy*. Read its
report (or ask the orchestrator) before finalising. If a string changed after you translated it,
your `LocalizationTests` assertion will fail loudly, which is the correct outcome — that's the
test doing its job, not a problem to work around.

## Verification (mandatory)

```bash
cd /Users/xanderevans/Documents/fantasy-app
xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/build-agent-m21-4 build

xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'platform=iOS Simulator,id=448665F0-289F-47A6-BB48-8EFC0FB58A58' \
  -derivedDataPath /tmp/build-agent-m21-4 \
  -only-testing:BallIQTests/LocalizationTests test
```

Then the **full** suite, same destination. A malformed `.xcstrings` can fail to compile into the
bundle entirely, which `LocalizationTests.testKnownKeyResolvesToSpanish` catches by asserting
`es.lproj` exists at all — so a green run of that specific test is your proof the catalog is
still well-formed.

## Definition of done

1. Every new user-facing string is in the catalog with an `es` value (or a justified
   `shouldTranslate: false`).
2. `LocalizationTests` asserts the Spanish value for each, and passes.
3. Full suite green.
4. Report lists every string you added, its translation, and any string you found that **can't**
   be localized because of how it's constructed in code (with file:line, for the orchestrator).

## Do not

- Do not machine-translate without reading the result. A headline that is grammatical but reads
  like a form field defeats the point of these prompts.
- Do not add `en` stringUnits — English is key fallback in this catalog by design.
- Do not install or launch on a simulator.
- Do not `git commit` or `git push`.
