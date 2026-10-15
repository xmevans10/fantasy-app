"""Fit an empirical, shrinkage-smoothed outcome model; evaluate on later unseen games.

This predicts observed outcome categories, not counterfactual route/coverage effects.
Sacks have no route label: share their mass across pass families rather than counting
one sack as a full observation for every route. No LLM confidence enters these odds.
"""
from collections import Counter, defaultdict

FAMILIES = ('inside', 'screen', 'slant', 'out', 'post', 'go', 'kick')
EVENTS = ('turnover', 'sack', 'incomplete', 'loss', 'short', 'gain', 'explosive', 'made', 'miss')


def event(p):
    if p['turnover']: return 'turnover'
    if p['call'] == 'field_goal': return 'made' if p['made'] else 'miss'
    if p['sack']: return 'sack'
    if p['call'] == 'pass' and not p['complete']: return 'incomplete'
    return 'loss' if p['yards'] <= 0 else 'short' if p['yards'] <= 3 else 'gain' if p['yards'] < 15 else 'explosive'


def family(p):
    if p['call'] == 'field_goal': return 'kick'
    if p['call'] == 'run': return 'inside'
    if p['sack'] or p['air'] is None: return None
    return 'screen' if p['air'] <= 0 else ('slant' if p['side'] == 'middle' else 'out') if p['air'] < 10 else 'post' if p['air'] < 20 else 'go'


def key(f, to_go, yardline):
    return f'{f}:{0 if to_go <= 3 else 1 if to_go <= 7 else 2}:{0 if yardline <= 20 else 1 if yardline <= 50 else 2}'


def observations(plays):
    # Empirical route shares distribute unlabelled sacks without inventing route data.
    shares = Counter(family(p) for p in plays if p['call'] == 'pass' and family(p))
    total = sum(shares.values())
    for p in plays:
        f = family(p)
        if f: yield p, f, 1.0
        elif p['sack']:
            for f, n in shares.items(): yield p, f, n / total


def fit(plays):
    global_counts, local_counts = defaultdict(Counter), defaultdict(Counter)
    for p, f, w in observations(plays):
        global_counts[f][event(p)] += w
        local_counts[key(f, p['toGo'], p['yardline'])][event(p)] += w
    global_probs = {f: {e: (c[e] + .5) / (sum(c.values()) + .5 * len(EVENTS)) for e in EVENTS} for f, c in global_counts.items()}
    probabilities = {}
    for f in FAMILIES:
        for distance in range(3):
            for zone in range(3):
                k = f'{f}:{distance}:{zone}'; c = local_counts[k]; n = sum(c.values())
                probabilities[k] = {e: (c[e] + 80 * global_probs[f][e]) / (n + 80) for e in EVENTS}
    return dict(version=1, globalProbabilities=global_probs, probabilities=probabilities)


def evaluate(model, plays, contextual=True):
    bins = defaultdict(lambda: [0., 0., 0.]); brier = total = 0.
    for p, f, w in observations(plays):
        probs = model['probabilities'][key(f, p['toGo'], p['yardline'])] if contextual else model['globalProbabilities'][f]
        actual = event(p); total += w
        brier += w * sum((probs[e] - (e == actual)) ** 2 for e in EVENTS)
        for e in EVENTS:
            q = probs[e]; bucket = min(9, int(q * 10))
            b = bins[(e, bucket)]; b[0] += w; b[1] += w * q; b[2] += w * (e == actual)
    ece = sum(abs(predicted - observed) for n, predicted, observed in bins.values()) / (total * len(EVENTS))
    return dict(observations=round(total, 3), multiclassBrier=round(brier / total, 6), eventECE=round(ece, 6))


def build_model(plays):
    train = [p for p in plays if int(p['game'].split('_')[1]) <= 13]
    holdout = [p for p in plays if int(p['game'].split('_')[1]) >= 14]
    trained = fit(train)
    report = dict(trainingWeeks='1–13', holdoutWeeks='14–18', trainingPlays=len(train), holdoutPlays=len(holdout),
                  contextual=evaluate(trained, holdout), familyBaseline=evaluate(trained, holdout, False),
                  caveat='Observed depth/direction families; no tracking data or causal route/coverage claims. Arcade boosts are separate and are not NFL probabilities.')
    model = fit(plays)
    report['excludedUnlabelledPasses'] = len(holdout) - int(report['contextual']['observations'])
    model['examples'] = {}
    for f in FAMILIES:
        eligible = [p for p in plays if family(p) == f or (f not in ('inside', 'kick') and p['sack'])]
        for distance, to_go in enumerate((2, 5, 10)):
            for zone, yardline in enumerate((10, 35, 75)):
                nearest = sorted(eligible, key=lambda p: (abs(p['yardline'] - yardline) + abs(p['toGo'] - to_go) * 5, p['id']))
                pool = nearest[:80]
                represented = {event(p) for p in pool}
                for p in nearest:
                    if event(p) not in represented:
                        pool.append(p); represented.add(event(p))
                model['examples'][f'{f}:{distance}:{zone}'] = [p['id'] for p in pool]
    return model, report
