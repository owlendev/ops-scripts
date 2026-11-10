package main

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"regexp"
	"slices"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
)

type settingKind int

const (
	kindText settingKind = iota
	kindBool
	kindSecret
)

type setting struct {
	Key, Label, Help, Module string // Module: show only when it's selected ("" = always)
	Kind                     settingKind
	Validate                 func(string) error
}

var settings = []setting{
	{Key: "ADMIN_USER", Label: "Login user", Help: "The user you SSH in as (ubuntu on Ubuntu, admin on Debian).", Validate: validUser},
	{Key: "TIMEZONE", Label: "Timezone", Help: "e.g. UTC, Asia/Riyadh, Europe/London", Module: "system-update", Validate: validTZ},
	{Key: "HOSTNAME_FQDN", Label: "Hostname", Help: "e.g. web1.acme.com (empty = leave as is)", Module: "system-update"},
	{Key: "SWAP_SIZE", Label: "Swap size", Help: "auto (2G if RAM < 4G), 0 for none, or 1G / 4G...", Module: "swap", Validate: match(`^(auto|0|[0-9]+[MG])$`, "use auto, 0, or a size like 2G")},
	{Key: "FIREWALL_ALLOW_HTTP", Label: "Open HTTP (80)", Module: "firewall", Kind: kindBool},
	{Key: "FIREWALL_ALLOW_HTTPS", Label: "Open HTTPS (443)", Module: "firewall", Kind: kindBool},
	{Key: "FIREWALL_EXTRA_PORTS", Label: "Extra ports", Help: "space separated, e.g. 8080/tcp 443/udp", Module: "firewall", Validate: match(`^([0-9]+(:[0-9]+)?/(tcp|udp)( +|$))*$`, "use PORT/tcp or PORT/udp, space separated")},
	{Key: "SSH_ALLOW_FROM", Label: "SSH allowed from", Help: "CIDR like 203.0.113.4/32 (empty = anywhere; the cloud firewall still applies)", Module: "firewall"},
	{Key: "SSH_PORT", Label: "SSH port", Help: "Keep 22 unless you have a reason. If you change it, open it in the cloud firewall first.", Module: "ssh-hardening", Validate: validPort},
	{Key: "AUTO_UPDATES_REBOOT", Label: "Auto reboot at night when updates need it", Module: "auto-updates", Kind: kindBool},
	{Key: "GIT_USER_NAME", Label: "Git name", Module: "dev-tools"},
	{Key: "GIT_USER_EMAIL", Label: "Git email", Module: "dev-tools"},
	{Key: "TAILSCALE_AUTHKEY", Label: "Tailscale auth key", Help: "tskey-auth-... (empty = log in later). Never saved to files.", Module: "tailscale", Kind: kindSecret, Validate: match(`^(tskey-.*)?$`, "auth keys start with tskey-")},
	{Key: "TAILSCALE_HOSTNAME", Label: "Tailnet name", Help: "e.g. acme-web (empty = system hostname)", Module: "tailscale"},
	{Key: "TAILSCALE_SSH", Label: "Enable Tailscale SSH", Module: "tailscale", Kind: kindBool},
	{Key: "TAILSCALE_SSH_ONLY", Label: "Close public SSH once Tailscale is connected", Module: "tailscale", Kind: kindBool},
	{Key: "CERTBOT_DOMAINS", Label: "HTTPS domains", Help: "e.g. acme.com www.acme.com (DNS must point here; empty = skip)", Module: "nginx"},
	{Key: "CERTBOT_EMAIL", Label: "HTTPS email", Help: "Let's Encrypt expiry notices", Module: "nginx"},
	{Key: "REBOOT_IF_REQUIRED", Label: "Reboot at the end if updates need it", Kind: kindBool},
}

func isSecret(key string) bool {
	for _, s := range settings {
		if s.Key == key {
			return s.Kind == kindSecret
		}
	}
	return false
}

