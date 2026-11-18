import sqlite3

from peaker_pipeline.peaks import wikitext
from peaker_pipeline.peaks.db import write_peak_db
from peaker_pipeline.peaks.model import Peak


class FakeWiki:
    """Wikidata sitelinks and Wikipedia intros, counting requests."""

    def __init__(self):
        self.calls = []

    def __call__(self, url, params):
        self.calls.append((url, params))
        if "wikidata" in url:
            entities = {
                "Q1374": {"sitelinks": {"enwiki": {"title": "Matterhorn"}, "dewiki": {"title": "Matterhorn"}}},
                "Q42": {"sitelinks": {"dewiki": {"title": "Dom (Mischabel)"}}},
            }
            return {"entities": {q: entities.get(q, {}) for q in params["ids"].split("|")}}
        lang = url.split("//")[1].split(".")[0]
        titles = params["titles"].split("|")
        pages, normalized, redirects = {}, [], []
        for i, t in enumerate(titles):
            if t == "matterhorn":  # lower-case spelling, normalised by the API
                normalized.append({"from": t, "to": "Matterhorn"})
                continue
            if t == "Dom (Mischabel)":
                redirects.append({"from": t, "to": "Dom (Berg)"})
                pages[str(i)] = {"title": "Dom (Berg)", "extract": "Der Dom ist ein Berg. Er ist hoch."}
                continue
            pages[str(i)] = {"title": t, "extract": f"{t} ({lang}) is a mountain. " * 3}
        return {"query": {"pages": pages, "normalized": normalized, "redirects": redirects}}


def peaks():
    return [
        Peak(45.97, 7.65, name="Matterhorn", wikidata="Q1374", wikipedia="it:Cervino", osm_id=1, sources=["osm"]),
        Peak(46.09, 7.85, name="Dom", wikidata="Q42", osm_id=2, sources=["osm"]),
        Peak(46.0, 7.0, name="Hill", osm_id=3, sources=["osm"]),
    ]


def test_collect_english_and_one_local_language(tmp_path):
    fake = FakeWiki()
    texts = wikitext.collect(peaks(), tmp_path, get=fake)
    mh = dict((lang, (title, text)) for lang, title, text in texts["wd:Q1374"])
    assert set(mh) == {"en", "it"}  # English + the tag's language, not German as a third
    assert mh["it"][0] == "Cervino" and "(it)" in mh["it"][1]
    dom = texts["wd:Q42"]
    assert dom == [("de", "Dom (Mischabel)", "Der Dom ist ein Berg. Er ist hoch.")]  # followed the redirect
    assert "osm:n3" not in texts
    # Second run: everything from the cache except the Wikidata lookup.
    fake2 = FakeWiki()
    wikitext.collect(peaks(), tmp_path, get=fake2)
    assert all("wikidata" in url for url, _ in fake2.calls)


def test_trim_at_sentence_end():
    text = "First sentence. " * 200
    out = wikitext.trim(text, max_chars=100)
    assert len(out) <= 100 and out.endswith(".")
    assert wikitext.trim("Short.\n\n\nSecond paragraph.") == "Short.\nSecond paragraph."


def test_texts_in_the_peak_db(tmp_path):
    ps = peaks()
    db = tmp_path / "x.sqlite"
    write_peak_db(db, ps, {"country": "CH"}, {"wd:Q1374": [("en", "Matterhorn", "A mountain.")],
                                              "wd:unknown": [("en", "X", "dropped")]})
    rows = sqlite3.connect(db).execute("SELECT peak_id, lang, title, text FROM peak_texts").fetchall()
    assert rows == [("wd:Q1374", "en", "Matterhorn", "A mountain.")]
