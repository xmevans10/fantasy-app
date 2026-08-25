# Playbook — Brand Basics

The short version of `BallIQ/DesignSystem/DESIGN.md`, cut down to what someone posting on
social actually needs. Where the two disagree, the app is right and this file is stale.

---

## Palette

The identity is **"Prime Time"** — arcade-pop meets sports broadcast. Paper ground, one
dominant blue, one sharp accent, hard ink outlines.

| Role | Hex | Use for |
|---|---|---|
| **Blue** (dominant) | `#1E50FF` | The brand color. Backgrounds, the "book" half of the wordmark, primary buttons. |
| **Volt** (accent) | `#C2F03A` | Spend it *once* per composition. Kickers, highlights, the payoff number. |
| **Ink** (text) | `#15120B` | All body text on light grounds. Every outline and offset shadow. |
| **Paper** (ground) | `#F4F1E9` | The light background. Warm, not white — never use `#FFFFFF` as the ground. |
| Gold | `#E0A92E` | Journeyman only |
| Red | `#E63A2E` | Over/Under only, and urgency (a clock at 0:00) |
| Green | `#18A957` | Puzzle Blitz only |
| Purple | `#6D3BF5` | Pro / The Grid only |

Swatch sheet: `05-brand/palette-swatches.png`

The four format colors are **not** general-purpose decoration. Each one means a specific
game mode inside the app; using gold for a post about K4C4 teaches people the wrong thing.

---

## Type

All three faces are SIL Open Font License and vendored at `BallIQ/Resources/Fonts/`
(licenses alongside them). Free to use in any marketing material.

| Face | Where | Notes |
|---|---|---|
| **Anton** | Big statement headlines, hero numerals | All caps. Tight. This is the shouty one. |
| **Saira Condensed** (Bold / Black) | The wordmark, labels, chips, UI headings | Bold = "play", Black = "book". Uppercase for labels. |
| **Saira** (Regular / SemiBold) | Body copy, taglines, captions | Sentence case. |

On the web, all three are on Google Fonts.

---

## The wordmark

`play` in **Saira Condensed Bold** + `book` in **Saira Condensed Black**, lowercase, no
space, no tracking. Two weights, two colors, one word.

| Ground | "play" | "book" |
|---|---|---|
| Paper | Ink `#15120B` | Blue `#1E50FF` |
| Ink / dark | Paper `#F4F1E9` | Volt `#C2F03A` |
| Blue | White | Volt `#C2F03A` |

**Do**
- Keep clear space of at least the cap-height of the "P" on all four sides.
- Use the mono versions when the background is busy or the reproduction is one-color.
- Let it sit small. It's a broadcast bug, not a billboard.

**Don't**
- Re-space, re-weight, or set it in one weight — the two-weight contrast *is* the mark.
- Capitalize it ("Playbook" in prose is fine; the mark is always lowercase).
- Put the blue "book" on a blue ground, or the volt "book" on a volt ground.
- Add a drop shadow, gradient, outline, or stroke.
- Recolor "book" to a format color (gold/red/green/purple) — those mean game modes.

---

## Composition

Three moves carry most of the look:

1. **The block card.** A solid fill, a 3px ink outline, and a hard ink shadow offset down-right
   by ~7px. No blur, ever. This is how every card in the app is built.
2. **The lower-third chip.** A skewed (-9°) blue block with white condensed caps, on a hard
   shadow — the broadcast lower-third. Used for section headers.
3. **Format cartridges.** Rounded rects in each mode's color with a 2px ink outline, set in
   Saira Condensed Black caps. See any header in `03-headers/`.

**Dead space is a bug.** The app's own product direction calls for "no dead space on hero
screens." If a post has a big empty field, put the app in it.

---

## Voice

Plain, confident, specific. Short sentences. Numbers over adjectives.

- **Say:** "Eight real seasons, sorted blind." · "Five minutes. Every format. One score."
- **Don't say:** "Test your sports knowledge with our exciting trivia experience!"

No exclamation marks. No emoji in headlines (fine in replies). Never claim a number that
isn't true — the whole product is built on real stat lines and the copy should act like it.
