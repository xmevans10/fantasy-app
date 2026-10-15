# Two-Minute Drill — arcade edition

Native, free, unranked NFL play-calling minigame inspired by https://nfl2mindrill.com/. Build 63 significantly replaces build 61's simple run/pass screen. No reference-site code, assets, private playbook or proprietary ratings are copied.

## Reference study and acceptance bar

The reference was played through its pass route editor, targeted throw, post-snap explanation and option comparison, run concepts, tempo, RPO, trick playbook and Survivor introduction. The arcade edition's acceptance criteria are visible 22-player football action, meaningful receiver/route/concept choices, clock management, staged snap/development/flight/contact feedback, replay/skip without duplicate execution, and a clear call grade independent of the realized play outcome.

Build 64 simplifies the surface to **RUN / PASS**, with optional receiver selection and the persistent screen/slant/out/post/go route editor. The daily drive opens directly. Practice and Survivor live under More modes. Tempo is automatic; RPO, tricks, modifiers, spike and kneel controls are removed from the product flow. Timeout appears while running with timeouts available; a useful tying/winning field goal appears on fourth down or in the last 20 seconds inside the opponent’s 45. Replay, grades and option comparison sit inside an optional breakdown. Scoring remains unranked.

After the possession, **What actually happened?** compares your arcade result with the real possession result, then reveals its original play sequence from the exact starting snap. All 53 starts have sourced timelines (303 entries). Penalties/clock actions remain in the historical sequence; conversions are excluded. The reveal does not grade whether you copied history.

## Data and reproducibility

The offline bank retains **53 real starting situations and 33,936 observed plays** from the 2024 regular season. It adds **22 active-roster players per situation**, plus real kickers/holders when available, with names, jersey numbers, positions, optional headshots and archived receiving statistics. Schematics select players from that week's active roster, prioritizing recorded involvement in that game; they are not historical tracking lineups.

Sources, maintained by the nflverse contributors under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/):

