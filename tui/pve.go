package main

// Proxmox mode: when ops runs on a Proxmox VE host, it can create LXCs and VMs
// from recipes (machines/*.env) and set them up inside. The work is done by
// proxmox/new-machine.sh; these pages pick a recipe, explain it, ask the few
// questions it needs, and stream the script's output.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

func isProxmox() bool {
	if fileExists("/etc/pve/.version") {
		return true
	}
	_, err := exec.LookPath("pveversion")
	return err == nil
}

// --- Recipes ---------------------------------------------------------------------------

type recipeAsk struct {
	Key, Label, Help string
	Secret           bool
}

type recipe struct {
	Name, File, Summary, Kind string
	Detail                    []string
	Asks                      []recipeAsk
	Cfg                       map[string]string // default.env + the recipe, as bash sees it
}

func (r *recipe) kindLabel() string {
	if r.Kind == "vm" {
		return "VM"
	}
	return "LXC"
}

func (r *recipe) uses(module string) bool { return isYes(r.Cfg[enableVar(module)]) }

func loadRecipes(repo *Repo) ([]*recipe, error) {
	files, err := filepath.Glob(repo.path("machines", "*.env"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	var out []*recipe
	for _, f := range files {
		r := &recipe{Name: strings.TrimSuffix(filepath.Base(f), ".env"), File: f}
		fh, err := os.Open(f)
		if err != nil {
			return nil, err
		}
		sc := bufio.NewScanner(fh)
		inDetail := true
		for i := 0; sc.Scan(); i++ {
			line := sc.Text()
			if !strings.HasPrefix(line, "#") {
				inDetail = false
				continue
			}
			text := strings.TrimSpace(strings.TrimPrefix(line, "#"))
			switch {
			case i == 0:
				r.Summary = text
			case strings.HasPrefix(text, "ask:"):
				inDetail = false
				parts := strings.Split(strings.TrimSpace(strings.TrimPrefix(text, "ask:")), "|")
				for j := range parts {
					parts[j] = strings.TrimSpace(parts[j])
				}
				for len(parts) < 4 {
					parts = append(parts, "")
				}
				r.Asks = append(r.Asks, recipeAsk{Key: parts[0], Label: parts[1], Help: parts[2],
					Secret: strings.EqualFold(parts[3], "secret")})
			case text == "" || strings.HasPrefix(text, "next:"):
				inDetail = false
			case inDetail:
				r.Detail = append(r.Detail, text)
			}
		}
		fh.Close()
		saved := repo.Config
		repo.Config = f
		r.Cfg, err = repo.LoadConfig()
		repo.Config = saved
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		r.Kind = r.Cfg["PVE_KIND"]
		out = append(out, r)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no recipes in %s", repo.path("machines"))
	}
	return out, nil
}

// --- Facts about this Proxmox host (from new-machine.sh --info) --------------------------

type pveStorage struct {
	Name string `json:"name"`
	Free int64  `json:"free"`
}
type pveBridge struct{ Name, CIDR, Gateway string }
type pveMachine struct {
	ID, Name, Kind, IP, Recipe, User string
	AppsDomain                       string `json:"apps_domain"`
	Done, AdGuard                    bool
	AppProxy                         bool `json:"app_proxy"`
}
type pveInfo struct {
	Node       string
	NextID     string       `json:"nextid"`
	Bridges    []pveBridge  `json:"bridges"`
	StorageLXC []pveStorage `json:"storage_lxc"`
	StorageVM  []pveStorage `json:"storage_vm"`
	SSHKeys    []string     `json:"ssh_keys"`
	Machines   []pveMachine `json:"machines"`
}

func loadPveInfo(repo *Repo) (*pveInfo, error) {
	out, err := exec.Command("bash", repo.path("proxmox", "new-machine.sh"), "--info").Output()
	if err != nil {
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			msg = strings.TrimSpace(string(ee.Stderr))
		}
		return nil, fmt.Errorf("reading this Proxmox host's setup failed:\n\n%s", msg)
	}
	var info pveInfo
	if err := json.Unmarshal(out, &info); err != nil {
		return nil, fmt.Errorf("couldn't read the host facts: %w", err)
	}
	return &info, nil
}

func (in *pveInfo) adguardIP() string {
	for _, m := range in.Machines {
		if m.AdGuard && m.Done {
			return strings.Split(m.IP, "/")[0]
		}
	}
	return ""
}

func (in *pveInfo) bridge(name string) pveBridge {
	for _, b := range in.Bridges {
		if b.Name == name {
			return b
		}
	}
	return pveBridge{Name: name}
}

// --- Page 1: pick a recipe (or finish one that stopped) --------------------------------

type pveItem struct {
	recipe *recipe
	resume *pveMachine
}

type pveRecipesPage struct {
	repo   *Repo
	info   *pveInfo
	items  []pveItem
	cursor int
	w, h   int
}

func newPveRecipes(repo *Repo) (page, error) {
	recipes, err := loadRecipes(repo)
	if err != nil {
		return nil, err
	}
	info, err := loadPveInfo(repo)
	if err != nil {
		return nil, err
	}
	p := &pveRecipesPage{repo: repo, info: info}
	for _, r := range recipes {
		p.items = append(p.items, pveItem{recipe: r})
	}
	for i := range info.Machines {
		if m := &info.Machines[i]; !m.Done {
			p.items = append(p.items, pveItem{resume: m})
		}
	}
	return p, nil
}

func (p *pveRecipesPage) Init() tea.Cmd    { return nil }
func (p *pveRecipesPage) SetSize(w, h int) { p.w, p.h = w, h }
func (p *pveRecipesPage) Help() string {
	return help("↑/↓", "move", "enter", "choose", "esc", "back")
}

func (p *pveRecipesPage) Update(msg tea.Msg) (page, tea.Cmd) {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		return p, nil
	}
	switch k.String() {
	case "up", "k":
		p.cursor = max(p.cursor-1, 0)
	case "down", "j", "tab":
		p.cursor = min(p.cursor+1, len(p.items)-1)
	case "esc", "q":
		return p, pop(nil)
	case "enter":
		it := p.items[p.cursor]
		if it.resume != nil {
			m := it.resume
			st := step{Args: []string{"bash", p.repo.path("proxmox", "new-machine.sh"), "--resume", m.ID}, Env: os.Environ()}
			return p, tea.Sequence(pop(nil), push(newRun("Finish "+m.Name+" (ID "+m.ID+")", []step{st}, nil)))
		}
		return p, push(newPveForm(p.repo, p.info, it.recipe))
	}
	return p, nil
}

