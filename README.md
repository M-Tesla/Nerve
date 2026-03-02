# Nerve - Brazilian PIX Payment System (Educational Project)

> **This is a study and learning project , not production software.**
> Everything here was intentionally kept as simple as possible. The goal is to understand how a real-time payment system works internally by building one from scratch, not to ship a finished product. There is no hardening, no thorough error handling, no security audit, no operational tooling. Treat it as a reference for learning low-level systems programming and payment system architecture concepts.

Nerve is a from-scratch educational implementation of Brazil's PIX instant payment system, built for Windows using low-level technologies as a learning exercise. No ORM, no high-level framework, no external runtime in the core: storage via direct C FFI, custom Ed25519 auth, raw TCP NATS client in Zig, deliberately simple implementations to make each piece easy to read and understand.

---

## What is PIX?

PIX is Brazil's Central Bank instant payment system , transfers between different banks in seconds, 24/7, zero fee. The real system is composed of Central Bank infrastructure (SPI, DICT, STR) plus the participating banks and fintechs (PSPs).

Nerve recreates this entire architecture in a single repository:

- **SPI**: central orchestrator; guarantees settlement and irrevocability
- **DICT**: PIX key directory (CPF, email, phone, random key)
- **STR**: interbank reserve system (collateral in transit)
- **BACEN**: regulatory supervisor; consolidates daily positions
- **PSPs**: the banks that connect end-users to the infrastructure

---

## Performance

**Real hardware: Windows 10 Pro · SAS HDD · x86-64 · single node.**

| Load | Throughput | p50 | p99 | Success | Total RAM |
|------|-----------|-----|-----|---------|-----------|
| 200 tx | 75 tx/s | 240 ms | 385 ms | 100% | 41 MB |
| 1,000 tx | 55 tx/s | 301 ms | 1.6 s | 100% | 64 MB |
| **5,000 tx** | **44 tx/s** | **376 ms** | **2.7 s** | **100%** | **68 MB** |

Central Bank SLA: p50 ≤ 5 s and p99 ≤ 10 s. Result: **13× below the p50 limit, 3.7× below p99.**

Throughput drops under high concurrency because STR uses libmdbx's single-writer model. 100% success across all loads , zero transaction loss.

**Ramp-up stress test (2 → 80 workers, SAS HDD):**

| Workers | tx/s | p50 | p99 | Success |
|---------|------|-----|-----|---------|
| 2 | 60.0 | 24 ms | 130 ms | 100% |
| 5 | 40.4 | 131 ms | 261 ms | 100% |
| 80 | 72.4 | 1.60 s | 1.75 s | 100% |

System ceiling not reached, 0 failures at any concurrency level. With SSD, expect 3–10× more throughput.

---

## Stack

| Component | Technology | Why |
|---|---|---|
| SPI, DICT, STR, BACEN, Auth | **Zig 0.15** | Zero GC, memory control, direct C FFI |
| PSP-alpha, PSP-beta, Dashboard | **Go 1.22** | Native concurrency, HTTP stdlib, fast iteration |
| Storage engine | **libmdbx** (via C FFI) | ACID B-tree, MVCC, copy-on-write, no Postgres, no Redis |
| Messaging | **NATS JetStream** | Single binary, replaces Kafka; raw TCP client in Zig |
| Auth | **Ed25519 JWT** | No Keycloak, no external JWT library |
| Observability | **VictoriaMetrics + Grafana** | Podman containers; real-time SPI/BACEN/PSP metrics |

---

## Prerequisites

**OS: Windows 10/11** (tested on 10.0.19045).

Services run natively on Windows, no WSL required for the core.

```powershell
zig version    # >= 0.15.0-dev (nightly build)
go version     # >= 1.22
```

For the stress test dashboard: **Windows Terminal** (ANSI + Unicode block character support needed).

For observability (optional): **Podman Desktop** with the default machine running.

---

## Tutorial: Running the Full System

### Step 1: Start all services

Open **Windows Terminal**, navigate to the project root and run:

```powershell
# First run , compiles everything, opens each service in its own cmd.exe window:
.\scripts\start-all.ps1

# Subsequent runs , skip recompilation (use existing binaries):
.\scripts\start-all.ps1 -NoBuild

# Wipe all databases and restart from scratch:
.\scripts\start-all.ps1 -Clean
```

