#!/usr/bin/env bash
# ==============================================================================
# check_project.sh — Consulta e exibe todas as informações da VM a ser migrada
#
# Lê project_id, zone e source_instance_name do terraform.tfvars e exibe um
# relatório completo: máquina, discos, rede, IPs, tags e prévia da migração.
#
# Uso:
#   ./check_project.sh           → lê do terraform.tfvars
#   ./check_project.sh -h        → ajuda
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'
MAGENTA='\033[0;35m'; NC='\033[0m'

log()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()    { echo -e "${RED}[ERRO]${NC}  $1" >&2; }
header() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
  echo ""
}
row() {
  # row "Label" "Valor" [cor_valor]
  local label="$1" value="$2" color="${3:-$NC}"
  printf "  ${BOLD}%-22s${NC} ${color}%s${NC}\n" "$label" "$value"
}
divider() { echo -e "  ${BLUE}──────────────────────────────────────────────${NC}"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "  Lê project_id, zone e source_instance_name do terraform.tfvars"
  echo "  e exibe um relatório completo da VM."
  exit 0
fi

# ------------------------------------------------------------------------------
# Lê um valor do terraform.tfvars
# ------------------------------------------------------------------------------
get_tfvar() {
  local key="$1"
  grep -E "^\s*${key}\s*=" terraform.tfvars 2>/dev/null \
    | head -1 \
    | sed 's/[^=]*=\s*//' \
    | tr -d '"' | tr -d "'" \
    | sed 's/\s*#.*//' \
    | xargs || true
}

# ------------------------------------------------------------------------------
# Pré-requisitos
# ------------------------------------------------------------------------------
for tool in gcloud terraform; do
  command -v "$tool" &>/dev/null || { err "Ferramenta não encontrada: $tool"; exit 1; }
done

if [[ ! -f "terraform.tfvars" ]]; then
  err "terraform.tfvars não encontrado no diretório atual."
  exit 1
fi

# ------------------------------------------------------------------------------
# Carrega variáveis do tfvars
# ------------------------------------------------------------------------------
PROJECT_ID=$(get_tfvar "project_id")
ZONE=$(get_tfvar "zone")
REGION=$(get_tfvar "region")
SOURCE_VM=$(get_tfvar "source_instance_name")

# Variáveis de destino (opcionais — usadas para prévia da migração)
TARGET_FAMILY=$(get_tfvar "target_machine_family")
TARGET_DISK_TYPE=$(get_tfvar "target_disk_type")
TARGET_VCPUS=$(get_tfvar "target_vcpus")
TARGET_MEM_GB=$(get_tfvar "target_memory_gb")
MT_OVERRIDE=$(get_tfvar "machine_type_override")

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "projeto-aqui" ]]; then
  err "project_id não preenchido em terraform.tfvars."
  exit 1
fi
if [[ -z "$SOURCE_VM" || "$SOURCE_VM" == "minha-vm" ]]; then
  err "source_instance_name não preenchido em terraform.tfvars."
  exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         RELATÓRIO DE VM — PRÉ-MIGRAÇÃO           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
row "Projeto:" "$PROJECT_ID" "$CYAN"
row "Região:"  "$REGION"     "$CYAN"
row "Zona:"    "$ZONE"       "$CYAN"

# ------------------------------------------------------------------------------
# Consulta a VM
# ------------------------------------------------------------------------------
header "Instância"

log "Consultando VM '$SOURCE_VM'..."

VM_JSON=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="json" 2>/dev/null || echo "")

if [[ -z "$VM_JSON" ]]; then
  err "VM '$SOURCE_VM' não encontrada no projeto '$PROJECT_ID', zona '$ZONE'."
  exit 1
fi

MACHINE_TYPE_URL=$(echo "$VM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('machineType',''))" 2>/dev/null || \
  gcloud compute instances describe "$SOURCE_VM" --zone="$ZONE" --project="$PROJECT_ID" --format="value(machineType)")
