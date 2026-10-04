"""Image billing regressions: scope public origins; never warm paid transforms."""
from tools.ingest.warm_cdn import _cdn_url
from tools.ingest.headshots import warm_transforms

ORIGIN = "https://nhccgufqwndtoasdbkhc.supabase.co/storage/v1/object/public/"
CDN = "https://playbook-images.xmevans10.workers.dev/v1/"

def test_cdn_preserves_encoded_nested_path_and_is_idempotent():
    for bucket in ("player-headshots", "team-logos"):
        path = bucket + "/soccer/england/a%20b.png"
        assert _cdn_url(ORIGIN + path) == CDN + path
        assert _cdn_url(CDN + path) == CDN + path

def test_cdn_rejects_private_other_project_and_credentialed_sources():
    for url in (
        ORIGIN + "avatars/a.png",
        ORIGIN + "team-logos/a.png?token=secret",
        ORIGIN.replace("nhccgufqwndtoasdbkhc", "other") + "team-logos/a.png",
        ORIGIN.replace("https://", "https://user:secret@") + "team-logos/a.png",
        ORIGIN.replace("/object/public/", "/object/sign/") + "team-logos/a.png",
    ):
        assert _cdn_url(url) is None

def test_retired_transform_warm_never_uses_network(monkeypatch):
    import urllib.request
    def forbidden(*args, **kwargs):
        raise AssertionError("retired command must never request paid transforms")
    monkeypatch.setattr(urllib.request, "urlopen", forbidden)
    assert warm_transforms(workers=12, limit=None) == 0
