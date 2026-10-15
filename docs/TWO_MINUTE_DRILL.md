# Two-Minute Drill — arcade edition

Native, free, unranked NFL play-calling minigame inspired by https://nfl2mindrill.com/. Build 62 significantly replaces build 61's simple run/pass screen. No reference-site code, assets, private playbook or proprietary ratings are copied.

## Reference study and acceptance bar

The reference was played through its pass route editor, targeted throw, post-snap explanation and option comparison, run concepts, tempo, RPO, trick playbook and Survivor introduction. The arcade edition's acceptance criteria are visible 22-player football action, meaningful receiver/route/concept choices, clock management, staged snap/development/flight/contact feedback, replay/skip without duplicate execution, and a clear call grade independent of the realized play outcome.

The native implementation offers inside zone, left/right sweeps, QB keeper, screen/slant/out/post/go routes, play-action/rollout/sideline modifiers, a box-reading RPO, reverse/flea-flicker concepts, field goals, timeout/spike/kneel, and three tempos. Daily, Practice and Survivor are separate setup choices. Survivor advances when a scored possession ties or takes the lead; failure ends the run. It does not simulate overtime or an opponent possession.

## Data and reproducibility

The offline bank retains **53 real starting situations and 33,936 observed plays** from the 2024 regular season. It adds **22 active-roster players per situation**, plus real kickers/holders when available, with names, jersey numbers, positions, optional headshots and archived receiving statistics. Schematics select players from that week's active roster, prioritizing recorded involvement in that game; they are not historical tracking lineups.

Sources, maintained by the nflverse contributors under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/):

- [2024 play-by-play](https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_2024.csv.gz)
- [2024 weekly rosters](https://github.com/nflverse/nflverse-data/releases/download/weekly_rosters/roster_weekly_2024.csv.gz)

The full license is bundled as `nflverse-license.txt`; attribution and transformation disclosure appear in the app's rules. Both input SHA-256 values and source URLs are stored in the bank.

```
python3 tools/drill/build.py --input /path/to/play_by_play_2024.csv.gz --rosters /path/to/roster_weekly_2024.csv.gz
```

Output is deterministic, verified byte-for-byte. This is a fixed historical edition with no current-season/refresh promise. Starting situations are the first eligible Q4 snap of a possession, 30–120 seconds left, tied or trailing by up to five, first down, at least 25 yards from the goal. Penalties, kneels and spikes are excluded from the sampled bank. Kneel/spike actions are explicitly modeled clock rules.

## Arcade model and scoring

Concepts map to observed pass depth/direction or run direction; sacks are included in pass pools. RPO uses a run pool against light/two-high looks and a quick-pass pool against pressure/loaded boxes. Trick pools use descriptions marking reverses, flea-flickers or laterals. Pools contain up to 80 nearby plays, prioritized by field position, distance and down. The selected receiver's archived catch rate reweights pass completions. Simulated defensive reads and optional modifiers reweight observed outcomes; they are game rules, not calibrated NFL probabilities.

The option comparison grades expected yards, first downs, clock stops and turnovers across concepts for the current target/modifiers. Final score is **70% average call quality + 30% drive score**, capped at 1000. Drive score: touchdown 1000; field goal to lead 800, other made kicks 600; otherwise five per net yard advanced, capped at 400. A smart call still pays when the sampled outcome is unlucky.

Time advances when acting: six seconds per play; 20/32/38 seconds before a subsequent snap when the clock is running. Timeout removes runoff; spike costs three seconds and a down; kneel loses a yard and keeps the clock running. Thinking, animation, replay and background time do not consume extra game time. A final snap may finish after zero; expired pre-snap runoff prevents the snap. Turnovers, downs, safety, score and clock expiry end the possession. Kicks unlock at opponent 45 or closer. Penalties, conversions and opposing possessions are omitted.

Only the first daily finish per UTC date/device earns XP through the existing unranked completion path. Practice, Survivor and daily replays record zero-XP sessions. There is no cross-device daily uniqueness or global leaderboard claim.

## Presentation and verification

A normalized tactical camera shows all 22 roster players, route diagrams, line of scrimmage, first-down line, blocking/rush movement, ball flight, catches/contact, result stamps and play narration. Replay and Skip share a presentation-id commit latch; they cannot repeat a snap, Survivor win or reward. Score/clock transitions, team colors, haptics, synthesized sound cues and existing brand confetti provide feedback. Ambient sound respects silent mode, can be muted, and Reduce Motion resolves immediately with the full explanation.

The scoreboard and primary actions stay pinned while the playbook scrolls. The camera follows long plays into the end zone, and run/receiver motion follows the drawn path. Routes remain assigned when changing targets. Field labels and buttons support compact screens; eligible receiver cards give larger selection targets. Historical source text is available separately from virtual roster narration.

Automated validation: full iOS 18.3 suite **1,053 tests, one skipped, zero failures**; targeted minigame/arcade tests **16 passed**. Python suite **969 passed, one skipped**. Independent source audit matched 33,936 outcomes, 53 starts and all 1,166 standard active-roster placements to the original CSVs. Rebuild matches the bundled JSON byte-for-byte.

Debug snapshots: `-drillScreen setup|play|pass|run|trick|flight|feedback|result|replay` (with `-hasOnboarded YES -skipStoreKit`). They exercise the shipping seams, force practice logging, and are disabled in Release. `flight` holds the throw for inspection; `feedback` also asserts repeated commit does not execute a second snap; `result` uses an observed long scoring play to inspect touchdown layout. `flight` and `replay` choose a completed archived pass for repeatable inspection; `replay` runs the full sequence for a motion recording. Snapshot stages are deterministic by UTC date and include the standard long-label/small-screen cases.

## Delivery

Build 61's initial version is merged in [PR #7](https://github.com/xmevans10/fantasy-app/pull/7), uploaded, confirmed VALID/READY_FOR_BETA_TESTING, and installed/launched on Xander's iPhone over Wi-Fi. Build 62 is the arcade replacement has passed offscreen iPhone 15/SE visual verification of playbook, throws, feedback, touchdown/end-zone camera and dark-mode trick concepts; its signed release delivery is being finalized. Public App Store release remains 1.8.7 (55). Internal TestFlight uses the existing automatic-build-access group; external group distribution is outside this release request.
