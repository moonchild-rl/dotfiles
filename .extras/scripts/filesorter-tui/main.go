package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/sync/errgroup"
	"gopkg.in/yaml.v3"
)

/* -------------------- Config -------------------- */

type Config struct {
	CaseInsensitive bool `yaml:"case_insensitive"`
	MinOccurrences  int  `yaml:"min_occurrences"`
	Workers         int  `yaml:"workers"`

	Rules struct {
		FolderMatch struct {
			Enabled bool   `yaml:"enabled"`
			Mode    string `yaml:"mode"` // "contains" or "word"
		} `yaml:"folder_match"`

		Keywords struct {
			By       string `yaml:"by_keyword"`       // default: " by "
			Original string `yaml:"original_keyword"` // default: "original"
		} `yaml:"keywords"`
	} `yaml:"rules"`

	Stopwords []string `yaml:"stopwords"`
}

func defaultConfig() Config {
	var cfg Config
	cfg.CaseInsensitive = true
	cfg.MinOccurrences = 2
	cfg.Workers = 8

	cfg.Rules.FolderMatch.Enabled = true
	cfg.Rules.FolderMatch.Mode = "contains"

	cfg.Rules.Keywords.By = " by "
	cfg.Rules.Keywords.Original = "original"

	cfg.Stopwords = []string{
		"a", "an", "and", "are", "as", "at", "be", "but", "by",
		"can", "could", "did", "do", "does", "for", "from", "had",
		"has", "have", "how", "i", "if", "in", "into", "is", "it",
		"me", "my", "no", "not", "of", "on", "or", "our", "please",
		"point", "right", "so", "someone", "that", "the", "their",
		"them", "then", "there", "they", "this", "to", "up", "was",
		"we", "were", "what", "when", "where", "which", "who", "why",
		"with", "would", "you", "your",
	}
	return cfg
}

func loadOrCreateConfig(path string) (Config, bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			cfg := defaultConfig()
			if err := writeConfig(path, cfg); err != nil {
				return Config{}, false, err
			}
			return cfg, true, nil
		}
		return Config{}, false, err
	}
	var cfg Config
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return Config{}, false, err
	}
	if cfg.MinOccurrences <= 0 {
		cfg.MinOccurrences = 2
	}
	if cfg.Workers <= 0 {
		cfg.Workers = 8
	}
	if strings.TrimSpace(cfg.Rules.Keywords.By) == "" {
		cfg.Rules.Keywords.By = " by "
	}
	if strings.TrimSpace(cfg.Rules.Keywords.Original) == "" {
		cfg.Rules.Keywords.Original = "original"
	}
	return cfg, false, nil
}

func writeConfig(path string, cfg Config) error {
	b, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

/* -------------------- Data structures -------------------- */

type FileRec struct {
	Name  string
	Path  string
	Ext   string
	Stem  string
	Tok   []string // tokens of Stem (underscore + hyphen kept)
	Paren []string // parentheses contents (raw)
	ByTok []string // tokens after "by" keyword (if present)

	FolderMatch string
}

type SuggestionKind string

const (
	SugBy       SuggestionKind = "by"
	SugOriginal SuggestionKind = "original"
	SugParen1   SuggestionKind = "paren_one_word"
	SugParenAny SuggestionKind = "paren_multi_word"
	SugBegin    SuggestionKind = "beginning"
)

type Suggestion struct {
	Kind    SuggestionKind
	Base    string
	Context []string
}

type CandidateGroup struct {
	Base      string
	Kind      SuggestionKind
	Files     []*FileRec
	Count     int
	Opt2      string
	Opt2Count int
	Opt3      string
	Opt3Count int
}

/* -------------------- CLI options -------------------- */

type Options struct {
	Dir     string
	Workers int
	Apply   bool
	Config  string
}

// IMPORTANT: supports "folder first, flags after" AND "flags first, folder after".
func parseArgs() Options {
	var opt Options
	opt.Dir = "."

	fs := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	fs.SetOutput(io.Discard) // avoid flag package printing; we handle errors ourselves

	fs.BoolVar(&opt.Apply, "apply", false, "Actually move files (default is dry-run)")
	fs.IntVar(&opt.Workers, "workers", 8, "Workers for scanning/moving (default 8)")
	fs.StringVar(&opt.Config, "config", "", "Path to config file (default: ./sorter.config.yaml)")

	args := os.Args[1:]

	// If first arg is a folder (not a flag), take it as Dir, then parse remaining flags.
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		opt.Dir = args[0]
		args = args[1:]
	}

	if err := fs.Parse(args); err != nil {
		// show a helpful message
		fmt.Fprintln(os.Stderr, "Argument error:", err)
		fmt.Fprintln(os.Stderr, "Usage:")
		fmt.Fprintln(os.Stderr, "  go run . /path/to/folder -apply")
		fmt.Fprintln(os.Stderr, "  go run . -apply /path/to/folder")
		os.Exit(2)
	}

	// If flags were first and folder is leftover, pick it up.
	if opt.Dir == "." && fs.NArg() > 0 && !strings.HasPrefix(fs.Arg(0), "-") {
		opt.Dir = fs.Arg(0)
	}

	return opt
}

/* -------------------- Scanning -------------------- */

func scanTopLevel(dir string) (subfolders []string, files []*FileRec, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, err
	}

	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		full := filepath.Join(dir, name)
		if e.IsDir() {
			subfolders = append(subfolders, name)
			continue
		}
		ext := filepath.Ext(name)
		stem := strings.TrimSuffix(name, ext)
		stem = normalizeStem(stem)

		files = append(files, &FileRec{
			Name: name,
			Path: full,
			Ext:  ext,
			Stem: stem,
			Tok:  tokenize(stem),
		})
	}

	sort.Strings(subfolders)
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	return subfolders, files, nil
}

