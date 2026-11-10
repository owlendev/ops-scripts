package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// --- Run a single module -------------------------------------------------------

type moduleMenu struct {
	repo    *Repo
	modules []Module
	cursor  int
	confirm bool
	w, h    int
}

func newModuleMenu(r *Repo) (*moduleMenu, error) {
	mods, err := r.Modules()
	if err != nil {
		return nil, err
	}
	return &moduleMenu{repo: r, modules: mods}, nil
}

func (p *moduleMenu) Init() tea.Cmd    { return nil }
func (p *moduleMenu) SetSize(w, h int) { p.w, p.h = w, h }
func (p *moduleMenu) Help() string {
	if p.confirm {
		return help("enter", "run", "esc", "cancel")
	}
	return help("↑/↓", "move", "enter", "run", "esc", "back")
}

func (p *moduleMenu) Update(msg tea.Msg) (page, tea.Cmd) {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		return p, nil
	}
	if p.confirm {
		switch k.String() {
		case "enter", "y":
			p.confirm = false
			m := p.modules[p.cursor]
			args := []string{"bash", p.repo.path("bootstrap.sh"), "--only", m.Name}
			if p.repo.Config != "" {
				args = append(args, "-c", p.repo.Config)
			}
			return p, push(newRun("Module: "+m.Name, []step{{Args: args, Env: p.repo.Env()}}, nil))
		case "esc", "n":
			p.confirm = false
		}
		return p, nil
	}
	switch k.String() {
	case "up", "k":
		p.cursor = max(p.cursor-1, 0)
	case "down", "j":
		p.cursor = min(p.cursor+1, len(p.modules)-1)
	case "enter":
		p.confirm = true
	case "esc", "q":
		return p, pop(nil)
	}
	return p, nil
}

func (p *moduleMenu) View() string {
	var b strings.Builder
	b.WriteString("\n  " + sTitle.Render("Run a single module") + "  " +
		sMuted.Render("(modules are safe to re-run)") + "\n\n")
	for i, m := range p.modules {
		bar, name := "  ", fmt.Sprintf("%-17s", m.Name)
		if i == p.cursor {
			bar, name = " "+sSelBar.String(), sAcc.Bold(true).Render(name)
		}
		b.WriteString(bar + " " + name + " " + sMuted.Render(ansi.Truncate(m.Desc, max(p.w-26, 10), "…")) + "\n")
	}
	if p.confirm {
		cfg := "default settings"
		if p.repo.Config != "" {
			cfg = p.repo.Config
		}
		b.WriteString("\n  " + sYel.Render("Run "+p.modules[p.cursor].Name+" now") +
			sMuted.Render(" with "+cfg+"?  ") + sKey.Render("Enter") + sMuted.Render(" run  ") +
			sKey.Render("Esc") + sMuted.Render(" cancel"))
	}
	return b.String()
}

// --- Secrets ------------------------------------------------------------------

type secretKind struct {
	key, title, desc string
	gen              func() string
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func typeable(n int) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
	out := make([]byte, n)
	for i := range out {
		idx, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			panic(err)
		}
		out[i] = alphabet[idx.Int64()]
	}
	return string(out)
}

var secretKinds = []secretKind{
	{"app", "App secret / API key / JWT", "64 hex characters (256 bits)", func() string { return hex.EncodeToString(randBytes(32)) }},
	{"db", "Database password", "48 hex characters, safe inside connection URLs", func() string { return hex.EncodeToString(randBytes(24)) }},
	{"url", "URL-safe secret", "base64url, 43 characters", func() string { return base64.RawURLEncoding.EncodeToString(randBytes(32)) }},
	{"human", "Password you can type", "24 letters and digits, no look-alikes (0/O, 1/l)", func() string { return typeable(24) }},
	{"ssh", "SSH / EC2 key pair", "how to create one (on your own computer)", nil},
}

type secrets struct {
	cursor int
	value  string
	flash  string
	w, h   int
}

func newSecrets() *secrets          { return &secrets{} }
func (p *secrets) Init() tea.Cmd    { return nil }
func (p *secrets) SetSize(w, h int) { p.w, p.h = w, h }
func (p *secrets) Help() string {
	if p.value != "" {
		return help("c", "copy", "enter", "new one", "↑/↓", "type", "esc", "back")
	}
	return help("↑/↓", "move", "enter", "generate", "esc", "back")
}

func (p *secrets) Update(msg tea.Msg) (page, tea.Cmd) {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		return p, nil
	}
	switch k.String() {
	case "up", "k":
		p.cursor = max(p.cursor-1, 0)
		p.value, p.flash = "", ""
	case "down", "j":
		p.cursor = min(p.cursor+1, len(secretKinds)-1)
		p.value, p.flash = "", ""
	case "enter", "g":
		if gen := secretKinds[p.cursor].gen; gen != nil {
			p.value, p.flash = gen(), ""
		}
	case "c":
		if p.value != "" {
			termenv.Copy(p.value) // OSC 52: copies to YOUR clipboard, even over SSH
			p.flash = "Copied to your clipboard (needs a terminal with OSC 52: kitty, Ghostty, WezTerm, iTerm2, Windows Terminal...)"
		}
	case "esc", "q":
		return p, pop(nil)
	}
	return p, nil
}

func (p *secrets) View() string {
	var b strings.Builder
	b.WriteString("\n  " + sTitle.Render("Generate a secret") + "  " + sMuted.Render("(made with Go crypto/rand; nothing is stored)") + "\n\n")
	for i, s := range secretKinds {
		bar, title := "  ", sTitle.Render(s.title)
		if i == p.cursor {
			bar, title = " "+sSelBar.String(), sAcc.Bold(true).Render(s.title)
		}
		b.WriteString(bar + " " + title + "  " + sMuted.Render(s.desc) + "\n")
	}
	b.WriteString("\n")
	width := max(min(p.w-4, 100), 30)
	switch {
	case secretKinds[p.cursor].gen == nil:
		txt := sBold.Render("Create the key on YOUR computer, not on the server:") + "\n\n" +
			sCode.Render("ssh-keygen -t ed25519 -f ~/.ssh/acme-ec2 -C acme-ec2") + "\n\n" +
			"Then import " + sCode.Render("~/.ssh/acme-ec2.pub") + " in your cloud console\n" +
			"(AWS: EC2 → Key Pairs → Actions → Import key pair).\n" +
			sMuted.Render("Details: \"EC2 key pairs\" in README.md")
		b.WriteString("  " + strings.ReplaceAll(sBox.Width(width).Render(txt), "\n", "\n  "))
	case p.value != "":
		box := sBox.Width(width).Render(sGreen.Bold(true).Render(p.value) + "\n\n" +
			sMuted.Render("Copy it now. Press c to copy, or select it with your mouse."))
		b.WriteString("  " + strings.ReplaceAll(box, "\n", "\n  "))
		if p.flash != "" {
			b.WriteString("\n  " + lipgloss.NewStyle().Width(width).Render(sAcc.Render(p.flash)))
		}
	default:
		b.WriteString("  " + sMuted.Render("Press Enter to generate."))
	}
	return b.String()
}