MACHINE_TYPE=$(echo "$MACHINE_TYPE_URL" | awk -F'/' '{print $NF}')
VM_STATUS=$(echo "$VM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || \
  gcloud compute instances describe "$SOURCE_VM" --zone="$ZONE" --project="$PROJECT_ID" --format="value(status)")
SOURCE_FAMILY=$(echo "$MACHINE_TYPE" | cut -d'-' -f1)

# Busca vCPUs e RAM reais via API
MT_SPECS=$(gcloud compute machine-types describe "$MACHINE_TYPE" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="csv[no-heading](guestCpus,memoryMb)" 2>/dev/null || echo "")

if [[ -n "$MT_SPECS" ]]; then
  SRC_VCPUS=$(echo "$MT_SPECS" | cut -d',' -f1)
  SRC_RAM_MB=$(echo "$MT_SPECS" | cut -d',' -f2)
  SRC_RAM_GB=$(( (SRC_RAM_MB + 512) / 1024 ))
else
  SRC_VCPUS="?"
  SRC_RAM_GB="?"
fi

# Status com ícone
if [[ "$VM_STATUS" == "RUNNING" ]]; then
  STATUS_DISPLAY="${GREEN}● RUNNING${NC}"
elif [[ "$VM_STATUS" == "TERMINATED" || "$VM_STATUS" == "STOPPED" ]]; then
  STATUS_DISPLAY="${RED}● $VM_STATUS${NC}"
else
  STATUS_DISPLAY="${YELLOW}● $VM_STATUS${NC}"
fi

row "Nome:"         "$SOURCE_VM"    "$GREEN"
row "Status:"       "" ; printf "  ${BOLD}%-22s${NC} " ""; echo -e "$STATUS_DISPLAY"
row "Tipo:"         "$MACHINE_TYPE" "$CYAN"
row "Família:"      "$SOURCE_FAMILY"
row "vCPUs:"        "$SRC_VCPUS"
row "RAM:"          "${SRC_RAM_GB} GB"

# ------------------------------------------------------------------------------
# Disco de boot
# ------------------------------------------------------------------------------
header "Disco de Boot"

BOOT_DISK_SOURCE=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(disks[0].source)" 2>/dev/null || echo "")
BOOT_DISK_NAME=$(echo "$BOOT_DISK_SOURCE" | awk -F'/' '{print $NF}')
BOOT_DISK_MODE=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(disks[0].mode)" 2>/dev/null || echo "READ_WRITE")

if [[ -n "$BOOT_DISK_NAME" ]]; then
  DISK_INFO=$(gcloud compute disks describe "$BOOT_DISK_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --format="csv[no-heading](type,sizeGb,status)" 2>/dev/null || echo "")
  BOOT_DISK_TYPE=$(echo "$DISK_INFO" | cut -d',' -f1 | awk -F'/' '{print $NF}')
  BOOT_DISK_SIZE=$(echo "$DISK_INFO" | cut -d',' -f2)
  BOOT_DISK_STATUS=$(echo "$DISK_INFO" | cut -d',' -f3)

  row "Nome:"    "$BOOT_DISK_NAME"  "$CYAN"
  row "Tipo:"    "$BOOT_DISK_TYPE"  "$YELLOW"
  row "Tamanho:" "${BOOT_DISK_SIZE} GB"
  row "Status:"  "$BOOT_DISK_STATUS"
  row "Modo:"    "$BOOT_DISK_MODE"
else
  warn "Não foi possível identificar o disco de boot."
  BOOT_DISK_TYPE="unknown"
  BOOT_DISK_SIZE="unknown"
fi

# ------------------------------------------------------------------------------
# Discos secundários
# ------------------------------------------------------------------------------
SEC_DISKS_JSON=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="json(disks)" 2>/dev/null || echo "")

# Filtra discos que não são boot (boot=true na lista)
SEC_DISK_SOURCES=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(disks[1:].source)" 2>/dev/null || echo "")

SEC_COUNT=0
declare -a SEC_NAMES=()
if [[ -n "$SEC_DISK_SOURCES" ]]; then
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    name=$(echo "$src" | awk -F'/' '{print $NF}')
    SEC_NAMES+=("$name")
    ((SEC_COUNT++))
  done <<< "$SEC_DISK_SOURCES"
fi

if [[ $SEC_COUNT -gt 0 ]]; then
  header "Discos Secundários ($SEC_COUNT)"
  for name in "${SEC_NAMES[@]}"; do
    disk_info=$(gcloud compute disks describe "$name" \
      --zone="$ZONE" --project="$PROJECT_ID" \
      --format="csv[no-heading](type,sizeGb,status)" 2>/dev/null || echo "")
    d_type=$(echo "$disk_info" | cut -d',' -f1 | awk -F'/' '{print $NF}')
    d_size=$(echo "$disk_info" | cut -d',' -f2)
    d_status=$(echo "$disk_info" | cut -d',' -f3)
    echo -e "  ${BOLD}${CYAN}▸ $name${NC}"
    echo -e "    Tipo: ${YELLOW}$d_type${NC}  |  Tamanho: ${d_size} GB  |  Status: $d_status"
  done
else
  header "Discos Secundários"
  echo -e "  ${BLUE}Nenhum disco secundário encontrado.${NC}"
fi

# ------------------------------------------------------------------------------
# Rede
# ------------------------------------------------------------------------------
header "Rede"

NETWORK_URL=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].network)" 2>/dev/null || echo "")
SUBNETWORK_URL=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].subnetwork)" 2>/dev/null || echo "")
INTERNAL_IP=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "N/A")
EXTERNAL_IP=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "")
NIC_TYPE=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(networkInterfaces[0].nicType)" 2>/dev/null || echo "VIRTIO_NET")

