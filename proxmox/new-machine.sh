#!/usr/bin/env bash
# Create an LXC or VM on this Proxmox host from a recipe (machines/*.env), then set
# it up inside with ops-scripts. The ops UI ("New machine") runs this; it also works
# on its own:
#
#   sudo proxmox/new-machine.sh --recipe dns --name dns --ip 192.168.1.2/24 \
#        --user omar --ssh-key "ssh-ed25519 AAAA... me@laptop"
#   sudo proxmox/new-machine.sh --resume 101     # finish one that stopped halfway
#   sudo proxmox/new-machine.sh --list           # machines made by ops-scripts
#   sudo proxmox/new-machine.sh --info           # facts the UI needs (JSON)
#
# State: /etc/ops-scripts/machines/<id>.env on this host holds each machine's
# settings (no secrets); inside the machine it's /opt/ops-scripts/clients/<name>.env.
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OPS_ROOT
# shellcheck source=../lib/common.sh
. "$OPS_ROOT/lib/common.sh"

STATE="${OPS_PVE_STATE:-/etc/ops-scripts/machines}"   # override for tests only
HOSTKEY="$(dirname "$STATE")/id_ed25519"
NODE="$(hostname -s)"
export LC_ALL=C.UTF-8

ID="" RECIPE="" NAME="" IP="" GW="" DNS="" BRIDGE="vmbr0" STORAGE="" ADMIN="" SSHKEY=""
CORES="" MEMORY="" DISK="" RESUME="" MODE=create
SETS=()

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

# --- Output: steps, explanations, failures with a fix ------------------------------
STEP=""
step() { STEP="$1"; section "Step: $1"; }
why()  { printf '     %s\n' "$*"; }
CREATED=0
fail() { # what fix
  FAILED_CLEANLY=1
  printf '%s[%s] FAIL%s %s\n' "$C_RED" "$(_ts)" "$C_RESET" "$1" >&2
  printf '%s     How to fix:%s %s\n' "$C_YELLOW" "$C_RESET" "$2" >&2
  if (( CREATED )); then
    printf '     The %s (ID %s) exists but isn'"'"'t finished. After fixing, finish it with:\n' "$(kind_word)" "$ID" >&2
    printf '       in ops: New machine → Finish a machine that stopped, or: sudo %s --resume %s\n' "$0" "$ID" >&2
    printf '     Or delete it and start over: %s\n' "$([[ $KIND == lxc ]] && echo "pct stop $ID; pct destroy $ID" || echo "qm stop $ID; qm destroy $ID")" >&2
  fi
  exit 1
}
trap 'rc=$?; (( rc != 0 )) && [[ -n "$STEP" ]] && [[ "${FAILED_CLEANLY:-}" != 1 ]] && printf "%s     (failed during: %s)%s\n" "$C_YELLOW" "$STEP" "$C_RESET" >&2' EXIT

kind_word() { [[ "${KIND:-}" == vm ]] && echo VM || echo container; }

# --- Proxmox helpers -----------------------------------------------------------------
need_pve() {
  [[ "$(id -u)" -eq 0 ]] || fail "This must run as root on the Proxmox host" "Run it with sudo, in the Proxmox host's shell"
  command -v pct >/dev/null && command -v qm >/dev/null && command -v pvesh >/dev/null ||
    fail "This isn't a Proxmox VE host (pct/qm/pvesh not found)" "Run this on the Proxmox host itself (Proxmox web UI → your node → Shell, or ssh root@<proxmox>)"
  if ! command -v jq >/dev/null; then
    apt-get -qq update >/dev/null 2>&1 || true
    apt-get -y -qq install jq >/dev/null 2>&1 ||
      fail "Couldn't install jq (a small JSON tool this script needs)" "Check the Proxmox host can reach the internet, then: apt install jq"
  fi
}
pvejson() { pvesh get "$@" --output-format json 2>/dev/null; }
guest_exists() { pvejson /cluster/resources --type vm | jq -e --argjson id "$1" 'any(.[]; .vmid == $id)' >/dev/null; }
guest_status() { if [[ "$2" == lxc ]]; then pct status "$1" 2>/dev/null | awk '{print $2}'; else qm status "$1" 2>/dev/null | awk '{print $2}'; fi; }