func matchFolderNames(files []*FileRec, subfolders []string, cfg Config) {
	for _, f := range files {
		var matches []string
		for _, sf := range subfolders {
			if folderMatch(f.Stem, sf, cfg) {
				matches = append(matches, sf)
			}
		}
		if len(matches) == 1 {
			f.FolderMatch = matches[0]
		}
	}
}

func folderMatch(stem, folder string, cfg Config) bool {
	a := stem
	b := folder
	if cfg.CaseInsensitive {
		a = strings.ToLower(a)
		b = strings.ToLower(b)
	}
	mode := strings.ToLower(strings.TrimSpace(cfg.Rules.FolderMatch.Mode))
	if mode == "word" {
		re := regexp.MustCompile(`(^|\s)` + regexp.QuoteMeta(b) + `(\s|$)`)
		return re.FindStringIndex(a) != nil
	}
	return strings.Contains(a, b)
}

/* -------------------- Pre-extraction -------------------- */

func enrichFilesConcurrently(files []*FileRec, cfg Config) error {
	workers := cfg.Workers
	if workers <= 0 {
		workers = 8
	}
	if workers > runtime.NumCPU()*8 {
		workers = runtime.NumCPU() * 8
	}

	parenRe := regexp.MustCompile(`\(([^()]*)\)`)
	byKeyword := cfg.Rules.Keywords.By

	jobs := make(chan *FileRec)
	var g errgroup.Group
	g.SetLimit(workers)

	for i := 0; i < workers; i++ {
		g.Go(func() error {
			for f := range jobs {
				matches := parenRe.FindAllStringSubmatch(f.Stem, -1)
				for _, m := range matches {
					if len(m) < 2 {
						continue
					}
					v := strings.TrimSpace(m[1])
					if v != "" {
						f.Paren = append(f.Paren, v)
					}
				}
				f.ByTok = extractByTokens(f.Stem, byKeyword, cfg.CaseInsensitive)
			}
			return nil
		})
	}

	go func() {
		defer close(jobs)
		for _, f := range files {
			jobs <- f
		}
	}()

	return g.Wait()
}

func extractByTokens(stem, byKeyword string, caseInsensitive bool) []string {
	if strings.TrimSpace(byKeyword) == "" {
		byKeyword = " by "
	}
	hay := stem
	needle := byKeyword
	if caseInsensitive {
		hay = strings.ToLower(hay)
		needle = strings.ToLower(needle)
	}
	idx := strings.LastIndex(hay, needle)
	if idx < 0 {
		return nil
	}
	start := idx + len(needle)
	if start < 0 || start > len(stem) {
		return nil
	}
	tail := strings.TrimSpace(stem[start:])
	if tail == "" {
		return nil
	}
	return tokenize(tail)
}

/* -------------------- Suggestion heuristics -------------------- */

func computeSuggestion(f *FileRec, cfg Config, stop map[string]bool) (Suggestion, bool) {
	// 1) by
	if len(f.ByTok) > 0 {
		base := normalizeCandidate(f.ByTok[0])
		if base == "" || isStopwordSingle(base, stop) {
			return Suggestion{}, false
		}
		return Suggestion{Kind: SugBy, Base: base, Context: f.ByTok}, true
	}

	// 2) original -> username likely before "original"
	origSeg := originalPrefixTokens(f.Tok, cfg.Rules.Keywords.Original, cfg.CaseInsensitive)
	if len(origSeg) > 0 {
		base := normalizeCandidate(origSeg[0])
		if base == "" || isStopwordSingle(base, stop) {
			return Suggestion{}, false
		}
		return Suggestion{Kind: SugOriginal, Base: base, Context: origSeg}, true
	}

	// 3) parentheses containing exactly one word
	for i := len(f.Paren) - 1; i >= 0; i-- {
		p := f.Paren[i]
		pt := tokenize(p)
		if len(pt) == 1 {
			base := normalizeCandidate(pt[0])
			if base == "" || isStopwordSingle(base, stop) {
				continue
			}
			return Suggestion{Kind: SugParen1, Base: base, Context: nil}, true
		}
	}

	// 4) multi-word parentheses as fallback before "beginning"
	for i := len(f.Paren) - 1; i >= 0; i-- {
		p := f.Paren[i]
		pt := tokenize(p)
		if len(pt) >= 2 {
			base := normalizeCandidate(strings.Join(pt, " "))
			if base == "" {
				continue
			}
			return Suggestion{Kind: SugParenAny, Base: base, Context: nil}, true
		}
	}

	// 5) fallback: beginning first word
	if len(f.Tok) > 0 {
		base := normalizeCandidate(f.Tok[0])
		if base == "" || isStopwordSingle(base, stop) {
			return Suggestion{}, false
		}
		return Suggestion{Kind: SugBegin, Base: base, Context: f.Tok}, true
	}

	return Suggestion{}, false
}

func originalPrefixTokens(tokens []string, originalKeyword string, caseInsensitive bool) []string {
	if len(tokens) == 0 {
		return nil
	}
	okw := strings.TrimSpace(originalKeyword)
	if okw == "" {
		okw = "original"
	}
	for i := 0; i < len(tokens); i++ {
		a := tokens[i]
		b := okw
		if caseInsensitive {
			a = strings.ToLower(a)
			b = strings.ToLower(b)
		}
		if a == b {
			if i == 0 {
				return nil
			}
			return tokens[:i]
		}
	}
	return nil
}

