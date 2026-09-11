"""F1 constructor identity — the display name and crest behind an `f1` `team_abbr`.

Why this exists as its own module rather than a branch of `teams.py`'s US-sports loop: F1
crests are the one team-identity case none of the existing sources cover.

* ESPN is not an option. Its `/sports/racing/f1/teams` payload carries **no `logos` array and
  no stable `abbreviation`** (verified 2026-09-03), and it lists only the ~11 constructors on
  the CURRENT grid — Brabham, Tyrrell and Team Lotus were never there at all. That is why
  `Sport.espnLeagueSlug` returns nil for F1 while hockey gets "nhl".
* A hardcoded map is not an option either. There are 214 constructors across 1950-present and
  their liveries are the thing that changes most often about them, so a frozen table would be
  wrong more often than right (and `TeamColors.swift` deliberately ships no F1 table for the
  same reason) — EXCEPT for the small, explicitly-curated exception described below.

What IS available: Ergast gives every constructor a `url` pointing at its own Wikipedia page,
which is an authoritative mapping rather than a guessed title — worth stressing, because
guessing titles is exactly what fails here ("Brabham" and "Tyrrell_Racing" both miss, while
Ergast's own URLs for those constructors resolve).

## Four crest sources, tried in order (`resolve_crest`)

1. **`data/f1_constructor_logo_overrides.csv`** — a small hand-verified table, the same shape
   as soccer's `data/soccer_club_code_overrides.csv`. Not a coverage backfill: every entry here
   exists because the automatic sources resolve to something the *wrong kind* of image, not
   nothing. Confirmed live: Ferrari's and Williams's Wikipedia infobox `Logo` fields are the
   CURRENT title-sponsor lockup ("Scuderia Ferrari HP", "Atlassian Williams F1 Team") — real
   logo-shaped SVGs, so no dimension/transparency heuristic tells them apart from a genuine
   marque crest, which is exactly the "cannot be told apart programmatically" case the M23
   brief called out. Surtees is here for a different reason: Ergast's own URL
   (`/wiki/Surtees`) is a disambiguation page, not the team's article, verified live
   2026-09-05 (`{{TOCright}}`, "Surtees may refer to:" — no infobox, no lead image, no
   Wikidata claims because there IS no page here to have them). All three overrides link a
   *plain marque* crest with no sponsor branding: Ferrari's Prancing Horse, Williams's classic
   double-chevron "W", Surtees's own wordmark from `Surtees_Racing_Organisation`.
2. **Wikidata's logo property (P154)** — unambiguous when present, unchanged from before.
3. **The article's own infobox `Logo` field** (NEW). Ergast's Wikipedia URL is an article, but
   the article's LEAD IMAGE (source 4) is often unrelated to the team's identity — Maserati's
   page leads with a road car, not a crest — while its `{{Former F1 team}}`/`{{Infobox F1
   team}}` infobox has an editor-asserted `Logo =` field most of the time. Checked live against
   the four constructors the prior version of this module named as having no crest by ANY
   source: Brabham, Tyrrell, Jordan and Minardi ALL resolve here (`Brabham91.png`,
   `Tyrrell.svg`, `Jordan Grand Prix logo.png`, `Minardi F1 Team.svg`) — none had a P154 claim
   or a logo-shaped lead image. This single source is most of this module's coverage gain.
   The infobox field appears in three textual shapes across different team pages —
   `[[File:X.svg|250px]]`, bare `File:X.png`, and bare `X.svg` with no prefix at all — all three
   confirmed live, which is why `_parse_infobox_logo_field`'s regex treats the `[[` and
   `File:` prefixes as independently optional rather than assuming one fixed form.
4. **The article's lead image** (`pageimages`/REST summary API) — last resort, and the source
   most likely to be a photograph of a car or driver rather than a mark. Kept because it is
   still sometimes the ONLY resolvable source (BRM, Arrows).

Whichever source resolves, the actual bytes are always fetched through `en.wikipedia.org`'s own
`imageinfo` query rather than assumed to live on Commons: MediaWiki's foreign-repo resolution
means one call correctly reaches a locally-uploaded (often non-free/fair-use, e.g. most current
team sponsor logos) file OR a Commons-shared one transparently, and returns real
width/height/mime alongside the URL — useful for anyone auditing a resolved crest's shape later,
even though this module does not attempt to use pixel geometry as an automatic accept/reject
gate (see the module-level note below on why not).

## Why no automatic photo-vs-logo shape heuristic

A first pass at this module considered scoring every resolved candidate by aspect ratio/
transparency/format and picking the most "logo-shaped" one automatically. It was dropped after
Ferrari's and Williams's infobox logos turned out to be wide, transparent, vector SVGs — exactly
as logo-shaped as a correct marque crest by every dimension/format signal, because they ARE
logos, just the wrong (sponsor-branded) one. A shape heuristic cannot see brand history, so it
would have been a fragile, mostly-decorative check dressed up as a fix. The two real problems
this module solves — a photograph resolving instead of a crest (Maserati), and a correct-KIND
but wrong-ERA crest resolving (Ferrari, Williams) — are solved by, respectively, adding a
same-page-authoritative source (#3 above) and a small hand-verified override table (#1 above).

## Coverage has a real ceiling, and it is not a backfill waiting to happen

Even with all four sources, some historic constructors have no freely-hosted crest on Wikimedia
at all. That is a polish gap rather than a blocker, and deliberately so: a Journeyman stint row
renders crest + club NAME + years, and the name is always present. Per M22's own reasoning the
name is what carries fairness and the crest only carries recognition, so "Kuzma 1955-1956" over
a neutral badge is a completely playable row. This is the opposite of the headshot rule (M16: no
photo, no row) because a faceless *player* card has nothing left to identify, while a
crest-less *club* row still says exactly which club it is.

## Licensing: a known, quantified exposure — read before extending this

Wikimedia is two different things and the URL says which. `upload.wikimedia.org/wikipedia/
commons/...` is Wikimedia Commons, which is free-licensed. `upload.wikimedia.org/wikipedia/
en/...` is an English-Wikipedia LOCAL upload, which is where **non-free "fair use"** logos
live — Wikipedia claims fair use for encyclopedic display on its own article pages, and that
claim does not transfer to us rehosting the file and serving it from our CDN in a paid app.

Measured 2026-09-05 over the 164 constructors in our catalog: **83 crests resolve from Commons
(free) and 55 from enwiki-local (non-free)**, the latter covering 935 of 2,557 driver-seasons.
Ferrari (241 driver-seasons), BRM, Brabham, Renault, Red Bull and Jordan are all in the
non-free group. Restricting to Commons would be legally cleanest and would cost roughly a third
of the volume-weighted coverage, Ferrari included.

This is NOT a new exposure introduced by F1, and that is why it is documented rather than
unilaterally "fixed" here: `teams.py` already rehosts ESPN's copyrighted club crests for NFL,
NBA, MLB, hockey and soccer under exactly the same posture, and those ship in production today.
F1 follows the established practice. The decision of whether that posture is right belongs to
the product owner and applies to all seven sports at once, not to this module alone. If a
free-only policy is ever adopted, the discriminator is the `/wikipedia/en/` vs
`/wikipedia/commons/` path segment, which is a one-line test.

Also worth knowing when extending: **P154 is not infallible.** ALTA's Wikidata logo claim
points at `Alta_engine.jpg`, a photograph of an engine. Low volume (3 driver-seasons), so no
override was added, but do not treat a P154 hit as self-evidently a crest.

Run:  python -m tools.ingest.providers.f1_constructors [--dry-run]
"""
from __future__ import annotations

