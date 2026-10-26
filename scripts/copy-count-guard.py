#!/usr/bin/env python3
"""Catalogue-count guard (DIVE-6998).

Our READMEs and docs do not type how many agents the marketplace has. The
number changes every time a pack is added or cut (DIVE-6997 took 36 to 35), and
a typed one is wrong from that merge on. lodar, 2026-10-26: "why someone
hardcoded 36 agents everywhere? what if we add or remove an agent". Say
"ready-made agents and teams" instead; a screen that needs the number reads it
from the marketplace index.json, it never types it.

It reads README*.md and docs/**/*.md, the copy a stranger reads, in English,
Russian and Chinese. A hit fails the job and names the line. A line that
really means a fixed number that is not the catalogue's (a plan limit, "Hire 10
agents") carries the marker `count-ok` in an HTML comment.

  python3 copy-count-guard.py                scan the checkout
  python3 copy-count-guard.py --self-test    prove a typed count is red and a clean tree green
  python3 copy-count-guard.py --text "..."   scan one string (exit 1 on a hit)
"""
import os
import re
import subprocess
import sys
import tempfile

COUNT = re.compile(
    r"\b\d+\+?\s+(?:ready-made|ready|prebuilt|pre-built|curated)\b"
    r"|\b\d+\+?\s+(?:AI\s+|specialist\s+)?(?:agents|personas|characters)\b"
    r"|\bthree\s+dozen\b|\b(?:over|more\s+than)\s+(?:twenty|thirty|forty)\s+agents\b"
    r"|\d+\s*个(?:现成的)?(?:智能体|角色)"
    r"|\d+\+?\s+(?:готов\w*\s+)?агент",
    re.I,
)
ALLOW = "count-ok"
COPY = re.compile(r"^(?:[^/]*/)*README[^/]*\.md$|^docs/.*\.md$", re.I)

ADVICE = ('do not type how many agents the marketplace has; it changes with every pack. '
          'Write "ready-made agents and teams" (or mark a fixed plan number with <!-- count-ok -->).')

QUIET = False


def hits(line):
    if ALLOW in line:
        return []
    return [m.group(0) for m in COUNT.finditer(line)]


def annotate(where, word, line):
    if not QUIET:
        print('::error file=%s,line=%d::found "%s": %s' % (where, line, word, ADVICE))


def scan_tree(cwd=None):
    bad = 0
    out = subprocess.run(["git", "ls-files", "-z"], cwd=cwd, capture_output=True, check=True).stdout
    for raw in out.split(b"\0"):
        path = raw.decode("utf-8", "replace")
        if not path or not COPY.search(path) or "node_modules/" in path:
            continue
        full = os.path.join(cwd or ".", path)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        with open(full, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                for w in hits(line):
                    annotate(path, w, n)
                    bad += 1
    return bad


def self_test():
    """A typed count is red in each language, the copy we ship instead is green."""
    global QUIET
    QUIET = True
    fails = []

    def expect(name, got, want):
        print("  %s %s" % ("ok  " if got == want else "FAIL", name))
        if got != want:
            fails.append(name)

    for text in ("The marketplace has 36 ready-made agents.", "Hire any of our 36 agents",
                 "36+ agents", "three dozen agents", "市场里有 36 个现成的智能体",
                 "36 готовых агентов"):
        expect("red: %s" % text, bool(hits(text)), True)
    for text in ("Hire ready-made agents from the marketplace, or a whole team at once.",
                 "Hire 10 agents or create your own <!-- count-ok -->",
                 "雇用现成的智能体", "Нанять готовых агентов или команду"):
        expect("green: %s" % text, bool(hits(text)), False)

    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["git", "init", "-q"], cwd=d, check=True)
        with open(os.path.join(d, "README.md"), "w") as f:
            f.write("Hire ready-made agents, or a whole team at once.\n")
        with open(os.path.join(d, "CHANGELOG.md"), "w") as f:
            f.write("crash-looped 19/21 agents; the marketplace had 36 ready-made agents\n")
        subprocess.run(["git", "add", "."], cwd=d, check=True)
        expect("a clean README (a changelog is history, not copy) is green", scan_tree(d), 0)
        with open(os.path.join(d, "README.md"), "a") as f:
            f.write("The marketplace has 36 ready-made agents.\n")
        expect("a README typing the count is red", scan_tree(d) > 0, True)

    QUIET = False
    if fails:
        print("self-test FAILED: %d" % len(fails))
        return 1
    print("self-test ok")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if "--text" in argv:
        found = hits(argv[argv.index("--text") + 1])
        for w in found:
            print('found "%s": %s' % (w, ADVICE))
        return 1 if found else 0
    bad = scan_tree()
    print("copy-count-guard: %d hit(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
