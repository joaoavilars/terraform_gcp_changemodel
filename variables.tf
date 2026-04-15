# ==============================================================================
# variables.tf
# Declaração de todas as variáveis da migração.
# Os valores são definidos em terraform.tfvars — edite apenas aquele arquivo.
# ==============================================================================

# ------------------------------------------------------------------------------
# Identidade do Projeto
# ------------------------------------------------------------------------------

variable "project_id" {
  description = "ID do projeto GCP (não o nome exibido no console)"
  type        = string
}

variable "region" {
  description = "Região GCP onde os recursos serão criados (ex: us-central1, southamerica-east1)"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona GCP da instância — deve pertencer à region acima (ex: us-central1-a)"
  type        = string
  default     = "us-central1-a"
}

# ------------------------------------------------------------------------------
# VM de Origem
# ------------------------------------------------------------------------------

variable "source_instance_name" {
  description = "Nome exato da VM de origem a ser migrada"
  type        = string
}


variable "network" {
  description = "Nome ou self_link da VPC da nova instância. Deixe vazio (\"\") para herdar automaticamente da VM de origem."
  type        = string
  default     = ""
}

variable "subnetwork" {
  description = "Nome ou self_link da subrede da nova instância. Deixe vazio (\"\") para herdar automaticamente da VM de origem."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Família e Dimensionamento da VM de Destino
# ------------------------------------------------------------------------------

variable "target_machine_family" {
  description = "Família de máquina da VM de destino (n4, n2, n2d, e2, c2, c3, c3d, m1, m3, t2a, t2d)"
  type        = string

  validation {
    condition     = contains(["n4", "n2", "n2d", "e2", "c2", "c2d", "c3", "c3d", "m1", "m3", "t2a", "t2d"], var.target_machine_family)
    error_message = "Família de máquina inválida. Use uma das opções: n4, n2, n2d, e2, c2, c2d, c3, c3d, m1, m3, t2a, t2d."
  }
}

variable "target_vcpus" {
  description = "Número de vCPUs da nova instância. O script tenta encontrar um tipo predefinido equivalente; se não houver, usa custom automaticamente."
  type        = number
}

variable "target_memory_gb" {
  description = "Quantidade de memória RAM da nova instância, em GB inteiro. Combinado com target_vcpus para resolver o tipo de máquina."
  type        = number
}

variable "machine_type_override" {
  description = "Tipo de máquina explícito. Se preenchido, ignora a resolução automática por vCPU/RAM e usa este valor diretamente (ex: n4-standard-8, n2-highmem-4)."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Tipo de Disco de Destino
# ------------------------------------------------------------------------------

variable "target_disk_type" {
  description = "Tipo de disco para a VM de destino (ex: pd-balanced, pd-ssd, hyperdisk-balanced). Deixe vazio para usar o default da família (hyperdisk-balanced para n4/c3/c3d, pd-balanced para demais)."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Telegram — Alertas de Migração
# ------------------------------------------------------------------------------

variable "telegram_bot_token" {
  description = "Token de autenticação do Bot do Telegram (obtenha com o @BotFather no Telegram)"
  type        = string
  sensitive   = true
}

variable "telegram_chat_id" {
  description = "ID do chat ou canal do Telegram que receberá os alertas. Use @userinfobot para descobrir o seu."
  type        = string
}