import argparse
import csv
import re
import time
import urllib.parse
from pathlib import Path

from .. import logos
from .http import fetch_json, is_cached
from .f1_ergast import load_seasons
from .wikimedia import WIKI_DELAY

_CONSTRUCTORS_URL = "https://api.jolpi.ca/ergast/f1/constructors/?format=json&limit=100&offset={offset}"
_SUMMARY_URL = "https://en.wikipedia.org/api/rest_v1/page/summary/{title}"
_PAGEPROPS_URL = ("https://en.wikipedia.org/w/api.php?action=query&prop=pageprops"
                  "&ppprop=wikibase_item|disambiguation&titles={title}&format=json")
_PARSE_URL = ("https://en.wikipedia.org/w/api.php?action=parse&page={title}&prop=wikitext"
              "&section=0&format=json&redirects=1")
_IMAGEINFO_URL = ("https://en.wikipedia.org/w/api.php?action=query&titles=File:{name}"
                  "&prop=imageinfo&iiprop=url|size|mime&format=json")
_ENTITY_URL = "https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"
_COMMONS_FILE = "https://commons.wikimedia.org/wiki/Special:FilePath/{name}?width=500"
_WBSEARCH_URL = ("https://www.wikidata.org/w/api.php?action=wbsearchentities&search={q}"
                 "&language=en&format=json&limit=10")
