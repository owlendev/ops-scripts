# ops-scripts

Prepare fresh Ubuntu/Debian servers (mainly AWS EC2) for client work: updated, hardened, with SSH/HTTP/HTTPS open and nothing else.

This repo is only for **preparing** a server. Deploying the client's application is a separate step/repo.

```
fresh EC2 ──► setup.sh (menu)  ─┐
          └─► bootstrap.sh -c   ─┴─► updated · firewalled · SSH keys only · fail2ban · auto security updates
                                     (+ optional: modern CLI tools, Neovim/LazyVim, lazygit, herdr,
                                        nginx/HTTPS, Docker, AWS CLI)
```

There are two ways to drive it, and they use the same modules:

- **`sudo ./setup.sh`**: an interactive menu with checklists. Use it when you're on the server doing things by hand.
- **`sudo ./bootstrap.sh [-c config.env]`**: no questions asked. Use it for repeatable setups, scripts and (later) Terraform.

The menu can save your choices as a config file, so you can reuse them with `bootstrap.sh` next time.

---

## Contents

- [Layout](#layout)
- [Interactive menu](#interactive-menu)
- [Quick start](#quick-start)
  - [A. Launch + prepare a new EC2 instance in one command](#a-launch--prepare-a-new-ec2-instance-in-one-command)
  - [B. Prepare an existing server from your machine](#b-prepare-an-existing-server-from-your-machine)
  - [C. Run directly on the server](#c-run-directly-on-the-server)
- [Client configs](#client-configs)
- [Modules](#modules)
- [Tools installed](#tools-installed)
- [Tailscale](#tailscale)
- [Configuration reference](#configuration-reference)
- [Audit](#audit)
- [Destroying an instance](#destroying-an-instance)
- [Important notes (read once)](#important-notes-read-once)
- [Generating secrets and keys](#generating-secrets-and-keys)
- [Adding a module](#adding-a-module)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)

---

## Layout

```
ops-scripts/
├── setup.sh                # Interactive menu: checklists → run (run ON the server)
├── bootstrap.sh            # Non-interactive: runs the enabled modules in order (run ON the server)
├── config/
│   └── default.env         # All settings and their defaults
├── lib/
│   └── common.sh           # Shared helpers (logging, apt, config loading)
├── modules/                # One job per script, run in numeric order, safe to re-run
│   ├── 10-system-update.sh
│   ├── 20-base-tools.sh
│   ├── 22-cli-tools.sh     # ripgrep, fd, fzf, bat, eza, btop...
│   ├── 25-swap.sh
│   ├── 30-firewall.sh
│   ├── 40-ssh-hardening.sh
│   ├── 45-fail2ban.sh
│   ├── 50-auto-updates.sh
│   ├── 55-kernel-hardening.sh
│   ├── 60-dev-tools.sh     # optional: git setup, lazygit, Neovim, LazyVim, herdr
│   ├── 65-tailscale.sh     # optional: private VPN access, Tailscale SSH
│   ├── 70-docker.sh        # optional
│   ├── 75-aws-cli.sh       # optional
│   └── 80-nginx.sh         # optional (+ certbot / HTTPS)
├── checks/
│   └── audit.sh            # Read-only security/health report
├── tools/                  # Run FROM YOUR MACHINE, not on the server
│   ├── ec2-launch.sh       # Security group + instance + bootstrap
│   ├── ec2-terminate.sh    # Remove everything ec2-launch.sh created
│   └── push-and-run.sh     # Copy repo to any server over SSH and bootstrap it
└── examples/               # Starting points for client configs
    ├── web-server.env
    ├── docker-host.env
    └── minimal.env
```

**Supported:** Ubuntu 22.04 / 24.04 LTS (main target) and Debian 12. Tested on Ubuntu 24.04.

---

## Interactive menu

The easiest way to prepare a server by hand: create the instance in the AWS console, SSH in, and run:

```bash
git clone <this-repo> ops-scripts && cd ops-scripts
sudo ./setup.sh
```

```
┌──────────── ops-scripts - web1 ─────────────┐
│ What do you want to do?                     │
│                                             │
│   setup   Guided setup: choose modules,     │
│           tools, settings > run             │
│   module  Run a single module               │
│   audit   Security audit (read-only)        │
│   secret  Generate a secret or password     │
│   status  Show current choices              │
│   exit    Exit                              │
└─────────────────────────────────────────────┘
```

**Guided setup** goes through these screens:

1. **Modules checklist.** Tick what you want. The defaults are pre-ticked.
2. **CLI tools checklist** (if `cli-tools` is ticked): pick individual tools.
3. **Dev tools checklist** (if `dev-tools` is ticked): git, lazygit, Neovim, LazyVim, herdr.
4. **Settings.** Only the settings for the modules you picked are shown (timezone, hostname, SSH port, HTTPS domains, git name/email…). Values are checked before they're accepted.
5. **Review.** A summary with warnings, for example if the SSH port changes or your user has no SSH key. Then **Run now** or **Back**.
6. **Save?** You can save the choices as a config file (default `config/saved.local.env`, git-ignored).

**Keys:** arrows move · **Space** ticks a box · **Enter** confirms · **Tab** jumps to the buttons · **Esc** goes back.

Other ways to open it:

```bash
sudo ./setup.sh -c clients/acme.env      # start with this config's choices pre-ticked
sudo ./bootstrap.sh -i                   # same menu
tools/push-and-run.sh -i key.pem ubuntu@host -- --interactive   # copy repo + open the menu remotely
```

---

## Quick start

### A. Launch + prepare a new EC2 instance in one command

Requirements on your machine: [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured (`aws configure` or `AWS_PROFILE`), and an EC2 key pair with its `.pem` file.

```bash
# 1. Make a config for the client (clients/ is git-ignored)
mkdir -p clients
cp examples/web-server.env clients/acme.env
vim clients/acme.env

# 2. Launch and prepare
tools/ec2-launch.sh \
  --name acme-web \
  --key-name acme \
  --key-file ~/.ssh/acme.pem \
  --config clients/acme.env \
  --type t3.small \
  --region me-south-1 \
  --eip
```

This will:

1. Create a security group `acme-web-sg`: SSH only from **your current IP**, HTTP/HTTPS from anywhere.
2. Launch the latest official Ubuntu 24.04 AMI, with an encrypted gp3 disk and IMDSv2 required.
3. (`--eip`) Attach an Elastic IP so the IP doesn't change on stop/start. You need this for DNS.
4. Wait for SSH and for cloud-init to finish, then run `bootstrap.sh` with your config. You'll see the output live.
5. Print the SSH command and the destroy command.

Use `--no-bootstrap` to only launch. Run `tools/ec2-launch.sh --help` for all options.

### B. Prepare an existing server from your machine

Use this for any server you can reach over SSH: an EC2 instance launched from the console, a Lightsail box, a DigitalOcean droplet, and so on.

```bash
tools/push-and-run.sh -i ~/.ssh/acme.pem -c clients/acme.env ubuntu@203.0.113.10
```

It copies the repo to `/opt/ops-scripts` on the server and runs `sudo bootstrap.sh` there. Anything after `--` is passed to `bootstrap.sh`:

```bash
tools/push-and-run.sh -i key.pem ubuntu@host -- --only nginx
```

### C. Run directly on the server

```bash
git clone <this-repo> /opt/ops-scripts     # or scp it
cd /opt/ops-scripts
sudo ./bootstrap.sh -c /path/to/client.env
```

Options:

```bash
sudo ./bootstrap.sh --list                         # show modules and whether they're enabled
sudo ./bootstrap.sh -c client.env                  # run all enabled modules
sudo ./bootstrap.sh --only firewall,ssh-hardening  # run just these (ignores ENABLE_* flags)
sudo ./bootstrap.sh --skip swap                    # run enabled modules except these
sudo ./modules/80-nginx.sh                         # run one module by itself
sudo SSH_PORT=2222 ./bootstrap.sh --only ssh-hardening   # override a setting from the environment
```

Everything is logged to `/var/log/ops-bootstrap.log`.

---

## Client configs

`config/default.env` has every setting with a safe default. **Don't edit it for a client.** Copy an example and change only what that client needs:

```bash
cp examples/web-server.env clients/acme.env
```

```bash
# clients/acme.env
HOSTNAME_FQDN=web1.acme.com
TIMEZONE=Asia/Riyadh
ENABLE_NGINX=yes
CERTBOT_DOMAINS="acme.com www.acme.com"
CERTBOT_EMAIL=it@acme.com
SSH_ALLOW_FROM=203.0.113.4/32
```

Precedence: **config file > environment variables > defaults**.

`clients/` and `*.pem` are in `.gitignore`. Keep client configs and keys out of git, or in a separate private repo.

| Example | Use for |
|---|---|
| `examples/web-server.env` | A website on nginx with Let's Encrypt HTTPS |
| `examples/docker-host.env` | Apps in Docker containers, nginx in front, AWS CLI for ECR |
| `examples/minimal.env` | Hardened base only, no web ports |

---

## Modules

They run in numeric order. All of them are **idempotent**, so re-running only changes what is missing or different.

| Module | Default | What it does |
|---|---|---|
| `system-update` | on | `apt update` + `dist-upgrade`, autoremove, timezone, NTP, optional hostname |
| `base-tools` | on | curl, wget, git, vim, htop, tmux, jq, unzip, rsync, dnsutils (`dig`), net-tools, traceroute, mtr, tcpdump, netcat, nmap, whois… |
| `cli-tools` | on | Modern CLI tools (see [Tools installed](#tools-installed)), `fd`/`bat` names, and shell helpers (`ll`, `z`, fzf Ctrl-R) |
| `swap` | on | 2G swap file when RAM < 4G (stops t3.micro/small builds being OOM-killed) |
| `firewall` | on | UFW: deny inbound, allow SSH (rate limited), 80, 443 and any extra ports |
| `ssh-hardening` | on | Key-only login, no root login, MaxAuthTries 3, idle timeout, no X11/agent forwarding, optional port/AllowUsers. **Refuses to run if the admin user has no SSH key** |
| `fail2ban` | on | Bans IPs after 5 failed SSH logins in 10 min, for 1 hour |
| `auto-updates` | on | unattended-upgrades for daily security updates (auto reboot off by default) |
| `kernel-hardening` | on | sysctl: SYN cookies, no ICMP redirects/source routing, log martians, restrict dmesg/kernel pointers |
| `dev-tools` | off | git setup, lazygit, latest Neovim, LazyVim, herdr, all for `ADMIN_USER` (see [Tools installed](#tools-installed)) |
| `tailscale` | off | Tailscale from its official repo, UFW rules for the tailnet, optional auto-login, Tailscale SSH, and closing public SSH (see [Tailscale](#tailscale)) |
| `docker` | off | Docker Engine + compose/buildx plugins from Docker's repo, log rotation, admin user in `docker` group |
| `aws-cli` | off | AWS CLI v2 |
| `nginx` | off | nginx with version hidden, `snippets/security-headers.conf`, certbot. Requests a certificate if `CERTBOT_DOMAINS` is set |

---

## Tools installed

### `cli-tools` (apt, on by default)

The list is in `CLI_TOOLS`, or tick them in the menu. A tool your OS version doesn't package is skipped with a warning instead of failing. Ubuntu 22.04 lacks `eza`, `tealdeer` and `git-delta`, and Debian 12 lacks `eza` and `git-delta`.

| Tool | Command | What for |
|---|---|---|
| ripgrep | `rg` | Very fast grep: `rg "error" /var/log` |
| fd-find | `fd` | Simple fast find: `fd nginx /etc` |
| fzf | `fzf` | Fuzzy finder: **Ctrl-R** history, **Ctrl-T** files, **Alt-C** cd |
| bat | `bat` | `cat` with syntax highlighting |
| eza | `ll`, `lt` | Modern `ls` with git status, plus a tree view |
| zoxide | `z` | `z nginx` jumps to `/etc/nginx` once you've visited it |
| btop | `btop` | CPU / memory / disk / network monitor |
| ncdu | `ncdu /` | What's filling the disk |
| duf | `duf` | Disk usage overview |
| tealdeer | `tldr tar` | Short practical examples (run `tldr --update` once) |
| git-delta | (automatic) | Readable `git diff`. Set as git's pager by `dev-tools` |
| httpie | `http` | Friendly curl for APIs: `http GET api.example.com/health` |
| iftop / nethogs | `iftop`, `nethogs` | Bandwidth per connection / per process |
| iotop-c | `iotop-c` | Disk I/O per process |
| sysstat | `sar`, `iostat` | Performance history |
| strace | `strace` | Trace what a process is doing |
| lnav | `lnav /var/log/nginx/` | Log viewer with search and filters |
| plocate | `locate` | Instant file-name search |

The shell helpers (`CLI_SHELL_INTEGRATION=yes`) live in `/etc/ops-shell.sh` and are loaded from the end of `~/.bashrc` (for `ADMIN_USER`, root and new users). They take effect in **new** shells.

### `dev-tools` (off by default)

Pick items in `DEV_TOOLS`, or tick them in the menu. Binaries come from the projects' **official GitHub releases**, and each download is checked against the SHA-256 checksum published with the release. Re-running only updates a tool when there's a newer release.

| Item | What you get |
|---|---|
| `git` | git + git-lfs. For `ADMIN_USER`: `init.defaultBranch main`, `push.autoSetupRemote`, `fetch.prune`, delta as pager, and your `GIT_USER_NAME` / `GIT_USER_EMAIL` |
| `lazygit` | [lazygit](https://github.com/jesseduffield/lazygit), a terminal UI for git, in `/usr/local/bin` |
| `neovim` | Latest [Neovim](https://github.com/neovim/neovim) in `/opt/nvim` (apt's version is too old for LazyVim) |
| `lazyvim` | [LazyVim](https://www.lazyvim.org) starter config in `~/.config/nvim` for `ADMIN_USER`, plugins pre-installed. Also adds Neovim, tree-sitter CLI, a C compiler, ripgrep, fd and fzf. **An existing `~/.config/nvim` is never overwritten.** Use a [Nerd Font](https://www.nerdfonts.com) in *your* terminal app to see icons |
| `herdr` | [herdr](https://github.com/herdrdev/herdr), a terminal multiplexer for coding agents. Sessions keep running after you disconnect, and you reattach over SSH. Start it with `herdr` |

If the GitHub API rate-limits you (60 requests per hour per IP), set `GITHUB_TOKEN`: `sudo GITHUB_TOKEN=ghp_… ./bootstrap.sh --only dev-tools`.

---

## Tailscale

[Tailscale](https://tailscale.com) puts your laptop, phone and servers on a private network (a "tailnet"). Every device gets a stable private IP (`100.x.y.z`) and a name like `acme-web`. That lets you:

- SSH into servers **without exposing port 22 to the internet**
- reach private things (databases, admin panels, Grafana) without opening ports
- keep working when your own IP changes, with no security group edits

The free Personal plan is enough to start.

### 1. One-time: your own devices

1. Sign up at [login.tailscale.com](https://login.tailscale.com).
2. Install Tailscale on your laptop (and phone) and log in: [tailscale.com/download](https://tailscale.com/download).

### 2. Add a server

**Option A: log in by hand.** No key needed, which suits a one-off server.

Tick `tailscale` in the menu (or set `ENABLE_TAILSCALE=yes`) and run the setup. Then on the server:

```bash
sudo tailscale up --ssh --hostname=acme-web
# It prints a login URL. Open it on your laptop and approve the server.
```

**Option B: join automatically with an auth key.** No browser step.

1. In the admin console: **Settings → Keys → Generate auth key**. For servers, tick **Pre-approved**, and tick **Reusable** if you'll use it for several servers. Optionally add a tag.
2. Pass the key **at run time** so it never lands in a file:

   ```bash
   sudo TAILSCALE_AUTHKEY=tskey-auth-xxxx ./bootstrap.sh -c clients/acme.env
   ```

   Or paste it into the menu: **Settings → TAILSCALE_AUTHKEY**. It's hidden while you type and is never written to saved config files.

**After adding a server**, in the admin console open **Machines → … → Disable key expiry** for it. Otherwise it drops off the tailnet after 180 days and needs a new login.

### 3. Use it

From your laptop (Tailscale running):

```bash
ssh ubuntu@acme-web            # by name (MagicDNS), or
ssh ubuntu@100.101.102.103     # by Tailscale IP
```

On the server:

```bash
tailscale status     # devices in your tailnet and whether they're online
tailscale ip -4      # this server's Tailscale IP
tailscale ping laptop
tailscale netcheck   # connectivity details (direct vs relayed)
```

The audit also reports whether Tailscale is connected.

### Tailscale SSH (optional)

With `TAILSCALE_SSH=yes` (or `tailscale up --ssh`), Tailscale handles SSH that arrives over the tailnet. It checks **your Tailscale identity** instead of an SSH key, and the tailnet's access policy decides who may log in as which user. Normal sshd with keys keeps working alongside it.

Your tailnet's default policy may ask you to re-authenticate in the browser now and then ("check mode"). You can change that in the admin console under **Access controls**.

### Close public SSH (optional, recommended once it works)

When you can reliably SSH over Tailscale, you can stop exposing SSH to the internet entirely:

1. **Test first:** `ssh ubuntu@acme-web` from your laptop over Tailscale.
2. Set `TAILSCALE_SSH_ONLY=yes` and run `sudo ./bootstrap.sh -c clients/acme.env --only firewall`. This removes the public SSH rules from UFW. Your current session stays connected.
3. In the **EC2 security group**, delete the SSH (22) inbound rule. Port 22 is now closed to the internet; HTTP/HTTPS stay public.

Safety: the firewall only closes public SSH **while Tailscale is connected**. If Tailscale is logged out or stopped when the firewall module runs, public SSH stays open and you get a warning. If you ever get locked out anyway, use the AWS console: **EC2 Instance Connect** (only if the security group still allows it) or the **EC2 Serial Console**.

### Notes

- **No security group change needed** to *use* Tailscale. It connects outbound. Optionally allow inbound **UDP 41641** in the security group so devices connect directly instead of through a relay, which is faster. UFW already allows it.
- **Private services:** bind a database or admin panel to the Tailscale IP or `127.0.0.1`, never `0.0.0.0`. Then it's reachable only over the tailnet, e.g. `psql -h acme-web`.
- **Per-client separation:** one tailnet with tags (`tag:acme`) and access rules is usually enough. A separate tailnet per client is cleaner if the client will own it later.
- **Remove a server:** `sudo tailscale logout`, then delete it under **Machines** in the admin console.

---

## Configuration reference

All variables are in `config/default.env`. The main ones:

| Variable | Default | Notes |
|---|---|---|
| `ENABLE_<MODULE>` | see above | `yes` / `no` per module |
| `ADMIN_USER` | `ubuntu` | Your login user (`admin` on Debian AMIs) |
| `TIMEZONE` | `UTC` | e.g. `Asia/Riyadh` |
| `HOSTNAME_FQDN` | empty | e.g. `web1.acme.com` |
| `EXTRA_PACKAGES` | empty | Space-separated extra apt packages |
| `CLI_TOOLS` | 19 tools | apt package names for `cli-tools` |
| `CLI_SHELL_INTEGRATION` | `yes` | `ll`/`lt` aliases, `z`, fzf key bindings |
| `DEV_TOOLS` | `git lazygit neovim lazyvim herdr` | Items for `dev-tools` |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | empty | git identity for `ADMIN_USER` |
| `TAILSCALE_AUTHKEY` | empty | `tskey-auth-…` to join automatically. **Secret**: pass it at run time, don't commit it |
| `TAILSCALE_HOSTNAME` | empty | Name in your tailnet (default: system hostname) |
| `TAILSCALE_SSH` | `no` | Enable Tailscale SSH |
| `TAILSCALE_TAGS` | empty | e.g. `tag:server` (must exist in your tailnet policy) |
| `TAILSCALE_SSH_ONLY` | `no` | Close public SSH once Tailscale is connected |
| `SWAP_SIZE` | `auto` | `auto`, `0`, `1G`, `4G`… |
| `FIREWALL_ALLOW_HTTP` / `_HTTPS` | `yes` | |
| `FIREWALL_EXTRA_PORTS` | empty | e.g. `"8080/tcp 51820/udp"` |
| `SSH_PORT` | `22` | See [changing the SSH port](#changing-the-ssh-port) |
| `SSH_ALLOW_FROM` | empty | Limit SSH in UFW to a CIDR |
| `SSH_ALLOW_USERS` | empty | sshd `AllowUsers` |
| `SSH_ALLOW_TCP_FORWARDING` | `yes` | Needed for `ssh -L` tunnels to databases |
| `AUTO_UPDATES_REBOOT` | `no` | Let unattended-upgrades reboot at `AUTO_UPDATES_REBOOT_TIME` |
| `REBOOT_IF_REQUIRED` | `no` | Reboot at the end of bootstrap if a kernel update needs it |
| `CERTBOT_DOMAINS` / `CERTBOT_EMAIL` | empty | Request a Let's Encrypt cert (DNS must already point to the server) |

---

## Audit

`checks/audit.sh` is read-only. It reports PASS / WARN / FAIL for:

- pending (security) updates, reboot required, unattended upgrades, clock sync, disk usage
- effective sshd settings (root login, password login, X11)
- extra UID-0 accounts and accounts with empty passwords
- UFW status and rules, fail2ban status and current bans
- every port listening on a non-localhost address, with the process name
- Docker containers publishing ports on `0.0.0.0` (these bypass UFW)
- nginx version hiding
- whether IMDSv2 is enforced (on EC2)

It runs automatically at the end of `bootstrap.sh`. Run it any time:

```bash
sudo /opt/ops-scripts/checks/audit.sh
```

It exits with code `1` if anything FAILs, so you can use it in scripts and CI.

---

## Destroying an instance

```bash
tools/ec2-terminate.sh --name acme-web
```

This lists everything tagged `Name=acme-web` and `ManagedBy=ops-scripts` (the instance and its disk, the Elastic IP, and the `acme-web-sg` security group). It asks you to type the name to confirm, then deletes them. Add `--yes` to skip the prompt. It never touches resources it didn't create.

---

## Important notes (read once)

### The EC2 security group is the real firewall

AWS drops traffic at the **security group** before it reaches the server. UFW is a second layer. If a port isn't open in the security group, opening it in UFW does nothing. `ec2-launch.sh` sets up the security group to match the defaults. If you change ports, change both.

### Docker bypasses UFW

`docker run -p 8080:80` (or `ports:` in compose) adds iptables rules that skip UFW, so the port is public even if UFW says deny. Do this instead:

- publish on localhost only: `127.0.0.1:8080:80`, and put nginx in front, **or**
- rely on the security group to block the port.

The audit warns about containers published on `0.0.0.0`.

### Don't lock yourself out

- `ssh-hardening` stops if `ADMIN_USER` has no key in `~/.ssh/authorized_keys`.
- Restarting sshd doesn't drop your current session. **Always test a new SSH session before closing the old one** after SSH changes.
- If you're locked out of an EC2 instance, use **EC2 Serial Console** or **SSM Session Manager**, or detach the volume and fix it from another instance.

### Changing the SSH port

Port changes are supported, but they give little real security when you already use keys only and restrict the security group to your IP. If you set `SSH_PORT=2222`:

1. The firewall module allows both the old and new port, so you can't get cut off.
2. sshd moves to 2222. This works with Ubuntu 24.04 socket activation.
3. Open 2222 in the security group (`ec2-launch.sh` does this for you), connect with `ssh -p 2222 …`, then remove the old port 22 rules from UFW (`sudo ufw delete limit 22/tcp`) and from the security group.

### HTTPS

Certificates need DNS pointing at the server first. Typical flow:

1. Bootstrap with `ENABLE_NGINX=yes` and `CERTBOT_DOMAINS` empty.
2. Point the client's DNS A records at the Elastic IP.
3. Set `CERTBOT_DOMAINS` / `CERTBOT_EMAIL` and run `sudo ./bootstrap.sh -c client.env --only nginx`, or simply `sudo certbot --nginx -d acme.com -d www.acme.com`.

Renewal is automatic (`certbot.timer`).

In your site's `server {}` block, add `include snippets/security-headers.conf;`.

---

## Generating secrets and keys

Use `openssl` for app secrets and passwords. It's installed on Ubuntu, Debian and macOS by default. **Generate a new value per client and per environment. Never reuse one.**

### Quick reference

| Need | Command | Output |
|---|---|---|
| App secret / JWT secret / API key | `openssl rand -hex 32` | 64 chars, `0-9a-f` |
| Database password | `openssl rand -hex 24` | 48 chars, safe everywhere |
| Shorter secret (base64) | `openssl rand -base64 32` | 44 chars, contains `+ / =` |
| URL-safe secret | `openssl rand -base64 32 \| tr '+/' '-_' \| tr -d '='` | 43 chars, `A-Z a-z 0-9 - _` |
| Human-typeable password | `openssl rand -base64 18 \| tr -d '+/='` | ~24 letters/digits |
| SSH / EC2 key pair | `ssh-keygen -t ed25519 -f ~/.ssh/acme-ec2 -C acme-ec2` | see [EC2 key pairs](#ec2-key-pairs) |

`32` is the number of random **bytes**. 32 bytes (256 bits) is plenty for any secret, and 24 bytes is plenty for a password.

### Which format?

- **Database passwords → hex.** Characters like `+ / = @ :` break connection strings such as `postgres://user:PASS@host/db` and some `.env` parsers. Hex has none of them.
- **Secrets that go in URLs or headers → URL-safe base64 or hex.**
- **Anything else → either.** Hex is the safe default if you're not sure.

### Framework-specific

Some frameworks have their own generator in a specific format. Use theirs:

```bash
php artisan key:generate                       # Laravel APP_KEY
python3 -c "import secrets; print(secrets.token_urlsafe(50))"   # Django SECRET_KEY, Flask
bin/rails secret                               # Rails SECRET_KEY_BASE
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"  # Node
```

### Write straight into a `.env` file

This keeps the value off your screen. Commands typed in full go into shell history, but these generate the value inside the command, so only the command is saved, not the secret:

```bash
echo "APP_SECRET=$(openssl rand -hex 32)"  >> .env
echo "DB_PASSWORD=$(openssl rand -hex 24)" >> .env
chmod 600 .env
```

### EC2 key pairs

You have two options. **Option B is better**, because the private key is created on your machine and never passes through AWS.

**Option A: create it in the AWS console**

EC2 → Key Pairs → Create key pair → type **ED25519**, format **.pem** → it downloads once. AWS does not keep a copy, so if you lose the file you can't download it again.

```bash
mv ~/Downloads/acme-ec2.pem ~/.ssh/
chmod 400 ~/.ssh/acme-ec2.pem        # ssh refuses keys that other users can read
```

**Option B: generate locally and import the public key (recommended)**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/acme-ec2 -C "acme-ec2"
# creates ~/.ssh/acme-ec2 (private, keep it) and ~/.ssh/acme-ec2.pub (public, safe to share)
```

Then import the `.pub` file:

- **Console:** EC2 → Key Pairs → Actions → **Import key pair** → paste the contents of `~/.ssh/acme-ec2.pub`
- **or CLI:** `aws ec2 import-key-pair --key-name acme-ec2 --public-key-material fileb://~/.ssh/acme-ec2.pub`

When you launch an instance, choose that key pair. Connect with:

```bash
ssh -i ~/.ssh/acme-ec2 ubuntu@<ip>
```

**Tips**

- **One key per client.** If one key leaks, only that client is exposed, and you can drop a client cleanly when the work ends.
- **Use a passphrase** when `ssh-keygen` asks. Add the key once with `ssh-add ~/.ssh/acme-ec2` so you don't have to type the passphrase on every connection.
- Key pairs are **per region**. Import the same `.pub` file into each region you use.
- **Save typing** with `~/.ssh/config`:

  ```
  Host acme-web
      HostName 203.0.113.10
      User ubuntu
      IdentityFile ~/.ssh/acme-ec2
      # Port 2222    # if you changed SSH_PORT
  ```

  Then just `ssh acme-web`.

- **Add another person's (or another of your) keys to a running server.** The EC2 key pair is only installed at launch, so append the extra key yourself:

  ```bash
  echo "ssh-ed25519 AAAA... colleague@laptop" >> ~/.ssh/authorized_keys
  ```

  Remove that line to revoke their access.
- **Lost the key?** In the AWS console, select the instance → **Connect** → **EC2 Instance Connect**. It pushes a temporary key, so it works even with password login disabled, but the security group must allow SSH from AWS's Instance Connect IP range. Once you're in, add a new public key to `~/.ssh/authorized_keys`.
- **Back up private keys** in your password manager (1Password and Bitwarden both store SSH keys).

### nginx basic auth (password-protect a staging site)

```bash
sudo apt install apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd clientname   # prompts for the password
```

### Where to keep them

- **Never in git.** Not in this repo and not in the app repo. Commit a `.env.example` with empty values instead.
- **On the server:** in the app's `.env` with `chmod 600`, owned by the user that runs the app.
- **Your copy:** a password manager (1Password, Bitwarden), with one vault or folder per client.
- **Later, on AWS:** SSM Parameter Store (SecureString, free tier) or Secrets Manager. The app reads them using the instance's IAM role, so no secret files live on the server.

If a secret leaks (committed to git, pasted in chat, sent by email), **rotate it**. Deleting the commit isn't enough.

---

## Adding a module

1. Create `modules/NN-my-thing.sh`. The number sets the order.
2. Start it like the other modules:

   ```bash
   #!/usr/bin/env bash
   # Short summary, max ~60 chars (shown in the setup.sh checklist).
   # More detail on the following lines if needed.
   set -euo pipefail
   # shellcheck source=../lib/common.sh
   . "$(dirname "$0")/../lib/common.sh"
   require_root; require_supported_os; load_config

   pkg_installed thing || { apt_get update; apt_install thing; }
   ok "thing installed"
   ```

3. Add `: "${ENABLE_MY_THING:=no}"` (and any settings) to `config/default.env`. The variable name is `ENABLE_` plus the file name without the number, in upper case with `-` → `_`.
4. Make it **idempotent**: check before changing, and use `write_if_changed` for config files.
5. `chmod +x` it and run `shellcheck -x modules/NN-my-thing.sh`.

Helpers in `lib/common.sh`: `info` `ok` `warn` `die` `section`, `is_true`, `apt_get` / `apt_install` (wait for the dpkg lock, never prompt), `pkg_installed`, `user_exists`, `user_home`, `current_ssh_ports`, `write_if_changed`.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `Could not get lock /var/lib/dpkg/lock` | Shouldn't happen (apt waits up to 10 min). On first boot, unattended-upgrades may be running; wait and re-run |
| Module failed halfway | Fix the cause and re-run `bootstrap.sh`. Finished modules are skipped quickly |
| certbot failed | DNS not pointing to the server yet, or port 80 closed in the security group |
| Can't reach the site on port 80/443 | Check the security group first, then `sudo ufw status`, then `sudo ss -tlnp` |
| `ec2-launch.sh`: SSH never comes up | Your IP changed since the security group was created. Update the SSH rule or pass `--ssh-cidr` |
| Full log | `/var/log/ops-bootstrap.log` |

---

## Roadmap

Ideas for when this outgrows bash:

- **Terraform** for launching and destroying (instance, security group, EIP, DNS records, IAM role). Keep this repo for server preparation: Terraform can run `push-and-run.sh` from a `local-exec`, or clone the repo in `user_data`.
- **SSM Session Manager** instead of public SSH. Attach the `AmazonSSMManagedInstanceCore` role, close port 22 completely, and connect with `aws ssm start-session`.
- **Golden AMI with Packer**: run `bootstrap.sh` once into an AMI, so new client servers boot already hardened in seconds.
- **Ansible**, once you manage many long-lived client servers and need to push config changes to all of them and detect drift.
- **Monitoring module**: node_exporter or the CloudWatch agent, plus log shipping.
- **Backups module**: EBS snapshot lifecycle policy (Data Lifecycle Manager) per client.
