// PSP-beta — Receiver Bank
// Full implementation — receives PIX credit from SPI with idempotency.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

// ---------------------------------------------------------------------------
// In-memory state
// ---------------------------------------------------------------------------

// Account represents a local account at PSP-beta.
type Account struct {
	Balance int64  // in centavos
	PIXKey  string // PIX key for this account
}

// CreditRecord stores the result of a credit (idempotency by tx_id).
type CreditRecord struct {
	AccountID      string `json:"account_id"`
	AmountCentavos int64  `json:"amount_centavos"`
	NewBalance     int64  `json:"new_balance_centavos"`
	CreditedAt     string `json:"credited_at"`
}

var (
	mu           sync.Mutex
	accounts     = map[string]*Account{}      // accountID → Account
	keyToAccount = map[string]string{}         // pixKey → accountID
	credited     = map[string]*CreditRecord{}  // txID → CreditRecord (idempotency)
)

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	port := strings.TrimSpace(getEnv("PSP_BETA_PORT", "9090"))

	mux := http.NewServeMux()
	mux.HandleFunc("/health",     handleHealth)
	mux.HandleFunc("/admin/seed", handleSeed)
	mux.HandleFunc("/credit",     handleCredit)
	mux.HandleFunc("/balance/",   handleBalance)
	mux.HandleFunc("/metrics",    handleMetrics)

	log.Printf("[PSP-beta] Listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

// ---------------------------------------------------------------------------
// GET /health
// ---------------------------------------------------------------------------

func handleHealth(w http.ResponseWriter, r *http.Request) {
	jsonResp(w, 200, map[string]string{
		"status":  "ok",
		"service": "psp-beta",
		"version": "0.1.0",
	})
}

// ---------------------------------------------------------------------------
// POST /admin/seed — create/reload account with balance and PIX key
// Body: {"account_id":"...","pix_key":"...","balance_centavos":0}
// ---------------------------------------------------------------------------

func handleSeed(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		AccountID       string `json:"account_id"`
		PIXKey          string `json:"pix_key"`
		BalanceCentavos int64  `json:"balance_centavos"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AccountID == "" {
		jsonResp(w, 400, map[string]string{"error": "INVALID_JSON"})
		return
	}

	mu.Lock()
	accounts[req.AccountID] = &Account{Balance: req.BalanceCentavos, PIXKey: req.PIXKey}
	if req.PIXKey != "" {
		keyToAccount[req.PIXKey] = req.AccountID
	}
	mu.Unlock()

	log.Printf("[PSP-beta] Account %s seeded: balance=R$%.2f key=%s",
		req.AccountID, float64(req.BalanceCentavos)/100, req.PIXKey)

	jsonResp(w, 201, map[string]interface{}{
		"account_id":       req.AccountID,
		"pix_key":          req.PIXKey,
		"balance_centavos": req.BalanceCentavos,
	})
}

// ---------------------------------------------------------------------------
// POST /credit — called by SPI to credit the payee/receiver account
//
// Body sent by SPI:
//   {"tx_id":"<uuid>","payee_key":"<pix_key>","amount_centavos":<int>,"payer_psp_id":"<str>"}
// ---------------------------------------------------------------------------

func handleCredit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		TxID           string `json:"tx_id"`
		PayeeKey       string `json:"payee_key"`
		AmountCentavos int64  `json:"amount_centavos"`
		PayerPSPID     string `json:"payer_psp_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonResp(w, 400, map[string]string{"error": "INVALID_JSON"})
		return
	}
	if req.TxID == "" || req.PayeeKey == "" || req.AmountCentavos <= 0 {
		jsonResp(w, 400, map[string]string{"error": "MISSING_FIELDS"})
		return
	}

	mu.Lock()
	defer mu.Unlock()

	// Idempotency: tx_id already processed?
	if rec, ok := credited[req.TxID]; ok {
		log.Printf("[PSP-beta] Idempotent credit tx=%s", req.TxID)
		jsonResp(w, 200, map[string]interface{}{
			"credited":             true,
			"account_id":           rec.AccountID,
			"new_balance_centavos": rec.NewBalance,
			"credited_at":          rec.CreditedAt,
			"idempotent":           true,
		})
		return
	}

	// Resolve PIX key → local account_id
	accountID, found := keyToAccount[req.PayeeKey]
	if !found {
		log.Printf("[PSP-beta] PIX key '%s' not found in this PSP", req.PayeeKey)
		jsonResp(w, 404, map[string]string{"error": "PAYEE_KEY_NOT_FOUND"})
		return
	}

	acc, ok := accounts[accountID]
	if !ok {
		log.Printf("[PSP-beta] Account %s not found (internal inconsistency)", accountID)
		jsonResp(w, 404, map[string]string{"error": "ACCOUNT_NOT_FOUND"})
		return
	}

	// Credit account
	acc.Balance += req.AmountCentavos
	now := time.Now().UTC().Format(time.RFC3339)

	rec := &CreditRecord{
		AccountID:      accountID,
		AmountCentavos: req.AmountCentavos,
		NewBalance:     acc.Balance,
		CreditedAt:     now,
	}
	credited[req.TxID] = rec

	log.Printf("[PSP-beta] Credit: account=%s key=%s amount=R$%.2f new_balance=R$%.2f payer_psp=%s",
		accountID, req.PayeeKey,
		float64(req.AmountCentavos)/100,
		float64(acc.Balance)/100,
		req.PayerPSPID,
	)

	jsonResp(w, 200, map[string]interface{}{
		"credited":             true,
		"account_id":           accountID,
		"new_balance_centavos": acc.Balance,
		"credited_at":          now,
	})
}

// ---------------------------------------------------------------------------
// GET /balance/:account_id
// ---------------------------------------------------------------------------

func handleBalance(w http.ResponseWriter, r *http.Request) {
	accountID := r.URL.Path[len("/balance/"):]

	mu.Lock()
	acc, exists := accounts[accountID]
	var balance int64
	if exists {
		balance = acc.Balance
	}
	mu.Unlock()

	if !exists {
		jsonResp(w, 404, map[string]string{"error": "ACCOUNT_NOT_FOUND"})
		return
	}
	jsonResp(w, 200, map[string]interface{}{
		"account_id":       accountID,
		"balance_centavos": balance,
	})
}

// ---------------------------------------------------------------------------
// GET /metrics
// ---------------------------------------------------------------------------

func handleMetrics(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	totalAccounts := len(accounts)
	totalCredits  := len(credited)
	mu.Unlock()

	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintf(w,
		"# HELP nerve_psp_beta_accounts_total Total accounts\n"+
			"nerve_psp_beta_accounts_total %d\n"+
			"# HELP nerve_psp_beta_credits_total Total credits received\n"+
			"nerve_psp_beta_credits_total %d\n",
		totalAccounts, totalCredits,
	)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func jsonResp(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}
