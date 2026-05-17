# ==============================================================================
# main.tf
# Recursos de infraestrutura — orquestração completa da migração de VMs GCP
#
# Cadeia de dependências gerenciada pelo Terraform:
#
#   notify_start ──► snapshot ──► notify_snapshot_done
#                            └──► disk (se tipo mudou) ──► notify_disk_done (se tipo mudou)
#                                      └──► stop_and_detach_source  ◄── DOWNTIME INICIA
#                                                └──► instância destino              ◄── DOWNTIME ENCERRA
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
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      echo $(date +%s) > "${local.start_time_file}"

      DISK_ACTION="${local.create_new_disk ? "Criar novo disco (${local.resolved_disk_type} ${local.resolved_disk_size}GB)${local.disk_is_downgrade ? " ⚠️ DOWNGRADE" : ""}" : "Reutilizar disco (${local.resolved_disk_type} ${local.source_boot_disk_size}GB)"}"

      MSG=$(printf '%s\n' \
        "🚀 <b>MIGRAÇÃO INICIADA</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "🖥  Origem : <code>${var.source_instance_name}</code>" \
        "🎯 Destino: <code>${local.new_instance_name}</code> (${local.resolved_machine_type})" \
        "💾 Disco  : $DISK_ACTION" \
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
# PASSO 1 — Snapshot do disco de boot da VM de origem
# DEPENDÊNCIA EXPLÍCITA: aguarda notify_migration_start.
# O snapshot é SEMPRE criado (para segurança), mesmo quando o disco será reutilizado.
# ==============================================================================
resource "google_compute_snapshot" "migration_snapshot" {
  name    = local.snapshot_name
  project = var.project_id

  depends_on = [null_resource.notify_migration_start]

  source_disk = data.google_compute_instance.source_vm.boot_disk[0].source

  storage_locations = [var.region]
  description       = "Snapshot de migração — origem: ${var.source_instance_name} → ${local.new_instance_name}"

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
    tipo       = "migracao"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

# ==============================================================================
# PASSO 1.5 — Snapshots dos discos secundários da VM de origem
# Cria um snapshot para cada disco anexado que NÃO seja o disco de boot.
# ==============================================================================
resource "google_compute_snapshot" "secondary_disk_snapshot" {
  count = local.secondary_disk_count

  name    = "${local.secondary_disk_names[count.index]}-migration-snapshot"
  project = var.project_id

  depends_on = [null_resource.notify_migration_start]

  source_disk = local.attached_disks[count.index].source

  storage_locations = [var.region]
  description       = "Snapshot de migração — disco secundário: ${local.secondary_disk_names[count.index]}"

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
    tipo       = "migracao-secundario"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

# ==============================================================================
# NOTIFICAÇÃO 2 — Snapshot concluído
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

      DISK_MSG="${local.create_new_disk ? "▶ Criando disco ${local.resolved_disk_type} ${local.resolved_disk_size}GB..." : "▶ Disco sera reutilizado — nenhum disco novo necessario."}"

      MSG=$(printf '%s\n' \
        "✅ <b>Passo 1/3 — Snapshot criado</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "📸 Nome  : <code>${local.snapshot_name}</code>" \
        "📍 Região: <code>${var.region}</code>" \
        "⏱  Hora  : <b>$HORA</b>" \
        "" \
        "$DISK_MSG"
      )

      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    EOT
  }
}

# ==============================================================================
# PASSO 2 — Disco de boot para a nova instância (CONDICIONAL)
# Só é criado quando o tipo de disco muda (create_new_disk = true).
# Quando o tipo é o mesmo, o disco de origem é reutilizado diretamente.
# ==============================================================================
resource "google_compute_disk" "migration_boot_disk" {
  count = local.create_new_disk ? 1 : 0

  name    = local.new_disk_name
  project = var.project_id
  zone    = var.zone

  type = local.resolved_disk_type

  # Tamanho do disco — só é definido quando o usuário solicitou mudança (change_disk_size=true).
  # Quando não solicitado, o GCP herda o tamanho do snapshot automaticamente.
  size = var.change_disk_size ? var.target_disk_size : null

  # Dependência implícita: o disco SÓ é provisionado após o snapshot estar disponível
  snapshot = google_compute_snapshot.migration_snapshot.self_link

  # GVNIC feature — adicionado quando a família de destino suporta
  dynamic "guest_os_features" {
    for_each = local.supports_gvnic ? [1] : []
    content {
      type = "GVNIC"
    }
  }

  labels = {
    origem     = var.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# ==============================================================================
# PASSO 2.5 — Discos secundários (sempre criados a partir de snapshot)
# Nota: a lógica de reuso se aplica apenas ao disco de boot.
# Discos secundários são sempre recriados para garantir consistência.
# ==============================================================================
resource "google_compute_disk" "secondary_disk" {
  count = local.secondary_disk_count

  name    = "${local.secondary_disk_names[count.index]}-${local.resolved_disk_type}"
  project = var.project_id
  zone    = var.zone

  type = local.resolved_disk_type

  snapshot = google_compute_snapshot.secondary_disk_snapshot[count.index].self_link

  dynamic "guest_os_features" {
    for_each = local.supports_gvnic ? [1] : []
    content {
      type = "GVNIC"
    }
  }

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
# NOTIFICAÇÃO 3 — Disco criado (CONDICIONAL — só quando disco novo é criado)
# ==============================================================================
resource "null_resource" "notify_disk_done" {
  count = local.create_new_disk ? 1 : 0

  triggers = {
    disk_id = google_compute_disk.migration_boot_disk[0].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      MSG=$(printf '%s\n' \
        "✅ <b>Passo 2/3 — Disco criado</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "💾 Nome    : <code>${local.new_disk_name}</code>" \
        "🔷 Tipo    : <code>${local.resolved_disk_type}</code>" \
        "📏 Tamanho : <code>${local.resolved_disk_size}GB</code>${local.disk_is_downgrade ? " ⚠️ DOWNGRADE" : ""}" \
        "📍 Zona    : <code>${var.zone}</code>" \
        "⏱  Hora    : <b>$HORA</b>" \
        "" \
        "⚠️ Próximo passo: parar a VM de origem e liberar o IP..." \
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
# PASSO 2.5 — Para a VM de origem e desvincula o IP externo (via gcloud)
# INÍCIO DO DOWNTIME: a VM de origem fica inacessível a partir daqui.
# ==============================================================================
resource "null_resource" "stop_and_detach_source" {
  triggers = {
    # Depende do disco novo (se criado) ou apenas do snapshot (se reutilizado)
    boot_disk_ready     = local.create_new_disk ? google_compute_disk.migration_boot_disk[0].id : google_compute_snapshot.migration_snapshot.id
    secondary_disks_ready = join(",", google_compute_disk.secondary_disk[*].id)
    always_run          = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      TOKEN="${var.telegram_bot_token}"
      CHAT_ID="${var.telegram_chat_id}"
      HORA=$(date '+%d/%m/%Y %H:%M:%S')

      MSG_DOWN=$(printf '%s\n' \
        "⚠️ <b>Passo 2.5 — DOWNTIME INICIADO</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "🔴 Parando VM  : <code>${var.source_instance_name}</code>" \
        "🔌 IP externo  : <code>${try(data.google_compute_instance.source_vm.network_interface[0].access_config[0].nat_ip, "já liberado")}</code>" \
        "⏱  Horário     : <b>$HORA</b>"
      )
      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG_DOWN" > /dev/null 2>&1 || true

      # [1/2] Para a instância de origem — idempotente
      echo ">>> [1/2] Parando a instância: ${var.source_instance_name}"
      STATUS_SRC=$(gcloud compute instances describe "${var.source_instance_name}" \
        --zone="${var.zone}" --project="${var.project_id}" \
        --format="value(status)" || echo "NOT_FOUND")
      if [ "$STATUS_SRC" = "RUNNING" ] || [ "$STATUS_SRC" = "STAGING" ]; then
        gcloud compute instances stop "${var.source_instance_name}" \
          --zone="${var.zone}" \
          --project="${var.project_id}" \
          --quiet
        echo ">>> Instância parada com sucesso."
      else
        echo ">>> Instância já estava parada (status: $STATUS_SRC). Pulando stop."
      fi

      # [2/2] Desvincula o IP estático externo
      echo ">>> [2/2] Verificando IP externo..."
      EXISTING_CONFIG=$(gcloud compute instances describe "${var.source_instance_name}" \
        --zone="${var.zone}" --project="${var.project_id}" \
        --format="value(networkInterfaces[0].accessConfigs[0].name)" || echo "")
      if [ -n "$EXISTING_CONFIG" ]; then
        echo ">>> Access config encontrado: '$EXISTING_CONFIG'. Removendo..."
        gcloud compute instances delete-access-config "${var.source_instance_name}" \
          --access-config-name="$EXISTING_CONFIG" \
          --zone="${var.zone}" \
          --project="${var.project_id}" \
          --quiet
        echo ">>> IP desvinculado com sucesso."
      else
        echo ">>> IP externo já estava desvinculado ou não encontrado. Pulando."
      fi
    EOT
  }
}

# ==============================================================================
# PASSO 3 — Nova instância com disco e IP estático reutilizado
# FIM DO DOWNTIME: quando a instância subir com o mesmo IP, o serviço volta ao ar.
# ==============================================================================
resource "google_compute_instance" "migrated_instance" {
  name         = local.new_instance_name
  machine_type = local.resolved_machine_type
  project      = var.project_id
  zone         = var.zone

  depends_on = [null_resource.stop_and_detach_source]

  allow_stopping_for_update = true

  # Copia as network tags da VM de origem
  tags = data.google_compute_instance.source_vm.tags

  # Disco de boot: usa o novo disco (se criado) ou reutiliza o disco de origem
  boot_disk {
    source      = local.create_new_disk ? google_compute_disk.migration_boot_disk[0].self_link : data.google_compute_disk.source_boot_disk.self_link
    auto_delete = false
  }

  # Discos secundários
  dynamic "attached_disk" {
    for_each = local.attached_disks
    content {
      source = google_compute_disk.secondary_disk[attached_disk.key].self_link
      mode   = local.secondary_disk_modes[attached_disk.key].mode
    }
  }

  network_interface {
    network    = coalesce(var.network, data.google_compute_instance.source_vm.network_interface[0].network)
    subnetwork = coalesce(var.subnetwork, data.google_compute_instance.source_vm.network_interface[0].subnetwork)

    access_config {
      nat_ip = try(data.google_compute_instance.source_vm.network_interface[0].access_config[0].nat_ip, null)
    }

    # GVNIC obrigatório para N4, C3, C3D, T2A, M3; VIRTIO_NET para demais
    nic_type = local.requires_gvnic ? "GVNIC" : "VIRTIO_NET"
  }

  metadata = {
    migrado-de = var.source_instance_name
    gerenciado = "terraform"
  }

  labels = {
    origem     = var.source_instance_name
    familia    = var.target_machine_family
    gerenciado = "terraform"
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

# ==============================================================================
# NOTIFICAÇÃO 4 — Migração concluída
# ==============================================================================
resource "null_resource" "notify_migration_done" {
  triggers = {
    instance_id = google_compute_instance.migrated_instance.id
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
      IP="${try(google_compute_instance.migrated_instance.network_interface[0].access_config[0].nat_ip, "N/A")}"
      START_FILE="${local.start_time_file}"

      STATUS=$(gcloud compute instances describe "$INSTANCE" \
        --zone="$ZONE" --project="$PROJECT" \
        --format="value(status)" 2>/dev/null || echo "DESCONHECIDO")

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

      if [ "$STATUS" = "RUNNING" ]; then
        STATUS_ICON="✅"
        STATUS_TEXT="ONLINE — RUNNING"
      else
        STATUS_ICON="⚠️"
        STATUS_TEXT="$STATUS"
      fi

      DISK_TEXT="${local.create_new_disk ? "Novo disco: ${local.resolved_disk_type} ${local.resolved_disk_size}GB${local.disk_is_downgrade ? " (DOWNGRADE)" : ""}" : "Disco reutilizado: ${local.resolved_disk_type} ${local.source_boot_disk_size}GB"}"

      MSG=$(printf '%s\n' \
        "🎉 <b>MIGRAÇÃO CONCLUÍDA</b>" \
        "━━━━━━━━━━━━━━━━━━━━━━━━" \
        "$STATUS_ICON VM         : <code>$INSTANCE</code>" \
        "📊 Status     : <b>$STATUS_TEXT</b>" \
        "🌐 IP Externo : <code>$IP</code>" \
        "⚡ Tipo        : <code>${local.resolved_machine_type}</code>" \
        "💾 Disco       : <code>$DISK_TEXT</code>" \
        "🔌 NIC         : <code>${local.nic_type_text}</code>" \
        "⏱  Duração    : <b>$DURACAO</b>" \
        "📋 Projeto     : <code>$PROJECT</code>" \
        "🕐 Fim         : <b>$HORA</b>"
      )

      curl -s -X POST "${local.telegram_api_url}" \
        -d "chat_id=$CHAT_ID" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    EOT
  }
}
