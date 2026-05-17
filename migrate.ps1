# ==============================================================================
# migrate.ps1 — Executor da migração GCP (qualquer família)
# Compatível com: Windows PowerShell 5.1+ e PowerShell Core 7+
#
# Uso:
#   .\migrate.ps1              → executa com confirmação interativa
#   .\migrate.ps1 -AutoApprove → executa sem pedir confirmação (CI/CD)
#   .\migrate.ps1 -DryRun      → apenas terraform plan, sem apply
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
$script:Resuming = $false

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
    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Blue }
function Write-Ok($msg)   { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[AVISO] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERRO]  $msg" -ForegroundColor Red }

# ------------------------------------------------------------------------------
# Lê um valor do terraform.tfvars
# ------------------------------------------------------------------------------
function Get-TfVar($name) {
    if (-not (Test-Path "terraform.tfvars")) { return "" }
    $line = Get-Content "terraform.tfvars" |
        Where-Object { $_ -match "^\s*$name\s*=" } |
        Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -replace "^[^=]+=\s*", "" `
                  -replace '"', "" `
                  -replace "'", "" `
                  -replace "\s*#.*$", "").Trim()
}

# ------------------------------------------------------------------------------
# Envia mensagem para o Telegram (falha silenciosa)
# ------------------------------------------------------------------------------
function Send-Telegram($token, $chatId, $message) {
    if ([string]::IsNullOrEmpty($token) -or
        $token -eq "SEU-BOT-TOKEN-AQUI" -or
        $token -eq "TOKEN_AQUI") { return }
    try {
        $body = @{
            chat_id    = $chatId
            text       = $message
            parse_mode = "HTML"
        }
        Invoke-RestMethod `
            -Uri    "https://api.telegram.org/bot${token}/sendMessage" `
            -Method Post `
            -Body   $body `
            -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

# ------------------------------------------------------------------------------
# Resolve o tipo de disco — espelha lógica do locals.tf
# ------------------------------------------------------------------------------
function Resolve-DiskType($family, $diskTypeVar) {
    if (-not [string]::IsNullOrEmpty($diskTypeVar)) { return $diskTypeVar }
    switch ($family) {
        { $_ -in "n4","c3","c3d","m3" } { return "hyperdisk-balanced" }
        default { return "pd-balanced" }
    }
}

# Retorna $true se GVNIC é obrigatório para a família
function Test-RequiresGvnic($family) {
    return $family -in @("n4","c3","c3d","t2a","m3")
}

# Retorna $true se GVNIC é suportado (mas não obrigatório)
function Test-SupportsGvnic($family) {
    return $family -notin @("m1","m2")
}

# ------------------------------------------------------------------------------
# Consulta vCPUs e RAM reais via API GCP (preciso para custom e qualquer tipo)
# ------------------------------------------------------------------------------
function Get-MachineSpecs($machineType, $zone, $project) {
    try {
        $raw = gcloud compute machine-types describe $machineType `
            --zone=$zone --project=$project `
            --format="csv[no-heading](guestCpus,memoryMb)" 2>$null
        if ($raw) {
            $parts  = $raw.Trim().Split(",")
            $vcpus  = [int]$parts[0]
            $ramMb  = [int]$parts[1]
            $ramGb  = [math]::Round($ramMb / 1024)
            return @{ vCPUs = $vcpus; RamGb = $ramGb }
        }
    } catch { }

    # Fallback para custom: family-custom-vcpus-mem_mb
    if ($machineType -match "-custom-(\d+)-(\d+)$") {
        return @{
            vCPUs = [int]$Matches[1]
            RamGb = [math]::Round([int]$Matches[2] / 1024)
        }
    }
    return @{ vCPUs = "?"; RamGb = "?" }
}

# ==============================================================================
# ETAPA 1 — Verificação de pré-requisitos
# ==============================================================================
Write-Header "Verificando Pré-requisitos"

$missing = @()
foreach ($tool in @("terraform","gcloud","curl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
}
if ($missing.Count -gt 0) {
    Write-Err "Ferramentas não encontradas: $($missing -join ', ')"
    Write-Err "Instale as ferramentas listadas e adicione ao PATH antes de continuar."
    exit 1
}
Write-Ok "terraform, gcloud e curl encontrados."

# Verifica bash (necessário para os provisioners local-exec do Terraform)
$bashFound = $false
foreach ($p in @("bash","C:\Program Files\Git\bin\bash.exe","C:\Program Files\Git\usr\bin\bash.exe")) {
    if (Get-Command $p -ErrorAction SilentlyContinue) { $bashFound = $true; break }
}
if (-not $bashFound) {
    Write-Warn "bash não encontrado no PATH."
    Write-Warn "Os provisioners Terraform (notificações + gcloud) requerem bash."
    Write-Warn "Instale o Git for Windows: https://git-scm.com/download/win"
    Write-Warn "Continuando — os provisioners poderão falhar durante o apply."
} else {
    Write-Ok "bash encontrado."
}

if (-not (Test-Path "terraform.tfvars")) {
    Write-Err "Arquivo terraform.tfvars não encontrado."
    Write-Err "Copie terraform.tfvars.example e preencha com os valores do seu ambiente."
    exit 1
}
Write-Ok "terraform.tfvars encontrado."

# Carrega todas as variáveis necessárias
$TelegramToken  = Get-TfVar "telegram_bot_token"
$TelegramChat   = Get-TfVar "telegram_chat_id"
$ProjectId      = Get-TfVar "project_id"
$Region         = Get-TfVar "region"
$Zone           = Get-TfVar "zone"
$SourceVm       = Get-TfVar "source_instance_name"
$FinalVmName    = Get-TfVar "final_instance_name"
$TargetFamily   = Get-TfVar "target_machine_family"
$TargetDiskVar  = Get-TfVar "target_disk_type"
$TargetVcpus    = Get-TfVar "target_vcpus"
$TargetMemGb    = Get-TfVar "target_memory_gb"
$MtOverride     = Get-TfVar "machine_type_override"
$ChangeDiskSize = Get-TfVar "change_disk_size"
$TargetDiskSize = Get-TfVar "target_disk_size"

if ([string]::IsNullOrEmpty($ProjectId) -or $ProjectId -eq "SEU-PROJECT-ID") {
    Write-Err "project_id não configurado em terraform.tfvars."
    exit 1
}
if ([string]::IsNullOrEmpty($TargetFamily)) {
    Write-Err "target_machine_family não configurado em terraform.tfvars."
    exit 1
}
if ([string]::IsNullOrEmpty($TelegramToken) -or
    $TelegramToken -eq "TOKEN_AQUI" -or $TelegramToken -eq "SEU-BOT-TOKEN-AQUI") {
    Write-Warn "Token do Telegram não configurado — notificações de erro via script desabilitadas."
    $TelegramToken = ""
}
Write-Ok "Configuração carregada do terraform.tfvars."

$activeAccount = (gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null |
    Select-Object -First 1)
Write-Info "Conta GCP ativa: $activeAccount"

# ------------------------------------------------------------------------------
# Detecção de downgrade de disco
# Se change_disk_size = true e target_disk_size < tamanho atual do disco,
# verifica se o filesystem já foi reduzido. Se não, oferece rodar
# .\downgrade_boot_disk.ps1 automaticamente.
# ------------------------------------------------------------------------------
$TargetDiskSizeInt = 0
if ($ChangeDiskSize -eq "true" -and [int]::TryParse($TargetDiskSize, [ref]$TargetDiskSizeInt) -and $TargetDiskSizeInt -gt 0) {
    $currentDiskSize = [int](gcloud compute disks describe $SourceVm `
        --zone=$Zone --project=$ProjectId `
        --format="value(sizeGb)" 2>$null)

    if ($TargetDiskSizeInt -lt $currentDiskSize) {
        Write-Info "Detectado downgrade de disco: ${currentDiskSize} GB → ${TargetDiskSizeInt} GB"

        # Verifica se o filesystem já foi reduzido (tenta ler via SSH)
        $fsAlreadyReduced = $false
        $vmStatus = gcloud compute instances describe $SourceVm `
            --zone=$Zone --project=$ProjectId --format="value(status)" 2>$null

        if ($vmStatus -eq "RUNNING") {
            $fsSize = gcloud compute ssh $SourceVm --zone=$Zone --project=$ProjectId `
                --command='df -B1G --output=size / | tail -1 | tr -d " " || echo 0' `
                --quiet 2>$null
            $fsSizeInt = 0
            if ([int]::TryParse($fsSize, [ref]$fsSizeInt) -and $fsSizeInt -le $TargetDiskSizeInt) {
                $fsAlreadyReduced = $true
            }
        }

        if ($fsAlreadyReduced) {
            Write-Ok "Filesystem já reduzido (${fsSizeInt}G ≤ ${TargetDiskSizeInt}G). Prosseguindo com a migração."
        } else {
            Write-Warn "O filesystem do disco de boot AINDA NÃO foi reduzido para caber em ${TargetDiskSizeInt} GB."
            Write-Warn "A migração criará um disco de ${TargetDiskSizeInt} GB a partir do snapshot atual."
            Write-Warn "Se o filesystem ocupar mais que ${TargetDiskSizeInt} GB, a nova VM NÃO inicializará."
            Write-Host ""
            Write-Host "  Deseja rodar o script de downgrade automático agora?" -ForegroundColor White
            Write-Host "  Ele irá:" -ForegroundColor White
            Write-Host "    • Criar snapshot de segurança" -ForegroundColor White
            Write-Host "    • Parar a VM, criar VM temporária, reduzir FS+partição" -ForegroundColor White
            Write-Host "    • Devolver o disco e apagar a VM temporária" -ForegroundColor White
            Write-Host "    • Depois disso a migração prossegue normalmente" -ForegroundColor White
            Write-Host ""
            Write-Host "  Requisitos: Linux + ext4 + partição única /dev/sda1" -ForegroundColor Yellow
            Write-Host "  Fora disso: responda 'nao' e siga o procedimento manual no README" -ForegroundColor Yellow
            Write-Host ""

            if ($AutoApprove) {
                $runDowngrade = $true
            } else {
                $resp = Read-Host "Rodar downgrade automático agora? (sim/nao)"
                $runDowngrade = ($resp -eq "sim")
            }

            if ($runDowngrade) {
                if (-not (Test-Path ".\downgrade_boot_disk.ps1")) {
                    Write-Err "Script .\downgrade_boot_disk.ps1 não encontrado."
                    exit 1
                }
                Write-Info "Executando .\downgrade_boot_disk.ps1..."
                Write-Host ""
                if ($DryRun) {
                    Write-Warn "DRY-RUN: pulando execução do downgrade."
                } else {
                    if ($AutoApprove) {
                        & .\downgrade_boot_disk.ps1 -AutoApprove
                    } else {
                        & .\downgrade_boot_disk.ps1
                    }
                    if ($LASTEXITCODE -ne 0) {
                        Write-Err "downgrade_boot_disk.ps1 falhou (exit code: $LASTEXITCODE)."
                        Write-Err "Corrija o problema e execute novamente o migrate.ps1."
                        exit 1
                    }
                    Write-Ok "Downgrade concluído. Prosseguindo com a migração."
                }
            } else {
                Write-Warn "Downgrade não executado. A migração continuará, mas o disco pode não caber."
                if (-not $AutoApprove) {
                    Write-Host ""
                    $resp2 = Read-Host "Tem certeza que deseja prosseguir sem reduzir o filesystem? (sim/nao)"
                    if ($resp2 -ne "sim") { Write-Err "Abortado pelo usuário."; exit 1 }
                }
            }
        }
    } elseif ($TargetDiskSizeInt -gt $currentDiskSize) {
        Write-Info "Detectado upgrade de disco: ${currentDiskSize} GB → ${TargetDiskSizeInt} GB"
        Write-Info "O upgrade é seguro e será feito automaticamente pelo Terraform."
    }
}

