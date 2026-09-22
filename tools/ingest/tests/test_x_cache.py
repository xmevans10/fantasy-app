"""The X read cache — because a cache miss here costs real money."""
from __future__ import annotations

from tools.marketing import x_cache


def test_roundtrip_and_expiry(tmp_path, monkeypatch):
    monkeypatch.setattr(x_cache, "PATH", tmp_path / "cache.json")
    assert x_cache.get("uid:NFL", 3600) is None
    x_cache.put("uid:NFL", "19426551")
    assert x_cache.get("uid:NFL", 3600) == "19426551"
    assert x_cache.get("uid:NFL", -1) is None          # negative ttl = already stale


def test_corrupt_cache_degrades_to_miss(tmp_path, monkeypatch):
    p = tmp_path / "cache.json"
    p.write_text("{not json")
    monkeypatch.setattr(x_cache, "PATH", p)
    assert x_cache.get("k", 60) is None
    x_cache.put("k", 1)                                 # and a put still succeeds
    assert x_cache.get("k", 60) == 1
