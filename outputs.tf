# ==============================================================================
# outputs.tf
# Valores exibidos no terminal ao final do 'terraform apply'
# ==============================================================================

output "tipo_maquina_n4" {
  description = "Tipo de máquina N4 resolvido e aplicado na nova instância"
  value       = local.resolved_machine_type
}

output "tipo_maquina_origem" {
  description = "Como o tipo foi determinado: predefinido (match exato na tabela), custom (n4-custom) ou override-manual"
  value       = local.machine_type_source
}

output "nova_instancia_nome" {
  description = "Nome da nova instância N4 criada"
  value       = google_compute_instance.migrated_n4_instance.name
}

output "nova_instancia_ip_externo" {
  description = "IP externo estático reutilizado — mesmo endereço da VM E2 de origem"
  value       = data.google_compute_instance.source_vm.network_interface[0].access_config[0].nat_ip
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
  description = "Self-link do disco Hyperdisk-Balanced provisionado"
  value       = google_compute_disk.migration_hyperdisk.self_link
}

output "discos_secundarios_migrados" {
  description = "Lista dos discos secundários migrados (nome original → nome Hyperdisk)"
  value = local.secondary_disk_count > 0 ? [
    for i in range(local.secondary_disk_count) : {
      origem    = local.secondary_disk_names[i]
      hyperdisk = google_compute_disk.secondary_hyperdisk[i].name
    }
  ] : []
}