# ==============================================================================
# ETAPA 1.5 — Consulta specs da VM de origem via API GCP
# ==============================================================================
Write-Header "Consultando VM de Origem"

$sourceVmCsv = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="csv[no-heading](machineType,status)" 2>$null

if ([string]::IsNullOrEmpty($sourceVmCsv)) {
    Write-Err "VM de origem '$SourceVm' não encontrada no projeto '$ProjectId', zona '$Zone'."
    exit 1
}

$csvParts          = $sourceVmCsv.Trim().Split(",")
$SourceMachineType = ($csvParts[0] -split "/")[-1]
$SourceStatus      = $csvParts[1]
$SourceFamily      = ($SourceMachineType -split "-")[0]

Write-Info "Consultando specs da máquina '$SourceMachineType' via API GCP..."
$srcSpecs   = Get-MachineSpecs $SourceMachineType $Zone $ProjectId
$SrcVcpus   = $srcSpecs.vCPUs
$SrcRamGb   = $srcSpecs.RamGb

# Disco de boot
$bootDiskUrl  = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(disks[0].source)" 2>$null
$BootDiskName = ($bootDiskUrl -split "/")[-1]

if (-not [string]::IsNullOrEmpty($BootDiskName)) {
    $SrcDiskType = (gcloud compute disks describe $BootDiskName `
        --zone=$Zone --project=$ProjectId `
        --format="value(type)" 2>$null) -replace ".*/", ""
    $SrcDiskSize = gcloud compute disks describe $BootDiskName `
        --zone=$Zone --project=$ProjectId `
        --format="value(sizeGb)" 2>$null
} else {
    $SrcDiskType = "unknown"
    $SrcDiskSize = "unknown"
}