var cliCatalog = [][2]string{
	{"ripgrep", "rg: very fast grep"}, {"fd-find", "fd: simple, fast find"},
	{"fzf", "fuzzy finder (Ctrl-R history, Ctrl-T files)"}, {"bat", "cat with syntax highlighting"},
	{"eza", "modern ls (ll and lt aliases)"}, {"zoxide", "smarter cd: z <part-of-dir>"},
	{"btop", "CPU / memory / disk / network monitor"}, {"ncdu", "find what's using disk space"},
	{"duf", "disk usage overview"}, {"tealdeer", "tldr: short command examples"},
	{"git-delta", "readable git diffs"}, {"httpie", "http: friendly curl for APIs"},
	{"iftop", "bandwidth per connection"}, {"nethogs", "bandwidth per process"},
	{"iotop-c", "disk I/O per process"}, {"sysstat", "sar / iostat performance history"},
	{"strace", "trace system calls"}, {"lnav", "log viewer with search and filters"},
	{"plocate", "locate: instant file-name search"},
}

var devCatalog = [][2]string{
	{"git", "git + git-lfs with sane defaults"}, {"lazygit", "terminal UI for git"},
	{"lazydocker", "terminal UI for Docker containers and logs"},
	{"neovim", "latest Neovim (official release)"}, {"lazyvim", "LazyVim config (adds Neovim)"},
	{"herdr", "terminal multiplexer for coding agents"},
}

type setupDoneMsg struct{}
type setupCanceledMsg struct{}

type setupPage struct {
	repo    *Repo
	cfg     map[string]string
	modules []Module
	form    *huh.Form

	mods, cli, dev []string
	text           map[string]*string
	bools          map[string]*bool
	save, run      bool
	savePath       string
	w, h           int
}

func newSetup(r *Repo) (*setupPage, error) {
	cfg, err := r.LoadConfig()
	if err != nil {
		return nil, err
	}
	mods, err := r.Modules()
	if err != nil {
		return nil, err
	}
	p := &setupPage{repo: r, cfg: cfg, modules: mods, text: map[string]*string{}, bools: map[string]*bool{},
		run: true, savePath: r.path("config", "saved.local.env")}
	for _, m := range mods {
		if isYes(cfg[enableVar(m.Name)]) {
			p.mods = append(p.mods, m.Name)
		}
	}
	p.cli = strings.Fields(cfg["CLI_TOOLS"])
	p.dev = strings.Fields(cfg["DEV_TOOLS"])
	for _, s := range settings {
		if s.Kind == kindBool {
			v := isYes(cfg[s.Key])
			p.bools[s.Key] = &v
		} else {
			v := cfg[s.Key]
			p.text[s.Key] = &v
		}
	}
	return p, nil
}

func isYes(v string) bool {
	switch strings.ToLower(v) {
	case "1", "y", "yes", "true", "on":
		return true
	}
	return false
}

func (p *setupPage) on(module string) bool { return slices.Contains(p.mods, module) }

