"""MkDocs hook: resolve Obsidian ``[[wikilinks]]`` against page slugs.

Source pages come from an Obsidian vault, where cross-references are written
as ``[[00 - Track Overview]]``. Page files here use kebab-case slugs, so a
wikilink target is slugified the same way and linked if that page exists in
this repo. Targets that live in other training tracks (not in this repo)
render as plain text rather than raw brackets.

Wikilinks inside fenced code blocks and inline code spans are left alone:
shell snippets legitimately contain ``[[ ... ]]`` tests and grep patterns.
"""

import re

_WIKILINK = re.compile(r"\[\[([^\[\]]+)\]\]")
# Fenced code blocks (``` / ~~~) and inline code spans, kept verbatim.
_PROTECTED = re.compile(
    r"(?ms)(^[ \t]*(?P<fence>```+|~~~+).*?^[ \t]*\2[ \t]*$|`+[^`\n]*`+)"
)

_slugs = set()


def _slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def on_files(files, config, **kwargs):
    _slugs.clear()
    for f in files:
        if f.src_path.endswith(".md"):
            _slugs.add(_slugify(f.src_path[: -len(".md")]))
    return files


def _replace(match: re.Match) -> str:
    target, _, alias = match.group(1).partition("|")
    text = (alias or target).strip()
    slug = _slugify(target.strip())
    if slug in _slugs:
        return f"[{text}]({slug}.md)"
    return text


def on_page_markdown(markdown, **kwargs):
    # _PROTECTED has two capture groups, so re.split yields repeating triples
    # of (plain text, protected chunk, fence marker). Rewrite only the plain
    # segments; emit protected chunks verbatim and drop the fence markers.
    out = []
    for i, part in enumerate(_PROTECTED.split(markdown)):
        if part is None:
            continue
        if i % 3 == 0:
            out.append(_WIKILINK.sub(_replace, part))
        elif i % 3 == 1:
            out.append(part)
    return "".join(out)