Write-Ok "VM de origem: $SourceVm ($SourceMachineType) — $SourceStatus"
Write-Ok "vCPUs: $SrcVcpus | RAM: ${SrcRamGb}GB | Disco: $SrcDiskType (${SrcDiskSize}GB)"

# ==============================================================================
# ETAPA 1.6 — Resolve configuração de destino
# ==============================================================================
$ResolvedDiskType = Resolve-DiskType $TargetFamily $TargetDiskVar
$NeedsGvnic       = Test-RequiresGvnic $TargetFamily
$SupportsGvnic    = Test-SupportsGvnic $TargetFamily

$CreateNewDisk = ($SrcDiskType -ne $ResolvedDiskType)

if ($NeedsGvnic)       { $TargetNic = "GVNIC (obrigatorio)" }
elseif ($SupportsGvnic){ $TargetNic = "VIRTIO_NET (GVNIC opcional)" }
else                   { $TargetNic = "VIRTIO_NET" }

if ($CreateNewDisk) { $DiskAction = "CRIAR NOVO a partir de snapshot" }
else               { $DiskAction = "REUTILIZADO (snapshot criado para seguranca)" }

if (-not [string]::IsNullOrEmpty($FinalVmName)) {
    $TargetVm = $FinalVmName
} else {
    $TargetVm = "$SourceVm-$TargetFamily"
}
$NewDiskName  = "$SourceVm-$ResolvedDiskType"
$SnapshotName = "$SourceVm-migration-snapshot"