The script builds 4 Zig services (`zig build`) and 3 Go services (`go build`), opens each in a separate `cmd.exe` window with the correct environment variables, and waits until all respond to health checks. Then opens the dashboard at `http://localhost:3000`.

**Services started:**

| Service | Port | Language | Role |
|---------|------|----------|------|
| SPI | 8080 | Zig | PIX orchestrator |
| DICT | 8081 | Zig | Key directory |
| STR | 8082 | Zig | Reserve system |
| BACEN | 8083 | Zig | Regulatory supervisor |
| Auth | 8084 | Zig | Ed25519 JWT issuer |
| PSP-alpha | 9080 | Go | Payer bank (Alice) |
| PSP-beta | 9090 | Go | Receiver bank (Bob) |
| Dashboard | 3000 | Go | Web UI + reverse proxy |
| NATS | 4222 | , | Optional , services degrade gracefully without it |

---

### Step 2: Seed initial data

**Option A: Web dashboard (easiest):**

Open `http://localhost:3000`. Click **[Seed Dados]**, creates Alice (PSP-alpha) and Bob (PSP-beta) in DICT and funds the STR reserve.

**Option B: PowerShell (manual control):**

```powershell
# Fund Alice's account in PSP-alpha (R$ 10,000.00 = 1,000,000 centavos)
Invoke-RestMethod -Method POST http://localhost:9080/admin/seed `
  -ContentType "application/json" `
  -Body '{"account_id":"alice-local-001","pix_key":"alice@psp-alpha.com","balance_centavos":1000000}'

# Fund STR reserve for psp-alpha
Invoke-RestMethod -Method POST http://localhost:8082/admin/seed `
  -ContentType "application/json" `
  -Body '{"psp_id":"psp-alpha","balance_centavos":1000000}'

# Register Bob in PSP-beta (starts with 0 balance)
Invoke-RestMethod -Method POST http://localhost:9090/admin/seed `
  -ContentType "application/json" `
  -Body '{"account_id":"bob-local-001","pix_key":"bob@psp-beta.com","balance_centavos":0}'

# Register Alice and Bob as users in DICT
# (The bench/stress scripts handle this automatically via the seeding functions)
```

---

### Step 3: Send a PIX transaction

```powershell
# Initiate a PIX payment: Alice → Bob, R$ 1.00
$result = Invoke-RestMethod -Method POST http://localhost:8080/pix/initiate `
  -ContentType "application/json" `
  -Body '{"idempotency_key":"my-first-pix","payer_key":"alice@psp-alpha.com","payee_key":"bob@psp-beta.com","amount_centavos":100,"description":"test"}'

$result
# Expected: { tx_id: "<uuid>", status: "SETTLED" }
```

```powershell
# Check transaction status
Invoke-RestMethod "http://localhost:8080/pix/status/$($result.tx_id)"

# Check Alice's balance (PSP-alpha)
Invoke-RestMethod http://localhost:9080/account/alice-local-001

# Check Bob's balance (PSP-beta)
Invoke-RestMethod http://localhost:9090/account/bob-local-001

# Check BACEN net positions
Invoke-RestMethod http://localhost:8083/position

# Check BACEN audit log
Invoke-RestMethod http://localhost:8083/audit
```

**Idempotency test, sending the same key twice returns the same tx_id:**

```powershell
# Second call with same idempotency_key → returns same result, no double charge
Invoke-RestMethod -Method POST http://localhost:8080/pix/initiate `
  -ContentType "application/json" `
  -Body '{"idempotency_key":"my-first-pix","payer_key":"alice@psp-alpha.com","payee_key":"bob@psp-beta.com","amount_centavos":100,"description":"test"}'
```

---

### Step 4: Run the benchmark (count-based)

The benchmark sends N transactions with C concurrent workers, measures latency percentiles and checks the BCB SLA:

