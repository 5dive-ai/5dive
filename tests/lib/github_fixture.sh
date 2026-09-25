# shellcheck shell=bash
# DIVE-4955 — serve fixture "GitHub" repositories from local directories.
#
# `official` is decided from the GitHub owner a marketplace was REGISTERED from
# (cmd_plugin.sh _plugin_mkt_is_official), never from the plugin's manifest. So a
# harness that needs an official fixture has to register it the way a box does —
# `marketplace add 5dive-ai/<repo>` — and a local-directory marketplace is, by
# design, community whatever its manifests say.
#
# The redirect is git's own `url.<base>.insteadOf`, in a throwaway global config.
# Nothing in the product knows it is under test: it records the owner/repo it was
# given and clones https://github.com/<owner>/<repo>.git exactly as on a box.
#
#   gh_fixture_seam <root>        repos then live at <root>/<owner>/<repo>.git
#   gh_fixture_publish <dir>      commit whatever <dir> holds now, so a
#                                 `marketplace upgrade` (git fetch) sees it
gh_fixture_seam() {
  local root="$1"
  mkdir -p "$root"
  export GIT_CONFIG_GLOBAL="$root/.gitconfig" GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"
  command git config --global url."file://$root/".insteadOf "https://github.com/"
  command git config --global user.name fixture
  command git config --global user.email fixture@invalid
  command git config --global init.defaultBranch main
  command git config --global protocol.file.allow always
}

gh_fixture_publish() {
  local d="$1"
  [[ -d "$d/.git" ]] || command git -C "$d" init -q
  command git -C "$d" add -A \
    && command git -C "$d" commit -q --allow-empty -m fixture
}