# ==============================================================================
# ETAPA 1.7 — Validações e resumo pré-plan
# ==============================================================================
$Warnings = @()

if ($TargetVcpus -and $SrcVcpus -and $TargetVcpus -ne "$SrcVcpus") {
    $Warnings += "vCPUs diferente (origem: $SrcVcpus, destino: $TargetVcpus)"
}
if ($TargetMemGb -and $SrcRamGb -and $TargetMemGb -ne "$SrcRamGb") {
    $Warnings += "RAM diferente (origem: ${SrcRamGb}GB, destino: ${TargetMemGb}GB)"
}
if ($NeedsGvnic -and ($SourceFamily -notin @("n4","c3","c3d","t2a","m3"))) {
    $Warnings += "NIC muda para GVNIC — certifique-se de que o SO suporta"
}
if ($TargetFamily -eq "t2a") {
    $Warnings += "T2A usa arquitetura ARM — o SO deve ser compativel"
}

Write-Header "RESUMO DA MIGRAÇÃO"
Write-Host "  ORIGEM                               DESTINO" -ForegroundColor White
Write-Host "  ─────────────────────────────────    ─────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Família  : " -NoNewline; Write-Host $SourceFamily -ForegroundColor Cyan -NoNewline
Write-Host "                       Família  : " -NoNewline; Write-Host $TargetFamily -ForegroundColor Green
Write-Host "  Tipo     : " -NoNewline; Write-Host $SourceMachineType -ForegroundColor Cyan
Write-Host "  vCPUs    : " -NoNewline; Write-Host $SrcVcpus -ForegroundColor Cyan -NoNewline
Write-Host "                        vCPUs    : " -NoNewline; Write-Host ($TargetVcpus -replace "^$","?") -ForegroundColor Green
Write-Host "  RAM      : " -NoNewline; Write-Host "${SrcRamGb} GB" -ForegroundColor Cyan -NoNewline
Write-Host "                     RAM      : " -NoNewline; Write-Host "$(if ($TargetMemGb) { "${TargetMemGb} GB" } else { '?' })" -ForegroundColor Green
Write-Host "  Disco    : " -NoNewline; Write-Host $SrcDiskType -ForegroundColor Cyan -NoNewline
Write-Host "               Disco    : " -NoNewline; Write-Host $ResolvedDiskType -ForegroundColor Green
Write-Host "  Tamanho  : " -NoNewline; Write-Host "${SrcDiskSize} GB" -ForegroundColor Cyan -NoNewline
Write-Host "                    Ação     : " -NoNewline; Write-Host $DiskAction -ForegroundColor Green
Write-Host "  NIC      : " -NoNewline; Write-Host "VIRTIO_NET" -ForegroundColor Cyan -NoNewline
Write-Host "               NIC      : " -NoNewline; Write-Host $TargetNic -ForegroundColor Green
Write-Host ""