_UA = {"User-Agent": "balliq-ingest (data pipeline; contact: xmevans10@gmail.com)"}
_TTL = 24 * 90

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
OVERRIDES_PATH = DATA_DIR / "f1_constructor_logo_overrides.csv"

# A page's Wikidata description that reads as one of these is a real racing team/constructor
# entity — the signal used to pick the right search result when Ergast's own URL points at a
# disambiguation page (Surtees) rather than the article, instead of guessing a title outright.
_RACING_HINTS = ("formula one", "racing team", "grand prix", "constructor",
                 "motor racing", "racing car manufacturer")

# The infobox `Logo` parameter shows up in three shapes across different team pages, all
# confirmed live: `[[File:X.svg|250px]]` (Tyrrell, Surtees), bare `File:X.png` (Red Bull,
# Cooper), and a bare filename with no prefix at all (Brabham: `Logo = Brabham91.png`). Both
# the `[[` and `File:` prefixes are therefore optional, not alternatives to pick one of.
_INFOBOX_LOGO_RE = re.compile(r"\|\s*[Ll]ogo\s*=\s*(?:\[\[)?(?:[Ff]ile:)?([^\]|\n]+)")


def fetch_constructors() -> list[dict]:
    """Every constructor Ergast knows, with its name and Wikipedia URL."""
    out: list[dict] = []
    offset = 0
    while True:
        data = fetch_json(_CONSTRUCTORS_URL.format(offset=offset),
                          cache_key=f"f1_constructors_{offset}.json", ttl_hours=_TTL)["MRData"]
        out.extend(data.get("ConstructorTable", {}).get("Constructors", []))
        total = int(data.get("total") or 0)
        offset += 100
        if offset >= total:
            return out


def _page_title(url: str) -> str:
    """'https://en.wikipedia.org/wiki/Team_Lotus' -> 'Team_Lotus'."""
    return urllib.parse.unquote(url.rstrip("/").rsplit("/", 1)[-1])


def _wiki_json(url: str, cache_key: str) -> dict | None:
    """`fetch_json` against a Wikimedia endpoint, rate-limited exactly like
    `wikimedia._lookup` on every UNCACHED call, and `None` (never an exception) on any
    failure — every caller here treats "no candidate from this source" as a normal outcome,
    not something to abort a whole constructor's resolution over.

    Omitting the delay is not a style slip: the first run of this module resolved only 28 of
    164 constructors because Wikipedia throttled an undelayed burst and every throttled
    response came back indistinguishable from "no image"."""
    was_cached = is_cached(cache_key, _TTL)
    try:
        data: dict | None = fetch_json(url, headers=_UA, cache_key=cache_key, ttl_hours=_TTL)
    except Exception:  # noqa: BLE001 — 404/disambiguation/network: just no candidate
        data = None
    if not was_cached:
        time.sleep(WIKI_DELAY)
    return data


def _page_qid_and_disambig(title: str) -> tuple[str | None, bool]:
    """This Wikipedia page's Wikidata id, and whether the page itself is a disambiguation
    page rather than an article. The second element is what lets `_effective_title_and_qid`
    tell "Surtees has no crest" apart from "Ergast's URL for Surtees isn't Surtees's page"."""
    data = _wiki_json(_PAGEPROPS_URL.format(title=urllib.parse.quote(title)),
                      f"wiki_pageprops_{title.lower()}.json")
    if not data:
        return None, False
    pages = data.get("query", {}).get("pages", {})
    for page in pages.values():
        props = page.get("pageprops", {})
        return props.get("wikibase_item"), "disambiguation" in props
    return None, False


def _search_qid_by_name(name: str) -> str | None:
    """When Ergast's own page turns out to be a disambiguation page, search Wikidata by the
    constructor's plain name and take the first result whose description reads as a real
    racing team/constructor. This is NOT a general title-guessing fallback — every other
    constructor still resolves through Ergast's own URL untouched, and this path only
    triggers for the verified disambiguation case (Surtees)."""
    data = _wiki_json(_WBSEARCH_URL.format(q=urllib.parse.quote(name)),
                      f"wd_search_{name.lower()}.json")
    if not data:
        return None
    for result in data.get("search", []):
        desc = (result.get("description") or "").lower()
        if any(hint in desc for hint in _RACING_HINTS):
            return result.get("id")
    return None


