# LinuxTrainingCourse

Linux Internals training track: 14 mechanism-first modules covering a running
Linux system from permissions and PAM through the kernel, namespaces/cgroups,
eBPF tracing, SELinux, and early userspace.

- `content/` — the course modules in Markdown (the only source of truth)
- `mkdocs.yml` — MkDocs Material site config (builds into `dist/`, not committed)
- `hooks/wikilinks.py` — resolves Obsidian `[[wikilinks]]` to page slugs at build
  time; targets that live in other tracks render as plain text

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
