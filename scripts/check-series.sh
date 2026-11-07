#!/bin/sh
# Pre-publish gate for the "How Rocky Gets Built" series (modules 40 to 53).
#
#   scripts/check-series.sh [--strict] [--urls] [--quiet] [FILE...]
#
# With no FILE arguments it checks content/4[0-9]-*.md and content/5[0-3]-*.md.
# Prints "path:line: LEVEL [rule] message". ERROR lines fail the run (exit 1).
# WARN lines are advisory unless --strict is given. --urls also prints every
# external URL found (for the curl -sI pass). --quiet hides the summary table.
#
# Optional: MKDOCS=/path/to/mkdocs scripts/check-series.sh
# also runs `mkdocs build --strict` into a temporary directory.
#
# Needs only POSIX sh and python3 (standard library). Works on macOS and Linux.

set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
cd "$root" || exit 2

if ! command -v python3 >/dev/null 2>&1; then
  echo "check-series.sh: python3 is required" >&2
  exit 2
fi

python3 -I - "$@" <<'PYEOF'
import glob
import os
import re
import sys

args = sys.argv[1:]
STRICT = "--strict" in args
URLS = "--urls" in args
QUIET = "--quiet" in args
files = [a for a in args if not a.startswith("--")]
if not files:
    files = sorted(glob.glob("content/4[0-9]-*.md") + glob.glob("content/5[0-3]-*.md"))
if not files:
    print("check-series.sh: no module files found", file=sys.stderr)
    sys.exit(2)

STAGES = ["source", "build", "sign", "compose", "publish", "install"]
STAGE_NAMES = [s.capitalize() for s in STAGES]
TOP_WIDGETS = {"stepper", "layers", "quiz", "decision", "terminal-sim", "flashcards"}
ALL_WIDGETS = TOP_WIDGETS | {"step", "layer", "node", "task", "card", "pipeline-strip"}
EV_PREFIXES = ("Observed:", "Stated by the project:", "Our reading:", "Reported, not confirmed:")
LAB_LABELS = ["Tier", "Status", "Time", "Hardware", "Tested on"]
LAB_STATUS = ("Tested partly", "Tested", "Read-along")
UNKNOWN_TITLE = "What nobody outside the project can tell you"

RE_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
RE_ADM = re.compile(r'^(\s*)(!!!|\?\?\?\+?)\s+([\w-]+)(?:\s+"(.*)")?\s*$')
RE_DATE = re.compile(r"\b20\d\d-\d\d(-\d\d)?\b")
RE_EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿⭐⬆✅❌✔✖✨]")
RE_EV = re.compile(r"^\s*<!--\s*ev:")
RE_EV_OK = re.compile(r"^<!-- ev: [^|]+? \| (observed|official|inference|unverified) \| [^|]+? -->$")
REGISTER = r"\b(152|10,361|56,661|306,497|4,759|3,194|7,672|211\.74\.1)\b"
RE_THOUSANDS = re.compile(r"\b\d{1,3}(?:,\d{3})+\b")
RE_COUNTNOUN = re.compile(
    r"\b\d[\d,]*\s+(mirrors|packages|builds|tasks|advisories|RPMs|files|repositories|rebuilds)\b")
RE_PERCENT = re.compile(r"\b\d+(?:\.\d+)?\s?%")
RE_URL = re.compile(r"https?://[^\s)>\]\"'`]+")

findings = []   # (path, line, level, rule, msg)
rule_ids = set()


def add(path, line, level, rule, msg):
    findings.append((path, line, level, rule, msg))
    rule_ids.add(rule)


