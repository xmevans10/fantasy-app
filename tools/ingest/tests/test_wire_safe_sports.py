"""The release gate that stops a newly-ingested sport reaching shipped clients too early.

The failure this exists to prevent, reproduced empirically on 2026-09-06: `Sport` on the
client is a plain `String` raw-value enum with no unknown-case fallback, and the archive fetch
carries NO sport predicate when the user is on the "All" filter — it decodes the pool as an
ARRAY under `try?`. One row naming a sport an installed build has never heard of throws, the
whole array comes back nil, and that user's archive silently degrades to stale cache or the
bundled JSON. Same mechanism `validate._VALID_KINDS` documents for `ClueKind`.

So "we have the data" and "shipped clients can read it" are two different questions, and every
mint path has to ask the second one.
"""
from pathlib import Path

from tools.ingest import journeyman
from tools.ingest.daily_journeyman import SPORTS as JOURNEYMAN_SPORTS
from tools.ingest.daily_puzzle import SPORTS as KEEP4_SPORTS
from tools.ingest.daily_whoami import SPORTS as WHOAMI_SPORTS
from tools.ingest.validate import _VALID_SPORTS, WIRE_SAFE_SPORTS


def test_wire_safe_is_a_subset_of_what_we_actually_ingest():
    """The gate narrows; it must never name a sport the pipeline cannot produce."""
    assert WIRE_SAFE_SPORTS <= _VALID_SPORTS


def test_every_daily_mint_path_respects_the_gate():
    """All four formats publish to the same `puzzles` table, so one ungated path is enough to
    break the archive — `daily_journeyman` in particular derives its list from `MIN_STINTS`
    (a data fact about club careers) rather than from the other two."""
    for label, sports in (("keep4", KEEP4_SPORTS), ("whoami", WHOAMI_SPORTS),
                          ("journeyman", JOURNEYMAN_SPORTS)):
        assert set(sports) <= WIRE_SAFE_SPORTS, f"{label} mints outside the gate: {sports}"


def test_journeyman_is_gated_without_losing_its_own_club_career_rule():
    """The gate is an intersection, not a replacement: tennis has no clubs and must stay out
    on its own merits even if it is wire-safe."""
    assert "tennis" in WIRE_SAFE_SPORTS and "tennis" not in JOURNEYMAN_SPORTS
    assert set(JOURNEYMAN_SPORTS) == set(journeyman.MIN_STINTS) & WIRE_SAFE_SPORTS


def test_grid_skips_gated_sports_even_when_named_explicitly(capsys):
    """The workflows pass a literal sport list on the command line, so gating only inside the
    daily modules would leave the Grid free to publish rows shipped clients cannot decode."""
    from tools.ingest import main as ingest_main

    gated = sorted(_VALID_SPORTS - WIRE_SAFE_SPORTS)
    if not gated:
        return          # nothing currently held back; the guard below has nothing to prove
    assert ingest_main.run_grid(gated, upsert=False, dry_run=True) == 0
    assert "not yet wire-safe" in capsys.readouterr().out


def test_m31_sports_are_ingested_but_held_back():
    """Documents the CURRENT release state. When hockey/F1 ship, add them to
    WIRE_SAFE_SPORTS and update this test in the same change — it should be a deliberate act,
    not something that drifts."""
    assert {"hockey", "f1"} <= _VALID_SPORTS, "M31 data should be fully ingested"
    assert not ({"hockey", "f1"} & WIRE_SAFE_SPORTS), "M31 sports not yet released to clients"


# ── The release transition, not just the gate ─────────────────────────────────
#
# The gate above decides what may be MINTED. It says nothing about the two other halves of
# actually releasing a sport, and both were wrong at once on 2026-09-07: the app announced NHL
# and F1 in 1.8.4 while the gate held them back, and no client had any way to receive a new
# sport safely even after the gate opened. So the release had an announcement with no content
# behind it, and no path to putting content behind it that did not break installed builds.
#
# These two tests pin the halves the Python gate cannot see, by reading the Swift. Crossing
# languages in a test is worth it here precisely because nothing else can: the ingest pipeline
# and the app are released on separate clocks, and that gap is the whole failure mode.

_ROOT = Path(__file__).resolve().parents[3]
UPDATE_NOTES = _ROOT / "BallIQ" / "Features" / "Updates" / "UpdateNotes.swift"
REMOTE_REPO = _ROOT / "BallIQ" / "Data" / "Repositories" / "RemotePuzzleRepository.swift"

# The slide artwork that announces a sport, and the sports it claims have arrived. A slide may
# only be keyed into a shipping release once every sport it names is minting.
ANNOUNCEMENTS = {"opm-new-sports": {"hockey", "f1"}}


def _shipping_slides(swift: str) -> str:
    """The body of `UpdateNotes.byVersion` — the slides a released build actually shows.

    Deliberately not the whole file: an announcement parked outside the dictionary (see
    `newSportsSlide`) is written but unshipped, which is exactly the state this enforces.
    """
    body = swift.split("static let byVersion", 1)[1]
    return body.split("static let deliberatelySilent", 1)[0]


def test_the_app_never_announces_a_sport_the_pipeline_is_still_holding_back():
    """An upgrader who is told about NHL and F1 goes looking for them. If the gate is closed,
    they find nothing, and the app has lied to them on the strength of a release note."""
    shipping = _shipping_slides(UPDATE_NOTES.read_text(encoding="utf-8"))
    for artwork, sports in ANNOUNCEMENTS.items():
        if f'artwork: "{artwork}"' not in shipping:
            continue
        missing = sorted(sports - WIRE_SAFE_SPORTS)
        assert not missing, (
            f"UpdateNotes.byVersion ships `{artwork}`, which announces {sorted(sports)}, but "
            f"{missing} are not in WIRE_SAFE_SPORTS. Open the gate in the same change, or keep "
            "the slide out of byVersion until it is open.")


def test_a_client_asks_only_for_sports_it_can_decode():
    """The gate is a stopgap for a client that asks for everything. The fix is the client asking
    for what it knows: with a sport predicate on the "All" fetch, publishing a new sport cannot
    nil an installed build's whole archive, and the gate becomes a scheduling decision rather
    than the only thing preventing an outage.

    Pinned from the Python side because this file is where the reason lives, and because the
    consequence of it regressing lands here: without it, `WIRE_SAFE_SPORTS` can never open.
    """
    swift = REMOTE_REPO.read_text(encoding="utf-8")
    assert "Sport.decodableFilterValue" in swift, (
        "RemotePuzzleRepository no longer sends a sport allowlist on the All filter. Without it "
        "the archive fetch asks for rows the build may not decode, and one unknown sport nils "
        "the entire array.")
