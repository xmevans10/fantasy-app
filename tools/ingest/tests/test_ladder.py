

# ── Board identity is CONTENT, not the row id ────────────────────────────────────

def _cand(pid, sig, diff=0.32, fmt="keep4", sport="soccer"):
    from tools.ingest.ladder import Candidate
    return Candidate(pid, fmt, sport, diff, [diff] * 8, [True] * 4 + [False] * 4, sig)


def test_content_signature_is_identical_for_a_pool_row_and_its_daily_reid():
    """`daily_puzzle._finalize_row` re-ids a stable pool row when it mints it as a daily, so
    one board is live under two ids with byte-identical content. Reported from the app on
    2026-08-19: rungs 4 and 5 both served `soccer-playmakers-00`'s eight cards, one as
    `soccer-playmakers-00` and one as `soccer-playmakers-00-daily-20260814`."""
    from tools.ingest.ladder import content_signature
    content = {"players": [{"id": f"p{i}", "name": f"Player {i}"} for i in range(8)]}
    a = content_signature("keep4", "soccer-playmakers-00", content)
    b = content_signature("keep4", "soccer-playmakers-00-daily-20260814", content)
    assert a == b, "the same eight cards must have one signature whatever the row id"


def test_content_signature_separates_genuinely_different_boards():
    from tools.ingest.ladder import content_signature
    one = {"players": [{"id": f"p{i}"} for i in range(8)]}
    two = {"players": [{"id": f"q{i}"} for i in range(8)]}
    assert content_signature("keep4", "a", one) != content_signature("keep4", "b", two)
    # Card ORDER is not identity — the same eight dealt differently is the same puzzle.
    shuffled = {"players": list(reversed(one["players"]))}
    assert content_signature("keep4", "a", one) == content_signature("keep4", "c", shuffled)


def test_content_signature_falls_back_to_the_id_for_an_unknown_format():
    from tools.ingest.ladder import content_signature
    assert content_signature("mystery-format", "some-id", {}) == "some-id"


def test_two_ids_for_one_board_cannot_occupy_two_rungs():
    """The end-to-end guard: feed the builder a board that exists under two ids and confirm the
    ladder never seats both. Before the signature change these were two candidates."""
    from tools.ingest.ladder import RUNG_COUNT, build_rungs
    twins = [_cand("soccer-playmakers-00", "keep4|shared"),
             _cand("soccer-playmakers-00-daily-20260814", "keep4|shared")]
    # `mode_for` cycles keep4/whoami/grid across the ladder, so every format needs depth or
    # the builder exits on the difficulty floor before it ever reaches the twins.
    others = []
    for fmt in ("keep4", "whoami", "grid"):
        others += [_cand(f"{fmt}-filler-{i}", f"{fmt}|filler-{i}",
                         diff=0.25 + (i % 40) * 0.01, fmt=fmt)
                   for i in range(RUNG_COUNT * 3)]
    roster = [{"id": f"bot{i}", "base_skill": 0.3 + i * 0.01, "style": "consistent"}
              for i in range(RUNG_COUNT)]
    rows, boards = build_rungs(twins + others, roster)
    seated = [r["puzzle_id"] for r in rows]
    assert not ("soccer-playmakers-00" in seated
                and "soccer-playmakers-00-daily-20260814" in seated), \
        "one board took two rungs under two ids"
    # And no board — primary or pooled — is shared across rungs.
    by_rung: dict[str, set] = {}
    for b in boards:
        by_rung.setdefault(b["puzzle_id"], set()).add(b["rung"])
    assert not [pid for pid, rungs in by_rung.items() if len(rungs) > 1]


def test_board_difficulty_is_the_lever_at_the_bottom_of_the_ladder():
    """The finding behind M24 D1, pinned because it is counter-intuitive and expensive to
    rediscover: a rung's bot score is driven by the BOARD as much as by `bot_skill`. Measured on
    a uniform board, worst possible bot (skill 0.05): 0.465 at difficulty 0.25 → 0.255 at 0.45.

    Consequence: on rung 1's deliberately-easy board there is no `bot_skill` that produces a low
    score, so the solver pins at minimum and the early rungs separate on board difficulty alone.
    Anyone "softening Bronze" by lowering skill will find it already is as low as it goes.
    """
    from tools.ingest import ladder

    keeps = [i < 4 for i in range(8)]
    worst = 0.05
    scores = [ladder.mean_score("keep4", [d] * 8, worst, keeps, trials=400)
              for d in (0.25, 0.45, 0.70)]
    assert scores == sorted(scores, reverse=True), f"harder boards must score lower: {scores}"
    assert scores[0] - scores[-1] > 0.25, (
        f"board difficulty should move the bot's score substantially, got {scores}")


