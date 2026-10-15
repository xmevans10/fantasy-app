"""Build an offline NFL two-minute-drill bank from public nflverse play-by-play.

Usage: python3 tools/drill/build.py --input /tmp/drill-pbp-2024.csv.gz
No accounts or third-party Python dependencies required. See docs/TWO_MINUTE_DRILL.md.
"""
import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_2024.csv.gz'


def number(row, key):
    return int(float(row[key] or 0))


def build(path):
    with gzip.open(path, 'rt') as stream:
        rows = list(csv.DictReader(stream))
    if {number(row, "season") for row in rows} != {2024}:
        raise ValueError("This edition requires the 2024 play-by-play source")
    plays, scenarios, seen = [], [], set()
    for row in rows:
        if row['season_type'] != 'REG' or row['posteam'] == '' or row['down'] == '':
            continue
        if row['penalty'] == '1' or row['qb_kneel'] == '1' or row['qb_spike'] == '1':
            continue
        call = 'pass' if row['qb_dropback'] == '1' else row['play_type']
        if call not in ('run', 'pass', 'field_goal'):
            continue
        if call == 'field_goal' and row['field_goal_result'] not in ('made', 'missed', 'blocked'):
            continue
        play = dict(id=row['game_id'] + ':' + row['play_id'], game=row['game_id'],
                    call=call, down=number(row, 'down'), toGo=number(row, 'ydstogo'),
                    yardline=number(row, 'yardline_100'), yards=number(row, 'yards_gained'),
                    turnover=row['interception'] == '1' or row['fumble_lost'] == '1',
                    stopped=row['incomplete_pass'] == '1' or row['out_of_bounds'] == '1',
                    made=row['field_goal_result'] == 'made', description=row['desc'])
        # Keep all real plays: no random trimming or missing down/distance bins.
        plays.append(play)
        drive_key = (row['game_id'], row['fixed_drive'])
        if drive_key in seen:
            continue
        seen.add(drive_key)
        seconds = number(row, 'game_seconds_remaining')
        deficit = -number(row, 'score_differential')
        if number(row, 'qtr') != 4 or not 30 <= seconds <= 120 or not 0 <= deficit <= 5:
            continue
        if play['down'] != 1 or call == 'field_goal' or play['yardline'] < 25:
            continue
        scenarios.append(dict(id=play['id'], game=row['game_id'], date=row['game_date'],
                              offense=row['posteam'], defense=row['defteam'],
                              offenseScore=number(row, 'posteam_score'), defenseScore=number(row, 'defteam_score'),
                              seconds=seconds, yardline=play['yardline'], toGo=play['toGo'],
                              timeouts=number(row, 'posteam_timeouts_remaining'),
                              actualResult=row['fixed_drive_result']))
    scenarios.sort(key=lambda x: x['id'])
    assert len(scenarios) >= 20, 'Not enough complete late-game starting situations'
    assert {p['call'] for p in plays} == {'run', 'pass', 'field_goal'}
    return dict(season=2024, source=SOURCE, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                scenarios=scenarios, plays=plays)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'BallIQ/Data/two_minute_drill.json')
    args = parser.parse_args()
    bank = build(args.input)
    args.output.write_text(json.dumps(bank, separators=(',', ':')) + '\n')
    print(f"{len(bank['scenarios'])} situations; {len(bank['plays'])} sourced plays; {args.output.stat().st_size:,} bytes")
