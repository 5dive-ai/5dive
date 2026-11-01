#!/usr/bin/env bash
# DIVE-6801: the 5dive marketplace image (marketplace/). What can be graded off a
# real cloud: the clean-up strips every per-server key and fails the build on one
# it missed, the login line says how to link and goes silent once linked, the
# first boot never stops on a failed step, and the DigitalOcean, Vultr and Linode
# wrappers point at the files that exist.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }

img=marketplace/image
lin=marketplace/linode
app=$lin/apps/linode-marketplace-5dive
motd=$img/files/etc/update-motd.d/99-5dive

# 0. Every script parses.
for f in $img/build.sh $img/cleanup.sh $img/firstboot.sh $motd \
         $lin/deployment_scripts/linode-marketplace-5dive/5dive-deploy.sh; do
  if bash -n "$f"; then ok "parses: $f"; else bad "does not parse: $f"; fi
done

# 1. Clean-up on a built server's tree: per-server state goes, the install stays.
root="$tmp/root"
mkdir -p "$root"/{etc/5dive/connectors,var/lib/5dive/tasks,var/lib/5dive/secret-drop,var/lib/5dive/wiki} \
         "$root"/{etc/ssh,var/lib/dbus,root/.ssh,home/claude/.ssh,var/lib/caddy/.local/share/caddy}
for f in var/lib/5dive/gate-proof.key etc/5dive/vault.key etc/5dive/connectord.env \
         etc/5dive/provisioning.env var/lib/5dive/tasks/tasks.db var/lib/5dive/secret-drop/abc \
         etc/5dive/connectors/telegram.env etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub \
         var/lib/dbus/machine-id root/.ssh/authorized_keys root/.bash_history \
         home/claude/.ssh/id_ed25519 home/claude/.bash_history var/lib/caddy/.local/share/caddy/cert; do
  echo secret > "$root/$f"
done
echo 0123456789abcdef > "$root/etc/machine-id"
echo '{"agents":{}}' > "$root/var/lib/5dive/agents.json"
echo '# Team wiki' > "$root/var/lib/5dive/wiki/index.md"
echo 'Host *' > "$root/etc/ssh/ssh_config"

if out=$(IMAGE_ROOT="$root" bash $img/cleanup.sh 2>&1); then ok "clean-up exits 0 on a built tree"; else bad "clean-up failed: $out"; fi
for f in var/lib/5dive/gate-proof.key etc/5dive/vault.key etc/5dive/connectord.env \
         etc/5dive/provisioning.env var/lib/5dive/tasks var/lib/5dive/secret-drop \
         etc/5dive/connectors/telegram.env etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub \
         var/lib/dbus/machine-id root/.ssh/authorized_keys root/.bash_history \
         home/claude/.ssh/id_ed25519 home/claude/.bash_history var/lib/caddy/.local/share/caddy; do
  [[ ! -e "$root/$f" ]] && ok "removed: /$f" || bad "left in the image: /$f"
done
[[ -f "$root/etc/machine-id" && ! -s "$root/etc/machine-id" ]] && ok "machine id emptied, file kept" \
  || bad "machine id not emptied (or file gone: systemd needs it present and empty)"
for f in var/lib/5dive/agents.json var/lib/5dive/wiki/index.md etc/ssh/ssh_config etc/5dive/connectors; do
  [[ -e "$root/$f" ]] && ok "kept: /$f" || bad "clean-up removed install state: /$f"
done

# 2. A key the explicit list does not know about fails the build.
echo secret > "$root/var/lib/5dive/new-feature.key"
if IMAGE_ROOT="$root" bash $img/cleanup.sh >/dev/null 2>&1; then
  bad "clean-up passed with a stray key in the image"
else
  ok "clean-up fails the build on a stray key"
fi
rm -f "$root/var/lib/5dive/new-feature.key"

# 3. The login line: one line with the link while unlinked, silent once linked,
#    silent with no CLI.
cli="$tmp/5dive"
printf '#!/bin/sh\n[ "$1" = _app_hint ] && cat "%s/hint" 2>/dev/null\nexit 0\n' "$tmp" > "$cli"
chmod +x "$cli"
printf '\nOptional: chat with your agents from your phone, free:\n  https://5dive.ai/self-host\n\n' > "$tmp/hint"
out=$(FIVEDIVE_CLI="$cli" sh $motd)
[[ "$out" == "Link this server to your 5dive account: https://5dive.ai/self-host" ]] \
  && ok "unlinked server: the one link line" || bad "unlinked server printed: [$out]"
: > "$tmp/hint"
out=$(FIVEDIVE_CLI="$cli" sh $motd)
[[ -z "$out" ]] && ok "linked server: silent" || bad "linked server still printed: [$out]"
if out=$(FIVEDIVE_CLI="$tmp/missing" sh $motd) && [[ -z "$out" ]]; then
  ok "no CLI: silent, exit 0"
else
  bad "no CLI: printed or failed"
fi
cmp -s $motd $app/roles/fivedive/files/99-5dive && ok "Linode ships the same login line" \
  || bad "Linode's 99-5dive differs from the image's"

# 4. First boot: a failed update does not stop the per-server steps.
fb="$tmp/fb-5dive"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n[ "$1" = self-update ] && exit 1\nexit 0\n' "$tmp" > "$fb"
chmod +x "$fb"
if FIVEDIVE_CLI="$fb" FIVEDIVE_FIRSTBOOT_LOG="$tmp/fb.log" bash $img/firstboot.sh; then
  ok "first boot exits 0 when the update fails"