```powershell
cd scripts\bench

# Quick test , 200 transactions (~3s):
go run . -n 200 -c 20

# Standard test , 1,000 transactions (~20s):
go run . -n 1000 -c 20

# Heavy test , 5,000 transactions (~2 min):
go run . -n 5000 -c 20

# Skip seeding (reuse existing state):
go run . -n 1000 -c 20 -no-seed

# Custom PIX amount (default: 100 centavos = R$ 1.00):
go run . -n 500 -c 10 -amount 50
```

Output: throughput, p50/p75/p90/p99/p99.9/max, ASCII latency histogram, BCB SLA check, RAM per process.

---

### Step 5: Run the stress test (ramp-up with live TUI dashboard)

The stress test **progressively increases concurrency** to find the system's throughput ceiling. It displays a full-screen live terminal dashboard that updates 4 times per second:

```
╔══ Nerve PIX , Stress Test ════════════════════════════════════════════════════════╗
║  Phase 3/6 · 10 workers · 00:12 elapsed                                           ║
╠══ Requests/s ══════════════════════════════════╦══ Latency p99 ═══════════════════╣
║  60tx/s  █████████████████▇▇▆▅▄▃▂▁        ║  300ms ▁▂▃▄▅▆▇████████▇▆▅  ║
║   0tx/s                                        ║    0ms                           ║
║  dim: max:60  last:42.3 tx/s                   ║  dim: max:300  last:312ms        ║
╠══ CPU % ═══════════════════════════════════════╬══ Memory ════════════════════════╣
║  spi       [████████░░░░░░░░░░░░░░]  38.5%     ║  spi          25.1 MiB           ║
║  dict      [████░░░░░░░░░░░░░░░░░░]   9.8%     ║  dict          8.3 MiB           ║
║  str       [███░░░░░░░░░░░░░░░░░░░]   9.1%     ║  str           7.9 MiB           ║
║  bacen     [█░░░░░░░░░░░░░░░░░░░░░]   2.1%     ║  bacen         4.1 MiB           ║
║  psp-alpha [██░░░░░░░░░░░░░░░░░░░░]   5.3%     ║  psp-alpha     6.2 MiB           ║
║  psp-beta  [██░░░░░░░░░░░░░░░░░░░░]   4.9%     ║  psp-beta      5.8 MiB           ║
╠══ Phase Progress ═════════════════════════════════════════════════════════════════╣
║  Phase 3/6 · 10w  [███████████████████░░░░░░░░░░░░░░░]  3.8s / 5.0s               ║
║  OK: 1842  FAIL: 0  Success: 100.0%   RPS: 42.3  p50: 180ms  p99: 312ms           ║
╠══ Phase History ══════════════════════════════════════════════════════════════════╣
║  #    Workers   tx/s      p50      p99      OK     FAIL    ok%   Status           ║
║  1         2   60.0      24ms    130ms     300        0   100%   OK               ║
║  2         5   40.4     131ms    261ms     202        0   100%   OK               ║
╚═══════════════════════════════════════════════════════════════════════════════════╝
```

```powershell
cd scripts\stress

# Default: 30s total, 6 phases × 5s, workers: 2→5→10→20→40→80
go run .

# Longer test , find the real ceiling:
go run . -duration 60s -step 10s -ramp 2,5,10,20,40,80,150,300

# Skip seeding (reuse existing state):
go run . -no-seed

# Custom worker ramp only:
go run . -ramp 5,10,25,50,100
```

**After each phase completes**, a row is added to the history table. When all phases finish, the dashboard exits and prints a final summary:

```
  ══════════════════════════════════════════════════════════
  STRESS TEST RESULTS
  ══════════════════════════════════════════════════════════

  #    Workers  tx/s     p50      p99      OK      FAIL   ok%   Status
  ─────────────────────────────────────────────────────────────────────
  1          2  60.0    24ms    130ms     300         0   100%  OK
  2          5  40.4   131ms    261ms     202         0   100%  OK
  ...

  Throughput (tx/s) per concurrency level:
    2w │████████████████████████████████████████  60.0 tx/s
    5w │██████████████████████████████            40.4 tx/s  ▼ declining
  ...

  Peak throughput : 72.4 tx/s @ 80 workers (phase 6)
  BCB SLA (p99 ≤ 10s) : ✓ met across all phases
```

> **Requires Windows Terminal** for ANSI escape codes and Unicode block characters.