Write-Host "  Validações:" -ForegroundColor White
if ($Warnings.Count -eq 0) {
    Write-Host "  ✓ vCPUs/RAM compatíveis" -ForegroundColor Green
    Write-Host "  ✓ Disco e NIC sem restrições adicionais" -ForegroundColor Green
} else {
    foreach ($w in $Warnings) {
        Write-Host "  ⚠ $w" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "  Downtime: " -NoNewline; Write-Host "sim (VM será parada)" -ForegroundColor Red
Write-Host "  Projeto : $ProjectId"
Write-Host "  Zona    : $Zone"
Write-Host ""

# ==============================================================================
# Detecção de execução anterior incompleta
# ==============================================================================
function Test-IncompleteRun {
    $hasState     = Test-Path "terraform.tfstate"
    $hasTfplan    = Test-Path "tfplan"
    $hasSnapshot  = $false
    $hasDisk      = $false
    $hasTargetVm  = $false

    # Verifica recursos existentes no GCP
    $null = gcloud compute snapshots describe $SnapshotName `
        --project=$ProjectId 2>$null
    if ($LASTEXITCODE -eq 0) { $hasSnapshot = $true }

    $null = gcloud compute disks describe $NewDiskName `
        --zone=$Zone --project=$ProjectId 2>$null
    if ($LASTEXITCODE -eq 0) { $hasDisk = $true }

    $null = gcloud compute instances describe $TargetVm `
        --zone=$Zone --project=$ProjectId 2>$null
    if ($LASTEXITCODE -eq 0) { $hasTargetVm = $true }

    # VM de destino já existe — migração já foi concluída
    if ($hasTargetVm) {
        $vmStatus = gcloud compute instances describe $TargetVm `
            --zone=$Zone --project=$ProjectId `
            --format="value(status)" 2>$null
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║       MIGRAÇÃO JÁ FOI CONCLUÍDA ANTERIORMENTE             ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        Write-Host "  VM Destino  : $TargetVm"
        Write-Host "  Status      : $vmStatus"
        Write-Host "  Projeto     : $ProjectId"
        Write-Host ""
        Write-Host "  Nenhuma ação é necessária. A migração foi concluída."
        Write-Host ""
        exit 0
    }

    if (-not $hasState -and -not $hasSnapshot -and -not $hasDisk) { return }

    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║       EXECUÇÃO ANTERIOR INCOMPLETA DETECTADA              ║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Estado atual dos recursos:" -ForegroundColor White
    Write-Host ""

    if ($hasState) {
        $resCount = (Select-String '"mode":' terraform.tfstate -ErrorAction SilentlyContinue).Count
        Write-Host "  ▸ terraform.tfstate   : " -NoNewline
        Write-Host "EXISTS ($resCount recursos)" -ForegroundColor Red
    }
    if ($hasSnapshot) {
        $snapStatus = gcloud compute snapshots describe $SnapshotName `
            --project=$ProjectId --format="value(status)" 2>$null
        Write-Host "  ▸ Snapshot de boot    : " -NoNewline
        Write-Host "$snapStatus ($SnapshotName)" -ForegroundColor Green
    } else {
        Write-Host "  ▸ Snapshot de boot    : " -NoNewline
        Write-Host "NÃO ENCONTRADO" -ForegroundColor Red
    }
    if ($hasDisk) {
        $diskStatus = gcloud compute disks describe $NewDiskName `
            --zone=$Zone --project=$ProjectId --format="value(status)" 2>$null
        Write-Host "  ▸ Disco destino       : " -NoNewline
        Write-Host "$diskStatus ($NewDiskName)" -ForegroundColor Green
    } else {
        Write-Host "  ▸ Disco destino       : " -NoNewline
        Write-Host "NÃO ENCONTRADO" -ForegroundColor Red
    }
    Write-Host "  ▸ VM destino          : " -NoNewline
    Write-Host "NÃO CRIADA" -ForegroundColor Red

    Write-Host ""
    Write-Host "  Escolha uma opção:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1) Retomar de onde parou (terraform init + plan + apply — recomendado)"
    Write-Host "    2) Reiniciar do zero (apaga estado + recursos órfãos no GCP)"
    Write-Host "       " -NoNewline
    Write-Host "⚠ Os dados do snapshot são preservados no disco original." -ForegroundColor Yellow
    Write-Host "    3) Cancelar"
    Write-Host ""

    $choice = Read-Host "  Opção [1/2/3]"

    switch ($choice) {
        "1" {
            Write-Host ""
            $script:Resuming = $true
            Write-Ok "Retomando execução anterior..."
            Remove-Item -Path "tfplan" -ErrorAction SilentlyContinue

            Write-Info "Verificando necessidade de importar recursos existentes..."
            terraform init -input=false 2>&1 | Out-Null

            if ($hasSnapshot) {
                $inState = Select-String '"name": "migration_snapshot"' terraform.tfstate -ErrorAction SilentlyContinue
                if (-not $inState) {
                    Write-Info "Importando snapshot existente para o estado do Terraform..."
                    terraform import google_compute_snapshot.migration_snapshot `
                        "projects/${ProjectId}/global/snapshots/${SnapshotName}"
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warn "Falha ao importar snapshot — pode ser necessário reiniciar do zero (opção 2)."
                    }
                } else {
                    Write-Info "Snapshot já está no estado do Terraform. Pulando import."
                }
            }
            if ($hasDisk -and $CreateNewDisk) {
                $inState = Select-String '"name": "migration_boot_disk"' terraform.tfstate -ErrorAction SilentlyContinue
                if (-not $inState) {
                    Write-Info "Importando disco existente para o estado do Terraform..."
                    terraform import "google_compute_disk.migration_boot_disk[0]" `
                        "projects/${ProjectId}/zones/${Zone}/disks/${NewDiskName}"
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warn "Falha ao importar disco — pode ser necessário reiniciar do zero (opção 2)."
                    }
                } else {
                    Write-Info "Disco já está no estado do Terraform. Pulando import."
                }
            }
            Write-Ok "Importação concluída. Prosseguindo com plan..."
        }
        "2" {
            Write-Host ""
            Write-Warn "Reiniciando do zero — limpando estado e recursos órfãos..."

            Remove-Item -Path "terraform.tfstate","terraform.tfstate.backup","tfplan" `
                -ErrorAction SilentlyContinue

            if ($hasDisk) {
                Write-Info "Removendo disco órfão: $NewDiskName"
                gcloud compute disks delete $NewDiskName `
                    --zone=$Zone --project=$ProjectId --quiet 2>$null
            }
            if ($hasSnapshot) {
                Write-Info "Removendo snapshot órfão: $SnapshotName"
                gcloud compute snapshots delete $SnapshotName `
                    --project=$ProjectId --quiet 2>$null
            }

            # Remove snapshots secundários órfãos
            $secSnaps = gcloud compute snapshots list `
                --project=$ProjectId `
                --filter="name~-migration-snapshot AND labels.origem=$SourceVm AND labels.tipo=migracao-secundario" `
                --format="value(name)" 2>$null
            foreach ($snap in $secSnaps) {
                if ($snap) {
                    Write-Info "Removendo snapshot secundário: $snap"
                    gcloud compute snapshots delete $snap --project=$ProjectId --quiet 2>$null
                }
            }

            # Remove discos secundários órfãos
            $secDisks = gcloud compute disks list `
                --project=$ProjectId `
                --filter="name~-$ResolvedDiskType AND zone:($Zone) AND labels.origem=$SourceVm" `
                --format="value(name)" 2>$null
            foreach ($dsk in $secDisks) {
                if ($dsk) {
                    Write-Info "Removendo disco secundário: $dsk"
                    gcloud compute disks delete $dsk --zone=$Zone --project=$ProjectId --quiet 2>$null
                }
            }

            # Garante que a VM de origem está rodando
            $srcStatus = gcloud compute instances describe $SourceVm `
                --zone=$Zone --project=$ProjectId `
                --format="value(status)" 2>$null
            if ($srcStatus -and $srcStatus -ne "RUNNING") {
                Write-Info "Iniciando VM de origem que estava parada: $SourceVm"
                gcloud compute instances start $SourceVm `
                    --zone=$Zone --project=$ProjectId --quiet 2>$null
            }

            Write-Ok "Limpeza concluída. Iniciando migração do zero."
        }
        default {
            Write-Info "Operação cancelada pelo usuário."
            exit 0
        }
    }
}

function Test-TargetChange {
    $currentVm = Get-TfVar "source_instance_name"
    if (Test-Path "terraform.tfstate") {
        $lastVm = (Select-String '"origem":' terraform.tfstate |
            Select-Object -First 1).Line -replace '.*: "(.*)".*', '$1'
        if ($lastVm -and $lastVm -ne $currentVm) {
            Write-Host ""
            Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
            Write-Host "║           ALERTA: MUDANÇA DE ALVO DETECTADA                ║" -ForegroundColor Yellow
            Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Migração anterior foi para a VM: $lastVm"
            Write-Host "  Configuração atual (tfvars) aponta: $currentVm"
            Write-Host ""
            $confirmClean = Read-Host "  Deseja LIMPAR o estado anterior para iniciar esta nova migração? (s/n)"
            if ($confirmClean -eq "s" -or $confirmClean -eq "S") {
                Write-Info "Limpando arquivos de estado anteriores..."
                Remove-Item -Path "terraform.tfstate","terraform.tfstate.backup","tfplan" `
                    -ErrorAction SilentlyContinue
                Write-Ok "Estado resetado. Iniciando nova migração."
            } else {
                Write-Err "Execução cancelada. Limpe o estado manualmente ou volte ao alvo anterior."
                exit 1
            }
        }
    }
}

