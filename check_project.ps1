# ==============================================================================
# check_project.ps1 — Consulta e exibe todas as informações da VM a ser migrada
#
# Lê project_id, zone e source_instance_name do terraform.tfvars e exibe um
# relatório completo: máquina, discos, rede, IPs, tags e prévia da migração.
#
# Uso:
#   .\check_project.ps1         → lê do terraform.tfvars
#   .\check_project.ps1 -Help   → ajuda
# ==============================================================================

[CmdletBinding()]
param([switch]$Help)

if ($Help) {
    Write-Host "Uso: .\check_project.ps1"
    Write-Host "  Lê project_id, zone e source_instance_name do terraform.tfvars"
    Write-Host "  e exibe um relatório completo da VM."
    exit 0
}

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# Helpers de output
# ------------------------------------------------------------------------------
function Write-Header($title) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Row($label, $value, $color = "White") {
    Write-Host ("  {0,-22}" -f "${label}:") -NoNewline -ForegroundColor White
    Write-Host $value -ForegroundColor $color
}
function Write-Divider { Write-Host "  ──────────────────────────────────────────────" -ForegroundColor DarkBlue }

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
# Pré-requisitos
# ------------------------------------------------------------------------------
foreach ($tool in @("gcloud")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "[ERRO]  Ferramenta não encontrada: $tool" -ForegroundColor Red
        exit 1
    }
}
if (-not (Test-Path "terraform.tfvars")) {
    Write-Host "[ERRO]  terraform.tfvars não encontrado no diretório atual." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# Carrega variáveis do tfvars
# ------------------------------------------------------------------------------
$ProjectId    = Get-TfVar "project_id"
$Zone         = Get-TfVar "zone"
$Region       = Get-TfVar "region"
$SourceVm     = Get-TfVar "source_instance_name"
$FinalVmName  = Get-TfVar "final_instance_name"

# Variáveis de destino (opcionais — para prévia da migração)
$TargetFamily  = Get-TfVar "target_machine_family"
$TargetDisk    = Get-TfVar "target_disk_type"
$TargetVcpus   = Get-TfVar "target_vcpus"
$TargetMemGb   = Get-TfVar "target_memory_gb"
$MtOverride    = Get-TfVar "machine_type_override"

if ([string]::IsNullOrEmpty($ProjectId) -or $ProjectId -eq "projeto-aqui") {
    Write-Host "[ERRO]  project_id não preenchido em terraform.tfvars." -ForegroundColor Red
    exit 1
}
if ([string]::IsNullOrEmpty($SourceVm) -or $SourceVm -eq "minha-vm") {
    Write-Host "[ERRO]  source_instance_name não preenchido em terraform.tfvars." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         RELATÓRIO DE VM — PRÉ-MIGRAÇÃO           ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Row "Projeto"  $ProjectId "Cyan"
Write-Row "Região"   $Region    "Cyan"
Write-Row "Zona"     $Zone      "Cyan"

# ------------------------------------------------------------------------------
# Consulta a VM
# ------------------------------------------------------------------------------
Write-Header "Instância"
Write-Host "  [INFO]  Consultando VM '$SourceVm'..." -ForegroundColor Blue

$vmCsv = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="csv[no-heading](machineType,status)" 2>$null

if ([string]::IsNullOrEmpty($vmCsv)) {
    Write-Host "[ERRO]  VM '$SourceVm' não encontrada no projeto '$ProjectId', zona '$Zone'." -ForegroundColor Red
    exit 1
}

$csvParts    = $vmCsv.Trim().Split(",")
$MachineType = ($csvParts[0] -split "/")[-1]
$VmStatus    = $csvParts[1]
$SrcFamily   = ($MachineType -split "-")[0]

# Busca vCPUs e RAM reais via API
Write-Host "  [INFO]  Consultando specs de '$MachineType'..." -ForegroundColor Blue
$mtRaw = gcloud compute machine-types describe $MachineType `
    --zone=$Zone --project=$ProjectId `
    --format="csv[no-heading](guestCpus,memoryMb)" 2>$null

if ($mtRaw) {
    $mtParts = $mtRaw.Trim().Split(",")
    $SrcVcpus = [int]$mtParts[0]
    $SrcRamGb = [math]::Round([int]$mtParts[1] / 1024)
} else {
    $SrcVcpus = "?"
    $SrcRamGb = "?"
}

$statusColor = switch ($VmStatus) {
    "RUNNING"    { "Green" }
    "TERMINATED" { "Red" }
    "STOPPED"    { "Red" }
    default      { "Yellow" }
}

Write-Row "Nome"    $SourceVm    "Green"
Write-Row "Status"  $VmStatus    $statusColor
Write-Row "Tipo"    $MachineType "Cyan"
Write-Row "Família" $SrcFamily
Write-Row "vCPUs"   "$SrcVcpus"
Write-Row "RAM"     "${SrcRamGb} GB"

# ------------------------------------------------------------------------------
# Disco de boot
# ------------------------------------------------------------------------------
Write-Header "Disco de Boot"

$bootDiskSrc  = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(disks[0].source)" 2>$null
$BootDiskName = ($bootDiskSrc -split "/")[-1]
$BootDiskMode = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(disks[0].mode)" 2>$null

if (-not [string]::IsNullOrEmpty($BootDiskName)) {
    $dInfo = gcloud compute disks describe $BootDiskName `
        --zone=$Zone --project=$ProjectId `
        --format="csv[no-heading](type,sizeGb,status)" 2>$null
    $dParts       = $dInfo.Trim().Split(",")
    $BootDiskType = ($dParts[0] -split "/")[-1]
    $BootDiskSize = $dParts[1]
    $BootDiskStat = $dParts[2]

    Write-Row "Nome"    $BootDiskName "Cyan"
    Write-Row "Tipo"    $BootDiskType "Yellow"
    Write-Row "Tamanho" "${BootDiskSize} GB"
    Write-Row "Status"  $BootDiskStat
    Write-Row "Modo"    $BootDiskMode
} else {
    Write-Host "  [AVISO] Não foi possível identificar o disco de boot." -ForegroundColor Yellow
    $BootDiskType = "unknown"
    $BootDiskSize = "unknown"
}

# ------------------------------------------------------------------------------
# Discos secundários
# ------------------------------------------------------------------------------
$secSources = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(disks[1:].source)" 2>$null

$SecDisks = @()
if ($secSources) {
    foreach ($src in ($secSources -split "`n")) {
        $src = $src.Trim()
        if ($src) { $SecDisks += ($src -split "/")[-1] }
    }
}

Write-Header "Discos Secundários ($($SecDisks.Count))"

if ($SecDisks.Count -gt 0) {
    Write-Host "  " -NoNewline
    Write-Host "(serão sempre recriados a partir de snapshot)" -ForegroundColor DarkGray
    Write-Host ""
    foreach ($dsk in $SecDisks) {
        $dInfo = gcloud compute disks describe $dsk `
            --zone=$Zone --project=$ProjectId `
            --format="csv[no-heading](type,sizeGb,status)" 2>$null
        $dParts  = $dInfo.Trim().Split(",")
        $dType   = ($dParts[0] -split "/")[-1]
        $dSize   = $dParts[1]
        $dStatus = $dParts[2]
        Write-Host "  ▸ " -NoNewline -ForegroundColor Cyan
        Write-Host "$dsk" -ForegroundColor Cyan
        Write-Host "    Tipo: " -NoNewline
        Write-Host $dType -ForegroundColor Yellow -NoNewline
        Write-Host "  |  Tamanho: ${dSize} GB  |  Status: $dStatus"
    }
} else {
    Write-Host "  Nenhum disco secundário encontrado." -ForegroundColor Blue
}

# ------------------------------------------------------------------------------
# Rede
# ------------------------------------------------------------------------------
Write-Header "Rede"

$networkUrl    = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(networkInterfaces[0].network)" 2>$null
$subnetworkUrl = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(networkInterfaces[0].subnetwork)" 2>$null
$InternalIp    = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(networkInterfaces[0].networkIP)" 2>$null
$ExternalIp    = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>$null
$NicType       = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(networkInterfaces[0].nicType)" 2>$null

$Network    = ($networkUrl -split "/")[-1]
$Subnetwork = ($subnetworkUrl -split "/")[-1]
if ([string]::IsNullOrEmpty($NicType)) { $NicType = "VIRTIO_NET" }

# Verifica se o IP externo é estático (reservado) ou efêmero
$IpType = "N/A"
if (-not [string]::IsNullOrEmpty($ExternalIp)) {
    $staticCheck = gcloud compute addresses list `
        --project=$ProjectId `
        --filter="address=$ExternalIp AND region:$Region" `
        --format="value(name,status)" 2>$null
    if ($staticCheck) {
        $staticName = ($staticCheck -split "\s+")[0]
        $IpType = "ESTÁTICO (reservado: $staticName)"
    } else {
        $IpType = "EFÊMERO"
    }
}

Write-Row "VPC"         $Network
Write-Row "Subrede"     $Subnetwork
Write-Row "IP Interno"  $InternalIp
Write-Row "IP Externo"  $(if ($ExternalIp) { $ExternalIp } else { "Nenhum" }) "Green"
Write-Row "Tipo do IP"  $IpType "Yellow"
Write-Row "NIC"         $NicType

# ------------------------------------------------------------------------------
# Network Tags
# ------------------------------------------------------------------------------
Write-Header "Network Tags"

$Tags = gcloud compute instances describe $SourceVm `
    --zone=$Zone --project=$ProjectId `
    --format="value(tags.items)" 2>$null

if ($Tags) {
    Write-Host "  " -NoNewline
    Write-Host "(serão copiadas automaticamente para a nova VM)" -ForegroundColor Green
    Write-Host ""
    $tagList = $Tags -split ";"
    foreach ($tag in $tagList) {
        $tag = $tag.Trim()
        if ($tag) {
            Write-Host "    ▸ " -NoNewline -ForegroundColor Cyan
            Write-Host $tag
        }
    }
} else {
    Write-Host "  Nenhuma network tag encontrada." -ForegroundColor Blue
}

# ------------------------------------------------------------------------------
# Prévia da migração (se variáveis de destino estiverem preenchidas)
# ------------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($TargetFamily)) {
    Write-Header "Prévia da Migração"

    # Resolve tipo de disco
    if (-not [string]::IsNullOrEmpty($TargetDisk)) {
        $ResolvedDisk = $TargetDisk
    } else {
        $ResolvedDisk = switch ($TargetFamily) {
            { $_ -in "n4","c3","c3d","m3" } { "hyperdisk-balanced" }
            default { "pd-balanced" }
        }
    }

    # Ação no disco
    if ($BootDiskType -eq $ResolvedDisk) {
        $DiskActionText  = "REUTILIZAR — tipo igual ($ResolvedDisk), snapshot criado para segurança"
        $DiskActionColor = "Green"
        $CreateNew       = "não"
    } else {
        $DiskActionText  = "CRIAR NOVO — $BootDiskType → $ResolvedDisk (a partir do snapshot)"
        $DiskActionColor = "Yellow"
        $CreateNew       = "sim"
    }

    # NIC destino
    $NicDestino = if ($TargetFamily -in @("n4","c3","c3d","t2a","m3")) { "GVNIC (obrigatório)" }
                  elseif ($TargetFamily -in @("m1","m2"))               { "VIRTIO_NET" }
                  else                                                   { "VIRTIO_NET (GVNIC opcional)" }

    if (-not [string]::IsNullOrEmpty($FinalVmName)) {
        $TargetVm = $FinalVmName
    } else {
        $TargetVm = "$SourceVm-$TargetFamily"
    }

    Write-Divider
    Write-Row "VM destino"       $TargetVm       "Green"
    Write-Row "Família destino"  $TargetFamily   "Green"
    if (-not [string]::IsNullOrEmpty($MtOverride)) {
        Write-Row "Tipo destino" $MtOverride     "Green"
    } else {
        Write-Row "vCPUs destino"  $(if ($TargetVcpus) { $TargetVcpus } else { "?" })
        Write-Row "RAM destino"    $(if ($TargetMemGb)  { "${TargetMemGb} GB" } else { "?" })
    }
    Write-Row "Disco destino"    $ResolvedDisk    "Yellow"
    Write-Row "Novo disco?"      $CreateNew
    Write-Row "NIC destino"      $NicDestino
    Write-Divider
    Write-Host ""
    Write-Host ("  {0,-22}" -f "Ação no disco:") -NoNewline -ForegroundColor White
    Write-Host $DiskActionText -ForegroundColor $DiskActionColor
    Write-Host ("  {0,-22}" -f "IP externo:") -NoNewline -ForegroundColor White
    Write-Host "migrado automaticamente — sem configuração necessária" -ForegroundColor Green
    Write-Host ("  {0,-22}" -f "Network tags:") -NoNewline -ForegroundColor White
    Write-Host "copiadas automaticamente da VM de origem" -ForegroundColor Green

    Write-Host ""
    if ($TargetFamily -eq "t2a") {
        Write-Host "  ⚠ T2A usa arquitetura ARM — confirme compatibilidade do SO antes de migrar." -ForegroundColor Yellow
    }
    if ($NicType -eq "VIRTIO_NET" -and $TargetFamily -in @("n4","c3","c3d","t2a","m3")) {
        Write-Host "  ⚠ NIC mudará de VIRTIO_NET para GVNIC — confirme que o SO suporta (kernel >= 4.15)." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------------------
# Resumo final
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║               RESUMO                            ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "  VM            : " -NoNewline; Write-Host $SourceVm -ForegroundColor White -NoNewline
Write-Host " — " -NoNewline; Write-Host $VmStatus -ForegroundColor $statusColor
Write-Host "  Tipo          : " -NoNewline; Write-Host "$MachineType  ($SrcVcpus vCPUs / ${SrcRamGb} GB RAM)" -ForegroundColor Cyan
Write-Host "  Boot disk     : " -NoNewline; Write-Host "$BootDiskName  ($BootDiskType / ${BootDiskSize} GB)" -ForegroundColor Cyan
Write-Host "  Discos sec.   : $($SecDisks.Count)"
Write-Host "  IP externo    : " -NoNewline; Write-Host $(if ($ExternalIp) { $ExternalIp } else { "Nenhum" }) -ForegroundColor Green -NoNewline
Write-Host "  ($IpType)" -ForegroundColor Yellow
Write-Host "  IP interno    : $InternalIp"
Write-Host "  VPC / Subnet  : $Network / $Subnetwork"
Write-Host "  NIC           : $NicType"
if ($Tags) {
    $tagInline = ($Tags -replace ";", ", ")
    Write-Host "  Network tags  : " -NoNewline; Write-Host $tagInline -ForegroundColor Cyan
} else {
    Write-Host "  Network tags  : nenhuma"
}
Write-Host ""
