// stress — Nerve PIX ramp-up load test with live TUI dashboard
//
// Displays a full-screen dashboard (no dependencies) with:
//   • RPS time-series chart    • p99 latency time-series chart
//   • CPU % per process        • Memory per process
//   • Phase progress bar       • Phase history table
//
// Usage:
//   go run .                                    (30s total, 5s/phase, 2→80 workers)
//   go run . -duration 60s -step 10s           (longer test)
//   go run . -ramp 5,10,25,50,100,200          (custom worker schedule)
//   go run . -no-seed                          (skip seeding)

package main

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// ANSI escape codes
// ─────────────────────────────────────────────────────────────────────────────

const (
	aReset   = "\033[0m"
	aBold    = "\033[1m"
	aDim     = "\033[2m"
	aGreen   = "\033[32m"
	aYellow  = "\033[33m"
	aBGreen  = "\033[92m"
	aBYellow = "\033[93m"
	aBRed    = "\033[91m"
	aHide    = "\033[?25l"
	aShow    = "\033[?25h"
	aHome    = "\033[H"
	aClearSc = "\033[2J"
)

// ─────────────────────────────────────────────────────────────────────────────
// Layout — target 120-column terminal
//
//  ╔══ title ════════════════════════════════════════════════════════════════╗
//  ║ phase info                                                              ║
//  ╠══ Requests/s ═══════════════════════════╦══ Latency p99 ══════════════╣
//  ║ [chart rows × chartH]                   ║ [chart rows × chartH]       ║
//  ║ max / last label                        ║ max / last label             ║
//  ╠══ CPU % ════════════════════════════════╬══ Memory ════════════════════╣
//  ║ [cpu gauge rows × 6]                    ║ [memory values]              ║
//  ╠══ Phase Progress ════════════════════════════════════════════════════════╣
//  ║ [progress bar line]                                                     ║
//  ║ [live stats line]                                                       ║
//  ╠══ Phase History ═════════════════════════════════════════════════════════╣
//  ║ [header]                                                                ║
//  ║ [history rows × histRows]                                               ║
//  ╚═════════════════════════════════════════════════════════════════════════╝
// ─────────────────────────────────────────────────────────────────────────────

const (
	dashW    = 118 // total line width
	leftW    = 58  // left panel inner width
	// rightW = dashW - leftW - 3 = 57
	chartH   = 4  // rows per time-series chart
	cpuBarW  = 22 // width of CPU gauge bar
	histRows = 6  // max history rows shown
)

func rightW() int { return dashW - leftW - 3 }

// ─────────────────────────────────────────────────────────────────────────────
// Ring buffer — 60 samples (1/sec)
// ─────────────────────────────────────────────────────────────────────────────

type ring struct {
	d    [60]float64
	head int
	n    int
}

func (r *ring) push(v float64) {
	r.d[r.head] = v
	r.head = (r.head + 1) % 60
	if r.n < 60 {
		r.n++
	}
}

func (r *ring) slice(width int) []float64 {
	cnt := r.n
	if cnt > width {
		cnt = width
	}
	if cnt == 0 {
		return nil
	}
	out := make([]float64, cnt)
	start := (r.head - cnt + 60) % 60
	for i := 0; i < cnt; i++ {
		out[i] = r.d[(start+i)%60]
	}
	return out
}

func (r *ring) maxVal() float64 {
	m := 0.0
	for i := 0; i < r.n; i++ {
		if r.d[i] > m {
			m = r.d[i]
		}
	}
	return m
}

// ─────────────────────────────────────────────────────────────────────────────
// Domain types
// ─────────────────────────────────────────────────────────────────────────────

type procInfo struct {
	name   string
	cpuPct float64 // −1 = N/A
	memMiB float64
}

type phaseRes struct {
	workers int
	tp      float64 // throughput tx/s
	p50     time.Duration
	p99     time.Duration
	ok      int64
	fail    int64
}

func (p *phaseRes) successPct() float64 {
	t := p.ok + p.fail
	if t == 0 {
		return 100
	}
	return 100.0 * float64(p.ok) / float64(t)
}

