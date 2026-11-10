package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// auditItem is one line of `checks/audit.sh --json`.
type auditItem struct {
	Type    string `json:"type"` // section | check | info | summary
	Title   string `json:"title"`
	Section string `json:"section"`
	ID      string `json:"id"`
	Status  string `json:"status"` // pass | warn | fail
	Message string `json:"message"`
	Fix     string `json:"fix"`      // args for checks/fix.sh
	FixDesc string `json:"fix_desc"` // what the fix does (or manual advice if Fix is empty)
	Risk    string `json:"risk"`     // safe | caution
	Pass    int    `json:"pass"`
	Warn    int    `json:"warn"`
	Fail    int    `json:"fail"`
}

func (it auditItem) fixable() bool { return it.Type == "check" && it.Status != "pass" && it.Fix != "" }

type auditLoadedMsg struct {
	items []auditItem
	err   error
}

func runAuditCmd(r *Repo) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("bash", r.path("checks", "audit.sh"), "--json")
		cmd.Env = r.Env()
		var out, errb bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errb
		_ = cmd.Run() // exits 1 when something fails; the JSON still tells us everything
		var items []auditItem
		sc := bufio.NewScanner(&out)
		sc.Buffer(make([]byte, 64*1024), 1024*1024)
		for sc.Scan() {
			var it auditItem
			if json.Unmarshal(sc.Bytes(), &it) == nil && it.Type != "" {
				items = append(items, it)
			}
		}
		if len(items) == 0 {
			return auditLoadedMsg{err: fmt.Errorf("audit produced no results. %s", strings.TrimSpace(errb.String()))}
		}
		return auditLoadedMsg{items: items}
	}
}

type auditPage struct {
	repo         *Repo
	loading      bool
	spin         spinner.Model
	items        []auditItem
	summary      auditSummary
	err          error
	cursor       int  // index into visibleChecks()
	problemsOnly bool // hide passing checks and info lines
	offset       int
	confirm      []auditItem // fixes awaiting Enter
	lastFixed    []auditItem // to report the outcome after the re-scan
	flash        string
	w, h         int
}

func newAudit(r *Repo) *auditPage {
	return &auditPage{repo: r, loading: true,
		spin: spinner.New(spinner.WithSpinner(spinner.MiniDot), spinner.WithStyle(sAcc))}
}

func (p *auditPage) Init() tea.Cmd    { return tea.Batch(p.spin.Tick, runAuditCmd(p.repo)) }
func (p *auditPage) SetSize(w, h int) { p.w, p.h = w, h }

func (p *auditPage) Help() string {
	switch {
	case p.loading:
		return help("esc", "back")
	case len(p.confirm) > 0:
		return help("enter", "apply", "esc", "cancel")
	}
	pairs := []string{"↑/↓", "move"}
	if sel := p.selected(); sel != nil && sel.fixable() {
		pairs = append(pairs, "enter", "fix")
	}
	if len(p.safeFixes()) > 0 {
		pairs = append(pairs, "a", "fix all safe")
	}
	toggle := "problems only"
	if p.problemsOnly {
		toggle = "show all"
	}
	return help(append(pairs, "p", toggle, "r", "re-scan", "esc", "back")...)
}

func (p *auditPage) rescan() tea.Cmd {
	p.loading = true
	p.flash = ""
	return tea.Batch(p.spin.Tick, runAuditCmd(p.repo))
}

func (p *auditPage) Update(msg tea.Msg) (page, tea.Cmd) {
	switch m := msg.(type) {
	case spinner.TickMsg:
		if !p.loading {
			return p, nil
		}
		var cmd tea.Cmd
		p.spin, cmd = p.spin.Update(m)
		return p, cmd
	case auditLoadedMsg:
		return p, p.loaded(m)
	case rescanMsg:
		return p, p.rescan()
	case tea.KeyMsg:
		return p.key(m.String())
	}
	return p, nil
}

type rescanMsg struct{}

func (p *auditPage) loaded(m auditLoadedMsg) tea.Cmd {
	p.loading = false
	p.err = m.err
	if m.err != nil {
		return nil
	}
	p.items = m.items
	for _, it := range m.items {
		if it.Type == "summary" {
			p.summary = auditSummary{Pass: it.Pass, Warn: it.Warn, Fail: it.Fail}
		}
	}
	p.reportFixed()
	// Start on the first problem.
	if p.lastFixed == nil {
		for i, it := range p.visibleChecks() {
			if it.Status != "pass" {
				p.cursor = i
				break
			}
		}
	}
	p.lastFixed = nil
	p.clampCursor()
	s := p.summary
	return func() tea.Msg { return summaryMsg(s) }
}

