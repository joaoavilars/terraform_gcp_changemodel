# ==============================================================================
# downgrade_boot_disk.ps1 — Reduz o tamanho do disco de boot de uma VM no GCP
#
# ESCOPO ESTRITO desta automação:
#   - Linux                            (Windows guest não suportado)
#   - Filesystem ext4                  (xfs/btrfs/zfs NÃO suportados)
#   - Partição única em /dev/sda1      (LVM/criptografia/multi-partição NÃO suportados)
#   - Disco de BOOT (não de dados)
#
# Para cenários fora disso, siga o procedimento MANUAL no README.md.
#
# Uso:
#   .\downgrade_boot_disk.ps1                # interativo
#   .\downgrade_boot_disk.ps1 -AutoApprove   # sem confirmação (CI)
#   .\downgrade_boot_disk.ps1 -DryRun        # mostra plano sem executar
#   .\downgrade_boot_disk.ps1 -Help          # ajuda
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [switch]$DryRun,
    [switch]$Help
)

if ($Help) {
    Get-Content $PSCommandPath | Select-Object -First 18 | ForEach-Object { Write-Host $_ }
    exit 0
}

$ErrorActionPreference = "Stop"

function Write-Log($msg)  { Write-Host "[INFO]  $msg"  -ForegroundColor Blue }
function Write-Ok($msg)   { Write-Host "[OK]    $msg"  -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[AVISO] $msg"  -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERRO]  $msg"  -ForegroundColor Red }
function Write-Step($msg) {
    Write-Host ""
    Write-Host "▶ $msg" -ForegroundColor Cyan
    Write-Host ""
}

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
# Pré-requisitos
# ------------------------------------------------------------------------------
foreach ($tool in @("gcloud")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Err "Ferramenta não encontrada: $tool"
        exit 1
    }
}
if (-not (Test-Path "terraform.tfvars")) {
    Write-Err "terraform.tfvars não encontrado no diretório atual."
    exit 1
}

# ------------------------------------------------------------------------------
# Configuração
# ------------------------------------------------------------------------------
$ProjectId       = Get-TfVar "project_id"
$Zone            = Get-TfVar "zone"
$Region          = Get-TfVar "region"
$SourceVm        = Get-TfVar "source_instance_name"
$ChangeDiskSize  = Get-TfVar "change_disk_size"
$TargetDiskSize  = Get-TfVar "target_disk_size"
$TelegramToken   = Get-TfVar "telegram_bot_token"
$TelegramChat    = Get-TfVar "telegram_chat_id"

# ------------------------------------------------------------------------------
# Notificação Telegram — envia se TOKEN/CHAT estiverem configurados
# Não falha o script se o Telegram estiver offline
# ------------------------------------------------------------------------------
function Send-Tg($msg) {
    if (-not $TelegramToken -or -not $TelegramChat) { return }
    try {
        $url = "https://api.telegram.org/bot$TelegramToken/sendMessage"
        $body = @{
            chat_id    = $TelegramChat
            parse_mode = "HTML"
            text       = $msg
        }
        Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # silencioso — não bloqueia a operação principal
    }
}

# Estado global para o trap de erro
$script:DowngradeStarted = $false
$script:DowngradeStartTs = $null

if (-not $ProjectId) { Write-Err "project_id não preenchido em terraform.tfvars."; exit 1 }
if (-not $Zone)      { Write-Err "zone não preenchido em terraform.tfvars."; exit 1 }
if (-not $SourceVm)  { Write-Err "source_instance_name não preenchido em terraform.tfvars."; exit 1 }

if ($ChangeDiskSize -ne "true") {
    Write-Err "change_disk_size deve ser 'true' em terraform.tfvars para usar este script."
    Write-Err "Sem isso, o migrate.sh manteria o tamanho original — o downgrade seria perdido."
    exit 1
}

$TargetDiskSizeInt = 0
if (-not [int]::TryParse($TargetDiskSize, [ref]$TargetDiskSizeInt) -or $TargetDiskSizeInt -le 0) {
    Write-Err "target_disk_size deve ser um inteiro > 0 em terraform.tfvars."
    exit 1
}

$FsNewSize   = $TargetDiskSizeInt - 10
$PartNewSize = $TargetDiskSizeInt - 5

if ($FsNewSize -le 5) {
    Write-Err "target_disk_size = $TargetDiskSizeInt GB é pequeno demais (mínimo viável: 16 GB)."
    exit 1
}

$TempVmName    = "$SourceVm-resize-temp"
$SnapshotName  = "$SourceVm-pre-downgrade-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# ------------------------------------------------------------------------------
# Inspeciona VM de origem
# ------------------------------------------------------------------------------
Write-Step "Lendo informações da VM de origem"

