# ==============================================================================
# providers.tf
# Configuração do Terraform e registro dos provedores utilizados na migração
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    # Provider null: necessário para os null_resources de orquestração e notificações Telegram
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Herda project, region e zone das variáveis — sem duplicação de configuração
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