---

### Step 6: Observability (optional, requires Podman Desktop)

With services running, start VictoriaMetrics + Grafana:

```powershell
.\scripts\start-observability.ps1
```

Creates an SSH reverse tunnel from Windows to the Podman machine (ports offset 18080+ to avoid WSL2 proxy conflicts), starts both containers, and opens the browser.

| URL | What |
|-----|------|
| `http://localhost:3000` | Grafana (admin / nerve123) |
| `http://localhost:3000/d/nerve-pix/nerve-pix` | Nerve PIX live dashboard |
| `http://localhost:8428` | VictoriaMetrics (direct query) |

**Metrics collected:** `nerve_pix_transactions_total`, `nerve_bacen_settled_total`, `nerve_psp_alpha_payments_total`, `nerve_psp_beta_credits_total` and more.

> DICT, STR and Auth do not expose `/metrics` , no Prometheus endpoint yet.

---

## PIX Transaction Flow

```
Alice (PSP-alpha :9080)    SPI (:8080)    DICT (:8081)   STR (:8082)   PSP-beta (:9090)
        │                      │               │               │               │
        │── POST /payment ─────>│               │               │               │
        │                       │── GET key ───>│               │               │
        │                       │<── psp-beta ──│               │               │
        │                       │── GET key ───>│  (payee)      │               │
        │                       │<── psp-alpha ─│               │               │
        │                       │── reserve ────────────────────>│               │
        │                       │<── ok ─────────────────────────│               │
        │                       │── update DB (PENDING→RESERVED) │               │
        │                       │── settle ──────────────────────>│               │
        │                       │<── ok ──────────────────────────│               │
        │                       │── POST /credit ─────────────────────────────────>│
        │                       │<── ok ────────────────────────────────────────────│
        │                       │── update DB (RESERVED→SETTLED) │               │
        │<── 200 SETTLED ────────│               │               │               │
```

Each transaction touches 4 distinct services in sequence. Idempotency is guaranteed at two levels: SHA-256 of the idempotency key in SPI, and `tx_id` deduplication in PSP-beta.

---

## The Monolith (Mini DB with libmdbx Storage Engine)

**Monolith** is the mini database (with libmdbx for storage layer) for all Zig services , a Zig wrapper over **libmdbx** (C), compiled as an in-process static library. No daemon, no network, nothing but the `.monolith` file on disk.

```
libs/monolith/
├── libmdbx/          # C source (mdbx.c, mdbx.h) , vendored
├── src/
│   ├── lib.zig       # Public API: Environment, Transaction, Cursor
│   ├── env.zig       # Environment.open / .close
│   ├── txn.zig       # Transaction.begin / .commit / .abort / .get / .put / .del
│   └── cursor.zig    # Cursor.first / .next / .find / .findGe / dupsort
├── build.zig
└── build.zig.zon
```

Each service embeds Monolith via local dependency (`path = "../../libs/monolith"`). Data lives in `data/{spi,dict,str,bacen}/` , persisted across restarts, one file per service.

**Active optimizations (4–7× throughput improvement on SAS HDD):**

| Flag | Service | Effect |
|------|---------|--------|
| `MDBX_SAFE_NOSYNC` | STR | Commits go to RAM (page cache), not disk , fsync every 100ms |
| `MDBX_LIFORECLAIM` | All | Reclaims pages LIFO → better locality, fewer disk seeks |
| `MDBX_APPEND` | STR ledger | Skips B-tree search on sequential inserts (big-endian keys) |

> `MDBX_WRITEMAP` **do not use on Windows**, NT section objects + CoW per page is slower than native shadow paging.

---

## Project Structure

