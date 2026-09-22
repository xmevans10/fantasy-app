"""OAuth 1.0a signing. The base string is pinned to the worked example in X's signing docs, and
the algorithm is independently verified against X's live `oauth/request_token` endpoint (a real
200 with `oauth_callback_confirmed=true`), which uses the identical HMAC-SHA1 check.
"""
from __future__ import annotations

from tools.marketing import x_oauth1

# X's documented example (public sample consumer key/secret and access token/secret).
_CONSUMER_SECRET = "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw"
_TOKEN_SECRET = "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE"
_URL = "https://api.twitter.com/1.1/statuses/update.json"
_PARAMS = {
    "oauth_consumer_key": "xvz1evFS4wEEPTGEFPHBog",
    "oauth_nonce": "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg",
    "oauth_signature_method": "HMAC-SHA1",
    "oauth_timestamp": "1318622958",
    "oauth_token": "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb",
    "oauth_version": "1.0",
    "status": "Hello Ladies + Gentlemen, a signed OAuth request!",
    "include_entities": "true",
}
_EXPECTED_BASE = (
    "POST&https%3A%2F%2Fapi.twitter.com%2F1.1%2Fstatuses%2Fupdate.json&"
    "include_entities%3Dtrue%26oauth_consumer_key%3Dxvz1evFS4wEEPTGEFPHBog"
    "%26oauth_nonce%3DkYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg"
    "%26oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D1318622958"
    "%26oauth_token%3D370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb"
    "%26oauth_version%3D1.0%26status%3DHello%2520Ladies%2520%252B%2520Gentlemen"
    "%252C%2520a%2520signed%2520OAuth%2520request%2521"
)


def test_base_string_matches_the_documented_example():
    assert x_oauth1.signature_base_string("POST", _URL, _PARAMS) == _EXPECTED_BASE


def test_signature_is_deterministic():
    sig = x_oauth1.sign("POST", _URL, _PARAMS, _CONSUMER_SECRET, _TOKEN_SECRET)
    assert sig == "hCtSmYh+iHYCEqBWrE7C7hYmtUk="


def test_encoding_uses_percent20_not_plus_and_sorts_params():
    # The param string is encoded once per value and once as a whole, so a space shows as
    # %2520; either way it must never become "+".
    base = x_oauth1.signature_base_string("GET", "https://api.twitter.com/x", {"b": "a b", "a": "1"})
    assert "%2520" in base and "+" not in base
    assert base.endswith(x_oauth1._enc("a=1&b=a%20b"))


def test_header_omits_the_token_when_two_legged_and_keeps_extra_params():
    header = x_oauth1.auth_header("POST", "https://api.twitter.com/oauth/request_token",
                                  "ck", "cs", "", "", nonce="n", timestamp="1",
                                  extra={"oauth_callback": "oob"})
    assert header.startswith("OAuth ")
    assert "oauth_token=" not in header                       # 2-legged: no token
    assert 'oauth_callback="oob"' in header
    assert 'oauth_signature_method="HMAC-SHA1"' in header


def test_header_includes_the_token_for_user_context():
    header = x_oauth1.auth_header("POST", x_oauth1.UPLOAD_URL, "ck", "cs", "tok", "ts",
                                  nonce="n", timestamp="1")
    assert 'oauth_token="tok"' in header and 'oauth_nonce="n"' in header


def test_query_params_are_signed_but_not_placed_in_the_header():
    """A GET's query string must be in the signature (omitting it is the 401 we hit) but must not
    leak into the Authorization header."""
    base = x_oauth1.auth_header("GET", "https://api.x.com/2/tweets/1", "ck", "cs", "tok", "ts",
                                nonce="n", timestamp="1")
    with_query = x_oauth1.auth_header("GET", "https://api.x.com/2/tweets/1", "ck", "cs", "tok",
                                      "ts", nonce="n", timestamp="1",
                                      sign_extra={"tweet.fields": "public_metrics"})
    assert base != with_query                       # the query changed the signature
    assert "public_metrics" not in with_query       # but is not in the header
