package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// page is one screen. Pages are pointers and live on a stack: Enter pushes,
// Esc pops back to the previous screen.
type page interface {
	Init() tea.Cmd
	Update(tea.Msg) (page, tea.Cmd)
	View() string
	Help() string
	SetSize(w, h int)
}

type pushMsg struct{ p page }
type popMsg struct{ then tea.Cmd }

func push(p page) tea.Cmd { return func() tea.Msg { return pushMsg{p} } }
func pop(then tea.Cmd) tea.Cmd {
	return func() tea.Msg { return popMsg{then} }
}

type auditSummary struct{ Pass, Warn, Fail int }
type summaryMsg auditSummary

type app struct {
	repo    *Repo
	host    hostInfo
	stack   []page
	w, h    int
	summary *auditSummary
}

func newApp(repo *Repo) *app {
	a := &app{repo: repo, host: readHostInfo()}
	a.stack = []page{newHome(a)}
	return a
}

func (a *app) top() page { return a.stack[len(a.stack)-1] }

// Body size available to pages (minus header and footer).
func (a *app) bodySize() (int, int) { return a.w, max(a.h-4, 5) }

func (a *app) Init() tea.Cmd { return a.top().Init() }

func (a *app) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m := msg.(type) {
	case tea.WindowSizeMsg:
		a.w, a.h = m.Width, m.Height
		w, h := a.bodySize()
		for _, p := range a.stack {
			p.SetSize(w, h)
		}
		return a, nil
	case pushMsg:
		m.p.SetSize(a.bodySize())
		a.stack = append(a.stack, m.p)
		return a, m.p.Init()
	case popMsg:
		if len(a.stack) > 1 {
			a.stack = a.stack[:len(a.stack)-1]
		}
		return a, m.then
	case summaryMsg:
		s := auditSummary(m)
		a.summary = &s
		return a, nil
	}
	p, cmd := a.top().Update(msg)
	a.stack[len(a.stack)-1] = p
	return a, cmd
}

func (a *app) View() string {
	if a.w == 0 {
		return ""
	}
	left := sBrand.Render("ops") + " " + sTitle.Render(a.host.Name)
	right := sMuted.Render(strings.Join(nonEmpty(a.host.OS, a.host.IP, a.host.Arch), " · "))
	gap := max(a.w-lipgloss.Width(left)-lipgloss.Width(right)-2, 1)
	header := " " + left + strings.Repeat(" ", gap) + right
	rule := sMuted.Render(strings.Repeat("─", a.w))

	_, bodyH := a.bodySize()
	body := lipgloss.NewStyle().Height(bodyH).MaxHeight(bodyH).Render(a.top().View())
	footer := " " + a.top().Help()
	return lipgloss.JoinVertical(lipgloss.Left, header, rule, body, rule, footer)
}

func nonEmpty(xs ...string) []string {
	var out []string
	for _, x := range xs {
		if x != "" {
			out = append(out, x)
		}
	}
	return out
}

// --- Home ---------------------------------------------------------------------

type menuItem struct{ key, title, desc string }

type home struct {
	app    *app
	items  []menuItem
	cursor int
	w, h   int
}

func newHome(a *app) *home {
	return &home{app: a, items: []menuItem{
		{"setup", "Guided setup", "Pick modules, tools and settings, then run them"},
		{"audit", "Audit & fix", "Check security and health, then fix problems with Enter"},
		{"module", "Run a module", "Run a single module on its own"},
		{"secret", "Generate a secret", "App secrets, database passwords, SSH key help"},
		{"quit", "Quit", ""},
	}}
}

func (p *home) Init() tea.Cmd    { return nil }
func (p *home) SetSize(w, h int) { p.w, p.h = w, h }
func (p *home) Help() string     { return help("↑/↓", "move", "enter", "open", "q", "quit") }

func (p *home) Update(msg tea.Msg) (page, tea.Cmd) {
	if k, ok := msg.(tea.KeyMsg); ok {
		switch k.String() {
		case "up", "k":
			p.cursor = (p.cursor + len(p.items) - 1) % len(p.items)
		case "down", "j", "tab":
			p.cursor = (p.cursor + 1) % len(p.items)
		case "q", "ctrl+c", "esc":
			return p, tea.Quit
		case "enter":
			return p, p.open(p.items[p.cursor].key)
		}
	}
	return p, nil
}

func (p *home) open(key string) tea.Cmd {
	r := p.app.repo
	switch key {
	case "setup":
		sp, err := newSetup(r)
		if err != nil {
			return push(newMessage("Guided setup", err.Error()))
		}
		return push(sp)
	case "audit":
		return push(newAudit(r))
	case "module":
		mp, err := newModuleMenu(r)
		if err != nil {
			return push(newMessage("Run a module", err.Error()))
		}
		return push(mp)
	case "secret":
		return push(newSecrets())
	}
	return tea.Quit
}

func (p *home) View() string {
	var b strings.Builder
	b.WriteString("\n  " + sTitle.Render("What do you want to do?") + "\n\n")
	for i, it := range p.items {
		bar, title := "  ", sTitle.Render(it.title)
		if i == p.cursor {
			bar = " " + sSelBar.String()
			title = sAcc.Bold(true).Render(it.title)
		}
		b.WriteString(bar + " " + title + "\n")
		if it.desc != "" {
			b.WriteString("    " + sMuted.Render(it.desc) + "\n")
		}
		b.WriteString("\n")
	}
	if s := p.app.summary; s != nil {
		b.WriteString(fmt.Sprintf("  %s  %s  %s  %s\n", sMuted.Render("Last audit:"),
			sGreen.Render(fmt.Sprintf("✓ %d", s.Pass)), sYel.Render(fmt.Sprintf("! %d", s.Warn)),
			sRed.Render(fmt.Sprintf("✗ %d", s.Fail))))
	}
	return b.String()
}

// --- Simple message page --------------------------------------------------------

type message struct {
	title, text string
	w, h        int
}

func newMessage(title, text string) *message { return &message{title: title, text: text} }
func (p *message) Init() tea.Cmd             { return nil }
func (p *message) SetSize(w, h int)          { p.w, p.h = w, h }
func (p *message) Help() string              { return help("esc", "back") }
func (p *message) View() string {
	return "\n  " + sTitle.Render(p.title) + "\n\n" +
		lipgloss.NewStyle().Width(max(p.w-4, 20)).PaddingLeft(2).Render(p.text)
}
func (p *message) Update(msg tea.Msg) (page, tea.Cmd) {
	if k, ok := msg.(tea.KeyMsg); ok && (k.String() == "esc" || k.String() == "enter" || k.String() == "q") {
		return p, pop(nil)
	}
	return p, nil
}