Test-IncompleteRun
Test-TargetChange

# ==============================================================================
# ETAPA 2 — Terraform Init
# ==============================================================================
Write-Header "Terraform Init"
terraform init
if ($LASTEXITCODE -ne 0) { Write-Err "terraform init falhou."; exit 1 }
Write-Ok "Providers instalados e backend inicializado."

# ==============================================================================
# ETAPA 3 — Terraform Plan
# ==============================================================================
Write-Header "Terraform Plan"
terraform plan -out=tfplan
if ($LASTEXITCODE -ne 0) { Write-Err "terraform plan falhou."; exit 1 }
Write-Ok "Plano gerado e salvo em 'tfplan'."

if ($DryRun) {
    Write-Info "Modo -DryRun: encerrando sem aplicar."
    exit 0
}

# ==============================================================================
# ETAPA 4 — Confirmação final (após terraform plan)
# Re-exibe o resumo completo para conferência antes de aplicar
# ==============================================================================
if (-not $AutoApprove) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║         CONFIRMAÇÃO FINAL — REVISE ANTES DE PROSSEGUIR      ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    if ($script:Resuming) {
        Write-Host "  Modo retomada: apenas os passos PENDENTES serão executados." -ForegroundColor White
        Write-Host ""
        Write-Host "  VM alvo  : " -NoNewline; Write-Host $TargetVm -ForegroundColor Green
        Write-Host "  Projeto  : $ProjectId"
        Write-Host "  Zona     : $Zone"
    } else {
        Write-Host "  ORIGEM                                DESTINO" -ForegroundColor White
        Write-Host "  ──────────────────────────────────    ──────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  VM       : " -NoNewline; Write-Host $SourceVm -ForegroundColor Cyan
        Write-Host "  Família  : " -NoNewline; Write-Host $SourceFamily -ForegroundColor Cyan -NoNewline
        Write-Host "                        Família  : " -NoNewline; Write-Host $TargetFamily -ForegroundColor Green
        Write-Host "  Tipo     : " -NoNewline; Write-Host $SourceMachineType -ForegroundColor Cyan
        Write-Host "  vCPUs    : " -NoNewline; Write-Host $SrcVcpus -ForegroundColor Cyan -NoNewline
        Write-Host "                         vCPUs    : " -NoNewline; Write-Host ($TargetVcpus -replace "^$","?") -ForegroundColor Green
        Write-Host "  RAM      : " -NoNewline; Write-Host "${SrcRamGb} GB" -ForegroundColor Cyan -NoNewline
        Write-Host "                      RAM      : " -NoNewline; Write-Host "$(if ($TargetMemGb) { "${TargetMemGb} GB" } else { '?' })" -ForegroundColor Green
        Write-Host "  Disco    : " -NoNewline; Write-Host $SrcDiskType -ForegroundColor Cyan -NoNewline
        Write-Host "                  Disco    : " -NoNewline; Write-Host $ResolvedDiskType -ForegroundColor Green
        Write-Host "  Tamanho  : " -NoNewline; Write-Host "${SrcDiskSize} GB" -ForegroundColor Cyan
        Write-Host "  NIC      : " -NoNewline; Write-Host "VIRTIO_NET" -ForegroundColor Cyan -NoNewline
        Write-Host "                  NIC      : " -NoNewline; Write-Host $TargetNic -ForegroundColor Green
        Write-Host ""
        Write-Host "  Operações que serão executadas:" -ForegroundColor White
        Write-Host "  1. Criar snapshot de: " -NoNewline
        Write-Host $BootDiskName -ForegroundColor Cyan -NoNewline
        Write-Host "  →  " -NoNewline; Write-Host $SnapshotName -ForegroundColor Green
        if ($CreateNewDisk) {
            Write-Host "  2. Criar novo disco " -NoNewline
            Write-Host $ResolvedDiskType -ForegroundColor Green -NoNewline
            Write-Host " a partir do snapshot"
        } else {
            Write-Host "  2. " -NoNewline
            Write-Host "Reutilizar disco existente" -ForegroundColor Green -NoNewline
            Write-Host " ($ResolvedDiskType) — sem criação de novo disco"
        }
        Write-Host "  3. " -NoNewline; Write-Host "PARAR" -ForegroundColor Red -NoNewline
        Write-Host " VM " -NoNewline; Write-Host $SourceVm -ForegroundColor Cyan -NoNewline
        Write-Host " e desvincular o IP externo  ← " -NoNewline
        Write-Host "DOWNTIME INICIA" -ForegroundColor Red
        Write-Host "  4. Criar nova VM " -NoNewline; Write-Host $TargetVm -ForegroundColor Green -NoNewline
        Write-Host " com o mesmo IP               ← " -NoNewline
        Write-Host "DOWNTIME ENCERRA" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Projeto : $ProjectId"
        Write-Host "  Zona    : $Zone"
    }

    Write-Host ""

    if ($Warnings.Count -gt 0) {
        Write-Host "  ⚠ Alertas:" -ForegroundColor Yellow
        foreach ($w in $Warnings) {
            Write-Host "    • $w" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    $confirm = Read-Host "  Digite 'sim' para confirmar e iniciar a migração"
    if ($confirm -ne "sim") {
        Write-Info "Operação cancelada pelo usuário."
        exit 0
    }
}

# ==============================================================================
# ETAPA 5 — Terraform Apply
# ==============================================================================
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
    Write-Err "ATENÇÃO: A VM de origem pode ter sido parada — verifique o Console GCP."
    Write-Err "Execute novamente o script para detectar o estado e retomar."

    Send-Telegram $TelegramToken $TelegramChat @"
❌ <b>ERRO NA MIGRAÇÃO</b>
━━━━━━━━━━━━━━━━━━━━━━━━
🔴 Projeto  : <code>$ProjectId</code>
🔴 VM Origem: <code>$SourceVm</code>
💀 Erro     : <code>$_</code>
⏱  Horário  : <b>$hora</b>

⚠️ Verifique os logs do Terraform.
⚠️ A VM de origem pode ter sido parada — confirme no Console GCP.
💡 Execute o script novamente para detectar e retomar.
"@
    exit 1
}

