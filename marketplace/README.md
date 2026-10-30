# 5dive on hosting marketplaces

Someone who rents a server finds 5dive in the hoster's app list and gets a
working 5dive server in one click (DIVE-6801).

| Where | What we submit | Folder |
|---|---|---|
| DigitalOcean Marketplace (1-Click) | a snapshot built with Packer, sent from the Vendor Portal | `digitalocean/` + `image/` |
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
- **First login** (`files/etc/update-motd.d/99-5dive`): one line, *Link this server
  to your 5dive account: https://5dive.ai/self-host*. It goes away once the server
  is linked.

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

- **Vultr Marketplace**: a vendor account, then a snapshot from the same `image/`
  scripts (cloud-init based, like DigitalOcean).
- **Hetzner Cloud apps**: closed to new apps today ("we cannot accept ...
  suggestions for new apps as of now", `hetznercloud/apps` README, 2026-10-30).
  The same `image/` scripts build a snapshot a Hetzner user can keep as their
  own template meanwhile.