func isStopwordSingle(s string, stop map[string]bool) bool {
	if strings.Contains(s, " ") {
		return false
	}
	return stop[strings.ToLower(s)]
}

/* -------------------- Matching -------------------- */

type Username struct {
	Name   string
	Folder string
	Tok    []string
}

func makeUsername(name string) (Username, bool) {
	n := sanitizeFolderName(normalizeCandidate(name))
	if n == "" {
		return Username{}, false
	}
	return Username{
		Name:   n,
		Folder: n,
		Tok:    tokenize(n),
	}, true
}

func tokensPrefixMatch(fileTok, userTok []string, caseInsensitive bool) bool {
	if len(fileTok) < len(userTok) {
		return false
	}
	for i := 0; i < len(userTok); i++ {
		a := fileTok[i]
		b := userTok[i]
		if caseInsensitive {
			a = strings.ToLower(a)
			b = strings.ToLower(b)
		}
		if a != b {
			return false
		}
	}
	return true
}

func fileMatchesUsernameStrict(f *FileRec, u Username, cfg Config) bool {
	if len(u.Tok) == 0 {
		return false
	}

	if len(f.ByTok) > 0 {
		return tokensPrefixMatch(f.ByTok, u.Tok, cfg.CaseInsensitive)
	}

	origSeg := originalPrefixTokens(f.Tok, cfg.Rules.Keywords.Original, cfg.CaseInsensitive)
	if len(origSeg) > 0 {
		return tokensPrefixMatch(origSeg, u.Tok, cfg.CaseInsensitive)
	}

	for _, p := range f.Paren {
		pt := tokenize(p)
		if len(pt) == 1 && len(u.Tok) == 1 {
			a := pt[0]
			b := u.Tok[0]
			if cfg.CaseInsensitive {
				a = strings.ToLower(a)
				b = strings.ToLower(b)
			}
			if a == b {
				return true
			}
		}
		if len(pt) >= 2 {
			if tokensPrefixMatch(pt, u.Tok, cfg.CaseInsensitive) {
				return true
			}
		}
	}

	return tokensPrefixMatch(f.Tok, u.Tok, cfg.CaseInsensitive)
}

func fileMatchesUsernamePartial(f *FileRec, typed string, cfg Config) bool {
	typed = strings.TrimLeft(typed, " ")
	if typed == "" {
		return false
	}

	endsWithSpace := strings.HasSuffix(typed, " ")
	ttok := tokenize(typed)
	if len(ttok) == 0 {
		return false
	}

	matchPrefix := func(fileTok []string) bool {
		if len(fileTok) < len(ttok) {
			return false
		}
		for i := 0; i < len(ttok); i++ {
			a := fileTok[i]
			b := ttok[i]
			if cfg.CaseInsensitive {
				a = strings.ToLower(a)
				b = strings.ToLower(b)
			}
			if i == len(ttok)-1 && !endsWithSpace {
				if !strings.HasPrefix(a, b) {
					return false
				}
			} else {
				if a != b {
					return false
				}
			}
		}
		return true
	}

	if len(f.ByTok) > 0 {
		return matchPrefix(f.ByTok)
	}
	origSeg := originalPrefixTokens(f.Tok, cfg.Rules.Keywords.Original, cfg.CaseInsensitive)
	if len(origSeg) > 0 {
		return matchPrefix(origSeg)
	}

	for _, p := range f.Paren {
		pt := tokenize(p)
		if len(pt) == 0 {
			continue
		}
		if matchPrefix(pt) {
			return true
		}
	}

	return matchPrefix(f.Tok)
}

/* -------------------- Build candidate groups -------------------- */

func buildGroups(files []*FileRec, cfg Config, stop map[string]bool, confirmedSet map[string]bool, skippedSet map[string]bool, confirmed []Username) []*CandidateGroup {
	eligible := make([]*FileRec, 0, len(files))
	for _, f := range files {
		if f.FolderMatch != "" {
			continue
		}
		if isCoveredByAny(f, confirmed, cfg) {
			continue
		}
		eligible = append(eligible, f)
	}

	type agg struct {
		kind  SuggestionKind
		files []*FileRec
		exp2  map[string]int
		exp3  map[string]int
	}
	m := map[string]*agg{}

	for _, f := range eligible {
		sug, ok := computeSuggestion(f, cfg, stop)
		if !ok || sug.Base == "" {
			continue
		}
		key := strings.ToLower(sug.Base)
		if confirmedSet[key] || skippedSet[key] {
			continue
		}

		a := m[sug.Base]
		if a == nil {
			a = &agg{kind: sug.Kind, exp2: map[string]int{}, exp3: map[string]int{}}
			m[sug.Base] = a
		}
		a.files = append(a.files, f)

		if (sug.Kind == SugBy || sug.Kind == SugOriginal || sug.Kind == SugBegin) && len(sug.Context) >= 2 {
			e2 := strings.Join(sug.Context[:2], " ")
			a.exp2[e2]++
			if len(sug.Context) >= 3 {
				e3 := strings.Join(sug.Context[:3], " ")
				a.exp3[e3]++
			}
		}
	}

	var groups []*CandidateGroup
	for base, a := range m {
		if len(a.files) < cfg.MinOccurrences {
			continue
		}
		sort.Slice(a.files, func(i, j int) bool { return a.files[i].Name < a.files[j].Name })

		opt2, opt2c := topExpansion(a.exp2)
		opt3, opt3c := topExpansion(a.exp3)

		groups = append(groups, &CandidateGroup{
			Base:      base,
			Kind:      a.kind,
			Files:     a.files,
			Count:     len(a.files),
			Opt2:      opt2,
			Opt2Count: opt2c,
			Opt3:      opt3,
			Opt3Count: opt3c,
		})
	}

	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Count == groups[j].Count {
			return groups[i].Base < groups[j].Base
		}
		return groups[i].Count > groups[j].Count
	})
	return groups
}

