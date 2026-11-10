// ops: terminal UI for ops-scripts. It runs the repo's bash modules, audit and
// fixes, and shows their progress; the scripts remain the source of truth.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
)

var version = "dev"

func main() {
	root := flag.String("root", "", "path to the ops-scripts folder (default: auto-detect)")
	config := flag.String("c", "", "client config file to start from")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: sudo ops [-c client.env] [--root DIR]\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	if *showVersion {
		fmt.Println("ops", version)
		return
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "ops changes system settings, so it needs root:  sudo ./ops")
		os.Exit(1)
	}

	dir, err := findRoot(*root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ops:", err)
		os.Exit(1)
	}
	repo := &Repo{Root: dir}
	if *config != "" {
		if repo.Config, err = filepath.Abs(*config); err != nil || !fileExists(repo.Config) {
			fmt.Fprintln(os.Stderr, "ops: config file not found:", *config)
			os.Exit(1)
		}
	}

	if _, err := tea.NewProgram(newApp(repo), tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "ops:", err)
		os.Exit(1)
	}
}
