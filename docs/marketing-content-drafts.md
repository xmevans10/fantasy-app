# Ready-to-post content drafts (2026-07-31, voice calibration added 2026-07-31)

Copy for the "now / training camp" row of `MARKETING.md`'s sequencing table. These are drafts
to post yourself — creating the @playbookdaily account and actually publishing to
X/TikTok/Reddit needs a human (and the app's real name on the App Store is **"Playbook:
Sports Trivia"**, so lead with "Playbook," not "BallIQ," anywhere user-facing).

Reality-checked against the actual share-text code (`ChallengeLink.headline`/`shareText` in
`BallIQ/Features/Share/ChallengeLink.swift`) rather than guessing the format: a real Grid share
reads **"I went 7/9 on today's NFL Grid — beat that."** followed by the 🟩⬛ board, the score
line, and the App Store link — not the "Playbook Grid — NFL 2026-07-17" headline style
`docs/MARKETING.md` used as illustrative shorthand. Copy below matches the real format.

---

## Voice calibration (5 samples, pending your sign-off)

No mascot, no character — just a consistent brand voice. Confident, plainspoken, a little
dry. It talks like someone who actually knows the stats, not like a brand account performing
enthusiasm. Run through the `avoid-ai-writing` skill: no em dashes, no rule-of-three padding,
no hollow intensifiers, sentence lengths actually vary.

**1. Daily templated post:**
> Today's NFL Grid: Raiders, Titans, Jaguars against Broncos, Panthers, Bears.
> Jaguars from the '90s is the cell that gets people. Nine guesses, one per cell.
> Play: [App Store link]

**2. Streak nudge:**
> Your streak's at 12 and today's board is still sitting there.
> Don't let a Tuesday be the reason it ends.

**3. Reactive / trending-player post** (safe category only — trades, big games, milestones):
> [Player] just signed with [Team]. That's a new Grid cell as of today.
> Go find out who else fills it before someone spoils it for you.

**4. Reply into someone else's thread** (the reply-guy tactic):
> That's not right. [Player] only did that twice in the last decade, not "constantly."
> Name the three who actually pulled it off. Bet the list is shorter than you think.

**5. Debut post:**
> Playbook is live. Nine cells, one guess each, real players only.
> New board every day, five sports, free to play.
> [App Store link]

Tell me what to adjust: punchier, drier, warmer, whatever's off. Once this is locked I'll
rewrite the rest of this file's templates and the campaign drafts to match.

---

## X/Twitter — @playbookdaily launch + first week

**Pinned / first post (account launch):**
> Playbook: a daily sports trivia game with a Grid (Immaculate-Grid-style team×team board),
> Keep 4, Who Am I?, and Daily Draft — five sports including soccer and tennis, full Spanish
> support. One board a day, everyone plays the same one. Today's Grid ⬇️

**Daily board post template** (post every morning once the day's board is live):
> Today's [SPORT] Grid: [row labels] × [col labels].
> Name a [hardest cell, e.g. "Jaguars 1990s"] player without looking — [X]% of players couldn't.
> 🟢 Play: [App Store link]

**A real completed-run post** (post your own daily result, not a template — failures included):
> I went 7/9 on today's NFL Grid — beat that.
> 🟩🟩⬛
> 🟩🟩🟩
> ⬛🟩🟩
> 7/9 · 1,240 pts
> [App Store link]

**Reply-guy / trending-player post** (whenever a player is in the news — trade, retirement,
big game):
> [Player] just [news event]. Here's the Grid cell he'd answer: [team] × [decade/stat].
> Bet you can't name who else fills it.

**Weekly crowd-rarity post:**
> Yesterday's most-picked [team] [decade] answer was [player] at [X]%. Would that've been
> your pick, or did you go deeper?

---

## TikTok / Reels / Shorts — play-along script (60-90s, same cut for all three platforms)

**Format:** screen recording of a real Grid run, voiceover, cut on the last cell.

```
[0:00] (screen: Grid board, empty)
VO: "Today's board — NFL, teams by decade. Nine cells, one guess each."

[0:05-0:45] (play 6-7 cells at real pace, light commentary per cell)
VO examples:
 - "Vikings 2010s... easy, that's [player]."
 - "Chargers 1990s... oh, this one's rough."
 - (on a miss or long pause) "Okay I don't know this one — do you?"

[0:45-0:55] (final cell, don't reveal the answer on screen)
VO: "Last cell. [Team] [decade]. I've got a guess but—"
(cut to black / hard cut here, before the answer shows)

[0:55-1:00] (end card: app icon + "Playbook" wordmark)
VO: "Today's board is live in the app. Can you go 9-for-9?
     Link in bio."
```

**Rarity-flex variant (20s):**
```
[0:00] "Only 2% of players got this cell right."
[0:03] (show the cell + the correct answer)
[0:08] "Here's who they picked instead—" (show the 98%'s answer)
[0:14] "Play today's Grid — link in bio."
```

**Caption (same for both, all three platforms):**
> Can you go 9/9 on today's sports Grid? 🏈🏀⚾️⚽️🎾 New board daily — free to play.
> #ImmaculateGrid #SportsTrivia #NFL #DailyGame

---

## Reddit — r/SideProject launch story

**Title:** Solo-built a daily sports trivia app — the data pipeline ingests every NFL roster
since 1999

**Body:**
> Been building this solo for the last few months — Playbook, a daily sports trivia app for
> iOS. The centerpiece is a Grid mode (think Immaculate Grid): nine cells, each one the
> intersection of two things — team × team, team × decade, team × stat milestone — and you
> name a real player who satisfies both. No reused players across a board, autocomplete on
> guesses, and a crowd-rarity score showing what % of players picked the same answer as you.
>
> Some of what was actually hard:
> - The data pipeline pulls every NFL roster since 1999 (~69k player-team-year rows) plus
>   NBA/MLB/soccer/tennis, refreshed weekly, so a cell like "Jaguars, 1990s" has a real,
>   complete answer pool instead of just stat-leaders.
> - Soccer club codes collided across leagues (two different clubs both coded "MCI") — had
>   to make axes league-scoped to fix it.
> - Getting board generation to reliably produce a *viable* team×team board (every cell has
>   at least one real answer) without either being trivially easy or silently broken.
>
> Also does Keep 4 (rank-the-stat-lines), Who Am I?, and a daily fantasy-style draft mode.
> Five sports including soccer and tennis (usually underserved in trivia apps), fully
> localized in Spanish. Free to play daily; Pro unlocks archive/hard mode/extra sports.
>
> [App Store link]. Happy to answer questions about the data pipeline or the Grid-generation
> logic if anyone's curious.

**r/apple weekly app thread (shorter, same links):**
> Playbook — daily sports trivia (Grid/Keep4/Who Am I?/Daily Draft), 5 sports incl. soccer &
> tennis, Spanish localization, free daily play. [App Store link]

---

## Notes for whoever posts these

- Fill in `[App Store link]` with the real short link once decided (raw `apps.apple.com/app/
  id6785275045` works today — a shortened/branded link is a nice-to-have, not a blocker).
- The TikTok script assumes a real device or simulator recording of an actual board — don't
  fabricate cell contents; pull the real daily board the morning you film.
- Swap `[SPORT]`/team/decade placeholders for whatever's actually live that day — these are
  templates, not fixed copy.
