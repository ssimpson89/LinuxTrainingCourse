#!/usr/bin/env python3
"""Build a static HTML site from the markdown in content/ into docs/.

Requires pandoc. Usage: python3 build.py
"""
import html
import re
import subprocess
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).parent
CONTENT = ROOT / "content"
OUT = ROOT / "docs"

CSS = """
:root { --fg:#1a1a1a; --bg:#ffffff; --accent:#0b5fa5; --muted:#666; --code-bg:#f5f5f5; --border:#e2e2e2; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#ddd; --bg:#161719; --accent:#6ab0e3; --muted:#999; --code-bg:#222428; --border:#333; }
}
* { box-sizing: border-box; }
body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
       color:var(--fg); background:var(--bg); line-height:1.65; }
.layout { display:flex; max-width:1200px; margin:0 auto; }
nav.sidebar { width:280px; flex-shrink:0; padding:1.5rem 1rem; border-right:1px solid var(--border);
              position:sticky; top:0; height:100vh; overflow-y:auto; font-size:0.9rem; }
nav.sidebar a { display:block; padding:0.3rem 0.5rem; color:var(--fg); text-decoration:none; border-radius:4px; }
nav.sidebar a:hover { background:var(--code-bg); }
nav.sidebar a.current { color:var(--accent); font-weight:600; }
main { flex:1; min-width:0; padding:2rem 2.5rem 4rem; }
main h1,h2,h3 { line-height:1.3; }
main h2 { border-bottom:1px solid var(--border); padding-bottom:0.3rem; margin-top:2.2rem; }
a { color:var(--accent); }
code { background:var(--code-bg); padding:0.15em 0.35em; border-radius:4px; font-size:0.9em; }
pre { background:var(--code-bg); padding:1rem; border-radius:8px; overflow-x:auto; }
pre code { background:none; padding:0; }
table { border-collapse:collapse; width:100%; display:block; overflow-x:auto; }
th,td { border:1px solid var(--border); padding:0.4rem 0.7rem; text-align:left; }
blockquote { border-left:4px solid var(--accent); margin:1rem 0; padding:0.2rem 1rem; color:var(--muted); }
@media (max-width:800px){ .layout{flex-direction:column;} nav.sidebar{position:static;height:auto;width:100%;border-right:none;border-bottom:1px solid var(--border);} main{padding:1rem;} }
"""

def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s + ".html"

def main():
    OUT.mkdir(exist_ok=True)
    (OUT / "style.css").write_text(CSS)

    pages = sorted(CONTENT.glob("*.md"))
    titles = {p.stem: slug(p.stem) for p in pages}

    nav_links = "\n".join(
        f'<a href="{titles[p.stem]}" data-page="{titles[p.stem]}">{html.escape(p.stem)}</a>'
        for p in pages
    )

    def wikilink(m):
        target, _, alias = m.group(1).partition("|")
        text = alias or target
        if target in titles:
            return f"[{text}]({titles[target]})"
        return text

    for p in pages:
        md = p.read_text()
        md = re.sub(r"\[\[([^\]]+)\]\]", wikilink, md)
        body = subprocess.run(
            ["pandoc", "-f", "markdown", "-t", "html", "--no-highlight"],
            input=md, capture_output=True, text=True, check=True,
        ).stdout
        page = titles[p.stem]
        nav = nav_links.replace(f'data-page="{page}"', f'data-page="{page}" class="current"')
        (OUT / page).write_text(f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(p.stem)} | Linux Training Course</title>
<link rel="stylesheet" href="style.css"></head>
<body><div class="layout">
<nav class="sidebar"><a href="index.html"><strong>Linux Training Course</strong></a><hr>
{nav}</nav>
<main>{body}</main>
</div></body></html>""")

    # index = redirect to track overview
    first = titles[pages[0].stem]
    (OUT / "index.html").write_text(
        f'<!DOCTYPE html><meta charset="utf-8"><meta http-equiv="refresh" content="0; url={first}">'
        f'<a href="{first}">Linux Training Course</a>'
    )
    print(f"Built {len(pages)} pages into {OUT}")

if __name__ == "__main__":
    main()
