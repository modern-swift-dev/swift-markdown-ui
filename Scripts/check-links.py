#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


IGNORED_SCHEMES = {"data", "javascript", "mailto", "tel"}
LINK_ATTRIBUTES = {"href", "poster", "src"}


@dataclass(frozen=True)
class Link:
    line: int
    target: str


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[Link] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        del tag
        line, _ = self.getpos()
        for name, value in attrs:
            if value is None:
                continue
            if name in LINK_ATTRIBUTES:
                self.links.append(Link(line, value))
            elif name == "srcset":
                for candidate in value.split(","):
                    target = candidate.strip().split(maxsplit=1)[0]
                    if target:
                        self.links.append(Link(line, target))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check links in a static HTML site.")
    parser.add_argument("site", type=Path, help="Static site root")
    parser.add_argument(
        "--base-path",
        default="/",
        help="Hosting base path used by root-relative links",
    )
    return parser.parse_args()


def normalized_base_path(raw_base_path: str) -> str:
    if raw_base_path == "/":
        return "/"
    return "/" + raw_base_path.strip("/")


def local_path(
    site_root: Path, source: Path, target: str, base_path: str
) -> Path | None:
    parsed = urlsplit(target)
    if parsed.scheme.lower() in IGNORED_SCHEMES or parsed.scheme or parsed.netloc:
        return None
    if not parsed.path:
        return source

    decoded_path = unquote(parsed.path)
    if decoded_path.startswith("/"):
        if base_path != "/" and not (
            decoded_path == base_path or decoded_path.startswith(base_path + "/")
        ):
            return site_root / "__outside_hosting_base_path__" / decoded_path.lstrip("/")
        relative_path = decoded_path[len(base_path) :].lstrip("/")
        return site_root / relative_path

    return source.parent / decoded_path


def path_exists(path: Path, target: str) -> bool:
    if path.is_file():
        return True
    if path.is_dir() and (path / "index.html").is_file():
        return True

    target_path = urlsplit(target).path
    if not target_path.endswith("/") and not path.suffix:
        return path.with_suffix(".html").is_file() or (path / "index.html").is_file()
    return False


def is_within_site(site_root: Path, path: Path) -> bool:
    try:
        path.resolve().relative_to(site_root)
    except ValueError:
        return False
    return True


def main() -> int:
    args = parse_args()
    site_root = args.site.resolve()
    base_path = normalized_base_path(args.base_path)
    if not site_root.is_dir():
        print(f"error: site directory does not exist: {site_root}", file=sys.stderr)
        return 2

    failures: list[str] = []
    html_files = sorted(site_root.rglob("*.html"))
    for source in html_files:
        parser = LinkParser()
        parser.feed(source.read_text(encoding="utf-8"))
        for link in parser.links:
            candidate = local_path(site_root, source, link.target, base_path)
            if candidate is None:
                continue
            if is_within_site(site_root, candidate) and path_exists(candidate, link.target):
                continue
            relative_source = source.relative_to(site_root)
            failures.append(f"{relative_source}:{link.line}: {link.target}")

    if failures:
        print("Broken internal links:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"Checked {len(html_files)} HTML files in {site_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
