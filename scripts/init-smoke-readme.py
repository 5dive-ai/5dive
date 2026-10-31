#!/usr/bin/env python3
# init-smoke-readme.py (DIVE-7370) — run every `5dive …` command the README
# shows, for real, on the fresh box init-smoke just set up. The README is the
# open-source front door: on 10-31 lodar found `5dive init` bugs a week after a
# by-hand README pass "said all fine". Nothing ran the README every night.
#
#   init-smoke-readme.py list <README.md>                    every command found, and what the arm does with it
#   init-smoke-readme.py run  <README.md> <result.json> [--no-model]
#
# WHAT IS A README COMMAND: a line in a fenced code block whose shell segment
# (split on && ; |) starts with `5dive` or `sudo 5dive`, and every backticked
# item in the first column of a table ("`5dive agent create` · `list` · `rm`":
# a bare item continues the noun before it). A table item that names a command
# a code block already shows ("agent import <pack>" vs "agent import olivia")
# is the same command, counted once. New README commands are picked up by
# themselves: nothing here lists what to RUN.
#
# THE HAND-KEPT PART is SKIP (a command this box cannot run, and why) and FILL
# (a table item names a command without the arguments it needs). A command in
# neither runs exactly as the README writes it, with its example names mapped
# onto this box (TEAM, PLACEHOLDER). It fails on a non-zero exit, a usage
# error or an unknown command; `--help` is never a run.
#
# --no-model: the box has no test key, so the commands that need the agent's
# answer (MODEL) are skipped with that reason; everything else still runs.
import json, os, re, shlex, subprocess, sys, time

AGENT = os.environ.get('README_AGENT', 'my-agent')

# Matched on the command's leading words (after `5dive`). Keep each reason one
# line: it is printed in the run summary next to the command.
SKIP = {
    'init': "the cell's own init step ran it, on a real terminal",
    'account login': 'interactive sign-in at a browser',
    'account set': 'needs a paid provider API key on stdin',
    'agent create': 'every README form needs a signed-in account or a paid provider key (init created this box\'s agent)',
    'agent switch': 'needs a signed-in Codex account',
    'team import': 'starts five agents on one runner; agent import runs the same import path',
    'secret https enable': 'needs a real domain pointed at the box',
    'watch': 'a live full-screen view: needs a person at a terminal',
    'wall': 'a live full-screen view: needs a person at a terminal',
    'self-update': 'would replace the CLI under test with the latest release',
}
MODEL = {'agent ask': 'no test key: the agent cannot answer'}

# A README command that fails today for a reason a row owns. It still runs,
# every night: a failure is reported as KNOWN with the row, not as red, and a
# pass is reported as a pass (then delete the entry). Never a skip by another
# name: each entry names an open row whose DONE WHEN removes it.
KNOWN = {
    'goal add': 'DIVE-7380',
    'agent export': 'DIVE-7380',
}

# Flags the README leaves to a person at a terminal (a confirmation prompt).
ADD = {'plugin add': ['--yes']}

# Bytes a command reads on stdin (a secret the README pipes in by hand).
STDIN = {'trigger add': b'readme-smoke-secret\n'}

# A table item that names a command but not the arguments it needs.
FILL = {
    'agent logs': ['agent', 'logs', AGENT, '--lines=20'],
    'agent rm': ['agent', 'rm', 'ceo'],  # the agent `agent import olivia --as=ceo` hired
    'human add': ['human', 'add', 'sam', '--name=Sam'],
    'company': ['company', '--yes', '--name=Init Smoke', '--objective=Ship the launch',
                '--metric-cmd=echo 1', '--target=2'],
    'objective add': ['objective', 'add', 'Readme smoke', '--metric-cmd=echo 1', '--target=2'],
    'trigger add': ['trigger', 'add', 'webhook', '--name=readme-smoke', '--event=deploy.done',
                    f'--assignee={AGENT}', '--secret-from-stdin'],
    'export': ['export', '-o', '5dive.yaml'],  # `up` reads ./5dive.yaml next
}

# The README's example teammates: this box has one agent.
TEAM = {'cmo', 'creative', 'devops', 'researcher'}
# A reviewer must not be the assignee: `--review=` gets the agent `agent import
# olivia --as=ceo` hired (README line order: import runs first, `agent rm` later).
REVIEWER = 'ceo'
PLACEHOLDER = {'<name>': AGENT, '<agent>': AGENT, '<query>': 'release checklist',
               '<outcome>': 'Write the launch post'}

