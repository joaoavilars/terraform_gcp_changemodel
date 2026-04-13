# ==============================================================================
# main.tf
# Recursos de infraestrutura — orquestração completa da migração E2 → N4
#
# Cadeia de dependências gerenciada pelo Terraform:
#
#   notify_start ──► snapshot ──► notify_snapshot_done
#                            └──► disk ──► notify_disk_done
#                                      └──► stop_and_detach_e2  ◄── DOWNTIME INICIA
#                                                └──► instância N4              ◄── DOWNTIME ENCERRA
#                                                           └──► notify_done
#
# NOTA sobre interpolação nos provisioners local-exec:
#   ${var.*} e ${local.*}  → interpolados pelo Terraform antes de passar ao bash
#   $VAR_BASH              → variável bash pura (sem chaves) — Terraform não toca
#   $(comando)             → substituição de comando bash — Terraform não toca
# ==============================================================================

# ==============================================================================
# NOTIFICAÇÃO 1 — Início da migração
# Executa a cada 'terraform apply' (trigger timestamp muda sempre).
# O snapshot depende deste recurso: garante que a notificação seja enviada
# antes de qualquer operação de infraestrutura.
# ==============================================================================
resource "null_resource" "notify_migration_start" {
  triggers = {
    # Muda a cada apply — intencionalmente, para sempre notificar o início
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      # Salva timestamp de início para calcular duração ao final da migração
      echo $(date +%s) > "${local.start_time_file}"

      MSG=$(printf '%s\n' \
        "🚀 <b>MIGRAÇÃO INICIADA</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "🖥  Origem : <code>${var.source_instance_name}</code>  (E2)" \
        "🎯 Destino: <code>${local.new_instance_name}</code>  (${local.resolved_machine_type})" \
        "📋 Projeto: <code>${var.project_id}</code>" \
        "🌍 Zona   : <code>${var.zone}</code>" \
        "⏱  Início : <b>$HORA</b>"
      )

      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    EOT
  }
}

# ==============================================================================
# PASSO 1 — Snapshot do disco de boot da VM de origem (E2)
# DEPENDÊNCIA EXPLÍCITA: aguarda notify_migration_start (notificação de início).
# DEPENDÊNCIA IMPLÍCITA: lê boot_disk[0].source do data source da VM de origem.
# ==============================================================================
resource "google_compute_snapshot" "migration_snapshot" {
  name    = local.snapshot_name
  project = var.project_id
  zone    = var.zone

  # Garante que a notificação de início é enviada antes de qualquer operação
  depends_on = [null_resource.notify_migration_start]

  # O Terraform resolve o URI do disco automaticamente via data source — sem hardcode
  source_disk = data.google_compute_instance.source_vm.boot_disk[0].source

  storage_locations = [var.region]
  description       = "Snapshot de migração E2→N4 — origem: ${var.source_instance_name}"

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
    tipo       = "migracao"
  }

  # Impede destruição acidental durante o processo de migração
  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# PASSO 1.5 — Snapshots dos discos secundários da VM de origem (E2)
