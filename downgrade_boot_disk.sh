#!/usr/bin/env bash
# ==============================================================================
# downgrade_boot_disk.sh — Reduz o tamanho do disco de boot de uma VM no GCP
#
# ESCOPO ESTRITO desta automação:
#   • Linux                                 (Windows não suportado)
#   • Filesystem ext4                       (xfs/btrfs/zfs NÃO suportados)
#   • Partição única em /dev/sda1           (LVM/criptografia/multi-partição NÃO suportados)
#   • Disco de BOOT (não disco de dados)
#
# Para qualquer cenário fora disso, siga o procedimento MANUAL no README.md.
#
# Fluxo automatizado:
#   1. Valida pré-requisitos (gcloud, jq) e configuração em terraform.tfvars
#   2. Verifica uso real do filesystem na VM de origem via SSH
#   3. Cria snapshot manual de segurança (rede de proteção, fora do Terraform)
#   4. Para a VM de origem
#   5. Cria VM temporária e2-small Debian 12 na mesma zona
#   6. Desanexa o disco de boot da origem e anexa na temporária como secundário
#   7. Detecta filesystem/partição na temporária e ABORTA se não for ext4 + sda1
#   8. Executa e2fsck -f + resize2fs (reduz filesystem)
#   9. Reduz a partição com parted
#  10. Desanexa o disco da temporária, devolve para a origem como BOOT
#  11. Apaga a VM temporária
#  12. (Não inicia a origem automaticamente — o migrate.sh fará isso depois)
#
# Uso:
#   ./downgrade_boot_disk.sh                # interativo
#   ./downgrade_boot_disk.sh --yes          # sem confirmação (para CI)
#   ./downgrade_boot_disk.sh --dry-run      # mostra plano sem executar
#   ./downgrade_boot_disk.sh -h             # ajuda
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'
MAGENTA='\033[0;35m'; NC='\033[0m'

log()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()    { echo -e "${RED}[ERRO]${NC}  $1" >&2; }
step()   { echo ""; echo -e "${BOLD}${CYAN}▶ $1${NC}"; echo ""; }

# ------------------------------------------------------------------------------
# Flags
# ------------------------------------------------------------------------------
AUTO_YES=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes)     AUTO_YES=true ;;
    --dry-run)    DRY_RUN=true ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      err "Argumento desconhecido: $arg"
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Pré-requisitos
# ------------------------------------------------------------------------------
for tool in gcloud; do
  command -v "$tool" &>/dev/null || { err "Ferramenta não encontrada: $tool"; exit 1; }
done

if [[ ! -f "terraform.tfvars" ]]; then
  err "terraform.tfvars não encontrado no diretório atual."
  exit 1
fi

get_tfvar() {
  local key="$1"
  grep -E "^\s*${key}\s*=" terraform.tfvars 2>/dev/null \
    | head -1 | sed 's/[^=]*=\s*//' \
    | tr -d '"' | tr -d "'" | sed 's/\s*#.*//' | xargs || true
}

# ------------------------------------------------------------------------------
# Carrega configuração
# ------------------------------------------------------------------------------
PROJECT_ID=$(get_tfvar "project_id")
ZONE=$(get_tfvar "zone")
REGION=$(get_tfvar "region")
SOURCE_VM=$(get_tfvar "source_instance_name")
CHANGE_DISK_SIZE=$(get_tfvar "change_disk_size")
TARGET_DISK_SIZE=$(get_tfvar "target_disk_size")
TELEGRAM_TOKEN=$(get_tfvar "telegram_bot_token")
TELEGRAM_CHAT=$(get_tfvar "telegram_chat_id")

# ------------------------------------------------------------------------------
# Notificação Telegram — envia se TOKEN/CHAT estiverem configurados
# Uso: tg "<HTML mensagem>"
# Não falha o script se o Telegram estiver offline (|| true)
# ------------------------------------------------------------------------------
tg() {
  local msg="$1"
  if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT" ]]; then
    return 0
  fi
  if ! command -v curl &>/dev/null; then
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=${msg}" > /dev/null 2>&1 || true
}

