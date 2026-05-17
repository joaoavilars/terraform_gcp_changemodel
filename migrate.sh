#!/usr/bin/env bash
# ==============================================================================
# migrate.sh — Executor da migração GCP (qualquer família)
# Otimizado para Linux
#
# Uso:
#   ./migrate.sh              → executa com confirmação interativa
#   ./migrate.sh -y           → executa sem pedir confirmação (CI/CD)
#   ./migrate.sh --dry-run    → apenas terraform plan, sem apply
#
# Pré-requisitos:
#   - terraform >= 1.5.0
#   - gcloud (autenticado com permissão Compute Instance Admin)
#   - curl
#   - terraform.tfvars preenchido
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Cores e helpers de output
# ------------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()    { echo -e "${RED}[ERRO]${NC}  $1" >&2; }
header() {
  echo ""
  echo -e "${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}══════════════════════════════════════════${NC}"
  echo ""
}

# ------------------------------------------------------------------------------
# Flags
# ------------------------------------------------------------------------------
AUTO_APPROVE=false
DRY_RUN=false
RESUMING=false

for arg in "$@"; do
  case "$arg" in
    -y|--yes)      AUTO_APPROVE=true ;;
    --dry-run)     DRY_RUN=true ;;
    -h|--help)
      echo "Uso: $0 [-y] [--dry-run]"
      echo "  -y, --yes    Executa sem confirmação interativa"
      echo "  --dry-run    Apenas terraform plan, sem apply"
      exit 0 ;;
  esac
done

# ------------------------------------------------------------------------------
# Verificação de SO — script otimizado para Linux
# ------------------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
  warn "Script otimizado para Linux. Executando em $(uname -s) — pode haver incompatibilidades."
fi

# ------------------------------------------------------------------------------
# Lê um valor do terraform.tfvars
# ------------------------------------------------------------------------------
get_tfvar() {
  local key="$1"
  grep -E "^${key}\s*=" terraform.tfvars 2>/dev/null \
    | head -1 \
    | sed 's/[^=]*=\s*//' \
    | tr -d '"' | tr -d "'" \
    | sed 's/\s*#.*//' \
    | xargs || true
}

