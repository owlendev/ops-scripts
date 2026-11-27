package main

// Apps: a front end for the ops-app command on a machine with the app-proxy module:
// deploy your own app from Git, update it, back it up, check everything. The
// work is done by ops-app; its output streams into the run page.

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
)

const opsAppBin = "/usr/local/bin/ops-app"

func hasOpsApp() bool { return fileExists(opsAppBin) && fileExists("/etc/ops-app.env") }

func opsAppConf() map[string]string {
	cfg := map[string]string{}
	fh, err := os.Open("/etc/ops-app.env")
	if err != nil {
		return cfg
	}
	defer fh.Close()
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), "="); ok && !strings.HasPrefix(k, "#") {
			cfg[k] = v
		}
	}
	return cfg
}

// listApps returns the app folders (those with a compose file).
func listApps() []string {
	dir := opsAppConf()["APPS_DIR"]
	if dir == "" {
		return nil
	}
	entries, _ := os.ReadDir(dir)
	var apps []string
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), "_") || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		for _, f := range []string{"compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"} {
			if fileExists(filepath.Join(dir, e.Name(), f)) {
				apps = append(apps, e.Name())
				break
			}
		}
	}
	sort.Strings(apps)
	return apps
}

func gitApps() []string {
	meta := filepath.Join(opsAppConf()["APPS_DIR"], ".meta")
	var out []string
	for _, a := range listApps() {
		if data, err := os.ReadFile(filepath.Join(meta, a+".env")); err == nil && strings.Contains(string(data), "GIT_URL=") {
			out = append(out, a)
		}
	}
	return out
}

func opsAppStep(label string, args ...string) step {
	return step{Label: label, Args: append([]string{opsAppBin}, args...), Env: os.Environ()}
}

func opsAppOutput(args ...string) string {
	out, err := exec.Command(opsAppBin, args...).CombinedOutput()
	text := strings.TrimRight(string(out), "\n")
	if err != nil && text == "" {
		text = err.Error()
	}
	return text
}

// --- Menu ------------------------------------------------------------------------------

type appsPage struct {
	items  []menuItem
	cursor int
	w, h   int
}

func newAppsPage() *appsPage {
	domain := opsAppConf()["APPS_DOMAIN"]
	return &appsPage{items: []menuItem{
		{"list", "Your apps", "Every app, its address and whether it runs"},
		{"deploy", "Deploy an app from Git", "Your website or SaaS (Kontor...): clone, .env from .env.example, build, https://<name>." + domain},
		{"update", "Update an app", "Back up, pull the new code, rebuild, and check the new version answers"},
		{"backup", "Back up now", "Data volumes + .env, into the backups folder (nightly backups run on their own)"},
		{"backups", "Backups", "What's been backed up, and how to restore"},
		{"env", "An app's settings", "What's in its .env (secrets hidden), and what's still empty"},
		{"doctor", "Check everything", "Caddy, DNS names, and whether each app answers"},
	}}
}

func (p *appsPage) Init() tea.Cmd    { return nil }
func (p *appsPage) SetSize(w, h int) { p.w, p.h = w, h }
func (p *appsPage) Help() string     { return help("↑/↓", "move", "enter", "open", "esc", "back") }

func (p *appsPage) Update(msg tea.Msg) (page, tea.Cmd) {
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
		return p, p.open(p.items[p.cursor].key)
	}
	return p, nil
}

func (p *appsPage) open(key string) tea.Cmd {
	switch key {
	case "list":
		return push(newMessage("Your apps", opsAppOutput("list")))
	case "doctor":
		return push(newRun("Check everything", []step{opsAppStep("", "doctor")}, nil))
	case "backups":
		return push(newMessage("Backups", opsAppOutput("backups")+"\n\n"+sMuted.Render(
			"Restore one (a backup of the current state is made first):\n  sudo ops-app restore <app> <file> --yes")))
	case "deploy":
		return push(newDeployForm())
	case "update":
		apps := gitApps()
		if len(apps) == 0 {
			return push(newMessage("Update an app", "No apps deployed from Git yet. Use Deploy an app from Git first.\n(Apps from an image update with: ops-app pull <app>)"))
		}
		return push(newPickApp("Update which app?", apps, false, func(app string) tea.Cmd {
			return push(newRun("Update "+app, []step{opsAppStep("", "update", app)}, nil))
		}))
	case "backup":
		apps := listApps()
		if len(apps) == 0 {
			return push(newMessage("Back up now", "No apps yet."))
		}
		return push(newPickApp("Back up which app?", apps, true, func(app string) tea.Cmd {
			target := app
			if app == "*" {
				target = "--all"
			}
			return push(newRun("Back up "+map[bool]string{true: "everything", false: app}[app == "*"], []step{opsAppStep("", "backup", target)}, nil))
		}))
	case "env":
		apps := listApps()
		if len(apps) == 0 {
			return push(newMessage("Settings", "No apps yet."))
		}
		return push(newPickApp("Show the settings of which app?", apps, false, func(app string) tea.Cmd {
			return push(newMessage("Settings: "+app, opsAppOutput("env", app)))
		}))
	}
	return nil
}

func (p *appsPage) View() string {
	var b strings.Builder
	b.WriteString("\n  " + sTitle.Render("Apps on this machine") + "  " +
		sMuted.Render(fmt.Sprintf("%d app(s), each at https://<name>.%s", len(listApps()), opsAppConf()["APPS_DOMAIN"])) + "\n\n")
	for i, it := range p.items {
		bar, title := "  ", sTitle.Render(it.title)
		if i == p.cursor {
			bar, title = " "+sSelBar.String(), sAcc.Bold(true).Render(it.title)
		}
		b.WriteString(bar + " " + title + "\n    " + sMuted.Render(it.desc) + "\n\n")
	}
	return b.String()
}