func (p *pveRecipesPage) View() string {
	var b strings.Builder
	b.WriteString("\n  " + sTitle.Render("New machine on this Proxmox") + "  " +
		sMuted.Render("pick a recipe: what kind of machine it is and what it runs") + "\n\n")
	for i, it := range p.items {
		var name, desc string
		if it.recipe != nil {
			name = fmt.Sprintf("%-6s %-4s", it.recipe.Name, it.recipe.kindLabel())
			desc = it.recipe.Summary
		} else {
			name = fmt.Sprintf("%-11s", "finish")
			desc = fmt.Sprintf("%s (ID %s) stopped halfway: pick up where it stopped", it.resume.Name, it.resume.ID)
		}
		bar := "  "
		if i == p.cursor {
			bar, name = " "+sSelBar.String(), sAcc.Bold(true).Render(name)
		}
		b.WriteString(bar + " " + name + " " + sMuted.Render(desc) + "\n")
	}

	width := max(min(p.w-6, 100), 30)
	var box []string
	if it := p.items[p.cursor]; it.recipe != nil {
		r := it.recipe
		box = append(box, sTitle.Render(r.Summary), "")
		box = append(box, r.Detail...)
		var mods []string
		for _, m := range []string{"system-update", "firewall", "ssh-hardening", "fail2ban", "auto-updates",
			"docker", "app-proxy", "adguard", "tailscale", "dev-tools"} {
			if r.uses(m) {
				mods = append(mods, m)
			}
		}
		box = append(box, "", sMuted.Render(fmt.Sprintf("%s · %s CPU · %s MB RAM · %s GB disk · modules: %s",
			r.kindLabel(), r.Cfg["PVE_CORES"], r.Cfg["PVE_MEMORY"], r.Cfg["PVE_DISK"], strings.Join(mods, ", "))))
		box = append(box, sMuted.Render("Recipe file: machines/"+r.Name+".env (copy it to make your own)"))
	} else {
		box = append(box, sTitle.Render("Finish "+it.resume.Name),
			"", "Creating it stopped before the end (the reason was shown then).",
			"This re-runs the remaining steps; anything already done is skipped quickly.")
	}
	b.WriteString("\n  " + strings.ReplaceAll(sBox.Width(width).Render(strings.Join(box, "\n")), "\n", "\n  "))

	if len(p.info.Machines) > 0 {
		var names []string
		for _, m := range p.info.Machines {
			names = append(names, fmt.Sprintf("%s (%s, %s)", m.Name, m.Kind, strings.Split(m.IP, "/")[0]))
		}
		b.WriteString("\n\n  " + sMuted.Render("Already made here: "+strings.Join(names, " · ")))
	}
	return b.String()
}