- [2024 play-by-play](https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_2024.csv.gz)
- [2024 weekly rosters](https://github.com/nflverse/nflverse-data/releases/download/weekly_rosters/roster_weekly_2024.csv.gz)

The full license is bundled as `nflverse-license.txt`; attribution and transformation disclosure appear in the app's rules. Both input SHA-256 values and source URLs are stored in the bank.

```
python3 tools/drill/build.py --input /path/to/play_by_play_2024.csv.gz --rosters /path/to/roster_weekly_2024.csv.gz
```

Output is deterministic, verified byte-for-byte. This is a fixed historical edition with no current-season/refresh promise. Starting situations are the first eligible Q4 snap of a possession, 30–120 seconds left, tied or trailing by up to five, first down, at least 25 yards from the goal. Penalties, kneels and spikes are excluded from the sampled bank. The historical reveal retains original penalties and clock actions, separately from the sampled arcade bank.

## Arcade model and scoring

`tools/drill/calibrate.py` fits a small empirical categorical outcome model from observed run/pass/field-goal results. Pass families use observed depth/direction as route proxies, not tracking labels: screen (air <= 0), short middle (1–9), short sideline (1–9), intermediate (10–19), deep (20+). Run uses all non-kneel runs. Context is distance (<=3 / <=7 / longer) and field zone (red zone / opponent half / own half). Context counts shrink toward family frequencies with 80 pseudo-observations; unlabelled sacks share their mass according to empirical pass-family shares. Other unlabelled passes are excluded from fitting. All 33,936 original plays stay in the source bank.

Validation fits weeks 1–13 (24,309 plays), evaluates on untouched weeks 14–18 (9,627 plays, 9,343 usable weighted observations), then refits on the full fixed season for shipping. Held-out multiclass Brier: **0.642919** vs **0.652188** for the family-only baseline. Mean event-wise 10-bin ECE: **0.005370**; this aggregate can hide errors in small subgroups and is not proof of counterfactual route/coverage calibration. The baseline ECE is slightly lower (0.005170), so the improvement claim is about Brier, not every calibration metric.

Generated tables contain 63 contexts plus nearby source example ids; load builds an index, so snaps need no network request or archive sort. Rare outcome examples retain support. Each event’s source weights normalize to its fitted mass before explicit **arcade** modifiers: turnover x0.22, sack x0.32, incompletion x0.75, nonpositive gain x0.6, 4–14-yard gain x1.3, explosive gain x1.65. These intentionally generous outcomes are **not NFL probabilities**. Defensive looks are game rules. Receiver season catch rates are shrunk toward 65% with 40 pseudo-targets and bounded to a modest 0.8–1.2 weight adjustment; this adjustment is also not a calibrated player rating.

Call quality compares expected gains, first downs, touchdowns, clock stops, turnover risk and useful kicks. Final score is **80% drive score + 20% average call quality**, capped at 1000. Drive score: TD 1000; FG to lead 800, other made kicks 600; otherwise five per net yard advanced, capped at 400. Winning the drive is the main reward. A scored tie counts as success because conversions/overtime/opponent possessions are omitted.

The clock costs six seconds per play plus eight seconds of automatic hurry-up if running. Timeout removes the runoff. Thinking, animations and replays are free. Final snaps can finish after zero; expired pre-snap runoff prevents a snap. Turnovers, downs, safety, score and clock expiry end the possession.

`tools/drill/verify.swift` runs the **shipping Swift engine**, rather than a Python reimplementation. Across 2,650 drives per policy (50 seeded runs for every start), the visible-clue policy won **1,700 / 2,650 (64.2%)**, expected-utility policy **2,013 (76.0%)**, random routes **1,629 (61.5%)**, and worst-utility routes **1,140 (43.0%)**. This is offline bot balance evidence, not observed human win rates. Expected-utility play scored 1,562 TDs; the simpler read policy scored 587 TDs and used late/4th-down kicks. All policies use the same late timeout and useful-kick policy, isolating route-choice differences. The simple clue policy is only 2.7 percentage points ahead of random; broader situational choice by the utility policy improves the gap to 14.5 points. These figures do not imply every clue-based choice is optimal.

```
swiftc -O -module-cache-path /tmp/drill-swift-module-cache BallIQ/Models/TwoMinuteDrill.swift BallIQ/Models/DrillArcade.swift BallIQ/Models/DrillOutcomeModel.swift tools/drill/verify.swift -o /tmp/drill-verify
/tmp/drill-verify BallIQ/Data/two_minute_drill.json 50 /tmp/drill-balance.json
```

## Research decision

Researched [TypeSafe Jev](https://typesafe.ai/), [JevBall’s implementation](https://jevball.online/), [OpenAI Decisions](https://developers.openai.com/api/docs/guides/decisions) and [nflfastR’s documented models](https://nflfastr.com/). Jev/Decisions answer typed questions; their confidence is not independently validated football completion probability. JevBall itself computes candidate geometry/success estimates locally and uses Jev to choose actions. OpenAI Decisions is the available public counterpart, not privileged internal access. No published reusable Retro Bowl probability model was located in the [New Star Games developer material](https://www.newstargames.com/) reviewed; no claims are made about its proprietary engine.

Chosen path: the small local statistical model above, grounded in the existing nflverse bank and checked against later games. nflfastR’s completion/expected-YAC/EP/WP models are useful references, but do not directly simulate our editable routes and arcade defensive looks. No Jev/OpenAI calls, new credentials, third-party SDKs, live model costs or runtime network dependency are needed. Model probabilities anchor the unboosted observed-event distribution; explicit game rules provide generosity.

Only the first daily finish per UTC date/device earns XP through the existing unranked completion path. Practice, Survivor and daily replays record zero-XP sessions. There is no cross-device daily uniqueness or global leaderboard claim.

## Presentation and verification

A normalized tactical camera shows all 22 roster players, route diagrams, line of scrimmage, first-down line, blocking/rush movement, ball flight, catches/contact, result stamps and play narration. Replay and Skip share a presentation-id commit latch; they cannot repeat a snap, Survivor win or reward. Score/clock transitions, team colors, haptics, synthesized sound cues and existing brand confetti provide feedback. Ambient sound respects silent mode, can be muted, and Reduce Motion resolves immediately with the full explanation.

The scoreboard and primary actions stay pinned while the playbook scrolls. The camera follows long plays into the end zone, and run/receiver motion follows the drawn path. Routes remain assigned when changing targets. Field labels and buttons support compact screens; eligible receiver cards give larger selection targets. Historical source text is available separately from virtual roster narration.

Build 63 baseline: full iOS 18.3 suite **1,053 tests, one skipped, zero failures**. Build 64 targeted minigame/arcade tests **19 passed**; three added Python tests check table support, holdout reproduction and reveal integrity. Full isolated iOS 18.3 suite: **1,057 tests, one skipped, zero failures**. Python: **972 passed, one skipped**. All 303 historical entries were independently matched to the original CSV’s game/drive ids, clocks and descriptions. Independent source audit matched 33,936 outcomes, 53 starts and all 1,166 standard active-roster placements to the original CSVs. Rebuild matches the bundled JSON byte-for-byte.

Debug snapshots: `-drillScreen setup|play|pass|run|clock|history|flight|feedback|result|replay` (with `-hasOnboarded YES -skipStoreKit`). They exercise the shipping seams, force practice logging, and are disabled in Release. `flight` holds the throw for inspection; `feedback` also asserts repeated commit does not execute a second snap; `result` uses an observed long scoring play to inspect touchdown layout. `flight` and `replay` choose a completed archived pass for repeatable inspection; `replay` runs the full sequence for a motion recording. `clock` shows a late running clock with one timeout; `history` opens the final historical reveal. Snapshot stages are deterministic by UTC date and include the standard long-label/small-screen cases.

## Delivery

The arcade implementation is merged in [PR #8](https://github.com/xmevans10/fantasy-app/pull/8) (`7adf75a`), with the enlarged-text scoreboard correction in [PR #9](https://github.com/xmevans10/fantasy-app/pull/9) (`0d2e6ba`). Final **1.9.0 (63)** is uploaded, confirmed **VALID / READY_FOR_BETA_TESTING** internally, and installed on Xander's iPhone over Wi-Fi. Launch on the phone remains unverified because it was locked; unlock and open Playbook. Offscreen iPhone 15/SE visual verification covers the playbook, throws, feedback, touchdown/end-zone camera, dark-mode trick concepts and enlarged text. Public App Store release remains 1.8.7 (55). Internal TestFlight uses the existing automatic-build-access group; no external beta distribution or App Store submission was performed for this release.

Accessibility follow-up: build 63 fixes team-score rendering at enlarged Dynamic Type sizes. The exact failing SE state was re-rendered after the fix and both scores remain visible. The broadcast HUD uses stable label/score sizing while the playbook and narration still scale.

Build 64 delivery (2026-10-15): PR #10 merged (`c06c016`); **1.9.0 (64) is VALID / READY_FOR_BETA_TESTING internally**, upload/build id `9b080045-107c-4bc1-9bf1-bf29c5454d6a`. Testing notes are saved. Final targeted Swift tests: 19 passed. Compact pass/run, pinned timeout, historical reveal and enlarged-text scoreboard were checked on a task-owned SE simulator. The signed archive was built from an isolated minigame-only source snapshot; concurrent Keep4/My Teams/headshot edits were excluded. Direct phone installation failed because Xcode’s paired wireless tunnel was unavailable; the user explicitly chose TestFlight delivery. Public App Store release and external beta distribution are unchanged.