def _qid_enwiki_title(qid: str) -> str:
    data = _wiki_json(_ENTITY_URL.format(qid=qid), f"wd_entity_{qid}.json")
    if not data:
        return ""
    entity = data.get("entities", {}).get(qid, {})
    return entity.get("sitelinks", {}).get("enwiki", {}).get("title", "")


def _effective_title_and_qid(name: str, wiki_url: str) -> tuple[str, str | None]:
    """The Wikipedia title and Wikidata id every other resolver in this module should use.
    Ordinarily just Ergast's own URL, resolved to its Wikidata id. Substituted only when that
    page is a disambiguation page or has no Wikidata id at all."""
    title = _page_title(wiki_url)
    if not title:
        return "", None
    qid, is_disambig = _page_qid_and_disambig(title)
    if is_disambig or not qid:
        if alt_qid := _search_qid_by_name(name):
            if alt_title := _qid_enwiki_title(alt_qid):
                return alt_title, alt_qid
    return title, qid


def _file_source(filename: str) -> str:
    """A bare Commons/enwiki filename (as found in an infobox `Logo =` field) -> its real
    upload URL, via en.wikipedia's own `imageinfo` rather than Commons's `Special:FilePath`:
    MediaWiki's foreign-repo resolution reaches a locally-uploaded file (often non-free/
    fair-use — most current team sponsor logos, e.g. Jordan's, are exactly this) or a
    Commons-shared one (Maserati's, Minardi's, Tyrrell's) through the same one call."""
    if not filename:
        return ""
    data = _wiki_json(_IMAGEINFO_URL.format(name=urllib.parse.quote(filename)),
                      f"wiki_imageinfo_{filename.lower()}.json")
    if not data:
        return ""
    for page in data.get("query", {}).get("pages", {}).values():
        info = (page.get("imageinfo") or [None])[0]
        if info and info.get("url"):
            # Wikipedia appends tracking query params to some image URLs; they break the
            # rehost's content-type sniff and are not part of the object's identity.
            return info["url"].split("?", 1)[0]
    return ""


def _parse_infobox_logo_field(wikitext: str) -> str:
    """Pure regex extraction, kept separate from the network call so it's unit-testable
    against the three real shapes an infobox `Logo` field takes (see the regex's own
    comment) with no fixture beyond a wikitext string."""
    match = _INFOBOX_LOGO_RE.search(wikitext)
    return match.group(1).strip() if match else ""


def _infobox_logo(title: str) -> str:
    """The Wikipedia article's OWN infobox `Logo` field — an editor-asserted "this is the
    crest", unlike the lead image (`_lead_image`) which is merely the page's most prominent
    picture and is frequently unrelated (a car, a driver, a race photo)."""
    if not title:
        return ""
    data = _wiki_json(_PARSE_URL.format(title=urllib.parse.quote(title)),
                      f"wiki_infobox_{title.lower()}.json")
    if not data:
        return ""
    wikitext = (data.get("parse") or {}).get("wikitext", {}).get("*", "")
    return _file_source(_parse_infobox_logo_field(wikitext))


def _lead_image(title: str) -> str:
    """The Wikipedia lead image for a constructor page, or "" when it has none. Last resort:
    of the four sources this module tries, it is the one most likely to be a photograph
    rather than a crest (Maserati's own page leads with a road car)."""
    if not title:
        return ""
    data = _wiki_json(_SUMMARY_URL.format(title=urllib.parse.quote(title)),
                      f"wiki_summary_{title.lower()}.json")
    if not data:
        return ""
    source = ((data.get("originalimage") or data.get("thumbnail") or {}).get("source")) or ""
    return source.split("?", 1)[0]


def _wikidata_logo(qid: str | None) -> str:
    """This entity's Wikidata **logo image** (P154), or "".

    A second, independent source because neither one alone is close to sufficient. The
    Wikipedia lead image is often a car photo rather than a crest, and P154 is populated for
    only a minority of constructors."""
    if not qid:
        return ""
    data = _wiki_json(_ENTITY_URL.format(qid=qid), f"wd_entity_{qid}.json")
    if not data:
        return ""
    try:
        claims = data["entities"][qid]["claims"]
        filename = claims["P154"][0]["mainsnak"]["datavalue"]["value"]
    except Exception:  # noqa: BLE001 — no entity / no logo claim
        return ""
    return _COMMONS_FILE.format(name=urllib.parse.quote(filename))