def test_skill_still_moves_the_score_so_the_objective_has_a_lever():
    """The other half: `solve_bot_skill` bisects on score, which only works if score is
    monotone in skill. If this ever goes flat the solver silently returns whatever `lo` was."""
    from tools.ingest import ladder

    keeps = [i < 4 for i in range(8)]
    board = [0.35] * 8
    scores = [ladder.mean_score("keep4", board, sk, keeps, trials=400) for sk in (0.05, 0.3, 0.6)]
    assert scores == sorted(scores), f"score must rise with skill: {scores}"


def test_chance_is_where_keep4_scoring_sits_not_where_it_bottoms_out():
    """`FORMAT_SCORE_FLOOR['keep4'] == 0.5` marks CHANCE, not a hard floor. Below it the bot is
    systematically making the wrong call, which is a product decision (see M24 D1), not an
    impossibility — the original claim that four forced keeps made 4/8 unreachable was wrong."""
    from tools.ingest import ladder

    assert ladder.FORMAT_SCORE_FLOOR["keep4"] == 0.5
    sub_chance = ladder.mean_score("keep4", [0.7] * 8, 0.05, [i < 4 for i in range(8)], trials=400)
    assert sub_chance < 0.5, (
        "a hard board plus a minimum-skill bot should score BELOW chance — if this ever stops "
        f"being true the D1 reasoning needs revisiting, got {sub_chance:.2f}")


def test_the_ladder_comparable_no_longer_includes_speed():
    """Bot duels have no clock (M24 D2), so pace must not decide them. `win_rate` is a pure
    accuracy comparison now; if speed creeps back in, a rung can be lost on reading speed."""
    import inspect

    from tools.ingest import ladder
    body = "".join(line.split("#", 1)[0]
                   for line in inspect.getsource(ladder.win_rate).splitlines(keepends=True))
    assert "speed_adjusted(" not in body, "speed is back in the ladder comparable"


# ── Format placement follows each format's reachable floor ────────────────────

def test_each_format_only_guards_rungs_its_floor_can_serve():
    """A format placed below its reachable win-rate floor produces a flat spot, not a step.

    Measured floors (skill 1.0 against the reference player): whoami 0.75, keep4 0.27, grid
    0.18. So the formats have to appear in that order along the curve — whoami where it is
    still high, grid alone at the bottom. This pins the ordering rather than the specific
    cutoffs, which are expected to move as the curve is retuned.
    """
    from tools.ingest.ladder import (BOSS_EVERY, KEEP4_MAX_RUNG, RUNG_COUNT, WHOAMI_MAX_RUNG,
                                     mode_for)
    rungs = {r: mode_for(r) for r in range(1, RUNG_COUNT + 1)}

    # K4C4 is the app's best surface, so it is what a player meets first (BALLIQ_SPEC §1).
    assert rungs[1] == "keep4"

    whoami = [r for r, m in rungs.items() if m == "whoami"]
    keep4 = [r for r, m in rungs.items() if m == "keep4"]
    grid = [r for r, m in rungs.items() if m == "grid"]
    assert whoami and keep4 and grid, "every format should still appear somewhere"
    assert max(whoami) <= WHOAMI_MAX_RUNG
    assert max(keep4) <= KEEP4_MAX_RUNG
    assert max(whoami) < max(keep4) < max(grid), "formats must run in reachable-floor order"

    # Below the deepest format's stretch, only the format that reaches the bottom is left.
    assert all(m == "grid" for r, m in rungs.items() if r > KEEP4_MAX_RUNG)

    # A boss has to be a step up, and Who Am I? has no step left at that height.
    assert all(rungs[r] != "whoami" for r in range(BOSS_EVERY, RUNG_COUNT + 1, BOSS_EVERY))
