# Migração Terraform GCP (E2 para N4)

Projeto responsável pela orquestração automatizada da migração de instâncias Google Cloud (E2) para a nova família focada em otimização de custos e performance (N4), preservando os dados vitais e redes de sua infraestrutura.

## 🚀 Sobre o Projeto

Este modelo automatiza integralmente a mudança de famílias de Virtual Machines no GCP. Devido às restrições do Compute Engine, onde discos padrão (`pd-standard`, `pd-ssd`) e opções legadas de rede não são suportadas na nova arquitetura N4, uma "simples alteração de tipo" pelo console não funciona.

O script realiza as seguintes etapas **em ordem exata para garantir redução máxima de downtime**:
1. **Snapshots:** Tira um snapshot do disco de boot da E2 enquanto ela ainda está operando.
2. **Hyperdisk:** Converte automaticamente o snapshot em um `hyperdisk-balanced` (obrigatório para N4).
3. **Downtime e IP:** Deliga a máquina e2, localiza os IPs atrelados, e desamarra/libera o IP Público Estático atrelado.
4. **Provisionamento:** Levanta a nova VM N4 com as configurações ideais calculadas sob demanda, pluga o Hyperdisk, e atrela o IP liberado.
5. **Notificação:** Dispara um relatório de todo o progresso (incluindo duração de cada passo do downtime) via Telegram.

## 🛠️ Tecnologias e Dependências

A orquestração híbrida usa recursos do Terraform pareados a scripts que chamam os binários utilitários em seu terminal. Garanta que:
* **Terraform** >= 1.5.0
* **Google Cloud CLI** (`gcloud`) autênticado como *Compute Instance Admin* (`gcloud auth login`)
* **Curl** (para disparos Webhook / Telegram)

## ⚙️ Como Utilizar

### 1. Configurar as credenciais e variáveis
Copie o template de variáveis ou preencha o arquivo oculto `terraform.tfvars` na raiz do projeto conforme a folha de especificações:

```hcl
project_id                = "sivaadm-1259"
region                    = "us-east1"
zone                      = "us-east1-c"

source_instance_name      = "teste-e2-n4"
existing_static_ip_name   = "teste-e2-n4-static-ip"

# Dimensionamento N4
target_vcpus              = 2
target_memory_gb          = 8

# Telegram Info
telegram_bot_token        = "..."
telegram_chat_id          = "..."
```

> **Atenção:** As definições de acesso da rede interna ou externa (`source_access_config_name`) são identificadas automaticamente caso o campo correspondente obsoleto venha a falhar.

### 2. Executar a Migração

Você possui duas opções autônomas (via PowerShell ou Bash) que garantem as travas de execução, logs amigáveis, limpeza e chamadas locais simultâneas ao Terraform.

**Via Linux/Mac/Git Bash:**
```bash
# Validar planejamento preventivo
./migrate.sh --dry-run

# Aplicar migração final
./migrate.sh
```

**Via Windows PowerShell:**
```powershell
# Validar planejamento preventivo
.\migrate.ps1 -DryRun

# Aplicar migração final
.\migrate.ps1
```

## ⚠️ Ações Pós-Migração
* A antiga VM modelo E2 (agora em uso de um disco órfão) continuará **DESLIGADA**, porém não automaticamente apagada. Esse comportamento evita exclusão acidental. Valide a comunicação e integridade dos serviços dentro da N4 e realize a limpeza do lixo deixado para trás (VM e2 desligada e disco antigo) de forma manual pelo console GCP.
* Políticas e Cronogramas de Backups Autônomos (Resource Policies) estarão *desabilitadas* nativamente no provisionamento do seu Hypedisk de destino. Isso se fez necessário para evitar gatilhos recursivos passados da VM E2. Lembre-se de refazer as devidas rotinas para a VM N4 recém-migrada.