NETWORK=$(echo "$NETWORK_URL" | awk -F'/' '{print $NF}')
SUBNETWORK=$(echo "$SUBNETWORK_URL" | awk -F'/' '{print $NF}')
[[ -z "$NIC_TYPE" ]] && NIC_TYPE="VIRTIO_NET"

# Verifica se o IP externo é estático (reservado) ou efêmero
IP_TYPE="N/A"
if [[ -n "$EXTERNAL_IP" ]]; then
  STATIC_CHECK=$(gcloud compute addresses list \
    --project="$PROJECT_ID" \
    --filter="address=$EXTERNAL_IP AND region:$REGION" \
    --format="value(name,status)" 2>/dev/null || echo "")
  if [[ -n "$STATIC_CHECK" ]]; then
    STATIC_NAME=$(echo "$STATIC_CHECK" | awk '{print $1}')
    IP_TYPE="ESTÁTICO (reservado: $STATIC_NAME)"
  else
    IP_TYPE="EFÊMERO"
  fi
fi

row "VPC:"          "$NETWORK"
row "Subrede:"      "$SUBNETWORK"
row "IP Interno:"   "$INTERNAL_IP"
row "IP Externo:"   "${EXTERNAL_IP:-Nenhum}"  "$GREEN"
row "Tipo do IP:"   "$IP_TYPE"                 "$YELLOW"
row "NIC:"          "$NIC_TYPE"

# ------------------------------------------------------------------------------
# Network Tags
# ------------------------------------------------------------------------------
header "Network Tags"

TAGS=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(tags.items)" 2>/dev/null || echo "")

if [[ -n "$TAGS" ]]; then
  echo -e "  ${GREEN}Tags encontradas (serão copiadas automaticamente para a nova VM):${NC}"
  echo ""
  while IFS=';' read -ra TAG_LIST; do
    for tag in "${TAG_LIST[@]}"; do
      [[ -n "$tag" ]] && echo -e "    ${CYAN}▸${NC} $tag"
    done
  done <<< "$TAGS"
else
  echo -e "  ${BLUE}Nenhuma network tag encontrada.${NC}"
fi