# Cria um snapshot para cada disco anexado que NÃO seja o disco de boot.
# Usa count para iterar dinamicamente — sem discos secundários, count = 0.
# ==============================================================================
resource "google_compute_snapshot" "secondary_disk_snapshot" {
  count = local.secondary_disk_count

  name    = "${local.secondary_disk_names[count.index]}-migration-snapshot"
  project = var.project_id
  zone    = var.zone

  depends_on = [null_resource.notify_migration_start]

  source_disk = local.attached_disks[count.index].source

  storage_locations = [var.region]
  description       = "Snapshot de migração E2→N4 — disco secundário: ${local.secondary_disk_names[count.index]}"

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
    tipo       = "migracao-secundario"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# NOTIFICAÇÃO 2 — Snapshot concluído
# Dispara quando o snapshot é criado pela primeira vez (trigger muda com o ID).
# Executa em paralelo com a criação do disco — não bloqueia o próximo passo.
# ==============================================================================
resource "null_resource" "notify_snapshot_done" {
  triggers = {
    snapshot_id = google_compute_snapshot.migration_snapshot.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      MSG=$(printf '%s\n' \
        "✅ <b>Passo 1/3 — Snapshot criado</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "📸 Nome  : <code>${local.snapshot_name}</code>" \
        "📍 Região: <code>${var.region}</code>" \
        "⏱  Hora  : <b>$HORA</b>" \
        "" \
        "▶ Criando disco Hyperdisk-Balanced..."
      )

      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    EOT
  }
}

# ==============================================================================
# PASSO 2 — Disco Hyperdisk-Balanced para a nova instância N4
# DEPENDÊNCIA IMPLÍCITA: aguarda o snapshot via 'snapshot = ...self_link'.
# O Terraform ordena a criação automaticamente por essa referência.
# Tipo 'hyperdisk-balanced' é obrigatório — pd-* não é suportado em N4.
# ==============================================================================
resource "google_compute_disk" "migration_hyperdisk" {
  name    = local.new_disk_name
  project = var.project_id
  zone    = var.zone

  # Tipo obrigatório para N4: pd-standard e pd-ssd causam falha na criação da instância
  type = "hyperdisk-balanced"

  # Dependência implícita: o disco SÓ é provisionado após o snapshot estar disponível
  snapshot = google_compute_snapshot.migration_snapshot.self_link

  # Garante explicitamente que rotinas de backup automático não sejam vinculadas ao novo disco

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
  }

  # Proteção crítica: preserva os dados mesmo que a instância seja destruída
  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# PASSO 2.5 — Discos Hyperdisk-Balanced para discos secundários
# Cria um Hyperdisk para cada disco secundário a partir do snapshot correspondente.
# Usa count para iterar dinamicamente — sem discos secundários, count = 0.
# ==============================================================================
resource "google_compute_disk" "secondary_hyperdisk" {
  count = local.secondary_disk_count

  name    = "${local.secondary_disk_names[count.index]}-hyperdisk"
  project = var.project_id
  zone    = var.zone

  type = "hyperdisk-balanced"

  # Dependência implícita: aguarda o snapshot do disco secundário correspondente
  snapshot = google_compute_snapshot.secondary_disk_snapshot[count.index].self_link

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# NOTIFICAÇÃO 3 — Disco Hyperdisk criado
# Executa quando o disco é criado. Avisa que o downtime está prestes a começar.
# ==============================================================================
resource "null_resource" "notify_disk_done" {
  triggers = {
    disk_id = google_compute_disk.migration_hyperdisk.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      MSG=$(printf '%s\n' \
        "✅ <b>Passo 2/3 — Hyperdisk criado</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "💾 Nome: <code>${local.new_disk_name}</code>" \
        "🔷 Tipo: <code>hyperdisk-balanced</code>" \
        "📍 Zona: <code>${var.zone}</code>" \
        "⏱  Hora: <b>$HORA</b>" \
        "" \
        "⚠️ Próximo passo: parar a VM E2 e liberar o IP..." \
        "⚠️ <b>O downtime começará em instantes.</b>"
      )

      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    EOT
  }
}

# ==============================================================================
# PASSO 2.5 — Para a VM E2 e desvincula o IP externo (via gcloud)
# DEPENDÊNCIA EXPLÍCITA: executa SOMENTE após o Hyperdisk estar pronto.
# Estratégia: snapshot e disco são criados com a E2 ainda no ar para
# minimizar o downtime. Só então a E2 é parada e o IP é liberado para a N4.
#
# INÍCIO DO DOWNTIME: a E2 fica inacessível externamente a partir daqui.
#
# PRÉ-REQUISITO: gcloud instalado e autenticado com permissão Compute Instance Admin.
# ==============================================================================
resource "null_resource" "stop_and_detach_e2" {
  # Executa sempre para garantir que a E2 está parada e IP liberado
  triggers = {
    hyperdisk_id          = google_compute_disk.migration_hyperdisk.id
    secondary_disks_ready = join(",", google_compute_disk.secondary_hyperdisk[*].id)
    always_run            = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      # Notifica o início do downtime antes de parar a E2
      MSG_DOWN=$(printf '%s\n' \
        "⚠️ <b>Passo 2.5 — DOWNTIME INICIADO</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "🔴 Parando VM  : <code>${var.source_instance_name}</code>" \
        "🔌 Liberando IP: <code>${data.google_compute_instance.source_vm.network_interface[0].access_config[0].nat_ip}</code>" \
        "⏱  Horário     : <b>$HORA</b>"
      )
      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG_DOWN" > /dev/null 2>&1 || true

      # O comando gcloud no Git Bash Windows pode requerer .cmd
      GCLOUD_CMD="gcloud"
      command -v gcloud.cmd >/dev/null 2>&1 && GCLOUD_CMD="gcloud.cmd"

      # [1/2] Para a instância E2 — idempotente: gcloud não falha se já estiver parada
      echo ">>> [1/2] Parando a instância E2: ${var.source_instance_name}"
      STATUS_E2=$($GCLOUD_CMD compute instances describe "${var.source_instance_name}" \
        --zone="${var.zone}" --project="${var.project_id}" \
        --format="value(status)" || echo "NOT_FOUND")
      if [ "$STATUS_E2" = "RUNNING" ] || [ "$STATUS_E2" = "STAGING" ]; then
        $GCLOUD_CMD compute instances stop "${var.source_instance_name}" \
          --zone="${var.zone}" \
          --project="${var.project_id}" \
          --quiet
        echo ">>> E2 parada com sucesso."
      else
        echo ">>> E2 já estava parada (status: $STATUS_E2). Pulando stop."
      fi

      # [2/2] Desvincula o IP estático externo da E2 — verifica antes de tentar remover
      echo ">>> [2/2] Verificando IP externo..."
      EXISTING_CONFIG=$($GCLOUD_CMD compute instances describe "${var.source_instance_name}" \
        --zone="${var.zone}" --project="${var.project_id}" \
        --format="value(networkInterfaces[0].accessConfigs[0].name)" || echo "")
      if [ -n "$EXISTING_CONFIG" ]; then
        echo ">>> Access config encontrado: '$EXISTING_CONFIG'. Removendo..."
        $GCLOUD_CMD compute instances delete-access-config "${var.source_instance_name}" \
          --access-config-name="$EXISTING_CONFIG" \
          --zone="${var.zone}" \
          --project="${var.project_id}" \
          --quiet
        echo ">>> IP desvinculado com sucesso. Pronto para criar a instância N4."
      else
        echo ">>> IP externo já estava desvinculado ou não encontrado. Pulando."
      fi
    EOT
  }
}

# ==============================================================================
# PASSO 3 — Nova instância N4 com Hyperdisk e IP estático reutilizado
# DEPENDÊNCIA EXPLÍCITA via depends_on: a instância SÓ é criada após
# stop_and_detach_e2 confirmar que a E2 foi parada e o IP está livre.
# FIM DO DOWNTIME: quando a N4 subir com o mesmo IP, o serviço volta ao ar.
# ==============================================================================
resource "google_compute_instance" "migrated_n4_instance" {
  name         = local.new_instance_name
  # Tipo resolvido automaticamente em locals.tf a partir de target_vcpus + target_memory_gb
  machine_type = local.resolved_machine_type
  project      = var.project_id
  zone         = var.zone

  # Garante que E2 está parada e IP está liberado antes de criar a N4.
  # Sem isso, o GCP retorna erro: IP_IN_USE_BY_ANOTHER_RESOURCE
  depends_on = [null_resource.stop_and_detach_e2]

  # Permite que o Terraform pare a VM para aplicar mudanças sem recriar o recurso
  allow_stopping_for_update = true

  # Copia as network tags da VM E2 de origem para manter as mesmas regras de firewall
  tags = data.google_compute_instance.source_vm.tags

  # auto_delete = false: disco NÃO é excluído caso a instância seja destruída.
  # Proteção dupla junto com o prevent_destroy no google_compute_disk.
  boot_disk {
    source      = google_compute_disk.migration_hyperdisk.self_link
    auto_delete = false
  }

  # Discos secundários — anexa todos os Hyperdisks criados a partir dos snapshots
  # Preserva o modo (rw/ro) original da VM E2; auto_delete não se aplica a
  # attached_disk com source (disco pré-existente) — o disco não é deletado com a VM.
  dynamic "attached_disk" {
    for_each = local.attached_disks
    content {
      source = google_compute_disk.secondary_hyperdisk[attached_disk.key].self_link
      mode   = local.secondary_disk_modes[attached_disk.key].mode
    }
  }

  network_interface {
    # Se network/subnetwork estiverem vazias em terraform.tfvars, herda automaticamente
    # da VM E2 de origem via data source — garante compatibilidade sem configuração manual.
    # Para forçar uma rede diferente, preencha as variáveis em terraform.tfvars.
    network    = coalesce(var.network,    data.google_compute_instance.source_vm.network_interface[0].network)
    subnetwork = coalesce(var.subnetwork, data.google_compute_instance.source_vm.network_interface[0].subnetwork)

    # Reutiliza o IP estático já liberado da VM E2 (obtido dinamicamente)
    access_config {
      nat_ip = data.google_compute_instance.source_vm.network_interface[0].access_config[0].nat_ip
    }

    # OBRIGATÓRIO para família N4: VirtioNet não é suportado — sem GVNIC a VM não inicializa
    nic_type = "GVNIC"
  }

  metadata = {
    migrado-de = var.source_instance_name
    gerenciado = "terraform"
  }

  labels = {
    origem     = var.source_instance_name
    familia    = "n4"
    gerenciado = "terraform"
  }

  lifecycle {
    # Evita recriações desnecessárias por metadados injetados pelo GCP (IAP, startup-scripts, etc.)
    ignore_changes = [metadata]
  }
}

# ==============================================================================
# NOTIFICAÇÃO 4 — Migração concluída
# Verifica o status real da VM N4 via gcloud e envia resumo completo:
# nome, status, IP externo e duração total calculada desde o início.
# ==============================================================================
resource "null_resource" "notify_migration_done" {
  triggers = {
    instance_id = google_compute_instance.migrated_n4_instance.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')
      INSTANCE="${local.new_instance_name}"
      PROJECT="${var.project_id}"
      ZONE="${var.zone}"
      IP="${data.google_compute_instance.source_vm.network_interface[0].access_config[0].nat_ip}"
      START_FILE="${local.start_time_file}"

      # Verifica o status real da instância N4 via gcloud
      STATUS=$(gcloud compute instances describe "$INSTANCE" \
        --zone="$ZONE" --project="$PROJECT" \
        --format="value(status)" 2>/dev/null || echo "DESCONHECIDO")

      # Calcula duração total a partir do timestamp salvo no início
      DURACAO="não disponível"
      if [ -f "$START_FILE" ]; then
        START_TS=$(cat "$START_FILE")
        NOW_TS=$(date +%s)
        DIFF=$((NOW_TS - START_TS))
        MIN=$((DIFF / 60))
        SEG=$((DIFF % 60))
        DURACAO="$${MIN}m $${SEG}s"
        rm -f "$START_FILE"
      fi

      # Define ícone e texto conforme o status retornado pelo GCP
      if [ "$STATUS" = "RUNNING" ]; then
        STATUS_ICON="✅"
        STATUS_TEXT="ONLINE — RUNNING"
      else
        STATUS_ICON="⚠️"
        STATUS_TEXT="$STATUS"
      fi

      MSG=$(printf '%s\n' \
        "🎉 <b>MIGRAÇÃO CONCLUÍDA</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "$STATUS_ICON VM N4     : <code>$INSTANCE</code>" \
        "📊 Status   : <b>$STATUS_TEXT</b>" \
        "🌐 IP Externo: <code>$IP</code>" \
        "⚡ Tipo      : <code>${local.resolved_machine_type} + hyperdisk-balanced</code>" \
        "⏱  Duração  : <b>$DURACAO</b>" \
        "📋 Projeto   : <code>$PROJECT</code>" \
        "🕐 Fim       : <b>$HORA</b>"
      )

      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    EOT
  }
}