// --- Page 2: the questions for one recipe ---------------------------------------------

type pveFormDone struct{}
type pveFormCancel struct{}

type pveForm struct {
	repo *Repo
	info *pveInfo
	r    *recipe
	form *huh.Form

	name, id, ip, dns, bridge, storage, cores, memory, disk string
	user, keyChoice, keyPaste                               string
	asks                                                    map[string]*string
	confirm                                                 bool
	w, h                                                    int
}

var (
	reName = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	reUser = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
	reNum  = regexp.MustCompile(`^[0-9]+$`)
)

func newPveForm(repo *Repo, info *pveInfo, r *recipe) *pveForm {
	p := &pveForm{repo: repo, info: info, r: r, asks: map[string]*string{},
		name: r.Name, id: info.NextID, bridge: "vmbr0",
		cores: r.Cfg["PVE_CORES"], memory: r.Cfg["PVE_MEMORY"], disk: r.Cfg["PVE_DISK"]}
	if len(info.Bridges) > 0 && info.bridge("vmbr0").CIDR == "" {
		p.bridge = info.Bridges[0].Name
	}
	gw := info.bridge(p.bridge).Gateway
	p.dns = gw
	if ip := info.adguardIP(); ip != "" && !r.uses("adguard") {
		p.dns = ip
	}
	if st := p.storages(); len(st) > 0 {
		p.storage = st[0].Name
	}
	for _, m := range info.Machines { // same login user as last time
		if m.User != "" {
			p.user = m.User
		}
	}
	if len(info.SSHKeys) > 0 {
		p.keyChoice = info.SSHKeys[len(info.SSHKeys)-1]
	} else {
		p.keyChoice = "paste"
	}
	for _, a := range r.Asks {
		v := r.Cfg[a.Key]
		p.asks[a.Key] = &v
	}
	return p
}

func (p *pveForm) storages() []pveStorage {
	st := p.info.StorageLXC
	if p.r.Kind == "vm" {
		st = p.info.StorageVM
	}
	sorted := append([]pveStorage(nil), st...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Free > sorted[j].Free })
	return sorted
}

func (p *pveForm) Init() tea.Cmd {
	p.form = p.build()
	return p.form.Init()
}

