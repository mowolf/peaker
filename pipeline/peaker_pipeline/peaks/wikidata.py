"""Peaks from Wikidata (CC0): multilingual names, elevation, prominence, links.

Queried per 1°×1° tile, independent of countries, so results are cached per tile
and shared between packs. Two steps keep each request under the query
service's 60 s limit:

1. ``ITEMS_QUERY``: mountain-like items inside the tile, via the spatial index
   (``wikibase:box``). Dense tiles (cities) can still time out; those cells are
   split into quarters, up to ``MAX_SPLIT`` levels deep, then skipped with a warning.
2. ``DETAILS_QUERY``: names, elevation, prominence and links for batches of items.

Measured (Nov 2026): alpine tiles take 10–16 s for step 1. "Class first" or
"country first" query shapes time out (see docs/decisions.md).
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

import requests

from ..http import USER_AGENT
from ..tiles import TileId
from .model import Peak

log = logging.getLogger(__name__)

ENDPOINT = "https://query.wikidata.org/sparql"
LANGS = ["en", "de", "fr", "it", "es", "pt", "nl", "pl", "cs", "sk", "sl", "hr", "sv", "nb", "fi",
         "ja", "zh", "ko", "ru", "uk", "ne", "hi", "tr", "el", "rm", "ca", "eu"]
# mountain, summit, volcano, hill (incl. subclasses)
ROOT_CLASSES = ["Q8502", "Q207326", "Q8072", "Q54050"]
MAX_SPLIT = 3
DETAILS_BATCH = 300

ITEMS_QUERY = """
SELECT DISTINCT ?item ?lat ?lon ?class WHERE {{
  SERVICE wikibase:box {{
    ?item wdt:P625 ?coord .
    bd:serviceParam wikibase:cornerSouthWest "Point({west} {south})"^^geo:wktLiteral .
    bd:serviceParam wikibase:cornerNorthEast "Point({east} {north})"^^geo:wktLiteral .
  }}
  ?item wdt:P31 ?class . ?class wdt:P279* ?root . VALUES ?root {{ {roots} }}
  BIND(geof:latitude(?coord) AS ?lat) BIND(geof:longitude(?coord) AS ?lon)
}}
"""

DETAILS_QUERY = """
SELECT ?item ?elev ?prom ?osm ?label ?lang ?article WHERE {{
  VALUES ?item {{ {items} }}
  OPTIONAL {{ ?item p:P2044/psn:P2044/wikibase:quantityAmount ?elev }}
  OPTIONAL {{ ?item p:P2660/psn:P2660/wikibase:quantityAmount ?prom }}
  OPTIONAL {{ ?item wdt:P11693 ?osm }}
  OPTIONAL {{ ?item rdfs:label ?label . BIND(LANG(?label) AS ?lang) FILTER(?lang IN ({langs})) }}
  OPTIONAL {{ ?article schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> }}
}}
"""

VOLCANO_CLASSES = {"Q8072", "Q169358", "Q212057", "Q190869"}
HILL_CLASSES = {"Q54050"}


class QueryTimeout(Exception):
    pass


def query(sparql: str, retries: int = 4) -> list[dict]:
    delay = 5.0
    for attempt in range(retries + 1):
        try:
            r = requests.post(ENDPOINT, data={"query": sparql},
                              headers={"Accept": "application/sparql-results+json", "User-Agent": USER_AGENT},
                              timeout=90)
            if r.status_code == 200:
                return r.json()["results"]["bindings"]
        except (requests.Timeout, requests.exceptions.ChunkedEncodingError, ValueError) as e:
            # ValueError: JSON cut off when the server stops streaming at its time limit.
            raise QueryTimeout(str(e)[:200]) from e
        if r.status_code == 504 or (r.status_code == 500 and "TimeoutException" in r.text):
            raise QueryTimeout(r.text[:200])
        if r.status_code in (429, 502, 503) and attempt < retries:
            wait = float(r.headers.get("Retry-After", delay))
            log.warning("wikidata %s, retrying in %.0fs", r.status_code, wait)
            time.sleep(wait)
            delay *= 2
            continue
        r.raise_for_status()
    raise AssertionError("unreachable")


def _items_in_cell(west: float, south: float, east: float, north: float, depth: int) -> list[dict]:
    q = ITEMS_QUERY.format(west=west, south=south, east=east, north=north,
                           roots=" ".join(f"wd:{c}" for c in ROOT_CLASSES))
    try:
        return query(q)
    except QueryTimeout:
        if depth >= MAX_SPLIT:
            log.warning("wikidata: giving up on cell %.3f,%.3f..%.3f,%.3f (too dense)", west, south, east, north)
            return []
        log.info("wikidata: timeout for cell %.3f,%.3f..%.3f,%.3f, splitting", west, south, east, north)
        mx, my = (west + east) / 2, (south + north) / 2
        return [r for (w, s, e, n) in ((west, south, mx, my), (mx, south, east, my),
                                       (west, my, mx, north), (mx, my, east, north))
                for r in _items_in_cell(w, s, e, n, depth + 1)]


def fetch_tile_rows(tile: TileId, cache_dir: Path) -> list[dict]:
    """Raw SPARQL rows (items + details) for one tile, cached as JSON."""
    cache = Path(cache_dir) / "wikidata" / "tiles" / f"{tile.name}.json"
    if cache.exists():
        return json.loads(cache.read_text())
    w, s, e, n = tile.bounds
    items = _items_in_cell(w, s, e, n, 0)
    qids = sorted({b["item"]["value"].rsplit("/", 1)[-1] for b in items})
    details: list[dict] = []
    for i in range(0, len(qids), DETAILS_BATCH):
        batch = " ".join(f"wd:{q}" for q in qids[i : i + DETAILS_BATCH])
        details += query(DETAILS_QUERY.format(items=batch, langs=", ".join(f'"{l}"' for l in LANGS)))
    rows = items + details
    log.info("wikidata %s: %d items", tile, len(qids))
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(rows))
    return rows


def fetch_area_peaks(tiles: list[TileId], cache_dir: Path) -> list[Peak]:
    rows: list[dict] = []
    for t in tiles:
        rows += fetch_tile_rows(t, cache_dir)
    return rows_to_peaks(rows)


def rows_to_peaks(rows: list[dict]) -> list[Peak]:
    by_item: dict[str, Peak] = {}
    classes: dict[str, set[str]] = {}
    # Item rows (with coordinates) first, so detail rows always find their peak.
    for b in sorted(rows, key=lambda b: "lat" not in b):
        qid = b["item"]["value"].rsplit("/", 1)[-1]
        p = by_item.get(qid)
        if p is None:
            if "lat" not in b:
                continue
            p = by_item[qid] = Peak(lat=float(b["lat"]["value"]), lon=float(b["lon"]["value"]),
                                    wikidata=qid, sources=["wikidata"])
            classes[qid] = set()
        if "elev" in b and p.ele is None:
            v = float(b["elev"]["value"])
            if -500 <= v <= 9000:
                p.ele, p.ele_source = v, "wikidata"
        if "prom" in b and p.prominence is None:
            p.prominence = float(b["prom"]["value"])
        if "osm" in b and p.osm_id is None:
            try:
                p.osm_id = int(b["osm"]["value"])
            except ValueError:
                pass
        if "label" in b:
            p.names.setdefault(b["lang"]["value"], b["label"]["value"])
        if "article" in b and not p.wikipedia:
            p.wikipedia = "en:" + requests.utils.unquote(b["article"]["value"].rsplit("/", 1)[-1]).replace("_", " ")
        if "class" in b:
            classes[qid].add(b["class"]["value"].rsplit("/", 1)[-1])
    for qid, p in by_item.items():
        if classes[qid] & VOLCANO_CLASSES:
            p.kind = "volcano"
        elif classes[qid] & HILL_CLASSES:
            p.kind = "hill"
        p.name = p.names.get("en") or next(iter(p.names.values()), None)
    return list(by_item.values())
