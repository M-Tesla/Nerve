// bench — Nerve PIX load tester
//
// Measures p50/p99 latency of end-to-end PIX payments:
//   Alice (PSP-alpha) → SPI → DICT → STR → PSP-beta (Bob)
//
// Brazilian Central Bank SLA:
//   p50 ≤ 5,000ms  |  p99 ≤ 10,000ms
//
// Usage:
//   go run .                           (1,000 txs, 20 workers, R$1.00 each)
//   go run . -n 5000 -c 50             (5,000 txs, 50 workers)
//   go run . -n 500  -c 10 -no-seed    (skip seed, use current state)
//   go build -o bench.exe . && bench.exe -n 2000 -c 30

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// HTTP client — generous connection pool for high load
// ---------------------------------------------------------------------------

var httpClient = &http.Client{
	Timeout: 30 * time.Second,
	Transport: &http.Transport{
		MaxIdleConnsPerHost: 256,
		MaxConnsPerHost:     256,
		IdleConnTimeout:     60 * time.Second,
	},
}

// ---------------------------------------------------------------------------
// Result of a transaction
// ---------------------------------------------------------------------------

type txResult struct {
	latency time.Duration
	status  string // "SETTLED" | "FAILED" | "INSUFFICIENT_BALANCE" | "NETWORK_ERROR" | ...
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	nFlag    := flag.Int("n",      1000,                      "number of transactions")
	cFlag    := flag.Int("c",      20,                        "concurrent workers")
	amtFlag  := flag.Int("amount", 100,                       "value per TX in centavos (100 = R$1.00)")
	alphaURL := flag.String("alpha", "http://127.0.0.1:9080", "PSP-alpha URL")
	betaURL  := flag.String("beta",  "http://127.0.0.1:9090", "PSP-beta URL")
	strURL   := flag.String("str",   "http://127.0.0.1:8082", "STR URL")
	dictURL  := flag.String("dict",  "http://127.0.0.1:8081", "DICT URL")
	noSeed   := flag.Bool("no-seed", false,                   "skip seed (use existing balances)")
	flag.Parse()

	n   := *nFlag
	c   := *cFlag
	amt := *amtFlag

	banner()
	fmt.Printf("  Transactions:  %d\n", n)
	fmt.Printf("  Concurrency:   %d workers\n", c)
	fmt.Printf("  Value/TX:      R$ %.2f\n", float64(amt)/100)
	fmt.Printf("  PSP-alpha:     %s\n", *alphaURL)
	fmt.Println()

	// ── Seed ──────────────────────────────────────────────────────────────────
	if !*noSeed {
		fmt.Println(">>> Preparing test data...")
		reserve := int64(n)*int64(amt)*2 + 1_000_000 // generous margin

		if err := seedSTR(*strURL, "psp-alpha", reserve); err != nil {
			fmt.Printf("    ! STR seed failed (can continue): %v\n", err)
		} else {
			fmt.Printf("    ✓ STR psp-alpha reserve: R$ %.2f\n", float64(reserve)/100)
		}

		if err := seedAlpha(*alphaURL, reserve); err != nil {
			fmt.Printf("    ! PSP-alpha seed failed (can continue): %v\n", err)
		} else {
			fmt.Printf("    ✓ Alice balance: R$ %.2f\n", float64(reserve)/100)
		}

		// PSP-beta: Bob account is in-memory — needs to be recreated on each restart
		if err := seedBeta(*betaURL); err != nil {
			fmt.Printf("    ! PSP-beta seed failed (can continue): %v\n", err)
		} else {
			fmt.Printf("    ✓ Bob (psp-beta): account ready\n")
		}

		if err := seedDICT(*dictURL); err != nil {
			fmt.Printf("    ! DICT seed failed: %v\n", err)
		} else {
			fmt.Printf("    ✓ DICT: alice@psp-alpha.com and bob@psp-beta.com registered\n")
		}
		fmt.Println()
	}

	// ── Memory snapshot — before ────────────────────────────────────────────
	memSnap := sampleMemory()

	// ── Execution ──────────────────────────────────────────────────────────
	fmt.Println(">>> Running benchmark...")

	jobs    := make(chan int, n)
	results := make([]txResult, n)
	var done int64

	for i := 0; i < n; i++ {
		jobs <- i
	}
	close(jobs)

	runID    := time.Now().UnixNano()
	runStart := time.Now()

	// Progress bar
	progDone := make(chan struct{})
	go func() {
		defer close(progDone)
		for {
			cur := atomic.LoadInt64(&done)
			pct := int(cur * 40 / int64(n))
			bar := strings.Repeat("█", pct) + strings.Repeat("░", 40-pct)
			ela := time.Since(runStart).Truncate(time.Millisecond)
			fmt.Printf("\r    [%s] %5d/%-5d  %s", bar, cur, n, ela)
			if cur >= int64(n) {
				break
			}
			time.Sleep(80 * time.Millisecond)
		}
	}()

	// Workers
	var wg sync.WaitGroup
	for i := 0; i < c; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range jobs {
				key := fmt.Sprintf("bench-%d-%d", runID, idx)
				r   := sendPayment(*alphaURL, key, amt)
				results[idx] = r
				atomic.AddInt64(&done, 1)
			}
		}()
	}
	wg.Wait()

	totalDur := time.Since(runStart)

	// Wait for progress bar to close
	time.Sleep(100 * time.Millisecond)
	<-progDone
	fmt.Printf("\r    [████████████████████████████████████████] %5d/%-5d  %s\n",
		n, n, totalDur.Truncate(time.Millisecond))
	fmt.Println()

	// ── Statistics ──────────────────────────────────────────────────────────
	var settled, failed, netErr int
	latencies := make([]float64, 0, n)
	statusCounts := map[string]int{}

	for _, r := range results {
		statusCounts[r.status]++
		switch r.status {
		case "SETTLED":
			settled++
			latencies = append(latencies, float64(r.latency.Milliseconds()))
		case "NETWORK_ERROR":
			netErr++
		default:
			failed++
			latencies = append(latencies, float64(r.latency.Milliseconds()))
		}
	}
	sort.Float64s(latencies)

	// ── Report ─────────────────────────────────────────────────────────────
	sep := "  " + strings.Repeat("═", 54)
	fmt.Println(sep)
	fmt.Println("  BENCHMARK RESULTS")
	fmt.Println(sep)
	fmt.Println()

	throughput := float64(n) / totalDur.Seconds()
	fmt.Printf("  Total duration:    %s\n", totalDur.Truncate(time.Millisecond))
	fmt.Printf("  Throughput:        %.1f tx/s\n", throughput)
	fmt.Println()
	fmt.Printf("  ✓  Settled:        %d (%.1f%%)\n", settled, pct(settled, n))
	fmt.Printf("  ✗  Failed:         %d (%.1f%%)\n", failed, pct(failed, n))
	if netErr > 0 {
		fmt.Printf("  ⚠  Network error:  %d (%.1f%%)\n", netErr, pct(netErr, n))
	}

	// Detail failure causes if any
	if failed > 0 {
		fmt.Println()
		fmt.Println("  Failure causes:")
		for status, count := range statusCounts {
			if status != "SETTLED" && status != "NETWORK_ERROR" {
				fmt.Printf("    %-30s %d\n", status, count)
			}
		}
	}

	fmt.Println()

	if len(latencies) > 0 {
		pMin := latencies[0]
		p50  := percentile(latencies, 50)
		p75  := percentile(latencies, 75)
		p90  := percentile(latencies, 90)
		p99  := percentile(latencies, 99)
		p999 := percentile(latencies, 99.9)
		pMax := latencies[len(latencies)-1]

		fmt.Println("  End-to-end latency (PSP-alpha → SPI → DICT → STR → PSP-beta):")
		fmt.Println()
		fmt.Printf("  %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n",
			"min", "p50", "p75", "p90", "p99", "p99.9", "max")
		fmt.Printf("  %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n",
			fmtMs(pMin), fmtMs(p50), fmtMs(p75), fmtMs(p90),
			fmtMs(p99), fmtMs(p999), fmtMs(pMax))
		fmt.Println()

		// Latency distribution histogram
		fmt.Println("  Latency distribution:")
		printHistogram(latencies)
		fmt.Println()

		// SLA check
		fmt.Println("  SLA — Brazilian Central Bank:")
		fmt.Printf("  p50  ≤  5,000ms:   %s  %s\n", slaCheck(p50, 5000), fmtMs(p50))
		fmt.Printf("  p99  ≤ 10,000ms:   %s  %s\n", slaCheck(p99, 10000), fmtMs(p99))
		fmt.Println()
	}

	// ── Process memory ─────────────────────────────────────────────────────
	fmt.Println("  Nerve service memory usage:")
	printMem(memSnap)
	fmt.Println()

	fmt.Println(sep)
	fmt.Println()
}

