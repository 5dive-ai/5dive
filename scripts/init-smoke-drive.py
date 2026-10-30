#!/usr/bin/env python3
# init-smoke-drive.py (DIVE-7337) — answer `5dive init` on a real terminal (a
# pty, TERM=dumb so menus are numbered) the way a person would, let it create
# the agent, and wait for it to exit.
#
#   init-smoke-drive.py <steps.json> <log> <result.json>
#
# steps.json is a list of {"wait": <regex>, ...} with ONE answer key:
#   "pick": "<label>"   choose the numbered menu line whose label is <label>
#                       (by label, so a reordered menu cannot pick the wrong one)
#   "secret": true      type $INIT_SMOKE_KEY, then Enter (masked prompt)
#   "send": "<text>"    type <text> as is ("\n" = take the default)
# A step waits up to "secs" (default 300) for its prompt. The first prompt after
# the type pick sits behind the agent tool's own install, so it gets more.
#
# init that stops at a prompt no step expects (hermes asking for the key a
# second time, DIVE-7330) times out on the next step's wait, and the result
# names the last line init printed. The key never reaches the log.
import json, os, pty, re, select, sys, time

steps_path, log_path, result_path = sys.argv[1:4]
steps = json.load(open(steps_path))
key = os.environ.pop('INIT_SMOKE_KEY', '')
log = open(log_path, 'w')
T0 = time.time()


def redact(s):
    if key:
        s = s.replace(key, '<KEY>')
    return re.sub(r'sk-[A-Za-z0-9_-]{16,}', '<KEY>', s)


def note(msg):
    log.write(f'\n[drive {time.time() - T0:7.1f}s] {msg}\n')
    log.flush()


def finish(ok, detail, rc=None):
    note(f'result ok={ok} rc={rc}: {detail}')
    json.dump({'ok': ok, 'rc': rc, 'detail': detail, 'secs': round(time.time() - T0, 1)},
              open(result_path, 'w'))
    sys.exit(0 if ok else 1)


pid, fd = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'dumb'
    os.environ['COLUMNS'] = '120'
    os.execvp('5dive', ['5dive', 'init'])

buf = ''
seen = ''


def pump(t):
    """Read what init printed; False once the pty is closed (init exited)."""
    global buf, seen
    r, _, _ = select.select([fd], [], [], t)
    if not r:
        return True
    try:
        d = os.read(fd, 4096).decode('utf-8', 'replace')
    except OSError:
        return False
    if not d:
        return False
    buf += d
    seen = (seen + d)[-20000:]
    log.write(redact(d))
    log.flush()
    return True


def last_line():
    lines = [l.strip() for l in re.split(r'[\r\n]+', seen) if l.strip()]
    return redact(lines[-1])[:300] if lines else '(init printed nothing)'


EXIT = None


def reap():
    """init's exit code once it has exited, else None (kept: a pid reaps once)."""
    global EXIT
    if EXIT is None:
        try:
            p, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if p:
            EXIT = os.waitstatus_to_exitcode(st)
    return EXIT


for i, st in enumerate(steps):
    pat = st['wait']
    end = time.time() + st.get('secs', 300)
    m = None
    while time.time() < end:
        m = re.search(pat, buf)
        if m:
            break
        if not pump(1):
            break
    if not m:
        rc = reap()
        if rc is not None:
            finish(False, f'init exited {rc} before {pat!r}; its last line: {last_line()}', rc)
        finish(False, f'init never asked {pat!r} (waited {st.get("secs", 300)}s); its last line: {last_line()}')
    shown = m.group(0)
    buf = buf[m.end():]
    time.sleep(0.3)
    if 'pick' in st:
        n = None
        for line in shown.splitlines():
            # "    3. <label padded to 18> <description>"; a long label
            # leaves one space before its description.
            mm = re.match(r'\s*(\d+)\.\s+(.*)$', line)
            rest = mm.group(2).rstrip() if mm else ''
            if rest == st['pick'] or rest.startswith(st['pick'] + ' '):
                n = mm.group(1)
        if n is None:
            finish(False, f'menu {pat!r} has no option {st["pick"]!r}')
        os.write(fd, (n + '\n').encode())
        note(f'picked {n} ({st["pick"]})')
    elif st.get('secret'):
        if not key:
            finish(False, 'no key to type (INIT_SMOKE_KEY is empty)')
        os.write(fd, (key + '\r').encode())
        note('typed the key + Enter')
    else:
        os.write(fd, st['send'].encode())
        note(f'sent {st["send"]!r}')

# Every answer given: init now installs config and creates the agent.
end = time.time() + 1200
while time.time() < end and pump(1):
    rc = reap()
    if rc is not None:
        break
rc = reap()
if rc is None:
    if time.time() >= end:
        os.kill(pid, 15)
        finish(False, f'init still running 1200s after the last answer; its last line: {last_line()}')
    _, st = os.waitpid(pid, 0)
    rc = EXIT = os.waitstatus_to_exitcode(st)
if rc != 0:
    finish(False, f'init exited {rc} after the last answer; its last line: {last_line()}', rc)
if not re.search(r'is ready', seen):
    finish(False, f'init exited 0 but never said the agent is ready; its last line: {last_line()}', rc)
finish(True, 'init finished', rc)
