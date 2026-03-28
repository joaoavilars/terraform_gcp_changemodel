# ==============================================================================
# data.tf
# Leitura de recursos já existentes no GCP.
# Estes blocos NÃO criam, modificam nem destroem nada — apenas leem estado atual.
# ==============================================================================

# Lê a VM de origem (E2) para obter a referência (self_link) ao disco de boot.
# Esse self_link é passado ao google_compute_snapshot no main.tf para criar o snapshot.
data "google_compute_instance" "source_vm" {
  name    = var.source_instance_name
  zone    = var.zone
  project = var.project_id
}