func (p *pveForm) build() *huh.Form {
	taken := map[string]bool{}
	for _, m := range p.info.Machines {
		taken[m.Name] = true
	}
	prefix := func() string {
		if _, n, err := net.ParseCIDR(p.info.bridge(p.bridge).CIDR); err == nil {
			ones, _ := n.Mask.Size()
			return "/" + strconv.Itoa(ones)
		}
		return "/24"
	}

	var bridgeOpts []huh.Option[string]
	for _, b := range p.info.Bridges {
		label := b.Name
		if b.CIDR != "" {
			label += sMuted.Render("  " + b.CIDR)
		}
		bridgeOpts = append(bridgeOpts, huh.NewOption(label, b.Name))
	}
	if len(bridgeOpts) == 0 {
		bridgeOpts = []huh.Option[string]{huh.NewOption("vmbr0", "vmbr0")}
	}
	var storageOpts []huh.Option[string]
	for _, s := range p.storages() {
		storageOpts = append(storageOpts, huh.NewOption(fmt.Sprintf("%-14s %s", s.Name,
			sMuted.Render(fmt.Sprintf("%.0f GB free", float64(s.Free)/1e9))), s.Name))
	}
	if len(storageOpts) == 0 {
		storageOpts = []huh.Option[string]{huh.NewOption("local-lvm", "local-lvm")}
	}
	var keyOpts []huh.Option[string]
	for _, k := range p.info.SSHKeys {
		f := strings.Fields(k)
		label := f[0]
		if len(f) > 2 {
			label = strings.Join(f[2:], " ") + sMuted.Render("  "+f[0])
		}
		keyOpts = append(keyOpts, huh.NewOption(label, k))
	}
	keyOpts = append(keyOpts, huh.NewOption("Paste a key", "paste"))

	number := func(what string) func(string) error {
		return func(v string) error {
			if !reNum.MatchString(strings.TrimSpace(v)) || strings.TrimSpace(v) == "0" {
				return fmt.Errorf("%s must be a whole number", what)
			}
			return nil
		}
	}

	groups := []*huh.Group{
		huh.NewGroup(
			huh.NewNote().Title(p.r.kindLabel()+": "+p.r.Summary).
				Description("A few questions, then a summary before anything is created. esc = back"),
			huh.NewInput().Title("Name").Description("Its hostname, and its name in Proxmox").Value(&p.name).
				Validate(func(v string) error {
					if !reName.MatchString(v) {
						return fmt.Errorf("lowercase letters, digits and '-', e.g. dns")
					}
					if taken[v] {
						return fmt.Errorf("a machine called %s exists already", v)
					}
					return nil
				}),
			huh.NewInput().Title("Proxmox ID").Description("The next free one is filled in").Value(&p.id).Validate(number("The ID")),
			huh.NewInput().Title("IP address").
				Description("A free fixed address in your LAN, e.g. 192.168.1.2 (pick one outside your router's DHCP range)").
				Value(&p.ip).Validate(func(v string) error {
				v = strings.TrimSpace(v)
				if !strings.Contains(v, "/") {
					v += prefix()
				}
				if ip, _, err := net.ParseCIDR(v); err != nil || ip.To4() == nil {
					return fmt.Errorf("an IPv4 address like 192.168.1.2 (or 192.168.1.2/24)")
				}
				return nil
			}),
			huh.NewInput().Title("DNS server").
				Description(map[bool]string{true: "Your AdGuard machine, so it can find your other machines by name",
					false: "Your router for now (once the AdGuard machine exists, new machines use it)"}[p.dns != "" && p.dns != p.info.bridge(p.bridge).Gateway]).
				Value(&p.dns).Validate(func(v string) error {
				if net.ParseIP(strings.TrimSpace(v)) == nil {
					return fmt.Errorf("an IP address, e.g. 192.168.1.1")
				}
				return nil
			}),
		).Title("The machine"),

		huh.NewGroup(
			huh.NewSelect[string]().Title("Network bridge").Description("The one your LAN is on (usually vmbr0)").
				Options(bridgeOpts...).Value(&p.bridge),
			huh.NewSelect[string]().Title("Disk storage").Options(storageOpts...).Value(&p.storage),
			huh.NewInput().Title("CPU cores").Value(&p.cores).Validate(number("Cores")),
			huh.NewInput().Title("Memory (MB)").Value(&p.memory).Validate(number("Memory")),
			huh.NewInput().Title("Disk (GB)").Description("Can grow later (Proxmox → Hardware → Resize), never shrink").
				Value(&p.disk).Validate(number("Disk")),
		).Title("Size and place"),

		huh.NewGroup(
			huh.NewInput().Title("Your login user").Description("You'll ssh in as this user (not root), e.g. omar").
				Value(&p.user).Validate(func(v string) error {
				if !reUser.MatchString(v) || v == "root" {
					return fmt.Errorf("a lowercase username like omar (not root)")
				}
				return nil
			}),
			huh.NewSelect[string]().Title("Your SSH key").
				Description("Found on this Proxmox host (/root/.ssh/authorized_keys), or paste your laptop's").
				Options(keyOpts...).Value(&p.keyChoice),
		).Title("Logging in"),

		huh.NewGroup(
			huh.NewText().Title("Paste your public SSH key").
				Description("On your laptop: cat ~/.ssh/id_ed25519.pub  (none yet? ssh-keygen -t ed25519)").
				Value(&p.keyPaste).Validate(func(v string) error {
				if f := strings.Fields(v); len(f) < 2 || !strings.HasPrefix(f[0], "ssh-") && !strings.HasPrefix(f[0], "ecdsa-") && !strings.HasPrefix(f[0], "sk-") {
					return fmt.Errorf("one line starting with ssh-ed25519 or ssh-rsa")
				}
				return nil
			}),
		).WithHideFunc(func() bool { return p.keyChoice != "paste" }),
	}

	if len(p.r.Asks) > 0 {
		var fields []huh.Field
		for _, a := range p.r.Asks {
			in := huh.NewInput().Title(a.Label).Description(a.Help).Value(p.asks[a.Key])
			if a.Secret {
				in = in.EchoMode(huh.EchoModePassword)
			}
			if a.Key == "TIMEZONE" {
				in = in.Validate(func(v string) error {
					if v != "" && validTZ(v) != nil {
						return validTZ(v)
					}
					return nil
				})
			}
			fields = append(fields, in)
		}
		groups = append(groups, huh.NewGroup(fields...).Title("Settings for "+p.r.Name))
	}

	groups = append(groups, huh.NewGroup(
		huh.NewNote().Title("Review").DescriptionFunc(p.review, &p.ip),
		huh.NewConfirm().Title("Create it now?").Affirmative("Create").Negative("Not now").Value(&p.confirm),
	))

	f := huh.NewForm(groups...).WithTheme(huh.ThemeCharm()).WithShowHelp(true).
		WithWidth(max(min(p.w-4, 110), 40)).WithHeight(max(p.h-3, 10))
	f.SubmitCmd = func() tea.Msg { return pveFormDone{} }
	f.CancelCmd = func() tea.Msg { return pveFormCancel{} }

	return f
}