func (p *setupPage) buildForm() *huh.Form {
	listH := max(min(p.h-8, 16), 5)

	var modOpts []huh.Option[string]
	for _, m := range p.modules {
		modOpts = append(modOpts, huh.NewOption(fmt.Sprintf("%-17s %s", m.Name, sMuted.Render(m.Desc)), m.Name).
			Selected(p.on(m.Name)))
	}
	groups := []*huh.Group{
		huh.NewGroup(huh.NewMultiSelect[string]().
			Title("What should this server get?").
			Description("space = toggle · enter = next · shift+tab = back · esc = leave").
			Options(modOpts...).Value(&p.mods).Height(listH).Filterable(false)),
		huh.NewGroup(catalogSelect("Which CLI tools?", cliCatalog, &p.cli, listH)).
			WithHideFunc(func() bool { return !p.on("cli-tools") }),
		huh.NewGroup(catalogSelect("Which dev tools? (installed for the login user)", devCatalog, &p.dev, listH)).
			WithHideFunc(func() bool { return !p.on("dev-tools") }),
	}

	// One page of settings per module, shown only if the module is selected.
	order := []string{""}
	for _, m := range p.modules {
		order = append(order, m.Name)
	}
	for _, mod := range order {
		var fields []huh.Field
		for _, s := range settings {
			if s.Module != mod || (mod == "" && s.Key == "REBOOT_IF_REQUIRED") {
				continue
			}
			fields = append(fields, p.field(s))
		}
		if len(fields) == 0 {
			continue
		}
		mod := mod
		title := "General"
		if mod != "" {
			title = "Settings: " + mod
		}
		g := huh.NewGroup(fields...).Title(title)
		if mod != "" {
			g = g.WithHideFunc(func() bool { return !p.on(mod) })
		}
		groups = append(groups, g)
	}

	groups = append(groups,
		huh.NewGroup(
			huh.NewNote().Title("Review").DescriptionFunc(p.review, &p.mods),
			p.field(settingByKey("REBOOT_IF_REQUIRED")),
			huh.NewConfirm().Title("Save these choices to a config file?").
				Description("Reuse later with: sudo ./bootstrap.sh -c <file>").Value(&p.save),
		),
		huh.NewGroup(huh.NewInput().Title("Save to").Value(&p.savePath)).
			WithHideFunc(func() bool { return !p.save }),
		huh.NewGroup(huh.NewConfirm().Title("Run now?").Affirmative("Run now").Negative("Not now").Value(&p.run)),
	)

	f := huh.NewForm(groups...).WithTheme(huh.ThemeCharm()).WithShowHelp(true).
		WithWidth(max(min(p.w-4, 110), 40)).WithHeight(max(p.h-3, 10))
	f.SubmitCmd = func() tea.Msg { return setupDoneMsg{} }
	f.CancelCmd = func() tea.Msg { return setupCanceledMsg{} }
	return f
}

func settingByKey(k string) setting {
	for _, s := range settings {
		if s.Key == k {
			return s
		}
	}
	panic("unknown setting " + k)
}

func catalogSelect(title string, catalog [][2]string, value *[]string, height int) *huh.MultiSelect[string] {
	var opts []huh.Option[string]
	known := map[string]bool{}
	for _, c := range catalog {
		known[c[0]] = true
		opts = append(opts, huh.NewOption(fmt.Sprintf("%-10s %s", c[0], sMuted.Render(c[1])), c[0]).
			Selected(slices.Contains(*value, c[0])))
	}
	for _, v := range *value { // keep custom entries from a config file
		if !known[v] {
			opts = append(opts, huh.NewOption(v+" "+sMuted.Render("(from your config)"), v).Selected(true))
		}
	}
	return huh.NewMultiSelect[string]().Title(title).Options(opts...).Value(value).Height(height).Filterable(false)
}

func (p *setupPage) field(s setting) huh.Field {
	if s.Kind == kindBool {
		return huh.NewConfirm().Title(s.Label).Description(s.Help).Affirmative("Yes").Negative("No").Value(p.bools[s.Key])
	}
	in := huh.NewInput().Title(s.Label).Description(s.Help).Value(p.text[s.Key])
	if s.Kind == kindSecret {
		in = in.EchoMode(huh.EchoModePassword)
	}
	if s.Validate != nil {
		in = in.Validate(func(v string) error {
			if v == "" && s.Key != "ADMIN_USER" && s.Key != "SSH_PORT" && s.Key != "TIMEZONE" {
				return nil
			}
			return s.Validate(strings.TrimSpace(v))
		})
	}
	return in
}

func (p *setupPage) review() string {
	var b strings.Builder
	if len(p.mods) == 0 {
		return sYel.Render("No modules selected: nothing will run.")
	}
	b.WriteString("Modules: " + strings.Join(p.mods, ", ") + "\n")
	if p.on("cli-tools") {
		b.WriteString(fmt.Sprintf("CLI tools: %d selected\n", len(p.cli)))
	}
	if p.on("dev-tools") {
		b.WriteString("Dev tools: " + strings.Join(p.dev, ", ") + "\n")
	}
	if p.on("ssh-hardening") && *p.text["SSH_PORT"] != "22" {
		b.WriteString(sYel.Render("! SSH will move to port "+*p.text["SSH_PORT"]+". Open it in the cloud firewall first.") + "\n")
	}
	if p.on("tailscale") && *p.bools["TAILSCALE_SSH_ONLY"] {
		b.WriteString(sYel.Render("! Public SSH closes once Tailscale is connected.") + "\n")
	}
	return b.String()
}