# Trap de erro: envia notificação Telegram em qualquer falha não tratada
DOWNGRADE_STARTED=false
on_error() {
  local exit_code=$?
  if [[ "$DOWNGRADE_STARTED" == "true" ]]; then
    tg "$(printf '%s\n' \
      "❌ <b>DOWNGRADE DE DISCO — FALHA</b>" \
      "━━━━━━━━━━━━━━━━━━━━━━━━" \
      "🖥  VM       : <code>${SOURCE_VM}</code>" \
      "📋 Projeto  : <code>${PROJECT_ID}</code>" \
      "💥 Exit code: <code>${exit_code}</code>" \
      "⏱  Hora     : <b>$(date '+%d/%m/%Y %H:%M:%S')</b>" \
      "" \
      "⚠️ Verifique o snapshot de seguranca para rollback se necessario.")"
  fi
  exit $exit_code
}
trap on_error ERR

[[ -z "$PROJECT_ID" ]] && { err "project_id não preenchido em terraform.tfvars."; exit 1; }
[[ -z "$ZONE" ]]       && { err "zone não preenchido em terraform.tfvars."; exit 1; }
[[ -z "$SOURCE_VM" ]]  && { err "source_instance_name não preenchido em terraform.tfvars."; exit 1; }

if [[ "$CHANGE_DISK_SIZE" != "true" ]]; then
  err "change_disk_size deve ser 'true' em terraform.tfvars para usar este script."
  err "Sem isso, o migrate.sh manteria o tamanho original — o downgrade seria perdido."
  exit 1
fi

if [[ -z "$TARGET_DISK_SIZE" || "$TARGET_DISK_SIZE" -le 0 ]] 2>/dev/null; then
  err "target_disk_size deve ser um inteiro > 0 em terraform.tfvars."
  exit 1
fi

# Margens de segurança:
#   FS reduzido em (TARGET - 10) GB
#   Partição reduzida em (TARGET - 5) GB
FS_NEW_SIZE_GB=$((TARGET_DISK_SIZE - 10))
PART_NEW_SIZE_GB=$((TARGET_DISK_SIZE - 5))

if [[ "$FS_NEW_SIZE_GB" -le 5 ]]; then
  err "target_disk_size = ${TARGET_DISK_SIZE} GB é pequeno demais (mínimo viável: 16 GB)."
  exit 1
fi

TEMP_VM_NAME="${SOURCE_VM}-resize-temp"
SNAPSHOT_SAFETY_NAME="${SOURCE_VM}-pre-downgrade-$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------------------------
# Lê informações da VM de origem
# ------------------------------------------------------------------------------
step "Lendo informações da VM de origem"

SOURCE_STATUS=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [[ "$SOURCE_STATUS" == "NOT_FOUND" ]]; then
  err "VM '$SOURCE_VM' não encontrada no projeto '$PROJECT_ID', zona '$ZONE'."
  exit 1
fi

BOOT_DISK_SOURCE=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(disks[0].source)")
BOOT_DISK_NAME=$(basename "$BOOT_DISK_SOURCE")

BOOT_DISK_SIZE_GB=$(gcloud compute disks describe "$BOOT_DISK_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(sizeGb)")

ok "VM: $SOURCE_VM (status: $SOURCE_STATUS)"
ok "Disco de boot: $BOOT_DISK_NAME (${BOOT_DISK_SIZE_GB} GB)"

if [[ "$TARGET_DISK_SIZE" -ge "$BOOT_DISK_SIZE_GB" ]]; then
  err "target_disk_size (${TARGET_DISK_SIZE} GB) >= tamanho atual (${BOOT_DISK_SIZE_GB} GB)."
  err "Este script é APENAS para DOWNGRADE. Para upgrade, basta rodar ./migrate.sh."
  exit 1
fi

# ------------------------------------------------------------------------------
# Validação pré-execução: SO + filesystem na VM de origem (via SSH)
# ------------------------------------------------------------------------------
step "Verificando filesystem da VM de origem via SSH"

