#!/usr/bin/env bash
# Modern CLI tools: ripgrep, fd, fzf, bat, eza, btop, ncdu...
# Tools the OS doesn't package are skipped with a warning.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

# shellcheck disable=SC2206
wanted=($CLI_TOOLS)

missing=()
for p in "${wanted[@]}"; do
  pkg_installed "$p" || missing+=("$p")
done

if [[ ${#missing[@]} -eq 0 ]]; then
  ok "All ${#wanted[@]} CLI tools already installed"
else
  apt_get update
  install=(); unavailable=()
  for p in "${missing[@]}"; do
    if apt_available "$p"; then install+=("$p"); else unavailable+=("$p"); fi
  done
  if [[ ${#install[@]} -gt 0 ]]; then
    info "Installing: ${install[*]}"
    apt_install "${install[@]}"
    ok "Installed ${#install[@]} tool(s)"
  fi
  if [[ ${#unavailable[@]} -gt 0 ]]; then
    warn "Not packaged for $OS_ID $OS_VERSION, skipped: ${unavailable[*]}"
  fi
fi

link_distro_names

is_true "$CLI_SHELL_INTEGRATION" || exit 0

if write_if_changed /etc/ops-shell.sh 0644 <<'EOF'
# Managed by ops-scripts (modules/22-cli-tools.sh). Loaded from ~/.bashrc.
case $- in *i*) ;; *) return 0 ;; esac

if command -v eza >/dev/null 2>&1; then
  alias ll='eza -la --git --group-directories-first'
  alias lt='eza --tree --level=2 --git-ignore'
fi

# z <part-of-dir> jumps to directories you've visited
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi

# Ctrl-R: fuzzy history, Ctrl-T: fuzzy file picker, Alt-C: fuzzy cd
if command -v fzf >/dev/null 2>&1; then
  if fzf --bash >/dev/null 2>&1; then
    eval "$(fzf --bash)"
  else
    for f in /usr/share/doc/fzf/examples/key-bindings.bash /usr/local/share/fzf/key-bindings.bash; do
      if [ -f "$f" ]; then . "$f"; break; fi
    done
  fi
fi
EOF
then
  info "Wrote /etc/ops-shell.sh (aliases, zoxide, fzf key bindings)"
fi

# Older fzf (< 0.48) has no 'fzf --bash' and keeps its bindings in /usr/share/doc,
# which minimal images (incl. Ubuntu Minimal AMIs) strip. Fetch the matching file.
if command -v fzf >/dev/null && ! fzf --bash >/dev/null 2>&1 \
   && [[ ! -f /usr/share/doc/fzf/examples/key-bindings.bash && ! -f /usr/local/share/fzf/key-bindings.bash ]]; then
  fzf_ver="$(fzf --version | awk '{print $1}')"
  mkdir -p /usr/local/share/fzf
  if curl -fsSL "https://raw.githubusercontent.com/junegunn/fzf/$fzf_ver/shell/key-bindings.bash" \
       -o /usr/local/share/fzf/key-bindings.bash; then
    info "Downloaded fzf $fzf_ver key bindings"
  else
    rm -f /usr/local/share/fzf/key-bindings.bash
    warn "Could not download fzf key bindings; Ctrl-R/Ctrl-T won't use fzf"
  fi
fi

# Hook at the END of each ~/.bashrc so our aliases win over Ubuntu's defaults
# (e.g. ll). /etc/skel covers users created later.
hook='[ -f /etc/ops-shell.sh ] && . /etc/ops-shell.sh'
targets=(/etc/skel/.bashrc /root/.bashrc)
user_exists "$ADMIN_USER" && targets+=("$(user_home "$ADMIN_USER")/.bashrc")
for rc in "${targets[@]}"; do
  [[ -f "$rc" ]] || continue
  if ! grep -qxF "$hook" "$rc"; then
    printf '\n# ops-scripts shell helpers\n%s\n' "$hook" >> "$rc"
    info "Hooked /etc/ops-shell.sh into $rc (new shells only)"
  fi
done
ok "Shell integration enabled"
