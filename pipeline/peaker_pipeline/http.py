"""Small download helper with retries and atomic writes."""

from __future__ import annotations

import logging
import os
import time
import uuid
from pathlib import Path

import requests

log = logging.getLogger(__name__)

USER_AGENT = "peaker-pipeline/0.1 (+https://github.com/mowolf/peaker)"


def download(url: str, dest: Path | str, retries: int = 4, timeout: float = 120) -> Path:
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Unique temp name: parallel runs may download the same file.
    tmp = dest.with_name(f"{dest.name}.{os.getpid()}.{uuid.uuid4().hex[:8]}.part")
    delay = 2.0
    for attempt in range(retries + 1):
        try:
            with requests.get(url, stream=True, timeout=timeout, headers={"User-Agent": USER_AGENT}) as r:
                r.raise_for_status()
                with open(tmp, "wb") as f:
                    for chunk in r.iter_content(1 << 20):
                        f.write(chunk)
            tmp.replace(dest)
            return dest
        except requests.RequestException as e:
            if attempt == retries or (isinstance(e, requests.HTTPError) and e.response is not None
                                      and 400 <= e.response.status_code < 500):
                raise
            log.warning("download failed (%s), retrying in %.0fs: %s", e, delay, url)
            time.sleep(delay)
            delay *= 2
    raise AssertionError("unreachable")