if [[ "$SOURCE_STATUS" != "RUNNING" ]]; then
  warn "VM '$SOURCE_VM' não está RUNNING (status: $SOURCE_STATUS)."
  warn "É necessário ligá-la temporariamente para inspecionar o filesystem."
  if [[ "$AUTO_YES" != "true" ]]; then
    read -r -p "Iniciar a VM agora para validação? (sim/nao): " RESP
    [[ "$RESP" != "sim" ]] && { err "Abortado pelo usuário."; exit 1; }
  fi
  if [[ "$DRY_RUN" != "true" ]]; then
    gcloud compute instances start "$SOURCE_VM" --zone="$ZONE" --project="$PROJECT_ID" --quiet
    log "Aguardando 30s para o SSH ficar pronto..."
    sleep 30
  fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
  FS_INFO=$(gcloud compute ssh "$SOURCE_VM" --zone="$ZONE" --project="$PROJECT_ID" \
    --command="
ROOT_DEV=\$(findmnt -n -o SOURCE /)
ROOT_REAL=\$(readlink -f \"\$ROOT_DEV\")
PART_NAME=\$(basename \"\$ROOT_REAL\")
DISK_NAME=\$(echo \"\$PART_NAME\" | sed 's/1\$//')
FSTYPE=\$(lsblk -n -o FSTYPE \"\$ROOT_REAL\")
PART_COUNT=\$(lsblk -n -o NAME \"/dev/\$DISK_NAME\" 2>/dev/null | tail -n +2 | wc -l)
USED_GB=\$(df -B1G --output=used / | tail -1 | tr -d ' ')
echo \"DEV=\$ROOT_REAL FS=\$FSTYPE PARTS=\$PART_COUNT USED=\${USED_GB}G\"
lsblk -n -o NAME,FSTYPE \"/dev/\$DISK_NAME\" 2>/dev/null || true
" \
    --quiet 2>/dev/null) || {
      err "Falha ao conectar via SSH na VM de origem."
      err "Verifique conectividade, firewall e permissões IAM."
      exit 1
    }

  echo "$FS_INFO" | sed 's/^/    /'

  # Extrai a linha principal
  MAIN_LINE=$(echo "$FS_INFO" | grep "^DEV=")
  SRC_DEVICE=$(echo "$MAIN_LINE" | sed 's/.*DEV=//' | awk '{print $1}')
  SRC_FSTYPE=$(echo "$MAIN_LINE" | sed 's/.*FS=//' | awk '{print $1}')
  SRC_PARTS=$(echo "$MAIN_LINE" | sed 's/.*PARTS=//' | awk '{print $1}')
  SRC_USED_STR=$(echo "$MAIN_LINE" | sed 's/.*USED=//' | awk '{print $1}')
  SRC_USED_GB=${SRC_USED_STR%G}

  # Valida que a partição raiz termina com "da1" (ex: /dev/sda1, /dev/vda1)
  PART_NAME=$(basename "$SRC_DEVICE")
  if [[ ! "$PART_NAME" =~ ^[sv]da1$ ]]; then
    err "Partição raiz não é sda1/vda1 (encontrada: $PART_NAME em $SRC_DEVICE)."
    err "Este script suporta APENAS partição única /dev/sda1. Use o procedimento manual."
    exit 1
  fi

  if [[ "$SRC_FSTYPE" != "ext4" ]]; then
    err "Filesystem não é ext4 (encontrado: $SRC_FSTYPE)."
    err "Este script suporta APENAS ext4. Para xfs/btrfs/lvm, use o procedimento manual."
    exit 1
  fi

  if [[ "$SRC_PARTS" -ne 1 ]]; then
    err "Disco tem $SRC_PARTS partições. Esperado: exatamente 1."
    err "Este script suporta APENAS partição única. Use o procedimento manual."
    exit 1
  fi

  if [[ "$SRC_USED_GB" -ge "$FS_NEW_SIZE_GB" ]]; then
    err "Espaço usado (${SRC_USED_GB} GB) >= tamanho alvo do FS (${FS_NEW_SIZE_GB} GB)."
    err "Libere espaço antes de prosseguir (apague logs, caches, arquivos grandes)."
    exit 1
  fi

  ok "Filesystem: ext4 em $SRC_DEVICE"
  ok "Usado: ${SRC_USED_GB} GB | FS será reduzido para: ${FS_NEW_SIZE_GB} GB | Margem: $((FS_NEW_SIZE_GB - SRC_USED_GB)) GB"
fi

# ------------------------------------------------------------------------------
# Resumo do plano e confirmação
# ------------------------------------------------------------------------------
step "Resumo do plano de downgrade"

cat <<EOF
  Projeto         : $PROJECT_ID
  Zona            : $ZONE
  VM de origem    : $SOURCE_VM
  Disco           : $BOOT_DISK_NAME (${BOOT_DISK_SIZE_GB} GB)

  Tamanho alvo    : ${TARGET_DISK_SIZE} GB (definido em terraform.tfvars)
  FS será reduzido para  : ${FS_NEW_SIZE_GB} GB
  Partição reduzida para : ${PART_NEW_SIZE_GB} GB

  Snapshot de segurança  : $SNAPSHOT_SAFETY_NAME
  VM temporária          : $TEMP_VM_NAME (e2-small, Debian 12)
EOF
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY-RUN: nenhuma alteração será aplicada."
  exit 0
fi

if [[ "$AUTO_YES" != "true" ]]; then
  echo -e "${BOLD}${YELLOW}⚠  Esta operação para a VM '$SOURCE_VM' e reduz o disco de boot.${NC}"
  echo -e "${BOLD}${YELLOW}⚠  Em caso de falha, o snapshot '$SNAPSHOT_SAFETY_NAME' permite rollback.${NC}"
  echo ""
  read -r -p "Digite 'sim' para prosseguir: " RESP
  [[ "$RESP" != "sim" ]] && { err "Abortado pelo usuário."; exit 1; }
fi

# Marca que o downgrade começou para o trap de erro notificar falhas
DOWNGRADE_STARTED=true
DOWNGRADE_START_TS=$(date +%s)

# ------------------------------------------------------------------------------
# Notificação Telegram — início do downgrade
# ------------------------------------------------------------------------------
tg "$(printf '%s\n' \
  "🔧 <b>DOWNGRADE DE DISCO INICIADO</b>" \
  "━━━━━━━━━━━━━━━━━━━━━━━━" \
  "🖥  VM         : <code>${SOURCE_VM}</code>" \
  "💾 Disco      : <code>${BOOT_DISK_NAME}</code>" \
  "📐 De         : <b>${BOOT_DISK_SIZE_GB} GB</b>" \
  "📏 Para       : <b>${TARGET_DISK_SIZE} GB</b>" \
  "  • FS final  : ${FS_NEW_SIZE_GB} GB" \
  "  • Partição  : ${PART_NEW_SIZE_GB} GB" \
  "📋 Projeto    : <code>${PROJECT_ID}</code>" \
  "🌍 Zona       : <code>${ZONE}</code>" \
  "⏱  Início    : <b>$(date '+%d/%m/%Y %H:%M:%S')</b>")"

# ------------------------------------------------------------------------------
# Passo: snapshot de segurança
# ------------------------------------------------------------------------------
step "Passo 1/8 — Snapshot manual de segurança"

gcloud compute disks snapshot "$BOOT_DISK_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --snapshot-names="$SNAPSHOT_SAFETY_NAME" \
  --storage-location="$REGION" \
  --quiet
ok "Snapshot criado: $SNAPSHOT_SAFETY_NAME"

tg "$(printf '%s\n' \
  "✅ <b>Passo 1/8 — Snapshot de seguranca criado</b>" \
  "📸 <code>${SNAPSHOT_SAFETY_NAME}</code>" \
  "📍 Região: <code>${REGION}</code>" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Passo: parar VM origem
# ------------------------------------------------------------------------------
step "Passo 2/8 — Parando VM de origem"

CURRENT_STATUS=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" --format="value(status)")
if [[ "$CURRENT_STATUS" == "RUNNING" || "$CURRENT_STATUS" == "STAGING" ]]; then
  gcloud compute instances stop "$SOURCE_VM" --zone="$ZONE" --project="$PROJECT_ID" --quiet
  ok "VM parada."
else
  ok "VM já estava parada (status: $CURRENT_STATUS)."
fi

tg "$(printf '%s\n' \
  "✅ <b>Passo 2/8 — VM de origem parada</b>" \
  "🔴 <code>${SOURCE_VM}</code>" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Passo: criar VM temporária
# ------------------------------------------------------------------------------
step "Passo 3/8 — Criando VM temporária $TEMP_VM_NAME"

# Verifica se já existe (execução anterior incompleta)
TEMP_EXISTS=$(gcloud compute instances describe "$TEMP_VM_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(name)" 2>/dev/null || echo "")

if [[ -n "$TEMP_EXISTS" ]]; then
  warn "VM temporária $TEMP_VM_NAME já existe (execução anterior?). Reutilizando."
else
  gcloud compute instances create "$TEMP_VM_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --machine-type=e2-small \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=10GB \
    --no-address \
    --quiet 2>&1 | tail -3 || {
      # Tenta com IP externo se a flag --no-address não for permitida pela rede
      log "Retry: criando com IP externo padrão..."
      gcloud compute instances create "$TEMP_VM_NAME" \
        --zone="$ZONE" --project="$PROJECT_ID" \
        --machine-type=e2-small \
        --image-family=debian-12 --image-project=debian-cloud \
        --boot-disk-size=10GB \
        --quiet
    }
  ok "VM temporária criada."
  log "Aguardando 25s para a VM ficar pronta para SSH..."
  sleep 25
fi

tg "$(printf '%s\n' \
  "✅ <b>Passo 3/8 — VM temporaria pronta</b>" \
  "🆕 <code>${TEMP_VM_NAME}</code> (e2-small, Debian 12)" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Passo: mover disco da origem para a temporária
# ------------------------------------------------------------------------------
step "Passo 4/8 — Movendo disco de boot para VM temporária"

# Desanexa da origem
gcloud compute instances detach-disk "$SOURCE_VM" \
  --disk="$BOOT_DISK_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>&1 | tail -2 || true
ok "Disco desanexado de $SOURCE_VM."

# Anexa na temporária como secundário
gcloud compute instances attach-disk "$TEMP_VM_NAME" \
  --disk="$BOOT_DISK_NAME" \
  --device-name="resize-target" \
  --zone="$ZONE" --project="$PROJECT_ID" --quiet
ok "Disco anexado em $TEMP_VM_NAME (device-name: resize-target)."

tg "$(printf '%s\n' \
  "✅ <b>Passo 4/8 — Disco movido</b>" \
  "💾 <code>${BOOT_DISK_NAME}</code>" \
  "🔁 <code>${SOURCE_VM}</code> ➡️ <code>${TEMP_VM_NAME}</code>" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Passo: executa resize remoto
# ------------------------------------------------------------------------------
step "Passo 5/8 — Reduzindo filesystem e partição via SSH na VM temporária"

# Script remoto — escapa $-variables e usa o linux device by-id para detectar o disco
REMOTE_SCRIPT=$(cat <<REMOTE_EOF
set -e
echo ">>> Procurando o disco anexado..."

# O device name 'resize-target' aparece como /dev/disk/by-id/google-resize-target
DISK_DEV=\$(readlink -f /dev/disk/by-id/google-resize-target)
PART_DEV="\${DISK_DEV}1"

echo ">>> Disco detectado: \$DISK_DEV"
echo ">>> Partição alvo:   \$PART_DEV"

if [ ! -b "\$DISK_DEV" ]; then
  echo "ERRO: disco \$DISK_DEV não encontrado"
  exit 11
fi
if [ ! -b "\$PART_DEV" ]; then
  echo "ERRO: partição \$PART_DEV não encontrada"
  exit 12
fi

# Garante que não está montado
sudo umount "\$PART_DEV" 2>/dev/null || true

# Valida que é ext4 (segunda checagem, defensiva)
FSTYPE=\$(sudo blkid -o value -s TYPE "\$PART_DEV")
if [ "\$FSTYPE" != "ext4" ]; then
  echo "ERRO: filesystem em \$PART_DEV é '\$FSTYPE', esperado 'ext4'"
  exit 13
fi

# Conta partições do disco
NUM_PARTS=\$(lsblk -n -o NAME "\$DISK_DEV" | tail -n +2 | wc -l)
if [ "\$NUM_PARTS" -ne 1 ]; then
  echo "ERRO: disco tem \$NUM_PARTS partições. Esperado: 1 (apenas sda1)."
  exit 14
fi

echo ">>> Filesystem check (e2fsck -fy)..."
sudo e2fsck -fy "\$PART_DEV"

echo ">>> Reduzindo filesystem para ${FS_NEW_SIZE_GB}G..."
sudo resize2fs "\$PART_DEV" ${FS_NEW_SIZE_GB}G

echo ">>> Reduzindo partição para ${PART_NEW_SIZE_GB}GB..."
# parted requer aceite interativo; usamos ---pretend-input-tty + Yes
sudo parted "\$DISK_DEV" ---pretend-input-tty <<PARTED_EOF
resizepart 1
${PART_NEW_SIZE_GB}GB
Yes
PARTED_EOF

echo ">>> Verificação final:"
sudo parted "\$DISK_DEV" print
sudo e2fsck -fy "\$PART_DEV"

echo ">>> SUCESSO: filesystem em \$(sudo tune2fs -l \$PART_DEV | grep 'Block count' | awk '{print \$3}') blocos."
REMOTE_EOF
)

# Re-tenta o SSH algumas vezes (sshd pode demorar)
SSH_OK=false
for attempt in 1 2 3 4; do
  if gcloud compute ssh "$TEMP_VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
      --command="$REMOTE_SCRIPT" 2>&1 | tee /tmp/downgrade_remote.log; then
    SSH_OK=true
    break
  else
    warn "Tentativa $attempt falhou. Aguardando 15s..."
    sleep 15
  fi
done

if [[ "$SSH_OK" != "true" ]]; then
  err "Falha ao executar resize remoto após 4 tentativas."
  err "O disco continua anexado a $TEMP_VM_NAME. Snapshot de segurança preservado: $SNAPSHOT_SAFETY_NAME"
  err "Para rollback manual:"
  err "  1. gcloud compute instances detach-disk $TEMP_VM_NAME --disk=$BOOT_DISK_NAME --zone=$ZONE --project=$PROJECT_ID"
  err "  2. gcloud compute instances attach-disk $SOURCE_VM --disk=$BOOT_DISK_NAME --boot --zone=$ZONE --project=$PROJECT_ID"
  err "  3. gcloud compute instances delete $TEMP_VM_NAME --zone=$ZONE --project=$PROJECT_ID --quiet"
  exit 1
fi
ok "Filesystem e partição reduzidos com sucesso."

tg "$(printf '%s\n' \
  "✅ <b>Passo 5/8 — Filesystem e particao reduzidos</b>" \
  "📏 FS       : <b>${FS_NEW_SIZE_GB} GB</b>" \
  "🔢 Partição : <b>${PART_NEW_SIZE_GB} GB</b>" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Passo: devolver disco para a VM origem
# ------------------------------------------------------------------------------
step "Passo 6/8 — Devolvendo disco para a VM de origem"

gcloud compute instances detach-disk "$TEMP_VM_NAME" \
  --disk="$BOOT_DISK_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" --quiet
ok "Disco desanexado da VM temporária."

gcloud compute instances attach-disk "$SOURCE_VM" \
  --disk="$BOOT_DISK_NAME" \
  --boot \
  --zone="$ZONE" --project="$PROJECT_ID" --quiet
ok "Disco reanexado em $SOURCE_VM como BOOT."

tg "$(printf '%s\n' \
  "✅ <b>Passo 6/8 — Disco devolvido a origem</b>" \
  "🔁 <code>${TEMP_VM_NAME}</code> ➡️ <code>${SOURCE_VM}</code> (boot)" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Passo: apagar VM temporária
# ------------------------------------------------------------------------------
step "Passo 7/8 — Apagando VM temporária"

gcloud compute instances delete "$TEMP_VM_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" --quiet
ok "VM temporária $TEMP_VM_NAME removida."

tg "$(printf '%s\n' \
  "✅ <b>Passo 7/8 — VM temporaria removida</b>" \
  "🗑  <code>${TEMP_VM_NAME}</code>" \
  "⏱  $(date '+%H:%M:%S')")"

# ------------------------------------------------------------------------------
# Final
# ------------------------------------------------------------------------------
step "Passo 8/8 — Downgrade preparado"

# Calcula duração total
DOWNGRADE_END_TS=$(date +%s)
DIFF=$((DOWNGRADE_END_TS - DOWNGRADE_START_TS))
DUR_MIN=$((DIFF / 60))
DUR_SEC=$((DIFF % 60))
DURATION="${DUR_MIN}m ${DUR_SEC}s"

# Desativa o trap de erro — daqui pra frente não pode notificar falha
trap - ERR

tg "$(printf '%s\n' \
  "🎉 <b>DOWNGRADE PREPARADO COM SUCESSO</b>" \
  "━━━━━━━━━━━━━━━━━━━━━━━━" \
  "🖥  VM         : <code>${SOURCE_VM}</code>" \
  "💾 Disco      : <code>${BOOT_DISK_NAME}</code>" \
  "📐 Origem     : ${BOOT_DISK_SIZE_GB} GB (físico, inalterado)" \
  "📏 FS final   : <b>${FS_NEW_SIZE_GB} GB</b>" \
  "🔢 Partição   : <b>${PART_NEW_SIZE_GB} GB</b>" \
  "🎯 Alvo       : <b>${TARGET_DISK_SIZE} GB</b> (após migrate.sh)" \
  "📸 Snapshot   : <code>${SNAPSHOT_SAFETY_NAME}</code>" \
  "⏱  Duração   : <b>${DURATION}</b>" \
  "🕐 Fim        : <b>$(date '+%d/%m/%Y %H:%M:%S')</b>" \
  "" \
  "▶ Proximo: <code>./migrate.sh</code>")"

cat <<EOF
${GREEN}${BOLD}✅ Disco de boot preparado para downgrade.${NC}

  Disco: $BOOT_DISK_NAME
    • Tamanho físico        : ${BOOT_DISK_SIZE_GB} GB (inalterado neste passo)
    • Filesystem reduzido p/: ${FS_NEW_SIZE_GB} GB
    • Partição reduzida p/  : ${PART_NEW_SIZE_GB} GB

  Snapshot de rollback     : $SNAPSHOT_SAFETY_NAME
  Duração total            : ${DURATION}

${BOLD}Próximos passos:${NC}
  1. (Opcional) Inicie a VM '$SOURCE_VM' temporariamente para validar que sobe:
       gcloud compute instances start $SOURCE_VM --zone=$ZONE --project=$PROJECT_ID
       gcloud compute ssh $SOURCE_VM --zone=$ZONE --project=$PROJECT_ID
       df -h /        # deve mostrar ~${FS_NEW_SIZE_GB}G
       gcloud compute instances stop $SOURCE_VM --zone=$ZONE --project=$PROJECT_ID

  2. Rode a migração — ela criará um novo disco de ${TARGET_DISK_SIZE} GB a partir do snapshot:
       ./migrate.sh

  3. Após a migração, na nova VM, expanda o FS para usar todo o disco de ${TARGET_DISK_SIZE} GB:
       gcloud compute ssh <nova-vm> --zone=$ZONE --project=$PROJECT_ID
       sudo growpart /dev/sda 1
       sudo resize2fs /dev/sda1
EOF
