#Requires -Version 5.1
<#
.SYNOPSIS
    Nerve PIX - Iniciar stack de observabilidade (VictoriaMetrics + Grafana)

.DESCRIPTION
    Requer que os servicos Nerve ja estejam rodando (start-all.ps1).
    Cria um SSH reverse tunnel para expor as portas dos servicos dentro
    do Podman machine, depois inicia VictoriaMetrics e Grafana em containers.

    Acesso ao Grafana: http://localhost:3000
    Dashboard:         http://localhost:3000/d/nerve-pix/nerve-pix
    Usuario/senha:     admin / nerve123

.EXAMPLE
    .\scripts\start-observability.ps1

.NOTES
    Requer Podman Desktop com podman-machine-default rodando.
    Requer que os servicos Nerve estejam no ar (start-all.ps1 primeiro).
#>

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

function Step { param($m) Write-Host "" ; Write-Host ">>> $m" -ForegroundColor Cyan }
function OK   { param($m) Write-Host "    OK   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "    !!   $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "    ERR  $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Configuracoes
# ---------------------------------------------------------------------------
$SshKey    = "$env:USERPROFILE\.local\share\containers\podman\machine\machine"
$SshPort   = 53900
$SshUser   = "user"
$SshHost   = "localhost"

# Mapeamento: porta no Podman machine (18xxx) -> porta Windows real
$PortMap   = @{
    18080 = 8080  # SPI
    18081 = 8081  # DICT
    18082 = 8082  # STR
    18083 = 8083  # BACEN
    18084 = 8084  # Auth
    19080 = 9080  # PSP-alpha
    19090 = 9090  # PSP-beta
    18222 = 8222  # NATS
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    Nerve PIX - Observabilidade"              -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Verificar que servicos Nerve estao no ar
# ---------------------------------------------------------------------------
Step "Verificando servicos Nerve..."
$svcCheck = @(8080, 8081, 8082, 8083)
$allUp = $true
foreach ($p in $svcCheck) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try { $tcp.Connect("127.0.0.1", $p); $tcp.Close() }
    catch { $allUp = $false; Warn "Porta $p nao responde — execute start-all.ps1 primeiro" }
}
if (-not $allUp) { Fail "Servicos Nerve nao estao rodando. Execute: .\scripts\start-all.ps1 -NoBuild" }
OK "Todos os servicos respondendo"

# ---------------------------------------------------------------------------
# 2. Verificar Podman machine
# ---------------------------------------------------------------------------
Step "Verificando Podman machine..."
$machineStatus = wsl -d podman-machine-default -- echo "ok" 2>&1
if ($machineStatus -ne "ok") {
    Fail "podman-machine-default nao esta rodando. Abra Podman Desktop e inicie a machine."
}
OK "podman-machine-default rodando"

# ---------------------------------------------------------------------------
# 3. Verificar chave SSH
# ---------------------------------------------------------------------------
if (-not (Test-Path $SshKey)) {
    Fail "Chave SSH nao encontrada: $SshKey"
}
OK "Chave SSH encontrada"

# ---------------------------------------------------------------------------
# 4. Iniciar SSH reverse tunnel (portas offset 18xxx para evitar WSL2 proxy)
# ---------------------------------------------------------------------------
Step "Iniciando SSH reverse tunnel..."

# Mata tunnel antigo se existir
Get-Process -Name "ssh" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$rfwd = ($PortMap.GetEnumerator() | ForEach-Object { "-R $($_.Key):127.0.0.1:$($_.Value)" }) -join " "
$sshArgs = "-N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes " +
           "-i `"$SshKey`" -p $SshPort $rfwd $SshUser@$SshHost"

$proc = Start-Process "ssh" -ArgumentList $sshArgs -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 3

if ($proc.HasExited) {
    Fail "SSH tunnel falhou ao iniciar (exit code: $($proc.ExitCode))"
}
OK "SSH tunnel PID $($proc.Id) — portas 18080-19090 ativas no Podman machine"

# ---------------------------------------------------------------------------
# 5. Iniciar VictoriaMetrics
# ---------------------------------------------------------------------------
Step "Iniciando VictoriaMetrics..."

$scrapeYaml = "$Root\infra\victoriametrics\scrape.yaml"
$scrapePath = "/mnt/e" + ($Root -replace "^E:", "" -replace "\\", "/") + "/infra/victoriametrics/scrape.yaml"

# Para e remove container antigo
wsl -d podman-machine-default -- sudo podman stop nerve-victoriametrics 2>$null
wsl -d podman-machine-default -- sudo podman rm nerve-victoriametrics 2>$null

$vmArgs = "run -d --name nerve-victoriametrics --network=host " +
          "-v vm-data:/victoria-metrics-data " +
          "-v `"${scrapePath}:/etc/vm/scrape.yaml:ro`" " +
          "victoriametrics/victoria-metrics:latest " +
          "--promscrape.config=/etc/vm/scrape.yaml " +
          "--storageDataPath=/victoria-metrics-data"

$env:MSYS_NO_PATHCONV = "1"
wsl -d podman-machine-default -- sudo podman $vmArgs.Split(" ") 2>&1 | Out-Null

Start-Sleep -Seconds 3

$vmHealth = wsl -d podman-machine-default -- sudo podman exec nerve-victoriametrics `
    wget -qO- http://localhost:8428/health 2>&1
if ($vmHealth -ne "OK") {
    Warn "VictoriaMetrics pode nao ter subido corretamente: $vmHealth"
} else {
    OK "VictoriaMetrics saudavel em :8428"
}

# ---------------------------------------------------------------------------
# 6. Iniciar Grafana
# ---------------------------------------------------------------------------
Step "Iniciando Grafana..."

$dsPath   = "/mnt/e" + ($Root -replace "^E:", "" -replace "\\", "/") + "/infra/grafana/datasources.yaml"
$dashPath = "/mnt/e" + ($Root -replace "^E:", "" -replace "\\", "/") + "/infra/grafana/dashboards"

wsl -d podman-machine-default -- sudo podman stop nerve-grafana 2>$null
wsl -d podman-machine-default -- sudo podman rm nerve-grafana 2>$null

$grafanaArgs = "run -d --name nerve-grafana --network=host " +
               "-e GF_SECURITY_ADMIN_PASSWORD=nerve123 " +
               "-e GF_AUTH_ANONYMOUS_ENABLED=true " +
               "-e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer " +
               "-v grafana-data:/var/lib/grafana " +
               "-v `"${dashPath}:/etc/grafana/provisioning/dashboards:ro`" " +
               "-v `"${dsPath}:/etc/grafana/provisioning/datasources/ds.yaml:ro`" " +
               "grafana/grafana:latest"

wsl -d podman-machine-default -- sudo podman $grafanaArgs.Split(" ") 2>&1 | Out-Null

Start-Sleep -Seconds 5

$grafanaHealth = wsl -d podman-machine-default -- sudo podman exec nerve-grafana `
    wget -qO- http://localhost:3000/api/health 2>&1
if ($grafanaHealth -match '"database":"ok"') {
    OK "Grafana saudavel em :3000"
} else {
    Warn "Grafana pode nao ter subido ainda: $grafanaHealth"
}

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    Observabilidade ativa!"                    -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "    Grafana:           http://localhost:3000" -ForegroundColor White
Write-Host "    Dashboard PIX:     http://localhost:3000/d/nerve-pix/nerve-pix" -ForegroundColor White
Write-Host "    Login:             admin / nerve123" -ForegroundColor DarkGray
Write-Host "    VictoriaMetrics:   http://localhost:8428" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Metricas coletadas de:" -ForegroundColor Yellow
Write-Host "      SPI, BACEN, PSP-alpha, PSP-beta" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Obs: DICT/STR/Auth nao expõem /metrics (sem implementacao Prometheus)" -ForegroundColor DarkGray
Write-Host ""

Start-Process "http://localhost:3000/d/nerve-pix/nerve-pix"