// reportFixed compares the new results with the checks we just fixed.
func (p *auditPage) reportFixed() {
	if len(p.lastFixed) == 0 {
		return
	}
	now := map[string]string{}
	for _, it := range p.items {
		if it.Type == "check" {
			now[it.ID] = it.Status
		}
	}
	fixed, still := 0, []string{}
	for _, f := range p.lastFixed {
		if st, ok := now[f.ID]; !ok || st == "pass" {
			fixed++ // gone or passing
		} else {
			still = append(still, f.Message)
		}
	}
	switch {
	case len(still) == 0:
		p.flash = sGreen.Render(fmt.Sprintf("✓ Fixed %d issue(s). Verified by a fresh scan.", fixed))
	case fixed > 0:
		p.flash = sYel.Render(fmt.Sprintf("! Fixed %d, still open: %s", fixed, strings.Join(still, "; ")))
	default:
		p.flash = sRed.Render("✗ Still open: " + strings.Join(still, "; ") + " (see the output for why)")
	}
}

func (p *auditPage) key(k string) (page, tea.Cmd) {
	if len(p.confirm) > 0 {
		switch k {
		case "enter", "y":
			return p, p.applyFixes()
		case "esc", "n", "q":
			p.confirm = nil
		}
		return p, nil
	}
	switch k {
	case "esc", "q":
		return p, pop(nil)
	}
	if p.loading {
		return p, nil
	}
	checks := p.visibleChecks()
	switch k {
	case "up", "k":
		if p.cursor > 0 {
			p.cursor--
		}
	case "down", "j":
		if p.cursor < len(checks)-1 {
			p.cursor++
		}
	case "home", "g":
		p.cursor = 0
	case "end", "G":
		p.cursor = len(checks) - 1
	case "p", "tab":
		id := ""
		if sel := p.selected(); sel != nil {
			id = sel.ID
		}
		p.problemsOnly = !p.problemsOnly
		p.cursor = 0
		for i, it := range p.visibleChecks() {
			if it.ID == id {
				p.cursor = i
			}
		}
	case "r":
		return p, p.rescan()
	case "enter":
		if sel := p.selected(); sel != nil && sel.fixable() {
			p.confirm = []auditItem{*sel}
		}
	case "a":
		if fixes := p.safeFixes(); len(fixes) > 0 {
			p.confirm = fixes
		}
	}
	p.clampCursor()
	return p, nil
}

// safeFixes returns one item per distinct safe fix for open problems.
func (p *auditPage) safeFixes() []auditItem {
	seen := map[string]bool{}
	var out []auditItem
	for _, it := range p.items {
		if it.fixable() && it.Risk != "caution" && !seen[it.Fix] {
			seen[it.Fix] = true
			out = append(out, it)
		}
	}
	return out
}

func (p *auditPage) applyFixes() tea.Cmd {
	fixes := p.confirm
	p.confirm = nil
	// Several checks can share one fix (e.g. ssh-hardening); run each once,
	// but remember every check it should resolve.
	var steps []step
	seen := map[string]bool{}
	var targets []auditItem
	for _, f := range fixes {
		for _, it := range p.items {
			if it.fixable() && it.Fix == f.Fix {
				targets = append(targets, it)
			}
		}
		if seen[f.Fix] {
			continue
		}
		seen[f.Fix] = true
		args := append([]string{"bash", p.repo.path("checks", "fix.sh")}, strings.Fields(f.Fix)...)
		steps = append(steps, step{Label: f.FixDesc, Args: args, Env: p.repo.Env()})
	}
	p.lastFixed = targets
	title := "Fix: " + fixes[0].FixDesc
	if len(steps) > 1 {
		title = fmt.Sprintf("Applying %d fixes", len(steps))
	}
	if len(steps) == 1 {
		steps[0].Label = ""
	}
	return push(newRun(title, steps, func(bool) tea.Cmd {
		return func() tea.Msg { return rescanMsg{} }
	}))
}

// --- Layout ---------------------------------------------------------------------

func (p *auditPage) visible(it auditItem) bool {
	switch it.Type {
	case "check":
		return !p.problemsOnly || it.Status != "pass"
	case "info":
		return !p.problemsOnly
	}
	return false
}

func (p *auditPage) visibleChecks() []auditItem {
	var out []auditItem
	for _, it := range p.items {
		if it.Type == "check" && p.visible(it) {
			out = append(out, it)
		}
	}
	return out
}

func (p *auditPage) selected() *auditItem {
	checks := p.visibleChecks()
	if p.cursor >= 0 && p.cursor < len(checks) {
		return &checks[p.cursor]
	}
	return nil
}

func (p *auditPage) clampCursor() {
	n := len(p.visibleChecks())
	if p.cursor >= n {
		p.cursor = n - 1
	}
	if p.cursor < 0 {
		p.cursor = 0
	}
}

func (p *auditPage) View() string {
	if p.loading {
		return "\n  " + p.spin.View() + " " + sTitle.Render("Scanning this server...") +
			"\n\n  " + sMuted.Render("Checking updates, SSH, accounts, firewall, open ports and more.")
	}
	if p.err != nil {
		return "\n  " + sRed.Render("Audit failed: ") + p.err.Error()
	}

	s := p.summary
	top := fmt.Sprintf("  %s   %s  %s  %s", sTitle.Render("Audit & fix"),
		sGreen.Render(fmt.Sprintf("✓ %d pass", s.Pass)), sYel.Render(fmt.Sprintf("! %d warn", s.Warn)),
		sRed.Render(fmt.Sprintf("✗ %d fail", s.Fail)))
	if p.problemsOnly {
		top += "   " + sMuted.Render("(problems only)")
	}
	if p.flash != "" {
		top += "\n  " + p.flash
	}
	top += "\n"

	panel := p.panel()
	listH := max(p.h-lipgloss.Height(top)-lipgloss.Height(panel)-2, 3)
	return top + "\n" + p.list(listH) + "\n" + panel
}