# ------------------------------------------------------------------------------
# Envia mensagem para o Telegram (falha silenciosa)
# ------------------------------------------------------------------------------
send_telegram() {
  local token="$1" chat_id="$2" message="$3"
  [[ -z "$token" || "$token" == "SEU-BOT-TOKEN-AQUI" || "$token" == "TOKEN_AQUI" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=${message}" > /dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# ETAPA 1 — Verificação de pré-requisitos
# ------------------------------------------------------------------------------
header "Verificando Pré-requisitos"

MISSING=()
for tool in terraform gcloud curl; do
  command -v "$tool" &>/dev/null || MISSING+=("$tool")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  err "Ferramentas não encontradas: ${MISSING[*]}"
  err "Instale as ferramentas listadas e tente novamente."
  exit 1
fi
ok "terraform, gcloud e curl encontrados."

TERRAFORM_VERSION=$(terraform --version | head -n 1 | awk '{print $2}')
ok "Terraform versão: $TERRAFORM_VERSION"

if [[ ! -f "terraform.tfvars" ]]; then
  err "Arquivo terraform.tfvars não encontrado no diretório atual."
  err "Preencha o template terraform.tfvars com os valores do seu ambiente."
  exit 1
fi
ok "terraform.tfvars encontrado."

# Lê variáveis necessárias do tfvars
TELEGRAM_TOKEN=$(get_tfvar "telegram_bot_token")
TELEGRAM_CHAT=$(get_tfvar "telegram_chat_id")
PROJECT_ID=$(get_tfvar "project_id")
SOURCE_VM=$(get_tfvar "source_instance_name")
FINAL_VM_NAME=$(get_tfvar "final_instance_name")
REGION=$(get_tfvar "region")
ZONE=$(get_tfvar "zone")
TARGET_FAMILY=$(get_tfvar "target_machine_family")
TARGET_DISK_TYPE_VAR=$(get_tfvar "target_disk_type")
TARGET_VCPUS=$(get_tfvar "target_vcpus")
TARGET_MEM_GB=$(get_tfvar "target_memory_gb")
CHANGE_DISK_SIZE=$(get_tfvar "change_disk_size")
TARGET_DISK_SIZE=$(get_tfvar "target_disk_size")

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "SEU-PROJECT-ID" ]]; then
  err "project_id não configurado em terraform.tfvars."
  exit 1
fi

if [[ -z "$TARGET_FAMILY" ]]; then
  err "target_machine_family não configurado em terraform.tfvars."
  err "Adicione: target_machine_family = \"n4\"  # ou n2, c3, e2, etc."
  exit 1
fi

if [[ -z "$TELEGRAM_TOKEN" || "$TELEGRAM_TOKEN" == "SEU-BOT-TOKEN-AQUI" || "$TELEGRAM_TOKEN" == "TOKEN_AQUI" ]]; then
  warn "Token do Telegram não configurado — notificações desabilitadas."
  TELEGRAM_TOKEN=""
fi

ok "Configuração carregada do terraform.tfvars."

# ------------------------------------------------------------------------------
# Detecção de downgrade de disco
# Se change_disk_size = true e target_disk_size < tamanho atual do disco,
# verifica se o filesystem já foi reduzido. Se não, oferece rodar
# ./downgrade_boot_disk.sh automaticamente.
# ------------------------------------------------------------------------------
if [[ "$CHANGE_DISK_SIZE" == "true" && -n "$TARGET_DISK_SIZE" && "$TARGET_DISK_SIZE" -gt 0 ]] 2>/dev/null; then
  # Obtém tamanho atual do disco de boot
  CURRENT_DISK_SIZE=$(gcloud compute disks describe "$SOURCE_VM" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --format="value(sizeGb)" 2>/dev/null || echo "0")

  if [[ "$TARGET_DISK_SIZE" -lt "$CURRENT_DISK_SIZE" ]]; then
    log "Detectado downgrade de disco: ${CURRENT_DISK_SIZE} GB → ${TARGET_DISK_SIZE} GB"

    # Verifica se o filesystem já foi reduzido (tenta ler via SSH)
    FS_ALREADY_REDUCED=false
    VM_STATUS=$(gcloud compute instances describe "$SOURCE_VM" \
      --zone="$ZONE" --project="$PROJECT_ID" \
      --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

    if [[ "$VM_STATUS" == "RUNNING" ]]; then
      FS_SIZE=$(gcloud compute ssh "$SOURCE_VM" --zone="$ZONE" --project="$PROJECT_ID" \
        --command="df -B1G --output=size / | tail -1 | tr -d ' ' || echo 0" \
        --quiet 2>/dev/null || echo "0")
      if [[ "$FS_SIZE" -le "$TARGET_DISK_SIZE" ]]; then
        FS_ALREADY_REDUCED=true
      fi
    fi

    if [[ "$FS_ALREADY_REDUCED" == "true" ]]; then
      ok "Filesystem já reduzido (${FS_SIZE}G ≤ ${TARGET_DISK_SIZE}G). Prosseguindo com a migração."
    else
      warn "O filesystem do disco de boot AINDA NÃO foi reduzido para caber em ${TARGET_DISK_SIZE} GB."
      warn "A migração criará um disco de ${TARGET_DISK_SIZE} GB a partir do snapshot atual."
      warn "Se o filesystem ocupar mais que ${TARGET_DISK_SIZE} GB, a nova VM NÃO inicializará."
      echo ""
      echo -e "  ${BOLD}Deseja rodar o script de downgrade automático agora?${NC}"
      echo -e "  Ele irá:"
      echo -e "    • Criar snapshot de segurança"
      echo -e "    • Parar a VM, criar VM temporária, reduzir FS+partição"
      echo -e "    • Devolver o disco e apagar a VM temporária"
      echo -e "    • Depois disso a migração prossegue normalmente"
      echo ""
      echo -e "  ${YELLOW}Requisitos:${NC} Linux + ext4 + partição única /dev/sda1"
      echo -e "  ${YELLOW}Fora disso:${NC} responda 'nao' e siga o procedimento manual no README"
      echo ""

      if [[ "$AUTO_APPROVE" == "true" ]]; then
        RUN_DOWNGRADE=true
      else
        read -r -p "Rodar downgrade automático agora? (sim/nao): " RESP
        if [[ "$RESP" == "sim" ]]; then
          RUN_DOWNGRADE=true
        else
          RUN_DOWNGRADE=false
        fi
      fi

      if [[ "$RUN_DOWNGRADE" == "true" ]]; then
        if [[ ! -f "./downgrade_boot_disk.sh" ]]; then
          err "Script ./downgrade_boot_disk.sh não encontrado."
          err "Baixe-o ou siga o procedimento manual no README."
          exit 1
        fi
        log "Executando ./downgrade_boot_disk.sh..."
        echo ""
        if [[ "$DRY_RUN" == "true" ]]; then
          warn "DRY-RUN: pulando execução do downgrade."
        else
          if [[ "$AUTO_APPROVE" == "true" ]]; then
            ./downgrade_boot_disk.sh --yes
          else
            ./downgrade_boot_disk.sh
          fi
          DOWNGRADE_EXIT=$?
          if [[ "$DOWNGRADE_EXIT" -ne 0 ]]; then
            err "downgrade_boot_disk.sh falhou (exit code: $DOWNGRADE_EXIT)."
            err "Corrija o problema e execute novamente o migrate.sh."
            exit 1
          fi
          ok "Downgrade concluído. Prosseguindo com a migração."
        fi
      else
        warn "Downgrade não executado. A migração continuará, mas o disco pode não caber."
        warn "Para abortar agora: Ctrl+C. Para prosseguir mesmo assim, aguarde."
        if [[ "$AUTO_APPROVE" != "true" ]]; then
          echo ""
          read -r -p "Tem certeza que deseja prosseguir sem reduzir o filesystem? (sim/nao): " RESP2
          [[ "$RESP2" != "sim" ]] && { err "Abortado pelo usuário."; exit 1; }
        fi
      fi
    fi
  elif [[ "$TARGET_DISK_SIZE" -gt "$CURRENT_DISK_SIZE" ]]; then
    log "Detectado upgrade de disco: ${CURRENT_DISK_SIZE} GB → ${TARGET_DISK_SIZE} GB"
    log "O upgrade é seguro e será feito automaticamente pelo Terraform."
  fi
fi

# Confirma projeto GCP autenticado
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || echo "não autenticado")
log "Conta GCP ativa: $ACTIVE_ACCOUNT"

# ==============================================================================
# ETAPA 1.5 — Consulta specs da VM de origem via gcloud
# ==============================================================================

# Resolved disk type — espelha lógica do locals.tf
resolve_disk_type() {
  local family="$1"
  local disk_type_var="$2"

  if [[ -n "$disk_type_var" ]]; then
    echo "$disk_type_var"
    return
  fi

  case "$family" in
    n4|c3|c3d|m3) echo "hyperdisk-balanced" ;;
    *)             echo "pd-balanced" ;;
  esac
}