# "command not found" counts only when it is 5dive's own: `doctor` reports a
# missing `gh` that way, and that is a finding, not a broken README command.
BAD_OUTPUT = re.compile(r'unknown (command|subcommand|verb|flag|option)|^\s*(error:\s*)?usage:|\b5dive\b[^\n]*command not found',
                        re.I | re.M)
CMD_LINE = re.compile(r'(^|[\s;&|])(sudo\s+)?5dive\s')


def segments(tokens):
    seg = []
    for t in tokens + ['&&']:
        if t in ('&&', '||', ';', '|'):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)


def strip_sudo(tokens):
    return tokens[1:] if tokens and tokens[0] == 'sudo' else tokens


def path_of(argv):
    """The command's leading words: up to the first placeholder, flag or quoted arg."""
    out = []
    for t in argv:
        if t.startswith(('-', '<')) or ' ' in t or re.search(r'[A-Z<>"]', t):
            break
        out.append(t)
    return out


def extract(readme):
    """[(line, argv-after-5dive, source)] in README order."""
    found, fence = [], False
    for n, line in enumerate(open(readme), 1):
        s = line.strip()
        if s.startswith('```'):
            fence = not fence
            continue
        if fence and CMD_LINE.search(s):
            try:
                toks = shlex.split(s, comments=True)
            except ValueError as e:
                found.append((n, None, f'unparsable: {e}'))
                continue
            for seg in segments(toks):
                seg = strip_sudo(seg)
                if seg and seg[0] == '5dive' and len(seg) > 1:
                    found.append((n, seg[1:], 'code'))
        elif not fence and s.startswith('|'):
            cell = s.strip('|').split('|')[0]
            lead = None
            for item in re.findall(r'`([^`]+)`', cell):
                try:
                    toks = strip_sudo(shlex.split(item))
                except ValueError:
                    continue
                if toks and toks[0] == '5dive':
                    argv = toks[1:]
                elif lead is None:
                    continue  # a table of something else (plugins, flags)
                elif len(lead) == 1 or toks[0] == lead[0]:
                    argv = toks
                else:
                    argv = [lead[0]] + toks
                if not argv:
                    continue
                lead = argv
                found.append((n, argv, 'table'))
    return found


def plan(readme, no_model):
    """Dedupe, then decide: (line, readme_text, action, argv_or_reason)."""
    out, seen_code = [], []
    seen = set()
    for n, argv, src in extract(readme):
        if argv is None:
            out.append((n, '(line %d)' % n, 'fail', src))
            continue
        text = '5dive ' + ' '.join(shlex.quote(a) for a in argv)
        p = path_of(argv)
        if src == 'table' and any(c[:len(p)] == p for c in seen_code):
            continue  # a code block already shows this command
        key = ' '.join(argv)
        if key in seen:
            continue
        seen.add(key)
        if src == 'code':
            seen_code.append(argv)
        joined = ' '.join(p)
        skip = next((r for k, r in SKIP.items() if joined == k or joined.startswith(k + ' ')), None)
        if skip:
            out.append((n, text, 'skip', skip))
            continue
        if no_model:
            r = next((r for k, r in MODEL.items() if joined == k or joined.startswith(k + ' ')), None)
            if r:
                out.append((n, text, 'skip', r))
                continue
        run = FILL.get(joined) if src == 'table' and joined in FILL and argv == p else None
        if run is None:
            run = [AGENT if a in TEAM else a for a in argv]
            run = [re.sub(r'^(--[a-z-]+=)(\w+)$', lambda m: m.group(1) + (
                       (REVIEWER if m.group(1) == '--review=' else AGENT) if m.group(2) in TEAM else m.group(2)), a)
                   for a in run]
        add = next((v for k, v in ADD.items() if joined == k or joined.startswith(k + ' ')), [])
        run = list(run) + [a for a in add if a not in run]
        out.append((n, text, 'run', run))
    return out


def fill_runtime(argv, state):
    res = []
    for a in argv:
        for k, v in PLACEHOLDER.items():
            a = a.replace(k, v)
        if state.get('task'):
            a = a.replace('<task>', state['task'])
            a = re.sub(r'\bDIVE-\d+\b', state['task'], a)
        res.append(a)
    return res


