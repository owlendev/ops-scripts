package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// step is one command run by the run page, e.g. a bootstrap run or one fix.
type step struct {
	Label string
	Args  []string // Args[0] is the program
	Env   []string
}

type stepState int

const (
	stepPending stepState = iota
	stepRunning
	stepOK
	stepFailed
)

var runSeq int

type linesMsg struct {
	id    int
	lines []string
}
type stepDoneMsg struct {
	id  int
	err error
}

type modStatus struct {
	name  string
	state stepState
}

// runPage runs steps one after another and streams their output.
type runPage struct {
	title    string
	steps    []step
	states   []stepState
	cur      int
	id       int
	cmd      *exec.Cmd
	ch       chan tea.Msg
	lines    []string
	vp       viewport.Model
	spin     spinner.Model
	follow   bool
	running  bool
	canceled bool
	modules  []modStatus // parsed from bootstrap's "==> Module: X" lines
	onDone   func(ok bool) tea.Cmd
	w, h     int
}

func newRun(title string, steps []step, onDone func(ok bool) tea.Cmd) *runPage {
	sp := spinner.New(spinner.WithSpinner(spinner.MiniDot), spinner.WithStyle(sAcc))
	return &runPage{
		title: title, steps: steps, states: make([]stepState, len(steps)),
		spin: sp, follow: true, onDone: onDone, vp: viewport.New(80, 10),
	}
}

func (p *runPage) Init() tea.Cmd {
	return tea.Batch(p.spin.Tick, p.start(0))
}

func (p *runPage) SetSize(w, h int) {
	p.w, p.h = w, h
	p.vp.Width = max(w-2, 10)
	p.vp.Height = max(h-p.headerHeight(), 3)
	p.refresh()
}

func (p *runPage) headerHeight() int { return 4 }

func (p *runPage) Help() string {
	if p.running {
		return help("↑/↓ pgup/pgdn", "scroll", "end", "follow", "ctrl+c", "cancel")
	}
	return help("↑/↓ pgup/pgdn", "scroll", "enter/esc", "back")
}

func (p *runPage) start(i int) tea.Cmd {
	p.cur = i
	runSeq++
	p.id = runSeq
	s := p.steps[i]
	p.states[i] = stepRunning
	p.running = true
	if len(p.steps) > 1 || s.Label != "" {
		p.append(sAcc.Bold(true).Render(fmt.Sprintf("▶ %s", s.Label)))
	}

	cmd := exec.Command(s.Args[0], s.Args[1:]...)
	cmd.Env = s.Env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // so cancel kills children too
	r, w, err := os.Pipe()
	if err != nil {
		return p.failNow(err)
	}
	cmd.Stdout, cmd.Stderr = w, w
	if err := cmd.Start(); err != nil {
		r.Close()
		w.Close()
		return p.failNow(err)
	}
	w.Close()
	p.cmd = cmd
	p.ch = make(chan tea.Msg, 64)
	go readOutput(p.id, cmd, r, p.ch)
	return waitFor(p.ch)
}

func (p *runPage) failNow(err error) tea.Cmd {
	id := p.id
	return func() tea.Msg { return stepDoneMsg{id: id, err: err} }
}

// readOutput sends output in batches of lines (also splitting on \r, which
// apt and curl use for progress), then the exit status.
func readOutput(id int, cmd *exec.Cmd, r *os.File, ch chan<- tea.Msg) {
	defer r.Close()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	sc.Split(splitLinesCR)
	batch := []string{}
	flush := func() {
		if len(batch) > 0 {
			ch <- linesMsg{id: id, lines: batch}
			batch = []string{}
		}
	}
	lineCh := make(chan string)
	go func() {
		for sc.Scan() {
			lineCh <- sc.Text()
		}
		close(lineCh)
	}()
	for line := range lineCh {
		batch = append(batch, line)
	drain:
		for len(batch) < 200 {
			select {
			case l, ok := <-lineCh:
				if !ok {
					break drain
				}
				batch = append(batch, l)
			default:
				break drain
			}
		}
		flush()
	}
	ch <- stepDoneMsg{id: id, err: cmd.Wait()}
}

