# Fixes and ideas

Known problems and next steps, most important first. Each item says why it matters
and where to start. When one is done, delete it here (git history keeps the record).

## Fix first

### 1. Verify the Proxmox flow on a real Proxmox host
`proxmox/new-machine.sh` was tested against fake `pct`/`qm`/`pvesh` commands, which
check the logic but not Proxmox itself. On the first real run, watch for:
- `pct create` options (tags, `--features nesting=1`, the Debian 13 template on your
  Proxmox version; there is a fallback to Debian 12 on "unsupported debian version");
- the VM path: `import-from=` of the cloud image, cloud-init user/key/IP, the first
  boot reaching SSH within ~5 minutes;
- UFW inside an unprivileged LXC (if it can't run, the firewall module warns and
  points to the Proxmox firewall; see 4).

Fix what breaks, then make each fix permanent in the script.

### 2. `./ops` keeps running an old UI after `git pull`
`ops` only builds or downloads `bin/ops-linux-<arch>` when the file is **missing**.
After pulling new code, the old binary keeps running, without new screens (e.g.
New machine) or settings. Today's workaround: `rm bin/ops-linux-*` then `./ops`.
Fix: write the version next to the binary, and rebuild or redownload when it differs
from the checkout (`git describe`, or a hash of `tui/`).

### 3. Backups: the Proxmox side
App-level backups now exist (`ops-app backup`, nightly, including Caddy's CA). What's
still missing:
- On the Proxmox host: a nightly vzdump job for machines tagged `ops`
  (`pvesh create /cluster/backup ...`), with retention. That's the off-site/whole-machine layer.
- An off-site copy of `/srv/backups` (rclone to S3/R2/B2), encrypted (e.g. `age`).
  Backups contain `.env` secrets and keys like Kontor's `master.key` in the clear.
- `ops-app backup` stops each app for a few seconds. Apps with a database container could
  instead dump it (`pg_dump`/`mysqldump`) live. A per-app hook would allow that.
- A tested restore on a fresh VM, written down.

### 4. Firewall for LXCs, done by Proxmox
UFW may not run inside an unprivileged container. The module then only warns.
Better: let a recipe list its open ports (e.g. `PVE_FIREWALL_ALLOW="22/tcp 53 80/tcp"`),
and have `new-machine.sh` turn on the Proxmox firewall for that guest with those rules
(`pvesh` under `/nodes/<node>/lxc/<id>/firewall`). It then works the same whether or
not UFW works inside.

### 5. Lint scripts in CI
CI runs `go vet` only when the UI changes. Nothing checks the bash scripts, and
shellcheck wasn't available when this work was written. Add a workflow on every push:
`shellcheck -x` on `bootstrap.sh setup.sh lib/ modules/ checks/ proxmox/ apps/ops-app`,
`bash -n`, `go vet`, and a dry run of `new-machine.sh` against mocks of `pct`/`qm`/`pvesh`
(the ones used during development are easy to rebuild).

## Important next

### 6. Audit & fix don't know the new modules
`checks/audit.sh` has no checks for app-proxy or AdGuard. Add checks, with fixes in
`checks/fix.sh`:
- Caddy is running and its config is valid (`ops-app doctor` already does this);
- no container except Caddy publishes ports;
- the root certificate is exported;
- AdGuard answers on port 53, and its rewrites match `ADGUARD_REWRITES`.

### 7. Update and remove machines from the UI
- **Update**: machines carry a copy of ops-scripts in `/opt/ops-scripts`. Add
  "Machines → update" to push the current copy into a machine, then re-run its setup.
- **Remove**: there's no delete. When a guest is destroyed in Proxmox, its file in
  `/etc/ops-scripts/machines/` stays, and `--list` shows it as "deleted". Add "remove",
  which also drops its AdGuard name.

### 8. DNS has a single point of failure
If the AdGuard LXC is down, every device loses DNS. Options: a second AdGuard LXC
kept in sync (adguardhome-sync), handed out by DHCP as the secondary DNS server;
or the router as the secondary (but that skips ad blocking and local names).

### 9. Tailscale on LXCs, and the remaining manual steps
- Tailscale inside an unprivileged LXC needs `/dev/net/tun` passed through (a line
  in `/etc/pve/lxc/<id>.conf`). Recipes can't do that yet, so keep Tailscale on the
  apps VM for now.
- Approving subnet routes and setting split DNS (`home.internal` → AdGuard) are manual
  steps in the Tailscale admin console. They could be automated with an API key.

## Smaller fixes

- **`PROXY_TLS=cloudflare` is untested**: the xcaddy build and DNS challenge haven't
  been run. Also: this Caddy version has no `prefer_wildcard`, so each app gets its
  own certificate, and with real certificates every app name shows up in public
  Certificate Transparency logs. Fix: one `*.domain` site block that routes by host.
- **Deploys need the TUI or a shell**: there's no webhook, so a `git push` doesn't
  deploy. An `ops-app update` timer, or a webhook receiver behind Caddy, could do that.
  Keep it off by default: an update can change data, so it should be deliberate.
- **`ops-app deploy` guesses from names**: which `.env` names get the app's address
  and which get random secrets is decided by their names (see `env_kind`). Unusual names
  aren't filled. `ops-app env` lists them, and you fill them in by hand.
- **Shared proxy network**: every proxied app can reach every other proxied app on it.
  Fine for your own apps. For an app you trust less, give it its own network with Caddy.
- **Kontor's trusted proxy**: with `KONTOR_TRUST_PROXY=1`, another app on the proxy
  network could fake `X-Forwarded-For`. Kontor could trust only the proxy subnet
  (`PROXY_SUBNET`).
- **The "IP in use" check** pings the address. Devices that ignore ping pass it.
  Suggest a DHCP reservation, or an address outside the router's DHCP range (the UI says so).
- **The AdGuard password** is stored in plain text in `/root/adguard-admin.txt` (root-only).
  Consider showing it once, then deleting the file.
- **Nextcloud upgrades**: the template pins `nextcloud:32`, and Nextcloud can't skip
  major versions. Add `ops-app upgrade nextcloud`, which steps one major version at a time.
- **No Proxmox mode in `setup.sh`**: the whiptail fallback menu only does single-machine
  setup. `proxmox/new-machine.sh` works from the shell meanwhile.
