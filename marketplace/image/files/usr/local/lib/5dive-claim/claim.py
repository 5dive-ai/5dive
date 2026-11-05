#!/usr/bin/env python3
# DIVE-7731: connect a marketplace server to 5dive from the browser, no terminal.
#
# A server made from the 5dive marketplace image does not know whose it is. Its
# owner's proof is the root password the hoster showed them. So, once, on first
# boot, the server serves one page on its own address (https, through the box's
# own Caddy front from `5dive secret https`, so the password never crosses plain
# HTTP):
#
#   1. https://<server>/        the owner types the root password. It is checked
#                               here against /etc/shadow and never leaves the box.
#   2. my.5dive.ai/self-host    sign in (Google); the page mints the usual one-time
#      ?server=<host>&claim=<s> code and, on one tap, posts it back to step 3.
#   3. https://<server>/claim/finish   the box checks the claim and its cookie (both
#                               made in step 1, for that browser only) and runs the
#                               same link line the self-host page shows:
#                               curl -fsSL https://install.5dive.ai/link | bash -s CODE
#   4. "Server connected"       then the page closes itself for good.
#
# It closes for good, and its route leaves Caddy, once the server is linked, after
# MAX_FAILS wrong passwords, or OPEN_HOURS after first boot. A server linked any
# other way (the login line, the self-host command) closes it too.
#
#   claim.py open     root, firstboot.sh: the https front, the route, the service
#   claim.py serve    root, 5dive-claim.service: the page on 127.0.0.1:3129
#   claim.py close    root: close it now (reason "manual")
#   claim.py status   prints open|closed:<reason>
#
# Every path below can be moved by an environment variable for the unit test
# (tests/marketplace_claim_unit.sh).
import ctypes, hashlib, hmac, html, json, os, re, secrets, subprocess, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E = os.environ.get
STATE_DIR = E("CLAIM_STATE_DIR", "/var/lib/5dive-claim")
SHADOW = E("CLAIM_SHADOW", "/etc/shadow")
TOKEN_FILE = E("CLAIM_TOKEN_FILE", "/etc/5dive/connectord.env")
SECRET_CONF = E("CLAIM_SECRET_CONF", "/etc/5dive/secret-drop.env")
CADDYFILE = E("CLAIM_CADDYFILE", "/etc/5dive/secret-https.Caddyfile")
CADDY_UNIT = E("CLAIM_CADDY_UNIT", "5dive-secret-https")
UNIT = E("CLAIM_UNIT", "5dive-claim")
CLI = E("CLAIM_CLI", "/usr/local/bin/5dive")
LINK_URL = E("CLAIM_LINK_URL", "https://install.5dive.ai/link")
APP = E("CLAIM_APP", "https://my.5dive.ai").rstrip("/")
LINK_LOG = E("CLAIM_LINK_LOG", "/var/log/5dive-claim-link.log")
PORT = int(E("CLAIM_PORT", "3129"))
OPEN_HOURS = float(E("CLAIM_OPEN_HOURS", "24"))
MAX_FAILS = int(E("CLAIM_MAX_FAILS", "10"))
SESSION_S = int(E("CLAIM_SESSION_S", "1800"))
# After "Server connected" was shown (or this long after linking if it never
# is), the page closes.
SHOWN_GRACE_S = int(E("CLAIM_SHOWN_GRACE_S", "30"))
LINKED_GRACE_S = int(E("CLAIM_LINKED_GRACE_S", "600"))
TICK_S = float(E("CLAIM_TICK_S", "15"))
NO_SYSTEMCTL = E("CLAIM_NO_SYSTEMCTL") == "1"

STATE = os.path.join(STATE_DIR, "state.json")
CLOSED = os.path.join(STATE_DIR, "closed")
CODE_RE = re.compile(r"^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$")
CLAIM_RE = re.compile(r"^[A-Za-z0-9_-]{32,64}$")
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")
BEGIN, END = "# 5dive-claim begin (DIVE-7731)", "# 5dive-claim end"

lock = threading.RLock()

# ---- state ------------------------------------------------------------------

def now():
    return int(time.time())

def closed_reason():
    try:
        with open(CLOSED) as fh:
            return fh.read().strip() or "closed"
    except OSError:
        return None

def load():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None

def save(st):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = STATE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(st, fh)
    os.replace(tmp, STATE)

def linked():
    try:
        with open(TOKEN_FILE) as fh:
            return any(l.startswith("CONNECTORD_TOKEN=") and len(l.strip()) > 17 for l in fh)
    except OSError:
        return False