$endTime  = Get-Date
$duration = $endTime - $startTime
$durStr   = "{0}m {1}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds

Write-Host ""
Write-Ok "terraform apply concluído em $durStr."

# ==============================================================================
# ETAPA 6 — Exibe resultados
# ==============================================================================
Write-Header "Resultados da Migração"
terraform output

$ipExterno      = (terraform output -raw nova_instancia_ip_externo 2>$null)
$ipInterno      = (terraform output -raw nova_instancia_ip_interno 2>$null)
$discoReusado   = (terraform output -raw disco_reutilizado 2>$null)
$tipoDisco      = (terraform output -raw tipo_disco_destino 2>$null)

if (-not $ipExterno)    { $ipExterno = "N/A" }
if (-not $ipInterno)    { $ipInterno = "N/A" }
if (-not $tipoDisco)    { $tipoDisco = $ResolvedDiskType }
$discoAcao = if ($discoReusado -eq "true") { "reutilizado" } else { "criado novo" }

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║      MIGRAÇÃO CONCLUÍDA COM SUCESSO      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  VM Destino : $TargetVm"
Write-Host "  IP Externo : $ipExterno"
Write-Host "  IP Interno : $ipInterno"
Write-Host "  Disco      : $tipoDisco ($discoAcao)"
Write-Host "  Duração    : $durStr"
Write-Host "  Projeto    : $ProjectId"
Write-Host ""
Write-Host "Próximos passos (manuais):" -ForegroundColor Cyan
Write-Host "  1. Valide a VM — acesso SSH, serviços, aplicação"
Write-Host "  2. Após validação, exclua a VM de origem pelo Console GCP"
if ($discoReusado -eq "true") {
    Write-Host "  3. Disco foi reutilizado — nenhum disco órfão para limpar"
} else {
    Write-Host "  3. Após confirmar os dados, exclua o disco original pelo Console GCP"
}
Write-Host ""
