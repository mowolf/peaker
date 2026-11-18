"""Wikipedia article intros for the app's peak details, so they read offline on the mountain.

Text from Wikipedia is CC BY-SA 4.0: the app shows the source article and the licence with every text.

Which articles: the OSM ``wikipedia`` tag, and through the peak's Wikidata item its articles in English and the
pack's main languages (many peaks have a Wikidata item but no ``wikipedia`` tag). At most two texts per peak:
English and one local language. Intros only (``exintro``, plain text), trimmed to ~1200 characters at a sentence
end. Fetched in batches (Wikidata 50, Wikipedia 20 per request) and cached per language for 180 days, so the
weekly rebuild fetches only new articles.
"""

from __future__ import annotations

import json
import logging
import time
from collections import Counter
from datetime import date, timedelta
from pathlib import Path
from typing import Callable

from ..http import USER_AGENT
from .model import Peak

log = logging.getLogger(__name__)

MAX_CHARS = 1200
CACHE_DAYS = 180
WIKIDATA_API = "https://www.wikidata.org/w/api.php"

Getter = Callable[[str, dict], dict]


def _get(url: str, params: dict) -> dict:
    """GET JSON politely: identifies the project, waits as told on 429, retries network errors."""
    import requests

    for attempt in range(6):
        try:
            r = requests.get(url, params={**params, "format": "json", "maxlag": 5},
                             headers={"User-Agent": USER_AGENT}, timeout=60)
            if r.status_code == 429 or r.status_code >= 500:
                time.sleep(float(r.headers.get("Retry-After", 5 * (attempt + 1))))
                continue
            r.raise_for_status()
            time.sleep(0.05)
            return r.json()
        except requests.RequestException as e:
            log.warning("wikipedia request failed (%s), retrying", e)
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"giving up on {url}")


def trim(text: str, max_chars: int = MAX_CHARS) -> str:
    """The first paragraphs up to `max_chars`, cut at the end of a sentence."""
    text = "\n".join(p.strip() for p in text.strip().split("\n") if p.strip())
    if len(text) <= max_chars:
        return text
    cut = text[:max_chars]
    end = max(cut.rfind(". "), cut.rfind(".\n"), cut.rfind("! "), cut.rfind("? "))
    return cut[: end + 1] if end > max_chars // 3 else cut.rsplit(" ", 1)[0] + " …"


def pack_languages(peaks: list[Peak], extra: int = 3) -> list[str]:
    """English plus the most common languages of the peaks' wikipedia tags."""
    counts = Counter(p.wikipedia.split(":", 1)[0] for p in peaks if p.wikipedia and ":" in p.wikipedia)
    return ["en"] + [lang for lang, _ in counts.most_common() if lang != "en"][:extra]


def article_links(peaks: list[Peak], languages: list[str], get: Getter = _get) -> dict[str, dict[str, str]]:
    """Peak id → {language: article title} from the wikipedia tags and the Wikidata sitelinks."""
    links: dict[str, dict[str, str]] = {}
    for p in peaks:
        if p.wikipedia and ":" in p.wikipedia:
            lang, title = p.wikipedia.split(":", 1)
            links.setdefault(p.id, {})[lang] = title
    by_qid: dict[str, list[str]] = {}
    for p in peaks:
        if p.wikidata:
            by_qid.setdefault(p.wikidata, []).append(p.id)
    qids = sorted(by_qid)
    sites = "|".join(f"{lang}wiki" for lang in languages)
    for start in range(0, len(qids), 50):
        batch = qids[start:start + 50]
        data = get(WIKIDATA_API, {"action": "wbgetentities", "ids": "|".join(batch), "props": "sitelinks",
                                  "sitefilter": sites})
        for qid, entity in data.get("entities", {}).items():
            for site, link in (entity.get("sitelinks") or {}).items():
                lang = site.removesuffix("wiki")
                for peak_id in by_qid.get(qid, []):
                    links.setdefault(peak_id, {}).setdefault(lang, link["title"])
    return links


def choose(links: dict[str, str], languages: list[str]) -> dict[str, str]:
    """At most two articles: English and one local one (the tag's language first, as stored first)."""
    out: dict[str, str] = {}
    if "en" in links:
        out["en"] = links["en"]
    for lang in list(links) + languages:
        if lang != "en" and lang in links:
            out[lang] = links[lang]
            break
    return out


def intros(lang: str, titles: set[str], cache_dir: Path, get: Getter = _get) -> dict[str, str]:
    """Title → trimmed intro (empty if the article has none or doesn't exist), from the cache or Wikipedia."""
    path = Path(cache_dir) / "wikipedia" / f"{lang}.json"
    cache: dict[str, dict] = json.loads(path.read_text()) if path.exists() else {}
    oldest = (date.today() - timedelta(days=CACHE_DAYS)).isoformat()
    missing = sorted(t for t in titles if t not in cache or cache[t]["d"] < oldest)
    api = f"https://{lang}.wikipedia.org/w/api.php"
    for start in range(0, len(missing), 20):
        batch = missing[start:start + 20]
        data = get(api, {"action": "query", "prop": "extracts", "exintro": 1, "explaintext": 1, "exlimit": 20,
                         "redirects": 1, "titles": "|".join(batch)})
        query = data.get("query", {})
        # Requested title → title of the page that answered it (normalised spelling, redirects).
        rename = {n["from"]: n["to"] for n in query.get("normalized", [])}
        redirect = {r["from"]: r["to"] for r in query.get("redirects", [])}
        texts = {p.get("title"): trim(p.get("extract", "")) for p in query.get("pages", {}).values()}
        today = date.today().isoformat()
        for title in batch:
            final = redirect.get(rename.get(title, title), rename.get(title, title))
            cache[title] = {"t": texts.get(final, ""), "d": today}
    if missing:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(cache, ensure_ascii=False))
    return {t: cache[t]["t"] for t in titles if t in cache}


def collect(peaks: list[Peak], cache_dir: Path, get: Getter = _get) -> dict[str, list[tuple[str, str, str]]]:
    """Peak id → [(language, title, text)] for the peaks with Wikipedia articles."""
    languages = pack_languages(peaks)
    chosen = {pid: choose(links, languages) for pid, links in article_links(peaks, languages, get).items()}
    wanted: dict[str, set[str]] = {}
    for articles in chosen.values():
        for lang, title in articles.items():
            wanted.setdefault(lang, set()).add(title)
    texts = {lang: intros(lang, titles, cache_dir, get) for lang, titles in wanted.items()}
    out: dict[str, list[tuple[str, str, str]]] = {}
    for pid, articles in chosen.items():
        rows = [(lang, title, texts[lang].get(title, "")) for lang, title in articles.items()]
        rows = [r for r in rows if r[2]]
        if rows:
            out[pid] = rows
    log.info("wikipedia texts: %d peaks (%s)", len(out), ", ".join(f"{k} {len(v)}" for k, v in wanted.items()))
    return out