func topExpansion(m map[string]int) (string, int) {
	best := ""
	bestC := 0
	bestTok := -1
	for k, c := range m {
		tok := len(tokenize(k))
		if c > bestC || (c == bestC && tok > bestTok) || (c == bestC && tok == bestTok && k < best) {
			best = k
			bestC = c
			bestTok = tok
		}
	}
	return best, bestC
}

func isCoveredByAny(f *FileRec, confirmed []Username, cfg Config) bool {
	for _, u := range confirmed {
		if fileMatchesUsernameStrict(f, u, cfg) {
			return true
		}
	}
	return false
}

/* -------------------- Plan building -------------------- */

type MoveJob struct {
	SrcPath string
	DstDir  string
}

type AmbiguousFile struct {
	File    *FileRec
	Options []string
	Cursor  int
}

type Plan struct {
	Jobs     []MoveJob
	Unsorted []string
}

func buildPlan(files []*FileRec, confirmed []Username, cfg Config) (Plan, []*AmbiguousFile) {
	var jobs []MoveJob
	var unsorted []string
	var ambiguous []*AmbiguousFile

	for _, f := range files {
		if f.FolderMatch != "" {
			jobs = append(jobs, MoveJob{SrcPath: f.Path, DstDir: f.FolderMatch})
			continue
		}

		var matches []string
		for _, u := range confirmed {
			if fileMatchesUsernameStrict(f, u, cfg) {
				matches = append(matches, u.Folder)
			}
		}
		matches = uniqSorted(matches)

		if len(matches) == 1 {
			jobs = append(jobs, MoveJob{SrcPath: f.Path, DstDir: matches[0]})
		} else if len(matches) > 1 {
			ambiguous = append(ambiguous, &AmbiguousFile{File: f, Options: matches, Cursor: 0})
		} else {
			// by the end, unmatched files are simply not moved
			unsorted = append(unsorted, f.Name)
		}
	}

	sort.Slice(jobs, func(i, j int) bool { return filepath.Base(jobs[i].SrcPath) < filepath.Base(jobs[j].SrcPath) })
	sort.Strings(unsorted)
	return Plan{Jobs: jobs, Unsorted: unsorted}, ambiguous
}

/* -------------------- Moving with progress -------------------- */

type moveProgressMsg struct{ delta int }
type moveErrMsg struct{ err error }
type moveFinishedMsg struct{}

func startMoveWorkers(ctx context.Context, absTargetDir string, jobs []MoveJob, workers int) chan tea.Msg {
	ch := make(chan tea.Msg, 128)

	if workers <= 0 {
		workers = 8
	}
	if workers > len(jobs) && len(jobs) > 0 {
		workers = len(jobs)
	}
	if workers <= 0 {
		workers = 1
	}

	go func() {
		defer close(ch)

		ctx, cancel := context.WithCancel(ctx)
		defer cancel()

		jobCh := make(chan MoveJob)
		eg, egctx := errgroup.WithContext(ctx)

		for i := 0; i < workers; i++ {
			eg.Go(func() error {
				for {
					select {
					case <-egctx.Done():
						return egctx.Err()
					case j, ok := <-jobCh:
						if !ok {
							return nil
						}
						dstDirAbs := filepath.Join(absTargetDir, j.DstDir)
						if err := os.MkdirAll(dstDirAbs, 0o755); err != nil {
							return err
						}
						dstPath, err := uniqueDestPath(dstDirAbs, filepath.Base(j.SrcPath))
						if err != nil {
							return err
						}
						if err := safeMove(j.SrcPath, dstPath); err != nil {
							return err
						}
						ch <- moveProgressMsg{delta: 1}
					}
				}
			})
		}

		eg.Go(func() error {
			defer close(jobCh)
			for _, j := range jobs {
				select {
				case <-egctx.Done():
					return egctx.Err()
				case jobCh <- j:
				}
			}
			return nil
		})

		if err := eg.Wait(); err != nil && !errors.Is(err, context.Canceled) {
			ch <- moveErrMsg{err: err}
			return
		}
		ch <- moveFinishedMsg{}
	}()

	return ch
}

func waitMoveMsg(ch <-chan tea.Msg) tea.Cmd {
	return func() tea.Msg {
		msg, ok := <-ch
		if !ok {
			return moveFinishedMsg{}
		}
		return msg
	}
}

/* -------------------- Bubble Tea TUI -------------------- */

type stage int

const (
	stageCandidates stage = iota
	stageEdit
	stageConflicts
	stageSummary
	stageMoving
	stageDone
	stageQuit
)

type model struct {
	absTargetDir string
	cfgPath      string
	cfg          Config
	apply        bool

	createdConfig bool

	subfolders []string
	files      []*FileRec

	stop map[string]bool

	confirmed    []Username
	confirmedSet map[string]bool

	skippedSet map[string]bool

	groups []*CandidateGroup
	gidx   int

	editInput textinput.Model

	conflicts []*AmbiguousFile
	cidx      int

	plan Plan

	moveTotal   int
	moveDone    int64
	moveCh      chan tea.Msg
	moveErr     error
	progressBar progress.Model
	spin        spinner.Model

	st stage
}

/* -------------------- UI styles -------------------- */

