#Requires -Version 5.1
<#
.SYNOPSIS
    Nerve PIX - Iniciar todos os servicos (Windows)

.DESCRIPTION
    Compila todos os servicos (Zig + Go) e abre cada um em uma
    janela cmd.exe separada. Depois abre o dashboard no browser.

.PARAMETER NoBuild
    Pular a etapa de compilacao (usa binarios ja existentes).

.PARAMETER Clean
    Apagar arquivos .monolith antes de iniciar (banco de dados zerado).

.EXAMPLE
    # Primeira vez - compila e inicia tudo:
    .\scripts\start-all.ps1

    # Reiniciar sem recompilar:
    .\scripts\start-all.ps1 -NoBuild

    # Zerar dados e reiniciar:
    .\scripts\start-all.ps1 -Clean
#>
param(
    [switch]$NoBuild,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Helpers de output
# ---------------------------------------------------------------------------
function Step { param($m) Write-Host "" ; Write-Host ">>> $m" -ForegroundColor Cyan }
function OK   { param($m) Write-Host "    OK   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "    !!   $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "    ERR  $m" -ForegroundColor Red; exit 1 }

function Test-Port {
    param([int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect("127.0.0.1", $Port)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

# Abre um servico em uma nova janela cmd.exe
function Launch-Service {
    param(
        [string]$Title,
        [string]$WorkDir,
        [string]$Exe,
        [hashtable]$EnvVars = @{}
    )
    $setCmds = ($EnvVars.GetEnumerator() |
        ForEach-Object { "set $($_.Key)=$($_.Value)" }) -join "& "

    if ($setCmds.Length -gt 0) {
        $inner = "$setCmds& `"$Exe`""
    } else {
        $inner = "`"$Exe`""
    }
    $cmdArgs = "/k title $Title & cd /d `"$WorkDir`" & $inner"
    Start-Process cmd.exe -ArgumentList $cmdArgs -WindowStyle Normal
    Start-Sleep -Milliseconds 400
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    Nerve PIX - Sistema de Pagamentos PIX"    -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 0. Pre-requisitos
# ---------------------------------------------------------------------------
Step "Verificando pre-requisitos..."

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Fail "zig nao encontrado no PATH. Instale em https://ziglang.org/download/"
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Fail "go nao encontrado no PATH. Instale em https://go.dev/dl/"
}

$zigVer = (zig version 2>&1)
$goVer  = ((go version 2>&1) -replace "go version ","")
OK "zig $zigVer"
OK "go  $goVer"

# ---------------------------------------------------------------------------
# 1. Limpar dados (opcional)
# ---------------------------------------------------------------------------
if ($Clean) {
    Step "Limpando dados antigos..."
    $dataRoot = Join-Path $Root "data"
    if (Test-Path $dataRoot) {
        Get-ChildItem -Path $dataRoot -Recurse -Filter "*.monolith" |
            Remove-Item -Force -ErrorAction SilentlyContinue
        OK "Arquivos .monolith removidos"
    } else {
        Write-Host "    (diretorio data/ ainda nao existe)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 2. Criar diretorios de dados
# ---------------------------------------------------------------------------
foreach ($d in @("data/spi", "data/dict", "data/str", "data/bacen")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Compilar
# ---------------------------------------------------------------------------
if (-not $NoBuild) {

    # Servicos Zig
    foreach ($svc in @("dict", "str", "spi", "bacen")) {
        Step "Compilando $svc (Zig)..."
        $svcDir = Join-Path $Root "services\$svc"
        Push-Location $svcDir
        $buildOut = zig build 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location
        if ($exitCode -ne 0) {
            Fail "Falha ao compilar $svc`n$buildOut"
        }
        OK "$svc -> zig-out\bin\$svc.exe"
    }

    # Servicos Go
    $goSvcs = @(
        [pscustomobject]@{ name="psp-alpha"; dir="services\psp-alpha"; bin="psp-alpha.exe" },
        [pscustomobject]@{ name="psp-beta";  dir="services\psp-beta";  bin="psp-beta.exe"  },
        [pscustomobject]@{ name="dashboard"; dir="services\dashboard"; bin="dashboard.exe"  }
    )
    foreach ($svc in $goSvcs) {
        Step "Compilando $($svc.name) (Go)..."
        $svcDir = Join-Path $Root $svc.dir
        Push-Location $svcDir
        $buildOut = go build -o $svc.bin ./... 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location
        if ($exitCode -ne 0) {
            Fail "Falha ao compilar $($svc.name)`n$buildOut"
        }
        OK "$($svc.name) -> $($svc.bin)"
    }

} else {
    Warn "-NoBuild: pulando compilacao, usando binarios existentes"
}

# ---------------------------------------------------------------------------
# 4. Verificar binarios existem
# ---------------------------------------------------------------------------
Step "Verificando binarios..."
$bDict   = Join-Path $Root "services\dict\zig-out\bin\dict.exe"
$bStr    = Join-Path $Root "services\str\zig-out\bin\str.exe"
$bSpi    = Join-Path $Root "services\spi\zig-out\bin\spi.exe"
$bBacen  = Join-Path $Root "services\bacen\zig-out\bin\bacen.exe"
$bAlpha  = Join-Path $Root "services\psp-alpha\psp-alpha.exe"
$bBeta   = Join-Path $Root "services\psp-beta\psp-beta.exe"
$bDash   = Join-Path $Root "services\dashboard\dashboard.exe"

foreach ($b in @($bDict, $bStr, $bSpi, $bBacen, $bAlpha, $bBeta, $bDash)) {
    if (-not (Test-Path $b)) {
        Fail "Binario nao encontrado: $b"
    }
}
OK "Todos os binarios encontrados"

# ---------------------------------------------------------------------------
# 5. Verificar portas ja em uso
# ---------------------------------------------------------------------------
Step "Verificando portas..."
$occupied = New-Object System.Collections.Generic.List[int]

$portNames = @{ 8081=("DICT"); 8082=("STR"); 8080=("SPI"); 8083=("BACEN"); 9080=("PSP-alpha"); 9090=("PSP-beta"); 3000=("Dashboard") }
foreach ($port in $portNames.Keys) {
    if (Test-Port $port) {
        $name = $portNames[$port]
        Warn "Porta $port ($name) ja esta em uso - servico nao sera reiniciado"
        $occupied.Add($port)
    }
}

# ---------------------------------------------------------------------------
# 6. Iniciar servicos
# ---------------------------------------------------------------------------
Step "Iniciando servicos..."

# DICT :8081
if (-not $occupied.Contains(8081)) {
    Launch-Service "DICT :8081" `
        (Join-Path $Root "data\dict") `
        $bDict `
        @{ DICT_PORT="8081"; DB_PATH="dict.monolith" }
    OK "DICT iniciado"
}

# STR :8082
if (-not $occupied.Contains(8082)) {
    Launch-Service "STR :8082" `
        (Join-Path $Root "data\str") `
        $bStr `
        @{ STR_PORT="8082"; DB_PATH="str.monolith" }
    OK "STR iniciado"
}

# BACEN :8083
if (-not $occupied.Contains(8083)) {
    Launch-Service "BACEN :8083" `
        (Join-Path $Root "data\bacen") `
        $bBacen `
        @{ BACEN_PORT="8083"; DB_PATH="bacen.monolith"; NATS_PORT="4222" }
    OK "BACEN iniciado"
}

# SPI :8080
if (-not $occupied.Contains(8080)) {
    Launch-Service "SPI :8080" `
        (Join-Path $Root "data\spi") `
        $bSpi `
        @{ SPI_PORT="8080"; DICT_PORT="8081"; STR_PORT="8082"; PSP_ALPHA_PORT="9080"; PSP_BETA_PORT="9090"; DB_PATH="spi.monolith" }
    OK "SPI iniciado"
}

# PSP-alpha :9080
if (-not $occupied.Contains(9080)) {
    Launch-Service "PSP-alpha :9080" `
        (Join-Path $Root "services\psp-alpha") `
        $bAlpha `
        @{ PSP_ALPHA_PORT="9080"; SPI_PORT="8080" }
    OK "PSP-alpha iniciado"
}

# PSP-beta :9090
if (-not $occupied.Contains(9090)) {
    Launch-Service "PSP-beta :9090" `
        (Join-Path $Root "services\psp-beta") `
        $bBeta `
        @{ PSP_BETA_PORT="9090" }
    OK "PSP-beta iniciado"
}

# Dashboard :3000
if (-not $occupied.Contains(3000)) {
    Launch-Service "Dashboard :3000" `
        (Join-Path $Root "services\dashboard") `
        $bDash `
        @{ DASHBOARD_PORT="3000"; SPI_PORT="8080"; DICT_PORT="8081"; STR_PORT="8082"; BACEN_PORT="8083"; PSP_ALPHA_PORT="9080"; PSP_BETA_PORT="9090" }
    OK "Dashboard iniciado"
}

# ---------------------------------------------------------------------------
# 7. Aguardar servicos subirem (max 20s)
# ---------------------------------------------------------------------------
Step "Aguardando servicos prontos..."
$required = @(8080, 8081, 8082, 8083, 9080, 9090, 3000)
$waited   = 0
$maxWait  = 20

while ($waited -lt $maxWait) {
    $allUp = $true
    foreach ($p in $required) {
        if (-not (Test-Port $p)) {
            $allUp = $false
            break
        }
    }
    if ($allUp) { break }
    Write-Host "    aguardando... ${waited}/${maxWait}s" -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
    $waited++
}

if ($waited -ge $maxWait) {
    Warn "Timeout aguardando servicos. Verifique as janelas abertas."
} else {
    OK "Todos os servicos prontos em ${waited}s"
}

# ---------------------------------------------------------------------------
# 8. Abrir browser no dashboard
# ---------------------------------------------------------------------------
Step "Abrindo browser..."
Start-Process "http://localhost:3000"
OK "http://localhost:3000"

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    Nerve PIX esta rodando!"                   -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "    Dashboard:  http://localhost:3000"  -ForegroundColor White
Write-Host "    SPI:        http://localhost:8080"  -ForegroundColor DarkGray
Write-Host "    DICT:       http://localhost:8081"  -ForegroundColor DarkGray
Write-Host "    STR:        http://localhost:8082"  -ForegroundColor DarkGray
Write-Host "    BACEN:      http://localhost:8083"  -ForegroundColor DarkGray
Write-Host "    PSP-alpha:  http://localhost:9080"  -ForegroundColor DarkGray
Write-Host "    PSP-beta:   http://localhost:9090"  -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Proximos passos:"                                         -ForegroundColor Yellow
Write-Host "    1. No browser: clique em [Seed Dados]"                 -ForegroundColor Yellow
Write-Host "    2. Defina o valor e clique [Enviar PIX]"               -ForegroundColor Yellow
Write-Host "    3. Observe os saldos de Alice e Bob"                   -ForegroundColor Yellow
Write-Host ""
Write-Host "    Benchmark (p50/p99 SLA):"                              -ForegroundColor Cyan
Write-Host "    cd scripts\bench"                                       -ForegroundColor DarkGray
Write-Host "    go run . -n 1000 -c 20          # 1.000 txs, 20 workers" -ForegroundColor DarkGray
Write-Host "    go run . -n 5000 -c 50          # 5.000 txs, 50 workers" -ForegroundColor DarkGray
Write-Host "    go run . -n 1000 -c 20 -no-seed # reusar dados existentes" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Para parar: feche as janelas dos servicos."             -ForegroundColor DarkGray
Write-Host ""
