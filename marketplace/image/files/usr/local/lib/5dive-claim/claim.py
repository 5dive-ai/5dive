#!/usr/bin/env python3
# DIVE-7756: connect a server made from the 5dive marketplace image to its
# owner's 5dive account, with no login of the server and no terminal.
#
# Vultr generates a random code for each server made from the 5dive app (a
# generated app variable, claim_code). It shows the owner one link that carries it,
#   https://5dive.ai/self-host#code=<code>
# and hands the same code to this server through its metadata service. This
# job, started once by firstboot.sh:
#   1. reads the code (no code: not a Vultr server of the app; it stops);
#   2. registers it with the 5dive API over HTTPS (only a hash is kept there);
#   3. waits for the owner: they open the link, sign in, tap Connect; the API
#      then holds the usual one-time link code for this server;
#   4. takes that code and runs the same link line the self-host page shows:
#      curl -fsSL https://install.5dive.ai/link | bash -s CODE
# Nothing listens on this server, and no login of the server is asked for or read.
# It stops for good once the server is linked (by this job or any other way),
# when the API says the code is used or expired (24 hours unclaimed), or after
# 25 hours. The codes are never logged or written to disk.
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

E = os.environ.get
API = E("CLAIM_API", "https://api.5dive.com").rstrip("/")
META_URL = E("CLAIM_META_URL", "http://169.254.169.254/v1/internal/app-claim_code")
LINK_URL = E("CLAIM_LINK_URL", "https://install.5dive.ai/link")
STATE_DIR = E("CLAIM_STATE_DIR", "/var/lib/5dive-claim")
TOKEN_FILE = E("CLAIM_TOKEN_FILE", "/etc/5dive/connectord.env")
LOG = E("CLAIM_LOG", "/var/log/5dive-claim.log")
FIRSTBOOT_DONE = E("CLAIM_FIRSTBOOT_DONE", "/var/lib/5dive-claim/firstboot-done")
POLL_S = float(E("CLAIM_POLL_S", "10"))
SLOW_POLL_S = float(E("CLAIM_SLOW_POLL_S", "30"))
SLOW_AFTER_S = float(E("CLAIM_SLOW_AFTER_S", str(2 * 3600)))
GIVE_UP_S = float(E("CLAIM_GIVE_UP_S", str(25 * 3600)))
FIRSTBOOT_WAIT_S = float(E("CLAIM_FIRSTBOOT_WAIT_S", str(20 * 60)))
META_TRIES = int(E("CLAIM_META_TRIES", "12"))
CLOSED = os.path.join(STATE_DIR, "closed")
STARTED = os.path.join(STATE_DIR, "started")
CODE_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")


def log(msg):
    try:
        with open(LOG, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    except OSError:
        pass


def linked():
    try:
        with open(TOKEN_FILE) as fh:
            return any(l.startswith("CONNECTORD_TOKEN=") and len(l.strip()) > 17 for l in fh)
    except OSError:
        return False


def close(why):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(CLOSED, "w") as fh:
        fh.write(why + "\n")
    log("closed: " + why)
    return 0


def started_at():
    """When this server's claim began (kept across reboots, so 25 hours is 25 hours)."""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    try:
        with open(STARTED) as fh:
            return float(fh.read().strip())
    except (OSError, ValueError):
        t = time.time()
        with open(STARTED, "w") as fh:
            fh.write("%d\n" % t)
        return t


def valid_code(c):
    return isinstance(c, str) and 16 <= len(c) <= 64 and set(c) <= CODE_CHARS


def read_code():
    """Vultr's metadata answers only with its header; anything else is no code."""
    for i in range(META_TRIES):
        try:
            req = urllib.request.Request(META_URL, headers={"METADATA-TOKEN": "vultr"})
            with urllib.request.urlopen(req, timeout=5) as r:
                c = r.read(200).decode("ascii", "replace").strip()
            return c if valid_code(c) else None
        except urllib.error.HTTPError:
            return None  # the metadata service answered: this server has no code
        except (urllib.error.URLError, OSError):
            if i + 1 < META_TRIES:
                time.sleep(5)  # the network may not be up yet
    return None


def post(path, body):
    """(status, json body); (0, None) when the API could not be reached."""
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"content-type": "application/json", "user-agent": "5dive-claim"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read(4096) or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read(4096) or b"null")
        except ValueError:
            return e.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None


def run_link(code):
    """The self-host line, exactly. The code goes on bash's command line, never in a URL."""
    try:
        dl = subprocess.run(["curl", "-fsSL", "--max-time", "120", LINK_URL],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=150)
        if dl.returncode != 0 or not dl.stdout:
            log("link: could not download the link step (curl %d)" % dl.returncode)
            return False
        with open(LOG, "ab") as lf:
            p = subprocess.run(["bash", "-s", code], input=dl.stdout, stdout=lf, stderr=lf, timeout=900)
        log("link: exit %d" % p.returncode)
        return p.returncode == 0 and linked()
    except (OSError, subprocess.SubprocessError) as e:
        log("link: stopped (%s)" % type(e).__name__)
        return False


def wait_firstboot():
    """firstboot.sh updates the CLI first; the link runs after it, or after the cap."""
    until = time.time() + FIRSTBOOT_WAIT_S
    while not os.path.exists(FIRSTBOOT_DONE) and time.time() < until:
        time.sleep(5)


def main():
    if os.path.exists(CLOSED):
        return 0
    if linked():
        return close("linked")
    t0 = started_at()
    code = read_code()
    if not code:
        return close("no code from the hoster")
    st, body = 0, None
    while time.time() - t0 < GIVE_UP_S:
        st, body = post("/connector/claim/register", {"code": code})
        if st == 200:
            break
        if st in (400, 403):
            return close("register refused (%d)" % st)
        time.sleep(POLL_S)
    state = (body or {}).get("state")
    if state == "expired":
        return close("expired")
    log("registered (%s)" % state)
    while time.time() - t0 < GIVE_UP_S:
        if linked():
            return close("linked")
        st, body = post("/connector/claim/poll", {"code": code})
        b = body or {}
        if st == 200 and b.get("state") == "code" and isinstance(b.get("code"), str):
            log("the owner connected this server; linking")
            wait_firstboot()
            if run_link(b["code"]):
                return close("linked")
            return close("link failed; see the log")
        if st in (404, 410):
            return close("code %s" % (b.get("state") or st))
        time.sleep(SLOW_POLL_S if time.time() - t0 > SLOW_AFTER_S else POLL_S)
    return close("gave up after %d hours" % (GIVE_UP_S // 3600))


if __name__ == "__main__":
    sys.exit(main())
