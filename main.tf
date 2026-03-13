# ==============================================================================
# main.tf
# Automação de Migração de VM: Família E2 → N4 (Hyperdisk-Balanced)
# ------------------------------------------------------------------------------
# Fluxo de execução gerenciado pelo Terraform:
#
#   [DATA] VM de origem (leitura)  ──►  PASSO 1: Snapshot do disco de boot
#                                              │
#                                              ▼
#                                   PASSO 2: Disco Hyperdisk-Balanced
#                                     (disco aguarda o snapshot)
#                                              │
#                                              ▼
#                                   PASSO 2.5: Para E2 + desvincula IP  ◄── INÍCIO DO DOWNTIME
#                                     (null_resource + gcloud)
#                                              │
#   [DATA] IP Estático (leitura)   ──►         ▼
#                                   PASSO 3: Nova instância N4          ◄── FIM DO DOWNTIME
#                                     (instância aguarda o passo 2.5)
#
# Requisitos de compatibilidade N4:
#   - Tipo de disco : hyperdisk-balanced  (pd-* não é suportado)
#   - NIC           : GVNIC               (VirtioNet não inicializa em N4)
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    # Provider necessário para o null_resource que orquestra os comandos gcloud
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# ==============================================================================
# CONFIGURAÇÃO CENTRAL
# Edite APENAS este bloco locals para adaptar a migração ao seu ambiente.
# Todos os recursos derivam automaticamente dessas definições.
# ==============================================================================
locals {
  # --- Identidade do projeto ---
  project_id = "meu-projeto-gcp" # ID do projeto GCP (não o nome exibido)
  region     = "us-central1"     # Região onde os recursos serão criados
  zone       = "us-central1-a"   # Zona específica da instância (deve estar na region acima)

  # --- Recurso de origem ---
  source_instance_name = "vm-origem-e2" # Nome exato da VM E2 que será migrada

  # --- Recurso de rede ---
  existing_static_ip_name    = "ip-estatico-producao" # Nome do IP estático já reservado no GCP
  # Nome do access config do IP externo na VM E2.
  # Para verificar o nome correto: gcloud compute instances describe <NOME-VM> --zone=<ZONA>
  # O padrão do GCP é sempre "External NAT", altere somente se tiver customizado.
  source_access_config_name  = "External NAT"

  # --- Nomes derivados para os novos recursos ---
  # Gerados automaticamente a partir do nome da origem para garantir rastreabilidade
  new_instance_name = "${local.source_instance_name}-n4"
  new_disk_name     = "${local.source_instance_name}-hyperdisk"
  snapshot_name     = "${local.source_instance_name}-migration-snapshot"
}

# ==============================================================================
# PROVIDER
# Herda project, region e zone do bloco locals — sem duplicação de configuração
# ==============================================================================
provider "google" {
  project = local.project_id
  region  = local.region
  zone    = local.zone
}

# ==============================================================================
# DATA SOURCES — Leitura de recursos já existentes no GCP
# Esses blocos NÃO criam nada; apenas leem o estado atual da infraestrutura
# e expõem os atributos necessários para os recursos abaixo.
# ==============================================================================

# Lê a VM de origem para obter a referência (self_link) ao seu disco de boot.
# Essa referência é passada diretamente ao google_compute_snapshot no Passo 1.
data "google_compute_instance" "source_vm" {
  name    = local.source_instance_name
  zone    = local.zone
  project = local.project_id
}

# Lê o IP estático já reservado para reutilizá-lo na nova VM.
# Reutilizar o IP evita a necessidade de atualizar DNS, firewalls ou
# configurações de clientes que já conhecem o endereço atual.
data "google_compute_address" "existing_static_ip" {
  name    = local.existing_static_ip_name
  region  = local.region
  project = local.project_id
}

