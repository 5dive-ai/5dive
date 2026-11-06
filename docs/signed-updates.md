# Signed updates

Every online `5dive self-update` checks that the release was signed by 5dive
before it runs anything on your server. An update that is unsigned, changed
after signing, or signed by a key 5dive has revoked is refused, and your server
keeps the version it has.

## How it works

- **Root key.** An offline ed25519 key that never sits on a server. Its public
  half is built into the 5dive program on your server. It signs only two
  things: the current signing key (with an expiry date) and a list of revoked
  keys.
- **Signing key.** Lives on one machine of its own. It signs each release: the
  version, the commit, and the sha256 of the `5dive` program and of `install.sh`.
- **Your server** downloads the signed files, checks them against the root key
  it already holds, downloads the installer and the program from the signed
  commit, checks both hashes, and only then installs. Nothing it downloads can
  vouch for itself.

The checks use `openssl`, which every supported server already has.

## Rollout

The first release with these checks is **warn-only**: a failed check is logged,
shown by `5dive doctor` (`update-signature`), and the update still installs the
old way. The release after that **enforces**: a failed check refuses the update.

## What is not covered

- **The very first install** (`curl -fsSL https://install.5dive.com | bash`).
  There is no 5dive on the server yet to hold the key, so that download is
  protected only by HTTPS. If you want to check it by hand, compare the root
  key fingerprint below with the one in the program you installed:
  `grep -A3 SIGNED_UPDATE_ROOT_PUBKEY_PEM= /usr/local/bin/5dive`.
- **A server that never saw a revocation.** A server keeps the newest
  revocation list it has seen. One that was offline when a key was revoked
  trusts that key until its certificate expires.

## Root key fingerprint

Published here once the root key exists (sha256 of the DER public key).

## For maintainers

`packaging/signing/5dive-release-sign` makes every signed file (`keygen`,
`certify`, `revocations`, `sign-tag`, `publish`). The six files hang off the
tag's GitHub release: `signing-key.json/.sig`, `revoked.json/.sig`,
`release.json/.sig`. The box side is `src/lib/signed_update.sh`.
