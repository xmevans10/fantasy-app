

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
