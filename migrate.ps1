# ==============================================================================
# migrate.ps1 — Executor da migração GCP E2 → N4 (Windows PowerShell)
# Compatível com: Windows PowerShell 5.1+ e PowerShell Core 7+
#
# Uso:
#   .\migrate.ps1                → executa com confirmação interativa
#   .\migrate.ps1 -AutoApprove   → executa sem confirmação (CI/CD)
#   .\migrate.ps1 -DryRun        → apenas terraform plan, sem apply
#
# Pré-requisitos:
#   - terraform >= 1.5.0  (no PATH)
#   - gcloud              (no PATH, autenticado com Compute Instance Admin)
#   - curl                (nativo no Windows 10+)
#   - Git for Windows     (bash necessário para os provisioners Terraform)
#   - terraform.tfvars preenchido
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Host "Uso: .\migrate.ps1 [-AutoApprove] [-DryRun]"
    Write-Host "  -AutoApprove  Executa sem confirmação interativa"
    Write-Host "  -DryRun       Apenas terraform plan, sem apply"
    exit 0
}

# ------------------------------------------------------------------------------
# Helpers de output colorido
# ------------------------------------------------------------------------------
function Write-Header($title) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Blue }
function Write-Ok($msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[AVISO] $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERRO]  $msg" -ForegroundColor Red }

