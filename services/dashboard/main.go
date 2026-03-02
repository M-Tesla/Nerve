// Dashboard — Nerve PIX
// HTTP server that proxies internal APIs + serves UI for manual testing.
// No external dependencies — stdlib Go only.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

func trimPort(s string) string { return strings.TrimSpace(s) }

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

type Server struct {
	spiPort   string
	dictPort  string
	strPort   string
	bacenPort string
	alphaPort string
	betaPort  string
}

func main() {
	srv := &Server{
		spiPort:   trimPort(getEnv("SPI_PORT", "8080")),
		dictPort:  trimPort(getEnv("DICT_PORT", "8081")),
		strPort:   trimPort(getEnv("STR_PORT", "8082")),
		bacenPort: trimPort(getEnv("BACEN_PORT", "8083")),
		alphaPort: trimPort(getEnv("PSP_ALPHA_PORT", "9080")),
		betaPort:  trimPort(getEnv("PSP_BETA_PORT", "9090")),
	}
	port := trimPort(getEnv("DASHBOARD_PORT", "3000"))

	mux := http.NewServeMux()
	mux.HandleFunc("/", srv.handleIndex)
	mux.HandleFunc("/proxy/", srv.handleProxy)
	mux.HandleFunc("/_dashboard/seed", srv.handleSeed)
	mux.HandleFunc("/_dashboard/status", srv.handleServiceStatus)

	fmt.Printf("[dashboard] http://localhost:%s\n", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// GET / — serve the dashboard HTML
// ---------------------------------------------------------------------------

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, dashboardHTML)
}

// ---------------------------------------------------------------------------
// GET|POST /proxy/{service}/{path...} — simple reverse proxy
// ---------------------------------------------------------------------------

func (s *Server) handleProxy(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/proxy/")
	idx := strings.Index(rest, "/")

	var service, targetPath string
	if idx < 0 {
		service = rest
		targetPath = "/"
	} else {
		service = rest[:idx]
		targetPath = rest[idx:]
	}

	port := s.portFor(service)
	if port == "" {
		http.Error(w, `{"error":"service not found: `+service+`"}`, http.StatusNotFound)
		return
	}

	targetURL := "http://127.0.0.1:" + port + targetPath
	if r.URL.RawQuery != "" {
		targetURL += "?" + r.URL.RawQuery
	}

	proxyReq, err := http.NewRequest(r.Method, targetURL, r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if ct := r.Header.Get("Content-Type"); ct != "" {
		proxyReq.Header.Set("Content-Type", ct)
	}

	resp, err := http.DefaultClient.Do(proxyReq)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprintf(w, `{"error":"service unreachable","service":"%s"}`, service)
		return
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body) //nolint:errcheck
}

func (s *Server) portFor(service string) string {
	switch service {
	case "spi":
		return s.spiPort
	case "dict":
		return s.dictPort
	case "str":
		return s.strPort
	case "bacen":
		return s.bacenPort
	case "psp-alpha":
		return s.alphaPort
	case "psp-beta":
		return s.betaPort
	}
	return ""
}

// ---------------------------------------------------------------------------
// GET /_dashboard/status — health of all services
// ---------------------------------------------------------------------------