def run(readme, result_path, no_model):
    work = '/tmp/init-smoke-readme'
    os.makedirs(work, exist_ok=True)
    state, results = {}, []
    for n, text, action, what in plan(readme, no_model):
        r = {'line': n, 'readme': text, 'status': action}
        if action != 'run':
            r['why'] = what
            results.append(r)
            print(f'--- README:{n} {text}\n    {action.upper()}: {what}', flush=True)
            continue
        argv = fill_runtime(what, state)
        left = [a for a in argv if re.search(r'<[a-z-]+>', a)]
        r['ran'] = '5dive ' + ' '.join(shlex.quote(a) for a in argv)
        print(f'--- README:{n} {text}\n    $ {r["ran"]}', flush=True)
        if left:
            r.update(status='fail', why=f'no value for {left[0]}: add it to FILL or SKIP in init-smoke-readme.py')
            results.append(r)
            print('    FAIL: ' + r['why'], flush=True)
            continue
        path = ' '.join(path_of(argv))
        feed = next((v for k, v in STDIN.items() if path == k or path.startswith(k + ' ')), None)
        t0 = time.time()
        try:
            p = subprocess.run(['5dive'] + argv, cwd=work, input=feed if feed is not None else b'',
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
            rc, out = p.returncode, p.stdout.decode(errors='replace')
        except subprocess.TimeoutExpired as e:
            rc, out = 124, (e.stdout or b'').decode(errors='replace') + '\n(timed out after 900s)'
        r['rc'], r['secs'] = rc, round(time.time() - t0, 1)
        tail = [l for l in out.splitlines() if l.strip()][-12:]
        print('\n'.join('    | ' + l[:240] for l in tail), flush=True)
        bad = BAD_OUTPUT.search(out)
        if rc != 0:
            r.update(status='fail', why=f'exited {rc}: ' + (tail[-1][:200] if tail else '(no output)'))
        elif bad:
            r.update(status='fail', why='exited 0 but printed: ' + bad.group(0).strip()[:200])
        else:
            r['status'] = 'pass'
        known = next((v for k, v in KNOWN.items() if path == k or path.startswith(k + ' ')), None)
        if known and r['status'] == 'fail':
            r.update(status='known', why=f'known-broken, {known}: ' + r['why'])
        if argv[:2] == ['task', 'add'] and r['status'] == 'pass':
            m = re.search(r'\b[A-Z][A-Z0-9]*-\d+\b', out)
            if m:
                state['task'] = m.group(0)
        print(f'    {r["status"].upper()} ({r["secs"]}s)' + (': ' + r['why'] if r['status'] in ('fail', 'known') else ''), flush=True)
        results.append(r)
    ran = sum(1 for r in results if r['status'] == 'pass')
    failed = [r for r in results if r['status'] == 'fail']
    skipped = [r for r in results if r['status'] == 'skip']
    known = [r for r in results if r['status'] == 'known']
    line = f'README: {ran} of {len(results)} commands ran'
    if failed:
        line += f', {len(failed)} failed'
    if known:
        line += f', {len(known)} known-broken (' + '; '.join(
            ' '.join(path_of(shlex.split(r['readme'])[1:])[:2]) + ' ' + r['why'].split(':')[0].split(', ')[1] for r in known) + ')'
    line += f', {len(skipped)} skipped'
    if skipped:
        names = {}
        for r in skipped:
            k = ' '.join(path_of(shlex.split(r['readme'])[1:])[:2])
            names[k] = names.get(k, 0) + 1
        line += ' (' + '; '.join(k + (f' x{n}' if n > 1 else '') for k, n in names.items()) + ')'
    json.dump({'line': line, 'total': len(results), 'ran': ran, 'failed': len(failed),
               'skipped': len(skipped), 'known': len(known), 'commands': results}, open(result_path, 'w'), indent=1)
    print('\n' + line, flush=True)
    for r in failed + known:
        print(f'README {"FAIL" if r in failed else "KNOWN"} line {r["line"]}: {r["readme"]}: {r["why"]}', flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == 'list':
        for n, text, action, what in plan(a[1], '--no-model' in a):
            print(f'{n:4} {action:4} {text}\n          -> {what if action != "run" else "5dive " + " ".join(shlex.quote(x) for x in what)}')
    elif len(a) >= 3 and a[0] == 'run':
        sys.exit(run(a[1], a[2], '--no-model' in a))
    else:
        sys.exit('usage: init-smoke-readme.py list <README.md> | run <README.md> <result.json> [--no-model]')
