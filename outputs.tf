# ==============================================================================
# outputs.tf
# Valores exibidos no terminal ao final do 'terraform apply'
# ==============================================================================

output "tipo_maquina_destino" {
  description = "Tipo de máquina resolvido e aplicado na nova instância"
  value       = local.resolved_machine_type
}

output "familia_destino" {
  description = "Família de máquina da instância de destino"
  value       = var.target_machine_family
}

output "tipo_maquina_origem" {
  description = "Como o tipo foi determinado: predefinido (match exato na tabela), custom ou override-manual"
  value       = local.machine_type_source
}

output "nova_instancia_nome" {
  description = "Nome da nova instância criada"
  value       = google_compute_instance.migrated_instance.name
}

output "nova_instancia_ip_externo" {
  description = "IP externo da nova instância (efêmero ou reutilizado da origem)"
  value       = try(google_compute_instance.migrated_instance.network_interface[0].access_config[0].nat_ip, null)
}

output "nova_instancia_ip_interno" {
  description = "IP interno atribuído à nova instância pelo GCP"
  value       = google_compute_instance.migrated_instance.network_interface[0].network_ip
}

output "snapshot_self_link" {
  description = "Self-link do snapshot de migração — guarde para rollback se necessário"
  value       = google_compute_snapshot.migration_snapshot.self_link
}

output "disco_boot_self_link" {
  description = "Self-link do disco de boot provisionado (vazio se o disco foi reutilizado)"
  value       = local.create_new_disk ? google_compute_disk.migration_boot_disk[0].self_link : data.google_compute_disk.source_boot_disk.self_link
}

output "tipo_disco_destino" {
  description = "Tipo de disco usado na instância de destino"
  value       = local.resolved_disk_type
}

output "disco_reutilizado" {
  description = "Indica se o disco de boot existente foi reutilizado (true) ou se um novo foi criado a partir de snapshot (false)"
  value       = !local.create_new_disk
}

output "discos_secundarios_migrados" {
  description = "Lista dos discos secundários migrados (nome original → nome novo)"
  value = local.secondary_disk_count > 0 ? [
    for i in range(local.secondary_disk_count) : {
      origem = local.secondary_disk_names[i]
      novo   = google_compute_disk.secondary_disk[i].name
    }
  ] : []
}