# ------------------------------------------------------------------------------
# Prévia da migração (se variáveis de destino estiverem preenchidas)
# ------------------------------------------------------------------------------
if [[ -n "$TARGET_FAMILY" ]]; then
  header "Prévia da Migração"

  # Resolve tipo de disco
  if [[ -n "$TARGET_DISK_TYPE" ]]; then
    RESOLVED_DISK="$TARGET_DISK_TYPE"
  else
    case "$TARGET_FAMILY" in
      n4|c3|c3d|m3) RESOLVED_DISK="hyperdisk-balanced" ;;
      *)             RESOLVED_DISK="pd-balanced" ;;
    esac
  fi

  # Ação no disco
  if [[ "$BOOT_DISK_TYPE" == "$RESOLVED_DISK" ]]; then
    DISK_ACTION="${GREEN}REUTILIZAR${NC} — tipo igual ($RESOLVED_DISK), snapshot criado para segurança"
    CREATE_NEW="não"
  else
    DISK_ACTION="${YELLOW}CRIAR NOVO${NC} — $BOOT_DISK_TYPE → $RESOLVED_DISK (a partir do snapshot)"
    CREATE_NEW="sim"
  fi

  # GVNIC
  case "$TARGET_FAMILY" in
    n4|c3|c3d|t2a|m3) NIC_DESTINO="GVNIC (obrigatório)" ;;
    m1|m2)             NIC_DESTINO="VIRTIO_NET" ;;
    *)                 NIC_DESTINO="VIRTIO_NET (GVNIC opcional)" ;;
  esac

  TARGET_VM="${SOURCE_VM}-${TARGET_FAMILY}"

  divider
  row "VM destino:"      "$TARGET_VM"       "$GREEN"
  row "Família destino:" "$TARGET_FAMILY"   "$GREEN"
  if [[ -n "$MT_OVERRIDE" ]]; then
    row "Tipo destino:"  "$MT_OVERRIDE"     "$GREEN"
  else
    row "vCPUs destino:" "${TARGET_VCPUS:-?}"
    row "RAM destino:"   "${TARGET_MEM_GB:-?} GB"
  fi
  row "Disco destino:"   "$RESOLVED_DISK"   "$YELLOW"
  row "Novo disco?"      "$CREATE_NEW"
  row "NIC destino:"     "$NIC_DESTINO"
  divider
  echo ""
  printf "  ${BOLD}%-22s${NC} " "Ação no disco:"; echo -e "$DISK_ACTION"
  printf "  ${BOLD}%-22s${NC} " "IP externo:"; echo -e "${GREEN}migrado automaticamente — sem configuração necessária${NC}"
  printf "  ${BOLD}%-22s${NC} " "Network tags:"; echo -e "${GREEN}copiadas automaticamente da VM de origem${NC}"

  echo ""
  if [[ "$TARGET_FAMILY" == "t2a" ]]; then
    echo -e "  ${YELLOW}⚠ T2A usa arquitetura ARM — confirme compatibilidade do SO antes de migrar.${NC}"
  fi
  if [[ "$NIC_TYPE" == "VIRTIO_NET" && "$TARGET_FAMILY" =~ ^(n4|c3|c3d|t2a|m3)$ ]]; then
    echo -e "  ${YELLOW}⚠ NIC mudará de VIRTIO_NET para GVNIC — confirme que o SO suporta (kernel >= 4.15).${NC}"
  fi
fi

# ------------------------------------------------------------------------------
# Resumo final
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║               RESUMO                            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  VM            : ${BOLD}$SOURCE_VM${NC} — $STATUS_DISPLAY"
echo -e "  Tipo          : ${CYAN}$MACHINE_TYPE${NC}  (${SRC_VCPUS} vCPUs / ${SRC_RAM_GB} GB RAM)"
echo -e "  Boot disk     : ${CYAN}$BOOT_DISK_NAME${NC}  (${BOOT_DISK_TYPE} / ${BOOT_DISK_SIZE} GB)"
echo -e "  Discos sec.   : ${SEC_COUNT}"
echo -e "  IP externo    : ${GREEN}${EXTERNAL_IP:-Nenhum}${NC}  ($IP_TYPE)"
echo -e "  IP interno    : $INTERNAL_IP"
echo -e "  VPC / Subnet  : $NETWORK / $SUBNETWORK"
echo -e "  NIC           : $NIC_TYPE"
if [[ -n "$TAGS" ]]; then
  TAG_INLINE=$(echo "$TAGS" | tr ';' ', ')
  echo -e "  Network tags  : ${CYAN}$TAG_INLINE${NC}"
else
  echo -e "  Network tags  : nenhuma"
fi
echo ""
