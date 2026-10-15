"""Verify the shipped bank's statistical contract and historical reveal provenance."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('drill_calibrate', ROOT / 'tools/drill/calibrate.py')
calibrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibrate)


def test_outcome_tables_and_examples_have_matching_support():
    bank = json.loads((ROOT / 'BallIQ/Data/two_minute_drill.json').read_text())
    by_id = {p['id']: p for p in bank['plays']}
    model = bank['outcomeModel']
    assert len(model['probabilities']) == len(calibrate.FAMILIES) * 9
    for key, probabilities in model['probabilities'].items():
        assert abs(sum(probabilities.values()) - 1) < 1e-9
        assert all(0 <= p <= 1 for p in probabilities.values())
        examples = [by_id[i] for i in model['examples'][key]]
        family = key.split(':')[0]
        assert examples
        assert len({p['id'] for p in examples}) == len(examples)
        assert all(calibrate.family(p) == family or (p['sack'] and family not in ('inside', 'kick')) for p in examples)
        # Every event observed in the full family still has a source example locally.
        observed = {calibrate.event(p) for p in bank['plays'] if calibrate.family(p) == family or (p['sack'] and family not in ('inside', 'kick'))}
        assert {calibrate.event(p) for p in examples} == observed


def test_holdout_is_later_games_and_improves_over_family_baseline():
    bank = json.loads((ROOT / 'BallIQ/Data/two_minute_drill.json').read_text())
    report = bank['calibration']
    assert report['trainingWeeks'] == '1–13'
    assert report['holdoutWeeks'] == '14–18'
    assert report['trainingPlays'] + report['holdoutPlays'] == len(bank['plays'])
    trained = calibrate.fit([p for p in bank['plays'] if int(p['game'].split('_')[1]) <= 13])
    later = [p for p in bank['plays'] if int(p['game'].split('_')[1]) >= 14]
    assert calibrate.evaluate(trained, later) == report['contextual']
    assert report['contextual']['multiclassBrier'] < report['familyBaseline']['multiclassBrier']
    assert report['contextual']['eventECE'] < .02


def test_reveal_starts_at_the_exact_scenario_and_uses_one_game():
    bank = json.loads((ROOT / 'BallIQ/Data/two_minute_drill.json').read_text())
    for start in bank['scenarios']:
        history = start['history']
        assert history and history[0]['id'] == start['id']
        assert all(p['id'].startswith(start['game'] + ':') and p['description'] and p['clock'] for p in history)
        ids = [float(p['id'].split(':')[1]) for p in history]
        assert ids == sorted(set(ids))
