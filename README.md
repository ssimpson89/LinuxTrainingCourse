# Rocky Linux Deep Dive

An easy-to-follow, hands-on deep dive into how Rocky Linux really works: 21
modules that go from "how does a command run?" to boot, storage, networking,
SELinux, containers, and performance, with interactive diagrams, checkpoint
quizzes, and self-cleaning labs for a throwaway Rocky Linux 10 VM.

- `content/`: the course, in Markdown (the only source of truth)
- `STYLE.md`: the authoring guide. Read it before writing or editing a module.
- `content/javascripts/widgets.js` + `content/stylesheets/widgets.css`: the
  interactive widgets (stepper, layers, quiz, decision tree, chmod and subnet
  calculators, progress tracking)
- `hooks/wikilinks.py`: resolves `[[wikilinks]]` and `[[man:name(N)]]` man page badges
- `includes/abbreviations.md`: hover tooltips for acronyms, applied site-wide
- `mkdocs.yml`: MkDocs Material site config (builds into `dist/`, not committed)

## Hosting on Cloudflare Pages

Cloudflare builds the site on every push:

1. Cloudflare dashboard → Workers & Pages → Create → Pages → Connect to Git
2. Select `ssimpson89/LinuxTrainingCourse`, production branch `main`
3. Framework preset: **None**
   - Build command: `pip install -r requirements.txt && mkdocs build`
   - Build output directory: `dist`

## Local build

```
pip install -r requirements.txt
mkdocs serve
```

Run `mkdocs build --strict` before pushing; it fails on broken links.