$SourceStatus = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(status)" 2>$null
if (-not $SourceStatus) {
    Write-Err "VM '$SourceVm' não encontrada no projeto '$ProjectId', zona '$Zone'."
    exit 1
}

$BootDiskSource = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(disks[0].source)"
$BootDiskName = ($BootDiskSource -split "/")[-1]

$BootDiskSize = [int](gcloud compute disks describe $BootDiskName `
    --zone=$Zone --project=$ProjectId `
    --format="value(sizeGb)")

Write-Ok "VM: $SourceVm (status: $SourceStatus)"
Write-Ok "Disco de boot: $BootDiskName (${BootDiskSize} GB)"

if ($TargetDiskSizeInt -ge $BootDiskSize) {
    Write-Err "target_disk_size (${TargetDiskSizeInt} GB) >= tamanho atual (${BootDiskSize} GB)."
    Write-Err "Este script é APENAS para DOWNGRADE. Para upgrade, basta rodar .\migrate.ps1."
    exit 1
}

# ------------------------------------------------------------------------------
# Valida filesystem via SSH
# ------------------------------------------------------------------------------
Write-Step "Verificando filesystem da VM de origem via SSH"

if ($SourceStatus -ne "RUNNING") {
    Write-Warn "VM '$SourceVm' não está RUNNING (status: $SourceStatus)."
    Write-Warn "É necessário ligá-la temporariamente para inspecionar o filesystem."
    if (-not $AutoApprove) {
        $resp = Read-Host "Iniciar a VM agora para validação? (sim/nao)"
        if ($resp -ne "sim") { Write-Err "Abortado pelo usuário."; exit 1 }
    }
    if (-not $DryRun) {
        gcloud compute instances start $SourceVm --zone=$Zone --project=$ProjectId --quiet
        Write-Log "Aguardando 30s para o SSH ficar pronto..."
        Start-Sleep -Seconds 30
    }
}