# ------------------------------------------------------------------------------
# Lê um valor do terraform.tfvars
# ------------------------------------------------------------------------------
function Get-TfVar($name) {
    if (-not (Test-Path "terraform.tfvars")) { return "" }
    $line = Get-Content "terraform.tfvars" |
        Where-Object { $_ -match "^\s*$name\s*=" } |
        Select-Object -First 1
    if (-not $line) { return "" }
    # Remove key=, aspas, espaços e comentários inline
    return ($line -replace "^[^=]+=\s*", "" `
                  -replace '"', "" `
                  -replace "'", "" `
                  -replace "\s*#.*$", "").Trim()
}

# ------------------------------------------------------------------------------
# Envia mensagem para o Telegram (falha silenciosa)
# ------------------------------------------------------------------------------
function Send-Telegram($token, $chatId, $message) {
    if ([string]::IsNullOrEmpty($token) -or $token -eq "SEU-BOT-TOKEN-AQUI") { return }
    try {
        $body = @{
            chat_id    = $chatId
            text       = $message
            parse_mode = "HTML"
        }
        Invoke-RestMethod `
            -Uri     "https://api.telegram.org/bot${token}/sendMessage" `
            -Method  Post `
            -Body    $body `
            -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Falha silenciosa: notificação não deve interromper a migração
    }
}

# ------------------------------------------------------------------------------
# ETAPA 1 — Verificação de pré-requisitos
# ------------------------------------------------------------------------------
Write-Header "Verificando Pré-requisitos"

$missing = @()
foreach ($tool in @("terraform", "gcloud", "curl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $missing += $tool
    }
}
if ($missing.Count -gt 0) {
    Write-Err "Ferramentas não encontradas: $($missing -join ', ')"
    Write-Err "Instale as ferramentas e adicione ao PATH antes de continuar."
    exit 1
}
Write-Ok "terraform, gcloud e curl encontrados."

# Verifica bash (necessário para os provisioners local-exec do Terraform)
$bashPaths = @(
    "bash",
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe"
)
$bashFound = $false
foreach ($p in $bashPaths) {
    if (Get-Command $p -ErrorAction SilentlyContinue) { $bashFound = $true; break }
}
if (-not $bashFound) {
    Write-Warn "bash não encontrado no PATH."
    Write-Warn "Os provisioners Terraform (notificações + gcloud) requerem bash."
    Write-Warn "Instale o Git for Windows: https://git-scm.com/download/win"
    Write-Warn "Continuando mesmo assim — os provisioners poderão falhar."
} else {
    Write-Ok "bash encontrado."
}

if (-not (Test-Path "terraform.tfvars")) {
    Write-Err "Arquivo terraform.tfvars não encontrado."
    Write-Err "Preencha o template terraform.tfvars com os valores do seu ambiente."
    exit 1
}
Write-Ok "terraform.tfvars encontrado."

# Carrega variáveis
$telegramToken = Get-TfVar "telegram_bot_token"
$telegramChat  = Get-TfVar "telegram_chat_id"
$projectId     = Get-TfVar "project_id"
$sourceVm      = Get-TfVar "source_instance_name"
$zone          = Get-TfVar "zone"
$targetVm      = "$sourceVm-n4"

if ([string]::IsNullOrEmpty($projectId) -or $projectId -eq "SEU-PROJECT-ID") {
    Write-Err "project_id não configurado em terraform.tfvars."
    exit 1
}
if ([string]::IsNullOrEmpty($telegramToken) -or $telegramToken -eq "SEU-BOT-TOKEN-AQUI") {
    Write-Warn "Token do Telegram não configurado — notificações via script desabilitadas."
    $telegramToken = ""
}
Write-Ok "Configuração carregada."

$activeAccount = (gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null | Select-Object -First 1)
Write-Info "Conta GCP ativa: $activeAccount"

# ------------------------------------------------------------------------------
# ETAPA 2 — Terraform Init
# ------------------------------------------------------------------------------
Write-Header "Terraform Init"
terraform init
if ($LASTEXITCODE -ne 0) { Write-Err "terraform init falhou."; exit 1 }
Write-Ok "Providers instalados e backend inicializado."

# ------------------------------------------------------------------------------
# ETAPA 3 — Terraform Plan
# ------------------------------------------------------------------------------
Write-Header "Terraform Plan"
terraform plan -out=tfplan
if ($LASTEXITCODE -ne 0) { Write-Err "terraform plan falhou."; exit 1 }
Write-Ok "Plano gerado e salvo em 'tfplan'."

if ($DryRun) {
    Write-Info "Modo -DryRun: encerrando sem aplicar."
    exit 0
}

# ------------------------------------------------------------------------------
# ETAPA 4 — Confirmação
# ------------------------------------------------------------------------------
if (-not $AutoApprove) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║           ATENÇÃO — LEIA ANTES           ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Esta operação irá:"
    Write-Host "  1. Criar snapshot do disco da VM E2:  $sourceVm"
    Write-Host "  2. Criar disco Hyperdisk-Balanced"
    Write-Host "  3. PARAR a VM E2 e desvincular o IP externo  <- downtime"
    Write-Host "  4. Criar nova VM N4:  $targetVm  (com o mesmo IP)"
    Write-Host ""
    Write-Host "  Projeto : $projectId"
    Write-Host "  Zona    : $zone"
    Write-Host ""
    $confirm = Read-Host "  Digite 'sim' para confirmar a execução"
    if ($confirm -ne "sim") {
        Write-Info "Operação cancelada pelo usuário."
        exit 0
    }
}

# ------------------------------------------------------------------------------
# ETAPA 5 — Terraform Apply
# ------------------------------------------------------------------------------
Write-Header "Executando Migração"

$startTime = Get-Date
$startHora = $startTime.ToString("dd/MM/yyyy HH:mm:ss")
Write-Info "Início: $startHora"

try {
    terraform apply tfplan
    if ($LASTEXITCODE -ne 0) { throw "terraform apply retornou código $LASTEXITCODE" }
}
catch {
    $hora = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")
    Write-Host ""
    Write-Err "terraform apply falhou: $_"
    Write-Err "Verifique os logs acima para detalhes."
    Write-Err "ATENÇÃO: A VM E2 pode ter sido parada — verifique o Console GCP."

    Send-Telegram $telegramToken $telegramChat @"
❌ <b>ERRO NA MIGRAÇÃO</b>
━━━━━━━━━━━━━━━━━━━━━━━━
🔴 Projeto  : <code>$projectId</code>
🔴 VM Origem: <code>$sourceVm</code>
💀 Erro     : <code>$_</code>
⏱  Horário  : <b>$hora</b>

⚠️ Verifique os logs do Terraform.
⚠️ A VM E2 pode ter sido parada — confirme no Console GCP.
"@
    exit 1
}

$endTime  = Get-Date
$duration = $endTime - $startTime
$durStr   = "{0}m {1}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds

Write-Host ""
Write-Ok "terraform apply concluído em $durStr."

# ------------------------------------------------------------------------------
# ETAPA 6 — Exibe resultados
# ------------------------------------------------------------------------------
Write-Header "Resultados da Migração"
terraform output

$ipExterno = (terraform output -raw nova_instancia_ip_externo 2>$null) ?? "N/A"
$ipInterno = (terraform output -raw nova_instancia_ip_interno 2>$null) ?? "N/A"

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║      MIGRAÇÃO CONCLUÍDA COM SUCESSO      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  VM N4       : $targetVm"
Write-Host "  IP Externo  : $ipExterno"
Write-Host "  IP Interno  : $ipInterno"
Write-Host "  Duração     : $durStr"
Write-Host "  Projeto     : $projectId"
Write-Host ""
Write-Host "Próximos passos (manuais):" -ForegroundColor Cyan
Write-Host "  1. Valide a VM N4 — acesso SSH, servicos, aplicação"
Write-Host "  2. Após validação, exclua a VM E2 pelo Console GCP"
Write-Host "  3. Após confirmar os dados, exclua o disco PD original"
Write-Host ""
