# Two-Minute Drill

Native, free, unranked NFL minigame inspired by https://nfl2mindrill.com/. Original SwiftUI implementation; no reference-site assets, code, player grades or private data copied.

## Data and reproducibility

The offline bank contains 53 starting situations and 33,936 observed run/pass/kick plays from the **2024 regular season**, not a live coverage claim. Source: [nflverse play-by-play release](https://github.com/nflverse/nflverse-data/releases/tag/pbp), maintained by the nflverse contributors under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Full license is bundled as `nflverse-license.txt`; attribution and transformation disclosure appear in Rules & data sources.

Download `play_by_play_2024.csv.gz` from that release, then run:

```
python3 tools/drill/build.py --input /path/to/play_by_play_2024.csv.gz
```

The output stores the source URL and input SHA-256. Output is deterministic (verified byte-for-byte). This is a fixed historical season edition; there is no current-season constant or refresh promise.

Starting situations: first eligible snap of a Q4 possession, 30–120 seconds left, tied or trailing by 1–5, first down, at least 25 yards from the goal. Kneels, spikes and penalty plays are excluded. Snap outcomes retain source game/play ids and descriptions. No API key, account, new server table or network connection is required to play.

## Rules and limits

Run/pass pools contain the 40 nearest plays with the same down. Distance metric: absolute distance-to-go difference ×5 plus absolute field-position difference. Field goals use nearest field position. Uniform draws are stable by UTC date, snap number and call for daily play; practice randomizes the seed and starting scenario. The game shows empirical average gain and clock-stop rate for each pool, not defensive reads or calibrated win probabilities.

Observed yards, turnovers, out-of-bounds/incomplete flags and kick results are applied to the virtual drive. Source text always describes the original play. Time is explicitly modeled: six seconds per snap, twenty seconds of hurry-up runoff before a subsequent snap when running, three seconds plus a lost down for a spike. A timeout stops the clock without runoff. Thinking/background time consumes no game time. A snap begun before zero can finish at zero. Turnovers, downs, safety, score and clock expiry terminate the possession. Kicks are available at opponent 45 or closer. Opponent possessions, penalties, conversions, player ratings and defensive alignments are outside this edition.

Scores: TD 1000; field goal taking the lead 800, otherwise 600; no score earns five per net yard advanced, capped at 400. The score measures the drive; it does not claim the real game would have been won. Touchdowns add six; no conversion is silently invented.

Daily reset: midnight UTC. First finish per date/device uses the existing completion/XP/streak path with `ranked:false`; replays/practice use the existing zero-XP session log. There is no global leaderboard or cross-device daily XP uniqueness guarantee. The scoreboard stays visible while the playbook scrolls; the field can collapse for compact screens. Exiting a live drive requires confirmation and discards it. Results include source-drive outcome, share text and play-by-play. App backgrounding preserves the current in-memory drive.

## Validation

`TwoMinuteDrillTests` exercises clock/runoff/timeout behavior, final-snap scores, fourth-down spikes, terminal input latching, losses/goal-to-go, turnovers, kick range, full-bank pool coverage, stable UTC selection and bounded termination across every starting scenario. Run on an iOS 18.3 simulator. Launch `-screenshotDrill` to open setup; verify setup, gameplay, result, help and Home tile on iPhone 15 and SE, plus dark mode and enlarged text. Do not interact with the simulator during the test run.

Validation on October 14, 2026: full iOS 18.3 suite 1,046 tests, one skipped, zero failures; final layout pass reran eight minigame tests successfully. Python suite: 969 passed, one skipped. Source rebuild matches bundled JSON byte-for-byte. Simulator interaction verified real sampled outcomes, fourth-down conversion, spike, field goal, original-drive comparison and one daily XP award. Compact field sizing was corrected from screenshot evidence.

Release delivery, October 14, 2026: [PR #7](https://github.com/xmevans10/fantasy-app/pull/7) merged at `65d6a41`. Signed Playbook 1.9.0 (61) uploaded successfully to App Store Connect (`EXPORT SUCCEEDED`); Apple processing is pending. Existing internal `PlaybookTesters` automatically receives all builds; no external group assignment was requested or added. The same development-signed archive was installed over Wi-Fi on Xander’s paired iPhone 15, and installation metadata confirms version 1.9.0, bundle version 61. Application launch succeeded. Public App Store release remains 1.8.7 (55).
