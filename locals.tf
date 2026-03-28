# ==============================================================================
# locals.tf
# Valores derivados automaticamente das variáveis — sem configuração manual.
# Nunca edite este arquivo; ajuste as variáveis em terraform.tfvars.
# ==============================================================================

locals {
  # Nomes dos novos recursos gerados a partir do nome da VM de origem.
  # Garante rastreabilidade e consistência entre os recursos criados.
  new_instance_name = "${var.source_instance_name}-n4"
  new_disk_name     = "${var.source_instance_name}-hyperdisk"
  snapshot_name     = "${var.source_instance_name}-migration-snapshot"

  # URL base da API do Telegram — montada a partir do token da variável.
  # Marcado como sensitive no provider para não aparecer em logs.
  telegram_api_url = "https://api.telegram.org/bot${var.telegram_bot_token}/sendMessage"

  # Caminho do arquivo temporário usado para calcular a duração total da migração.
  # O project_id é sanitizado para evitar caracteres inválidos no nome do arquivo.
  start_time_file = "/tmp/tf_migration_${replace(var.project_id, "/", "_")}_start"

  # ============================================================================
  # Resolução automática do tipo de máquina N4
  # Ordem de prioridade:
  #   1. machine_type_override (definido manualmente) — tem precedência total
  #   2. Tipo N4 predefinido que bate exatamente com vcpus + memory_gb
  #   3. n4-custom com a combinação informada (fallback)
  # ============================================================================

  # Tabela de tipos N4 predefinidos — chave: "vcpus-memgb"
  # Standard  → 4 GB/vCPU  |  Highmem → 8 GB/vCPU
  # Para adicionar novos tipos, inclua entradas no mesmo formato.
  n4_predefined_types = {
    # --- N4 Standard (4 GB / vCPU) ---
    "2-8"    = "n4-standard-2"
    "4-16"   = "n4-standard-4"
    "8-32"   = "n4-standard-8"
    "16-64"  = "n4-standard-16"
    "32-128" = "n4-standard-32"
    "48-192" = "n4-standard-48"
    "64-256" = "n4-standard-64"
    "80-320" = "n4-standard-80"
    # --- N4 Highmem (8 GB / vCPU) ---
    "2-16"   = "n4-highmem-2"
    "4-32"   = "n4-highmem-4"
    "8-64"   = "n4-highmem-8"
    "16-128" = "n4-highmem-16"
    "32-256" = "n4-highmem-32"
    "48-384" = "n4-highmem-48"
    "64-512" = "n4-highmem-64"
    "80-640" = "n4-highmem-80"
  }

  # Chave de lookup derivada das variáveis informadas
  machine_key = "${var.target_vcpus}-${var.target_memory_gb}"

  # Tipo N4 custom para combinações sem equivalente predefinido.
  # Memória convertida de GB → MB (formato obrigatório na API do GCP).
  custom_machine_type = "n4-custom-${var.target_vcpus}-${var.target_memory_gb * 1024}"

  # Resultado do lookup na tabela predefinida ("" se não encontrado)
  predefined_match = lookup(local.n4_predefined_types, local.machine_key, "")

  # Tipo final resolvido — coalesce ignora null e strings vazias automaticamente
  resolved_machine_type = coalesce(
    var.machine_type_override != "" ? var.machine_type_override : null,
    local.predefined_match != ""    ? local.predefined_match    : null,
    local.custom_machine_type
  )

  # Indica a origem da resolução — exibido no output para rastreabilidade
  machine_type_source = (
    var.machine_type_override != "" ? "override-manual (${var.machine_type_override})" :
    local.predefined_match    != "" ? "predefinido (${local.predefined_match})" :
                                      "custom (${local.custom_machine_type})"
  )
}
