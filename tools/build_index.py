#!/usr/bin/env python3
"""Crawl digi-api.com once and bake a compact index shipped inside the app.

We bundle *data only* (names, stages, attributes, evolution edges) — never
artwork. Images stay remote and are fetched + cached at runtime, which keeps the
binary small and the fan-project posture clean.

Usage:  python3 tools/build_index.py [--out Sources/DigiTokenBar/Resources/digidex.json]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

API = "https://digi-api.com/api/v1"
CACHE = os.path.join(os.path.dirname(__file__), ".cache")
UA = {"User-Agent": "DigiTokenBar-index-builder/1.0 (+https://github.com/)"}

# digi-api spells the stages in the Japanese scheme. This is the canonical
# progression a partner walks; anything outside it (Armor, Hybrid, Super
# Ultimate...) is a side branch we tag rather than place on the main ladder.
MAIN_LINE = ["Baby I", "Baby II", "Child", "Adult", "Perfect", "Ultimate"]
SIDE_STAGES = ["Armor", "Hybrid", "Super Ultimate", "Unknown"]


def get(url: str, tries: int = 4):
    """GET JSON with a small retry budget; digi-api occasionally 502s."""
    last = None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001 - retry on anything transient
            last = e
            time.sleep(0.4 * (attempt + 1))
    raise RuntimeError(f"failed {url}: {last}")


def fetch_list() -> list[dict]:
    out, page = [], 0
    while True:
        d = get(f"{API}/digimon?pageSize=100&page={page}")
        out.extend(d["content"])
        pageable = d["pageable"]
        if page >= pageable["totalPages"] - 1:
            break
        page += 1
        print(f"  list page {page}/{pageable['totalPages']}", file=sys.stderr)
    return out


def fetch_detail(entry: dict) -> dict:
    path = os.path.join(CACHE, f"{entry['id']}.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    d = get(f"{API}/digimon/{entry['id']}")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f)
    return d


def english_description(detail: dict) -> str:
    for d in detail.get("descriptions") or []:
        if d.get("language", "").startswith("en"):
            text = (d.get("description") or "").strip()
            if text:
                return text[:400]
    return ""


def best_image(detail: dict) -> str:
    images = detail.get("images") or []
    if not images:
        return ""
    # Prefer a transparent cut-out — it composites cleanly over the menu bar.
    for img in images:
        if img.get("transparent"):
            return img["href"]
    return images[0]["href"]


def compact(detail: dict) -> dict | None:
    levels = [lv["level"] for lv in detail.get("levels") or []]
    stage = next((lv for lv in levels if lv in MAIN_LINE), None)
    side = next((lv for lv in levels if lv in SIDE_STAGES), None)
    if stage is None and side is None:
        return None

    name = detail["name"]
    return {
        "id": detail["id"],
        "name": name,
        "stage": stage or side,
        "side": side is not None and stage is None,
        "x": bool(detail.get("xAntibody")),
        "attrs": [a["attribute"] for a in detail.get("attributes") or []],
        "types": [t["type"] for t in detail.get("types") or []],
        "fields": [f["field"] for f in detail.get("fields") or []],
        "img": best_image(detail),
        "desc": english_description(detail),
        "next": sorted({e["id"] for e in detail.get("nextEvolutions") or []}),
        "prior": sorted({e["id"] for e in detail.get("priorEvolutions") or []}),
        "skills": [s["skill"] for s in (detail.get("skills") or [])[:4]],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="Sources/DigiTokenBar/Resources/digidex.json")
    ap.add_argument("--workers", type=int, default=12)
    args = ap.parse_args()

    os.makedirs(CACHE, exist_ok=True)
    print("fetching index...", file=sys.stderr)
    entries = fetch_list()
    print(f"{len(entries)} digimon; fetching details", file=sys.stderr)

    details: list[dict] = []
    done = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(fetch_detail, e): e for e in entries}
        for fut in as_completed(futures):
            entry = futures[fut]
            done += 1
            try:
                details.append(fut.result())
            except Exception as e:  # noqa: BLE001
                print(f"  !! {entry['name']}: {e}", file=sys.stderr)
            if done % 100 == 0:
                print(f"  {done}/{len(entries)}", file=sys.stderr)

    mons = [c for c in (compact(d) for d in details) if c]
    known = {m["id"] for m in mons}
    # Drop edges pointing at entries we filtered out, so the graph stays closed.
    for m in mons:
        m["next"] = [i for i in m["next"] if i in known]
        m["prior"] = [i for i in m["prior"] if i in known]
    mons.sort(key=lambda m: m["id"])

    payload = {
        "version": 1,
        "source": "digi-api.com",
        "generated": time.strftime("%Y-%m-%d"),
        "stages": MAIN_LINE,
        "digimon": mons,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, separators=(",", ":"), ensure_ascii=False)

    by_stage: dict[str, int] = {}
    for m in mons:
        by_stage[m["stage"]] = by_stage.get(m["stage"], 0) + 1
    size = os.path.getsize(args.out)
    print(f"\nwrote {args.out}  ({len(mons)} digimon, {size/1024:.0f} KB)", file=sys.stderr)
    print(f"by stage: {by_stage}", file=sys.stderr)
    print(f"x-antibody: {sum(1 for m in mons if m['x'])}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