var (
	titleStyle  = lipgloss.NewStyle().Bold(true)
	subtleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("241"))
	warnStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true)
	okStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("42")).Bold(true)

	card = lipgloss.NewStyle().
		Padding(1, 2).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("238"))

	hl = lipgloss.NewStyle().Background(lipgloss.Color("236")).Padding(0, 1)

	reco = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("229")).Background(lipgloss.Color("238")).Padding(0, 1)
)

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m.st {
	case stageCandidates:
		return m.updateCandidates(msg)
	case stageEdit:
		return m.updateEdit(msg)
	case stageConflicts:
		return m.updateConflicts(msg)
	case stageSummary:
		return m.updateSummary(msg)
	case stageMoving:
		return m.updateMoving(msg)
	case stageDone, stageQuit:
		return m, tea.Quit
	default:
		return m, nil
	}
}

func (m model) View() string {
	switch m.st {
	case stageCandidates:
		return m.viewCandidates()
	case stageEdit:
		return m.viewEdit()
	case stageConflicts:
		return m.viewConflicts()
	case stageSummary:
		return m.viewSummary()
	case stageMoving:
		return m.viewMoving()
	default:
		return ""
	}
}

/* -------------------- Candidate stage -------------------- */

func (m model) refreshGroups() model {
	m.groups = buildGroups(m.files, m.cfg, m.stop, m.confirmedSet, m.skippedSet, m.confirmed)
	m.gidx = 0
	return m
}

func (m model) currentGroup() *CandidateGroup {
	if m.gidx < 0 || m.gidx >= len(m.groups) {
		return nil
	}
	return m.groups[m.gidx]
}

func (m model) acceptUsername(name string) model {
	u, ok := makeUsername(name)
	if !ok {
		return m
	}
	key := strings.ToLower(u.Name)
	if m.confirmedSet[key] {
		return m
	}
	m.confirmedSet[key] = true
	m.confirmed = append(m.confirmed, u)
	return m.refreshGroups()
}

func (m model) skipCandidate(base string) model {
	k := strings.ToLower(strings.TrimSpace(base))
	if k != "" {
		m.skippedSet[k] = true
	}
	return m.refreshGroups()
}

func (m model) optionMatchCount(opt string) int {
	u, ok := makeUsername(opt)
	if !ok {
		return 0
	}
	cnt := 0
	for _, f := range m.files {
		if f.FolderMatch != "" {
			continue
		}
		if isCoveredByAny(f, m.confirmed, m.cfg) {
			continue
		}
		if fileMatchesUsernameStrict(f, u, m.cfg) {
			cnt++
		}
	}
	return cnt
}

func (m model) recommendOption(g *CandidateGroup) (recIdx int, counts [3]int, labels [3]string) {
	labels[0] = g.Base
	labels[1] = g.Opt2
	labels[2] = g.Opt3

	counts[0] = m.optionMatchCount(labels[0])
	if labels[1] != "" {
		counts[1] = m.optionMatchCount(labels[1])
	} else {
		counts[1] = -1
	}
	if labels[2] != "" {
		counts[2] = m.optionMatchCount(labels[2])
	} else {
		counts[2] = -1
	}

	maxC := counts[0]
	for i := 1; i < 3; i++ {
		if counts[i] > maxC {
			maxC = counts[i]
		}
	}

	// Among tied max count, recommend the LONGEST (most tokens), as requested.
	bestIdx := 0
	bestTok := len(tokenize(labels[0]))
	for i := 1; i < 3; i++ {
		if labels[i] == "" || counts[i] != maxC {
			continue
		}
		tok := len(tokenize(labels[i]))
		if counts[i] == maxC && tok > bestTok {
			bestIdx = i
			bestTok = tok
		}
	}
	// Also ensure bestIdx has the max count
	if counts[bestIdx] != maxC {
		// fallback to first max
		for i := 0; i < 3; i++ {
			if counts[i] == maxC && labels[i] != "" {
				bestIdx = i
				break
			}
		}
	}
	return bestIdx, counts, labels
}

func (m model) updateCandidates(msg tea.Msg) (tea.Model, tea.Cmd) {
	if len(m.groups) == 0 {
		m.plan, m.conflicts = m.buildPlanAndConflicts()
		m.st = stageSummary
		return m, nil
	}
	if m.gidx >= len(m.groups) {
		m.plan, m.conflicts = m.buildPlanAndConflicts()
		if len(m.conflicts) > 0 {
			m.st = stageConflicts
		} else {
			m.st = stageSummary
		}
		return m, nil
	}

	g := m.currentGroup()
	if g == nil {
		m.st = stageSummary
		return m, nil
	}

	switch k := msg.(type) {
	case tea.KeyMsg:
		switch k.String() {
		case "ctrl+c", "q":
			m.st = stageQuit
			return m, tea.Quit

		case "s":
			// skip candidate username permanently
			m = m.skipCandidate(g.Base)
			return m, nil

		case "e":
			ti := textinput.New()
			ti.SetValue(g.Base)
			ti.Placeholder = "type username / folder name"
			ti.Focus()
			ti.Width = 52
			ti.CharLimit = 200
			m.editInput = ti
			m.st = stageEdit
			return m, nil

		case "1":
			m = m.acceptUsername(g.Base)
			return m, nil

		case "2":
			if g.Opt2 != "" {
				m = m.acceptUsername(g.Opt2)
				return m, nil
			}

		case "3":
			if g.Opt3 != "" {
				m = m.acceptUsername(g.Opt3)
				return m, nil
			}

		case " ", "space":
			// Space selects +1 word (common action)
			if g.Opt2 != "" {
				m = m.acceptUsername(g.Opt2)
				return m, nil
			}

		case "enter":
			// Enter still accepts the proposed base (most common action)
			m = m.acceptUsername(g.Base)
			return m, nil
		}
	}
	return m, nil
}