def conf(key):
    v = None
    try:
        with open(SECRET_CONF) as fh:
            for l in fh:
                if l.startswith(key + "="):
                    v = l.split("=", 1)[1].strip()
    except OSError:
        pass
    return v

def front_host():
    h = conf("SECRET_HTTPS_HOST") or ""
    return h if HOST_RE.match(h) and "." in h else None

def public_ipv4():
    if E("CLAIM_IPV4"):
        return E("CLAIM_IPV4")
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", line)
        if not m:
            continue
        ip = m.group(1)
        if re.match(r"^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)", ip):
            continue
        return ip
    return None

# ---- the password: checked against /etc/shadow, here only ----------------------

_libcrypt = None

def _crypt(word, setting):
    global _libcrypt
    if _libcrypt is None:
        _libcrypt = ctypes.CDLL("libcrypt.so.1")
        _libcrypt.crypt.restype = ctypes.c_char_p
        _libcrypt.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    out = _libcrypt.crypt(word.encode(), setting.encode())
    return out.decode() if out else ""

def root_hash():
    """root's password hash, or None when root has no usable password (an SSH-key
    server: '*', '!', a locked '!$...', or empty)."""
    try:
        with open(SHADOW) as fh:
            for line in fh:
                f = line.rstrip("\n").split(":")
                if f[0] == "root" and len(f) > 1:
                    h = f[1]
                    return h if h.startswith("$") else None
    except OSError:
        pass
    return None

def password_ok(word):
    h = root_hash()
    if not h or not word or len(word) > 1024 or "\0" in word:
        return False
    try:
        return hmac.compare_digest(_crypt(word, h), h)
    except (OSError, UnicodeError, ValueError):
        return False

# ---- the route in the box's Caddy front ------------------------------------------

def route_block(host, ip):
    inner = ("\t%s\n\t@claim path / /claim /claim/*\n\thandle @claim {\n"
             "\t\treverse_proxy 127.0.0.1:%d\n\t}\n\t%s\n" % (BEGIN, PORT, END))
    outer = ""
    if ip and ip != host:
        # sslip.io front: the hoster's link names the bare IP over http.
        outer = "\n%s\nhttp://%s {\n\tredir https://%s{uri} 302\n}\n%s\n" % (BEGIN, ip, host, END)
    return inner, outer

def strip_route(text):
    out, skip = [], False
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s == BEGIN:
            skip = True; continue
        if s == END:
            skip = False; continue
        if not skip:
            out.append(line)
    return "".join(out).rstrip("\n") + "\n"

def with_route(text, host, ip):
    text = strip_route(text)
    inner, outer = route_block(host, ip)
    head = "https://%s {\n" % host
    i = text.find(head)
    if i < 0:
        return None
    j = i + len(head)
    return text[:j] + inner + text[j:].rstrip("\n") + "\n" + outer

def systemctl(*args):
    if NO_SYSTEMCTL:
        return 0
    try:
        return subprocess.run(["systemctl"] + list(args), stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=120).returncode
    except (OSError, subprocess.SubprocessError):
        return 1

