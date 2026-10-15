"""Build an offline NFL two-minute-drill bank from public nflverse play-by-play.

Usage: python3 tools/drill/build.py --input /tmp/drill-pbp-2024.csv.gz --rosters /tmp/drill-roster-2024.csv.gz
No accounts or third-party Python dependencies required. See docs/TWO_MINUTE_DRILL.md.
"""
import argparse
from calibrate import build_model
from collections import Counter, defaultdict
import csv
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_2024.csv.gz'


def number(row, key):
    return int(float(row[key] or 0))


def build(path, roster_path):
    with gzip.open(path, 'rt') as stream:
        rows = list(csv.DictReader(stream))
    if {number(row, "season") for row in rows} != {2024}:
        raise ValueError("This edition requires the 2024 play-by-play source")
    with gzip.open(roster_path, 'rt') as stream:
        quarterback_ids = {row['gsis_id'] for row in csv.DictReader(stream) if row['position'] == 'QB'}
    plays, scenarios, seen = [], [], set()
    drive_rows = defaultdict(list)
    for row in rows:
        if row['posteam'] and row['fixed_drive'] and row['desc']:
            drive_rows[(row['game_id'], row['fixed_drive'])].append(row)
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
                    made=row['field_goal_result'] == 'made', description=row['desc'],
                    air=number(row, 'air_yards') if row['air_yards'] else None,
                    side=row['pass_location'] or row['run_location'], gap=row['run_gap'],
                    sack=row['sack'] == '1', complete=row['complete_pass'] == '1',
                    qbRun=row['rusher_player_id'] in quarterback_ids,
                    runner=row['rusher_player_name'], receiver=row['receiver_player_name'],
                    passer=row['passer_player_name'],
                    trick=any(word in row['desc'].lower() for word in ('reverse', 'flea flicker', 'end around', 'lateral to')))
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
        history = [dict(id=r['game_id'] + ':' + r['play_id'], clock=r['time'], description=r['desc'])
                   for r in drive_rows[drive_key] if float(r['play_id']) >= float(row['play_id'])
                   and r['play_type'] not in ('kickoff', 'extra_point')]
        scenarios.append(dict(history=history, id=play['id'], game=row['game_id'], date=row['game_date'],
                              offense=row['posteam'], defense=row['defteam'],
                              offenseScore=number(row, 'posteam_score'), defenseScore=number(row, 'defteam_score'),
                              seconds=seconds, yardline=play['yardline'], toGo=play['toGo'],
                              timeouts=number(row, 'posteam_timeouts_remaining'),
                              actualResult=row['fixed_drive_result'], defenseTimeouts=number(row, 'defteam_timeouts_remaining')))
    scenarios.sort(key=lambda x: x['id'])
    assert len(scenarios) >= 20, 'Not enough complete late-game starting situations'
    assert {p['call'] for p in plays} == {'run', 'pass', 'field_goal'}
    bank = dict(season=2024, source=SOURCE, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                scenarios=scenarios, plays=plays)
    bank['outcomeModel'], bank['calibration'] = build_model(plays)
    if roster_path is not None:
        bank['lineups'] = lineups(rows, scenarios, roster_path)
        bank['rosterSource'] = 'https://github.com/nflverse/nflverse-data/releases/download/weekly_rosters/roster_weekly_2024.csv.gz'
        bank['rosterSHA256'] = hashlib.sha256(roster_path.read_bytes()).hexdigest()
    return bank