func (m model) viewCandidates() string {
	if len(m.groups) == 0 || m.gidx >= len(m.groups) {
		return card.Render(titleStyle.Render("No candidates left") + "\n" + subtleStyle.Render("Press q to quit."))
	}

	g := m.groups[m.gidx]
	remaining := len(m.groups) - m.gidx

	recIdx, counts, labels := m.recommendOption(g)

	renderLine := func(idx int, key, name string, count int) string {
		if name == "" {
			return subtleStyle.Render(fmt.Sprintf("  %-10s (n/a)\n", key))
		}
		line := fmt.Sprintf("  %-10s %-34s %s", key, name, subtleStyle.Render(fmt.Sprintf("matches %d", count)))
		if idx == recIdx && count >= 0 {
			return reco.Render("recommended") + " " + line + "\n"
		}
		return line + "\n"
	}

	var b strings.Builder
	b.WriteString(titleStyle.Render(fmt.Sprintf("%d username candidates remaining", remaining)) + "\n\n")
	b.WriteString(fmt.Sprintf("Candidate: %q  ", g.Base))
	b.WriteString(subtleStyle.Render(fmt.Sprintf("(%s, seen %d×)", g.Kind, g.Count)))
	b.WriteString("\n\n")

	b.WriteString(titleStyle.Render("Choose:") + "\n")
	b.WriteString(renderLine(0, "[Enter]/[1]", labels[0], counts[0]))
	b.WriteString(renderLine(1, "[Space]/[2]", labels[1], counts[1]))
	b.WriteString(renderLine(2, "[3]", labels[2], counts[2]))

	b.WriteString("\nFiles in this candidate group:\n")
	maxShow := 10
	for i := 0; i < len(g.Files) && i < maxShow; i++ {
		b.WriteString("  - " + g.Files[i].Name + "\n")
	}
	if len(g.Files) > maxShow {
		b.WriteString(subtleStyle.Render(fmt.Sprintf("  ... (%d more)\n", len(g.Files)-maxShow)))
	}

	b.WriteString("\n")
	b.WriteString(subtleStyle.Render("Keys: e=edit  s=skip (forever)  q=quit"))
	return card.Render(b.String())
}

/* -------------------- Edit stage -------------------- */

func (m model) updateEdit(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.editInput, cmd = m.editInput.Update(msg)

	switch k := msg.(type) {
	case tea.KeyMsg:
		switch k.String() {
		case "ctrl+c", "q":
			m.st = stageQuit
			return m, tea.Quit
		case "esc":
			m.st = stageCandidates
			return m, nil
		case "enter":
			val := strings.TrimSpace(m.editInput.Value())
			if val != "" {
				m = m.acceptUsername(val)
			} else {
				// empty = skip current candidate permanently
				if g := m.currentGroup(); g != nil {
					m = m.skipCandidate(g.Base)
				}
			}
			m.st = stageCandidates
			return m, nil
		}
	}
	return m, cmd
}

func (m model) liveMatchesForTyped(typed string) (int, []string) {
	typed = strings.TrimLeft(typed, " ")
	if typed == "" {
		return 0, nil
	}
	var names []string
	for _, f := range m.files {
		if f.FolderMatch != "" {
			continue
		}
		if fileMatchesUsernamePartial(f, typed, m.cfg) {
			names = append(names, f.Name)
		}
	}
	sort.Strings(names)
	cnt := len(names)
	if len(names) > 10 {
		names = names[:10]
	}
	return cnt, names
}

func (m model) viewEdit() string {
	val := m.editInput.Value()
	cnt, list := m.liveMatchesForTyped(val)

	var b strings.Builder
	b.WriteString(titleStyle.Render("Edit / enter username") + "\n\n")
	b.WriteString("Type a username/folder name. Live matches update while you type.\n\n")
	b.WriteString(m.editInput.View() + "\n\n")
	b.WriteString(subtleStyle.Render(fmt.Sprintf("Live matches: %d\n", cnt)))
	for _, n := range list {
		b.WriteString("  - " + n + "\n")
	}
	if cnt > len(list) {
		b.WriteString(subtleStyle.Render(fmt.Sprintf("  ... (%d more)\n", cnt-len(list))))
	}
	b.WriteString("\n")
	b.WriteString(subtleStyle.Render("Keys: Enter=confirm  Esc=back  q=quit"))
	return card.Render(b.String())
}

/* -------------------- Conflict stage -------------------- */

func (m model) buildPlanAndConflicts() (Plan, []*AmbiguousFile) {
	p, amb := buildPlan(m.files, m.confirmed, m.cfg)
	return p, amb
}

func (m model) updateConflicts(msg tea.Msg) (tea.Model, tea.Cmd) {
	if m.cidx >= len(m.conflicts) {
		m.st = stageSummary
		return m, nil
	}
	cur := m.conflicts[m.cidx]

	switch k := msg.(type) {
	case tea.KeyMsg:
		switch k.String() {
		case "ctrl+c", "q":
			m.st = stageQuit
			return m, tea.Quit
		case "up", "k":
			if cur.Cursor > 0 {
				cur.Cursor--
			}
			return m, nil
		case "down", "j":
			if cur.Cursor < len(cur.Options) {
				cur.Cursor++
			}
			return m, nil
		case "enter":
			if cur.Cursor >= 0 && cur.Cursor < len(cur.Options) {
				// set a per-file destination
				cur.File.FolderMatch = cur.Options[cur.Cursor]
			}
			m.cidx++
			if m.cidx >= len(m.conflicts) {
				m.st = stageSummary
				m.plan, m.conflicts = m.buildPlanAndConflicts()
			}
			return m, nil
		}
	}
	return m, nil
}