// ---------------------------------------------------------------------------
// HTTP calls
// ---------------------------------------------------------------------------

func sendPayment(alphaURL, idemKey string, amtCentavos int) txResult {
	body := map[string]interface{}{
		"from_account_id": "alice-local-001",
		"pix_key":         "bob@psp-beta.com",
		"amount_centavos": amtCentavos,
		"idempotency_key": idemKey,
		"description":     "bench",
	}
	data, _ := json.Marshal(body)

	start := time.Now()
	resp, err := httpClient.Post(alphaURL+"/payment/initiate", "application/json", bytes.NewReader(data))
	latency := time.Since(start)

	if err != nil {
		return txResult{latency: latency, status: "NETWORK_ERROR"}
	}
	defer resp.Body.Close()

	var out struct {
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck

	status := out.Status
	if status == "" {
		if out.Error != "" {
			status = out.Error
		} else if resp.StatusCode >= 400 {
			status = "FAILED"
		} else {
			status = "UNKNOWN"
		}
	}
	return txResult{latency: latency, status: status}
}

func seedSTR(strURL, pspID string, balanceCentavos int64) error {
	body := map[string]interface{}{
		"psp_id":           pspID,
		"balance_centavos": balanceCentavos,
	}
	data, _ := json.Marshal(body)
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

func seedBeta(betaURL string) error {
	body := map[string]interface{}{
		"account_id":       "bob-local-001",
		"pix_key":          "bob@psp-beta.com",
		"balance_centavos": 0,
	}
	data, _ := json.Marshal(body)
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

func seedAlpha(alphaURL string, balanceCentavos int64) error {
	body := map[string]interface{}{
		"account_id":       "alice-local-001",
		"pix_key":          "alice@psp-alpha.com",
		"balance_centavos": balanceCentavos,
	}
	data, _ := json.Marshal(body)
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

func seedDICT(dictURL string) error {
	type userSeed struct {
		name  string
		doc   string
		pspID string
		key   string
	}
	users := []userSeed{
		{"Alice", "11122233344", "psp-alpha", "alice@psp-alpha.com"},
		{"Bob", "22233344455", "psp-beta", "bob@psp-beta.com"},
	}
	for _, u := range users {
		// If key already exists, skip
		resp, err := httpClient.Get(dictURL + "/key/" + u.key)
		if err != nil {
			return fmt.Errorf("DICT GET /key/%s: %w", u.key, err)
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
		if resp.StatusCode == 200 {
			continue
		}

		// POST /user
		data, _ := json.Marshal(map[string]interface{}{
			"document": u.doc,
			"name":     u.name,
			"psp_id":   u.pspID,
		})
		resp, err = httpClient.Post(dictURL+"/user", "application/json", bytes.NewReader(data))
		if err != nil {
			return fmt.Errorf("DICT POST /user: %w", err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 400 {
			return fmt.Errorf("DICT POST /user HTTP %d: %s", resp.StatusCode, body)
		}
		var userResp struct {
			UserID string `json:"user_id"`
		}
		json.Unmarshal(body, &userResp) //nolint:errcheck

		// POST /account
		data, _ = json.Marshal(map[string]interface{}{
			"user_id":        userResp.UserID,
			"psp_id":         u.pspID,
			"bank_ispb":      "00000000",
			"agency":         "0001",
			"account_number": "000001",
			"account_type":   "corrente",
		})
		resp, err = httpClient.Post(dictURL+"/account", "application/json", bytes.NewReader(data))
		if err != nil {
			return fmt.Errorf("DICT POST /account: %w", err)
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 400 {
			return fmt.Errorf("DICT POST /account HTTP %d: %s", resp.StatusCode, body)
		}
		var accountResp struct {
			AccountID string `json:"account_id"`
		}
		json.Unmarshal(body, &accountResp) //nolint:errcheck

		// POST /key
		data, _ = json.Marshal(map[string]interface{}{
			"account_id": accountResp.AccountID,
			"key_type":   "EMAIL",
			"key_value":  u.key,
		})
		resp, err = httpClient.Post(dictURL+"/key", "application/json", bytes.NewReader(data))
		if err != nil {
			return fmt.Errorf("DICT POST /key: %w", err)
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 400 {
			return fmt.Errorf("DICT POST /key HTTP %d: %s", resp.StatusCode, body)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := p / 100.0 * float64(len(sorted)-1)
	lo  := int(math.Floor(idx))
	hi  := int(math.Ceil(idx))
	if lo == hi {
		return sorted[lo]
	}
	frac := idx - float64(lo)
	return sorted[lo]*(1-frac) + sorted[hi]*frac
}

func pct(count, total int) float64 {
	if total == 0 {
		return 0
	}
	return 100.0 * float64(count) / float64(total)
}

func fmtMs(ms float64) string {
	if ms >= 1000 {
		return fmt.Sprintf("%.1fs", ms/1000)
	}
	return fmt.Sprintf("%.0fms", ms)
}

func slaCheck(actual, limit float64) string {
	if actual <= limit {
		return "✓"
	}
	return "✗ FAIL"
}

// printHistogram prints an ASCII histogram of latencies.
func printHistogram(sorted []float64) {
	// Buckets: <50ms, 50-100, 100-250, 250-500, 500-1000, 1-2s, 2-5s, 5-10s, >10s
	type bucket struct {
		label string
		lo    float64
		hi    float64
	}
	buckets := []bucket{
		{"< 50ms  ", 0, 50},
		{"50-100ms", 50, 100},
		{"100-250ms", 100, 250},
		{"250-500ms", 250, 500},
		{"0.5-1s  ", 500, 1000},
		{"1-2s    ", 1000, 2000},
		{"2-5s    ", 2000, 5000},
		{"5-10s   ", 5000, 10000},
		{"> 10s   ", 10000, math.MaxFloat64},
	}

	counts := make([]int, len(buckets))
	for _, v := range sorted {
		for i, b := range buckets {
			if v >= b.lo && v < b.hi {
				counts[i]++
				break
			}
		}
	}

	maxCount := 0
	for _, c := range counts {
		if c > maxCount {
			maxCount = c
		}
	}

	total := len(sorted)
	barW := 30
	for i, b := range buckets {
		if counts[i] == 0 {
			continue
		}
		barLen := 0
		if maxCount > 0 {
			barLen = counts[i] * barW / maxCount
		}
		bar := strings.Repeat("▪", barLen)
		pctVal := pct(counts[i], total)
		fmt.Printf("    %s │%-30s %5d  %5.1f%%\n", b.label, bar, counts[i], pctVal)
	}
}

// ---------------------------------------------------------------------------
// Process memory (Windows: tasklist)
// ---------------------------------------------------------------------------

type procMem struct {
	name string
	mb   float64
}

var nerveProcs = map[string]bool{
	"spi.exe":       true,
	"dict.exe":      true,
	"str.exe":       true,
	"bacen.exe":     true,
	"psp-alpha.exe": true,
	"psp-beta.exe":  true,
	"dashboard.exe": true,
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
		nameLower := strings.ToLower(fields[0])
		if !nerveProcs[nameLower] {
			continue
		}
		// fields[4]: "3,456 K" (en-US) or "3.456 K" (pt-BR)
		memStr := fields[4]
		memStr  = strings.ReplaceAll(memStr, " K", "")
		memStr  = strings.ReplaceAll(memStr, ",", "")
		memStr  = strings.ReplaceAll(memStr, ".", "")
		var kb int
		fmt.Sscanf(strings.TrimSpace(memStr), "%d", &kb)
		result = append(result, procMem{
			name: strings.TrimSuffix(nameLower, ".exe"),
			mb:   float64(kb) / 1024,
		})
	}
	return result
}

// csvSplit splits a simple CSV line removing outer quotes.
func csvSplit(line string) []string {
	parts := strings.Split(line, "\",\"")
	for i, p := range parts {
		parts[i] = strings.Trim(p, "\"")
	}
	return parts
}

func printMem(procs []procMem) {
	if len(procs) == 0 {
		fmt.Println("    (use Windows to see per-process memory usage)")
		return
	}

	// Aggregate by name (may have multiple instances)
	type agg struct{ mb float64; n int }
	aggMap := map[string]*agg{}
	order  := []string{}
	for _, p := range procs {
		if _, ok := aggMap[p.name]; !ok {
			order = append(order, p.name)
			aggMap[p.name] = &agg{}
		}
		aggMap[p.name].mb += p.mb
		aggMap[p.name].n++
	}

	total := 0.0
	for _, name := range order {
		a := aggMap[name]
		fmt.Printf("    %-16s  %6.1f MB\n", name, a.mb)
		total += a.mb
	}
	fmt.Printf("    %s\n", strings.Repeat("─", 28))
	fmt.Printf("    %-16s  %6.1f MB\n", "TOTAL", total)
}

// ---------------------------------------------------------------------------
// Banner
// ---------------------------------------------------------------------------

func banner() {
	fmt.Println()
	fmt.Println("  ╔══════════════════════════════════════════════════════╗")
	fmt.Println("  ║          Nerve PIX — Benchmark p50/p99               ║")
	fmt.Println("  ║  SLA BCB: p50 ≤ 5s  |  p99 ≤ 10s                    ║")
	fmt.Println("  ╚══════════════════════════════════════════════════════╝")
	fmt.Println()
}
