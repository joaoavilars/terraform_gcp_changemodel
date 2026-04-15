# ==============================================================================
# data.tf
# Leitura de recursos já existentes no GCP.
# Estes blocos NÃO criam, modificam nem destroem nada — apenas leem estado atual.
# ==============================================================================

# Lê a VM de origem para obter a referência (self_link) ao disco de boot,
# discos secundários, network tags e network interface.
data "google_compute_instance" "source_vm" {
  name    = var.source_instance_name
  zone    = var.zone
  project = var.project_id
}

# Lê o disco de boot da VM de origem para obter tipo e tamanho.
# Necessário para a lógica de reuso: se o tipo do disco de origem for igual
# ao target_disk_type, o disco é reutilizado (sem criar novo a partir de snapshot).
data "google_compute_disk" "source_boot_disk" {
  name    = regex("disks/([^/]+)$", data.google_compute_instance.source_vm.boot_disk[0].source)[0]
  zone    = var.zone
  project = var.project_id
}
