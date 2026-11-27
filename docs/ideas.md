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

### 3. Backups aren't set up by anything
Nothing creates a backup job, and the most valuable data lives in the machines:
`/srv/apps` and the Docker volumes (Kontor's data and `master.key`, Nextcloud's
files and Postgres), and Caddy's CA in `proxy_caddy-data`. If that volume is lost,
every device has to trust a new certificate.
- On the Proxmox host: create a nightly vzdump job for machines tagged `ops`
  (`pvesh create /cluster/backup ...`) from the UI, with retention.
- In the apps VM: dump databases before the backup runs (a `pg_dump` for Nextcloud),
  so a restore never depends on a crash-consistent copy of a running database.
- Document and test a restore.

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
- **Private apps can't be cloned**: `ops-app adopt` expects the app to be in
  `/srv/apps/<name>` already. Add `ops-app clone <name> <git-url> --port N`, with a
  deploy key for private repos like Kontor.
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