# Determina se GVNIC é obrigatório para a família
requires_gvnic() {
  local family="$1"
  case "$family" in
    n4|c3|c3d|t2a|m3) echo "true" ;;
    *)                 echo "false" ;;
  esac
}

# Determina se GVNIC é suportado (mas não obrigatório)
supports_gvnic() {
  local family="$1"
  case "$family" in
    m1|m2) echo "false" ;;
    *)     echo "true" ;;
  esac
}

# Consulta vCPUs e RAM diretamente via API do GCP (preciso para qualquer tipo, incluindo custom)
fetch_machine_specs() {
  local machine_type="$1"
  local zone="$2"
  local project="$3"
  local specs

  specs=$(gcloud compute machine-types describe "$machine_type" \
    --zone="$zone" --project="$project" \
    --format="csv[no-heading](guestCpus,memoryMb)" 2>/dev/null || echo "")

  if [[ -n "$specs" ]]; then
    local vcpus ram_mb ram_gb
    vcpus=$(echo "$specs" | cut -d',' -f1)
    ram_mb=$(echo "$specs" | cut -d',' -f2)
    # Arredonda para GB inteiro mais próximo
    ram_gb=$(( (ram_mb + 512) / 1024 ))
    echo "$vcpus $ram_gb"
  else
    # Fallback: extrai do nome para tipos custom (family-custom-vcpus-mem_mb)
    if [[ "$machine_type" =~ -custom- ]]; then
      local vcpus ram_mb
      vcpus=$(echo "$machine_type" | awk -F'-' '{print $(NF-1)}')
      ram_mb=$(echo "$machine_type" | awk -F'-' '{print $NF}')
      echo "$vcpus $(( (ram_mb + 512) / 1024 ))"
    else
      echo "? ?"
    fi
  fi
}

header "Consultando VM de Origem"

# Consulta VM de origem
SOURCE_VM_JSON=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="csv[no-heading](machineType,status)" 2>/dev/null || echo "")

if [[ -z "$SOURCE_VM_JSON" ]]; then
  err "VM de origem '$SOURCE_VM' não encontrada no projeto '$PROJECT_ID', zona '$ZONE'."
  exit 1
fi

# Extrai machine type (último segmento do URL) e status
SOURCE_MACHINE_TYPE=$(echo "$SOURCE_VM_JSON" | cut -d',' -f1 | awk -F'/' '{print $NF}')
SOURCE_STATUS=$(echo "$SOURCE_VM_JSON" | cut -d',' -f2)

# Extrai família da origem
SOURCE_FAMILY=$(echo "$SOURCE_MACHINE_TYPE" | cut -d'-' -f1)

# Busca vCPUs e RAM reais via API (não estimativa)
log "Consultando specs da máquina '$SOURCE_MACHINE_TYPE' via API GCP..."
read -r SOURCE_VCPUS SOURCE_RAM_GB <<< "$(fetch_machine_specs "$SOURCE_MACHINE_TYPE" "$ZONE" "$PROJECT_ID")"

# Consulta disco de boot
BOOT_DISK_URL=$(gcloud compute instances describe "$SOURCE_VM" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format="value(disks[0].source)" 2>/dev/null || echo "")

BOOT_DISK_NAME=$(echo "$BOOT_DISK_URL" | awk -F'/' '{print $NF}')

