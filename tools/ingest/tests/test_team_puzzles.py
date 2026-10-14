import copy,json
from pathlib import Path
import pytest
from tools.ingest.team_puzzles import eligible,discover
from tools.ingest.assemble import PuzzleRow
from tools.ingest.validate import validate

def row(**changes):
    return dict({'id':'one','sport':'nfl','team_abbr':'NO','career':False,'week':None,'season_year':2020,'person_id':'person-1','name':'A Player','position':'QB','stats':{'passing_yards':4000,'passing_tds':30,'interceptions':10,'rushing_yards':100,'rushing_tds':2}},**changes)

def test_eligibility_never_invents_missing_stats_or_person_identity():
    for bad in [row(person_id=None),row(team_abbr='ATL'),row(week=3),row(career=True),row(season_year=2026),row(stats={'passing_yards':4000})]:
        assert eligible([bad],through_year=2025)[0]==[]
    assert len(eligible([row(),row(team_abbr='NOR')],through_year=2025)[0])==1
    bad=row();bad['stats']=dict(bad['stats'],passing_tds=99)
    with pytest.raises(ValueError,match='Conflicting'):eligible([row(),bad],through_year=2025)

def test_shipped_inventory_has_variety_correct_scores_and_no_answer_order():
    path=Path(__file__).resolve().parents[3]/'BallIQ/Data/team_puzzles.json'
    boards=json.loads(path.read_text())
    assert len(boards)>=12
    assert len({b['shelf'] for b in boards})==3
    assert sum(b['is_starter'] for b in boards)==1
    assert boards[0]['is_starter'] and boards[0]['content']['theme'].startswith('Drew Brees:')
    sets=[]
    for b in boards:
        c=b['content'];validate(PuzzleRow(id=b['id'],sport='nfl',format='keep4',content=c))
        assert c['id']==b['id'] and b['team_abbr']=='NO'
        cards={p['id'] for p in c['players']}
        assert all(len(cards&previous)<=5 for previous in sets);sets.append(cards)
        for p in c['players']:
            assert p['teamAbbr']=='NO'
            stats={s['label']:float(s['value'].replace(',','')) for s in p['stats']}
            expected=(.04*stats['Pass Yds']+4*stats['Pass TD']-2*stats['INT']+.1*stats['Rush Yds']+6*stats['Rush TD']) if c['scale']=='nfl_qb_fantasy' else (stats['Rec']+.1*stats['Rec Yds']+6*stats['Rec TD']+.1*stats['Rush Yds']+6*stats['Rush TD'])
            assert p['grade']==pytest.approx(round(expected,1))
        assert [p['grade'] for p in c['players']]!=sorted(p['grade'] for p in c['players'])

def test_single_player_recipe_is_repeatable_and_rejects_short_ladders():
    rows=[row(season_year=y,stats=dict(row()['stats'],passing_yards=3000+(y-2000)*100)) for y in range(2000,2010)]
    a=discover(rows,through_year=2025);b=discover(list(reversed(rows)),through_year=2025)
    assert a['puzzles']==b['puzzles'] and a['snapshot']==b['snapshot']
    assert len(a['puzzles'])==1
    assert discover(rows[:7],through_year=2025)['puzzles']==[]