func (m model) viewConflicts() string {
	cur := m.conflicts[m.cidx]
	var b strings.Builder
	b.WriteString(warnStyle.Render(fmt.Sprintf("Conflict %d/%d", m.cidx+1, len(m.conflicts))) + "\n\n")
	b.WriteString("File matches multiple confirmed usernames:\n")
	b.WriteString("  " + cur.File.Name + "\n\n")
	b.WriteString("Choose destination:\n")

	for i := 0; i < len(cur.Options); i++ {
		line := "  " + cur.Options[i]
		if cur.Cursor == i {
			b.WriteString(hl.Render(line) + "\n")
		} else {
			b.WriteString(line + "\n")
		}
	}
	skipIdx := len(cur.Options)
	skipLine := "  Skip this file"
	if cur.Cursor == skipIdx {
		b.WriteString(hl.Render(skipLine) + "\n")
	} else {
		b.WriteString(skipLine + "\n")
	}
	b.WriteString("\n")
	b.WriteString(subtleStyle.Render("Keys: ↑/↓  Enter=select  q=quit"))
	return card.Render(b.String())
}

/* -------------------- Summary + Moving -------------------- */

func (m model) updateSummary(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch k := msg.(type) {
	case tea.KeyMsg:
		switch k.String() {
		case "ctrl+c", "q":
			m.st = stageQuit
			return m, tea.Quit
		case "enter":
			if !m.apply {
				m.st = stageDone
				return m, tea.Quit
			}
			// Start moving
			m.st = stageMoving
			m.moveTotal = len(m.plan.Jobs)
			atomic.StoreInt64(&m.moveDone, 0)
			m.progressBar = progress.New(progress.WithDefaultGradient())
			m.spin = spinner.New()
			m.spin.Spinner = spinner.Dot

			ctx := context.Background()
			m.moveCh = startMoveWorkers(ctx, m.absTargetDir, m.plan.Jobs, m.cfg.Workers)

			cmds := []tea.Cmd{m.spin.Tick}
			if m.moveTotal > 0 {
				cmds = append(cmds, waitMoveMsg(m.moveCh))
			}
			return m, tea.Batch(cmds...)
		}
	}
	return m, nil
}

func (m model) viewSummary() string {
	m.plan, m.conflicts = m.buildPlanAndConflicts()

	var b strings.Builder
	b.WriteString(titleStyle.Render("Summary") + "\n\n")

	if m.createdConfig {
		b.WriteString(okStyle.Render("Created config: ") + m.cfgPath + "\n")
		b.WriteString(subtleStyle.Render("Edit it anytime; this run used defaults/overrides.") + "\n\n")
	}

	b.WriteString(fmt.Sprintf("Target:  %s\n", m.absTargetDir))
	if m.apply {
		b.WriteString(fmt.Sprintf("Mode:    %s\n", okStyle.Render("APPLY (move files)")))
	} else {
		b.WriteString(fmt.Sprintf("Mode:    %s\n", warnStyle.Render("DRY RUN (no moves)")))
	}
	b.WriteString(fmt.Sprintf("Workers: %d\n\n", m.cfg.Workers))

	b.WriteString(fmt.Sprintf("Confirmed usernames: %d\n", len(m.confirmed)))
	b.WriteString(fmt.Sprintf("Will move: %d file(s)\n", len(m.plan.Jobs)))
	b.WriteString(fmt.Sprintf("Unsorted (won't move): %d file(s)\n\n", len(m.plan.Unsorted)))

	preview := min(12, len(m.plan.Jobs))
	if preview > 0 {
		b.WriteString("Move preview:\n")
		for i := 0; i < preview; i++ {
			j := m.plan.Jobs[i]
			b.WriteString(fmt.Sprintf("  %s -> %s/\n", filepath.Base(j.SrcPath), j.DstDir))
		}
		if len(m.plan.Jobs) > preview {
			b.WriteString(subtleStyle.Render(fmt.Sprintf("  ... (%d more)\n", len(m.plan.Jobs)-preview)))
		}
		b.WriteString("\n")
	}

	if !m.apply {
		b.WriteString(subtleStyle.Render("Press Enter to exit (dry run), or q to quit."))
	} else {
		b.WriteString(warnStyle.Render("Press Enter to start moving files, or q to quit."))
	}
	return card.Render(b.String())
}

func (m model) updateMoving(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch x := msg.(type) {
	case tea.KeyMsg:
		switch x.String() {
		case "ctrl+c", "q":
			m.st = stageQuit
			return m, tea.Quit
		}

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case moveProgressMsg:
		done := atomic.AddInt64(&m.moveDone, int64(x.delta))
		if m.moveTotal > 0 {
			_ = m.progressBar.SetPercent(float64(done) / float64(m.moveTotal))
		}
		return m, waitMoveMsg(m.moveCh)

	case moveErrMsg:
		m.moveErr = x.err
		m.st = stageDone
		return m, tea.Quit

	case moveFinishedMsg:
		m.st = stageDone
		return m, tea.Quit
	}

	if m.moveCh != nil {
		return m, waitMoveMsg(m.moveCh)
	}
	return m, nil
}

func (m model) viewMoving() string {
	done := atomic.LoadInt64(&m.moveDone)

	var b strings.Builder
	b.WriteString(titleStyle.Render("Moving files...") + "\n\n")
	if m.moveTotal == 0 {
		b.WriteString(subtleStyle.Render("Nothing to move.\n"))
		return card.Render(b.String())
	}

	b.WriteString(fmt.Sprintf("%s  %d / %d\n\n", m.spin.View(), done, m.moveTotal))
	b.WriteString(m.progressBar.View() + "\n\n")
	b.WriteString(subtleStyle.Render("Press q to exit the UI (moves may still continue)."))
	return card.Render(b.String())
}