if [[ -n "$BOOT_DISK_NAME" ]]; then
  SOURCE_BOOT_DISK_TYPE=$(gcloud compute disks describe "$BOOT_DISK_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --format="value(type)" 2>/dev/null | awk -F'/' '{print $NF}' || echo "unknown")
  SOURCE_BOOT_DISK_SIZE=$(gcloud compute disks describe "$BOOT_DISK_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --format="value(sizeGb)" 2>/dev/null || echo "unknown")
else
  SOURCE_BOOT_DISK_TYPE="unknown"
  SOURCE_BOOT_DISK_SIZE="unknown"
fi

ok "VM de origem: $SOURCE_VM ($SOURCE_MACHINE_TYPE) — $SOURCE_STATUS"
ok "vCPUs: $SOURCE_VCPUS | RAM: ${SOURCE_RAM_GB}GB | Disco boot: $SOURCE_BOOT_DISK_TYPE (${SOURCE_BOOT_DISK_SIZE}GB)"

# ==============================================================================
# ETAPA 1.6 — Resolve configuração de destino e mostra resumo
# ==============================================================================

RESOLVED_DISK_TYPE=$(resolve_disk_type "$TARGET_FAMILY" "$TARGET_DISK_TYPE_VAR")
NEEDS_GVNIC=$(requires_gvnic "$TARGET_FAMILY")
SUPPORTS_GVNIC=$(supports_gvnic "$TARGET_FAMILY")

# Determina se disco será reutilizado ou criado novo
if [[ "$SOURCE_BOOT_DISK_TYPE" == "$RESOLVED_DISK_TYPE" ]]; then
  CREATE_NEW_DISK=false
  DISK_ACTION="REUTILIZADO (snapshot criado para seguranca)"
else
  CREATE_NEW_DISK=true
  DISK_ACTION="CRIAR NOVO a partir de snapshot"
fi

# NIC type da origem
if [[ "$NEEDS_GVNIC" == "true" ]]; then
  TARGET_NIC="GVNIC (obrigatorio)"
elif [[ "$SUPPORTS_GVNIC" == "true" ]]; then
  TARGET_NIC="VIRTIO_NET (GVNIC opcional)"
else
  TARGET_NIC="VIRTIO_NET"
fi

# Nomes dinâmicos
if [[ -n "$FINAL_VM_NAME" ]]; then
  TARGET_VM="$FINAL_VM_NAME"
else
  TARGET_VM="${SOURCE_VM}-${TARGET_FAMILY}"
fi
NEW_DISK_NAME="${SOURCE_VM}-${RESOLVED_DISK_TYPE}"
SNAPSHOT_NAME="${SOURCE_VM}-migration-snapshot"

# ==============================================================================
# ETAPA 1.7 — Validação e resumo interativo
# ==============================================================================
WARNINGS=()

# Compara vCPUs
if [[ -n "$TARGET_VCPUS" && -n "$SOURCE_VCPUS" && "$TARGET_VCPUS" != "$SOURCE_VCPUS" ]]; then
  WARNINGS+=("vCPUs diferente (origem: $SOURCE_VCPUS, destino: $TARGET_VCPUS)")
fi

# Compara RAM
if [[ -n "$TARGET_MEM_GB" && -n "$SOURCE_RAM_GB" && "$TARGET_MEM_GB" != "$SOURCE_RAM_GB" ]]; then
  WARNINGS+=("RAM diferente (origem: ${SOURCE_RAM_GB}GB, destino: ${TARGET_MEM_GB}GB)")
fi

# Alerta sobre mudança de NIC
if [[ "$NEEDS_GVNIC" == "true" && "$SOURCE_FAMILY" != "n4" && "$SOURCE_FAMILY" != "c3" && "$SOURCE_FAMILY" != "c3d" && "$SOURCE_FAMILY" != "t2a" && "$SOURCE_FAMILY" != "m3" ]]; then
  WARNINGS+=("NIC muda para GVNIC — certifique-se de que o SO suporta")
fi

# Alerta T2A (ARM)
if [[ "$TARGET_FAMILY" == "t2a" ]]; then
  WARNINGS+=("T2A usa arquitetura ARM — o SO deve ser compativel")
fi

# Mostra resumo
header "RESUMO DA MIGRACAO"

echo -e "  ${BOLD}ORIGEM${NC}                          ${BOLD}DESTINO${NC}"
echo -e "  ─────────────────────────────   ─────────────────────────────"
echo -e "  Familia  : ${CYAN}$SOURCE_FAMILY${NC}              Familia  : ${GREEN}$TARGET_FAMILY${NC}"
echo -e "  Tipo     : ${CYAN}$SOURCE_MACHINE_TYPE${NC}   Tipo     : ${GREEN}(sera resolvido pelo Terraform)${NC}"
echo -e "  vCPUs    : ${CYAN}$SOURCE_VCPUS${NC}                  vCPUs    : ${GREEN}${TARGET_VCPUS:-?}${NC}"
echo -e "  RAM      : ${CYAN}${SOURCE_RAM_GB} GB${NC}                RAM      : ${GREEN}${TARGET_MEM_GB:-?} GB${NC}"
echo -e "  Disco    : ${CYAN}$SOURCE_BOOT_DISK_TYPE${NC}         Disco    : ${GREEN}$RESOLVED_DISK_TYPE${NC}"
echo -e "  Tamanho  : ${CYAN}${SOURCE_BOOT_DISK_SIZE} GB${NC}             Acao    : ${GREEN}$DISK_ACTION${NC}"
echo -e "  NIC      : ${CYAN}VIRTIO_NET${NC}               NIC      : ${GREEN}$TARGET_NIC${NC}"
echo ""
echo -e "  ${BOLD}Validacoes:${NC}"

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}✓ vCPUs/RAM compativeis${NC}"
  echo -e "  ${GREEN}✓ Disco e NIC sem restricoes adicionais${NC}"
else
  for w in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}⚠ $w${NC}"
  done