func (p *pveForm) cidr() string {
	v := strings.TrimSpace(p.ip)
	if v != "" && !strings.Contains(v, "/") {
		if _, n, err := net.ParseCIDR(p.info.bridge(p.bridge).CIDR); err == nil {
			ones, _ := n.Mask.Size()
			return v + "/" + strconv.Itoa(ones)
		}
		return v + "/24"
	}
	return v
}

func (p *pveForm) key() string {
	if p.keyChoice == "paste" {
		return strings.TrimSpace(strings.ReplaceAll(p.keyPaste, "\n", " "))
	}
	return p.keyChoice
}

func (p *pveForm) review() string {
	var b strings.Builder
	ip := strings.Split(p.cidr(), "/")[0]
	fmt.Fprintf(&b, "%s %s (ID %s): %s CPU, %s MB RAM, %s GB on %s\n", p.r.kindLabel(), p.name, p.id,
		p.cores, p.memory, p.disk, p.storage)
	fmt.Fprintf(&b, "Address %s on %s, gateway %s, DNS %s\n", p.cidr(), p.bridge, p.info.bridge(p.bridge).Gateway, p.dns)
	fmt.Fprintf(&b, "Log in afterwards: ssh %s@%s\n\n", p.user, ip)
	b.WriteString(sTitle.Render("What happens, step by step") + "\n")
	steps := []string{"Check the plan (ID, name and address are free, storage fits)"}
	if p.r.Kind == "vm" {
		steps = append(steps, "Download Debian's cloud image once (~400 MB, checksum verified)",
			"Create the VM; cloud-init sets your user, key and address on first boot")
	} else {
		steps = append(steps, "Download the Debian container template once",
			"Create an unprivileged container (safer: root inside isn't root on the host)")
	}
	steps = append(steps, "Start it and wait until it's online",
		"Create your login user with your SSH key and sudo",
		"Copy ops-scripts into it (/opt/ops-scripts)",
		"Run the recipe's modules inside it; each one explains itself as it runs")
	if p.r.uses("app-proxy") && p.info.adguardIP() != "" {
		steps = append(steps, "Point *."+*p.askOr("APPS_DOMAIN", "home.internal")+" at it in your AdGuard machine")
	}
	if p.r.uses("adguard") {
		for _, m := range p.info.Machines {
			if m.AppProxy && m.Done && *p.asks["ADGUARD_REWRITES"] == "" {
				steps = append(steps, "Add *."+m.AppsDomain+" → "+strings.Split(m.IP, "/")[0]+" (your "+m.Name+" machine) to AdGuard")
			}
		}
	}
	for i, s := range steps {
		fmt.Fprintf(&b, "%d. %s\n", i+1, s)
	}
	b.WriteString("\n" + sMuted.Render("If a step fails, it says why and how to fix it, and you can finish it later from New machine."))
	return b.String()
}

