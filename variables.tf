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
  description = "Nome exato da VM E2 a ser migrada para N4"
  type        = string
}


variable "network" {
  description = "Nome ou self_link da VPC da nova instância N4. Deixe vazio (\"\") para herdar automaticamente da VM E2 de origem."
  type        = string
  default     = ""
}

variable "subnetwork" {
  description = "Nome ou self_link da subrede da nova instância N4. Deixe vazio (\"\") para herdar automaticamente da VM E2 de origem."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Dimensionamento da VM N4 de Destino
# ------------------------------------------------------------------------------

variable "target_vcpus" {
  description = "Número de vCPUs da nova instância N4. O script tenta encontrar um tipo predefinido N4 equivalente; se não houver, usa n4-custom automaticamente."
  type        = number
}

variable "target_memory_gb" {
  description = "Quantidade de memória RAM da nova instância N4, em GB inteiro. Combinado com target_vcpus para resolver o tipo de máquina."
  type        = number
}

variable "machine_type_override" {
  description = "Tipo N4 explícito. Se preenchido, ignora a resolução automática por vCPU/RAM e usa este valor diretamente (ex: n4-standard-8, n4-highmem-4)."
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