fi

echo ""
echo -e "  ${BOLD}Operacao:${NC}"
echo -e "  Downtime: ${RED}sim${NC} (VM sera parada)"
echo -e "  Projeto : $PROJECT_ID"
echo -e "  Zona    : $ZONE"
echo ""

# ==============================================================================
# Detecção de execução anterior incompleta
# ==============================================================================

check_incomplete_run() {
  local has_state=false has_snapshot=false has_disk=false has_target_vm=false has_tfplan=false
  local state_inconsistent=false

  [[ -f "terraform.tfstate" ]] && has_state=true
  [[ -f "tfplan" ]] && has_tfplan=true

  # Verifica recursos no GCP via gcloud
  gcloud compute snapshots describe "$SNAPSHOT_NAME" \
    --project="$PROJECT_ID" &>/dev/null && has_snapshot=true

  gcloud compute disks describe "$NEW_DISK_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null && has_disk=true

  gcloud compute instances describe "$TARGET_VM" \
    --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null && has_target_vm=true

  # Se a VM de destino já existe, a migração foi concluída
  if $has_target_vm; then
    local vm_status
    vm_status=$(gcloud compute instances describe "$TARGET_VM" \
      --zone="$ZONE" --project="$PROJECT_ID" \
      --format="value(status)" 2>/dev/null || echo "DESCONHECIDO")
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       MIGRAÇÃO JÁ FOI CONCLUÍDA ANTERIORMENTE              ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  VM Destino  : $TARGET_VM"
    echo "  Status      : $vm_status"
    echo "  Projeto     : $PROJECT_ID"
    echo ""
    echo "  Nenhuma ação é necessária. A migração foi concluída."
    echo ""
    exit 0
  fi

  if ! $has_state && ! $has_snapshot && ! $has_disk; then
    return 0
  fi

  if $has_state || $has_snapshot || $has_disk; then
    echo ""
    warn "╔════════════════════════════════════════════════════════════╗"
    warn "║       EXECUÇÃO ANTERIOR INCOMPLETA DETECTADA              ║"
    warn "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "  ${BOLD}Estado atual dos recursos:${NC}"
    echo ""

    if $has_state; then
      local resource_count
      resource_count=$(grep -c '"mode":' terraform.tfstate 2>/dev/null || echo "?")
      echo -e "  ${YELLOW}▸${NC} terraform.tfstate   : ${RED}EXISTS${NC} ($resource_count recursos)"
    fi

    if $has_snapshot; then
      local snap_status
      snap_status=$(gcloud compute snapshots describe "$SNAPSHOT_NAME" \
        --project="$PROJECT_ID" --format="value(status)" 2>/dev/null || echo "?")
      echo -e "  ${GREEN}▸${NC} Snapshot de boot    : ${GREEN}$snap_status${NC} ($SNAPSHOT_NAME)"
    else
      echo -e "  ${RED}▸${NC} Snapshot de boot    : ${RED}NÃO ENCONTRADO${NC}"
    fi

    if $has_disk; then
      local disk_status
      disk_status=$(gcloud compute disks describe "$NEW_DISK_NAME" \
        --zone="$ZONE" --project="$PROJECT_ID" --format="value(status)" 2>/dev/null || echo "?")
      echo -e "  ${GREEN}▸${NC} Disco destino       : ${GREEN}$disk_status${NC} ($NEW_DISK_NAME)"
    else
      echo -e "  ${RED}▸${NC} Disco destino       : ${RED}NÃO ENCONTRADO${NC}"
    fi

    echo -e "  ${RED}▸${NC} VM destino          : ${RED}NÃO CRIADA${NC}"

    if $has_snapshot && $has_state; then
      if ! grep -q '"google_compute_snapshot"' terraform.tfstate 2>/dev/null; then
        state_inconsistent=true
        echo ""
        warn "  ⚠ Estado INCONSISTENTE: snapshot existe no GCP mas NÃO no tfstate."
      fi
    fi

    echo ""
    echo -e "  ${BOLD}Escolha uma opção:${NC}"
    echo ""
    echo "    1) Retomar de onde parou (terraform init + plan + apply — recomendado)"
    if $state_inconsistent; then
      echo -e "       ${YELLOW}⚠ Pode falhar se o estado estiver muito dessincronizado.${NC}"
    fi
    echo ""
    echo "    2) Reiniciar do zero (apaga estado + recursos órfãos no GCP)"
    echo -e "       ${RED}⚠ Os dados do snapshot são preservados no disco original.${NC}"
    echo ""
    echo "    3) Cancelar"
    echo ""

    local choice
    read -r -p "  Opção [1/2/3]: " choice

    case "$choice" in
      1)
        echo ""
        RESUMING=true
        ok "Retomando execução anterior..."
        rm -f tfplan

        log "Verificando necessidade de importar recursos existentes..."
        terraform init -input=false &>/dev/null || true

        if $has_snapshot; then
          if ! grep -q '"name": "migration_snapshot"' terraform.tfstate 2>/dev/null; then
            log "Importando snapshot existente para o estado do Terraform..."
            terraform import google_compute_snapshot.migration_snapshot \
              "projects/${PROJECT_ID}/global/snapshots/${SNAPSHOT_NAME}" || {
              warn "Falha ao importar snapshot — pode ser necessário reiniciar do zero (opção 2)."
            }
          else
            log "Snapshot já está no estado do Terraform. Pulando import."
          fi
        fi

        if $has_disk && $CREATE_NEW_DISK; then
          if ! grep -q '"name": "migration_boot_disk"' terraform.tfstate 2>/dev/null; then
            log "Importando disco existente para o estado do Terraform..."
            terraform import google_compute_disk.migration_boot_disk \
              "projects/${PROJECT_ID}/zones/${ZONE}/disks/${NEW_DISK_NAME}" || {
              warn "Falha ao importar disco — pode ser necessário reiniciar do zero (opção 2)."
            }
          else
            log "Disco já está no estado do Terraform. Pulando import."
          fi
        fi

        if $has_target_vm; then
          if ! grep -q '"name": "migrated_instance"' terraform.tfstate 2>/dev/null; then
            log "Importando instância existente para o estado do Terraform..."
            terraform import google_compute_instance.migrated_instance \
              "projects/${PROJECT_ID}/zones/${ZONE}/instances/${TARGET_VM}" || {
              warn "Falha ao importar instância — pode ser necessário reiniciar do zero (opção 2)."
            }
          else
            log "Instância já está no estado do Terraform. Pulando import."
          fi
        fi

        ok "Importação de recursos concluída. Prosseguindo com plan..."
        ;;
      2)
        echo ""
        warn "Reiniciando do zero — limpando estado e recursos órfãos..."

        rm -f terraform.tfstate terraform.tfstate.backup tfplan

        if $has_disk; then
          log "Removendo disco órfão: $NEW_DISK_NAME"
          gcloud compute disks delete "$NEW_DISK_NAME" \
            --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null || true
        fi

        if $has_snapshot; then
          log "Removendo snapshot órfão: $SNAPSHOT_NAME"
          gcloud compute snapshots delete "$SNAPSHOT_NAME" \
            --project="$PROJECT_ID" --quiet 2>/dev/null || true
        fi

        # Remove snapshots de discos secundários
        local sec_snapshots
        sec_snapshots=$(gcloud compute snapshots list \
          --project="$PROJECT_ID" \
          --filter="name~-migration-snapshot AND labels.origem=$SOURCE_VM AND labels.tipo=migracao-secundario" \
          --format="value(name)" 2>/dev/null || true)
        if [[ -n "$sec_snapshots" ]]; then
          for snap in $sec_snapshots; do
            log "Removendo snapshot secundário órfão: $snap"
            gcloud compute snapshots delete "$snap" \
              --project="$PROJECT_ID" --quiet 2>/dev/null || true
          done
        fi

        # Remove discos secundários órfãos
        local sec_disks
        sec_disks=$(gcloud compute disks list \
          --project="$PROJECT_ID" \
          --filter="name~-$RESOLVED_DISK_TYPE AND zone:($ZONE) AND labels.origem=$SOURCE_VM" \
          --format="value(name)" 2>/dev/null || true)
        if [[ -n "$sec_disks" ]]; then
          for dsk in $sec_disks; do
            log "Removendo disco secundário órfão: $dsk"
            gcloud compute disks delete "$dsk" \
              --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null || true
          done
        fi

        # Garante que a VM de origem está rodando
        local src_status
        src_status=$(gcloud compute instances describe "$SOURCE_VM" \
          --zone="$ZONE" --project="$PROJECT_ID" \
          --format="value(status)" 2>/dev/null || echo "NOT_FOUND")
        if [[ "$src_status" != "RUNNING" && "$src_status" != "NOT_FOUND" ]]; then
          log "Iniciando VM de origem que estava parada: $SOURCE_VM"
          gcloud compute instances start "$SOURCE_VM" \
            --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null || true
        fi

        ok "Limpeza concluída. Iniciando migração do zero."
        ;;
      3|*)
        log "Operação cancelada pelo usuário."
        exit 0
        ;;
    esac
  fi
}

