#!/usr/bin/env bash
# Dev tools: git, lazygit, lazydocker, Neovim, LazyVim, herdr.
# Installed from official releases (checksums verified); configs go to ADMIN_USER.
# Each tool is verified after install and recorded for checks/audit.sh. Exit code
# 3 means it finished but some tools failed (the summary says why and how to fix).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

want() { [[ " $DEV_TOOLS " == *" $1 "* ]]; }

# LazyVim needs a newer Neovim than Ubuntu/Debian ship.
want lazyvim && ! want neovim && DEV_TOOLS="$DEV_TOOLS neovim"

for t in $DEV_TOOLS; do
  case "$t" in git|lazygit|lazydocker|neovim|lazyvim|herdr) ;; *) warn "Unknown DEV_TOOLS entry '$t', ignored" ;; esac
done

ensure_packages ca-certificates curl jq tar gzip

case "$(uname -m)" in
  x86_64)  ARCH_NVIM=x86_64 ARCH_LG=x86_64 ARCH_LD=x86_64 ARCH_TS=x64   ARCH_HERDR=x86_64 ;;
  aarch64) ARCH_NVIM=arm64  ARCH_LG=arm64  ARCH_LD=arm64  ARCH_TS=arm64 ARCH_HERDR=aarch64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

as_admin() { (cd / && sudo -u "$ADMIN_USER" -H "$@"); }

install_git() {
  ensure_packages git git-lfs
  if user_exists "$ADMIN_USER"; then
    gc() { as_admin git config --global "$@"; }
    gc init.defaultBranch main
    gc push.autoSetupRemote true
    gc fetch.prune true
    [[ -n "$GIT_USER_NAME" ]]  && gc user.name "$GIT_USER_NAME"
    [[ -n "$GIT_USER_EMAIL" ]] && gc user.email "$GIT_USER_EMAIL"
    if command -v delta >/dev/null; then
      gc core.pager delta
      gc interactive.diffFilter "delta --color-only"
      gc delta.navigate true
    fi
    as_admin git lfs install >/dev/null
  fi
  ok "git $(git --version | awk '{print $3}') configured for $ADMIN_USER"
}

install_lazygit() {
  local json ver
  json="$(gh_latest_release jesseduffield/lazygit)"
  ver="$(jq -r .tag_name <<< "$json")"; ver="${ver#v}"
  if command -v lazygit >/dev/null && lazygit --version | grep -q "version=$ver,"; then
    ok "lazygit $ver already installed"; return
  fi
  gh_download_asset "$json" "lazygit_${ver}_linux_${ARCH_LG}.tar.gz" "$tmp/lazygit.tar.gz"
  tar -xzf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit
  install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
  ok "lazygit $ver installed"
}

install_lazydocker() {
  local json ver
  json="$(gh_latest_release jesseduffield/lazydocker)"
  ver="$(jq -r .tag_name <<< "$json")"; ver="${ver#v}"
  if command -v lazydocker >/dev/null && lazydocker --version | grep -qF "Version: $ver"; then
    ok "lazydocker $ver already installed"; return
  fi
  gh_download_asset "$json" "lazydocker_${ver}_Linux_${ARCH_LD}.tar.gz" "$tmp/lazydocker.tar.gz"
  tar -xzf "$tmp/lazydocker.tar.gz" -C "$tmp" lazydocker
  install -m 0755 "$tmp/lazydocker" /usr/local/bin/lazydocker
  ok "lazydocker $ver installed (run it as root, or as a user in the docker group)"
  command -v docker >/dev/null || warn "Docker isn't installed yet; lazydocker needs it (module: docker)"
}

install_neovim() {
  local json tag
  json="$(gh_latest_release neovim/neovim)"
  tag="$(jq -r .tag_name <<< "$json")"
  if [[ -x /opt/nvim/bin/nvim ]] && /opt/nvim/bin/nvim --version | head -1 | grep -qF "NVIM $tag"; then
    ok "Neovim $tag already installed"; return
  fi
  gh_download_asset "$json" "nvim-linux-${ARCH_NVIM}.tar.gz" "$tmp/nvim.tar.gz"
  rm -rf /opt/nvim.new && mkdir -p /opt/nvim.new
  tar -xzf "$tmp/nvim.tar.gz" -C /opt/nvim.new --strip-components=1
  rm -rf /opt/nvim && mv /opt/nvim.new /opt/nvim
  ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
  pkg_installed neovim && warn "The old apt 'neovim' is also installed; /usr/local/bin/nvim ($tag) comes first in PATH"
  ok "Neovim $tag installed"
}

