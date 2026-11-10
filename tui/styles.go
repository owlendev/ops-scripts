package main

import "github.com/charmbracelet/lipgloss"

var (
	cAccent = lipgloss.AdaptiveColor{Light: "#5B4BDB", Dark: "#A99BFF"}
	cGreen  = lipgloss.AdaptiveColor{Light: "#1A7F37", Dark: "#4ADE80"}
	cYellow = lipgloss.AdaptiveColor{Light: "#9A6700", Dark: "#FACC15"}
	cRed    = lipgloss.AdaptiveColor{Light: "#CF222E", Dark: "#F87171"}
	cText   = lipgloss.AdaptiveColor{Light: "#1F2328", Dark: "#E6EDF3"}
	cMuted  = lipgloss.AdaptiveColor{Light: "#6E7781", Dark: "#8B949E"}
	cBorder = lipgloss.AdaptiveColor{Light: "#D0D7DE", Dark: "#30363D"}
	cBadge  = lipgloss.AdaptiveColor{Light: "#FFFFFF", Dark: "#0D1117"}
)

var (
	sBrand = lipgloss.NewStyle().Bold(true).Foreground(cBadge).Background(cAccent).Padding(0, 1)
	sTitle = lipgloss.NewStyle().Bold(true).Foreground(cText)
	sMuted = lipgloss.NewStyle().Foreground(cMuted)
	sBold  = lipgloss.NewStyle().Bold(true)
	sAcc   = lipgloss.NewStyle().Foreground(cAccent)
	sGreen = lipgloss.NewStyle().Foreground(cGreen)
	sYel   = lipgloss.NewStyle().Foreground(cYellow)
	sRed   = lipgloss.NewStyle().Foreground(cRed)
	sCode  = lipgloss.NewStyle().Foreground(cAccent)

	sBox = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).BorderForeground(cBorder).Padding(0, 1)
	sBoxWarn = sBox.BorderForeground(cYellow)

	sSelBar = lipgloss.NewStyle().Foreground(cAccent).SetString("┃")
	sKey    = lipgloss.NewStyle().Foreground(cText).Bold(true)
)

// help renders "key action · key action" footers.
func help(pairs ...string) string {
	out := ""
	for i := 0; i+1 < len(pairs); i += 2 {
		if out != "" {
			out += sMuted.Render("  ·  ")
		}
		out += sKey.Render(pairs[i]) + " " + sMuted.Render(pairs[i+1])
	}
	return out
}

func statusIcon(status string) string {
	switch status {
	case "pass":
		return sGreen.Render("✓")
	case "warn":
		return sYel.Render("!")
	case "fail":
		return sRed.Render("✗")
	}
	return sMuted.Render("·")
}