func (p *phaseRes) statusLabel() string {
	if p.successPct() < 80 {
		return "BREAKING"
	}
	if p.p99 > 10*time.Second {
		return "SLA BREACH"
	}
	return "OK"
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard
// ─────────────────────────────────────────────────────────────────────────────

type dashboard struct {
	mu sync.Mutex

	// Time-series (1 sample/sec)
	rpsRing ring
	p99Ring ring // milliseconds

	// Current phase metadata
	phaseIdx     int
	totalPhases  int
	phaseWorkers int
	phaseStart   time.Time
	phaseDur     time.Duration

	// Atomics written by worker goroutines
	curOK   atomic.Int64
	curFail atomic.Int64

	// Latencies for current phase (protected by latMu)
	latMu   sync.Mutex
	curLats []time.Duration

	// Last-sampled live stats (updated by rpsLoop goroutine)
	liveRPS float64
	liveP50 float64 // ms
	liveP99 float64 // ms
	lastOK  int64   // for delta calculation

	// Process info (updated every 3 s)
	procs []procInfo

	// Completed phase results
	history []*phaseRes

	testStart time.Time
	quit      chan struct{}
}

func newDashboard(totalPhases int) *dashboard {
	d := &dashboard{
		totalPhases: totalPhases,
		testStart:   time.Now(),
		quit:        make(chan struct{}),
	}
	for _, n := range []string{"spi", "dict", "str", "bacen", "psp-alpha", "psp-beta"} {
		d.procs = append(d.procs, procInfo{name: n, cpuPct: -1})
	}
	return d
}

func (d *dashboard) start() {
	// Restore cursor on Ctrl+C
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt)
	go func() {
		<-ch
		fmt.Print(aShow)
		os.Exit(0)
	}()

	fmt.Print(aHide + aClearSc)

	go d.rpsLoop()
	go d.procLoop()
	go d.renderLoop()
}

func (d *dashboard) stop() {
	close(d.quit)
	time.Sleep(60 * time.Millisecond) // allow final render
}

// rpsLoop samples throughput and p99 every second.
func (d *dashboard) rpsLoop() {
	for {
		select {
		case <-d.quit:
			return
		case <-time.After(time.Second):
		}

		newOK := d.curOK.Load()

		d.mu.Lock()
		delta := newOK - d.lastOK
		d.lastOK = newOK
		d.liveRPS = float64(delta)
		d.rpsRing.push(d.liveRPS)
		d.mu.Unlock()

		// Compute p50/p99 without holding the main lock
		d.latMu.Lock()
		if len(d.curLats) > 0 {
			lats := make([]time.Duration, len(d.curLats))
			copy(lats, d.curLats)
			d.latMu.Unlock()

			sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })
			n := len(lats)
			p50 := float64(lats[clamp(int(float64(n)*0.50), n)].Milliseconds())
			p99 := float64(lats[clamp(int(float64(n)*0.99), n)].Milliseconds())

			d.mu.Lock()
			d.liveP50 = p50
			d.liveP99 = p99
			d.p99Ring.push(p99)
			d.mu.Unlock()
		} else {
			d.latMu.Unlock()
		}
	}
}

// procLoop samples CPU % and memory every 3 seconds.
func (d *dashboard) procLoop() {
	d.sampleProcs()
	for {
		select {
		case <-d.quit:
			return
		case <-time.After(3 * time.Second):
		}
		d.sampleProcs()
	}
}