func (s *Server) handleServiceStatus(w http.ResponseWriter, r *http.Request) {
	type svcStatus struct {
		Name string `json:"name"`
		Port string `json:"port"`
		Up   bool   `json:"up"`
	}
	svcs := []struct{ name, port string }{
		{"spi", s.spiPort},
		{"dict", s.dictPort},
		{"str", s.strPort},
		{"bacen", s.bacenPort},
		{"psp-alpha", s.alphaPort},
		{"psp-beta", s.betaPort},
	}
	results := make([]svcStatus, 0, len(svcs))
	for _, svc := range svcs {
		resp, err := http.Get("http://127.0.0.1:" + svc.port + "/health")
		up := err == nil && resp.StatusCode == 200
		if resp != nil {
			resp.Body.Close()
		}
		results = append(results, svcStatus{Name: svc.name, Port: svc.port, Up: up})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(results) //nolint:errcheck
}

// ---------------------------------------------------------------------------
// POST /_dashboard/seed — populates DICT, STR and PSPs with test data
// ---------------------------------------------------------------------------

func (s *Server) handleSeed(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	var steps []string
	anyFailed := false

	// call: makes a POST JSON request, adds result to log, returns parsed body.
	// If service returns >= 400 or network error, returns nil.
	call := func(port, path, label string, body interface{}) map[string]interface{} {
		data, _ := json.Marshal(body)
		resp, err := http.Post("http://127.0.0.1:"+port+path, "application/json", bytes.NewReader(data))
		if err != nil {
			steps = append(steps, "✗ "+label+" (service unavailable)")
			anyFailed = true
			return nil
		}
		defer resp.Body.Close()
		var result map[string]interface{}
		json.NewDecoder(resp.Body).Decode(&result) //nolint:errcheck
		if resp.StatusCode >= 400 {
			steps = append(steps, fmt.Sprintf("✗ %s (HTTP %d)", label, resp.StatusCode))
			anyFailed = true
			return nil
		}
		steps = append(steps, "✓ "+label)
		return result
	}

	// ── DICT: check if already seeded ─────────────────────────────────────
	chkResp, _ := http.Get("http://127.0.0.1:" + s.dictPort + "/key/alice@psp-alpha.com")
	dictSeeded := chkResp != nil && chkResp.StatusCode == 200
	if chkResp != nil {
		chkResp.Body.Close()
	}

	if dictSeeded {
		steps = append(steps, "~ DICT: PIX keys already exist (skipping)")
	} else {
		// User Alice
		aliceUser := call(s.dictPort, "/user", "DICT: create user Alice", map[string]interface{}{
			"document": "12345678901", "name": "Alice Pagadora", "psp_id": "psp-alpha",
		})
		if aliceUser != nil {
			aliceUID, _ := aliceUser["user_id"].(string)
			aliceAcct := call(s.dictPort, "/account", "DICT: Alice account (psp-alpha)", map[string]interface{}{
				"user_id": aliceUID, "psp_id": "psp-alpha",
				"bank_ispb": "00000001", "agency": "0001",
				"account_number": "111111-1", "account_type": "corrente",
			})
			if aliceAcct != nil {
				aliceAID, _ := aliceAcct["account_id"].(string)
				call(s.dictPort, "/key", "DICT: key alice@psp-alpha.com", map[string]interface{}{
					"key_value": "alice@psp-alpha.com", "key_type": "EMAIL", "account_id": aliceAID,
				})
			}
		}

		// User Bob
		bobUser := call(s.dictPort, "/user", "DICT: create user Bob", map[string]interface{}{
			"document": "98765432100", "name": "Bob Recebedor", "psp_id": "psp-beta",
		})
		if bobUser != nil {
			bobUID, _ := bobUser["user_id"].(string)
			bobAcct := call(s.dictPort, "/account", "DICT: Bob account (psp-beta)", map[string]interface{}{
				"user_id": bobUID, "psp_id": "psp-beta",
				"bank_ispb": "99887766", "agency": "0001",
				"account_number": "222222-2", "account_type": "corrente",
			})
			if bobAcct != nil {
				bobAID, _ := bobAcct["account_id"].(string)
				call(s.dictPort, "/key", "DICT: key bob@psp-beta.com", map[string]interface{}{
					"key_value": "bob@psp-beta.com", "key_type": "EMAIL", "account_id": bobAID,
				})
			}
		}
	}

	// ── STR: PSP reserves ─────────────────────────────────────────────────
	call(s.strPort, "/admin/seed", "STR: psp-alpha R$10,000.00", map[string]interface{}{
		"psp_id": "psp-alpha", "balance_centavos": 1000000,
	})
	call(s.strPort, "/admin/seed", "STR: psp-beta R$0", map[string]interface{}{
		"psp_id": "psp-beta", "balance_centavos": 0,
	})

	// ── PSP-alpha: Alice local account ────────────────────────────────────
	call(s.alphaPort, "/admin/seed", "PSP-alpha: Alice R$5,000.00", map[string]interface{}{
		"account_id": "alice-local-001", "pix_key": "alice@psp-alpha.com", "balance_centavos": 500000,
	})

	// ── PSP-beta: Bob local account ───────────────────────────────────────
	call(s.betaPort, "/admin/seed", "PSP-beta: Bob R$0.00", map[string]interface{}{
		"account_id": "bob-local-001", "pix_key": "bob@psp-beta.com", "balance_centavos": 0,
	})

	status := http.StatusOK
	if anyFailed {
		status = http.StatusInternalServerError
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]interface{}{ //nolint:errcheck
		"ok": !anyFailed, "steps": steps,
	})
}

