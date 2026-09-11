"""F1 constructor crest resolution tests — no network, no provider-level import of
`fetch_json`/`fetch_constructors`; every network-touching helper is monkeypatched at the
module level the same way `test_club_codes.py` does for `soccer_club_code_overrides.csv`.

What these pin:
* The infobox `Logo` field parser against the three real wikitext shapes discovered live
  (`[[File:X.svg|250px]]`, bare `File:X.png`, bare `X.svg`) — this is the module's main new
  coverage source (Brabham, Tyrrell, Jordan, Minardi all resolve only here).
* `resolve_crest`'s priority order (override > Wikidata P154 > infobox logo > lead image)
  and that a higher-priority hit short-circuits the lower-priority calls entirely — those
  calls cost a real, rate-limited network round trip in production, so a resolved override
  or P154 hit calling `_infobox_logo`/`_lead_image` anyway would be a real (if silent)
  regression back toward the throttling failure the module's docstring describes.
* The override table (Ferrari/Williams sponsor-lockup fix, Surtees disambiguation-page fix)
  reloads from disk exactly like `soccer_club_code_overrides.csv` does.
* `build_identity`'s dry-run reporting counts a RESOLVED SOURCE, not a rehosted `logo_url`
  (a real bug found live: the previous version's `--dry-run` unconditionally printed 0
  crests because it gated the count on `logo_url`, which is only ever set when `rehost=True`).
"""
from __future__ import annotations

import csv

from tools.ingest.providers import f1_constructors as fc


# ---------------------------------------------------------------------------
# _parse_infobox_logo_field — pure regex extraction, the three real shapes

def test_infobox_logo_field_bracketed_with_size_param():
    # Tyrrell/Surtees shape.
    wikitext = "| Logo          = [[File:SurteesLogo.svg|250px]]\n| Base = Ockham"
    assert fc._parse_infobox_logo_field(wikitext) == "SurteesLogo.svg"


def test_infobox_logo_field_bare_file_prefix_no_brackets():
    # Red Bull/Cooper shape — confirmed live 2026-09-05, no `[[ ]]` at all.
    wikitext = "| Logo = File:Red Bull Racing Logo 2026.svg\n| Base = Milton Keynes"
    assert fc._parse_infobox_logo_field(wikitext) == "Red Bull Racing Logo 2026.svg"


def test_infobox_logo_field_bare_filename_no_prefix():
    # Brabham shape — confirmed live 2026-09-05.
    wikitext = "| Short_name = Brabham\n| Logo = Brabham91.png\n| Base = Weybridge"
    assert fc._parse_infobox_logo_field(wikitext) == "Brabham91.png"


def test_infobox_logo_field_missing_returns_empty():
    wikitext = "| Short_name = Ligier\n| Base = Magny-Cours"
    assert fc._parse_infobox_logo_field(wikitext) == ""


def test_infobox_logo_field_stops_at_pipe_for_wikilink_display_params():
    wikitext = "| Logo = [[File:Atlassian Williams F1 Team logo.svg|220px|class=skin-invert]]"
    assert fc._parse_infobox_logo_field(wikitext) == "Atlassian Williams F1 Team logo.svg"


# ---------------------------------------------------------------------------
# resolve_crest — priority order + short-circuiting

def _stub_no_calls(monkeypatch, name):
    """Monkeypatch `name` to raise if called, proving a higher-priority source short-
    circuited it (a real, avoided network round trip in production)."""
    def _boom(*a, **k):
        raise AssertionError(f"{name} should not have been called")
    monkeypatch.setattr(fc, name, _boom)


def test_resolve_crest_override_wins_and_skips_every_other_source(monkeypatch):
    monkeypatch.setattr(fc, "_OVERRIDES", {"ferrari": "https://example.org/prancing-horse.svg"})
    _stub_no_calls(monkeypatch, "_effective_title_and_qid")
    _stub_no_calls(monkeypatch, "_wikidata_logo")
    _stub_no_calls(monkeypatch, "_infobox_logo")
    _stub_no_calls(monkeypatch, "_lead_image")
    assert fc.resolve_crest("ferrari", "Ferrari", "https://en.wikipedia.org/wiki/Scuderia_Ferrari") \
        == "https://example.org/prancing-horse.svg"