check_incomplete_run

# ------------------------------------------------------------------------------
# Trava de Segurança — Detecta mudança de alvo (VM de origem)
# ------------------------------------------------------------------------------
check_target_change() {
  local current_vm
  current_vm=$(get_tfvar "source_instance_name")

  if [[ -f "terraform.tfstate" ]]; then
    local last_vm
    last_vm=$(grep '"origem":' terraform.tfstate | head -1 | sed 's/.*: "\(.*\)".*/\1/' || true)

    if [[ -n "$last_vm" && "$last_vm" != "$current_vm" ]]; then
      echo ""
      warn "╔════════════════════════════════════════════════════════════╗"
      warn "║           ALERTA: MUDANÇA DE ALVO DETECTADA                ║"
      warn "╚════════════════════════════════════════════════════════════╝"
      echo ""
      echo -e "  Detectamos que a migração anterior foi para a VM: ${BOLD}$last_vm${NC}"
      echo -e "  A configuração atual (tfvars) aponta para a VM : ${BOLD}$current_vm${NC}"
      echo ""
      read -r -p "  Deseja LIMPAR o estado anterior para iniciar esta nova migração? (s/n): " CONFIRM_CLEAN
      if [[ "$CONFIRM_CLEAN" == "s" || "$CONFIRM_CLEAN" == "S" ]]; then
        log "Limpando arquivos de estado anteriores..."
        rm -f terraform.tfstate terraform.tfstate.backup tfplan
        ok "Estado resetado. Iniciando nova migração."
      else
        err "Execução cancelada. Limpe o estado manualmente ou volte ao alvo anterior."
        exit 1
      fi
    fi
  fi
}

