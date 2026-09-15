"""Week Packs: the rules that stop five boards reading as one board five times.

Synthetic candidates only (no network). `check_rules` is asserted alongside `assemble_pack` as an
independent re-check, so a bug that loosened the assembler and the checker together would still
have to get past the concrete expectations here.
"""
from __future__ import annotations

import datetime as dt

from tools.ingest import curation, fresh_drop, pack, periods
from tools.ingest.assemble import PuzzleRow
from tools.ingest.models import RawSeason


def _cand(role, key, players, *, rank=0.0, tiebreak=0.0, position="", title=None):
    """`players` is eight ids, best first; the first four are the keeps."""
    assert len(players) == 8
    content = {"id": key, "theme": title or key, "sport": "nfl",
               "players": [{"id": p, "name": p, "grade": float(100 - i)}
                           for i, p in enumerate(players)]}
    row = PuzzleRow(id=key, sport="nfl", format="keep4", content=content)
    return pack.Candidate(role=role, theme_key=key, title=title or key, row=row,
                          signature=f"{key}|{','.join(sorted(players))}", rank=rank,
                          tiebreak=tiebreak, position=position)


def _ids(prefix, n=8):
    return [f"{prefix}{i}" for i in range(n)]


HEAD = _cand("headline", "fresh-nfl-2026-wk01-any", _ids("h"))


def test_slots_fill_in_priority_order():
    cands = [
        _cand("niche", "gen-2026-wk01-rookie", _ids("n")),
        _cand("division", "fresh-nfl-2026-wk01-any-afc-west", _ids("d")),
        _cand("position", "fresh-nfl-2026-wk01-te", _ids("p"), position="TE"),
        _cand("game", "shape-game-nfl-2026-09-13-car-chi", _ids("g")),
        HEAD,
    ]
    items = pack.assemble_pack(cands)
    assert [c.role for c in items] == list(pack.SLOTS)
    assert pack.check_rules(items) == []


def test_a_player_appears_on_at_most_two_boards():
    # h0 and h1 are already on the headline. The game board adds a second appearance (fine);
    # the first position board would be h0's third, so the second position board wins.
    game = _cand("game", "shape-game-a", ["h0", "h1"] + _ids("g", 6))
    over = _cand("position", "fresh-nfl-2026-wk01-rb", ["h0"] + _ids("r", 7),
                 position="RB", tiebreak=0.0)
    clean = _cand("position", "fresh-nfl-2026-wk01-wr", _ids("w"), position="WR", tiebreak=0.9)
    items = pack.assemble_pack([HEAD, game, over, clean])
    keys = [c.theme_key for c in items]
    assert "fresh-nfl-2026-wk01-rb" not in keys
    assert "fresh-nfl-2026-wk01-wr" in keys
    assert pack.check_rules(items) == []


def test_two_boards_never_share_the_same_four_keeps():
    """The replayed failure: 'fifteen-carry games' was the same eight as 'top RB performances'."""
    rb = _cand("position", "fresh-nfl-2026-wk01-rb", _ids("r"), position="RB")
    same_keeps = _cand("niche", "gen-2026-wk01-workhorse", _ids("r", 4) + _ids("x", 4))
    items = pack.assemble_pack([rb, same_keeps])
    assert [c.theme_key for c in items] == ["fresh-nfl-2026-wk01-rb"]


def test_one_board_per_kind():
    a = _cand("niche", "gen-2026-wk01-any-all-rookie-year", _ids("a"), tiebreak=0.1)
    # Same kind once the period is stripped, so a duplicate board type within one pack.
    b = _cand("division", "gen-2026-wk01-any-all-rookie-year", _ids("b"))
    items = pack.assemble_pack([a, b])
    assert len(items) == 1


def test_served_signatures_are_skipped():
    items = pack.assemble_pack([HEAD], served={HEAD.signature})
    assert items == []


def test_a_pinned_headline_is_taken_as_is_and_first():
    """An existing fresh daily is reused, never replaced by a different headline."""
    pinned = _cand("division", "fresh-nfl-2026-wk01-any-afc-west", _ids("z"))
    items = pack.assemble_pack([HEAD, _cand("game", "shape-game-a", _ids("g"))], headline=pinned)
    assert items[0].theme_key == pinned.theme_key
    assert items[0].role == "headline"
    assert HEAD.theme_key not in [c.theme_key for c in items]


def test_position_slot_prefers_a_position_the_keeps_left_out():
    positions = {p: "QB" for p in _ids("h", 4)}
    qb = _cand("position", "fresh-nfl-2026-wk01-qb", _ids("q"), position="QB", tiebreak=0.0)
    te = _cand("position", "fresh-nfl-2026-wk01-te", _ids("t"), position="TE", tiebreak=0.9)
    items = pack.assemble_pack([HEAD, qb, te], positions=positions)
    assert items[1].theme_key == "fresh-nfl-2026-wk01-te"


def test_cooldown_reorders_the_position_slot():
    """Replaying 2025 without this served 'top TE performances' in 11 of 18 packs."""
    te = _cand("position", "fresh-nfl-2026-wk02-te", _ids("t"), position="TE", tiebreak=0.0)
    wr = _cand("position", "fresh-nfl-2026-wk02-wr", _ids("w"), position="WR", tiebreak=0.9)
    items = pack.assemble_pack([te, wr], recent_kinds={fresh_drop.theme_kind(te.theme_key)})
    assert items[0].theme_key == wr.theme_key


def test_cooldown_never_starves_a_slot():
    only = _cand("niche", "gen-2026-wk02-rookie", _ids("n"))
    items = pack.assemble_pack([only], recent_kinds={only.kind})
    assert [c.theme_key for c in items] == [only.theme_key]