def test_resolve_crest_wikidata_wins_over_infobox_and_lead_image(monkeypatch):
    monkeypatch.setattr(fc, "_OVERRIDES", {})
    monkeypatch.setattr(fc, "_effective_title_and_qid", lambda name, url: ("Maserati", "Q1234"))
    monkeypatch.setattr(fc, "_wikidata_logo", lambda qid: "https://example.org/from-wikidata.png")
    _stub_no_calls(monkeypatch, "_infobox_logo")
    _stub_no_calls(monkeypatch, "_lead_image")
    assert fc.resolve_crest("maserati", "Maserati", "https://en.wikipedia.org/wiki/Maserati") \
        == "https://example.org/from-wikidata.png"


def test_resolve_crest_falls_back_to_infobox_when_wikidata_empty(monkeypatch):
    # The real Maserati case: P154 has nothing, but the infobox logo is the marque wordmark
    # rather than the page's lead image (a road car photo).
    monkeypatch.setattr(fc, "_OVERRIDES", {})
    monkeypatch.setattr(fc, "_effective_title_and_qid", lambda name, url: ("Maserati", None))
    monkeypatch.setattr(fc, "_wikidata_logo", lambda qid: "")
    monkeypatch.setattr(fc, "_infobox_logo", lambda title: "https://example.org/maserati-wordmark.svg")
    _stub_no_calls(monkeypatch, "_lead_image")
    assert fc.resolve_crest("maserati", "Maserati", "https://en.wikipedia.org/wiki/Maserati") \
        == "https://example.org/maserati-wordmark.svg"


def test_resolve_crest_falls_back_to_lead_image_last(monkeypatch):
    monkeypatch.setattr(fc, "_OVERRIDES", {})
    monkeypatch.setattr(fc, "_effective_title_and_qid", lambda name, url: ("British Racing Motors", None))
    monkeypatch.setattr(fc, "_wikidata_logo", lambda qid: "")
    monkeypatch.setattr(fc, "_infobox_logo", lambda title: "")
    monkeypatch.setattr(fc, "_lead_image", lambda title: "https://example.org/brm-lead.png")
    assert fc.resolve_crest("brm", "BRM", "https://en.wikipedia.org/wiki/British_Racing_Motors") \
        == "https://example.org/brm-lead.png"


def test_resolve_crest_returns_empty_when_nothing_resolves(monkeypatch):
    monkeypatch.setattr(fc, "_OVERRIDES", {})
    monkeypatch.setattr(fc, "_effective_title_and_qid", lambda name, url: ("", None))
    assert fc.resolve_crest("afm", "AFM", "https://en.wikipedia.org/wiki/AFM") == ""


# ---------------------------------------------------------------------------
# Override table load/reload

def test_overrides_csv_reload_picks_up_a_fixture_file(tmp_path, monkeypatch):
    fixture = tmp_path / "overrides.csv"
    fixture.write_text(
        "constructor_id,source_url,note\nfixture,https://example.org/fixture.svg,test\n",
        encoding="utf-8")
    monkeypatch.setattr(fc, "OVERRIDES_PATH", fixture)
    fc.reload_overrides()
    try:
        assert fc._OVERRIDES["fixture"] == "https://example.org/fixture.svg"
    finally:
        monkeypatch.setattr(fc, "OVERRIDES_PATH", fc.DATA_DIR / "f1_constructor_logo_overrides.csv")
        fc.reload_overrides()


def test_committed_overrides_csv_has_no_duplicate_constructor_ids():
    with fc.OVERRIDES_PATH.open(encoding="utf-8") as f:
        ids = [row["constructor_id"] for row in csv.DictReader(f)]
    assert len(ids) == len(set(ids))


def test_committed_overrides_cover_the_named_sponsor_lockup_and_disambiguation_cases():
    # The three constructors this task's brief named explicitly: Ferrari/Williams resolve
    # to a CURRENT title-sponsor lockup everywhere else, and Surtees's Ergast URL is a
    # disambiguation page rather than an article.
    with fc.OVERRIDES_PATH.open(encoding="utf-8") as f:
        ids = {row["constructor_id"] for row in csv.DictReader(f)}
    assert {"ferrari", "williams", "surtees"} <= ids


