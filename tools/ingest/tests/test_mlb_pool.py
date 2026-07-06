"""MLB pool-discovery tests — pure (fetch_json monkeypatched), covering the notability
threshold that keeps sustained stars and drops one-off category leaders."""
from tools.ingest.providers import mlb_pool


def _leaders(*people):
    """A stat-leaders payload carrying the given (id, name) people."""
    return {"leagueLeaders": [
        {"leaders": [{"person": {"id": pid, "fullName": name}} for pid, name in people]}
    ]}


def _patch_fetch(monkeypatch, per_call):
    """Route mlb_pool.fetch_json to `per_call(cache_key) -> payload`."""
    def fake(url, *, cache_key=None, ttl_hours=24.0):
        return per_call(cache_key)
    monkeypatch.setattr(mlb_pool, "fetch_json", fake)


def test_threshold_keeps_sustained_stars_drops_one_offs(monkeypatch):
    # "Star" appears in every swept (category, season); "OneOff" appears exactly once.
    def per_call(cache_key):
        people = [(1, "Star")]
        if cache_key == "mlb_leaders_homeRuns_2001.json":
            people.append((2, "OneOff"))
        return _leaders(*people)
    _patch_fetch(monkeypatch, per_call)

    pool = mlb_pool.discover(year_from=2000, year_to=2002, min_appearances=3)
    assert pool == {"1": "Star"}                 # OneOff (1 appearance) filtered out


def test_min_appearances_one_keeps_everyone(monkeypatch):
    def per_call(cache_key):
        people = [(1, "Star")]
        if cache_key == "mlb_leaders_hits_2000.json":
            people.append((2, "OneOff"))
        return _leaders(*people)
    _patch_fetch(monkeypatch, per_call)

    pool = mlb_pool.discover(year_from=2000, year_to=2000, min_appearances=1)
    assert pool == {"1": "Star", "2": "OneOff"}


def test_failed_pull_is_skipped_not_fatal(monkeypatch):
    calls = {"n": 0}
    def per_call(cache_key):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("429 forever")   # first category/season errors
        return _leaders((1, "Star"))
    _patch_fetch(monkeypatch, per_call)

    # Sweep still completes and collects Star from the surviving pulls.
    pool = mlb_pool.discover(year_from=2000, year_to=2000, min_appearances=1)
    assert pool == {"1": "Star"}
