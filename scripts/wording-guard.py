#!/usr/bin/env python3
"""Public wording guard (DIVE-5627).

Our public repos name no country, city, partner or region-only service as a
market, a customer or a place we run. Agents write most of what lands here, so
the rule lives in this check rather than in a document: it reads every tracked
file, and on a pull request also its title, body, branch name and commit
messages. A hit fails the job and names the word.

A LANGUAGE is fine ("99+ languages incl. Russian", ru UI strings next to zh),
and so is a literature reference. Where a comment needs to name a partner,
write "a partner".

The deny list is stored base64-encoded so that this file, which every public
repo fetches, does not itself carry the words it refuses. Decode it with
`python3 scripts/wording-guard.py --print-patterns`.

Every public 5dive-ai repo runs this file from 5dive-ai/5dive@main through the
reusable workflow .github/workflows/wording-guard.yml; there is no second copy.

  python3 wording-guard.py                 scan the checkout (+ the PR, from env)
  python3 wording-guard.py --self-test     prove a hit is red and a clean tree green
  python3 wording-guard.py --text "..."    scan one string (exit 1 on a hit)

PR env (all optional): PR_TITLE, PR_BODY, PR_BRANCH, BASE_SHA, HEAD_SHA.
"""
import base64
import os
import re
import subprocess
import sys
import tempfile

_DENY_B64 = [
    "cnVzc2lhKD8hbik=",
    "cnVzc2lhbltccy1dKyg/OmJveHxib3hlc3xyZWdpb258Y2xpZW50fGN1c3RvbWVyfHBhcnRuZXJ8bWFya2V0fHNwZWFrZXJ8c3BlYWtpbmd8dXNlcnxzZXJ2ZXJ8aG9zdHxjbG91ZHxjb21wYW58YnVzaW5lc3N8b3duZXJ8YWRkZXIp",
    "bW9zY293",
    "0LzQvtGB0LrQsg==",
    "0YDQvtGB0YHQuCg/OtGPfNC4fNGOfNC10Ll80LnRgdC6KQ==",
    "KD88IVx3KdGA0YQoPyFcdyk=",
    "b2lub2E=",
    "dGltZXdlYg==",
    "eWFuZGV4",
    "0Y/QvdC00LXQutGB",
    "bW95c2tsYWQ=",
    "0LzQvtC5ID/RgdC60LvQsNC0",
    "KD8taTooPzwhW1x3Li1dKVthLXowLTldW2EtejAtOS1dKig/OlwuW2EtejAtOS1dKykqXC5ydSkoPyFbXHcoXFstXXxcLlthLXpdKQ==",
]
DENY = re.compile("|".join("(?:%s)" % base64.b64decode(p).decode() for p in _DENY_B64), re.I)

# Vendored data we do not write (emoji keyword tables, installed packages).
SKIP_PATHS = re.compile(r"(^|/)(node_modules|vendor)/|(^|/)emoji-data\.json$")

ADVICE = ('public repos name no country, city, partner or region-only service. '
          'Write "a partner"; Russian as a language is fine.')

MAX_BYTES = 2_000_000


def hits(text):
    return [m.group(0) for m in DENY.finditer(text)]


QUIET = False


def annotate(where, word, line=None):
    if QUIET:
        return
    loc = "file=%s,line=%d" % (where, line) if line else "title=%s" % where
    print('::error %s::found "%s": %s' % (loc, word, ADVICE))


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, check=True).stdout


def scan_tree(cwd=None):
    bad = 0
    for raw in git("ls-files", "-z", cwd=cwd).split(b"\0"):
        path = raw.decode("utf-8", "replace")
        if not path or SKIP_PATHS.search(path):
            continue
        full = os.path.join(cwd or ".", path)
        try:
            if os.path.islink(full) or not os.path.isfile(full) or os.path.getsize(full) > MAX_BYTES:
                continue
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\0" in data:
            continue
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            for w in hits(line):
                annotate(path, w, n)
                bad += 1
    return bad


def scan_pr(env, cwd=None):
    bad = 0
    for label in ("PR_TITLE", "PR_BODY", "PR_BRANCH"):
        for w in hits(env.get(label) or ""):
            annotate(label.lower().replace("_", " "), w)
            bad += 1
    base, head = env.get("BASE_SHA"), env.get("HEAD_SHA")
    if base and head:
        log = git("log", "--format=%H%x00%B%x1e", "%s..%s" % (base, head), cwd=cwd).decode("utf-8", "replace")
        for entry in log.split("\x1e"):
            sha, _, msg = entry.strip().partition("\0")
            for w in hits(msg):
                annotate("commit " + sha[:12], w)
                bad += 1
    return bad


def self_test():
    """The guard must be red on a hit and green without one, and keep language words."""
    global QUIET
    QUIET = True
    word = base64.b64decode("TW9zY293").decode()
    fails = []

    def expect(name, got, want):
        print("  %s %s" % ("ok  " if got == want else "FAIL", name))
        if got != want:
            fails.append(name)

    with tempfile.TemporaryDirectory() as d:
        git("init", "-q", cwd=d)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base", cwd=d)
        base = git("rev-parse", "HEAD", cwd=d).decode().strip()
        with open(os.path.join(d, "a.md"), "w") as f:
            f.write("Voice covers 99+ languages incl. Russian; ru strings sit next to zh.\n"
                    "TAP_STRINGS.ru and LITE_STRINGS.ru.failed are i18n tables.\n")
        git("add", "a.md", cwd=d)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "clean", cwd=d)
        expect("a clean tree (language words only) is green", scan_tree(d), 0)
        head = git("rev-parse", "HEAD", cwd=d).decode().strip()
        expect("a clean PR is green", scan_pr({"PR_TITLE": "fix: x", "BASE_SHA": base, "HEAD_SHA": head}, d), 0)
        with open(os.path.join(d, "a.md"), "a") as f:
            f.write("Reminders fire at 9 %s time.\n" % word)
        git("add", "a.md", cwd=d)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tz for %s" % word, cwd=d)
        head = git("rev-parse", "HEAD", cwd=d).decode().strip()
        expect("a tracked file naming the city is red", scan_tree(d) > 0, True)
        expect("a commit message naming the city is red", scan_pr({"BASE_SHA": base, "HEAD_SHA": head}, d) > 0, True)
    expect("a PR title naming the city is red", scan_pr({"PR_TITLE": "feat: %s timezone" % word}) > 0, True)
    expect("a PR body naming the city is red", scan_pr({"PR_BODY": "for %s users" % word}) > 0, True)
    expect("a branch name naming the city is red", scan_pr({"PR_BRANCH": "fix/%s-tz" % word.lower()}) > 0, True)
    print("self-test: %s" % ("FAIL " + ", ".join(fails) if fails else "all arms pass"))
    return 1 if fails else 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if "--print-patterns" in argv:
        for p in _DENY_B64:
            print(base64.b64decode(p).decode())
        return 0
    if "--text" in argv:
        found = hits(argv[argv.index("--text") + 1])
        for w in found:
            print('found "%s": %s' % (w, ADVICE))
        return 1 if found else 0
    bad = scan_tree() + scan_pr(os.environ)
    if bad:
        print("wording-guard: %d hit(s). %s" % (bad, ADVICE))
        return 1
    print("wording-guard: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