check_target_change

# ------------------------------------------------------------------------------
# ETAPA 2 — Terraform Init
# ------------------------------------------------------------------------------
header "Terraform Init"
terraform init
ok "Providers instalados e backend inicializado."

# ------------------------------------------------------------------------------
# ETAPA 3 — Terraform Plan
# ------------------------------------------------------------------------------
header "Terraform Plan"
terraform plan -out=tfplan
ok "Plano gerado e salvo em 'tfplan'."

if $DRY_RUN; then
  log "Modo --dry-run: encerrando sem aplicar."
  exit 0
fi

# ------------------------------------------------------------------------------
# ETAPA 4 — Confirmação final (após terraform plan)
# Re-exibe o resumo completo para conferência antes de aplicar
# ------------------------------------------------------------------------------
if ! $AUTO_APPROVE; then
  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║         CONFIRMAÇÃO FINAL — REVISE ANTES DE PROSSEGUIR      ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if $RESUMING; then
    echo -e "  ${BOLD}Modo retomada${NC}: apenas os passos PENDENTES serão executados."
    echo ""
    echo -e "  VM alvo  : ${GREEN}$TARGET_VM${NC}"
    echo -e "  Projeto  : $PROJECT_ID"
    echo -e "  Zona     : $ZONE"
  else
    echo -e "  ${BOLD}ORIGEM${NC}                               ${BOLD}DESTINO${NC}"
    echo -e "  ──────────────────────────────────   ──────────────────────────────────"
    echo -e "  VM       : ${CYAN}$SOURCE_VM${NC}"
    echo -e "  Família  : ${CYAN}$SOURCE_FAMILY${NC}                       Família  : ${GREEN}$TARGET_FAMILY${NC}"
    echo -e "  Tipo     : ${CYAN}$SOURCE_MACHINE_TYPE${NC}"
    echo -e "  vCPUs    : ${CYAN}$SOURCE_VCPUS${NC}                        vCPUs    : ${GREEN}${TARGET_VCPUS:-?}${NC}"
    echo -e "  RAM      : ${CYAN}${SOURCE_RAM_GB} GB${NC}                     RAM      : ${GREEN}${TARGET_MEM_GB:-?} GB${NC}"
    echo -e "  Disco    : ${CYAN}$SOURCE_BOOT_DISK_TYPE${NC}               Disco    : ${GREEN}$RESOLVED_DISK_TYPE${NC}"
    echo -e "  Tamanho  : ${CYAN}${SOURCE_BOOT_DISK_SIZE} GB${NC}"
    echo -e "  NIC      : ${CYAN}VIRTIO_NET${NC}                   NIC      : ${GREEN}$TARGET_NIC${NC}"
    echo ""
    echo -e "  ${BOLD}Operações que serão executadas:${NC}"
    echo -e "  1. Criar snapshot de: ${CYAN}$BOOT_DISK_NAME${NC}  →  ${GREEN}$SNAPSHOT_NAME${NC}"
    if $CREATE_NEW_DISK; then
      echo -e "  2. Criar novo disco ${GREEN}$RESOLVED_DISK_TYPE${NC} a partir do snapshot"
    else
      echo -e "  2. ${GREEN}Reutilizar disco existente${NC} ($RESOLVED_DISK_TYPE) — sem criação de novo disco"
    fi
    echo -e "  3. ${RED}PARAR${NC} VM ${CYAN}$SOURCE_VM${NC} e desvincular o IP externo  ← ${RED}DOWNTIME INICIA${NC}"
    echo -e "  4. Criar nova VM ${GREEN}$TARGET_VM${NC} com o mesmo IP               ← ${GREEN}DOWNTIME ENCERRA${NC}"
    echo ""
    echo -e "  Projeto : $PROJECT_ID"
    echo -e "  Zona    : $ZONE"
  fi

  echo ""

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠ Alertas:${NC}"
    for w in "${WARNINGS[@]}"; do
      echo -e "    ${YELLOW}• $w${NC}"
    done
    echo ""
  fi

  read -r -p "  Digite 'sim' para confirmar e iniciar a migração: " CONFIRM
  if [[ "$CONFIRM" != "sim" ]]; then
    log "Operação cancelada pelo usuário."
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# ETAPA 5 — Terraform Apply
# ------------------------------------------------------------------------------
header "Executando Migração"