/* -------------------- Main -------------------- */

func main() {
	opt := parseArgs()

	absTargetDir, err := filepath.Abs(opt.Dir)
	must(err)

	cfgPath := opt.Config
	if cfgPath == "" {
		cwd, err := os.Getwd()
		must(err)
		cfgPath = filepath.Join(cwd, "sorter.config.yaml")
	}

	cfg, created, err := loadOrCreateConfig(cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Config error:", err)
		os.Exit(1)
	}

	if opt.Workers > 0 {
		cfg.Workers = opt.Workers
	}
	if cfg.Workers <= 0 {
		cfg.Workers = 8
	}

	subfolders, files, err := scanTopLevel(absTargetDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Scan error:", err)
		os.Exit(1)
	}

	stop := make(map[string]bool, len(cfg.Stopwords))
	for _, w := range cfg.Stopwords {
		stop[strings.ToLower(strings.TrimSpace(w))] = true
	}

	if cfg.Rules.FolderMatch.Enabled && len(subfolders) > 0 {
		matchFolderNames(files, subfolders, cfg)
	}

	if err := enrichFilesConcurrently(files, cfg); err != nil {
		fmt.Fprintln(os.Stderr, "Parse error:", err)
		os.Exit(1)
	}

	m := model{
		absTargetDir:  absTargetDir,
		cfgPath:       cfgPath,
		cfg:           cfg,
		apply:         opt.Apply,
		createdConfig: created,

		subfolders: subfolders,
		files:      files,
		stop:       stop,

		confirmed:    []Username{},
		confirmedSet: map[string]bool{},
		skippedSet:   map[string]bool{},

		groups: nil,
		gidx:   0,

		conflicts: nil,
		cidx:      0,

		progressBar: progress.New(progress.WithDefaultGradient()),
		spin:        spinner.New(),
		st:          stageCandidates,
	}

	m = m.refreshGroups()
	m.plan, m.conflicts = m.buildPlanAndConflicts()

	p := tea.NewProgram(m, tea.WithAltScreen())
	res, err := p.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "TUI error:", err)
		os.Exit(1)
	}

	finalModel := res.(model)
	finalPlan, _ := buildPlan(finalModel.files, finalModel.confirmed, finalModel.cfg)

	fmt.Printf("Target: %s\n", finalModel.absTargetDir)
	fmt.Printf("Mode: %s\n", func() string {
		if finalModel.apply {
			return "APPLY"
		}
		return "DRY RUN"
	}())
	fmt.Printf("Will move: %d, Unsorted: %d\n", len(finalPlan.Jobs), len(finalPlan.Unsorted))

	if finalModel.apply && finalModel.moveErr != nil {
		fmt.Fprintln(os.Stderr, "Move error:", finalModel.moveErr)
		os.Exit(1)
	}
}

/* -------------------- File move helpers -------------------- */

func uniqueDestPath(dstDir, baseName string) (string, error) {
	ext := filepath.Ext(baseName)
	stem := strings.TrimSuffix(baseName, ext)

	candidate := filepath.Join(dstDir, baseName)
	if _, err := os.Stat(candidate); err != nil {
		if os.IsNotExist(err) {
			return candidate, nil
		}
		return "", err
	}

	for n := 1; n <= 9999; n++ {
		name := fmt.Sprintf("%s (%d)%s", stem, n, ext)
		p := filepath.Join(dstDir, name)
		if _, err := os.Stat(p); err != nil {
			if os.IsNotExist(err) {
				return p, nil
			}
			return "", err
		}
	}
	return "", fmt.Errorf("too many name collisions for %q in %q", baseName, dstDir)
}

func safeMove(src, dst string) error {
	err := os.Rename(src, dst)
	if err == nil {
		return nil
	}
	if errors.Is(err, syscall.EXDEV) {
		if err := copyFilePreserve(src, dst); err != nil {
			return err
		}
		return os.Remove(src)
	}
	return err
}

func copyFilePreserve(src, dst string) error {
	st, err := os.Stat(src)
	if err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_EXCL, st.Mode())
	if err != nil {
		return err
	}

	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(dst)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(dst)
		return closeErr
	}

	mt := st.ModTime()
	_ = os.Chtimes(dst, time.Now(), mt)
	return nil
}

/* -------------------- Text helpers -------------------- */

// underscores AND hyphens are kept as part of tokens.
// we only normalize whitespace-like separators to spaces.
func normalizeStem(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Map(func(r rune) rune {
		switch r {
		case '\t', '\n', '\r':
			return ' '
		default:
			return r
		}
	}, s)
	return strings.Join(strings.Fields(s), " ")
}

func tokenize(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.FieldsFunc(s, func(r rune) bool { return unicode.IsSpace(r) })
	for i := range parts {
		// do NOT trim underscores or hyphens
		parts[i] = strings.Trim(parts[i], `"'“”‘’.,;:!`)
	}
	var out []string
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func normalizeCandidate(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, `"'“”‘’.,;:!`)
	s = strings.Join(strings.Fields(s), " ")
	return s
}

func sanitizeFolderName(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, `/\`)
	s = strings.ReplaceAll(s, string(os.PathSeparator), "_")
	if s == "." || s == ".." {
		return ""
	}
	s = strings.Join(strings.Fields(s), " ")
	return s
}

func uniqSorted(in []string) []string {
	if len(in) == 0 {
		return in
	}
	sort.Strings(in)
	out := in[:0]
	var last string
	for i, s := range in {
		if i == 0 || s != last {
			out = append(out, s)
			last = s
		}
	}
	return out
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
