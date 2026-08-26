# App Store Screenshot Audit — 2026-08-25

Audit of the six live iPhone 6.7" screenshots on the App Store listing, against three criteria:
**no anonymous helmets**, **shows the best-looking parts of the app**, **shows core features**.

**Verdict: yes, they need replacing — and the helmet problem is a live data defect, not just a
stale screenshot.** Retaking them without fixing the data would put helmets back in the new set.

Current set: `01_home` · `02_gridresult` · `03_keep4` · `04_draftspin` · `05_whoami` · `06_overunder`

---

## 1. Anonymous helmets — 3 of 6 shots

| Shot | Player shown | What renders |
|---|---|---|
| `03_keep4` | Byron Chamberlain | Faceless black NFL helmet |
| `04_draftspin` | T.J. Houshmandzadeh | Faceless black NFL helmet |
| `05_whoami` | Charlie Garner | Faceless black NFL helmet |

`04_draftspin` additionally shows Steve Tensi as an "ST" initials monogram — that one is the
*designed* fallback working correctly, and is fine.

### It's the data, not the screenshots

The three helmet players still point at NFL's CDN rather than our rehosted Storage bucket, and
at the `/image/private/` path specifically. Two of them return **byte-identical** images:

```
Byron Chamberlain  382,225 bytes  sha 33be6a8e3c2e353f
Charlie Garner     382,225 bytes  sha 33be6a8e3c2e353f   ← same file
Jerry Rice       1,208,205 bytes  sha 9332cfac31c1ef16   ← a real photo
```

That shared file is the faceless helmet. Same byte-identity technique as commit `c78372a`.

**Scale of the gap in production `player_seasons` (NFL):**

| | rows | share |
|---|---|---|
| Rehosted to our bucket | 83,580 | 62% |
| Still on NFL's CDN | **46,936** | **35%** |
| …of which `/image/private/` | 45,278 | 34% |
| Blank (renders initials monogram — correct) | 1,228 | 1% |

Sampling 20 distinct NFL-CDN URLs: **11 were byte-identical to the helmet placeholder**, all of
them `/image/private/`. Of the 14 `/private/` URLs sampled, 11 were helmets (79%).

Extrapolated: roughly **36,000 rows / ~5,000–6,000 players** currently render an anonymous
helmet in the shipping app. M26 rehosted 62% of NFL and left the rest.

**Fix before retaking screenshots:** ~~run `tools/ingest/headshots.py` over the un-rehosted NFL
rows~~ — **RESOLVED 2026-08-25, and that prescription was wrong.** The ledger queue was already
fully drained (0 `pending`): 7,047 of the hotlinked URLs were *already* classified `placeholder`
and 3,162 already `ok`. Re-running the tool would have found nothing to do. Two real causes:

1. **The ingest pipeline was writing the CDN URLs back.** `headshot_repoint()` clears a
   placeholder to `''`, but `fetch_catalog_ids_missing` counts `''` as *missing*, so the next
   `--upsert` "improved" the row by resending the provider's raw URL — and career rows are in
   `filter_new_catalog_rows`'s unconditional `always_send` path regardless. The repoint had a
   half-life of one ingest run.
2. **Minted puzzles freeze their own copy of the URL** (`content.players[].headshot` for keep4,
   `content.headshot` for journeyman). Repointing `player_seasons` never touches them, and the
   daily is what the app actually serves — 269 puzzle rows were still on NFL's CDN with zero on
   our Storage bucket while the catalog read clean.

Fixed by `main.apply_headshot_ledger`, which applies the ledger to the `RawSeason` list at the top
of a run so puzzles, catalog and both bundled fallbacks inherit one decision. Production now reads
**0** rows on `static.www.nfl.com` on both surfaces (was 46,936 and 269). Verified in the app: the
2001 Troy Brown card rendered the helmet before and the designed "TB" monogram after.

**Re-verified 2026-08-26 — the catalog is clean, the puzzle surface has a residue.**
`player_seasons` (nfl) is genuinely **0**, confirmed. `puzzles.content` is **33**, not 0:

