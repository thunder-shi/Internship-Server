#!/usr/bin/env python3
"""Reorder CREATE VIEW blocks in Navicat dump by dependency (topological sort)."""
import re
import sys
from collections import defaultdict, deque
from pathlib import Path


def parse_views(views_section: str) -> list[tuple[str, str]]:
    """Parse view blocks; tolerate missing separator lines between views."""
    blocks: list[tuple[str, str]] = []
    chunks = re.split(r"\n(?=-- View structure for )", views_section.strip())
    for chunk in chunks:
        chunk = chunk.strip()
        if not chunk.startswith("-- View structure for "):
            continue
        m = re.match(r"-- View structure for (\S+)\s*\n", chunk)
        if not m:
            continue
        name = m.group(1)
        if "DROP VIEW IF EXISTS" not in chunk or "CREATE" not in chunk:
            print(f"Warning: skip malformed block {name}")
            continue
        if not chunk.endswith("\n"):
            chunk += "\n"
        blocks.append((name, chunk))
    return blocks


def main() -> int:
    sql_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "internship.sql"
    text = sql_path.read_text(encoding="utf-8")

    view_start_marker = "-- View structure for "
    fn_marker = "-- Function structure for department_getAllParentNames"
    footer_marker = "SET FOREIGN_KEY_CHECKS = 1;"

    fn_start = text.rfind("-- ----------------------------", 0, text.index(fn_marker))
    views_start = text.index(view_start_marker)
    prefix = text[:fn_start].rstrip() + "\n\n"
    fn_and_trigger = text[fn_start:views_start].rstrip() + "\n\n"
    views_and_suffix = text[views_start:]
    footer_idx = views_and_suffix.rindex(footer_marker)
    views_section = views_and_suffix[:footer_idx].rstrip()
    suffix = "\n\n" + views_and_suffix[footer_idx:]

    blocks = parse_views(views_section)
    names = [n for n, _ in blocks]
    name_set = set(names)
    print(f"Parsed {len(blocks)} views from {sql_path}")

    deps: dict[str, set[str]] = defaultdict(set)
    for name, body in blocks:
        for other in name_set:
            if other == name:
                continue
            if re.search(rf"(`{re.escape(other)}`|internship\.`{re.escape(other)}`)", body, re.I):
                deps[name].add(other)

    in_degree = {n: 0 for n in names}
    rev: dict[str, set[str]] = defaultdict(set)
    for n in names:
        for d in deps.get(n, ()):
            in_degree[n] += 1
            rev[d].add(n)

    q = deque([n for n in names if in_degree[n] == 0])
    ordered: list[str] = []
    while q:
        n = q.popleft()
        ordered.append(n)
        for m in rev[n]:
            in_degree[m] -= 1
            if in_degree[m] == 0:
                q.append(m)

    if len(ordered) != len(names):
        print("Warning: cycle detected, appending remaining views in original order")
        for n in names:
            if n not in ordered:
                ordered.append(n)

    orig_idx = {n: i for i, n in enumerate(names)}
    fixes = 0
    for n in names:
        late = [d for d in deps.get(n, ()) if orig_idx.get(d, -1) > orig_idx[n]]
        if late:
            fixes += 1
            print(f"  fix: {n} depends on {late}")
    print(f"Reordered {fixes} views with wrong dependency order")

    block_map = dict(blocks)
    new_views = "\n".join(block_map[n].rstrip() for n in ordered) + "\n"
    sql_path.write_text(prefix + fn_and_trigger + new_views + suffix, encoding="utf-8")
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