func (p *setupPage) values() (map[string]string, []string) {
	vals := map[string]string{}
	var keys []string
	for _, m := range p.modules {
		k := enableVar(m.Name)
		vals[k] = map[bool]string{true: "yes", false: "no"}[p.on(m.Name)]
		keys = append(keys, k)
	}
	vals["CLI_TOOLS"], vals["DEV_TOOLS"] = strings.Join(p.cli, " "), strings.Join(p.dev, " ")
	keys = append(keys, "CLI_TOOLS", "DEV_TOOLS")
	for _, s := range settings {
		if s.Kind == kindBool {
			vals[s.Key] = map[bool]string{true: "yes", false: "no"}[*p.bools[s.Key]]
		} else {
			vals[s.Key] = strings.TrimSpace(*p.text[s.Key])
		}
		keys = append(keys, s.Key)
	}
	return vals, keys
}

func (p *setupPage) Init() tea.Cmd {
	p.form = p.buildForm()
	return p.form.Init()
}

func (p *setupPage) SetSize(w, h int) {
	p.w, p.h = w, h
	if p.form != nil {
		p.form = p.form.WithWidth(max(min(w-4, 110), 40)).WithHeight(max(h-3, 10))
	}
}

func (p *setupPage) Help() string { return help("esc", "leave setup") }

func (p *setupPage) Update(msg tea.Msg) (page, tea.Cmd) {
	switch m := msg.(type) {
	case setupCanceledMsg:
		return p, pop(nil)
	case setupDoneMsg:
		return p, p.finish()
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

func (p *setupPage) finish() tea.Cmd {
	vals, keys := p.values()
	note := ""
	if p.save && strings.TrimSpace(p.savePath) != "" {
		if err := p.repo.WriteChoices(p.savePath, vals, keys, true); err != nil {
			note = "Could not save: " + err.Error()
		} else {
			note = "Saved to " + p.savePath
		}
	}
	if !p.run || len(p.mods) == 0 {
		if note == "" {
			return pop(nil)
		}
		return tea.Sequence(pop(nil), push(newMessage("Guided setup", note)))
	}
	tmp, err := os.CreateTemp("", "ops-choices-*.env")
	if err != nil {
		return push(newMessage("Guided setup", err.Error()))
	}
	tmp.Close()
	if err := p.repo.WriteChoices(tmp.Name(), vals, keys, false); err != nil {
		return push(newMessage("Guided setup", err.Error()))
	}
	title := "Guided setup"
	if note != "" {
		title += "  " + sMuted.Render("("+note+")")
	}
	st := step{Args: []string{"bash", p.repo.path("bootstrap.sh"), "-c", tmp.Name()}, Env: os.Environ()}
	return tea.Sequence(pop(nil), push(newRun(title, []step{st}, func(bool) tea.Cmd {
		os.Remove(tmp.Name())
		return nil
	})))
}

// --- Validation ---------------------------------------------------------------

func match(pattern, msg string) func(string) error {
	re := regexp.MustCompile(pattern)
	return func(v string) error {
		if !re.MatchString(v) {
			return errors.New(msg)
		}
		return nil
	}
}

func validUser(v string) error {
	if _, err := user.Lookup(v); err != nil {
		return fmt.Errorf("user %q does not exist on this server", v)
	}
	return nil
}

func validTZ(v string) error {
	if !fileExists("/usr/share/zoneinfo/"+v) || strings.Contains(v, "..") {
		return fmt.Errorf("unknown timezone %q", v)
	}
	return nil
}

func validPort(v string) error {
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 65535 {
		return errors.New("port must be 1-65535")
	}
	return nil
}

func (p *setupPage) View() string {
	if p.form == nil {
		return ""
	}
	return "\n" + lipglossIndent(p.form.View(), 2)
}

func lipglossIndent(s string, n int) string {
	pad := strings.Repeat(" ", n)
	return pad + strings.ReplaceAll(s, "\n", "\n"+pad)
}
