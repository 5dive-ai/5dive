# Security Policy

## Reporting a vulnerability

Please report security issues through GitHub's private vulnerability reporting:

**[Report a vulnerability →](https://github.com/5dive-com/5dive/security/advisories/new)**

Do **not** open a public issue, PR, or discussion thread for a suspected
vulnerability — that exposes other users before a fix is available.

If GitHub's reporting flow is unavailable for you, open a public issue asking
for a private contact and we'll reach out. Don't include any details of the
issue itself in the public issue.

## What to include

A useful report has, at minimum:

- The version / commit you tested against (`5dive --version`).
- Steps to reproduce, or a proof-of-concept.
- The impact you observed or believe is possible.
- Your environment (OS, distro, install method — apt one-liner, Docker, manual).

We may ask follow-up questions in the advisory thread before we can confirm.

## What to expect

- **Acknowledgement** within 3 business days.
- **Triage + initial assessment** within 7 days. If we can't reproduce or need
  more info, we'll say so in the advisory.
- **Fix timeline** depends on severity. Critical issues (RCE, auth bypass on a
  publicly-bound dashboard, agent-isolation escapes) are prioritized over
  everything else.
- **Coordinated disclosure.** We'll agree on a public-disclosure date with you
  before publishing the advisory. Credit is given by default — tell us if
  you'd rather stay anonymous.

## Supported versions

5dive is pre-1.0 and ships from `main`. Only the latest tagged release
and current `main` receive security fixes. Once v1.0 is out, this section
will list the supported version range.

## Scope

In scope:

- The `5dive` CLI and its installer (`install.sh`).
- The systemd units shipped by the installer.
- The `5dive-com/*` GitHub Actions workflows.

Out of scope (report upstream instead):

- Vulnerabilities in the underlying coding CLIs (`claude`, `codex`, `gemini`,
  `hermes`, `openclaw`, `opencode`) — report to their respective vendors.
- Vulnerabilities in apt/nvm/Node — report to their maintainers.
- Findings that require already having root on the host. 5dive trusts the
  host operator by design.

## Hardening guidance

If you're deploying 5dive somewhere accessible beyond your laptop, read the
**Securing your server** section in the README.