if (-not $DryRun) {
    $sshCmd = @"
ROOT_DEV=`$(findmnt -n -o SOURCE /)
ROOT_REAL=`$(readlink -f "`$ROOT_DEV")
PART_NAME=`$(basename "`$ROOT_REAL")
DISK_NAME=`$(echo "`$PART_NAME" | sed 's/1`$//')
FSTYPE=`$(lsblk -n -o FSTYPE "`$ROOT_REAL")
PART_COUNT=`$(lsblk -n -o NAME "/dev/`$DISK_NAME" 2>/dev/null | tail -n +2 | wc -l)
USED_GB=`$(df -B1G --output=used / | tail -1 | tr -d ' ')
echo "DEV=`$ROOT_REAL FS=`$FSTYPE PARTS=`$PART_COUNT USED=`${USED_GB}G"
lsblk -n -o NAME,FSTYPE "/dev/`$DISK_NAME" 2>/dev/null || true
"@
    $fsInfo = gcloud compute ssh $SourceVm --zone=$Zone --project=$ProjectId `
        --command="$sshCmd" --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Falha ao conectar via SSH na VM de origem."
        Write-Err "Verifique conectividade, firewall e permissões IAM."
        exit 1
    }

    $fsInfo | ForEach-Object { Write-Host "    $_" }

    # Extrai a linha principal (DEV=...)
    $mainLine = ($fsInfo | Where-Object { $_ -match "^DEV=" }) | Select-Object -First 1
    if (-not $mainLine) {
        Write-Err "Não foi possível detectar o dispositivo raiz via SSH."
        exit 1
    }

    $srcDevice = if ($mainLine -match 'DEV=(\S+)') { $Matches[1] } else { "" }
    $srcFsType = if ($mainLine -match 'FS=(\S+)')   { $Matches[1] } else { "" }
    $srcParts  = if ($mainLine -match 'PARTS=(\S+)')  { $Matches[1] } else { "0" }
    $srcUsedStr = if ($mainLine -match 'USED=(\S+)')  { $Matches[1] } else { "0G" }
    $srcUsedGb = [int]($srcUsedStr -replace 'G$', '')

    # Valida que a partição raiz termina com "da1" (ex: /dev/sda1, /dev/vda1)
    $partName = Split-Path $srcDevice -Leaf
    if ($partName -notmatch '^[sv]da1$') {
        Write-Err "Partição raiz não é sda1/vda1 (encontrada: $partName em $srcDevice)."
        Write-Err "Este script suporta APENAS partição única /dev/sda1. Use o procedimento manual."
        exit 1
    }

    if ($srcFsType -ne "ext4") {
        Write-Err "Filesystem não é ext4 (encontrado: $srcFsType)."
        Write-Err "Este script suporta APENAS ext4. Para xfs/btrfs/lvm, use o procedimento manual."
        exit 1
    }

    if ($srcParts -ne 1) {
        Write-Err "Disco tem $srcParts partições. Esperado: exatamente 1."
        Write-Err "Este script suporta APENAS partição única. Use o procedimento manual."
        exit 1
    }

    if ($srcUsedGb -ge $FsNewSize) {
        Write-Err "Espaço usado ($srcUsedGb GB) >= tamanho alvo do FS ($FsNewSize GB)."
        Write-Err "Libere espaço antes de prosseguir (apague logs, caches, arquivos grandes)."
        exit 1
    }

    Write-Ok "Filesystem: ext4 em $srcDevice"
    Write-Ok "Usado: $srcUsedGb GB | FS será reduzido para: $FsNewSize GB | Margem: $($FsNewSize - $srcUsedGb) GB"
}

# ------------------------------------------------------------------------------
# Resumo e confirmação
# ------------------------------------------------------------------------------
Write-Step "Resumo do plano de downgrade"

Write-Host @"
  Projeto         : $ProjectId
  Zona            : $Zone
  VM de origem    : $SourceVm
  Disco           : $BootDiskName ($BootDiskSize GB)

  Tamanho alvo    : $TargetDiskSizeInt GB (definido em terraform.tfvars)
  FS será reduzido para  : $FsNewSize GB
  Partição reduzida para : $PartNewSize GB

  Snapshot de segurança  : $SnapshotName
  VM temporária          : $TempVmName (e2-small, Debian 12)
"@

if ($DryRun) {
    Write-Warn "DRY-RUN: nenhuma alteração será aplicada."
    exit 0
}

if (-not $AutoApprove) {
    Write-Host ""
    Write-Host "⚠  Esta operação para a VM '$SourceVm' e reduz o disco de boot." -ForegroundColor Yellow
    Write-Host "⚠  Em caso de falha, o snapshot '$SnapshotName' permite rollback." -ForegroundColor Yellow
    Write-Host ""
    $resp = Read-Host "Digite 'sim' para prosseguir"
    if ($resp -ne "sim") { Write-Err "Abortado pelo usuário."; exit 1 }
}

# Marca início para notificações de erro e cálculo de duração
$script:DowngradeStarted = $true
$script:DowngradeStartTs = Get-Date

# Hora helper
function Now { (Get-Date).ToString("HH:mm:ss") }
function NowFull { (Get-Date).ToString("dd/MM/yyyy HH:mm:ss") }

# ------------------------------------------------------------------------------
# Notificação Telegram — início do downgrade
# ------------------------------------------------------------------------------
Send-Tg @"
🔧 <b>DOWNGRADE DE DISCO INICIADO</b>
━━━━━━━━━━━━━━━━━━━━━━━━
🖥  VM         : <code>$SourceVm</code>
💾 Disco      : <code>$BootDiskName</code>
📐 De         : <b>$BootDiskSize GB</b>
📏 Para       : <b>$TargetDiskSizeInt GB</b>
  • FS final  : $FsNewSize GB
  • Partição  : $PartNewSize GB
📋 Projeto    : <code>$ProjectId</code>
🌍 Zona       : <code>$Zone</code>
⏱  Início    : <b>$(NowFull)</b>
"@

# ------------------------------------------------------------------------------
# Execução
# ------------------------------------------------------------------------------
try {

Write-Step "Passo 1/8 — Snapshot manual de segurança"
gcloud compute disks snapshot $BootDiskName `
    --zone=$Zone --project=$ProjectId `
    --snapshot-names=$SnapshotName `
    --storage-location=$Region `
    --quiet
Write-Ok "Snapshot criado: $SnapshotName"
Send-Tg @"
✅ <b>Passo 1/8 — Snapshot de seguranca criado</b>
📸 <code>$SnapshotName</code>
📍 Região: <code>$Region</code>
⏱  $(Now)
"@

Write-Step "Passo 2/8 — Parando VM de origem"
$currentStatus = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId --format="value(status)"
if ($currentStatus -in @("RUNNING","STAGING")) {
    gcloud compute instances stop $SourceVm --zone=$Zone --project=$ProjectId --quiet
    Write-Ok "VM parada."
} else {
    Write-Ok "VM já estava parada (status: $currentStatus)."
}
Send-Tg @"
✅ <b>Passo 2/8 — VM de origem parada</b>
🔴 <code>$SourceVm</code>
⏱  $(Now)
"@

Write-Step "Passo 3/8 — Criando VM temporária $TempVmName"
$tempExists = gcloud compute instances describe $TempVmName `
    --zone=$Zone --project=$ProjectId --format="value(name)" 2>$null
if ($tempExists) {
    Write-Warn "VM temporária $TempVmName já existe (execução anterior?). Reutilizando."
} else {
    gcloud compute instances create $TempVmName `
        --zone=$Zone --project=$ProjectId `
        --machine-type=e2-small `
        --image-family=debian-12 --image-project=debian-cloud `
        --boot-disk-size=10GB `
        --quiet
    Write-Ok "VM temporária criada."
    Write-Log "Aguardando 25s para a VM ficar pronta para SSH..."
    Start-Sleep -Seconds 25
}
Send-Tg @"
✅ <b>Passo 3/8 — VM temporaria pronta</b>
🆕 <code>$TempVmName</code> (e2-small, Debian 12)
⏱  $(Now)
"@

Write-Step "Passo 4/8 — Movendo disco de boot para VM temporária"
gcloud compute instances detach-disk $SourceVm `
    --disk=$BootDiskName --zone=$Zone --project=$ProjectId --quiet
Write-Ok "Disco desanexado de $SourceVm."

gcloud compute instances attach-disk $TempVmName `
    --disk=$BootDiskName `
    --device-name=resize-target `
    --zone=$Zone --project=$ProjectId --quiet
Write-Ok "Disco anexado em $TempVmName (device-name: resize-target)."
Send-Tg @"
✅ <b>Passo 4/8 — Disco movido</b>
💾 <code>$BootDiskName</code>
🔁 <code>$SourceVm</code> ➡️ <code>$TempVmName</code>
⏱  $(Now)
"@

Write-Step "Passo 5/8 — Reduzindo filesystem e partição via SSH na VM temporária"

# Script remoto bash — gerado e enviado para a VM Linux temporária
$remoteScript = @"
set -e
echo '>>> Procurando o disco anexado...'
DISK_DEV=`$(readlink -f /dev/disk/by-id/google-resize-target)
PART_DEV="`${DISK_DEV}1"
echo ">>> Disco: `$DISK_DEV"
echo ">>> Particao: `$PART_DEV"

if [ ! -b "`$DISK_DEV" ]; then echo 'ERRO: disco nao encontrado'; exit 11; fi
if [ ! -b "`$PART_DEV" ]; then echo 'ERRO: particao nao encontrada'; exit 12; fi

sudo umount "`$PART_DEV" 2>/dev/null || true

FSTYPE=`$(sudo blkid -o value -s TYPE "`$PART_DEV")
if [ "`$FSTYPE" != 'ext4' ]; then echo "ERRO: fs=`$FSTYPE esperado ext4"; exit 13; fi

NUM_PARTS=`$(lsblk -n -o NAME "`$DISK_DEV" | tail -n +2 | wc -l)
if [ "`$NUM_PARTS" -ne 1 ]; then echo "ERRO: `$NUM_PARTS particoes, esperado 1"; exit 14; fi

echo '>>> e2fsck...'
sudo e2fsck -fy "`$PART_DEV"
echo '>>> resize2fs para ${FsNewSize}G...'
sudo resize2fs "`$PART_DEV" ${FsNewSize}G
echo '>>> reduzindo particao para ${PartNewSize}GB...'
sudo parted "`$DISK_DEV" ---pretend-input-tty <<PARTED_EOF
resizepart 1
${PartNewSize}GB
Yes
PARTED_EOF
sudo parted "`$DISK_DEV" print
sudo e2fsck -fy "`$PART_DEV"
echo '>>> SUCESSO'
"@

$sshOk = $false
for ($attempt = 1; $attempt -le 4; $attempt++) {
    gcloud compute ssh $TempVmName --zone=$Zone --project=$ProjectId --command=$remoteScript
    if ($LASTEXITCODE -eq 0) { $sshOk = $true; break }
    Write-Warn "Tentativa $attempt falhou. Aguardando 15s..."
    Start-Sleep -Seconds 15
}

if (-not $sshOk) {
    Write-Err "Falha ao executar resize remoto após 4 tentativas."
    Write-Err "Snapshot de seguranca preservado: $SnapshotName"
    Write-Err "Rollback manual:"
    Write-Err "  gcloud compute instances detach-disk $TempVmName --disk=$BootDiskName --zone=$Zone --project=$ProjectId"
    Write-Err "  gcloud compute instances attach-disk $SourceVm --disk=$BootDiskName --boot --zone=$Zone --project=$ProjectId"
    Write-Err "  gcloud compute instances delete $TempVmName --zone=$Zone --project=$ProjectId --quiet"
    throw "Resize remoto falhou (4 tentativas)"
}
Write-Ok "Filesystem e partição reduzidos com sucesso."
Send-Tg @"
✅ <b>Passo 5/8 — Filesystem e particao reduzidos</b>
📏 FS       : <b>$FsNewSize GB</b>
🔢 Partição : <b>$PartNewSize GB</b>
⏱  $(Now)
"@

Write-Step "Passo 6/8 — Devolvendo disco para a VM de origem"
gcloud compute instances detach-disk $TempVmName `
    --disk=$BootDiskName --zone=$Zone --project=$ProjectId --quiet
Write-Ok "Disco desanexado da VM temporária."

gcloud compute instances attach-disk $SourceVm `
    --disk=$BootDiskName --boot `
    --zone=$Zone --project=$ProjectId --quiet
Write-Ok "Disco reanexado em $SourceVm como BOOT."
Send-Tg @"
✅ <b>Passo 6/8 — Disco devolvido a origem</b>
🔁 <code>$TempVmName</code> ➡️ <code>$SourceVm</code> (boot)
⏱  $(Now)
"@

Write-Step "Passo 7/8 — Apagando VM temporária"
gcloud compute instances delete $TempVmName `
    --zone=$Zone --project=$ProjectId --quiet
Write-Ok "VM temporária $TempVmName removida."
Send-Tg @"
✅ <b>Passo 7/8 — VM temporaria removida</b>
🗑  <code>$TempVmName</code>
⏱  $(Now)
"@

Write-Step "Passo 8/8 — Downgrade preparado"

# Calcula duração total
$durationSpan = (Get-Date) - $script:DowngradeStartTs
$duration = "{0}m {1}s" -f [int]$durationSpan.TotalMinutes, $durationSpan.Seconds

# Marca fim — daqui pra frente o catch não envia falha
$script:DowngradeStarted = $false

Send-Tg @"
🎉 <b>DOWNGRADE PREPARADO COM SUCESSO</b>
━━━━━━━━━━━━━━━━━━━━━━━━
🖥  VM         : <code>$SourceVm</code>
💾 Disco      : <code>$BootDiskName</code>
📐 Origem     : $BootDiskSize GB (físico, inalterado)
📏 FS final   : <b>$FsNewSize GB</b>
🔢 Partição   : <b>$PartNewSize GB</b>
🎯 Alvo       : <b>$TargetDiskSizeInt GB</b> (após migrate.ps1)
📸 Snapshot   : <code>$SnapshotName</code>
⏱  Duração   : <b>$duration</b>
🕐 Fim        : <b>$(NowFull)</b>

▶ Proximo: <code>.\migrate.ps1</code>
"@

Write-Host @"

✅ Disco de boot preparado para downgrade.

  Disco: $BootDiskName
    - Tamanho fisico         : $BootDiskSize GB (inalterado neste passo)
    - Filesystem reduzido p/ : $FsNewSize GB
    - Particao reduzida p/   : $PartNewSize GB

  Snapshot de rollback       : $SnapshotName
  Duracao total              : $duration

Proximos passos:
  1. (Opcional) Inicie a VM '$SourceVm' temporariamente para validar:
       gcloud compute instances start $SourceVm --zone=$Zone --project=$ProjectId
       gcloud compute ssh $SourceVm --zone=$Zone --project=$ProjectId
       df -h /        # deve mostrar ~$FsNewSize G
       gcloud compute instances stop $SourceVm --zone=$Zone --project=$ProjectId

  2. Rode a migracao - ela criara um novo disco de $TargetDiskSizeInt GB a partir do snapshot:
       .\migrate.ps1

  3. Apos a migracao, na nova VM, expanda o FS para usar todo o disco:
       gcloud compute ssh <nova-vm> --zone=$Zone --project=$ProjectId
       sudo growpart /dev/sda 1
       sudo resize2fs /dev/sda1
"@

} catch {
    # Notificação Telegram de falha
    if ($script:DowngradeStarted) {
        Send-Tg @"
❌ <b>DOWNGRADE DE DISCO — FALHA</b>
━━━━━━━━━━━━━━━━━━━━━━━━
🖥  VM       : <code>$SourceVm</code>
📋 Projeto  : <code>$ProjectId</code>
💥 Erro     : <code>$($_.Exception.Message)</code>
⏱  Hora     : <b>$(NowFull)</b>

⚠️ Verifique o snapshot de seguranca para rollback se necessario.
📸 <code>$SnapshotName</code>
"@
    }
    Write-Err $_.Exception.Message
    exit 1
}