```
nerve-code/
├── libs/
│   └── monolith/            # libmdbx C FFI , shared storage engine
│       ├── libmdbx/         # mdbx.c + mdbx.h (vendored)
│       ├── src/             # lib.zig, env.zig, txn.zig, cursor.zig, ...
│       ├── build.zig
│       └── build.zig.zon
├── services/
│   ├── spi/src/             # main, db, state_machine, http_client, nats, utils
│   ├── dict/src/            # main, db, utils
│   ├── str/src/             # main, db, utils
│   ├── bacen/src/           # main, db, utils
│   ├── auth/src/            # main, store/db, jwt/{signer,verifier,claims}, keys/registry
│   ├── psp-alpha/cmd/       # main.go , payer bank
│   ├── psp-beta/cmd/        # main.go , receiver bank
│   └── dashboard/           # main.go , web UI + reverse proxy
├── scripts/
│   ├── start-all.ps1        # Build + start all services (Windows)
│   ├── start-observability.ps1  # VictoriaMetrics + Grafana via Podman
│   ├── bench/               # Count-based benchmark (Go)
│   │   ├── main.go
│   │   └── go.mod
│   └── stress/              # Ramp-up stress test with live TUI dashboard (Go)
│       ├── main.go
│       └── go.mod
├── infra/
│   ├── victoriametrics/scrape.yaml
│   ├── grafana/
│   │   ├── datasources.yaml
│   │   └── dashboards/      # dashboards.yaml + nerve-pix.json
│   └── podman/compose.yaml  # Full containerized deploy (future)
└── .gitignore
```

---

## Data Models

### DICT
| DBI | Key | Value |
|-----|-----|-------|
| `users` | user_id (UUID) | `UserRecord` |
| `accounts` | account_id (UUID) | `AccountRecord` |
| `pix_keys` | pix_key (string) | `KeyRecord` |
| `idx_user_accounts` | user_id + account_id | `""` (dupsort index) |
| `idx_account_keys` | account_id + pix_key | `""` (dupsort index) |

### STR
| DBI | Key | Value |
|-----|-----|-------|
| `psp_reserves` | psp_id | `ReserveRecord` (balance + version) |
| `reservations` | reservation_id | `ReservationRecord` |
| `ledger_entries` | seq big-endian u64 | `LedgerEntry` |
| `str_meta` | `"ledger_seq"` | u64 LE counter |

### SPI
| DBI | Key | Value |
|-----|-----|-------|
| `pix_transactions` | tx_id | `TxRecord` (1-byte state + payload) |
| `idempotency` | SHA-256(idempotency_key) | tx_id |

### BACEN
| DBI | Key | Value |
|-----|-----|-------|
| `positions` | psp_id | `PositionRecord` (credits + debits + tx_count) |
| `audit_log` | seq big-endian u64 | JSON event |

---

## Version History

| Version | What it covers |
|---------|---------------|
| **v0.1** | Auth: Ed25519 keypair, JWT sign/verify, PSP key registry |
| **v0.2** | DICT: CRUD users/accounts/pix_keys, dupsort indices, 5 tests |
| **v0.3** | STR: reserve/settle/reverse, append-only ledger, optimistic versioning, 6 tests |
| **v0.4** | SPI: state machine, Zig HTTP client, NATS publisher, 15 tests, SHA-256 idempotency |
| **v0.5** | Go PSPs + Web dashboard: psp-alpha/psp-beta, seed API, UI, reverse proxy |
| **v0.6** | BACEN: net settlement, PSP positions, audit log; Prometheus metrics on SPI |
| **v0.6.1** | Benchmark: standalone Go tool, p50/p99, ASCII histogram, BCB SLA check, RAM per process |
| **v0.6.2** | libmdbx perf: SAFE_NOSYNC + LIFORECLAIM + MDBX_APPEND; 4–7× throughput on SAS HDD |
| **v0.7** | Observability: VictoriaMetrics + Grafana in Podman, SSH tunnel, provisioned dashboard |
| **v0.8** | Stress test TUI: full-screen Grafana-style terminal dashboard; time-series charts, CPU % per process (typeperf), memory (tasklist), zero external dependencies |

---

## What's Missing

- **HAProxy** , mTLS, path-prefix routing, port 443 exposure
- **NATS running** , services already publish/subscribe, but the NATS server must be started separately; without it, BACEN does not receive SPI events
- **`/metrics` on DICT, STR and Auth** , only SPI and BACEN have Prometheus endpoints today
- **Auth middleware** , services currently accept any request; JWT should be validated on each protected endpoint
- **Containerized deploy** , `infra/podman/compose.yaml` is defined but untested
- **Backup** , snapshot of `.monolith` files with BorgBackup or similar