def _load_overrides() -> dict[str, str]:
    if not OVERRIDES_PATH.exists():
        return {}
    with OVERRIDES_PATH.open(encoding="utf-8", newline="") as f:
        return {row["constructor_id"]: row["source_url"] for row in csv.DictReader(f)}


_OVERRIDES: dict[str, str] = _load_overrides()


def reload_overrides() -> None:
    """Re-read `f1_constructor_logo_overrides.csv` from disk (tests monkeypatch
    `OVERRIDES_PATH` then call this to pick up a fixture file)."""
    global _OVERRIDES
    _OVERRIDES = _load_overrides()


def resolve_crest(constructor_id: str, name: str, wiki_url: str) -> str:
    """The crest source URL for one constructor, or "" if nothing resolves.

    Resolution order — see the module docstring's "Four crest sources" section for the
    live evidence behind each step:
      1. `f1_constructor_logo_overrides.csv` (hand-verified sponsor-lockup / road-car /
         disambiguation-page fixes — always wins outright when present).
      2. Wikidata's logo property (P154).
      3. The article's own infobox `Logo` field.
      4. The article's lead image.
    """
    if override := _OVERRIDES.get(constructor_id):
        return override
    title, qid = _effective_title_and_qid(name, wiki_url)
    if not title:
        return ""
    return _wikidata_logo(qid) or _infobox_logo(title) or _lead_image(title)


def build_identity(rehost: bool = True) -> list[dict]:
    """`teams`-table rows for every constructor that appears in our own catalog.

    Scoped to the catalog rather than all 214 Ergast constructors: a constructor no driver-season
    in `player_seasons` references is a row nothing can ever look up."""
    in_catalog = {s.team_abbr for s in load_seasons()}
    rows: list[dict] = []
    resolved = 0
    crests = 0
    for c in fetch_constructors():
        abbr = c["constructorId"].upper()
        if abbr not in in_catalog:
            continue
        source = resolve_crest(c["constructorId"], c.get("name", ""), c.get("url", ""))
        if source:
            resolved += 1
        logo_url = logos.rehost(source, logos.logo_key("f1", "", abbr)) if (source and rehost) else None
        if logo_url:
            crests += 1
        rows.append({
            "sport": "f1",
            "team_abbr": abbr,
            "league": "",
            "full_name": c.get("name", ""),
            "logo_url": logo_url,
            # No color source exists for historic constructors, and inventing one would be
            # worse than the neutral fallback `TeamColors` already draws.
            "primary_color": None,
            "secondary_color": None,
        })
    if rehost:
        print(f"[f1-teams] {len(rows)} constructors in catalog, {crests} with a rehosted crest")
    else:
        # `--dry-run` skips the actual upload, but the whole point of running it is to see
        # how many WOULD resolve — reporting 0 unconditionally here (an earlier version of
        # this function did exactly that, by gating the count on `logo_url` instead of
        # `source`) makes `--dry-run` useless for measuring coverage.
        print(f"[f1-teams] {len(rows)} constructors in catalog, {resolved} with a resolved "
              f"crest source (dry-run: not rehosted)")
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="Build F1 constructor identity rows")
    ap.add_argument("--dry-run", action="store_true", help="resolve crests but skip the rehost")
    args = ap.parse_args()
    rows = build_identity(rehost=not args.dry_run)
    if args.dry_run:
        # `logo_url` is always None in a dry run (nothing was rehosted) — print the resolved
        # SOURCE per constructor instead, or the sample would misleadingly read "(no crest)"
        # for every single row regardless of whether one actually resolved.
        by_abbr = {c["constructorId"].upper(): c for c in fetch_constructors()}
        for r in rows[:10]:
            c = by_abbr.get(r["team_abbr"], {})
            source = resolve_crest(c.get("constructorId", ""), c.get("name", ""), c.get("url", ""))
            print(f"  {r['team_abbr']:16s} {r['full_name']:28s} {source or '(no crest)'}")
    else:
        for r in rows[:10]:
            print(f"  {r['team_abbr']:16s} {r['full_name']:28s} {r['logo_url'] or '(no crest)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