- 32 keep4 + 1 journeyman, all NFL, `active_date` 2026-07-28 → **2026-08-27**
- **242 affected cards**, 200 on the `/image/private/` path, **9 dated today or later**
- Byte-checked five cards on `gen-qb-all-first-round-01-daily-20260827` (*tomorrow's NFL daily*):
  Rodgers, Newton, Mahomes and Josh Allen are real photos — **Daunte Culpepper is byte-identical
  to the 382,225-byte helmet.**

Most likely because `apply_headshot_ledger` runs over the `RawSeason` list at the top of an ingest
run, so it only reaches puzzles that are **re-minted**; rows minted before the fix (including the
2-day-lookahead dailies already sitting there) keep their frozen copy. The remedy is a one-off
sweep over existing `puzzles.content`, not another ingest pass — re-minting would change boards
that may already have been played. Tracked as task 3 in `prompts/HANDOFF-m27-followups.md`.

---

## 2. Factual error in the marketing copy

`03_keep4` subtitle reads **"Ten real seasons, one hidden stat, sorted blind."**

K4C4 is **eight** cards. The screenshot itself says `CARD 1 OF 8` directly above the caption.

---

## 3. Four of six show result screens, not the game

`02_gridresult`, `04_draftspin`, `05_whoami` and (arguably) the whole set lead with score
summaries rather than gameplay.

The sharpest mismatch is `05_whoami`: the headline promises **"SIX CLUES. ONE PLAYER."** and the
image shows **zero clues** — just a final score and the answer. A browser scrolling the listing
learns nothing about how the game works.

Score screens are the payoff, not the pitch. At most one should be a result.

---

## 4. The Grid board looks machine-filled

`02_gridresult`'s nine answers, in order:

> Ahmad Bradshaw · Alex Bachman · Amani Toomer · Adrian Murrell · A.J. Green · Anquan Boldin ·
> A.J. Dillon · Allen Lazard · Antonio Freeman

Every one starts with "A" — the debug autofill taking the first alphabetical match per cell.
Anyone who looks closely sees a synthetic board, which undercuts the "real data" promise.

---

## 5. Third-party product name

`02_gridresult` headlines the result card **"IMMACULATE GRID"**. That is Sports Reference's
product name. Using it in App Store marketing is an avoidable trademark exposure — and it's the
app's own in-game wording for a perfect board, so it's worth renaming at the source
(e.g. "PERFECT GRID" / "NINE FOR NINE").

---

## 6. Composition problems

- **Dead space.** `05_whoami` is ~40% empty cream below the fold; `06_overunder` has large empty
  bands above and below the card. The product's own direction is "no dead space on hero screens."
- **Least-exciting state.** `06_overunder` shows `SCORE 0`, three full lives, and a line of
  `REC TD 3`. Nothing is at stake. A mid-run board with a combo multiplier lit would sell it.
- **Inconsistent vertical rhythm.** `06_overunder`'s headline is one line where the others are
  two, so its subtitle sits lower than the rest of the set. Reads as misaligned when swiped.

---

## 7. Missing core features

Not represented at all:

- **Puzzle Blitz** — the newest headline feature, shipping in 1.7.0
- **Journeyman** — a shipped daily format with the most visually distinctive board in the app
  (crest timeline)
- **Versus / live duels** — the whole multiplayer layer
- **Leagues** — weekly cohorts, promotion/relegation

Also: only two device sizes are uploaded (iPhone 6.7" and iPad 12.9"). That's the Apple minimum
and it's fine, but a 6.9" set would render sharper on current devices.

---

## Recommended replacement lineup (6 shots)

Ordered so the first three carry the pitch — most people never swipe past three.

| # | Screen | Headline | Why |
|---|---|---|---|
| 1 | Home, daily cards | Four new puzzles. Every day. | Orientation. Keep the current one — it's the strongest shot in the set. |
| 2 | **K4C4 mid-board** | Keep four. Cut four. No do-overs. | Core format, real gameplay. **Pick a card with a real photo.** Fix "Ten"→"Eight". |
| 3 | **Journeyman board** | Name him from his clubs. | Most distinctive visual in the app. Crests only — no headshot, so no helmet risk at all. |
| 4 | **Puzzle Blitz, clock at 0:00** | Five minutes. Every format. | New headline feature; the red 0:00 over a live board is the most arresting frame in the app. |
| 5 | **Who Am I? with clues visible** | Six clues. One player. | Fixes the promise/image mismatch. Show clues 1–3 revealed, mid-guess. |
| 6 | Grid or Versus | The 3×3 that settles it. | Keep Grid but **replay the board by hand** so the answers aren't all "A", and drop "Immaculate". |

**Sequencing note:** shots 2–5 all need the headshot backfill done first, except #3 (crests only)
and #4 if the captured board is Journeyman or Grid. Shot #3 is safe to capture today.

---

## Suggested order of work

1. ~~**Backfill the ~47k un-rehosted NFL headshots**~~ — **DONE 2026-08-25**; see §1, the cause was not an unfinished backfill.
2. ~~Fix the "Ten real seasons" copy error.~~ **DONE** — "Eight", in `make_store_screenshots.py`'s `PANELS`.
3. ~~Rename "Immaculate Grid" in-app.~~ **DONE** — now "PERFECT GRID" (`GridResultView.scoreHeader`).
4. Recapture all six with `-screenshotPro` on a 6.9" simulator, hand-playing the Grid board.
5. Upload via `PATCH /v1/appScreenshotSets/...` — 1.7.0 is in review now, so this lands on 1.7.1
   or later. Screenshots are **not** blocking the current submission.