# ---------------------------------------------------------------------------
# _effective_title_and_qid — the disambiguation-page fallback (Surtees)

def test_effective_title_uses_ergast_page_when_it_is_a_real_article(monkeypatch):
    monkeypatch.setattr(fc, "_page_qid_and_disambig", lambda title: ("Q173103", False))
    _stub_no_calls(monkeypatch, "_search_qid_by_name")
    title, qid = fc._effective_title_and_qid("Brabham", "https://en.wikipedia.org/wiki/Brabham")
    assert (title, qid) == ("Brabham", "Q173103")


def test_effective_title_substitutes_via_wikidata_search_when_disambiguation_page(monkeypatch):
    # The real Surtees case: Ergast's URL resolves to a disambiguation page (no qid of its
    # own kind that matters), so a Wikidata search restricted to a racing description finds
    # the real team entity, and its enwiki sitelink becomes the effective title.
    monkeypatch.setattr(fc, "_page_qid_and_disambig", lambda title: (None, True))
    monkeypatch.setattr(fc, "_search_qid_by_name", lambda name: "Q173306")
    monkeypatch.setattr(fc, "_qid_enwiki_title", lambda qid: "Surtees Racing Organisation")
    title, qid = fc._effective_title_and_qid("Surtees", "https://en.wikipedia.org/wiki/Surtees")
    assert (title, qid) == ("Surtees Racing Organisation", "Q173306")


def test_effective_title_falls_back_to_ergast_page_when_search_finds_nothing(monkeypatch):
    monkeypatch.setattr(fc, "_page_qid_and_disambig", lambda title: (None, True))
    monkeypatch.setattr(fc, "_search_qid_by_name", lambda name: None)
    title, qid = fc._effective_title_and_qid("Nonexistent Team",
                                             "https://en.wikipedia.org/wiki/Nonexistent_Team")
    assert (title, qid) == ("Nonexistent_Team", None)


# ---------------------------------------------------------------------------
# build_identity — dry-run must count a resolved SOURCE, not a rehosted logo_url

def test_build_identity_dry_run_counts_resolved_sources_not_rehosted_urls(monkeypatch, capsys):
    monkeypatch.setattr(fc, "load_seasons", lambda: [_FakeSeason("FERRARI"), _FakeSeason("BRABHAM")])
    monkeypatch.setattr(fc, "fetch_constructors", lambda: [
        {"constructorId": "ferrari", "name": "Ferrari", "url": "https://en.wikipedia.org/wiki/Scuderia_Ferrari"},
        {"constructorId": "brabham", "name": "Brabham", "url": "https://en.wikipedia.org/wiki/Brabham"},
    ])
    monkeypatch.setattr(fc, "resolve_crest", lambda cid, name, url: "https://example.org/x.png")

    def _boom_rehost(*a, **k):
        raise AssertionError("rehost must not be called when rehost=False")
    monkeypatch.setattr(fc.logos, "rehost", _boom_rehost)

    rows = fc.build_identity(rehost=False)
    assert len(rows) == 2
    assert all(r["logo_url"] is None for r in rows)  # never rehosted in a dry run
    out = capsys.readouterr().out
    assert "2 with a resolved crest source" in out


def test_build_identity_rehost_true_counts_rehosted_urls(monkeypatch, capsys):
    monkeypatch.setattr(fc, "load_seasons", lambda: [_FakeSeason("FERRARI")])
    monkeypatch.setattr(fc, "fetch_constructors", lambda: [
        {"constructorId": "ferrari", "name": "Ferrari", "url": "https://en.wikipedia.org/wiki/Scuderia_Ferrari"},
    ])
    monkeypatch.setattr(fc, "resolve_crest", lambda cid, name, url: "https://example.org/x.png")
    monkeypatch.setattr(fc.logos, "rehost", lambda source, key: "https://cdn.example.org/x.png")

    rows = fc.build_identity(rehost=True)
    assert rows[0]["logo_url"] == "https://cdn.example.org/x.png"
    out = capsys.readouterr().out
    assert "1 with a rehosted crest" in out


class _FakeSeason:
    def __init__(self, team_abbr: str):
        self.team_abbr = team_abbr