func splitLinesCR(data []byte, atEOF bool) (int, []byte, error) {
	if i := bytes.IndexAny(data, "\r\n"); i >= 0 {
		return i + 1, data[:i], nil
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

func waitFor(ch chan tea.Msg) tea.Cmd {
	return func() tea.Msg { return <-ch }
}

func (p *runPage) append(lines ...string) {
	for _, l := range lines {
		l = strings.TrimRight(l, " ")
		if strings.TrimSpace(ansi.Strip(l)) == "" && len(p.lines) > 0 && p.lines[len(p.lines)-1] == "" {
			continue // collapse blank runs
		}
		p.trackModule(l)
		p.lines = append(p.lines, l)
	}
	p.refresh()
}

func (p *runPage) trackModule(l string) {
	plain := ansi.Strip(l)
	if name, ok := strings.CutPrefix(plain, "==> Module: "); ok {
		if n := len(p.modules); n > 0 && p.modules[n-1].state == stepRunning {
			p.modules[n-1].state = stepOK
		}
		p.modules = append(p.modules, modStatus{name: strings.TrimSpace(name), state: stepRunning})
	} else if strings.HasPrefix(plain, "==> Summary") {
		if n := len(p.modules); n > 0 && p.modules[n-1].state == stepRunning {
			p.modules[n-1].state = stepOK
		}
	} else if strings.Contains(plain, " FAIL ") {
		if n := len(p.modules); n > 0 && p.modules[n-1].state == stepRunning {
			p.modules[n-1].state = stepFailed
		}
	}
}

func styleLine(l string) string {
	plain := ansi.Strip(l)
	switch {
	case strings.HasPrefix(plain, "==>"):
		return sAcc.Bold(true).Render(plain)
	case strings.Contains(plain, "] OK") || strings.HasPrefix(strings.TrimSpace(plain), "PASS"):
		return sGreen.Render(plain)
	case strings.Contains(plain, "] WARN") || strings.HasPrefix(strings.TrimSpace(plain), "WARN"):
		return sYel.Render(plain)
	case strings.Contains(plain, "] FAIL") || strings.HasPrefix(strings.TrimSpace(plain), "FAIL"):
		return sRed.Render(plain)
	case strings.HasPrefix(plain, "▶"):
		return l
	}
	return plain
}

func (p *runPage) refresh() {
	width := max(p.vp.Width, 10)
	var b strings.Builder
	for i, l := range p.lines {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(ansi.Hardwrap(styleLine(l), width, true))
	}
	p.vp.SetContent(b.String())
	if p.follow {
		p.vp.GotoBottom()
	}
}

func (p *runPage) Update(msg tea.Msg) (page, tea.Cmd) {
	switch m := msg.(type) {
	case spinner.TickMsg:
		var cmd tea.Cmd
		p.spin, cmd = p.spin.Update(m)
		return p, cmd
	case linesMsg:
		if m.id != p.id {
			return p, nil
		}
		p.append(m.lines...)
		return p, waitFor(p.ch)
	case stepDoneMsg:
		if m.id != p.id {
			return p, nil
		}
		return p, p.finishStep(m.err)
	case tea.KeyMsg:
		switch m.String() {
		case "ctrl+c":
			if p.running && p.cmd != nil && p.cmd.Process != nil {
				p.canceled = true
				_ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGTERM)
				p.append("", sYel.Render("Canceling..."))
			}
			return p, nil
		case "enter", "esc", "q":
			if !p.running {
				ok := !p.canceled
				for _, s := range p.states {
					ok = ok && s == stepOK
				}
				var then tea.Cmd
				if p.onDone != nil {
					then = p.onDone(ok)
				}
				return p, pop(then)
			}
			return p, nil
		case "end", "G":
			p.follow = true
			p.vp.GotoBottom()
			return p, nil
		}
		var cmd tea.Cmd
		p.vp, cmd = p.vp.Update(m)
		p.follow = p.vp.AtBottom()
		return p, cmd
	case tea.MouseMsg:
		var cmd tea.Cmd
		p.vp, cmd = p.vp.Update(m)
		p.follow = p.vp.AtBottom()
		return p, cmd
	}
	return p, nil
}

func (p *runPage) finishStep(err error) tea.Cmd {
	if err != nil {
		p.states[p.cur] = stepFailed
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok {
			msg = fmt.Sprintf("exit code %d", ee.ExitCode())
		}
		p.append("", sRed.Render("✗ "+p.label(p.cur)+" failed ("+msg+")"))
	} else {
		p.states[p.cur] = stepOK
		if len(p.steps) > 1 {
			p.append("", sGreen.Render("✓ "+p.label(p.cur)+" done"))
		}
	}
	if n := len(p.modules); n > 0 && p.modules[n-1].state == stepRunning {
		p.modules[n-1].state = map[bool]stepState{true: stepFailed, false: stepOK}[err != nil]
	}
	if !p.canceled && p.cur+1 < len(p.steps) {
		p.append("")
		return p.start(p.cur + 1)
	}
	p.running = false
	if p.canceled {
		p.append("", sYel.Render("Canceled."))
	}
	return nil
}

func (p *runPage) label(i int) string {
	if p.steps[i].Label != "" {
		return p.steps[i].Label
	}
	return p.title
}

func (p *runPage) View() string {
	var status string
	failed := 0
	for _, s := range p.states {
		if s == stepFailed {
			failed++
		}
	}
	switch {
	case p.running:
		status = p.spin.View() + " " + sMuted.Render("running...")
	case p.canceled:
		status = sYel.Render("■ canceled")
	case failed > 0:
		status = sRed.Render("✗ finished with errors")
	default:
		status = sGreen.Render("✓ done")
	}
	head := "  " + sTitle.Render(p.title) + "  " + status + "\n"
	head += "  " + p.progressLine() + "\n\n"
	return head + lipgloss.NewStyle().PaddingLeft(1).Render(p.vp.View())
}

func (p *runPage) progressLine() string {
	var parts []string
	icon := func(s stepState) string {
		switch s {
		case stepRunning:
			return p.spin.View()
		case stepOK:
			return sGreen.Render("✓")
		case stepFailed:
			return sRed.Render("✗")
		}
		return sMuted.Render("○")
	}
	if len(p.modules) > 0 {
		for _, m := range p.modules {
			parts = append(parts, icon(m.state)+" "+m.name)
		}
	} else if len(p.steps) > 1 {
		for i, s := range p.steps {
			parts = append(parts, icon(p.states[i])+" "+s.Label)
		}
	}
	return ansi.Truncate(strings.Join(parts, "  "), max(p.w-4, 10), "…")
}