else
  bad "first boot failed"
fi
calls=$(cat "$tmp/calls" 2>/dev/null || true)
[[ "$calls" == $'self-update\ngate-proof enforce on\nsecret _prewarm' ]] \
  && ok "first boot: update, then gate-proof, then secret route" || bad "first boot calls: [$calls]"
grep -q 'self-update failed' "$tmp/fb.log" && grep -q 'first boot done' "$tmp/fb.log" \
  && ok "first boot logs the failure and finishes" || bad "first boot log: $(cat "$tmp/fb.log")"

# 5. Build wiring: the firewall, and both files land where Ubuntu and cloud-init read them.
for rule in 'ufw allow OpenSSH' 'ufw allow 80/tcp' 'ufw allow 443/tcp' 'ufw --force enable'; do
  grep -qxF "$rule" $img/build.sh && ok "build: $rule" || bad "build is missing: $rule"
done
grep -q '/etc/update-motd.d/99-5dive$' $img/build.sh && ok "build installs the login line" || bad "build does not install 99-5dive"
grep -q '/var/lib/cloud/scripts/per-instance/001_5dive$' $img/build.sh && ok "build installs first boot per instance" \
  || bad "build does not install firstboot.sh as a per-instance script"

# 6. The DigitalOcean template runs our two steps, then DigitalOcean's pinned check.
pkr=marketplace/digitalocean/5dive.pkr.hcl
for needle in 'image         = "ubuntu-24-04-x64"' 'bash /tmp/5dive-image/build.sh' 'bash /tmp/5dive-image/cleanup.sh' \
              'bash 90-cleanup.sh' 'bash 99-img-check.sh' 'sha256sum -c -' 'sensitive = true'; do
  grep -qF "$needle" $pkr && ok "packer: $needle" || bad "packer is missing: $needle"
done
[[ "$(grep -n 'build.sh' $pkr | head -1 | cut -d: -f1)" -lt "$(grep -n 'bash 99-img-check.sh' $pkr | cut -d: -f1)" ]] \
  && ok "packer: the image check runs after our build" || bad "packer: image check is not last"
# DigitalOcean's base image ships droplet-agent; their check FAILs on /opt/digitalocean (DIVE-7368).
[[ -n "$(grep -n 'purge droplet-agent' $pkr | head -1)" ]] \
  && [[ "$(grep -n 'purge droplet-agent' $pkr | head -1 | cut -d: -f1)" -lt "$(grep -n 'bash 99-img-check.sh' $pkr | cut -d: -f1)" ]] \
  && ok "packer: droplet-agent is purged before the image check" || bad "packer: droplet-agent is not purged before the image check"

# 6b. The Vultr template (DIVE-7479): Ubuntu 24.04, our two steps, then Vultr's
#     pinned helper's clean_system last, and the key never written into the file.
vpk=marketplace/vultr/5dive.pkr.hcl
for needle in 'os_id         = "2284"' 'bash /tmp/5dive-image/build.sh' 'bash /tmp/5dive-image/cleanup.sh' \
              'install_cloud_init latest' '"clean_system",' 'sha256sum -c -' 'sensitive = true' \
              'default   = env("VULTR_API_KEY")' 'inline_shebang   = "/bin/bash -e"'; do
  grep -qF "$needle" $vpk && ok "vultr packer: $needle" || bad "vultr packer is missing: $needle"
done
grep -q 'vultr-marketplace/${local.vultr_tools_ref}/helper-scripts/vultr-helper.sh' $vpk \
  && grep -qE 'vultr_tools_ref +=  ?"[0-9a-f]{40}"' $vpk && grep -qE 'vultr_helper_sha += "[0-9a-f]{64}"' $vpk \
  && ok "vultr packer: helper pinned by commit and sha256" || bad "vultr packer: helper is not pinned"
[[ "$(grep -n 'bash /tmp/5dive-image/cleanup.sh' $vpk | cut -d: -f1)" -lt "$(grep -n '"clean_system",' $vpk | cut -d: -f1)" ]] \
  && ok "vultr packer: Vultr's clean-up runs after ours" || bad "vultr packer: clean_system is not last"
if grep -qiE 'api_key += "[^$]' $vpk; then bad "vultr packer: a literal API key"; else ok "vultr packer: no literal API key"; fi

# 7. The Linode app is whole: the deploy script names this app, every role exists.
grep -q '^export MARKETPLACE_APP="apps/linode-marketplace-5dive"$' $lin/deployment_scripts/linode-marketplace-5dive/5dive-deploy.sh \
  && ok "deploy script names the 5dive app" || bad "deploy script points at another app"
for r in common fivedive post; do
  [[ -f $app/roles/$r/tasks/main.yml ]] && ok "role exists: $r" || bad "role missing: $r"
done
grep -q 'loop: \[common, fivedive, post\]' $app/site.yml && ok "site runs common, fivedive, post" || bad "site.yml roles changed"
for f in README.md DOCUMENTATION.md provision.yml collections.yml requirements.txt ansible.cfg .ansible-lint .yamllint; do
  [[ -f $app/$f ]] && ok "app has $f" || bad "app is missing $f"
done
if python3 -c 'import yaml' 2>/dev/null; then
  ybad=0
  while IFS= read -r y; do
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$y" 2>/dev/null || { ybad=1; bad "not YAML: $y"; }
  done < <(find $app -name '*.yml')
  [[ $ybad -eq 0 ]] && ok "every playbook file is YAML"
fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
