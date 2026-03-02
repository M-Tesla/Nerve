// PSP-alpha — Payer Bank
// Full flow — validates balance, debits account, calls SPI, reverses on failure.

package main

import (
	"bytes"
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

// Account represents a local account at PSP-alpha.
type Account struct {
	Balance int64  // in centavos
	PIXKey  string // PIX key registered for this account
}

// PaymentRecord stores the result of a payment (idempotency by idempotency_key).
type PaymentRecord struct {
	PaymentID      string `json:"payment_id"`
	TransactionID  string `json:"transaction_id,omitempty"`
	Status         string `json:"status"`
	AmountCentavos int64  `json:"amount_centavos"`
	ToKey          string `json:"to_key"`
	SettledAt      string `json:"settled_at,omitempty"`
	Error          string `json:"error,omitempty"`
}

var (
	mu       sync.Mutex
	accounts = map[string]*Account{}        // accountID → Account
	payments = map[string]*PaymentRecord{} // idempotencyKey → PaymentRecord
)

var spiBaseURL string

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	port    := strings.TrimSpace(getEnv("PSP_ALPHA_PORT", "9080"))
	spiPort := strings.TrimSpace(getEnv("SPI_PORT", "8080"))
	spiBaseURL = fmt.Sprintf("http://127.0.0.1:%s", spiPort)

	mux := http.NewServeMux()
	mux.HandleFunc("/health",           handleHealth)
	mux.HandleFunc("/admin/seed",       handleSeed)
	mux.HandleFunc("/payment/initiate", handleInitiate)
	mux.HandleFunc("/payment/",         handlePaymentGet)
	mux.HandleFunc("/balance/",         handleBalance)
	mux.HandleFunc("/metrics",          handleMetrics)

	log.Printf("[PSP-alpha] Listening on :%s | SPI at %s", port, spiBaseURL)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

// ---------------------------------------------------------------------------
// GET /health
// ---------------------------------------------------------------------------

func handleHealth(w http.ResponseWriter, r *http.Request) {
	jsonResp(w, 200, map[string]string{
		"status":  "ok",
		"service": "psp-alpha",
		"version": "0.1.0",
	})
}

// ---------------------------------------------------------------------------
// POST /admin/seed — create/reload account with balance and PIX key
// Body: {"account_id":"...","pix_key":"...","balance_centavos":50000}
// ---------------------------------------------------------------------------

func handleSeed(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		AccountID      string `json:"account_id"`
		PIXKey         string `json:"pix_key"`
		BalanceCentavos int64 `json:"balance_centavos"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AccountID == "" {
		jsonResp(w, 400, map[string]string{"error": "INVALID_JSON"})
		return
	}

	mu.Lock()
	accounts[req.AccountID] = &Account{Balance: req.BalanceCentavos, PIXKey: req.PIXKey}
	mu.Unlock()

	log.Printf("[PSP-alpha] Account %s seeded: balance=R$%.2f key=%s",
		req.AccountID, float64(req.BalanceCentavos)/100, req.PIXKey)

	jsonResp(w, 201, map[string]interface{}{
		"account_id":       req.AccountID,
		"pix_key":          req.PIXKey,
		"balance_centavos": req.BalanceCentavos,
	})
}

// ---------------------------------------------------------------------------
// POST /payment/initiate — initiate PIX payment
// Body: {"from_account_id":"...","pix_key":"...","amount_centavos":10000,
//        "idempotency_key":"...","description":"..."}
// ---------------------------------------------------------------------------

type InitiateRequest struct {
	FromAccountID  string `json:"from_account_id"`
	PIXKey         string `json:"pix_key"`           // payee/receiver PIX key
	AmountCentavos int64  `json:"amount_centavos"`
	IdempotencyKey string `json:"idempotency_key"`
	Description    string `json:"description,omitempty"`
}

func handleInitiate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var req InitiateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonResp(w, 400, map[string]string{"error": "INVALID_JSON"})
		return
	}
	if req.FromAccountID == "" || req.PIXKey == "" || req.AmountCentavos <= 0 || req.IdempotencyKey == "" {
		jsonResp(w, 400, map[string]string{"error": "MISSING_FIELDS"})
		return
	}

	mu.Lock()

	// Idempotency: return previous result if key was already processed
	if existing, ok := payments[req.IdempotencyKey]; ok {
		mu.Unlock()
		status := 200
		if existing.Status != "SETTLED" {
			status = 422
		}
		jsonResp(w, status, existing)
		return
	}

	// Verify payer account
	acc, exists := accounts[req.FromAccountID]
	if !exists {
		mu.Unlock()
		jsonResp(w, 404, map[string]string{"error": "ACCOUNT_NOT_FOUND"})
		return
	}
	if acc.Balance < req.AmountCentavos {
		mu.Unlock()
		jsonResp(w, 422, map[string]string{
			"error":             "INSUFFICIENT_BALANCE",
			"balance_centavos": fmt.Sprintf("%d", acc.Balance),
		})
		return
	}

	// Provisional debit (hold)
	payerKey := acc.PIXKey
	acc.Balance -= req.AmountCentavos

	// Register as PENDING for idempotency during processing
	paymentID := fmt.Sprintf("pay-%d", time.Now().UnixNano())
	rec := &PaymentRecord{
		PaymentID:      paymentID,
		Status:         "PENDING",
		AmountCentavos: req.AmountCentavos,
		ToKey:          req.PIXKey,
	}
	payments[req.IdempotencyKey] = rec
	mu.Unlock()

	// Call SPI outside the lock (potentially slow network operation)
	txID, spiStatus := callSPI(payerKey, req.PIXKey, req.AmountCentavos, req.IdempotencyKey, req.Description)

	mu.Lock()
	if spiStatus == "SETTLED" {
		rec.TransactionID = txID
		rec.Status        = "SETTLED"
		rec.SettledAt     = time.Now().UTC().Format(time.RFC3339)
		log.Printf("[PSP-alpha] Payment SETTLED: %s → %s R$%.2f tx=%s",
			req.FromAccountID, req.PIXKey, float64(req.AmountCentavos)/100, txID)
	} else {
		// Reverse provisional debit
		if a, ok := accounts[req.FromAccountID]; ok {
			a.Balance += req.AmountCentavos
		}
		rec.Status = spiStatus
		rec.Error  = "payment not settled: " + spiStatus
		log.Printf("[PSP-alpha] Payment %s: %s → %s R$%.2f",
			spiStatus, req.FromAccountID, req.PIXKey, float64(req.AmountCentavos)/100)
	}
	mu.Unlock()

	httpStatus := 200
	if rec.Status != "SETTLED" {
		httpStatus = 422
	}
	jsonResp(w, httpStatus, rec)
}

// ---------------------------------------------------------------------------
// GET /payment/:payment_id_or_idempotency_key
// ---------------------------------------------------------------------------

func handlePaymentGet(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	id := r.URL.Path[len("/payment/"):]

	mu.Lock()
	defer mu.Unlock()
	// Search by idempotency key or payment_id
	for ikey, rec := range payments {
		if ikey == id || rec.PaymentID == id {
			jsonResp(w, 200, rec)
			return
		}
	}
	jsonResp(w, 404, map[string]string{"error": "NOT_FOUND"})
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
	total, settled := len(payments), 0
	for _, p := range payments {
		if p.Status == "SETTLED" {
			settled++
		}
	}
	mu.Unlock()

	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintf(w,
		"# HELP nerve_psp_alpha_payments_total Total payments initiated\n"+
			"nerve_psp_alpha_payments_total %d\n"+
			"# HELP nerve_psp_alpha_payments_settled_total Settled payments\n"+
			"nerve_psp_alpha_payments_settled_total %d\n",
		total, settled,
	)
}

// ---------------------------------------------------------------------------
// SPI client
// ---------------------------------------------------------------------------

// callSPI calls POST /pix/initiate on the SPI and returns (tx_id, status).
// status can be: "SETTLED", "REVERSED", "FAILED", or "ERROR" if SPI is unreachable.
func callSPI(payerKey, payeeKey string, amountCentavos int64, idempotencyKey, description string) (txID, status string) {
	payload := map[string]interface{}{
		"payer_key":       payerKey,
		"payee_key":       payeeKey,
		"amount_centavos": amountCentavos,
		"idempotency_key": idempotencyKey,
		"description":     description,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return "", "FAILED"
	}

	resp, err := http.Post(spiBaseURL+"/pix/initiate", "application/json", bytes.NewReader(data))
	if err != nil {
		log.Printf("[PSP-alpha] SPI unreachable: %v", err)
		return "", "FAILED"
	}
	defer resp.Body.Close()

	var result struct {
		TxID   string `json:"tx_id"`
		Status string `json:"status"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		log.Printf("[PSP-alpha] SPI invalid response: %v", err)
		return "", "FAILED"
	}
	return result.TxID, result.Status
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func jsonResp(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}
