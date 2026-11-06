#!/usr/bin/env bash
# Dev tools: git setup, lazygit, Neovim, LazyVim, herdr.
# Installed from official releases (checksums verified); configs go to ADMIN_USER.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

want() { [[ " $DEV_TOOLS " == *" $1 "* ]]; }

# LazyVim needs a newer Neovim than Ubuntu/Debian ship.
want lazyvim && ! want neovim && DEV_TOOLS="$DEV_TOOLS neovim"

for t in $DEV_TOOLS; do
  case "$t" in git|lazygit|neovim|lazyvim|herdr) ;; *) warn "Unknown DEV_TOOLS entry '$t', ignored" ;; esac
done

ensure_packages ca-certificates curl jq tar gzip

case "$(uname -m)" in
  x86_64)  ARCH_NVIM=x86_64 ARCH_LG=x86_64 ARCH_TS=x64   ARCH_HERDR=x86_64 ;;
  aarch64) ARCH_NVIM=arm64  ARCH_LG=arm64  ARCH_TS=arm64 ARCH_HERDR=aarch64 ;;
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

want git     && install_git
want lazygit && install_lazygit
want neovim  && install_neovim
want lazyvim && install_lazyvim
want herdr   && install_herdr
exit 0