install_tree_sitter() {
  local json ver
  json="$(gh_latest_release tree-sitter/tree-sitter)"
  ver="$(jq -r .tag_name <<< "$json")"; ver="${ver#v}"
  if command -v tree-sitter >/dev/null && tree-sitter --version | grep -qF "$ver"; then
    ok "tree-sitter $ver already installed"; return
  fi
  gh_download_asset "$json" "tree-sitter-linux-${ARCH_TS}.gz" "$tmp/tree-sitter.gz"
  gunzip -c "$tmp/tree-sitter.gz" > "$tmp/tree-sitter"
  install -m 0755 "$tmp/tree-sitter" /usr/local/bin/tree-sitter
  ok "tree-sitter $ver installed"
}

install_lazyvim() {
  user_exists "$ADMIN_USER" || die "ADMIN_USER '$ADMIN_USER' does not exist"
  # Compiler for treesitter parsers, plus the tools LazyVim's pickers use.
  ensure_packages build-essential git curl unzip ripgrep fd-find fzf
  link_distro_names
  install_tree_sitter

  local cfg
  cfg="$(user_home "$ADMIN_USER")/.config/nvim"
  if [[ -e "$cfg" ]]; then
    ok "$cfg already exists; left untouched"; return
  fi
  as_admin mkdir -p "$(dirname "$cfg")"
  as_admin git clone -q --depth 1 https://github.com/LazyVim/starter "$cfg"
  rm -rf "$cfg/.git"
  info "Installing LazyVim plugins for $ADMIN_USER (can take a few minutes)"
  if as_admin timeout 900 nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
    ok "LazyVim installed for $ADMIN_USER"
  else
    warn "Plugin install didn't finish; it will continue the first time $ADMIN_USER runs nvim"
  fi
  info "Use a Nerd Font in YOUR terminal app to see LazyVim's icons."
}

install_herdr() {
  local json tag
  json="$(gh_latest_release herdrdev/herdr)"
  tag="$(jq -r .tag_name <<< "$json")"
  if command -v herdr >/dev/null && herdr --version 2>/dev/null | grep -qF "${tag#v}"; then
    ok "herdr $tag already installed"; return
  fi
  gh_download_asset "$json" "herdr-linux-${ARCH_HERDR}" "$tmp/herdr"
  install -m 0755 "$tmp/herdr" /usr/local/bin/herdr
  ok "herdr $tag installed (run 'herdr' to start)"
}

# Install each tool on its own, so one failure doesn't stop the rest. Then check
# that it really runs for ADMIN_USER, and record the result for checks/audit.sh.
results=()
failed=0
for t in git lazygit lazydocker neovim lazyvim herdr; do
  want "$t" || continue
  info "--- $t"
  log="$tmp/$t.log"
  set +e
  ( set -e; "install_$t" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  if (( rc == 0 )) && ver="$(dev_tool_works "$t" "$ADMIN_USER")"; then
    results+=("ok|$t|$ver|")
    tool_record "$t" dev ok "$ADMIN_USER" "$ver" ""
  else
    (( rc == 0 )) && echo "${ver:-}" >> "$log"
    explain_failure "$log" "$t"
    results+=("failed|$t|$REASON|$HINT")
    tool_record "$t" dev failed "$ADMIN_USER" "$REASON" "$HINT"
    failed=$((failed + 1))
  fi
done

echo
info "Dev tools: each one checked by running it as $ADMIN_USER"
for r in "${results[@]}"; do
  IFS='|' read -r st t detail hint <<< "$r"
  if [[ "$st" == ok ]]; then
    ok "$(printf '%-11s %s' "$t" "$detail")"
  else
    err "$(printf '%-11s %s' "$t" "$detail")"
    echo "                   why: $hint"
    echo "                   fix: sudo $OPS_ROOT/checks/fix.sh tool $t"
  fi
done
(( failed == 0 )) || exit 3 # finished, with problems (bootstrap carries on)