START_TIME=$(date +%s)
START_HORA=$(date '+%d/%m/%Y %H:%M:%S')
log "Início: $START_HORA"

# Handler de erro: envia notificação de falha e encerra
on_error() {
  local EXIT_CODE=$?
  local HORA
  HORA=$(date '+%d/%m/%Y %H:%M:%S')
  echo ""
  err "terraform apply falhou (código de saída: $EXIT_CODE)"
  err "Verifique os logs acima para detalhes."
  err "ATENÇÃO: A VM de origem pode ter sido parada — verifique o Console GCP."
  err "Execute novamente o script para detectar o estado e retomar."

  if [[ -n "$TELEGRAM_TOKEN" ]]; then
    MSG=$(printf '%s\n' \
      "❌ <b>ERRO NA MIGRAÇÃO</b>" \
      "━━━━━━━━━━━━━━━━━━━━━━━━" \
      "🔴 Projeto  : <code>$PROJECT_ID</code>" \
      "🔴 VM Origem: <code>$SOURCE_VM</code>" \
      "💀 Código   : <code>$EXIT_CODE</code>" \
      "⏱  Horário  : <b>$HORA</b>" \
      "" \
      "⚠️ Verifique os logs do Terraform." \
      "⚠️ A VM de origem pode ter sido parada — confirme no Console GCP." \
      "💡 Execute o script novamente para detectar e retomar."
    )
    send_telegram "$TELEGRAM_TOKEN" "$TELEGRAM_CHAT" "$MSG"
  fi
  exit "$EXIT_CODE"
}
trap on_error ERR

terraform apply tfplan

END_TIME=$(date +%s)
DIFF=$((END_TIME - START_TIME))
DURACAO="$((DIFF / 60))m $((DIFF % 60))s"

echo ""
ok "terraform apply concluído em $DURACAO."

# ------------------------------------------------------------------------------
# ETAPA 6 — Exibe resultados
# ------------------------------------------------------------------------------
header "Resultados da Migração"
terraform output

IP_EXTERNO=$(terraform output -raw nova_instancia_ip_externo 2>/dev/null || echo "N/A")
IP_INTERNO=$(terraform output -raw nova_instancia_ip_interno 2>/dev/null || echo "N/A")
DISCO_REUTILIZADO=$(terraform output -raw disco_reutilizado 2>/dev/null || echo "false")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        MIGRAÇÃO CONCLUÍDA COM SUCESSO    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  VM Destino : $TARGET_VM"
echo "  IP Externo : $IP_EXTERNO"
echo "  IP Interno : $IP_INTERNO"
echo "  Disco      : $RESOLVED_DISK_TYPE ($([ "$DISCO_REUTILIZADO" == "true" ] && echo "reutilizado" || echo "criado novo"))"
echo "  Duração    : $DURACAO"
echo "  Projeto    : $PROJECT_ID"
echo ""
echo -e "${BOLD}Próximos passos (manuais):${NC}"
echo "  1. Valide a VM — acesso SSH, serviços, aplicação"
echo "  2. Após validação, exclua a VM de origem pelo Console GCP"
if [[ "$DISCO_REUTILIZADO" != "true" ]]; then
  echo "  3. Após confirmar os dados, exclua o disco original"
else
  echo "  3. Disco foi reutilizado — nenhum disco órfão para limpar"
fi
echo ""