func (p *auditPage) list(height int) string {
	width := max(p.w-4, 20)
	var lines []string
	cursorLine := 0
	checkIdx := -1
	section := ""
	for _, it := range p.items {
		if !p.visible(it) {
			continue
		}
		if it.Section != section {
			section = it.Section
			if len(lines) > 0 {
				lines = append(lines, "")
			}
			lines = append(lines, "  "+sMuted.Bold(true).Render(strings.ToUpper(section)))
		}
		if it.Type == "info" {
			lines = append(lines, "      "+sMuted.Render(ansi.Truncate(it.Message, width-6, "…")))
			continue
		}
		checkIdx++
		selected := checkIdx == p.cursor
		bar := "  "
		if selected {
			bar = " " + sSelBar.String()
			cursorLine = len(lines)
		}
		tag := ""
		if it.fixable() {
			tag = sAcc.Render("  [fix]")
		} else if it.Status != "pass" && it.FixDesc != "" {
			tag = sMuted.Render("  [how]")
		}
		msg := it.Message
		avail := width - 4 - lipgloss.Width(tag)
		msg = ansi.Truncate(msg, max(avail, 10), "…")
		if selected {
			msg = sBold.Render(msg)
		}
		lines = append(lines, bar+" "+statusIcon(it.Status)+" "+msg+tag)
	}
	// Keep the cursor in view.
	if cursorLine < p.offset {
		p.offset = max(cursorLine-1, 0)
	}
	if cursorLine >= p.offset+height {
		p.offset = cursorLine - height + 1
	}
	p.offset = min(p.offset, max(len(lines)-height, 0))
	end := min(p.offset+height, len(lines))
	return strings.Join(lines[p.offset:end], "\n")
}

// panel is the box under the list: details of the selected check, or the
// confirmation for the fix(es) about to run.
func (p *auditPage) panel() string {
	width := max(min(p.w-4, 110), 30)
	inner := width - 4
	wrap := func(s string) string { return lipgloss.NewStyle().Width(inner).Render(s) }

	if len(p.confirm) > 0 {
		var b strings.Builder
		caution := false
		if len(p.confirm) == 1 {
			f := p.confirm[0]
			b.WriteString(sTitle.Render("Apply this fix?") + "\n\n")
			b.WriteString(wrap(f.FixDesc) + "\n\n")
			b.WriteString(sMuted.Render("Runs: ") + sCode.Render("sudo checks/fix.sh "+f.Fix) + "\n")
			caution = f.Risk == "caution"
		} else {
			b.WriteString(sTitle.Render(fmt.Sprintf("Apply %d safe fixes?", len(p.confirm))) + "\n\n")
			for _, f := range p.confirm {
				b.WriteString("  • " + f.FixDesc + "  " + sMuted.Render("(fix.sh "+f.Fix+")") + "\n")
			}
		}
		if caution {
			b.WriteString("\n" + sYel.Render(wrap("! Careful: this changes SSH, the firewall, accounts or reboots. "+
				"Your current SSH session stays connected, but keep it open and test a new login afterwards.")) + "\n")
		}
		b.WriteString("\n" + sKey.Render("Enter") + sMuted.Render(" apply    ") + sKey.Render("Esc") + sMuted.Render(" cancel"))
		box := sBox
		if caution {
			box = sBoxWarn
		}
		return "  " + strings.ReplaceAll(box.Width(width).Render(b.String()), "\n", "\n  ")
	}

	sel := p.selected()
	if sel == nil {
		return "  " + sGreen.Render("✓ No problems left. Press p to see every check.")
	}
	var b strings.Builder
	b.WriteString(statusIcon(sel.Status) + " " + sBold.Render(wrap(sel.Message)) + "\n")
	switch {
	case sel.fixable():
		b.WriteString(sMuted.Render("Fix: ") + wrap(sel.FixDesc) + "\n")
		risk := sGreen.Render("safe")
		if sel.Risk == "caution" {
			risk = sYel.Render("careful (asks before running)")
		}
		b.WriteString(sMuted.Render("Risk: ") + risk + "   " + sKey.Render("Enter") + sMuted.Render(" to fix"))
	case sel.Status != "pass" && sel.FixDesc != "":
		b.WriteString(sMuted.Render("How to fix (manual): ") + wrap(sel.FixDesc))
	case sel.Status != "pass":
		b.WriteString(sMuted.Render("No automatic fix for this one."))
	default:
		b.WriteString(sGreen.Render("All good."))
	}
	return "  " + strings.ReplaceAll(sBox.Width(width).Render(b.String()), "\n", "\n  ")
}
