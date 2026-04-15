# ==============================================================================
# locals.tf
# Valores derivados automaticamente das variáveis — sem configuração manual.
# Nunca edite este arquivo; ajuste as variáveis em terraform.tfvars.
# ==============================================================================

locals {
  # ============================================================================
  # Nomes dos novos recursos — gerados a partir da VM de origem + família
  # Garante rastreabilidade e consistência entre os recursos criados.
  # ============================================================================
  new_instance_name = "${var.source_instance_name}-${var.target_machine_family}"
  new_disk_name     = "${var.source_instance_name}-${local.resolved_disk_type}"
  snapshot_name     = "${var.source_instance_name}-migration-snapshot"

  # URL base da API do Telegram — montada a partir do token da variável.
  telegram_api_url = "https://api.telegram.org/bot${var.telegram_bot_token}/sendMessage"

  # Caminho do arquivo temporário usado para calcular a duração total da migração.
  start_time_file = "/tmp/tf_migration_${replace(var.project_id, "/", "_")}_start"

  # ============================================================================
  # Discos secundários — extraídos dinamicamente da VM de origem
  # O data source expõe attached_disk (discos não-boot). Usamos regex para
  # extrair o nome do disco a partir do self_link.
  # ============================================================================
  attached_disks = [
    for disk in data.google_compute_instance.source_vm.attached_disk : disk
    if disk.source != data.google_compute_instance.source_vm.boot_disk[0].source
  ]

  secondary_disk_count = length(local.attached_disks)

  secondary_disk_names = [
    for disk in local.attached_disks : regex("disks/([^/]+)$", disk.source)[0]
  ]

  secondary_disk_modes = [
    for disk in local.attached_disks : {
      mode = disk.mode
    }
  ]

  # ============================================================================
  # GVNIC — determinado pela família de destino
  # N4, C3, C3D, T2A, M3: GVNIC obrigatório
  # N2, N2D, C2, C2D, T2D: GVNIC opcional (suportado)
  # E2, N1, M1, M2: GVNIC não suportado (VIRTIO_NET)
  # ============================================================================
  gvnic_required_families = toset(["n4", "c3", "c3d", "t2a", "m3"])
  gvnic_unsupported_families = toset(["m1", "m2"])

  requires_gvnic = contains(local.gvnic_required_families, var.target_machine_family)
  supports_gvnic = !contains(local.gvnic_unsupported_families, var.target_machine_family)

  # ============================================================================
  # Tipo de disco — resolução e lógica de reuso
  # Se target_disk_type for vazio, usa o default da família.
  # Se o tipo do disco de origem for igual ao tipo resolvido, reutiliza o disco
  # (sem criar novo a partir de snapshot). Se diferente, cria novo.
  # ============================================================================
  family_default_disk_type = {
    n4  = "hyperdisk-balanced"
    c3  = "hyperdisk-balanced"
    c3d = "hyperdisk-balanced"
    m3  = "hyperdisk-balanced"
  }

  resolved_disk_type = coalesce(
    var.target_disk_type != "" ? var.target_disk_type : null,
    lookup(local.family_default_disk_type, var.target_machine_family, "pd-balanced")
  )

  # Tipo e tamanho do disco de boot de origem (lido via data source)
  source_boot_disk_type = data.google_compute_disk.source_boot_disk.type
  source_boot_disk_size = data.google_compute_disk.source_boot_disk.size_gb

  # Lógica de reuso: mesmo tipo = reutiliza; diferente = cria novo a partir de snapshot
  disk_type_changed = local.source_boot_disk_type != local.resolved_disk_type
  create_new_disk   = local.disk_type_changed

  # Texto descritivo da ação do disco — usado nas notificações
  disk_action_text = local.create_new_disk ? "Criado novo disco ${local.resolved_disk_type} a partir de snapshot" : "Disco reutilizado (${local.resolved_disk_type}) — snapshot criado para seguranca"

  # ============================================================================
  # Resolução automática do tipo de máquina — multi-família
  # Ordem de prioridade:
  #   1. machine_type_override (definido manualmente) — tem precedência total
  #   2. Tipo predefinido que bate exatamente com vcpus + memory_gb
  #   3. custom com a combinação informada (fallback)
  # ============================================================================
  predefined_types = {
    # --- N4 Standard (4 GB / vCPU) ---
    n4 = {
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
    # --- N2 Standard (4 GB / vCPU) ---
    n2 = {
      "2-8"    = "n2-standard-2"
      "4-16"   = "n2-standard-4"
      "8-32"   = "n2-standard-8"
      "16-64"  = "n2-standard-16"
      "32-128" = "n2-standard-32"
      "48-192" = "n2-standard-48"
      "64-256" = "n2-standard-64"
      "80-320" = "n2-standard-80"
      "96-384" = "n2-standard-96"
      "128-512" = "n2-standard-128"
      # --- N2 Highmem (8 GB / vCPU) ---
      "2-16"   = "n2-highmem-2"
      "4-32"   = "n2-highmem-4"
      "8-64"   = "n2-highmem-8"
      "16-128" = "n2-highmem-16"
      "32-256" = "n2-highmem-32"
      "48-384" = "n2-highmem-48"
      "64-512" = "n2-highmem-64"
      "80-640" = "n2-highmem-80"
      "96-768" = "n2-highmem-96"
      "128-864" = "n2-highmem-128"
      "224-1433" = "n2-highmem-224"
      # --- N2 Highcpu (1 GB / vCPU) ---
      "2-2"    = "n2-highcpu-2"
      "4-4"    = "n2-highcpu-4"
      "8-8"    = "n2-highcpu-8"
      "16-16"  = "n2-highcpu-16"
      "32-32"  = "n2-highcpu-32"
      "48-48"  = "n2-highcpu-48"
      "64-64"  = "n2-highcpu-64"
      "80-80"  = "n2-highcpu-80"
      "96-96"  = "n2-highcpu-96"
      "128-128" = "n2-highcpu-128"
    }
    # --- N2D Standard (4 GB / vCPU) ---
    n2d = {
      "2-8"    = "n2d-standard-2"
      "4-16"   = "n2d-standard-4"
      "8-32"   = "n2d-standard-8"
      "16-64"  = "n2d-standard-16"
      "32-128" = "n2d-standard-32"
      "48-192" = "n2d-standard-48"
      "64-256" = "n2d-standard-64"
      "80-320" = "n2d-standard-80"
      "96-384" = "n2d-standard-96"
      "128-512" = "n2d-standard-128"
      "224-896" = "n2d-standard-224"
      # --- N2D Highmem (8 GB / vCPU) ---
      "2-16"   = "n2d-highmem-2"
      "4-32"   = "n2d-highmem-4"
      "8-64"   = "n2d-highmem-8"
      "16-128" = "n2d-highmem-16"
      "32-256" = "n2d-highmem-32"
      "48-384" = "n2d-highmem-48"
      "64-512" = "n2d-highmem-64"
      "80-640" = "n2d-highmem-80"
      "96-768" = "n2d-highmem-96"
      # --- N2D Highcpu (1 GB / vCPU) ---
      "2-2"    = "n2d-highcpu-2"
      "4-4"    = "n2d-highcpu-4"
      "8-8"    = "n2d-highcpu-8"
      "16-16"  = "n2d-highcpu-16"
      "32-32"  = "n2d-highcpu-32"
      "48-48"  = "n2d-highcpu-48"
      "64-64"  = "n2d-highcpu-64"
      "80-80"  = "n2d-highcpu-80"
      "96-96"  = "n2d-highcpu-96"
      "128-128" = "n2d-highcpu-128"
      "224-224" = "n2d-highcpu-224"
    }
    # --- E2 Standard (4 GB / vCPU) ---
    e2 = {
      "2-8"    = "e2-standard-2"
      "4-16"   = "e2-standard-4"
      "8-32"   = "e2-standard-8"
      "16-64"  = "e2-standard-16"
      "32-128" = "e2-standard-32"
      # --- E2 Highmem (8 GB / vCPU) ---
      "2-16"   = "e2-highmem-2"
      "4-32"   = "e2-highmem-4"
      "8-64"   = "e2-highmem-8"
      "16-128" = "e2-highmem-16"
      "32-256" = "e2-highmem-32"
      # --- E2 Highcpu (~1 GB / vCPU) ---
      "2-2"    = "e2-highcpu-2"
      "4-4"    = "e2-highcpu-4"
      "8-8"    = "e2-highcpu-8"
      "16-16"  = "e2-highcpu-16"
      "32-32"  = "e2-highcpu-32"
      # --- E2 Medium (1 vCPU compartilhado, 4 GB) ---
      # Use machine_type_override = "e2-medium" para selecionar diretamente
    }
    # --- C2 Standard (4 GB / vCPU) ---
    c2 = {
      "4-16"   = "c2-standard-4"
      "8-32"   = "c2-standard-8"
      "16-64"  = "c2-standard-16"
      "30-120" = "c2-standard-30"
      "60-240" = "c2-standard-60"
    }
    # --- C2D Standard (4 GB / vCPU) ---
    c2d = {
      "2-8"    = "c2d-standard-2"
      "4-16"   = "c2d-standard-4"
      "8-32"   = "c2d-standard-8"
      "16-64"  = "c2d-standard-16"
      "32-128" = "c2d-standard-32"
      "56-224" = "c2d-standard-56"
      "112-448" = "c2d-standard-112"
      # --- C2D Highmem (8 GB / vCPU) ---
      "2-16"   = "c2d-highmem-2"
      "4-32"   = "c2d-highmem-4"
      "8-64"   = "c2d-highmem-8"
      "16-128" = "c2d-highmem-16"
      "32-256" = "c2d-highmem-32"
      "56-448" = "c2d-highmem-56"
      "112-896" = "c2d-highmem-112"
      # --- C2D Highcpu (2 GB / vCPU) ---
      "2-2"    = "c2d-highcpu-2"
      "4-4"    = "c2d-highcpu-4"
      "8-8"    = "c2d-highcpu-8"
      "16-16"  = "c2d-highcpu-16"
      "32-32"  = "c2d-highcpu-32"
      "56-56"  = "c2d-highcpu-56"
      "112-112" = "c2d-highcpu-112"
    }
    # --- C3 Standard (4 GB / vCPU) ---
    c3 = {
      "4-16"   = "c3-standard-4"
      "8-32"   = "c3-standard-8"
      "22-88"  = "c3-standard-22"
      "44-176" = "c3-standard-44"
      "88-352" = "c3-standard-88"
      "176-704" = "c3-standard-176"
      # --- C3 Highmem (8 GB / vCPU) ---
      "4-32"   = "c3-highmem-4"
      "8-64"   = "c3-highmem-8"
      "22-176" = "c3-highmem-22"
      "44-352" = "c3-highmem-44"
      "88-704" = "c3-highmem-88"
      "176-1408" = "c3-highmem-176"
      # --- C3 Highcpu (2 GB / vCPU) ---
      "4-8"    = "c3-highcpu-4"
      "8-16"   = "c3-highcpu-8"
      "22-44"  = "c3-highcpu-22"
      "44-88"  = "c3-highcpu-44"
      "88-176" = "c3-highcpu-88"
      "176-352" = "c3-highcpu-176"
    }
    # --- C3D Standard (4 GB / vCPU) ---
    c3d = {
      "4-16"   = "c3d-standard-4"
      "8-32"   = "c3d-standard-8"
      "16-64"  = "c3d-standard-16"
      "30-120" = "c3d-standard-30"
      "60-240" = "c3d-standard-60"
      "90-360" = "c3d-standard-90"
      "180-720" = "c3d-standard-180"
      "360-1440" = "c3d-standard-360"
      # --- C3D Highmem (8 GB / vCPU) ---
      "4-32"   = "c3d-highmem-4"
      "8-64"   = "c3d-highmem-8"
      "16-128" = "c3d-highmem-16"
      "30-240" = "c3d-highmem-30"
      "60-480" = "c3d-highmem-60"
      "90-720" = "c3d-highmem-90"
      "180-1440" = "c3d-highmem-180"
      "360-2880" = "c3d-highmem-360"
      # --- C3D Highcpu (2 GB / vCPU) ---
      "4-8"    = "c3d-highcpu-4"
      "8-16"   = "c3d-highcpu-8"
      "16-32"  = "c3d-highcpu-16"
      "30-60"  = "c3d-highcpu-30"
      "60-120" = "c3d-highcpu-60"
      "90-180" = "c3d-highcpu-90"
      "180-360" = "c3d-highcpu-180"
      "360-720" = "c3d-highcpu-360"
    }
    # --- M1 (memory-optimized, ~14 GB / vCPU) ---
    m1 = {
      "4-61"    = "m1-ultramem-4"
      "8-122"   = "m1-ultramem-8"
      "16-244"  = "m1-ultramem-16"
      "24-366"  = "m1-ultramem-24"
      "32-488"  = "m1-ultramem-32"
      "40-614"  = "m1-ultramem-40"
      "48-730"  = "m1-ultramem-48"
      "64-976"  = "m1-ultramem-64"
      "80-1220" = "m1-ultramem-80"
      "96-1464" = "m1-ultramem-96"
    }
    # --- M3 (memory-optimized, ~14 GB / vCPU) ---
    m3 = {
      "4-61"    = "m3-ultramem-4"
      "8-122"   = "m3-ultramem-8"
      "16-244"  = "m3-ultramem-16"
      "24-366"  = "m3-ultramem-24"
      "32-488"  = "m3-ultramem-32"
      "48-730"  = "m3-ultramem-48"
      "64-976"  = "m3-ultramem-64"
      "80-1220" = "m3-ultramem-80"
      "96-1464" = "m3-ultramem-96"
      "128-1952" = "m3-ultramem-128"
    }
    # --- T2A (ARM, 4 GB / vCPU) ---
    t2a = {
      "1-4"    = "t2a-standard-1"
      "2-8"    = "t2a-standard-2"
      "4-16"   = "t2a-standard-4"
      "8-32"   = "t2a-standard-8"
      "16-64"  = "t2a-standard-16"
      "32-128" = "t2a-standard-32"
      "48-192" = "t2a-standard-48"
    }
    # --- T2D (AMD, 4 GB / vCPU) ---
    t2d = {
      "2-8"    = "t2d-standard-2"
      "4-16"   = "t2d-standard-4"
      "8-32"   = "t2d-standard-8"
      "16-64"  = "t2d-standard-16"
      "32-128" = "t2d-standard-32"
      "48-192" = "t2d-standard-48"
      "60-240" = "t2d-standard-60"
    }
  }

  # Chave de lookup derivada das variáveis informadas
  machine_key = "${var.target_vcpus}-${var.target_memory_gb}"

  # Lookup na tabela da família selecionada
  family_types     = lookup(local.predefined_types, var.target_machine_family, {})
  predefined_match = lookup(local.family_types, local.machine_key, "")

  # Tipo custom para combinações sem equivalente predefinido
  # Convenção GCP: <family>-custom-<vcpus>-<mem_mb>
  custom_machine_type = "${var.target_machine_family}-custom-${var.target_vcpus}-${var.target_memory_gb * 1024}"

  # Tipo final resolvido
  resolved_machine_type = coalesce(
    var.machine_type_override != "" ? var.machine_type_override : null,
    local.predefined_match != ""    ? local.predefined_match    : null,
    local.custom_machine_type
  )

  # Indica a origem da resolução
  machine_type_source = (
    var.machine_type_override != "" ? "override-manual (${var.machine_type_override})" :
    local.predefined_match    != "" ? "predefinido (${local.predefined_match})" :
                                      "custom (${local.custom_machine_type})"
  )

  # Texto do NIC para exibição
  nic_type_text = local.requires_gvnic ? "GVNIC (obrigatorio)" : (local.supports_gvnic ? "VIRTIO_NET (GVNIC opcional)" : "VIRTIO_NET")
}