def test_game_of_the_week_is_the_strongest_fixture():
    weak = _cand("game", "shape-game-weak", _ids("a"), rank=-150.0)
    strong = _cand("game", "shape-game-strong", _ids("b"), rank=-220.0)
    items = pack.assemble_pack([weak, strong])
    assert items[0].theme_key == "shape-game-strong"


def test_target_caps_the_pack():
    cands = [HEAD, _cand("game", "shape-game-a", _ids("g")),
             _cand("niche", "gen-2026-wk01-rookie", _ids("n"))]
    assert len(pack.assemble_pack(cands, target=2)) == 2


def test_assembly_is_deterministic():
    cands = [HEAD, _cand("game", "shape-game-a", _ids("g")),
             _cand("niche", "gen-a", _ids("n"), tiebreak=0.3),
             _cand("niche", "gen-b", _ids("m"), tiebreak=0.2)]
    first = [c.signature for c in pack.assemble_pack(cands)]
    assert first == [c.signature for c in pack.assemble_pack(list(reversed(cands)))]


def test_check_rules_catches_each_violation_on_its_own():
    dup_player = [_cand("game", "a", _ids("p")), _cand("niche", "b", _ids("p", 4) + _ids("q", 4)),
                  _cand("division", "c", _ids("p", 1) + _ids("r", 7))]
    assert any("over-exposed" in p for p in pack.check_rules(dup_player))
    same_kind = [_cand("niche", "gen-2026-wk01-x", _ids("a")),
                 _cand("niche", "gen-2026-wk02-x", _ids("b"))]
    assert any("kind" in p for p in pack.check_rules(same_kind))


# ── Items ─────────────────────────────────────────────────────────────────────

def test_board_zero_carries_the_daily_id_and_the_rest_are_pack_scoped():
    items = [HEAD, _cand("game", "shape-game-a", _ids("g"))]
    rows = pack.item_rows("nfl-2026-wk01", items, dt.date(2026, 9, 16),
                          "fresh-nfl-2026-wk01-any-00-daily-20260916")
    assert rows[0]["id"] == "fresh-nfl-2026-wk01-any-00-daily-20260916"
    assert rows[1]["id"] == "shape-game-a-pack-20260916"
    assert all(r["content"]["id"] == r["id"] for r in rows), "results key on content.id"
    assert [r["ordinal"] for r in rows] == [0, 1]
    assert HEAD.row.content["id"] == HEAD.theme_key, "building rows must not mutate candidates"


def test_board_zero_is_the_daily_even_when_it_is_not_the_headline_slot():
    """2025 Week 6: the league-wide board tied at the keep/cut line and was invalid."""
    items = [_cand("game", "shape-game-a", _ids("g")), _cand("niche", "gen-a", _ids("n"))]
    rows = pack.item_rows("nfl-2025-wk06", items, dt.date(2025, 10, 15), "daily-id")
    assert rows[0]["id"] == "daily-id"
    assert rows[1]["id"] != "daily-id"


def test_flagship_keys_map_to_their_slots():
    period = periods.Period(sport="nfl", key="2024-wk01", label="2024 Week 1",
                            start="2024-09-05", end="2024-09-09", season_year=2024,
                            slice=curation.week_slice(2024, 1))
    roles = {}
    for theme in fresh_drop.flagship_themes("nfl", period):
        role, position = pack._role_of_flagship(theme.key, "nfl", period)
        roles.setdefault(role, []).append(position)
    assert roles["headline"] == [""]
    assert len(roles["division"]) == 8
    assert sorted(roles["position"]) == ["QB", "RB", "TE", "WR"]


# ── Photos ────────────────────────────────────────────────────────────────────

STORE = "https://x.supabase.co/storage/v1/object/public/player-headshots/nfl/"


def _with_shots(c, shots):
    players = [dict(p, headshot=s) if s is not None else dict(p)
               for p, s in zip(c.row.content["players"], shots)]
    content = {**c.row.content, "players": players}
    return pack.dataclasses.replace(c, row=pack.dataclasses.replace(c.row, content=content))


def test_photos_are_rewritten_through_the_ledger_and_foreign_ones_dropped():
    c = _with_shots(HEAD, [f"https://cdn/{i}.png" for i in range(8)])
    ledger = {f"https://cdn/{i}.png": f"{STORE}{i}.png" for i in range(7)}
    [out] = pack.apply_photos([c], ledger)
    shots = [p.get("headshot") for p in out.row.content["players"]]
    assert shots[:7] == [f"{STORE}{i}.png" for i in range(7)]
    assert "headshot" not in out.row.content["players"][7], "never ship a provider URL"


def test_a_board_below_six_faces_is_not_offered():
    c = _with_shots(HEAD, [f"https://cdn/{i}.png" for i in range(8)])
    ledger = {f"https://cdn/{i}.png": f"{STORE}{i}.png" for i in range(5)}
    ledger["https://cdn/5.png"] = ""                    # a known placeholder
    assert pack.apply_photos([c], ledger) == []


def test_boards_that_pass_the_photo_gate_pass_the_wire_contract():
    full = [dict(p, teamAbbr="KC", seasonYear=2026, stats=[{"label": "Rec", "value": "5"}])
            for p in HEAD.row.content["players"]]
    base = pack.dataclasses.replace(HEAD, row=pack.dataclasses.replace(
        HEAD.row, content={**HEAD.row.content, "players": full}))
    c = _with_shots(base, [f"{STORE}{i}.png" for i in range(8)])
    [out] = pack.apply_photos([c], {})
    rows = pack.item_rows("nfl-2026-wk01", [out], dt.date(2026, 9, 16), "daily-id")
    pack.validate_items(rows)       # raises on a foreign headshot
