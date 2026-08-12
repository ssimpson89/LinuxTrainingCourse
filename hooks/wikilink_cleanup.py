"""MkDocs hook: strip unresolved Obsidian wikilinks from the built HTML.

Wikilinks to pages that exist in this repo are converted to real links by
the roamlinks plugin during the build. Anything still literal ``[[...]]``
in the output points at a page outside this repo (other training tracks),
so render it as plain text instead of raw brackets.
"""

import re
from pathlib import Path

_WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
# Code spans/blocks may legitimately contain [[ ]] (bash tests, grep
# patterns); never rewrite inside them.
_CODE = re.compile(r"(<(?:code|pre)\b.*?</(?:code|pre)>)", re.DOTALL)


def _to_text(match: re.Match) -> str:
    inner = match.group(1)
    if "|" in inner:
        _, alias = inner.split("|", 1)
        return alias.strip()
    return inner.strip()


def on_post_build(config, **kwargs):
    site_dir = Path(config["site_dir"])
    for html_file in site_dir.glob("**/*.html"):
        content = html_file.read_text(encoding="utf-8")
        parts = _CODE.split(content)
        modified = "".join(
            part if part.startswith(("<code", "<pre")) else _WIKILINK.sub(_to_text, part)
            for part in parts
        )
        if modified != content:
            html_file.write_text(modified, encoding="utf-8")