// ---------------------------------------------------------------------------
// Dashboard HTML (embedded)
// Note: Go raw string literal — no backticks inside the HTML.
// JS uses normal strings instead of template literals.
// ---------------------------------------------------------------------------

const dashboardHTML = `<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nerve PIX Dashboard</title>
<style>
:root{--bg:#0d1117;--sf:#161b22;--sf2:#21262d;--bd:#30363d;--tx:#e6edf3;--mt:#8b949e;--gn:#3fb950;--rd:#f85149;--yw:#d29922;--bl:#58a6ff;--or:#f0883e}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--tx);font-family:'Segoe UI',system-ui,sans-serif;padding:24px;min-height:100vh}
.hdr{display:flex;align-items:center;justify-content:space-between;padding-bottom:20px;border-bottom:1px solid var(--bd);margin-bottom:24px}
h1{font-size:20px;font-weight:700;letter-spacing:-0.3px}
.svcs{display:flex;align-items:center;gap:20px}
.sv{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--mt)}
.dot{width:8px;height:8px;border-radius:50%;background:var(--bd);transition:background .3s}
.dot.up{background:var(--gn)}.dot.dn{background:var(--rd)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:24px}
.card{background:var(--sf);border:1px solid var(--bd);border-radius:8px;padding:20px}
.ct{font-size:12px;color:var(--mt);margin-bottom:10px;text-transform:uppercase;letter-spacing:.5px}
.bal{font-size:30px;font-weight:700;font-variant-numeric:tabular-nums;margin-bottom:6px}
.bal.pos{color:var(--gn)}.bal.zer{color:var(--mt)}.bal.na{color:var(--bd)}
.pk{font-size:12px;color:var(--mt);font-family:monospace}
.ac{font-size:11px;color:var(--bd);margin-top:3px;font-family:monospace}
.fcard{background:var(--sf);border:1px solid var(--bd);border-radius:8px;padding:20px;margin-bottom:24px}
h2{font-size:12px;color:var(--mt);text-transform:uppercase;letter-spacing:.5px;margin-bottom:14px}
.fr{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
.fl{display:flex;flex-direction:column;gap:5px}
label{font-size:12px;color:var(--mt)}
input{background:var(--sf2);border:1px solid var(--bd);border-radius:6px;color:var(--tx);padding:8px 12px;font-size:14px;outline:none;font-family:inherit;width:100%}
input:focus{border-color:var(--bl)}input:disabled{opacity:.5}
.br{display:flex;justify-content:space-between;align-items:center;margin-top:16px}
.btn{background:var(--bl);border:none;border-radius:6px;color:#0d1117;font-size:14px;font-weight:600;padding:9px 22px;cursor:pointer;transition:opacity .15s}
.btn:hover{opacity:.85}.btn:disabled{opacity:.4;cursor:not-allowed}
.btn.seed{background:var(--or)}
.bg{background:transparent;border:1px solid var(--bd);color:var(--tx);border-radius:6px;font-size:12px;padding:6px 14px;cursor:pointer}
.bg:hover{border-color:var(--tx)}
.tcard{background:var(--sf);border:1px solid var(--bd);border-radius:8px;overflow:hidden}
.th{padding:14px 20px;border-bottom:1px solid var(--bd);display:flex;justify-content:space-between;align-items:center}
table{width:100%;border-collapse:collapse}
th{background:var(--sf2);padding:9px 16px;text-align:left;font-size:11px;color:var(--mt);font-weight:500;text-transform:uppercase;letter-spacing:.4px}
td{padding:11px 16px;font-size:13px;border-top:1px solid var(--bd)}
.mn{font-family:monospace;font-size:12px}
.bk{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600}
.bk.s{background:rgba(63,185,80,.15);color:var(--gn)}
.bk.r{background:rgba(248,81,73,.15);color:var(--rd)}
.bk.f{background:rgba(248,81,73,.15);color:var(--rd)}
.bk.p{background:rgba(210,153,34,.15);color:var(--yw)}
.bk.e{background:rgba(139,148,158,.15);color:var(--mt)}
.em{padding:48px;text-align:center;color:var(--mt);font-size:13px;line-height:1.8}
.toast{position:fixed;bottom:24px;right:24px;background:var(--sf2);border:1px solid var(--bd);border-radius:8px;padding:12px 20px;font-size:13px;max-width:380px;z-index:999;display:none;box-shadow:0 8px 32px rgba(0,0,0,.5)}
.toast.on{display:block}.toast.ok{border-color:var(--gn)}.toast.err{border-color:var(--rd)}
.step-list{font-size:12px;color:var(--mt);font-family:monospace;margin-top:8px;line-height:1.7}
</style>
</head>
<body>

<div class="hdr">
  <h1>&#x2B21; Nerve PIX</h1>
  <div class="svcs">
    <div class="sv"><div class="dot" id="d-spi"></div>SPI :8080</div>
    <div class="sv"><div class="dot" id="d-dict"></div>DICT :8081</div>
    <div class="sv"><div class="dot" id="d-str"></div>STR :8082</div>
    <div class="sv"><div class="dot" id="d-bacen"></div>BACEN :8083</div>
    <div class="sv"><div class="dot" id="d-alpha"></div>PSP-&#x3B1; :9080</div>
    <div class="sv"><div class="dot" id="d-beta"></div>PSP-&#x3B2; :9090</div>
    <button class="bg" onclick="refreshAll()">&#x21BB; Refresh</button>
  </div>
</div>

<div class="grid">
  <div class="card">
    <div class="ct">Alice &mdash; PSP-alpha (pagadora)</div>
    <div class="bal na" id="bal-alice">&mdash;</div>
    <div class="pk">alice@psp-alpha.com</div>
    <div class="ac">alice-local-001</div>
  </div>
  <div class="card">
    <div class="ct">Bob &mdash; PSP-beta (recebedor)</div>
    <div class="bal na" id="bal-bob">&mdash;</div>
    <div class="pk">bob@psp-beta.com</div>
    <div class="ac">bob-local-001</div>
  </div>
</div>

<div class="tcard" style="margin-bottom:24px">
  <div class="th">
    <h2 style="margin:0">BACEN &mdash; Net Settlement por PSP</h2>
    <button class="bg" onclick="refreshBacen()">&#x21BB;</button>
  </div>
  <div id="bacen-body">
    <div class="em">Aguardando dados do BACEN&hellip;</div>
  </div>
</div>

<div class="fcard">
  <h2>Enviar PIX</h2>
  <div class="fr">
    <div class="fl">
      <label>De</label>
      <input value="Alice (alice-local-001)" disabled>
    </div>
    <div class="fl">
      <label>Chave PIX do Recebedor</label>
      <input id="payee" value="bob@psp-beta.com">
    </div>
  </div>
  <div class="fr">
    <div class="fl">
      <label>Valor (R$)</label>
      <input id="amount" type="number" value="100" step="0.01" min="0.01">
    </div>
    <div class="fl">
      <label>Descri&#xe7;&#xe3;o</label>
      <input id="desc" value="Pagamento via Nerve PIX">
    </div>
  </div>
  <div class="br">
    <button class="btn seed" id="btn-seed" onclick="doSeed()">&#x2B21; Seed Dados</button>
    <button class="btn" id="btn-send" onclick="doSend()">Enviar PIX &#x2192;</button>
  </div>
</div>

<div class="tcard">
  <div class="th">
    <h2 style="margin:0">Hist&#xf3;rico de Transa&#xe7;&#xf5;es</h2>
    <button class="bg" onclick="renderTxns()">&#x21BB;</button>
  </div>
  <div id="tbody">
    <div class="em">Nenhuma transa&#xe7;&#xe3;o ainda.<br>Clique em <strong>Seed Dados</strong> e depois <strong>Enviar PIX</strong>.</div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
var txns = [];

function r2(x){ return (x/100).toFixed(2).replace(".",","); }
function fmtBRL(c){ return "R$ "+r2(c); }

function toast(msg, type){
  var el=document.getElementById("toast");
  el.textContent=msg; el.className="toast on "+(type||"");
  clearTimeout(el._t); el._t=setTimeout(function(){ el.className="toast"; },4500);
}

function api(method, service, path, body){
  var url="/proxy/"+service+path;
  var opts={method:method,headers:{"Content-Type":"application/json"}};
  if(body) opts.body=JSON.stringify(body);
  return fetch(url,opts).then(function(r){
    return r.json().then(function(d){ return {ok:r.ok,status:r.status,data:d}; })
      .catch(function(){ return {ok:r.ok,status:r.status,data:{}}; });
  }).catch(function(e){ return {ok:false,status:0,data:{error:e.message}}; });
}

function checkHealth(){
  var svcs=[
    ["spi","d-spi"],["dict","d-dict"],["str","d-str"],
    ["psp-alpha","d-alpha"],["psp-beta","d-beta"]
  ];
  svcs.forEach(function(s){
    fetch("/_dashboard/status").then(function(r){ return r.json(); }).then(function(list){
      list.forEach(function(item){
        var id="d-"+item.name;
        var el=document.getElementById(id);
        if(el) el.className="dot "+(item.up?"up":"dn");
      });
    }).catch(function(){});
    return;
  });
  fetch("/_dashboard/status").then(function(r){ return r.json(); }).then(function(list){
    list.forEach(function(item){
      var id="d-"+item.name;
      var el=document.getElementById(id);
      if(el) el.className="dot "+(item.up?"up":"dn");
    });
  }).catch(function(){});
}

function refreshBalances(){
  api("GET","psp-alpha","/balance/alice-local-001").then(function(r){
    var el=document.getElementById("bal-alice");
    if(r.ok){
      var b=r.data.balance_centavos||0;
      el.textContent=fmtBRL(b);
      el.className="bal "+(b>0?"pos":"zer");
    } else { el.textContent="N/A"; el.className="bal na"; }
  });
  api("GET","psp-beta","/balance/bob-local-001").then(function(r){
    var el=document.getElementById("bal-bob");
    if(r.ok){
      var b=r.data.balance_centavos||0;
      el.textContent=fmtBRL(b);
      el.className="bal "+(b>0?"pos":"zer");
    } else { el.textContent="N/A"; el.className="bal na"; }
  });
}

function refreshBacen(){
  api("GET","bacen","/position").then(function(r){
    var el=document.getElementById("bacen-body");
    if(!r.ok||!r.data||!Array.isArray(r.data.positions)){
      el.innerHTML="<div class=\"em\" style=\"padding:20px\">BACEN indispon\u00edvel ou sem dados.</div>";
      return;
    }
    var rows=r.data.positions.map(function(p){
      var net=p.credits_centavos-p.debits_centavos;
      var cls=net>=0?"pos":"rd";
      var color=net>=0?"var(--gn)":"var(--rd)";
      return "<tr>"
        +"<td class=\"mn\">"+p.psp_id+"</td>"
        +"<td style=\"font-variant-numeric:tabular-nums;color:var(--gn)\">"+fmtBRL(p.credits_centavos)+"</td>"
        +"<td style=\"font-variant-numeric:tabular-nums;color:var(--rd)\">"+fmtBRL(p.debits_centavos)+"</td>"
        +"<td style=\"font-variant-numeric:tabular-nums;font-weight:700;color:"+color+"\">"+fmtBRL(net)+"</td>"
        +"<td style=\"color:var(--mt)\">"+p.tx_count+"</td>"
        +"</tr>";
    }).join("");
    if(rows===""){
      el.innerHTML="<div class=\"em\" style=\"padding:20px\">Nenhuma liquida\u00e7\u00e3o registrada ainda.</div>";
      return;
    }
    el.innerHTML="<table><thead><tr>"
      +"<th>PSP</th><th>Cr\u00e9ditos</th><th>D\u00e9bitos</th><th>Net</th><th>Txs</th>"
      +"</tr></thead><tbody>"+rows+"</tbody></table>";
  }).catch(function(){
    var el=document.getElementById("bacen-body");
    el.innerHTML="<div class=\"em\" style=\"padding:20px\">Erro ao consultar BACEN.</div>";
  });
}

function refreshAll(){ checkHealth(); refreshBalances(); refreshBacen(); }

function doSeed(){
  var btn=document.getElementById("btn-seed");
  btn.disabled=true; btn.textContent="Semeando...";
  fetch("/_dashboard/seed",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"})
    .then(function(r){ return r.json().then(function(d){ return {ok:r.ok,data:d}; }); })
    .then(function(res){
      btn.disabled=false; btn.textContent="\u2B21 Seed Dados";
      var d=res.data;
      var steps=(d.steps||[]).join("\n");
      if(res.ok && d.ok){
        toast("Dados semeados com sucesso!","ok");
      } else {
        toast("Seed parcialmente falhou — veja console","err");
        console.warn("Seed steps:",steps);
      }
      console.log("Seed:\n"+steps);
      refreshAll();
    }).catch(function(e){
      btn.disabled=false; btn.textContent="\u2B21 Seed Dados";
      toast("Erro ao semear: "+e.message,"err");
    });
}

function doSend(){
  var payee=document.getElementById("payee").value.trim();
  var amount=Math.round(parseFloat(document.getElementById("amount").value)*100);
  var desc=document.getElementById("desc").value.trim();
  if(!payee||amount<=0){ toast("Preencha todos os campos","err"); return; }

  var btn=document.getElementById("btn-send");
  btn.disabled=true; btn.textContent="Enviando...";

  var idem="ui-"+Date.now();
  api("POST","psp-alpha","/payment/initiate",{
    from_account_id:"alice-local-001",
    pix_key:payee, amount_centavos:amount,
    idempotency_key:idem, description:desc
  }).then(function(r){
    btn.disabled=false; btn.textContent="Enviar PIX \u2192";
    var d=r.data;
    txns.unshift({
      pid: d.payment_id||"—",
      tid: d.transaction_id||"",
      status: d.status||"ERROR",
      amount: amount, to: payee,
      ts: d.settled_at||new Date().toISOString(),
      err: d.error||""
    });
    renderTxns();
    if(d.status==="SETTLED"){
      toast("PIX enviado! "+fmtBRL(amount)+" \u2192 "+payee,"ok");
      refreshBalances();
    } else {
      toast("Falha: "+(d.error||d.status||"UNKNOWN"),"err");
    }
  }).catch(function(e){
    btn.disabled=false; btn.textContent="Enviar PIX \u2192";
    toast("Erro de rede: "+e.message,"err");
  });
}

function checkTx(tid){
  if(!tid) return;
  api("GET","spi","/pix/status/"+tid).then(function(r){
    if(r.ok){
      var d=r.data;
      toast("TX "+tid.substring(0,8)+"... | "+d.status+" | "+fmtBRL(d.amount_centavos),"ok");
    } else { toast("Transa\u00e7\u00e3o n\u00e3o encontrada","err"); }
  });
}

function statusClass(s){
  return {SETTLED:"s",REVERSED:"r",FAILED:"f",PENDING:"p",ERROR:"e"}[s]||"e";
}

function renderTxns(){
  var el=document.getElementById("tbody");
  if(txns.length===0){
    el.innerHTML="<div class=\"em\">Nenhuma transa\u00e7\u00e3o ainda.<br>Clique em <strong>Seed Dados</strong> e depois <strong>Enviar PIX</strong>.</div>";
    return;
  }
  var rows=txns.map(function(t){
    var sc=statusClass(t.status);
    var idCell=t.tid
      ? "<a href=\"#\" onclick=\"checkTx('"+t.tid+"');return false;\" style=\"color:var(--bl)\" title=\""+t.tid+"\">"+t.tid.substring(0,8)+"&hellip;</a>"
      : "<span class=\"mn\" style=\"color:var(--mt)\">"+t.pid+"</span>";
    var ts=t.ts?new Date(t.ts).toLocaleTimeString("pt-BR"):"&mdash;";
    var errCell=t.err?"<span style=\"color:var(--rd);font-size:11px\">"+t.err+"</span>":"";
    return "<tr><td>"+idCell+"</td>"
      +"<td><span class=\"bk "+sc+"\">"+t.status+"</span>"+errCell+"</td>"
      +"<td style=\"font-variant-numeric:tabular-nums\">"+fmtBRL(t.amount)+"</td>"
      +"<td class=\"mn\" style=\"color:var(--mt)\">"+t.to+"</td>"
      +"<td style=\"color:var(--mt);font-size:12px\">"+ts+"</td></tr>";
  }).join("");
  el.innerHTML="<table><thead><tr>"
    +"<th>ID</th><th>Status</th><th>Valor</th><th>Para</th><th>Hor\u00e1rio</th>"
    +"</tr></thead><tbody>"+rows+"</tbody></table>";
}

refreshAll();
setInterval(refreshAll, 8000);
</script>
</body>
</html>`