func (d *dashboard) sampleProcs() {
	cpu := sampleCPU()
	mem := sampleMemory()

	memMap := make(map[string]float64)
	for _, m := range mem {
		memMap[m.name] += m.mb
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	for i := range d.procs {
		n := d.procs[i].name
		if v, ok := cpu[n]; ok {
			d.procs[i].cpuPct = v
		}
		if v, ok := memMap[n]; ok {
			d.procs[i].memMiB = v
		}
	}
}

func (d *dashboard) renderLoop() {
	for {
		select {
		case <-d.quit:
			d.render() // final render
			return
		case <-time.After(250 * time.Millisecond):
			d.render()
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Render — builds full-screen buffer and writes it in one print call
// ─────────────────────────────────────────────────────────────────────────────

func (d *dashboard) render() {
	// Snapshot all state under lock
	d.mu.Lock()
	rpsR := d.rpsRing
	p99R := d.p99Ring
	phIdx := d.phaseIdx
	totPh := d.totalPhases
	phW := d.phaseWorkers
	phStart := d.phaseStart
	phDur := d.phaseDur
	curOK := d.curOK.Load()
	curFail := d.curFail.Load()
	lRPS := d.liveRPS
	lP50 := d.liveP50
	lP99 := d.liveP99
	procs := append([]procInfo{}, d.procs...)
	hist := append([]*phaseRes{}, d.history...)
	tStart := d.testStart
	d.mu.Unlock()

	var sb strings.Builder

	// ── Header ──────────────────────────────────────────────────────────────
	elapsed := time.Since(tStart)
	eStr := fmt.Sprintf("%02d:%02d", int(elapsed.Minutes()), int(elapsed.Seconds())%60)
	phInfo := fmt.Sprintf(" Phase %d/%d · %d workers · %s elapsed",
		phIdx+1, totPh, phW, eStr)

	sb.WriteString(boxTop("Nerve PIX — Stress Test", dashW))
	sb.WriteByte('\n')
	sb.WriteString(boxMid(aBold+phInfo+aReset, dashW))
	sb.WriteByte('\n')

	// ── Time-series charts ───────────────────────────────────────────────────
	rw := rightW()
	chartWL := leftW - 9  // 1 space + 8 y-label
	chartWR := rw - 9

	rpsVals := rpsR.slice(chartWL)
	p99Vals := p99R.slice(chartWR)
	rpsMax := rpsR.maxVal()
	p99Max := p99R.maxVal()
	if rpsMax == 0 {
		rpsMax = 1
	}
	if p99Max == 0 {
		p99Max = 1
	}

	rpsRows := makeChart(rpsVals, rpsMax, chartWL, chartH)
	p99Rows := makeChart(p99Vals, p99Max, chartWR, chartH)
	rpsLbls := yLabels(rpsMax, chartH, "tx/s")
	p99Lbls := yLabels(p99Max, chartH, "ms")

	sb.WriteString(boxSep2("Requests/s", "Latency p99", dashW, leftW))
	sb.WriteByte('\n')

	for r := 0; r < chartH; r++ {
		lc := fmt.Sprintf(" %s%s%s%s", rpsLbls[r], aGreen, padR(rpsRows[r], chartWL), aReset)
		rc := fmt.Sprintf(" %s%s%s%s", p99Lbls[r], aYellow, padR(p99Rows[r], chartWR), aReset)
		sb.WriteString(box2Col(lc, rc, dashW, leftW))
		sb.WriteByte('\n')
	}
	// Chart footer: max + last value
	sb.WriteString(box2Col(
		fmt.Sprintf(" %smax:%.0f  last:%.1f tx/s%s", aDim, rpsMax, lRPS, aReset),
		fmt.Sprintf(" %smax:%.0f  last:%.0fms%s", aDim, p99Max, lP99, aReset),
		dashW, leftW,
	))
	sb.WriteByte('\n')

	// ── CPU % + Memory ──────────────────────────────────────────────────────
	sb.WriteString(boxSep2("CPU %", "Memory", dashW, leftW))
	sb.WriteByte('\n')

	for _, p := range procs {
		var cpuCol string
		if p.cpuPct < 0 {
			cpuCol = fmt.Sprintf(" %-9s [%s]  N/A  ", p.name, strings.Repeat("·", cpuBarW))
		} else {
			c := aGreen
			if p.cpuPct > 70 {
				c = aBRed
			} else if p.cpuPct > 40 {
				c = aBYellow
			}
			bar := gaugeBar(p.cpuPct, cpuBarW, c)
			cpuCol = fmt.Sprintf(" %-9s [%s] %5.1f%%", p.name, bar, p.cpuPct)
		}

		var memCol string
		if p.memMiB > 0 {
			memCol = fmt.Sprintf(" %-9s  %6.1f MiB", p.name, p.memMiB)
		} else {
			memCol = fmt.Sprintf(" %-9s     --- MiB", p.name)
		}

		sb.WriteString(box2Col(cpuCol, memCol, dashW, leftW))
		sb.WriteByte('\n')
	}

	// ── Phase progress ───────────────────────────────────────────────────────
	sb.WriteString(boxSepFull("Phase Progress", dashW))
	sb.WriteByte('\n')

	phElapsed := time.Since(phStart)
	pct := 0.0
	if phDur > 0 {
		pct = phElapsed.Seconds() / phDur.Seconds()
	}
	if pct > 1 {
		pct = 1
	}

	bar := progressBar(pct, 46)
	progLine := fmt.Sprintf(" Phase %d/%d · %dw  [%s]  %.1fs / %.1fs",
		phIdx+1, totPh, phW, bar,
		phElapsed.Seconds(), phDur.Seconds())
	sb.WriteString(boxMid(progLine, dashW))
	sb.WriteByte('\n')

	// Live stats line
	total := curOK + curFail
	var okPct float64
	if total > 0 {
		okPct = 100.0 * float64(curOK) / float64(total)
	}
	okC := aBGreen
	if okPct < 90 {
		okC = aBRed
	} else if okPct < 99 {
		okC = aBYellow
	}
	stats := fmt.Sprintf(
		" OK: %s%d%s  FAIL: %d  Success: %s%.1f%%%s  RPS: %.1f  p50: %.0fms  p99: %.0fms",
		aBGreen, curOK, aReset,
		curFail,
		okC, okPct, aReset,
		lRPS, lP50, lP99,
	)
	sb.WriteString(boxMid(stats, dashW))
	sb.WriteByte('\n')

	// ── Phase history ────────────────────────────────────────────────────────
	sb.WriteString(boxSepFull("Phase History", dashW))
	sb.WriteByte('\n')

	hdr := fmt.Sprintf("  %-4s %-8s %-9s %-8s %-8s %-7s %-7s %-6s  Status",
		"#", "Workers", "tx/s", "p50", "p99", "OK", "FAIL", "ok%")
	sb.WriteString(boxMid(aDim+hdr+aReset, dashW))
	sb.WriteByte('\n')

	shown := hist
	if len(shown) > histRows {
		shown = shown[len(shown)-histRows:]
	}
	for i, h := range shown {
		label := h.statusLabel()
		sc := aBGreen
		switch label {
		case "BREAKING":
			sc = aBRed
		case "SLA BREACH":
			sc = aBYellow
		}
		row := fmt.Sprintf("  %-4d %-8d %-9.1f %-8s %-8s %-7d %-7d %5.0f%%  %s%s%s",
			len(hist)-len(shown)+i+1,
			h.workers, h.tp,
			fmtDur(h.p50), fmtDur(h.p99),
			h.ok, h.fail, h.successPct(),
			sc, label, aReset,
		)
		sb.WriteString(boxMid(row, dashW))
		sb.WriteByte('\n')
	}
	// Pad remaining history slots
	for i := len(shown); i < histRows; i++ {
		sb.WriteString(boxMid("", dashW))
		sb.WriteByte('\n')
	}

	sb.WriteString(boxBot(dashW))
	sb.WriteByte('\n')

	fmt.Print(aHome + sb.String())
}

// ─────────────────────────────────────────────────────────────────────────────
// Box-drawing helpers
// ─────────────────────────────────────────────────────────────────────────────

// boxTop: ╔══ Title ═══════════════╗
func boxTop(title string, w int) string {
	fill := w - 6 - visLen(title)
	if fill < 0 {
		fill = 0
	}
	return "╔══ " + aBold + title + aReset + " " + strings.Repeat("═", fill) + "╗"
}

// boxBot: ╚══════════════════════════╝
func boxBot(w int) string {
	return "╚" + strings.Repeat("═", w-2) + "╝"
}

// boxMid: ║ content (padded) ║
func boxMid(content string, w int) string {
	pad := w - 2 - visLen(content)
	if pad < 0 {
		pad = 0
	}
	return "║" + content + strings.Repeat(" ", pad) + "║"
}

// boxSep2: ╠══ Left ══════╦══ Right ══════╣
func boxSep2(left, right string, w, lw int) string {
	lp := "══ " + left + " "
	rp := "══ " + right + " "
	lf := lw - len(lp)
	rf := w - lw - 3 - len(rp)
	if lf < 0 {
		lf = 0
	}
	if rf < 0 {
		rf = 0
	}
	return "╠" + lp + strings.Repeat("═", lf) + "╦" + rp + strings.Repeat("═", rf) + "╣"
}

// boxSepFull: ╠══ Title ═════════════════════════╣
func boxSepFull(title string, w int) string {
	part := "══ " + title + " "
	fill := w - 2 - len(part)
	if fill < 0 {
		fill = 0
	}
	return "╠" + part + strings.Repeat("═", fill) + "╣"
}

// box2Col: ║ left (padded to lw) ║ right (padded to rw) ║
func box2Col(left, right string, w, lw int) string {
	rw := w - lw - 3
	lpad := lw - visLen(left)
	rpad := rw - visLen(right)
	if lpad < 0 {
		lpad = 0
	}
	if rpad < 0 {
		rpad = 0
	}
	return "║" + left + strings.Repeat(" ", lpad) + "║" + right + strings.Repeat(" ", rpad) + "║"
}

// visLen counts display-width of a string, stripping ANSI escape codes.
func visLen(s string) int {
	n := 0
	esc := false
	for _, r := range s {
		if esc {
			if r == 'm' {
				esc = false
			}
			continue
		}
		if r == '\033' {
			esc = true
			continue
		}
		n++
	}
	return n
}

// padR pads s with spaces on the right to exactly n display chars.
func padR(s string, n int) string {
	l := len(s)
	if l >= n {
		return s[:n]
	}
	return s + strings.Repeat(" ", n-l)
}

// ─────────────────────────────────────────────────────────────────────────────
// Chart helpers
// ─────────────────────────────────────────────────────────────────────────────

var blockChars = []rune{' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

// makeChart returns height rows of width-wide bar chart using Unicode block chars.
func makeChart(vals []float64, maxV float64, width, height int) []string {
	if maxV <= 0 {
		maxV = 1
	}
	// Pad with leading zeros so chart fills full width
	padded := make([]float64, width)
	if len(vals) <= width {
		copy(padded[width-len(vals):], vals)
	} else {
		copy(padded, vals[len(vals)-width:])
	}

	bandH := maxV / float64(height)
	rows := make([]string, height)
	for r := 0; r < height; r++ {
		// Row 0 = top (highest values), row height-1 = bottom (lowest values)
		bandMin := maxV - float64(r+1)*bandH
		bandMax := bandMin + bandH
		var sb strings.Builder
		for _, v := range padded {
			switch {
			case v >= bandMax:
				sb.WriteRune('█')
			case v <= bandMin:
				sb.WriteRune(' ')
			default:
				frac := (v - bandMin) / bandH
				idx := int(frac * 8)
				if idx >= 8 {
					idx = 7
				}
				sb.WriteRune(blockChars[idx])
			}
		}
		rows[r] = sb.String()
	}
	return rows
}

// yLabels returns height y-axis labels, each exactly 8 chars wide.
func yLabels(maxV float64, height int, unit string) []string {
	lbl := make([]string, height)
	for r := 0; r < height; r++ {
		if r == 0 {
			lbl[r] = yLabelStr(maxV, unit)
		} else if r == height-1 {
			lbl[r] = yLabelStr(0, unit)
		} else {
			lbl[r] = "        " // 8 spaces
		}
	}
	return lbl
}

// yLabelStr formats a y-axis label into exactly 8 chars ("NNNNUUU ").
func yLabelStr(val float64, unit string) string {
	var num string
	if val >= 10000 {
		num = fmt.Sprintf("%.1fK", val/1000)
	} else {
		num = fmt.Sprintf("%.0f", val)
	}
	s := num + unit
	if len(s) > 7 {
		s = s[:7]
	}
	return fmt.Sprintf("%7s ", s) // right-align in 7 + 1 space = 8
}

// gaugeBar creates "color+filled░░░░reset" of total width chars.
func gaugeBar(pct float64, width int, color string) string {
	filled := int(pct / 100.0 * float64(width))
	if filled > width {
		filled = width
	}
	if filled < 0 {
		filled = 0
	}
	return color + strings.Repeat("█", filled) + aDim + strings.Repeat("░", width-filled) + aReset
}

// progressBar creates a green/dim bar for a fraction in [0, 1].
func progressBar(frac float64, width int) string {
	return gaugeBar(frac*100, width, aGreen)
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase runner
// ─────────────────────────────────────────────────────────────────────────────

var idSeq atomic.Int64

func (d *dashboard) runPhase(phaseIdx, workers int, dur time.Duration, spiURL string, amount int) *phaseRes {
	// Update dashboard metadata
	d.mu.Lock()
	d.phaseIdx = phaseIdx
	d.phaseWorkers = workers
	d.phaseStart = time.Now()
	d.phaseDur = dur
	d.lastOK = 0
	d.liveRPS = 0
	d.liveP50 = 0
	d.liveP99 = 0
	d.mu.Unlock()

	// Reset atomics and latency slice
	d.curOK.Store(0)
	d.curFail.Store(0)
	d.latMu.Lock()
	d.curLats = d.curLats[:0]
	d.latMu.Unlock()

	// Launch worker goroutines
	done := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-done:
					return
				default:
				}
				seq := idSeq.Add(1)
				t := time.Now()
				ok := sendPIX(spiURL, seq, amount)
				lat := time.Since(t)

				if ok {
					d.curOK.Add(1)
				} else {
					d.curFail.Add(1)
				}
				d.latMu.Lock()
				d.curLats = append(d.curLats, lat)
				d.latMu.Unlock()
			}
		}()
	}

	time.Sleep(dur)
	close(done)
	wg.Wait()

	// Compute phase result
	finalOK := d.curOK.Load()
	finalFail := d.curFail.Load()

	d.latMu.Lock()
	lats := make([]time.Duration, len(d.curLats))
	copy(lats, d.curLats)
	d.latMu.Unlock()

	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })
	n := len(lats)

	res := &phaseRes{
		workers: workers,
		ok:      finalOK,
		fail:    finalFail,
	}
	if dur > 0 {
		res.tp = float64(finalOK+finalFail) / dur.Seconds()
	}
	if n > 0 {
		res.p50 = lats[clamp(int(float64(n)*0.50), n)]
		res.p99 = lats[clamp(int(float64(n)*0.99), n)]
	}

	d.mu.Lock()
	d.history = append(d.history, res)
	d.mu.Unlock()

	return res
}

