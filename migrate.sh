#!/usr/bin/env bash
# ==============================================================================
# migrate.sh — Executor da migração GCP E2 → N4
# Compatível com: Linux, macOS, Windows (Git Bash / WSL)
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
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

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
# Lê um valor do terraform.tfvars
# ------------------------------------------------------------------------------
get_tfvar() {
  local key="$1"
  grep -E "^${key}\s*=" terraform.tfvars 2>/dev/null \
    | head -1 \
    | sed 's/[^=]*=\s*//' \
    | tr -d '"' | tr -d "'" \
    | sed 's/\s*#.*//' \
    | xargs
}

# ------------------------------------------------------------------------------
# Envia mensagem para o Telegram (falha silenciosa)
# ------------------------------------------------------------------------------
send_telegram() {
  local token="$1" chat_id="$2" message="$3"
  [[ -z "$token" || "$token" == "SEU-BOT-TOKEN-AQUI" ]] && return 0
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

# ------------------------------------------------------------------------------
# Trava de Segurança — Detecta mudança de alvo (VM de origem)
# ------------------------------------------------------------------------------
check_target_change() {
  local current_vm
  current_vm=$(get_tfvar "source_instance_name")

  if [[ -f "terraform.tfstate" ]]; then
    # Tenta extrair o nome da última VM migrada do estado (label 'origem')
    # Usamos grep/sed básico para compatibilidade máxima sem depender de jq
    local last_vm
    last_vm=$(grep '"origem":' terraform.tfstate | head -1 | sed 's/.*: "\(.*\)".*/\1/')

    if [[ -n "$last_vm" && "$last_vm" != "$current_vm" ]]; then
      echo ""
      warn "╔════════════════════════════════════════════════════════════╗"
      warn "║           ALERTA: MUDANÇA DE ALVO DETECTADA                ║"
      warn "╚════════════════════════════════════════════════════════════╝"
      echo ""
      echo -e "  Detectamos que a migração anterior foi para a VM: ${BOLD}$last_vm${NC}"
      echo -e "  A configuração atual (tfvars) aponta para a VM : ${BOLD}$current_vm${NC}"
      echo ""
      echo "  Isso causará conflitos no Terraform (prevent_destroy)."
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

# Lê variáveis necessárias
TELEGRAM_TOKEN=$(get_tfvar "telegram_bot_token")
TELEGRAM_CHAT=$(get_tfvar "telegram_chat_id")
PROJECT_ID=$(get_tfvar "project_id")
SOURCE_VM=$(get_tfvar "source_instance_name")
REGION=$(get_tfvar "region")
ZONE=$(get_tfvar "zone")
TARGET_VM="${SOURCE_VM}-n4"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "SEU-PROJECT-ID" ]]; then
  err "project_id não configurado em terraform.tfvars."
  exit 1
fi

if [[ -z "$TELEGRAM_TOKEN" || "$TELEGRAM_TOKEN" == "SEU-BOT-TOKEN-AQUI" ]]; then
  warn "Token do Telegram não configurado — notificações via script desabilitadas."
  warn "(As notificações embutidas no Terraform também não funcionarão.)"
  TELEGRAM_TOKEN=""
fi

ok "Configuração carregada do terraform.tfvars."

# Confirma projeto GCP autenticado
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || echo "não autenticado")
log "Conta GCP ativa: $ACTIVE_ACCOUNT"

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
# ETAPA 4 — Confirmação
# ------------------------------------------------------------------------------
if ! $AUTO_APPROVE; then
  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║           ATENÇÃO — LEIA ANTES           ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Esta operação irá:"
  echo "  1. Criar snapshot do disco da VM E2:  $SOURCE_VM"
  echo "  2. Criar disco Hyperdisk-Balanced"
  echo "  3. PARAR a VM E2 e desvincular o IP externo  ← downtime"
  echo "  4. Criar nova VM N4:  $TARGET_VM  (com o mesmo IP)"
  echo ""
  echo "  Projeto : $PROJECT_ID"
  echo "  Zona    : $ZONE"
  echo ""
  read -r -p "  Digite 'sim' para confirmar a execução: " CONFIRM
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
  err "ATENÇÃO: A VM E2 pode ter sido parada — verifique o Console GCP."

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
      "⚠️ A VM E2 pode ter sido parada — confirme no Console GCP."
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

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        MIGRAÇÃO CONCLUÍDA COM SUCESSO    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  VM N4       : $TARGET_VM"
echo "  IP Externo  : $IP_EXTERNO"
echo "  IP Interno  : $IP_INTERNO"
echo "  Duração     : $DURACAO"
echo "  Projeto     : $PROJECT_ID"
echo ""
echo -e "${BOLD}Próximos passos (manuais):${NC}"
echo "  1. Valide a VM N4 — acesso SSH, serviços, aplicação"
echo "  2. Após validação, exclua a VM E2 pelo Console GCP"
echo "  3. Após confirmar os dados, exclua o disco PD original"
echo ""