def strip_prose(s):
    s = re.sub(r"`[^`]*`", "", s)
    s = re.sub(r"<!--.*?-->", "", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = RE_URL.sub("", s)
    return s


def block_end(lines, i, indent):
    """Index after an admonition block that starts at line i."""
    j = i + 1
    n = len(lines)
    while j < n:
        l = lines[j]
        if l.strip() == "":
            j += 1
            continue
        ind = len(l) - len(l.lstrip(" "))
        if ind >= indent + 4:
            j += 1
            continue
        break
    # trim trailing blanks
    while j > i + 1 and lines[j - 1].strip() == "":
        j -= 1
    return j


def check(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    n = len(lines)
    base = os.path.basename(path)
    m = re.match(r"(\d\d)-", base)
    num = int(m.group(1)) if m else None
    exam = num == 53
    series = num is not None and 40 <= num <= 53

    # ---- pass 1: classify every line (front matter, fence, comment, mermaid)
    kind = [""] * n          # "fm", "fence", "mermaid", "comment" or ""
    fence = None
    fence_lang = ""
    fm = False
    in_comment = False
    mermaid_blocks = []      # (start_line_index, [lines])
    cur_mermaid = None
    if n and lines[0].strip() == "---":
        fm = True
        kind[0] = "fm"
    for i in range(1, n):
        l = lines[i]
        if fm:
            kind[i] = "fm"
            if l.strip() == "---":
                fm = False
            continue
    for i in range(n):
        if kind[i] == "fm":
            continue
        l = lines[i]
        fm_ = RE_FENCE.match(l)
        if fence is None:
            if fm_:
                fence = fm_.group(1)
                fence_lang = l.strip()[len(fence):].strip().split(" ")[0].split("{")[0]
                kind[i] = "fence"
                if fence_lang == "mermaid":
                    cur_mermaid = (i, [])
                continue
        else:
            kind[i] = "fence"
            if fm_ and fm_.group(1)[0] == fence[0] and len(fm_.group(1)) >= len(fence) \
                    and l.strip() == fm_.group(1):
                fence = None
                if cur_mermaid is not None:
                    mermaid_blocks.append(cur_mermaid)
                    cur_mermaid = None
            elif cur_mermaid is not None:
                cur_mermaid[1].append(l)
            continue
        # outside fences: html comments
        if in_comment:
            kind[i] = "comment"
            if "-->" in l:
                in_comment = False
            continue
        s = l.strip()
        if s.startswith("<!--"):
            kind[i] = "comment"
            if "-->" not in s:
                in_comment = True
            continue

    prose = []  # line indexes that are prose
    for i in range(n):
        if kind[i] in ("", "fm"):
            prose.append(i)

    # ---- admonition blocks
    blocks = []  # dict(kind, title, start, end, collapsed)
    for i in range(n):
        if kind[i] in ("fence", "comment", "fm"):
            continue
        am = RE_ADM.match(lines[i])
        if am:
            end = block_end(lines, i, len(am.group(1)))
            blocks.append({"type": am.group(3), "title": am.group(4) or "", "start": i,
                           "end": end, "collapsed": am.group(2).startswith("???"),
                           "indent": len(am.group(1))})
    in_box = [None] * n
    for b in blocks:
        if b["type"] in ("evidence", "freshness", "unknown"):
            for k in range(b["start"], b["end"]):
                in_box[k] = b["type"]
    lens = [False] * n
    for b in blocks:
        if b["type"] == "version" and b["title"].startswith("Comparison lens"):
            for k in range(b["start"], b["end"]):
                lens[k] = True
            if not b["collapsed"]:
                add(path, b["start"] + 1, "ERROR", "R24-lens-open",
                    "Comparison lens must be a collapsed fold (???), not !!!")

    def ref(i):
        return i + 1

    # ---- R20 line limits
    if n > 1500:
        add(path, 1, "ERROR", "R20-length", "%d lines, hard stop is 1,500" % n)
    elif n > 1300:
        add(path, 1, "WARN", "R20-length", "%d lines, target is 900 to 1,300" % n)
    elif series and not exam and n < 900:
        add(path, 1, "WARN", "R20-length", "%d lines, target is 900 to 1,300" % n)

    # ---- R27 stub
    if "Draft: this module is being written." in text:
        add(path, 1, "ERROR", "R27-stub", "stub file: replace the whole file")

    # ---- prose rules
    for i in prose:
        raw = lines[i]
        p = strip_prose(raw)
        if "—" in p or "–" in p:
            add(path, ref(i), "ERROR", "R01-dash", "em or en dash in prose")
        if re.search(r"\s--(?=\s|$)|\w--\w|\w--\s", p):
            add(path, ref(i), "ERROR", "R02-double-hyphen", "double hyphen in prose")
        if RE_EMOJI.search(p):
            add(path, ref(i), "ERROR", "R03-emoji", "emoji in prose")
        for pat, rid in ((r"\b(simply|obviously)\b", "R04-filler"),
                         (r"\bjust run\b", "R04-filler"),
                         (r"it is important to note|in today's", "R04-filler")):
            if re.search(pat, p, re.I):
                add(path, ref(i), "WARN", rid, "voice: filler word or phrase")
        if re.search(r"\b(yum(?!\.repos)|ifconfig|netstat)\b", p):
            add(path, ref(i), "WARN", "R05-legacy-cmd", "yum, ifconfig or netstat in prose")
        if re.search(r"\[(OFFICIAL|OBSERVED|INFERENCE|UNVERIFIED)\]", raw):
            add(path, ref(i), "ERROR", "R15-raw-tag", "internal evidence tag leaked into the page")
        if re.search(r"/Users/|/private/tmp|scratchpad|ctrliq|sshinn|sherif", raw, re.I):
            add(path, ref(i), "ERROR", "R16-local-path", "local path, handle or internal host name")
        if re.search(r"\b24 days\b", raw):
            add(path, ref(i), "ERROR", "R17-held-back", "held-back figure (24 days)")
        if re.search(r"Peridot\s+(?:builds?\s+Rocky\s*(?:Linux\s*)?9\b|built\s+Rocky\s*(?:Linux\s*)?9(?![.\d]))", raw, re.I):
            add(path, ref(i), "ERROR", "R18-peridot-9", "'Peridot builds Rocky 9' phrasing is not allowed")
        if re.search(r"\b(Ascender|SFE|SECO|Zendesk|JIRA|CUSP)\b", p):
            add(path, ref(i), "ERROR", "R19-internal-word", "CIQ-internal tool or process name")
        elif re.search(r"\b(CIQ|RLC|FIPS|Fuzzball|Warewulf)\b|Rocky Linux from CIQ", p):
            add(path, ref(i), "WARN", "R19-ciq-word", "CIQ or product word: held back unless the owner approves")
        if not lens[i] and not raw.lstrip().startswith("|") and \
                re.search(r"\b(AlmaLinux|Alma Linux|CentOS Stream|Oracle Linux|Fedora)\b", p):
            add(path, ref(i), "WARN", "R23-other-distro", "other distro in the main line: use a collapsed Comparison lens")
        if re.search(r"\b[0-9a-fA-F]{32,}\b", p):
            add(path, ref(i), "WARN", "R36-long-hash", "long hex string in prose: put it in a code block")
        if raw.lstrip().startswith("|") and raw.count("|") - 1 > 4 and not re.match(r"^\s*\|[\s:|-]+\|\s*$", raw):
            if raw.strip().startswith("|") and i + 1 < n and re.match(r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
                add(path, ref(i), "WARN", "R37-wide-table", "table with more than 4 columns")

    # headings (outside fences)
    heads = []
    for i in range(n):
        if kind[i] == "":
            hm = re.match(r"^(#{1,4})\s+(.*?)\s*(\{#.*\})?$", lines[i])
            if hm:
                heads.append((i, len(hm.group(1)), hm.group(2)))
    allow = set("Rocky Linux Koji Pungi Peridot Red Hat RHEL AlmaLinux CentOS Stream Secure Boot "
                "MyOrg Lab Fedora GnuPG RPM DNF ISO SRPM OS EL10 Git GitLab GitHub Mock Mock's "
                "Anaconda Lorax KIWI EPEL SIG UEFI Apollo Rocky's Red openQA Sigul Bootc bootc "
                "Trust Pipeline Go".split())
    for i, lvl, t in heads:
        if lvl in (2, 3) and not t.startswith("Lab "):
            words = [w for w in re.split(r"\s+", re.sub(r"`[^`]*`", "", t)) if w]
            caps = [w for w in words[1:]
                    if re.match(r"^[A-Z][a-z]+$", w) and w not in allow]
            if len(caps) >= 2:
                add(path, ref(i), "WARN", "R22-heading-case", "heading looks like Title Case: use sentence case")

    # ---- skeleton
    fmtext = "\n".join(lines[k] for k in range(n) if kind[k] == "fm")
    if not re.search(r"^title:\s*\S", fmtext, re.M) or not re.search(r"^description:\s*\S", fmtext, re.M):
        add(path, 1, "ERROR", "R19-skeleton", "front matter needs title and description")
    h1 = [(i, t) for i, l, t in heads if l == 1]
    if not h1:
        add(path, 1, "ERROR", "R19-skeleton", "missing h1")
    elif num is not None and not h1[0][1].startswith("%02d · " % num):
        add(path, ref(h1[0][0]), "ERROR", "R19-skeleton", "h1 must start with '%02d · '" % num)

    metas = [i for i in range(n) if 'class="module-meta"' in lines[i]]
    if not metas:
        add(path, 1, "ERROR", "R19-skeleton", "missing <ul class=\"module-meta\"> bar")
    else:
        mt = []
        k = metas[0]
        while k < n and "</ul>" not in lines[k]:
            mt.append(lines[k])
            k += 1
        mtext = "\n".join(mt)
        if "⏱" not in mtext:
            add(path, ref(metas[0]), "ERROR", "R19-meta", "meta bar needs the time item")
        if not re.search(r"\blabs?\b", mtext):
            add(path, ref(metas[0]), "ERROR", "R19-meta", "meta bar needs a labs item")
        if "Builds on:" not in mtext and not exam:
            add(path, ref(metas[0]), "ERROR", "R19-meta", "meta bar needs 'Builds on:'")
        if not re.search(r"Environment: Tier [A-D]\b", mtext):
            add(path, ref(metas[0]), "ERROR", "R19-meta", "meta bar needs 'Environment: Tier A' to D")
        if not re.search(r"Verified: Rocky 10\.\d+, \d{4}-\d{2}-\d{2}", mtext):
            add(path, ref(metas[0]), "ERROR", "R19-meta", "meta bar needs 'Verified: Rocky 10.N, YYYY-MM-DD'")

    strips = [i for i in range(n) if kind[i] == "" and 'class="pipeline-strip"' in lines[i]]
    if len(strips) != 1:
        add(path, 1, "ERROR", "R19-strip", "need exactly one pipeline strip (found %d)" % len(strips))
    else:
        i = strips[0]
        tag = lines[i]
        if "markdown" not in tag:
            add(path, ref(i), "ERROR", "R06-markdown-attr", "pipeline strip div missing markdown attribute")
        dm = re.search(r'data-here="([^"]*)"', tag)
        if not dm:
            add(path, ref(i), "ERROR", "R19-strip", "pipeline strip needs data-here")
        else:
            vals = dm.group(1).split()
            if not vals or any(v not in STAGES + ["none"] for v in vals):
                add(path, ref(i), "ERROR", "R19-strip", "data-here must be stage names: " + ", ".join(STAGES))
        items = []
        k = i + 1
        while k < n and "</div>" not in lines[k]:
            im = re.match(r"^\d+\.\s+(.*\S)\s*$", lines[k])
            if im:
                items.append(im.group(1))
            k += 1
        if items != STAGE_NAMES:
            add(path, ref(i), "ERROR", "R19-strip", "strip list must be: " + ", ".join(STAGE_NAMES))
        tail = "\n".join(lines[k:k + 6])
        if not re.search(r"^\*You are here:", tail, re.M):
            add(path, ref(k), "ERROR", "R19-strip", "text equivalent '*You are here: ...*' must follow the strip")
        # strip must come before 'What you'll learn'
        wl = [j for j in range(n) if lines[j].lstrip().startswith('!!! abstract')]
        if wl and wl[0] < i:
            add(path, ref(i), "ERROR", "R19-strip", "pipeline strip must come before 'What you'll learn'")

    if not any(b["type"] == "abstract" for b in blocks):
        add(path, 1, "ERROR", "R19-skeleton", "missing !!! abstract \"What you'll learn\"")
    if not exam:
        if not any(b["type"] == "recap" for b in blocks):
            add(path, 1, "ERROR", "R19-skeleton", "missing !!! recap")
        if not any(re.match(r"^\*\*Next:\*\*", lines[j]) for j in range(n) if kind[j] == ""):
            add(path, 1, "ERROR", "R19-skeleton", "missing '**Next:** [..](..)' line")

    htext = {}
    for i, l, t in heads:
        htext.setdefault((l, t), i)

    def find_head(level, prefix):
        for i, l, t in heads:
            if l == level and t.startswith(prefix):
                return i
        return None

    if series and not exam:
        req = [(2, "The big picture"), (3, "The few things that solve most problems"),
               (3, "Words you'll see"), (2, "The core skill"), (2, "Labs"),
               (2, "Common pitfalls"), (2, "Cheat sheet"), (2, "Facts and freshness"),
               (2, "Flashcards"), (2, "Recap"), (2, "Go deeper")]
        if num != 53:
            req.insert(10, (2, "Add to your dossier"))
        pos = {}
        for lvl, pre in req:
            hi = find_head(lvl, pre)
            if hi is None:
                add(path, 1, "ERROR", "R19-section", "missing section: %s %s" % ("#" * lvl, pre))
            else:
                pos[pre] = hi
        tail_order = ["Labs", "Common pitfalls", "Cheat sheet", "Facts and freshness",
                      "Flashcards", "Recap", "Add to your dossier", "Go deeper"]
        seq = [(pos[t], t) for t in tail_order if t in pos]
        for a, b2 in zip(seq, seq[1:]):
            if b2[0] < a[0]:
                add(path, ref(b2[0]), "WARN", "R19-order", "'%s' should come after '%s'" % (b2[1], a[1]))
        if "The big picture" in pos:
            s0 = pos["The big picture"]
            e0 = n
            for i, l, t in heads:
                if l == 2 and i > s0:
                    e0 = i
                    break
            if not any(lines[k].startswith("> ") and kind[k] == "" for k in range(s0, e0)):
                add(path, ref(s0), "ERROR", "R19-mental-model", "no one-sentence '> ' mental-model blockquote under The big picture")
        if num != 53 and not any(b["type"] == "example" and b["title"].startswith("Dossier entry") for b in blocks):
            add(path, 1, "ERROR", "R19-dossier", "missing !!! example \"Dossier entry\" block")
        last = ""
        for k in range(n - 1, -1, -1):
            if lines[k].strip():
                last = lines[k].strip()
                break
        if not re.match(r"^\*Verified on Rocky 10\.\d+.*\d{4}-\d{2}-\d{2}.*\*$", last):
            add(path, n, "WARN", "R19-changelog", "last line should be '*Verified on Rocky 10.N ... YYYY-MM-DD. Re-verify trigger: ...*'")

    # ---- evidence / freshness / unknown / lab boxes
    def ev_above(i):
        k = i - 1
        while k >= 0 and lines[k].strip() == "":
            k -= 1
        return k >= 0 and RE_EV.match(lines[k]) is not None

    for b in blocks:
        t, title, s0, e0 = b["type"], b["title"], b["start"], b["end"]
        body = "\n".join(lines[s0 + 1:e0])
        if t == "evidence":
            if not title.startswith(EV_PREFIXES):
                add(path, ref(s0), "ERROR", "R13-evidence", "title must start with: " + " | ".join(EV_PREFIXES))
            if not ev_above(s0):
                add(path, ref(s0), "ERROR", "R13-ev-comment", "evidence box needs an '<!-- ev: ... -->' comment on the line above")
            if "**Seen on:**" not in body:
                add(path, ref(s0), "ERROR", "R13-evidence", "evidence box needs a **Seen on:** line")
            if "**Check it yourself:**" not in body and "**Re-check:**" not in body:
                add(path, ref(s0), "ERROR", "R13-evidence", "evidence box needs a **Check it yourself:** line")
        elif t == "freshness":
            if not re.match(r"^As of \d{4}-\d{2}-\d{2} on Rocky 10\.\d+", title):
                add(path, ref(s0), "ERROR", "R14-freshness", "title must be 'As of YYYY-MM-DD on Rocky 10.N'")
            if "**Re-check:**" not in body:
                add(path, ref(s0), "ERROR", "R14-freshness", "freshness box needs a **Re-check:** line")
            if not ev_above(s0):
                add(path, ref(s0), "ERROR", "R13-ev-comment", "freshness box needs an '<!-- ev: ... -->' comment on the line above")
        elif t == "unknown":
            if title != UNKNOWN_TITLE:
                add(path, ref(s0), "ERROR", "R15-unknown", "title must be exactly: " + UNKNOWN_TITLE)
        elif t == "lab":
            first = None
            for k in range(s0 + 1, e0):
                if lines[k].strip():
                    first = k
                    break
            items = {}
            if first is not None:
                k = first
                while k < e0 and re.match(r"^\s*[-*]\s+\*\*", lines[k]):
                    im = re.match(r"^\s*[-*]\s+\*\*(.+?)\*\*\s*(.*)$", lines[k])
                    if im:
                        items[im.group(1)] = im.group(2)
                    k += 1
            if list(items.keys())[:5] != LAB_LABELS:
                add(path, ref(s0), "ERROR", "R16-lab-status",
                    "lab must start with the status list: " + ", ".join("**%s**" % x for x in LAB_LABELS))
            else:
                if not re.match(r"^[A-D]\b", items["Tier"]):
                    add(path, ref(s0), "ERROR", "R16-lab-status", "Tier value must start with A, B, C or D")
                if not items["Status"].startswith(LAB_STATUS) or \
                        items["Status"].strip() not in LAB_STATUS:
                    add(path, ref(s0), "ERROR", "R16-lab-status", "Status must be Tested, Tested partly or Read-along")
                if not RE_DATE.search(items["Tested on"]):
                    add(path, ref(s0), "ERROR", "R16-lab-status", "'Tested on' needs a YYYY-MM-DD date")
            if "**Check your work" not in body:
                add(path, ref(s0), "ERROR", "R16-lab-parts", "lab missing **Check your work:**")
            if "**Clean up" not in body:
                add(path, ref(s0), "ERROR", "R16-lab-parts", "lab missing **Clean up:**")
    unk = [b for b in blocks if b["type"] == "unknown"]
    if series and not exam and len(unk) != 1:
        add(path, 1, "ERROR", "R15-unknown", "need exactly one !!! unknown box (found %d)" % len(unk))
    if exam and len(unk) > 1:
        add(path, 1, "ERROR", "R15-unknown", "at most one !!! unknown box")

    # ev comment format
    in_fence_ev = False
    for i in range(n):
        s = lines[i].strip()
        if s.startswith("<!--") and re.match(r"<!--\s*ev:", s):
            if kind[i] == "fence":
                continue
            if not RE_EV_OK.match(s):
                add(path, ref(i), "ERROR", "R25-ev-format",
                    "ev comment must be '<!-- ev: SOURCE ID | observed|official|inference|unverified | where and when -->' on one line, no '--' inside")
        elif kind[i] == "fence" and "<!-- ev:" in lines[i]:
            add(path, ref(i), "ERROR", "R25-ev-format", "ev comment inside a code fence")

    # ---- volatile numbers
    def dated_near(i, w=3):
        for k in range(max(0, i - w), min(n, i + w + 1)):
            if RE_DATE.search(lines[k]) or re.search(r"as of 20\d\d", lines[k], re.I):
                return True
        return False

    for i in prose:
        if kind[i] == "fm" or in_box[i] in ("freshness", "evidence"):
            continue
        p = strip_prose(lines[i])
        hit = RE_THOUSANDS.search(p) or RE_COUNTNOUN.search(p) or re.search(REGISTER, p)
        if hit and not dated_near(i):
            add(path, ref(i), "WARN", "R12-bare-number", "volatile-looking number '%s' with no date within 3 lines" % hit.group(0))
        if RE_PERCENT.search(p) and not re.search(r"\bof\s+[\d,]+|\bdenominator\b", p) and \
                re.search(r"\b(share|packages?|files?|builds?|built|rebuilt|RPMs?|identical|match(es|ed)?|signed|advisor(y|ies)|mirrors?|repos?)\b", p, re.I):
            add(path, ref(i), "WARN", "R12-percent", "percentage without a stated denominator ('N of M')")
        if re.search(r"\bPungi\b", p):
            lo, hi = max(0, i - 8), min(n, i + 9)
            if not any(re.search(r"as of 20\d\d", lines[k], re.I) for k in range(lo, hi)):
                add(path, ref(i), "WARN", "R34-pungi-undated", "Pungi named with no 'as of YYYY-MM' within 8 lines")
        if re.search(r"as of 20\d\d", p, re.I):
            if not any("Re-check:" in lines[k] for k in range(i, min(n, i + 9))):
                add(path, ref(i), "WARN", "R26-recheck", "'as of' claim with no Re-check: within 8 lines")

    # ---- widgets
    stack = []
    for i in range(n):
        if kind[i] != "":
            continue
        l = lines[i]
        for mt in re.finditer(r"<div\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)(>?)|</div>", l):
            if mt.group(0) == "</div>":
                if stack:
                    stack.pop()
                continue
            attrs = mt.group(1)
            if not mt.group(2):
                attrs += " " + " ".join(lines[i + 1:i + 3])
            cm = re.search(r'class="([^"]*)"', attrs)
            cls = None
            if cm:
                for c in cm.group(1).split():
                    if c in ALL_WIDGETS:
                        cls = c
                        break
            if cls:
                if not re.search(r"\bmarkdown\b", attrs) and cls != "pipeline-strip":
                    add(path, ref(i), "ERROR", "R06-markdown-attr", "<div class=\"%s\"> missing markdown attribute" % cls)
                if cls in TOP_WIDGETS and any(s in TOP_WIDGETS for s in stack):
                    add(path, ref(i), "ERROR", "R11-nested-widget", "widget nested inside another widget")
                if re.search(r'data-(expect|hint|match)="[^"]*"[^ >/]', l):
                    add(path, ref(i), "WARN", "R10-attr-quote", "possible unescaped quote in widget attribute (use &quot;)")
            stack.append(cls)
        if re.search(r'data-title="\d+[.)]\s', l):
            add(path, ref(i), "ERROR", "R07-numbered-title", "data-title must not be numbered")
    # quiz answer range
    for i in range(n):
        if kind[i] == "" and 'class="quiz"' in lines[i]:
            am = re.search(r'data-answer="(\d+)"', lines[i])
            if not am:
                add(path, ref(i), "ERROR", "R06-quiz", "quiz needs data-answer")

    # ---- mermaid
    for start, body in mermaid_blocks:
        head = ""
        for l in body:
            if l.strip():
                head = l.strip()
                break
        if head.startswith("timeline"):
            add(path, start + 1, "ERROR", "R08-timeline", "Mermaid timeline is not allowed")
        if re.match(r"^(flowchart|graph)\s+LR\b", head):
            ids = set()
            longest = 0
            for l in body:
                arrows = re.findall(r"-->|---|==>|-\.->|--\s[^>]*?-->", l)
                if arrows:
                    longest = max(longest, len(arrows) + 1)
                for tok in re.split(r"-->|---|==>|-\.->|\|[^|]*\|", l):
                    idm = re.match(r"^\s*([A-Za-z_]\w*)", tok)
                    if idm and idm.group(1) not in ("flowchart", "graph", "class", "classDef",
                                                    "style", "subgraph", "end", "linkStyle", "click"):
                        ids.add(idm.group(1))
            if longest >= 6:
                add(path, start + 1, "ERROR", "R09-lr-wide", "flowchart LR chain of %d nodes: use TB" % longest)
            elif len(ids) >= 8:
                add(path, start + 1, "WARN", "R09-lr-wide", "flowchart LR with %d nodes may shrink: consider TB" % len(ids))

    # ---- counts
    if series and not exam:
        txt_nofence = "\n".join(lines[i] for i in range(n) if kind[i] == "")
        diagrams = len(mermaid_blocks) + len(re.findall(r'class="(stepper|layers)"', txt_nofence))
        quizzes = len(re.findall(r'class="quiz"', txt_nofence))
        terms = len(re.findall(r'class="terminal-sim"', txt_nofence))
        labs = sum(1 for b in blocks if b["type"] == "lab")
        cards = len(re.findall(r'<div class="card"', txt_nofence))
        if diagrams < 3:
            add(path, 1, "WARN", "R21-counts", "%d diagrams (mermaid, layers, stepper), want at least 3" % diagrams)
        if quizzes < 3:
            add(path, 1, "WARN", "R21-counts", "%d quizzes, want at least 3" % quizzes)
        if terms < 1:
            add(path, 1, "WARN", "R21-counts", "no terminal-sim practice terminal")
        if labs < 3:
            add(path, 1, "WARN", "R21-counts", "%d labs, want at least 3" % labs)
        if not 6 <= cards <= 10:
            add(path, 1, "WARN", "R21-counts", "%d flashcards, want 6 to 10" % cards)
        for b in blocks:
            if b["type"] == "recap":
                bl = sum(1 for k in range(b["start"] + 1, b["end"]) if re.match(r"^\s{4}[-*]\s", lines[k]))
                if not 5 <= bl <= 8:
                    add(path, ref(b["start"]), "WARN", "R21-counts", "recap has %d bullets, want 5 to 8" % bl)

    if URLS:
        seen = set()
        for i in range(n):
            if kind[i] == "comment":
                continue
            for u in RE_URL.findall(lines[i]):
                u = u.rstrip(".,;")
                if u not in seen:
                    seen.add(u)
                    print("%s:%d: URL %s" % (path, i + 1, u))
    return n


total_lines = 0
for f in files:
    if not os.path.exists(f):
        print("%s: not found" % f, file=sys.stderr)
        sys.exit(2)
    total_lines += check(f)

order = {"ERROR": 0, "WARN": 1}
for path, line, level, rule, msg in sorted(findings, key=lambda x: (x[0], x[1], order[x[2]])):
    print("%s:%d: %s [%s] %s" % (path, line, level, rule, msg))

errs = sum(1 for f in findings if f[2] == "ERROR")
warns = sum(1 for f in findings if f[2] == "WARN")
if not QUIET:
    print("")
    print("check-series: %d file(s), %d line(s), %d error(s), %d warning(s)" % (len(files), total_lines, errs, warns))
    by = {}
    for f in findings:
        by[(f[3], f[2])] = by.get((f[3], f[2]), 0) + 1
    for (rule, level), c in sorted(by.items()):
        print("  %-22s %-5s %d" % (rule, level, c))
sys.exit(1 if errs or (STRICT and warns) else 0)
PYEOF
py_rc=$?

if [ -n "${MKDOCS:-}" ]; then
  if [ ! -x "$MKDOCS" ]; then
    echo "check-series: MKDOCS is set but not executable: $MKDOCS" >&2
    exit 2
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-series.XXXXXX") || exit 2
  trap 'rm -rf "$tmp"' EXIT INT TERM
  echo "check-series: running mkdocs build --strict into $tmp"
  if NO_MKDOCS_2_WARNING=1 "$MKDOCS" build --strict -d "$tmp" >"$tmp.log" 2>&1; then
    echo "check-series: mkdocs build --strict passed"
  else
    cat "$tmp.log"
    rm -f "$tmp.log"
    echo "check-series: mkdocs build --strict FAILED" >&2
    exit 1
  fi
  rm -f "$tmp.log"
fi

exit "$py_rc"