def write_caddyfile(text):
    tmp = CADDYFILE + ".claim.tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o644)
    if not NO_SYSTEMCTL:
        r = subprocess.run(["caddy", "validate", "--config", tmp, "--adapter", "caddyfile"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode != 0:
            os.unlink(tmp)
            return False
    os.replace(tmp, CADDYFILE)
    return systemctl("restart", CADDY_UNIT) == 0

def ensure_route():
    """The claim route is in the front (a CLI step that rewrote the Caddyfile
    would have dropped it). True when it is there now."""
    host = front_host()
    try:
        with open(CADDYFILE) as fh:
            text = fh.read()
    except OSError:
        return False
    if not host:
        return False
    if BEGIN in text and ("https://%s {" % host) in text:
        return True
    new = with_route(text, host, public_ipv4())
    return bool(new) and write_caddyfile(new)

def drop_route():
    try:
        with open(CADDYFILE) as fh:
            text = fh.read()
    except OSError:
        return
    if BEGIN in text:
        write_caddyfile(strip_route(text))

# ---- open / close ------------------------------------------------------------

DROP_DELAY_S = 1.5

def _drop_and_disable():
    drop_route()
    systemctl("disable", UNIT)

def close(reason, answering=False):
    """Closed for good. answering=True when a request through the front is
    still waiting for its answer: dropping the route restarts Caddy, which cuts
    that very request, so the owner would see a broken page instead of why it
    closed. The marker is written now (every later request gets 410); the route
    leaves a moment after. A non-daemon timer, so the process waits for it."""
    with lock:
        if closed_reason():
            return
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        with open(CLOSED, "w") as fh:
            fh.write("%s %s\n" % (reason, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        try:
            os.unlink(STATE)
        except OSError:
            pass
        if answering:
            t = threading.Timer(DROP_DELAY_S, _drop_and_disable)
            t.daemon = False   # a request thread is a daemon; a Timer inherits that
            t.start()
        else:
            _drop_and_disable()
    log("closed: %s" % reason)

def log(msg):
    sys.stderr.write("5dive-claim: %s\n" % msg); sys.stderr.flush()

def cmd_open():
    if closed_reason():
        log("already closed (%s)" % closed_reason()); return 0
    if linked():
        close("linked-elsewhere"); return 0
    if load() is None:
        save({"opened": now(), "expires": now() + int(OPEN_HOURS * 3600), "fails": 0,
              "claims": {}, "link": None})
    # The box's own https front: an IP certificate, else <ip>.sslip.io. Without
    # it the password would cross plain HTTP, so no front means no page; the
    # login line's terminal path still works.
    if not front_host():
        try:
            r = subprocess.run([CLI, "secret", "https", "enable", "--via=auto"], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600).returncode
        except (OSError, subprocess.SubprocessError):
            r = 1
        if r != 0 or not front_host():
            close("no-https"); return 1
    if not ensure_route():
        close("no-route"); return 1
    systemctl("enable", UNIT)
    systemctl("restart", UNIT)
    log("open on https://%s/ until %s" % (front_host(), time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(load()["expires"]))))
    return 0

# ---- the link run ------------------------------------------------------------

def run_link(code):
    """The self-host line, exactly: curl <link> | bash -s CODE. The code goes on
    bash's argv, as the line puts it; the script never prints it."""
    rc, last = 1, ""
    try:
        with open(LINK_LOG, "ab") as lf:
            os.chmod(LINK_LOG, 0o600)
            lf.write(("--- link %s\n" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())).encode())
            dl = subprocess.run(["curl", "-fsSL", "--max-time", "120", LINK_URL],
                                capture_output=True, timeout=180)
            if dl.returncode != 0 or not dl.stdout:
                last = "Could not download the link step from 5dive. Check this server's internet connection."
            else:
                p = subprocess.run(["bash", "-s", code], input=dl.stdout, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=1800)
                lf.write(p.stdout)
                rc = p.returncode
                lines = [l.strip() for l in p.stdout.decode("utf-8", "replace").splitlines() if l.strip()]
                errs = [l for l in lines if l.startswith("error:")]
                last = (errs[-1][6:].strip() if errs else (lines[-1] if lines else ""))
    except (OSError, subprocess.SubprocessError) as e:
        last = "The link step stopped: %s" % type(e).__name__
    with lock:
        st = load()
        if st is None:
            return
        if rc == 0 and linked():
            st["link"] = {"state": "linked", "at": now()}
        else:
            st["link"] = {"state": "failed", "msg": last[:300] or "The link did not finish.", "at": now()}
        save(st)

# ---- pages -------------------------------------------------------------------

CSS = ("body{font:17px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;margin:0;background:#f6f6f4;color:#1b1b1a}"
       "main{max-width:26rem;margin:0 auto;padding:2.5rem 1rem}h1{font-size:1.5rem;line-height:1.25;margin:0 0 .75rem}"
       "p{margin:.6rem 0}.mark{font-weight:800;letter-spacing:-.02em;font-size:1.1rem;margin-bottom:2rem}"
       "input{display:block;width:100%;box-sizing:border-box;font:inherit;padding:.8rem;border:1px solid #bbb;"
       "border-radius:10px;margin:1rem 0 .75rem;background:#fff;color:inherit}"
       "button,.btn{display:block;width:100%;box-sizing:border-box;text-align:center;text-decoration:none;font:inherit;"
       "font-weight:700;padding:.85rem;border:0;border-radius:10px;background:#1b1b1a;color:#fff;cursor:pointer}"
       ".err{color:#b3261e;font-weight:600}.tip{background:#fff6dc;border-radius:10px;padding:.7rem .85rem}"
       "small{color:#666}.ok{font-size:3rem;line-height:1}"
       "@media (prefers-color-scheme:dark){body{background:#151514;color:#eee}input{background:#1f1f1e;border-color:#444}"
       "button,.btn{background:#eee;color:#151514}small{color:#aaa}.tip{background:#3a3220}.err{color:#ff8a80}}")

def page(title, body, refresh=None):
    meta = "<meta http-equiv=refresh content=%d>" % refresh if refresh else ""
    return ("<!doctype html><html lang=en><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content=noindex>%s<title>%s</title><style>%s</style></head>"
            "<body><main><div class=mark>5dive</div>%s</main></body></html>"
            % (meta, html.escape(title), CSS, body)).encode()

def password_page(err="", left=None):
    no_pw = root_hash() is None
    tip = ""
    if no_pw:
        tip = ("<p class=tip>This server has no root password yet: it was made with an SSH key. "
               "Get one without a terminal: in your hoster's control panel, open this server, then "
               "<b>Access › Reset root password</b>. The new password comes by email. Type it here.</p>")
    e = ""
    if err:
        e = "<p class=err>%s</p>" % html.escape(err)
    return page("Connect your server", (
        "<h1>Connect this server to 5dive</h1>"
        "<p>Type the root password your hoster shows for this server.</p>" + tip + e +
        "<form method=post action=/claim/password autocomplete=off>"
        "<input type=password name=password required autofocus autocomplete=off "
        "autocapitalize=off spellcheck=false aria-label='Root password' placeholder='Root password'>"
        "<button type=submit>Continue</button></form>"
        "<p><small>Checked here, on your server. It is never sent anywhere else. "
        "Next you sign in to 5dive.</small></p>"))

def closed_page():
    return page("Closed", "<h1>This page is closed</h1><p>To connect this server, log in to it "
                "(<code>ssh root@…</code>) and follow the line it shows, or open "
                "<b>my.5dive.ai/self-host</b>.</p>")

class Handler(BaseHTTPRequestHandler):
    server_version = "5dive"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 20

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body=b"", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        # The password form posts to this box; the finish form arrives from the
        # 5dive app, a top-level navigation that form-action does not cover.
        self.send_header("Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def redirect(self, url, headers=()):
        self.send(303, b"", [("Location", url)] + list(headers))

    def path_only(self):
        return self.path.split("?", 1)[0]

    def form(self):
        n = self.headers.get("Content-Length")
        if n is None or not n.isdigit() or int(n) > 8192:
            return None
        raw = self.rfile.read(int(n)).decode("utf-8", "replace")
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}

    def do_GET(self):
        p = self.path_only()
        if p == "/claim/healthz":
            return self.send(200, b"ok")
        with lock:
            st = load()
            if p == "/claim/linking":
                return self.linking(st)
            if closed_reason() or st is None:
                return self.send(410, closed_page())
            if p in ("/", "/claim", "/claim/"):
                return self.send(200, password_page())
        return self.send(404, page("Not found", "<h1>Not found</h1>"))

    do_HEAD = do_GET

    def do_POST(self):
        p = self.path_only()
        f = self.form()
        if f is None:
            return self.send(413, page("Too long", "<h1>That is too long</h1>"))
        if p == "/claim/password":
            return self.post_password(f)
        if p == "/claim/finish":
            return self.post_finish(f)
        return self.send(404, page("Not found", "<h1>Not found</h1>"))

    def post_password(self, f):
        host = front_host()
        origin = self.headers.get("Origin")
        if origin and host and origin != "https://" + host:
            return self.send(403, page("Not allowed", "<h1>Open this page from your server's own address</h1>"))
        word = f.get("password", "")
        with lock:
            st = load()
            if closed_reason() or st is None:
                return self.send(410, closed_page())
            if now() >= st["expires"]:
                close("expired", answering=True)
                return self.send(410, closed_page())
            if not password_ok(word):
                word = None
                st["fails"] = st.get("fails", 0) + 1
                save(st)
                if st["fails"] >= MAX_FAILS:
                    close("locked", answering=True)
                    return self.send(403, page("Locked", "<h1>Too many wrong passwords</h1><p>This page is "
                        "closed for good. To connect this server, log in to it (<code>ssh root@…</code>) "
                        "and follow the line it shows.</p>"))
                left = MAX_FAILS - st["fails"]
                return self.send(401, password_page("That is not this server's root password. %d %s left."
                                                    % (left, "try" if left == 1 else "tries")))
            word = None
            # The claim is the proof the password was typed: random, single use,
            # SESSION_S long, and only ever in this browser and the 5dive app's page.
            # Not a cookie: the way back is a cross-site POST, and Safari drops
            # cross-site cookies.
            claim = secrets.token_urlsafe(32)
            claims = {k: v for k, v in st.get("claims", {}).items() if now() - v <= SESSION_S}
            claims[hashlib.sha256(claim.encode()).hexdigest()] = now()
            st["claims"] = claims
            save(st)
        q = urllib.parse.urlencode({"server": host or "", "claim": claim})
        return self.redirect("%s/self-host?%s" % (APP, q))

    def post_finish(self, f):
        code, claim = f.get("code", "").strip().upper(), f.get("claim", "")
        with lock:
            st = load()
            if closed_reason() or st is None:
                return self.send(410, closed_page())
            at = st.get("claims", {}).get(hashlib.sha256(claim.encode()).hexdigest()) if CLAIM_RE.match(claim) else None
            if not at or now() - at > SESSION_S:
                return self.send(403, page("Start again", "<h1>Start again from your server</h1>"
                    "<p>This browser has not typed the server's password yet, or that was too long ago. "
                    "Open the link your hoster shows for this server again.</p>"))
            if not CODE_RE.match(code):
                return self.send(400, page("Start again", "<h1>That code is not from 5dive</h1>"
                    "<p>Open the link your hoster shows for this server again.</p>"))
            link = st.get("link") or {}
            if link.get("state") in ("running", "linked"):
                return self.redirect("/claim/linking")
            st["link"] = {"state": "running", "at": now()}
            st["claims"] = {}   # every claim is spent: one link per server
            save(st)
        threading.Thread(target=run_link, args=(code,), daemon=True).start()
        return self.redirect("/claim/linking")

    def linking(self, st):
        # No proof asked: it only says how the one link is going.
        if st is None:
            return self.send(410, closed_page())
        link = st.get("link") or {}
        state = link.get("state")
        if state == "running":
            return self.send(200, page("Connecting", "<h1>Connecting your server…</h1>"
                "<p>This takes under a minute. This page moves on by itself.</p>", refresh=2))
        if state == "linked":
            if not link.get("shown"):
                link["shown"] = now()
                st["link"] = link
                save(st)
            return self.send(200, page("Server connected", "<p class=ok>✓</p><h1>Server connected</h1>"
                "<p>Your agents are on 5dive now.</p>"
                "<a class=btn href='%s/tg'>Meet your team</a>" % html.escape(APP, quote=True)))
        if state == "failed":
            return self.send(200, page("Not connected", "<h1>Not connected yet</h1><p class=err>%s</p>"
                "<a class=btn href='/'>Try again</a>" % html.escape(link.get("msg", ""))))
        return self.redirect("/")

def watch(srv):
    while True:
        time.sleep(TICK_S)
        with lock:
            if closed_reason():
                break
            st = load()
            if st is None:
                close("no-state"); break
            link = st.get("link") or {}
            if link.get("state") == "linked":
                shown, at = link.get("shown"), link.get("at", 0)
                if (shown and now() - shown >= SHOWN_GRACE_S) or now() - at >= LINKED_GRACE_S:
                    close("linked"); break
                continue
            if link.get("state") == "running" and now() - link.get("at", 0) > 1900:
                # A run that outlived its own timeouts (the service restarted mid-run).
                st["link"] = {"state": "failed", "msg": "The link did not finish.", "at": now()}
                save(st)
            if link.get("state") != "running" and linked():
                close("linked-elsewhere"); break
            if now() >= st["expires"]:
                close("expired"); break
            ensure_route()
    srv.shutdown()

def cmd_serve():
    if closed_reason():
        log("closed (%s); not serving" % closed_reason()); return 0
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    threading.Thread(target=watch, args=(srv,), daemon=True).start()
    log("serving on 127.0.0.1:%d" % PORT)
    srv.serve_forever()
    return 0

def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "open":
        return cmd_open()
    if cmd == "serve":
        return cmd_serve()
    if cmd == "close":
        close(argv[2] if len(argv) > 2 else "manual"); return 0
    if cmd == "status":
        r = closed_reason()
        print("closed:" + r.split()[0] if r else ("open" if load() else "never-opened"))
        return 0
    sys.stderr.write("usage: claim.py open|serve|close|status\n")
    return 2

if __name__ == "__main__":
    sys.exit(main(sys.argv))