// --- Pick an app -------------------------------------------------------------------------

type pickDone struct{}

type pickApp struct {
	form *huh.Form
	app  string
	then func(string) tea.Cmd
	w, h int
}

func newPickApp(title string, apps []string, withAll bool, then func(string) tea.Cmd) *pickApp {
	p := &pickApp{then: then}
	var opts []huh.Option[string]
	if withAll {
		opts = append(opts, huh.NewOption("All apps (+ Caddy's certificates)", "*"))
	}
	for _, a := range apps {
		opts = append(opts, huh.NewOption(a, a))
	}
	p.form = huh.NewForm(huh.NewGroup(huh.NewSelect[string]().Title(title).Options(opts...).Value(&p.app))).
		WithTheme(huh.ThemeCharm()).WithShowHelp(true)
	p.form.SubmitCmd = func() tea.Msg { return pickDone{} }
	p.form.CancelCmd = func() tea.Msg { return setupCanceledMsg{} }
	return p
}

func (p *pickApp) Init() tea.Cmd { return p.form.Init() }
func (p *pickApp) SetSize(w, h int) {
	p.w, p.h = w, h
	p.form = p.form.WithWidth(max(min(w-4, 90), 30))
}
func (p *pickApp) Help() string { return help("enter", "choose", "esc", "back") }
func (p *pickApp) View() string { return "\n" + lipglossIndent(p.form.View(), 2) }
func (p *pickApp) Update(msg tea.Msg) (page, tea.Cmd) {
	switch m := msg.(type) {
	case pickDone:
		return p, tea.Sequence(pop(nil), p.then(p.app))
	case setupCanceledMsg:
		return p, pop(nil)
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

// --- Deploy form -----------------------------------------------------------------------

type deployDone struct{}

type deployForm struct {
	form                    *huh.Form
	name, url, branch, port string
	go_                     bool
	w, h                    int
}

var reGitURL = regexp.MustCompile(`^(https?://\S+|ssh://\S+|[A-Za-z0-9._-]+@[^:/\s]+:\S+|/\S+)$`)

func newDeployForm() *deployForm {
	p := &deployForm{go_: true}
	domain := opsAppConf()["APPS_DOMAIN"]
	p.form = huh.NewForm(
		huh.NewGroup(
			huh.NewNote().Title("Deploy an app from Git").Description(
				"For your own website or SaaS that has a Dockerfile and a compose file (like Kontor).\n"+
					"ops-app clones it, makes .env from its .env.example (fills in this app's address and\n"+
					"generates internal secrets), turns off the app's own front door if it has one, builds it,\n"+
					"puts it behind Caddy, and checks it answers. Re-running it is safe."),
			huh.NewInput().Title("Name").Description("Its address becomes https://<name>."+domain).Value(&p.name).
				Validate(func(v string) error {
					if !regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`).MatchString(v) {
						return fmt.Errorf("lowercase letters, digits and '-', e.g. kontor")
					}
					return nil
				}),
			huh.NewInput().Title("Git URL").
				Description("Private repo? Use the SSH URL (git@github.com:you/app.git): a read-only deploy key is made, and you're shown where to add it").
				Value(&p.url).Validate(func(v string) error {
				if !reGitURL.MatchString(strings.TrimSpace(v)) {
					return fmt.Errorf("e.g. git@github.com:you/app.git or https://github.com/you/app.git")
				}
				return nil
			}),
			huh.NewInput().Title("Branch").Description("Empty = the repo's default branch").Value(&p.branch),
			huh.NewInput().Title("Port").Description("Empty = found automatically (compose file, Dockerfile EXPOSE)").Value(&p.port).
				Validate(func(v string) error {
					if v != "" && !reNum.MatchString(v) {
						return fmt.Errorf("a number, e.g. 8080")
					}
					return nil
				}),
			huh.NewConfirm().Title("Deploy it now?").Affirmative("Deploy").Negative("Not now").Value(&p.go_),
		),
	).WithTheme(huh.ThemeCharm()).WithShowHelp(true)
	p.form.SubmitCmd = func() tea.Msg { return deployDone{} }
	p.form.CancelCmd = func() tea.Msg { return setupCanceledMsg{} }
	return p
}

func (p *deployForm) Init() tea.Cmd { return p.form.Init() }
func (p *deployForm) SetSize(w, h int) {
	p.w, p.h = w, h
	p.form = p.form.WithWidth(max(min(w-4, 110), 40)).WithHeight(max(h-3, 10))
}
func (p *deployForm) Help() string { return help("enter", "next", "shift+tab", "back", "esc", "leave") }
func (p *deployForm) View() string { return "\n" + lipglossIndent(p.form.View(), 2) }
func (p *deployForm) Update(msg tea.Msg) (page, tea.Cmd) {
	switch m := msg.(type) {
	case deployDone:
		if !p.go_ {
			return p, pop(nil)
		}
		args := []string{"deploy", strings.TrimSpace(p.name), strings.TrimSpace(p.url)}
		if b := strings.TrimSpace(p.branch); b != "" {
			args = append(args, "--branch", b)
		}
		if pt := strings.TrimSpace(p.port); pt != "" {
			args = append(args, "--port", pt)
		}
		return p, tea.Sequence(pop(nil), push(newRun("Deploy "+p.name, []step{opsAppStep("", args...)}, nil)))
	case setupCanceledMsg:
		return p, pop(nil)
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
