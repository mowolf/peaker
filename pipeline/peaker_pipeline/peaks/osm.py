"""Peaks from OpenStreetMap extracts (.osm.pbf), e.g. Geofabrik country files.

Source tags: ``natural=peak`` and ``natural=volcano`` (plus ``natural=hill`` if
asked for). Name tags ``name`` and ``name:<lang>``, ``ele``, ``prominence``,
``wikidata``, ``wikipedia``. Data © OpenStreetMap contributors, ODbL.
"""

from __future__ import annotations

from pathlib import Path

from .model import Peak, parse_ele

GEOFABRIK_URL = "https://download.geofabrik.de/{region}-latest.osm.pbf"

KINDS = {"peak": "peak", "volcano": "volcano", "hill": "hill"}


def read_osm_peaks(path: Path | str, include_hills: bool = False) -> list[Peak]:
    import osmium

    wanted = [("natural", "peak"), ("natural", "volcano")]
    if include_hills:
        wanted.append(("natural", "hill"))

    peaks: list[Peak] = []
    fp = osmium.FileProcessor(str(path), osmium.osm.NODE).with_filter(osmium.filter.TagFilter(*wanted))
    for node in fp:
        if not node.location.valid():
            continue
        tags = {t.k: t.v for t in node.tags}
        names = {k[5:]: v for k, v in tags.items() if k.startswith("name:") and len(k) <= 10 and v}
        alt = [v for k in ("alt_name", "old_name", "loc_name", "official_name") if (v := tags.get(k))]
        ele = parse_ele(tags.get("ele"))
        qid = tags.get("wikidata", "").strip()
        peaks.append(Peak(
            lat=node.location.lat,
            lon=node.location.lon,
            name=tags.get("name") or None,
            names=names,
            alt_names=[n for a in alt for n in a.split(";") if n],
            ele=ele,
            ele_source="osm" if ele is not None else None,
            prominence=parse_ele(tags.get("prominence")),
            kind=KINDS.get(tags.get("natural", ""), "peak"),
            osm_id=node.id,
            wikidata=qid if qid.startswith("Q") and qid[1:].isdigit() else None,
            wikipedia=tags.get("wikipedia") or None,
            sources=["osm"],
        ))
    return peaks


GEOFABRIK_INDEX = "https://download.geofabrik.de/index-v1-nogeom.json"


def geofabrik_pbf_urls(cc: str, cache_dir: Path) -> list[str]:
    """Geofabrik extract(s) for an ISO alpha-2 code, using Geofabrik's own index.

    Most countries have exactly one extract. A few only exist as several
    sub-regions; those are all returned. Shared extracts (e.g. "Israel and
    Palestine") are returned for each code they list.
    """
    import json

    from ..http import download

    index = Path(cache_dir) / "geofabrik" / "index-v1-nogeom.json"
    if not index.exists():
        download(GEOFABRIK_INDEX, index)
    features = json.loads(index.read_text())["features"]
    cc = cc.upper()
    hits = [f["properties"] for f in features if cc in (f["properties"].get("iso3166-1:alpha2") or [])]
    if not hits:
        return []
    ids = {h["id"] for h in hits}
    # Prefer the largest extract: drop any whose parent is also a hit.
    top = [h for h in hits if h.get("parent") not in ids]
    return [h["urls"]["pbf"] for h in top]


def osm_peaks_for_country(cc: str, cache_dir: Path, include_hills: bool = False,
                          keep_pbf: bool = True) -> list[Peak]:
    """Peaks of one country from Geofabrik.

    The extracted peaks are cached as JSON (``osm-peaks/``), which is tiny compared
    to the extract. With ``keep_pbf=False`` the .pbf is deleted right after reading,
    so CI runners never hold more than one extract (Germany/France are ~4.5 GB each).
    Delete the JSON to refresh (CI prunes it weekly).
    """
    import json

    from ..http import download

    urls = geofabrik_pbf_urls(cc, cache_dir)
    if not urls:
        raise LookupError(f"no Geofabrik extract for {cc}")
    peaks: list[Peak] = []
    for url in urls:
        rel = url.split("download.geofabrik.de/", 1)[-1]
        cached = Path(cache_dir) / "osm-peaks" / (rel.replace("/", "_") + ("-hills" if include_hills else "") + ".json")
        if cached.exists():
            peaks += [Peak.from_dict(d) for d in json.loads(cached.read_text())]
            continue
        path = Path(cache_dir) / "geofabrik" / rel
        if not path.exists():
            download(url, path, timeout=1800)
        found = read_osm_peaks(path, include_hills=include_hills)
        cached.parent.mkdir(parents=True, exist_ok=True)
        cached.write_text(json.dumps([p.to_dict() for p in found], ensure_ascii=False))
        if not keep_pbf:
            path.unlink()
        peaks += found
    return peaks