# ==============================================================================
# PASSO 1 — Snapshot do disco de boot da VM de origem (E2)
# Captura um ponto de restauração imutável do disco antes de qualquer alteração.
# Este snapshot é a fonte de verdade para o novo disco Hyperdisk do Passo 2.
# ==============================================================================
resource "google_compute_snapshot" "migration_snapshot" {
  name    = local.snapshot_name
  project = local.project_id
  zone    = local.zone

  # Referencia o disco de boot da VM de origem via data source.
  # O Terraform resolve o URI completo automaticamente — sem hardcode de self_links.
  source_disk = data.google_compute_instance.source_vm.boot_disk[0].source

  # Garante que o snapshot seja armazenado na mesma região dos demais recursos,
  # evitando latência de transferência cross-region na criação do disco.
  storage_locations = [local.region]

  description = "Snapshot de migração E2→N4 — origem: ${local.source_instance_name}"

  labels = {
    origem     = local.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
    tipo       = "migracao"
  }

  # PROTEÇÃO DE DADOS: prevent_destroy impede que um 'terraform destroy' acidental
  # remova o snapshot durante o processo de migração, evitando perda do ponto de restauração.
  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# PASSO 2 — Disco Hyperdisk-Balanced para a nova instância N4
#
# DEPENDÊNCIA IMPLÍCITA: o disco aguarda o snapshot estar 100% disponível.
# O Terraform identifica essa dependência pelo uso de
# 'google_compute_snapshot.migration_snapshot.self_link' e garante
# a ordem correta de criação sem necessidade de depends_on explícito.
#
# REQUISITO N4: 'hyperdisk-balanced' é o único tipo de disco compatível
# com instâncias da família N4. Usar pd-standard ou pd-ssd causa falha na criação.
# ==============================================================================
resource "google_compute_disk" "migration_hyperdisk" {
  name    = local.new_disk_name
  project = local.project_id
  zone    = local.zone

  # Tipo obrigatório para N4 — N4 não suporta persistent disk (pd-*) padrão.
  # Hyperdisk-Balanced oferece melhor throughput e IOPS, ideal para cargas N4.
  type = "hyperdisk-balanced"

  # Dependência implícita: o disco SÓ será provisionado após o snapshot estar disponível.
  # O Terraform ordena a criação automaticamente por esta referência.
  snapshot = google_compute_snapshot.migration_snapshot.self_link

  labels = {
    origem     = local.source_instance_name
    destino    = local.new_instance_name
    gerenciado = "terraform"
  }

  # PROTEÇÃO CRÍTICA: previne a destruição do disco com os dados de produção.
  # O disco persiste mesmo que a instância seja recriada ou removida do estado Terraform.
  # Para remover o disco intencionalmente, é necessário primeiro desabilitar este bloco.
  lifecycle {
    prevent_destroy = true
  }
}

# ==============================================================================
# PASSO 2.5 — Para a VM E2 e desvincula o IP externo (via gcloud)
#
# DEPENDÊNCIA EXPLÍCITA: este passo SÓ executa após o Hyperdisk estar pronto.
# Estratégia: o snapshot e o disco são criados com a E2 ainda no ar, maximizando
# a disponibilidade. Só então a E2 é parada e o IP é liberado para a N4.
#
# INÍCIO DO DOWNTIME: a partir daqui a E2 fica offline para acesso externo.
#
# PRÉ-REQUISITO: o gcloud deve estar instalado e autenticado na máquina
# que executa o 'terraform apply', com permissões de Editor na instância E2.
# ==============================================================================
resource "null_resource" "stop_and_detach_e2" {
  # Trigger baseado no ID do disco: este bloco executa UMA ÚNICA VEZ,
  # quando o Hyperdisk é criado. Reaplys subsequentes não re-executam os comandos.
  triggers = {
    hyperdisk_id = google_compute_disk.migration_hyperdisk.id
  }

  provisioner "local-exec" {
    # Usa bash explicitamente para garantir compatibilidade de sintaxe cross-platform
    interpreter = ["bash", "-c"]

    command = <<-EOT
      set -e

      echo ">>> [1/2] Parando a instância E2: ${local.source_instance_name}"
      gcloud compute instances stop ${local.source_instance_name} \
        --zone=${local.zone} \
        --project=${local.project_id} \
        --quiet
      echo ">>> E2 parada com sucesso."

      echo ">>> [2/2] Desvinculando o IP externo '${local.source_access_config_name}' da E2..."
      # '|| true' garante idempotência: não falha se o access config já foi removido
      gcloud compute instances delete-access-config ${local.source_instance_name} \
        --access-config-name="${local.source_access_config_name}" \
        --zone=${local.zone} \
        --project=${local.project_id} \
        --quiet || true
      echo ">>> IP externo desvinculado. Pronto para provisionar a instância N4."
    EOT
  }
}

# ==============================================================================
# PASSO 3 — Nova instância N4 com Hyperdisk e IP estático reutilizado
#
# DEPENDÊNCIA EXPLÍCITA via depends_on: a instância SÓ é criada após o
# null_resource confirmar que a E2 foi parada e o IP está liberado.
# FIM DO DOWNTIME: quando a N4 subir com o mesmo IP, o serviço volta ao ar.
# ==============================================================================
resource "google_compute_instance" "migrated_n4_instance" {
  name         = local.new_instance_name
  machine_type = "n4-highmem-2"
  project      = local.project_id
  zone         = local.zone

  # Dependência explícita: garante que a E2 foi parada e o IP foi liberado
  # antes de tentar criar a N4. Sem isso, o GCP retorna IP_IN_USE_BY_ANOTHER_RESOURCE.
  depends_on = [null_resource.stop_and_detach_e2]

  # Permite que o Terraform pare a VM para aplicar mudanças de configuração
  # sem forçar a recriação completa do recurso — minimiza janelas de manutenção.
  allow_stopping_for_update = true

  # Disco de boot aponta para o novo Hyperdisk criado a partir do snapshot.
  # auto_delete = false: GARANTE que o disco NÃO seja excluído caso a instância
  # seja destruída. Proteção dupla junto com o prevent_destroy do disco.
  boot_disk {
    source      = google_compute_disk.migration_hyperdisk.self_link
    auto_delete = false
  }

  network_interface {
    # Adapte 'network' e 'subnetwork' conforme a topologia de rede do projeto.
    # Exemplo para VPC customizada: network = "projects/PROJECT/global/networks/NOME-VPC"
    network    = "default"
    subnetwork = "default"

    # Reutiliza o IP estático já reservado — sem necessidade de atualizar
    # entradas de DNS, regras de firewall ou configurações de clientes externos.
    access_config {
      nat_ip = data.google_compute_address.existing_static_ip.address
    }

    # OBRIGATÓRIO para família N4: sem GVNIC (Google Virtual NIC), a instância
    # não inicializa corretamente e perde conectividade de rede ao bootar.
    # VirtioNet (nic_type padrão) NÃO é suportado em máquinas N4.
    nic_type = "GVNIC"
  }

  metadata = {
    migrado-de = local.source_instance_name
    gerenciado = "terraform"
  }

  labels = {
    origem     = local.source_instance_name
    familia    = "n4"
    gerenciado = "terraform"
  }

  # A instância PODE ser destruída e recriada pelo Terraform se necessário,
  # pois os dados estão duplamente protegidos:
  #   1. prevent_destroy = true no google_compute_disk acima
  #   2. auto_delete     = false no boot_disk deste recurso
  lifecycle {
    # Ignora mudanças nos metadados após o primeiro apply para evitar
    # recriações desnecessárias causadas por metadados injetados pelo GCP
    # (ex: startup-script-url, ssh-keys injetadas por IAP, etc.)
    ignore_changes = [metadata]
  }
}

# ==============================================================================
# OUTPUTS — Informações úteis exibidas ao final do 'terraform apply'
# ==============================================================================

output "nova_instancia_nome" {
  description = "Nome da nova instância N4 criada pela migração"
  value       = google_compute_instance.migrated_n4_instance.name
}

output "nova_instancia_ip_externo" {
  description = "IP externo estático reutilizado pela nova VM (mesmo IP da VM de origem)"
  value       = data.google_compute_address.existing_static_ip.address
}

output "nova_instancia_ip_interno" {
  description = "IP interno atribuído à nova instância N4 pelo GCP"
  value       = google_compute_instance.migrated_n4_instance.network_interface[0].network_ip
}

output "snapshot_self_link" {
  description = "Self-link do snapshot de migração — guarde para rollback se necessário"
  value       = google_compute_snapshot.migration_snapshot.self_link
}

output "hyperdisk_self_link" {
  description = "Self-link do novo disco Hyperdisk-Balanced provisionado"
  value       = google_compute_disk.migration_hyperdisk.self_link
}