// ─────────────────────────────────────────────────────────────────────────────
// PIX request
// ─────────────────────────────────────────────────────────────────────────────

var httpClient = &http.Client{
	Timeout: 20 * time.Second,
	Transport: &http.Transport{
		MaxIdleConnsPerHost: 512,
		MaxConnsPerHost:     512,
		IdleConnTimeout:     60 * time.Second,
	},
}

func sendPIX(spiURL string, seq int64, amountCentavos int) bool {
	idemKey := fmt.Sprintf("stress-%d", seq)
	body := fmt.Sprintf(
		`{"idempotency_key":%q,"payer_key":"alice@psp-alpha.com","payee_key":"bob@psp-beta.com","amount_centavos":%d,"description":"stress"}`,
		idemKey, amountCentavos,
	)
	resp, err := httpClient.Post(spiURL+"/pix/initiate", "application/json",
		bytes.NewBufferString(body))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
	return resp.StatusCode == 200
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

func main() {
	flagDuration := flag.Duration("duration", 30*time.Second, "total test duration")
	flagStep     := flag.Duration("step", 5*time.Second, "duration per phase")
	flagRamp     := flag.String("ramp", "2,5,10,20,40,80", "comma-separated worker counts")
	flagAmount   := flag.Int("amount", 100, "PIX amount in centavos")
	flagSPI      := flag.String("spi", "http://127.0.0.1:8080", "SPI base URL")
	flagAlpha    := flag.String("alpha", "http://127.0.0.1:9080", "PSP-alpha base URL")
	flagBeta     := flag.String("beta", "http://127.0.0.1:9090", "PSP-beta base URL")
	flagSTR      := flag.String("str", "http://127.0.0.1:8082", "STR base URL")
	flagDICT     := flag.String("dict", "http://127.0.0.1:8081", "DICT base URL")
	flagNoSeed   := flag.Bool("no-seed", false, "skip seeding")
	flag.Parse()

	ramp := parseRamp(*flagRamp)
	if len(ramp) == 0 {
		fmt.Fprintln(os.Stderr, "error: -ramp must be a non-empty comma-separated list of positive integers")
		os.Exit(1)
	}

	stepDur := *flagStep
	totalDur := *flagDuration
	maxPhases := int(totalDur / stepDur)
	if maxPhases > len(ramp) {
		maxPhases = len(ramp)
	}

	// ── Seed (before dashboard starts, output can scroll normally) ────────────
	if !*flagNoSeed {
		fmt.Println("Seeding services...")
		balance := int64(200) * int64(*flagDuration/time.Second) * int64(*flagAmount) * 4
		if balance < 50_000_000 {
			balance = 50_000_000
		}
		var errs []string
		if err := seedSTR(*flagSTR, "psp-alpha", balance); err != nil {
			errs = append(errs, "STR:"+err.Error())
		}
		if err := seedAlpha(*flagAlpha, balance); err != nil {
			errs = append(errs, "alpha:"+err.Error())
		}
		if err := seedBeta(*flagBeta); err != nil {
			errs = append(errs, "beta:"+err.Error())
		}
		if err := seedDICT(*flagDICT); err != nil {
			errs = append(errs, "DICT:"+err.Error())
		}
		if len(errs) > 0 {
			fmt.Printf("Seed partial: %s\n", strings.Join(errs, "; "))
		} else {
			fmt.Printf("Seed OK (STR balance: R$ %.2f)\n", float64(balance)/100)
		}
		fmt.Println()
	}

	// ── Dashboard ─────────────────────────────────────────────────────────────
	d := newDashboard(maxPhases)
	d.start()
	defer fmt.Print(aShow) // always restore cursor

	// ── Run phases ────────────────────────────────────────────────────────────
	totalStart := time.Now()
	breakingAt := -1

	for i := 0; i < maxPhases; i++ {
		remaining := totalDur - time.Since(totalStart)
		if remaining < 500*time.Millisecond {
			break
		}
		dur := stepDur
		if dur > remaining {
			dur = remaining
		}

		res := d.runPhase(i, ramp[i], dur, *flagSPI, *flagAmount)

		if res.successPct() < 80 && breakingAt < 0 {
			breakingAt = i
		}
	}

	d.stop()

	// ── Final summary (normal scrolling output) ───────────────────────────────
	fmt.Print(aShow + aClearSc + aHome)
	printFinalSummary(d.history, ramp, breakingAt)
}

// ─────────────────────────────────────────────────────────────────────────────
// Final summary (shown after dashboard exits)
// ─────────────────────────────────────────────────────────────────────────────

func printFinalSummary(history []*phaseRes, ramp []int, breakingAt int) {
	sep := "  " + strings.Repeat("═", 58)
	fmt.Println()
	fmt.Println(sep)
	fmt.Println("  STRESS TEST RESULTS")
	fmt.Println(sep)
	fmt.Println()

	// Phase table
	fmt.Printf("  %-4s %-8s %-9s %-8s %-8s %-7s %-7s %-6s  Status\n",
		"#", "Workers", "tx/s", "p50", "p99", "OK", "FAIL", "ok%")
	fmt.Println("  " + strings.Repeat("─", 76))
	for i, h := range history {
		fmt.Printf("  %-4d %-8d %-9.1f %-8s %-8s %-7d %-7d %5.0f%%  %s\n",
			i+1, h.workers, h.tp,
			fmtDur(h.p50), fmtDur(h.p99),
			h.ok, h.fail, h.successPct(), h.statusLabel())
	}
	fmt.Println()

	// Throughput chart
	maxTP := 0.0
	for _, h := range history {
		if h.tp > maxTP {
			maxTP = h.tp
		}
	}
	if maxTP > 0 {
		fmt.Println("  Throughput (tx/s) per concurrency level:")
		fmt.Println()
		for i, h := range history {
			blen := int(h.tp / maxTP * 40)
			bar := strings.Repeat("█", blen) + strings.Repeat("░", 40-blen)
			marker := ""
			if h.statusLabel() == "BREAKING" {
				marker = "  ✗ BREAKING"
			} else if i > 0 && h.tp < history[i-1].tp*0.95 {
				marker = "  ▼ declining"
			}
			fmt.Printf("  %4dw │%s %6.1f tx/s%s\n", ramp[i], bar, h.tp, marker)
		}
		fmt.Println()
	}

	// Peak + breaking point
	peakIdx := 0
	for i, h := range history {
		if h.tp > history[peakIdx].tp {
			peakIdx = i
		}
	}
	peak := history[peakIdx]
	fmt.Printf("  Peak throughput : %.1f tx/s @ %d workers (phase %d)\n",
		peak.tp, ramp[peakIdx], peakIdx+1)
	fmt.Printf("  Peak p50 / p99  : %s / %s\n", fmtDur(peak.p50), fmtDur(peak.p99))
	fmt.Println()

	if breakingAt >= 0 {
		h := history[breakingAt]
		fmt.Printf("  Breaking point  : %d workers (phase %d) — %.0f%% success\n",
			ramp[breakingAt], breakingAt+1, h.successPct())
		if breakingAt > 0 {
			safe := history[breakingAt-1]
			fmt.Printf("  Safe ceiling    : %d workers — %.1f tx/s, p99=%s\n",
				ramp[breakingAt-1], safe.tp, fmtDur(safe.p99))
		}
	} else {
		last := history[len(history)-1]
		fmt.Printf("  Ceiling not reached. Last phase: %d workers, %.1f tx/s, p99=%s\n",
			ramp[len(history)-1], last.tp, fmtDur(last.p99))
		fmt.Println("  Try: -ramp 2,5,10,20,40,80,150,300 to push further.")
	}
	fmt.Println()

	// BCB SLA check
	bcbOK := true
	for _, h := range history {
		if h.p99 > 10*time.Second {
			bcbOK = false
			break
		}
	}
	if bcbOK {
		fmt.Println("  BCB SLA (p99 ≤ 10s) : ✓ met across all phases")
	} else {
		for i, h := range history {
			if h.p99 > 10*time.Second {
				fmt.Printf("  BCB SLA (p99 ≤ 10s) : ✗ breached at %d workers (p99=%s)\n",
					ramp[i], fmtDur(h.p99))
				break
			}
		}
	}
	fmt.Println()
}

// ─────────────────────────────────────────────────────────────────────────────
// Seed helpers (same as bench/main.go)
// ─────────────────────────────────────────────────────────────────────────────

func seedSTR(strURL, pspID string, balanceCentavos int64) error {
	data, _ := json.Marshal(map[string]interface{}{
		"psp_id":           pspID,
		"balance_centavos": balanceCentavos,
	})
	resp, err := httpClient.Post(strURL+"/admin/seed", "application/json", bytes.NewReader(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func seedAlpha(alphaURL string, balanceCentavos int64) error {
	data, _ := json.Marshal(map[string]interface{}{
		"account_id":       "alice-local-001",
		"pix_key":          "alice@psp-alpha.com",
		"balance_centavos": balanceCentavos,
	})
	resp, err := httpClient.Post(alphaURL+"/admin/seed", "application/json", bytes.NewReader(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func seedBeta(betaURL string) error {
	data, _ := json.Marshal(map[string]interface{}{
		"account_id":       "bob-local-001",
		"pix_key":          "bob@psp-beta.com",
		"balance_centavos": 0,
	})
	resp, err := httpClient.Post(betaURL+"/admin/seed", "application/json", bytes.NewReader(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func seedDICT(dictURL string) error {
	type u struct{ name, doc, pspID, key string }
	users := []u{
		{"Alice", "11122233344", "psp-alpha", "alice@psp-alpha.com"},
		{"Bob", "22233344455", "psp-beta", "bob@psp-beta.com"},
	}
	for _, usr := range users {
		resp, err := httpClient.Get(dictURL + "/key/" + usr.key)
		if err != nil {
			return fmt.Errorf("DICT GET /key/%s: %w", usr.key, err)
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
		if resp.StatusCode == 200 {
			continue // already exists
		}

		data, _ := json.Marshal(map[string]interface{}{
			"document": usr.doc, "name": usr.name, "psp_id": usr.pspID,
		})
		resp, err = httpClient.Post(dictURL+"/user", "application/json", bytes.NewReader(data))
		if err != nil {
			return err
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		var userResp struct{ UserID string `json:"user_id"` }
		json.Unmarshal(body, &userResp) //nolint:errcheck

		data, _ = json.Marshal(map[string]interface{}{
			"user_id": userResp.UserID, "psp_id": usr.pspID,
			"bank_ispb": "00000000", "agency": "0001",
			"account_number": "000001", "account_type": "corrente",
		})
		resp, err = httpClient.Post(dictURL+"/account", "application/json", bytes.NewReader(data))
		if err != nil {
			return err
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		var accResp struct{ AccountID string `json:"account_id"` }
		json.Unmarshal(body, &accResp) //nolint:errcheck

		data, _ = json.Marshal(map[string]interface{}{
			"account_id": accResp.AccountID, "key_type": "EMAIL", "key_value": usr.key,
		})
		resp, err = httpClient.Post(dictURL+"/key", "application/json", bytes.NewReader(data))
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
	}
	return nil
}

// ─────────────────────────────────────────────────────────────────────────────
// CPU sampling (Windows — typeperf)
// ─────────────────────────────────────────────────────────────────────────────

var nerveProcNames = []string{"spi", "dict", "str", "bacen", "psp-alpha", "psp-beta"}

// sampleCPU returns CPU % per process name using typeperf on Windows.
// Values are in [0, 100] (capped). Returns −1 for unavailable processes.
func sampleCPU() map[string]float64 {
	result := make(map[string]float64, len(nerveProcNames))
	for _, n := range nerveProcNames {
		result[n] = -1
	}
	if runtime.GOOS != "windows" {
		return result
	}

	args := []string{"-sc", "1"}
	for _, n := range nerveProcNames {
		args = append(args, fmt.Sprintf(`\Process(%s)\%% Processor Time`, n))
	}

	out, err := exec.Command("typeperf", args...).Output()
	if err != nil {
		return result
	}

	r := csv.NewReader(strings.NewReader(string(out)))
	r.FieldsPerRecord = -1
	records, err := r.ReadAll()
	if err != nil {
		return result
	}

	// Find the first data line (not the PDH header)
	for _, rec := range records {
		if len(rec) < 2 || strings.HasPrefix(rec[0], "(PDH") {
			continue
		}
		for i, n := range nerveProcNames {
			if i+1 >= len(rec) {
				break
			}
			v, err := strconv.ParseFloat(strings.TrimSpace(rec[i+1]), 64)
			if err != nil || v < 0 {
				continue
			}
			if v > 100 {
				v = 100 // cap at 100%
			}
			result[n] = v
		}
		break
	}
	return result
}

// ─────────────────────────────────────────────────────────────────────────────
// Memory sampling (Windows — tasklist)
// ─────────────────────────────────────────────────────────────────────────────

type procMem struct {
	name string
	mb   float64
}

var nerveExes = map[string]bool{
	"spi.exe": true, "dict.exe": true, "str.exe": true,
	"bacen.exe": true, "psp-alpha.exe": true, "psp-beta.exe": true,
}

func sampleMemory() []procMem {
	if runtime.GOOS != "windows" {
		return nil
	}
	out, err := exec.Command("tasklist", "/FO", "CSV", "/NH").Output()
	if err != nil {
		return nil
	}
	var result []procMem
	for _, line := range strings.Split(string(out), "\n") {
		fields := csvSplit(strings.TrimRight(line, "\r\n"))
		if len(fields) < 5 {
			continue
		}
		lower := strings.ToLower(fields[0])
		if !nerveExes[lower] {
			continue
		}
		memStr := strings.ReplaceAll(fields[4], " K", "")
		memStr = strings.ReplaceAll(memStr, ",", "")
		memStr = strings.ReplaceAll(memStr, ".", "")
		var kb int
		fmt.Sscanf(strings.TrimSpace(memStr), "%d", &kb)
		result = append(result, procMem{
			name: strings.TrimSuffix(lower, ".exe"),
			mb:   float64(kb) / 1024,
		})
	}
	return result
}

func csvSplit(line string) []string {
	parts := strings.Split(line, "\",\"")
	for i, p := range parts {
		parts[i] = strings.Trim(p, "\"")
	}
	return parts
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatting helpers
// ─────────────────────────────────────────────────────────────────────────────

func fmtDur(d time.Duration) string {
	ms := float64(d.Milliseconds())
	if ms >= 10000 {
		return fmt.Sprintf("%.1fs", ms/1000)
	}
	if ms >= 1000 {
		return fmt.Sprintf("%.2fs", ms/1000)
	}
	return fmt.Sprintf("%.0fms", ms)
}

func parseRamp(s string) []int {
	parts := strings.Split(s, ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil || n <= 0 {
			return nil
		}
		out = append(out, n)
	}
	return out
}

func clamp(i, n int) int {
	if i >= n {
		return n - 1
	}
	if i < 0 {
		return 0
	}
	return i
}
