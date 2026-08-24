"""Tests for the headshot rehost tool.

The logic worth pinning here is the placeholder detection, because every failure mode it
guards against returns **HTTP 200** and is therefore invisible to a status-code check — that
is precisely how 90,092 baseball rows came to "have" a headshot that renders as a grey
silhouette.
"""
from __future__ import annotations

from tools.ingest.headshots import (
    MIN_REAL_BYTES,
    MLB_SILO_RE,
    NBA_STUB_MAX_BYTES,
    object_key,
    public_url,
)

MLB_URL = (
    "https://img.mlbstatic.com/mlb-photos/image/upload/"
    "w_213,d_people:generic:headshot:silo:current.png,q_auto:best,f_auto/"
    "v1/people/110001/headshot/67/current"
)


def test_silo_strip_turns_silent_fallback_into_a_real_404():
    """Cloudinary's `d_` parameter means "serve this if the asset is missing". Leaving it on
    makes every MLB player look like they have a photo."""
    stripped = MLB_SILO_RE.sub("", MLB_URL)
    assert "d_people:generic:headshot:silo" not in stripped
    # The rest of the transform chain must survive — dropping w_213 would change the rendition.
    assert "w_213" in stripped
    assert "q_auto:best" in stripped
    assert stripped.endswith("/v1/people/110001/headshot/67/current")


def test_silo_strip_is_a_noop_for_other_hosts():
    espn = "https://a.espncdn.com/i/headshots/nba/players/full/1035.png"
    assert MLB_SILO_RE.sub("", espn) == espn


def test_object_key_is_stable_and_content_addressed():
    a = object_key("nfl", "https://example.com/x.png", "image/png")
    b = object_key("nfl", "https://example.com/x.png", "image/png")
    assert a == b, "same source must map to the same object, or re-runs duplicate storage"
    assert a.startswith("nfl/") and a.endswith(".png")


def test_object_key_separates_distinct_sources_and_sports():
    assert object_key("nfl", "https://example.com/a.png", "image/png") != object_key(
        "nfl", "https://example.com/b.png", "image/png"
    )
    assert object_key("nba", "https://example.com/a.png", "image/png") != object_key(
        "nfl", "https://example.com/a.png", "image/png"
    )


def test_object_key_extension_follows_content_type():
    assert object_key("nfl", "u", "image/jpeg").endswith(".jpg")
    assert object_key("nfl", "u", "image/png").endswith(".png")
    assert object_key("nfl", "u", "application/octet-stream").endswith(".img")


def test_public_url_shape_matches_the_storage_contract():
    url = public_url("https://x.supabase.co", "nfl/abc.png")
    assert url == "https://x.supabase.co/storage/v1/object/public/player-headshots/nfl/abc.png"
    # The client rewrites exactly this marker to the render/transform endpoint
    # (AppImagePipeline.transformed); if it changes, headshots silently stop being resized.
    assert "/storage/v1/object/public/" in url


def test_placeholder_thresholds_separate_stubs_from_real_photos():
    """Measured 2026-08-24: cdn.nba.com serves a ~12.4 KB generic stub for unknown ids while
    real headshots run 180–280 KB. The threshold has to sit between those, with room."""
    assert NBA_STUB_MAX_BYTES > 12_430
    assert NBA_STUB_MAX_BYTES < 150_000
    assert MIN_REAL_BYTES < NBA_STUB_MAX_BYTES