def lineups(rows, scenarios, roster_path):
    with gzip.open(roster_path, 'rt') as stream:
        rosters = list(csv.DictReader(stream))
    if {number(row, 'season') for row in rosters} != {2024}:
        raise ValueError('Requires the 2024 weekly roster source')
    by_team_week = defaultdict(list)
    for row in rosters:
        if row['status'] == 'ACT' and row['gsis_id']:
            by_team_week[(row['team'], number(row, 'week'))].append(row)
    involvement = defaultdict(Counter)
    stats = defaultdict(Counter)
    for row in rows:
        if row['season_type'] == 'REG' and row['play_type'] in ('run', 'pass'):
            if row['receiver_player_id']:
                stat = stats[row['receiver_player_id']]; stat['targets'] += 1
                stat['catches'] += number(row, 'complete_pass'); stat['receivingYards'] += number(row, 'receiving_yards')
            if row['rusher_player_id'] and row['qb_kneel'] != '1':
                stat = stats[row['rusher_player_id']]; stat['carries'] += 1; stat['rushingYards'] += number(row, 'rushing_yards')
        for column in ['passer_player_id', 'rusher_player_id', 'receiver_player_id',
                       'solo_tackle_1_player_id', 'assist_tackle_1_player_id', 'sack_player_id',
                       'interception_player_id', 'pass_defense_1_player_id']:
            if row[column]:
                involvement[row['game_id']][row[column]] += 1
    offense_slots = [('QB', ['QB']), ('RB', ['RB', 'FB']), ('WR1', ['WR']), ('WR2', ['WR']),
                     ('WR3', ['WR']), ('TE', ['TE']), ('LT', ['T']), ('LG', ['G']),
                     ('C', ['C']), ('RG', ['G']), ('RT', ['T'])]
    defense_slots = [('E1', ['DE', 'OLB']), ('DT1', ['DT', 'NT']), ('DT2', ['DT', 'NT', 'DE']),
                     ('E2', ['DE', 'OLB']), ('LB1', ['ILB', 'MLB', 'LB', 'OLB']),
                     ('LB2', ['ILB', 'MLB', 'LB', 'OLB']), ('CB1', ['CB', 'DB']),
                     ('CB2', ['CB', 'DB']), ('CB3', ['CB', 'DB']), ('S1', ['FS', 'SS', 'DB']), ('S2', ['SS', 'FS', 'DB'])]
    result = {}
    for scenario in scenarios:
        week = int(scenario['game'].split('_')[1])
        sides = {}
        for side, team, slots in [('offense', scenario['offense'], offense_slots), ('defense', scenario['defense'], defense_slots)]:
            roster = by_team_week[(team, week)]
            roster.sort(key=lambda row: (-involvement[scenario['game']][row['gsis_id']], row['gsis_id']))
            used, selected = set(), []
            for role, positions in slots:
                candidates = [row for row in roster if row['gsis_id'] not in used and row['depth_chart_position'] in positions]
                if not candidates:
                    # A schematic may need an adjacent position, but never a fabricated player.
                    broad = 'OL' if role in ['LT','LG','C','RG','RT'] else ('DB' if role.startswith(('CB','S')) else 'LB')
                    candidates = [row for row in roster if row['gsis_id'] not in used and row['position'] == broad]
                if not candidates:
                    raise ValueError(f"Missing active roster slot: {scenario['game']} {team} {role}")
                row = candidates[0]; used.add(row['gsis_id'])
                selected.append(dict(id=row['gsis_id'], name=row['full_name'], jersey=number(row, 'jersey_number'),
                                     position=row['depth_chart_position'], role=role, headshot=row['headshot_url'], stats=dict(stats[row['gsis_id']])))
            sides[side] = selected
        assert len(sides['offense']) == len(sides['defense']) == 11
        specialists = []
        for role, position in [('K', 'K'), ('H', 'P')]:
            row = next((row for row in by_team_week[(scenario['offense'], week)] if row['position'] == position), None)
            if row:
                specialists.append(dict(id=row['gsis_id'], name=row['full_name'], jersey=number(row, 'jersey_number'),
                                        position=row['depth_chart_position'], role=role, headshot=row['headshot_url'], stats={}))
        sides['specialists'] = specialists
        result[scenario['id']] = sides
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--rosters', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'BallIQ/Data/two_minute_drill.json')
    args = parser.parse_args()
    bank = build(args.input, args.rosters)
    args.output.write_text(json.dumps(bank, separators=(',', ':')) + '\n')
    print(f"{len(bank['scenarios'])} situations; {len(bank['plays'])} sourced plays; {args.output.stat().st_size:,} bytes")