func (p *pveForm) askOr(key, def string) *string {
	if v, ok := p.asks[key]; ok && *v != "" {
		return v
	}
	return &def
}

func (p *pveForm) SetSize(w, h int) {
	p.w, p.h = w, h
	if p.form != nil {
		p.form = p.form.WithWidth(max(min(w-4, 110), 40)).WithHeight(max(h-3, 10))
	}
}

func (p *pveForm) Help() string { return help("enter", "next", "shift+tab", "back", "esc", "leave") }

func (p *pveForm) Update(msg tea.Msg) (page, tea.Cmd) {
	switch m := msg.(type) {
	case pveFormCancel:
		return p, pop(nil)
	case pveFormDone:
		if !p.confirm {
			return p, pop(nil)
		}
		return p, p.start()
	case tea.KeyMsg:
		if m.String() == "esc" {
			return p, pop(nil)
		}
	}
	f, cmd := p.form.Update(msg)
	if ff, ok := f.(*huh.Form); ok {
		p.form = ff
	}
	return p, cmd
}

func (p *pveForm) start() tea.Cmd {
	args := []string{"bash", p.repo.path("proxmox", "new-machine.sh"),
		"--recipe", p.r.Name, "--name", strings.TrimSpace(p.name), "--id", strings.TrimSpace(p.id),
		"--ip", p.cidr(), "--dns", strings.TrimSpace(p.dns), "--bridge", p.bridge, "--storage", p.storage,
		"--cores", strings.TrimSpace(p.cores), "--memory", strings.TrimSpace(p.memory), "--disk", strings.TrimSpace(p.disk),
		"--user", strings.TrimSpace(p.user), "--ssh-key", p.key()}
	if gw := p.info.bridge(p.bridge).Gateway; gw != "" {
		args = append(args, "--gateway", gw)
	}
	env := os.Environ()
	for _, a := range p.r.Asks {
		v := strings.TrimSpace(*p.asks[a.Key])
		if a.Secret {
			if v != "" {
				env = append(env, a.Key+"="+v) // secrets go by environment, never on the command line
			}
			continue
		}
		if v != "" || p.r.Cfg[a.Key] != "" {
			args = append(args, "--set", a.Key+"="+v)
		}
	}
	title := "New " + p.r.kindLabel() + ": " + p.name
	return tea.Sequence(pop(nil), pop(nil), push(newRun(title, []step{{Args: args, Env: env}}, nil)))
}

func (p *pveForm) View() string {
	if p.form == nil {
		return ""
	}
	return "\n" + lipglossIndent(p.form.View(), 2)
}

// --- Machines list ---------------------------------------------------------------------

func newPveMachines(repo *Repo) page {
	out, err := exec.Command("bash", repo.path("proxmox", "new-machine.sh"), "--list").CombinedOutput()
	text := strings.TrimRight(string(out), "\n")
	if err != nil && text == "" {
		text = err.Error()
	}
	return newMessage("Machines made by ops on this Proxmox",
		lipgloss.NewStyle().Render(text)+"\n\n"+sMuted.Render(
			"Unfinished ones can be finished from New machine. Settings live in /etc/ops-scripts/machines/ on this host."))
}