# Each machine's settings file (on this host).
machine_files() { ls "$STATE"/*.env 2>/dev/null || true; }
mget() { # file key -> value (the file is ours, so sourcing it in a subshell is safe)
  ( set +u; set -a; . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}
has_feature() { [[ "$(mget "$1" "ENABLE_$2")" =~ ^(yes|y|true|1|on)$ ]]; }

# --- Running things inside the machine ---------------------------------------------
ssh_opts() {
  echo -i "$HOSTKEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/$ID.known_hosts" -o LogLevel=ERROR
}
# guest_sh SCRIPT: run a bash script as root inside the machine, output streamed.
guest_sh() {
  if [[ "$KIND" == lxc ]]; then
    pct exec "$ID" -- env LC_ALL=C.UTF-8 bash -c "$1"
  else
    # shellcheck disable=SC2046
    ssh $(ssh_opts) "$ADMIN@${IP%/*}" "sudo env LC_ALL=C.UTF-8 bash -c $(printf '%q' "$1")"
  fi
}
# guest_put LOCAL REMOTE: copy a file in, root-only.
guest_put() {
  if [[ "$KIND" == lxc ]]; then
    pct push "$ID" "$1" "$2" --perms 0600
  else
    # shellcheck disable=SC2046
    ssh $(ssh_opts) "$ADMIN@${IP%/*}" "sudo sh -c 'umask 077; mkdir -p \"\$(dirname $2)\"; cat > $2'" < "$1"
  fi
}

# --- Facts for the UI ------------------------------------------------------------------
cmd_info() {
  need_pve
  local nextid bridges rootdir images keys machines f
  nextid="$(pvejson /cluster/nextid | tr -d '"')"
  bridges="$(pvejson "/nodes/$NODE/network" --type any_bridge | jq -c '[.[] | {name: .iface, cidr: (.cidr // ""), gateway: (.gateway // "")}]')"
  rootdir="$(pvejson "/nodes/$NODE/storage" --content rootdir --enabled 1 | jq -c '[.[] | {name: .storage, free: (.avail // 0)}]')"
  images="$(pvejson "/nodes/$NODE/storage" --content images --enabled 1 | jq -c '[.[] | {name: .storage, free: (.avail // 0)}]')"
  keys="$( { cat /root/.ssh/authorized_keys 2>/dev/null || true; } | { grep -E '^(ssh-|ecdsa-|sk-)' || true; } |
           { grep -vE " root@$NODE\$| root@[a-z0-9-]+\$" || true; } | jq -R . | jq -sc .)"
  machines="[]"
  for f in $(machine_files); do
    machines="$(jq -c --arg id "$(mget "$f" PVE_ID)" --arg name "$(mget "$f" PVE_NAME)" --arg kind "$(mget "$f" PVE_KIND)" \
      --arg ip "$(mget "$f" PVE_IP)" --arg recipe "$(mget "$f" PVE_RECIPE)" --arg user "$(mget "$f" ADMIN_USER)" \
      --arg domain "$(mget "$f" APPS_DOMAIN)" --arg done "$(mget "$f" PVE_DONE)" \
      --argjson adguard "$(has_feature "$f" ADGUARD && echo true || echo false)" \
      --argjson proxy "$(has_feature "$f" APP_PROXY && echo true || echo false)" \
      '. + [{id: $id, name: $name, kind: $kind, ip: $ip, recipe: $recipe, user: $user, apps_domain: $domain,
             done: ($done == "yes"), adguard: $adguard, app_proxy: $proxy}]' <<< "$machines")"
  done
  jq -n --arg node "$NODE" --arg nextid "$nextid" --argjson bridges "${bridges:-[]}" \
    --argjson rootdir "${rootdir:-[]}" --argjson images "${images:-[]}" --argjson keys "${keys:-[]}" \
    --argjson machines "$machines" \
    '{node: $node, nextid: $nextid, bridges: $bridges, storage_lxc: $rootdir, storage_vm: $images, ssh_keys: $keys, machines: $machines}'
}

cmd_list() {
  need_pve
  local f any=0
  printf '%s%-6s %-12s %-4s %-8s %-16s %-10s %s%s\n' "$C_BOLD" ID NAME KIND RECIPE IP STATE "LOG IN" "$C_RESET"
  for f in $(machine_files); do
    any=1
    local id kind state ip user
    id="$(mget "$f" PVE_ID)"; kind="$(mget "$f" PVE_KIND)"; ip="$(mget "$f" PVE_IP)"; user="$(mget "$f" ADMIN_USER)"
    state="$(guest_status "$id" "$kind")"; [[ -n "$state" ]] || state="deleted"
    [[ "$(mget "$f" PVE_DONE)" == yes || "$state" == deleted ]] || state="$state, unfinished"
    printf '%-6s %-12s %-4s %-8s %-16s %-10s %s\n' "$id" "$(mget "$f" PVE_NAME)" "$kind" "$(mget "$f" PVE_RECIPE)" \
      "${ip%/*}" "$state" "ssh $user@${ip%/*}$([[ $kind == lxc ]] && echo "   or: pct enter $id")"
    if [[ "$state" == deleted ]]; then why "(gone from Proxmox; forget it with: rm $f)"; fi
    if [[ "$state" == *unfinished* ]]; then why "(stopped halfway; finish it: sudo $0 --resume $id)"; fi
  done
  (( any )) || echo "No machines made by ops-scripts yet. Make one: ops → New machine, or: sudo $0 --help"
}

# --- Arguments ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe)  RECIPE="${2:-}"; shift 2 ;;
    --name)    NAME="${2:-}"; shift 2 ;;
    --id)      ID="${2:-}"; shift 2 ;;
    --ip)      IP="${2:-}"; shift 2 ;;
    --gateway) GW="${2:-}"; shift 2 ;;
    --dns)     DNS="${2:-}"; shift 2 ;;
    --bridge)  BRIDGE="${2:-}"; shift 2 ;;
    --storage) STORAGE="${2:-}"; shift 2 ;;
    --user)    ADMIN="${2:-}"; shift 2 ;;
    --ssh-key) SSHKEY="${2:-}"; shift 2 ;;
    --cores)   CORES="${2:-}"; shift 2 ;;
    --memory)  MEMORY="${2:-}"; shift 2 ;;
    --disk)    DISK="${2:-}"; shift 2 ;;
    --set)     SETS+=("${2:-}"); shift 2 ;;
    --resume)  RESUME="${2:-}"; MODE=resume; shift 2 ;;
    --list)    MODE=list; shift ;;
    --info)    MODE=info; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown option: $1" "See the usage above" ;;
  esac
done
case "$MODE" in
  info) cmd_info; exit 0 ;;
  list) cmd_list; exit 0 ;;
esac

need_pve
mkdir -p "$STATE"; chmod 700 "$(dirname "$STATE")" "$STATE"

# Secrets a recipe asks for come in as environment variables, never on the command line.
secret_keys() { grep -E '^# ask: ' "$1" | awk -F'|' 'tolower($4) ~ /secret/ { gsub(/^# ask: *| *$/, "", $1); print $1 }'; }

# =========================================================================================
step "Check the plan"
# =========================================================================================
if [[ "$MODE" == resume ]]; then
  ID="$RESUME"
  CONF="$STATE/$ID.env"
  [[ -f "$CONF" ]] || fail "No settings saved for machine $ID ($CONF)" "Only machines made by ops-scripts can be finished. See them with: sudo $0 --list"
  RECIPE="$(mget "$CONF" PVE_RECIPE)"; NAME="$(mget "$CONF" PVE_NAME)"; KIND="$(mget "$CONF" PVE_KIND)"
  IP="$(mget "$CONF" PVE_IP)"; ADMIN="$(mget "$CONF" ADMIN_USER)"; SSHKEY="$(mget "$CONF" PVE_SSHKEY)"
  guest_exists "$ID" || fail "Machine $ID doesn't exist in Proxmox any more" "Make it again (ops → New machine), and forget the old one: rm $CONF"
  CREATED=1
  why "Finishing $NAME (ID $ID, $(kind_word), recipe $RECIPE) where it stopped."
else
  RF="$OPS_ROOT/machines/$RECIPE.env"
  [[ -n "$RECIPE" && -f "$RF" ]] || fail "Unknown recipe '$RECIPE'" "Pick one of: $(cd "$OPS_ROOT/machines" && ls *.env | sed 's/\.env$//' | tr '\n' ' ')"
  KIND="$(mget "$RF" PVE_KIND)"
  [[ "$KIND" == lxc || "$KIND" == vm ]] || fail "Recipe $RECIPE has no valid PVE_KIND" "Set PVE_KIND=lxc or PVE_KIND=vm in $RF"
  CORES="${CORES:-$(mget "$RF" PVE_CORES)}"; MEMORY="${MEMORY:-$(mget "$RF" PVE_MEMORY)}"; DISK="${DISK:-$(mget "$RF" PVE_DISK)}"
  NAME="${NAME:-$RECIPE}"
  [[ -n "$ID" ]] || ID="$(pvejson /cluster/nextid | tr -d '"')"

  [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail "Name '$NAME' isn't a valid hostname" "Use lowercase letters, digits and '-', e.g. dns or apps"
  [[ "$ID" =~ ^[0-9]+$ ]] && (( ID >= 100 )) || fail "ID '$ID' isn't valid" "Proxmox IDs are numbers from 100 up; leave it empty to take the next free one"
  guest_exists "$ID" && fail "ID $ID is already used by another VM/container" "Pick another ID, or leave it empty to take the next free one"
  pvejson /cluster/resources --type vm | jq -e --arg n "$NAME" 'any(.[]; .name == $n)' >/dev/null &&
    fail "A machine called '$NAME' already exists" "Pick another name"
  [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] ||
    fail "IP '$IP' should be an address with its network size, like 192.168.1.2/24" "Use a free address in your LAN and its prefix (usually /24). Servers need a fixed address, so DHCP isn't offered."
  if ping -c 1 -W 1 "${IP%/*}" >/dev/null 2>&1; then
    fail "Something already answers at ${IP%/*}" "Pick a free address. Tip: use one outside your router's DHCP range so it's never handed to a phone or laptop."
  fi
  bjson="$(pvejson "/nodes/$NODE/network/$BRIDGE")" || fail "No network bridge '$BRIDGE' on this host" "Use the bridge your LAN is on (Proxmox → node → System → Network), usually vmbr0"
  [[ -n "$GW" ]] || GW="$(jq -r '.gateway // empty' <<< "$bjson")"
  [[ -n "$GW" ]] || GW="$(ip route show default | awk '{print $3; exit}')"
  [[ -n "$GW" ]] || fail "Couldn't work out the gateway (your router's address)" "Pass it with --gateway, e.g. --gateway 192.168.1.1"
  [[ -n "$DNS" ]] || DNS="$GW"
  content=$([[ $KIND == lxc ]] && echo rootdir || echo images)
  if [[ -z "$STORAGE" ]]; then
    STORAGE="$(pvejson "/nodes/$NODE/storage" --content "$content" --enabled 1 | jq -r 'sort_by(-(.avail // 0)) | .[0].storage // empty')"
  fi
  pvejson "/nodes/$NODE/storage" --content "$content" --enabled 1 | jq -e --arg s "$STORAGE" 'any(.[]; .storage == $s)' >/dev/null ||
    fail "Storage '$STORAGE' can't hold $( [[ $KIND == lxc ]] && echo container || echo VM ) disks" "Pick one listed under Datacenter → Storage with content '$content' (usually local-lvm)"
  [[ "$ADMIN" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$ADMIN" != root ]] ||
    fail "Login user '$ADMIN' isn't a valid name" "Use your usual username, lowercase, e.g. omar (not root)"
  [[ "$SSHKEY" != *"'"* && "$SSHKEY" != *$'\n'* ]] || fail "The SSH key has odd characters in it" "Paste exactly one line from ~/.ssh/id_ed25519.pub"
  kf="$(mktemp)"; printf '%s\n' "$SSHKEY" > "$kf"
  ssh-keygen -l -f "$kf" >/dev/null 2>&1 ||
    { rm -f "$kf"; fail "That SSH public key isn't valid" "Paste the one line from your laptop: cat ~/.ssh/id_ed25519.pub (make one with: ssh-keygen -t ed25519)"; }
  rm -f "$kf"
  for v in CORES MEMORY DISK; do
    [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || fail "$v must be a whole number above 0 (got '${!v}')" "Fix it in the form, or in $RF"
  done

  why "$(kind_word | sed 's/^./\U&/') '$NAME', ID $ID, from recipe '$RECIPE': $CORES CPU, ${MEMORY} MB RAM, ${DISK} GB disk on $STORAGE."
  why "Address ${IP%/*} on $BRIDGE, gateway $GW, DNS $DNS. Login: $ADMIN with your SSH key."
fi
ok "Plan checked"

# =========================================================================================
if [[ "$MODE" == create ]]; then
# =========================================================================================
  # Host key: lets this Proxmox host log in to VMs it creates, to set them up now and
  # to update them later (e.g. adding an AdGuard name). Only root here can use it.
  if [[ ! -f "$HOSTKEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "ops-scripts@$NODE" -f "$HOSTKEY"
  fi

  if [[ "$KIND" == lxc ]]; then
    step "Get the Debian container template"
    why "An LXC starts from a ready-made Debian image (a 'template'). It's downloaded once and reused."
    tstore="$(pvejson "/nodes/$NODE/storage" --content vztmpl --enabled 1 | jq -r '.[0].storage // empty')"
    [[ -n "$tstore" ]] || fail "No storage can hold container templates" "Datacenter → Storage → local → Edit → Content: add 'Container template'"
    pveam update >/dev/null 2>&1 || warn "Couldn't refresh the template list (no internet?); using what's known"
    # The list holds templates for several CPU types (amd64, arm64): keep only this host's.
    arch="$(dpkg --print-architecture)"
    mapfile -t tpls < <(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-[0-9]+-standard_.*_${arch}\.tar\." | sort -V -r)
    [[ ${#tpls[@]} -gt 0 ]] || fail "No Debian templates found for this CPU ($arch)" "Check this host reaches the internet (ping -c1 download.proxmox.com), then retry"
  else
    step "Get the Debian cloud image"
    why "A VM starts from Debian's official cloud image, set up on first boot by cloud-init."
    why "It's downloaded once (about 400 MB), checked against Debian's checksums, and reused."
    arch="$(dpkg --print-architecture)"
    img_name="debian-13-genericcloud-$arch.qcow2"
    img_url="https://cloud.debian.org/images/cloud/trixie/latest"
    IMG="${OPS_PVE_CACHE:-/var/lib/vz/template/cache}/ops-$img_name"
    if [[ ! -s "$IMG" ]] || [[ -n "$(find "$IMG" -mtime +30 2>/dev/null)" ]]; then
      mkdir -p "$(dirname "$IMG")"
      tmpimg="$(mktemp -p "$(dirname "$IMG")" .ops-img.XXXX)"
      curl -fL --progress-bar -o "$tmpimg" "$img_url/$img_name" ||
        { rm -f "$tmpimg"; fail "Downloading the Debian image failed" "Check this host reaches the internet: curl -sI $img_url/ | head -1"; }
      sum="$(curl -fsSL "$img_url/SHA512SUMS" | awk -v f="$img_name" '$2 == f {print $1}')"
      [[ -n "$sum" ]] && echo "$sum  $tmpimg" | sha512sum -c --quiet - ||
        { rm -f "$tmpimg"; fail "The downloaded image failed its checksum check" "Usually a broken download: just retry"; }
      mv -f "$tmpimg" "$IMG"
      ok "Downloaded and verified $img_name"
    else
      ok "Using the cached $img_name"
    fi
  fi

  # --- Settings file for this machine ---------------------------------------------------
  CONF="$STATE/$ID.env"
  features=""
  for m in docker app-proxy adguard tailscale; do
    v="ENABLE_$(tr 'a-z-' 'A-Z_' <<< "$m")"
    [[ "$(mget "$RF" "$v")" =~ ^(yes|y|true|1|on)$ ]] && features+=";ops-$m"
  done
  {
    echo "# Machine '$NAME' (Proxmox ID $ID), made by ops-scripts from machines/$RECIPE.env on $(date -I)."
    echo "# Inside the machine this file is /opt/ops-scripts/clients/$NAME.env. To re-run its setup there:"
    echo "#   sudo /opt/ops-scripts/bootstrap.sh -c /opt/ops-scripts/clients/$NAME.env"
    echo
    cat "$RF"
    echo
    echo "# --- Chosen when the machine was created (these win over the recipe) ---"
    echo "ADMIN_USER='$ADMIN'"
    for kv in "${SETS[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"
      [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || fail "--set '$kv' isn't KEY=value" "Use e.g. --set TIMEZONE=UTC"
      printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}"
    done
    echo
    echo "# --- For ops on the Proxmox host (ignored inside the machine) ---"
    echo "PVE_ID=$ID"; echo "PVE_NAME=$NAME"; echo "PVE_RECIPE=$RECIPE"; echo "PVE_KIND=$KIND"
    echo "PVE_IP=$IP"; echo "PVE_NODE=$NODE"; echo "PVE_DONE=no"
    printf "PVE_SSHKEY='%s'\n" "$SSHKEY"   # your public key (not a secret), for --resume
  } > "$CONF"
  chmod 600 "$CONF"

  # The AdGuard machine gets the apps VM's name automatically (if one exists already).
  if has_feature "$CONF" ADGUARD && [[ -z "$(mget "$CONF" ADGUARD_REWRITES)" ]]; then
    rw=""
    for f in $(machine_files); do
      [[ "$f" == "$CONF" ]] && continue
      if has_feature "$f" APP_PROXY; then rw+=" *.$(mget "$f" APPS_DOMAIN)=$(mget "$f" PVE_IP | cut -d/ -f1)"; fi
    done
    if [[ -n "$rw" ]]; then
      printf "ADGUARD_REWRITES='%s'\n" "${rw# }" >> "$CONF"
      why "Local names from your existing apps machine(s):${rw}"
    fi
  fi

  desc="Made by ops-scripts (recipe: $RECIPE) on $(date -I).
Log in: ssh $ADMIN@${IP%/*}$([[ $KIND == lxc ]] && echo "  (or on the host: pct enter $ID)" || true)
Settings: $CONF on the Proxmox host"
  rm -f "$STATE/$ID.known_hosts"

  step "Create the $(kind_word)"
  if [[ "$KIND" == lxc ]]; then
    why "Unprivileged container (root inside isn't root on the host), nesting on (needed by Debian's systemd),"
    why "starts when Proxmox boots, Proxmox firewall hook on its network card."
    kf="$(mktemp)"; printf '%s\n' "$SSHKEY" > "$kf"
    made=0
    for tpl in "${tpls[@]}"; do
      if ! pveam list "$tstore" 2>/dev/null | grep -q "$tpl"; then
        info "Downloading template $tpl"
        pveam download "$tstore" "$tpl" >/dev/null || { warn "Couldn't download $tpl"; continue; }
      fi
      out="$(pct create "$ID" "$tstore:vztmpl/$tpl" --hostname "$NAME" --cores "$CORES" --memory "$MEMORY" --swap 512 \
        --rootfs "$STORAGE:$DISK" --net0 "name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GW,firewall=1" \
        --nameserver "$DNS" --unprivileged 1 --features nesting=1 --onboot 1 \
        --ssh-public-keys "$kf" --tags "ops$features" --description "$desc" 2>&1)" && { made=1; break; }
      if grep -qi 'unsupported debian version' <<< "$out"; then
        warn "This Proxmox version can't run $tpl yet; trying the previous Debian release"
        continue
      fi
      rm -f "$kf"
      fail "Proxmox couldn't create the container: $(tail -1 <<< "$out")" "Check the storage has ${DISK} GB free (Datacenter → Storage), then retry"
    done
    rm -f "$kf"
    (( made )) || fail "No Debian template worked on this Proxmox version" "Update Proxmox (Node → Updates), then retry"
    ok "Container $ID created from $tpl"
  else
    why "Debian cloud image, cloud-init for the login user/SSH key/address, QEMU guest agent, serial console,"
    why "starts when Proxmox boots, Proxmox firewall hook on its network card."
    keys="$(mktemp)"; { printf '%s\n' "$SSHKEY"; cat "$HOSTKEY.pub"; } > "$keys"
    run_qm() { local out; out="$("$@" 2>&1)" || { rm -f "$keys"; fail "Proxmox refused: $* → $(tail -1 <<< "$out")" "Check the settings above (storage, bridge), then retry"; }; }
    run_qm qm create "$ID" --name "$NAME" --ostype l26 --machine q35 --cores "$CORES" --memory "$MEMORY" \
      --net0 "virtio,bridge=$BRIDGE,firewall=1" --scsihw virtio-scsi-single --agent enabled=1 \
      --serial0 socket --vga serial0 --onboot 1 --tags "ops$features" --description "$desc"
    CREATED=1
    run_qm qm set "$ID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,ssd=1,iothread=1"
    run_qm qm set "$ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
    qm disk resize "$ID" scsi0 "${DISK}G" >/dev/null 2>&1 || run_qm qm resize "$ID" scsi0 "${DISK}G"
    run_qm qm set "$ID" --ciuser "$ADMIN" --sshkeys "$keys" --ipconfig0 "ip=$IP,gw=$GW" --nameserver "$DNS"
    qm set "$ID" --ciupgrade 0 >/dev/null 2>&1 || true   # ops-scripts updates it; don't do it twice
    rm -f "$keys"
    ok "VM $ID created"
  fi
  CREATED=1
fi

# =========================================================================================
step "Start it and wait for the network"
# =========================================================================================
why "Starting it, then waiting until it can reach the internet (it needs to download packages)."
if [[ "$(guest_status "$ID" "$KIND")" != running ]]; then
  if [[ "$KIND" == lxc ]]; then out="$(pct start "$ID" 2>&1)" || fail "It didn't start: $(tail -1 <<< "$out")" "See why in Proxmox → $ID → Task history, or: pct start $ID --debug"
  else out="$(qm start "$ID" 2>&1)" || fail "It didn't start: $(tail -1 <<< "$out")" "See why in Proxmox → $ID → Task history (not enough free RAM is the usual cause)"; fi
fi
if [[ "$KIND" == lxc ]]; then
  for _ in $(seq 1 60); do pct exec "$ID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
  pct exec "$ID" -- getent hosts deb.debian.org >/dev/null 2>&1 ||
    fail "The container started but can't reach the internet" "Check its address/gateway/DNS (Proxmox → $ID → Network, DNS). From inside (pct enter $ID): ping -c1 $GW; getent hosts deb.debian.org"
else
  why "First boot of a VM takes a minute or two (cloud-init sets up the user, key and address)."
  up=0
  for _ in $(seq 1 90); do
    # shellcheck disable=SC2046
    ssh $(ssh_opts) "$ADMIN@${IP%/*}" true >/dev/null 2>&1 && { up=1; break; }
    sleep 3
  done
  (( up )) || fail "The VM didn't become reachable over SSH at ${IP%/*} within ~5 minutes" "Open Proxmox → $ID → Console to see where boot stopped. Common causes: wrong gateway, or the address is used elsewhere."
  guest_sh 'cloud-init status --wait >/dev/null 2>&1 || true; getent hosts deb.debian.org >/dev/null' ||
    fail "The VM can't reach the internet" "Check its gateway and DNS (Proxmox → $ID → Cloud-Init), then: sudo $0 --resume $ID"
fi
ok "It's up at ${IP%/*} and online"

# =========================================================================================
step "Prepare it (login user, sudo, git)"
# =========================================================================================
if [[ "$KIND" == lxc ]]; then
  why "Containers start with only root. Creating '$ADMIN' with your SSH key and passwordless sudo"
  why "(like cloud servers), so you log in as yourself and root login can be turned off."
  uq="$(printf '%q' "$ADMIN")"; kq="$(printf '%q' "$SSHKEY")"
  guest_sh "set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -y -qq install sudo git curl ca-certificates openssh-server >/dev/null
    id $uq >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $uq
    install -d -m 700 -o $uq -g $uq /home/$uq/.ssh
    touch /home/$uq/.ssh/authorized_keys
    grep -qxF $kq /home/$uq/.ssh/authorized_keys || printf '%s\n' $kq >> /home/$uq/.ssh/authorized_keys
    chown $uq:$uq /home/$uq/.ssh/authorized_keys; chmod 600 /home/$uq/.ssh/authorized_keys
    echo '$ADMIN ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ops-$ADMIN
    chmod 440 /etc/sudoers.d/90-ops-$ADMIN; visudo -cqf /etc/sudoers.d/90-ops-$ADMIN
    systemctl enable --now ssh >/dev/null 2>&1 || true" ||
    fail "Preparing the container failed (see the lines above)" "Usually a package download problem: check internet inside (pct enter $ID; apt-get update), then resume"
else
  why "cloud-init already made '$ADMIN' with your key and sudo. Adding git and the QEMU guest agent"
  why "(lets Proxmox show the VM's IP and shut it down cleanly)."
  guest_sh 'set -e; export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update; apt-get -y -qq install git curl qemu-guest-agent >/dev/null
    systemctl start qemu-guest-agent 2>/dev/null || true' ||
    fail "Preparing the VM failed (see the lines above)" "Usually a package download problem: ssh $ADMIN@${IP%/*} and run: sudo apt-get update; then resume"
fi
ok "Login user '$ADMIN' ready"

# =========================================================================================
step "Copy ops-scripts into it"
# =========================================================================================
why "The same ops-scripts you're running here goes to /opt/ops-scripts inside, with this machine's"
why "settings as clients/$NAME.env. Later, inside it: sudo /opt/ops-scripts/ops"
tgz="$(mktemp --suffix .tgz)"
tar -C "$OPS_ROOT" --exclude='./clients' --exclude='*.local.env' --exclude='*.pem' --exclude='*.key' \
  --exclude='./config/saved.local.env' -czf "$tgz" . || fail "Couldn't pack ops-scripts" "Check free space on this host: df -h /tmp"
guest_put "$tgz" /root/ops-scripts.tgz || { rm -f "$tgz"; fail "Couldn't copy ops-scripts in" "Check the machine is running and has free disk space"; }
rm -f "$tgz"
guest_put "$CONF" /root/ops-machine.env || fail "Couldn't copy the machine's settings in" "Check the machine is running"
nq="$(printf '%q' "$NAME")"
guest_sh "set -e; rm -rf /opt/ops-scripts; mkdir -p /opt/ops-scripts/clients
  tar -xzf /root/ops-scripts.tgz -C /opt/ops-scripts; rm -f /root/ops-scripts.tgz
  grep -v '^PVE_' /root/ops-machine.env > /opt/ops-scripts/clients/$nq.env; rm -f /root/ops-machine.env
  chmod 600 /opt/ops-scripts/clients/$nq.env" || fail "Unpacking ops-scripts inside failed" "Check free disk space inside: df -h /"
ok "ops-scripts is in /opt/ops-scripts"

# =========================================================================================
step "Set it up inside (modules)"
# =========================================================================================
why "Running ops-scripts' bootstrap inside, with recipe '$RECIPE'. Each module below explains itself."
sec="$(mktemp)"; : > "$sec"
for k in $(secret_keys "$OPS_ROOT/machines/$RECIPE.env"); do
  [[ -n "${!k:-}" ]] && printf "%s=%q\n" "$k" "${!k}" >> "$sec"
done
guest_put "$sec" /root/.ops-secrets.env >/dev/null 2>&1 || true
rm -f "$sec"
rc=0
guest_sh "set -a; [ -f /root/.ops-secrets.env ] && . /root/.ops-secrets.env; rm -f /root/.ops-secrets.env; set +a
  cd /opt/ops-scripts && bash bootstrap.sh -c clients/$nq.env" || rc=$?
if (( rc == 3 )); then
  warn "Setup finished, but some parts reported problems (see the WARN / How to fix lines above)."
elif (( rc != 0 )); then
  fail "Setup inside the machine stopped at a module (its reason and fix are printed just above)" \
    "Fix that, then resume (it re-runs setup; finished modules are quick). Or look inside: $([[ $KIND == lxc ]] && echo "pct enter $ID" || echo "ssh $ADMIN@${IP%/*}")"
fi
sed -i 's/^PVE_DONE=.*/PVE_DONE=yes/' "$CONF"
ok "Setup finished"

# =========================================================================================
if has_feature "$CONF" APP_PROXY; then
  step "Point the app names here (AdGuard)"
  domain="$(mget "$CONF" APPS_DOMAIN)"; me="${IP%/*}"
  linked=0
  for f in $(machine_files); do
    [[ "$f" == "$CONF" ]] && continue
    has_feature "$f" ADGUARD || continue
    [[ "$(mget "$f" PVE_DONE)" == yes ]] || continue
    did="$(mget "$f" PVE_ID)"; dkind="$(mget "$f" PVE_KIND)"; dname="$(mget "$f" PVE_NAME)"
    [[ "$(guest_status "$did" "$dkind")" == running ]] || { warn "AdGuard machine $dname ($did) isn't running; skipped"; continue; }
    why "Adding *.$domain → $me to AdGuard on '$dname', so every device finds your apps by name."
    cur="$(mget "$f" ADGUARD_REWRITES)"
    new="$(tr ' ' '\n' <<< "$cur" | { grep -v -e "^\*\.$domain=" -e '^$' || true; } | tr '\n' ' ')*.$domain=$me"
    sed -i '/^ADGUARD_REWRITES=/d' "$f"; printf "ADGUARD_REWRITES='%s'\n" "$new" >> "$f"
    # Run the adguard module inside that machine with its updated settings.
    ( ID="$did"; KIND="$dkind"; IP="$(mget "$f" PVE_IP)"; ADMIN="$(mget "$f" ADMIN_USER)"
      dq="$(printf '%q' "$dname")"
      guest_put "$f" /root/ops-machine.env &&
      guest_sh "grep -v '^PVE_' /root/ops-machine.env > /opt/ops-scripts/clients/$dq.env; rm -f /root/ops-machine.env
        chmod 600 /opt/ops-scripts/clients/$dq.env
        cd /opt/ops-scripts && bash bootstrap.sh -c clients/$dq.env --only adguard" ) && linked=1 ||
      { warn "Couldn't update AdGuard on $dname"
        hint "Add it by hand: AdGuard web UI → Filters → DNS rewrites → Add: *.$domain → $me"; }
  done
  if (( linked )); then ok "*.$domain now points here"
  else
    info "No AdGuard machine yet. When you create one (recipe dns), it gets *.$domain → $me automatically."
  fi
fi

# =========================================================================================
step "Done"
# =========================================================================================
FAILED_CLEANLY=1
ok "$(kind_word | sed 's/^./\U&/') '$NAME' (ID $ID) is ready at ${IP%/*}"
why "Log in:  ssh $ADMIN@${IP%/*}$([[ $KIND == lxc ]] && echo "     (or from this host: pct enter $ID)")"
why "Change its settings later: inside it, sudo /opt/ops-scripts/ops"
grep -E '^# next: ' "$OPS_ROOT/machines/$RECIPE.env" | sed 's/^# next: //' | while IFS= read -r line; do
  line="${line//\{ip\}/${IP%/*}}"; line="${line//\{id\}/$ID}"; line="${line//\{name\}/$NAME}"; line="${line//\{user\}/$ADMIN}"
  line="${line//\{APPS_DOMAIN\}/$(mget "$CONF" APPS_DOMAIN)}"
  why "Next: $line"
done
