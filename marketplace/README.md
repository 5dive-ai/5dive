# 5dive on hosting marketplaces

Someone who rents a server finds 5dive in the hoster's app list and gets a
working 5dive server in one click (DIVE-6801).

| Where | What we submit | Folder |
|---|---|---|
| DigitalOcean Marketplace (1-Click) | a snapshot built with Packer, sent from the Vendor Portal | `digitalocean/` + `image/` |
| Vultr Marketplace | a snapshot built with Packer, turned into an app image in the vendor portal | `vultr/` + `image/` |
| Linode (Akamai) Marketplace | an Ansible app, sent as a pull request to `akamai-compute-marketplace/marketplace-apps` | `linode/` |

Nothing here is listed or published until the listing copy in `LISTING.md` has
lodar's yes. It is public, under our brand.

## The image (`image/`)

Ubuntu 24.04 LTS plus our `install.sh`, split in two:

- **Build time** (`build.sh`): updates, the firewall (SSH, 80, 443), the 5dive CLI
  from the newest release, the login line and the first-boot step.
- **Clean-up** (`cleanup.sh`): removes everything that belongs to ONE server (5dive
  keys, the task board, account links, saved bot tokens, the machine id, SSH keys)
  and fails the build if a key is still there. Never bake a secret or a server
  identity into the image.
- **First boot** (`firstboot.sh`, cloud-init per instance): updates the CLI to the
  newest release and redoes the per-server install steps. Best-effort; it never
  blocks the login.
- **Connect page** (`files/usr/local/lib/5dive-claim/claim.py`, DIVE-7731): the
  no-terminal way. On first boot the server gets its own https name (`5dive
  secret https`: an IP certificate, else sslip.io) and serves one page at
  `http://<ip>/` (Caddy sends it to https). The owner types the root password
  the hoster shows (checked against `/etc/shadow`, never sent anywhere), signs in
  on my.5dive.ai/self-host, taps Connect, and the server runs the self-host link
  line itself. The page closes for good once linked, after 10 wrong passwords,
  or 24 hours after boot; with no https name it never opens. A DigitalOcean
  Droplet made with an SSH key has no root password: the page says to use
  Access › Reset root password (emailed). Unit test:
  `tests/marketplace_claim_unit.sh`.
- **First login** (`files/etc/update-motd.d/99-5dive`): one line, *Link this server
  to your 5dive account: https://5dive.ai/self-host*. It goes away once the server
  is linked. The terminal way, for after the connect page has closed.

## DigitalOcean

```sh
export DIGITALOCEAN_TOKEN=<token with write scope>
packer init marketplace/digitalocean
packer build marketplace/digitalocean
```

The build runs DigitalOcean's own clean-up and image check (pinned by commit and
sha256) and fails on any FAIL. Then submit the snapshot in the Vendor Portal
(https://cloud.digitalocean.com/vendorportal) with the copy from `LISTING.md`.
Their review takes days to weeks. Later versions can be pushed with their Vendor
API (`PATCH /api/v1/vendor-portal/apps/<app_id>`).

Rules checked 2026-10-30 against `digitalocean/marketplace-partners@b708788`:
Ubuntu 24.04 supported; cloud-init installed; ufw active; no pending security
updates; no password and no SSH keys on root or any user account (uid >= 1000);
bash history and logs cleared; no DigitalOcean agent directory. Build on the $6
size so every size can use the image.

## Vultr

```sh
export VULTR_API_KEY=<the vendor account's API key>
packer init marketplace/vultr
packer build marketplace/vultr
```

Same `image/` steps as DigitalOcean, then Vultr's own `clean_system` from their
helper script (pinned by commit and sha256), which also adds the `vultr` kernel
option they require. The build server is deleted by Packer; the snapshot stays.

Then the listing, all of it by the API with the same key (docs:
https://docs.vultr.com/platform/marketplace-vendor; the console path is the
same steps): `POST /v2/marketplace/vendor` once (the vendor name), `POST
/v2/marketplace/apps` with `LISTING.md`'s Vultr section, `PATCH` the
categories, instructions, support contact, deployable plans and slug `5dive`,
`PUT .../icons` (light and dark), `POST .../images` (gallery), `POST
.../builds` from the snapshot, `POST .../builds/{id}/publish`, then `PATCH
.../visibility` `{"public": true}`, which sends it to Vultr's review. Vultr
emails when it is approved. Vultr takes no revenue share from publishers.

The key's access list must name the build machine's IPv4. If the machine also
has IPv6, Packer reaches the API over it and gets 401 "Unauthorized IP
address": pin `api.vultr.com` to its IPv4 for the build (DIVE-7717).

The boot test on the test server: `http://<ip>/` shows the connect page over
https (`5dive-claim` active), `cloud-init status` is done,
`/var/log/5dive-firstboot.log` ends in "first boot done", `5dive doctor` is
healthy, the login line shows, `ufw status` is SSH/80/443, and all of it again
after a reboot. Delete the test server after.

Rules checked 2026-11-01 against https://docs.vultr.com/vultr-marketplace and
`vultr/vultr-marketplace@95768fc`: an OS with cloud-init; the `vultr` kernel
option; updates, temp files, SSH keys, logs, history, machine id cleared, free
space zeroed and trimmed; the smallest disk possible (`marketplace-2c-2gb`);
gallery images 8:5, 800x500.

## Linode

`linode/` mirrors their repository: copy `linode/apps/linode-marketplace-5dive/`
and `linode/deployment_scripts/linode-marketplace-5dive/` into a fork of
`akamai-compute-marketplace/marketplace-apps`, branch from `develop`, and open the
pull request against `develop` with `LISTING.md`'s Linode section and the logo
files. Test first by pasting `5dive-deploy.sh` into a StackScript on our account,
with `GH_USER`/`BRANCH` pointing at the fork; the log is `/var/log/stackscript.log`.

Rules checked 2026-10-30 against `akamai-compute-marketplace/marketplace-apps@ed42d8b`:
Ubuntu 24.04 LTS; hands-off deploy driven by UDFs; a limited sudo user, SSH
hardening and a firewall (their helper roles); credentials in
`/home/<user>/.credentials`; a MOTD; README.md + DOCUMENTATION.md; a 100-125 word
description, version, support URL, two brand colours, SVG/EPS logos in white and
full colour.

## Next, by effort

- **Hetzner Cloud apps**: closed to new apps today ("we cannot accept ...
  suggestions for new apps as of now", `hetznercloud/apps` README, 2026-10-30).
  The same `image/` scripts build a snapshot a Hetzner user can keep as their
  own template meanwhile.
- **Hostinger**: its open listing path (the "Deploy on Hostinger" button) only
  takes a Docker Compose file, and 5dive is Linux users plus systemd on the
  server, not a container. Not built (DIVE-7479 has the reasoning).
