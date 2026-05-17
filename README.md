# Migração de VMs GCP — Terraform

Automação Terraform para migrar VMs GCP entre famílias de máquina (E2, N2, N4, C3, C3D, M1, M3, T2A, T2D, etc.), com troca opcional de tipo de disco, reaproveitamento de IP estático, notificações via Telegram e downtime mínimo.

---

## Como funciona

O script executa as etapas nesta ordem para minimizar o downtime:

1. **Snapshot** do disco de boot da VM de origem (enquanto ela ainda está rodando)
2. **Novo disco** criado a partir do snapshot — apenas se o tipo de disco mudar (ex: `pd-balanced` → `hyperdisk-balanced`). Se o tipo for o mesmo, o disco é reutilizado diretamente.
3. **Downtime inicia**: VM de origem é parada e o IP externo é desvinculado
4. **Nova VM** criada com o modelo escolhido, mesmo IP e dados preservados
5. **Downtime encerra**: nova VM sobe com o mesmo IP, serviço volta ao ar
6. **Notificações Telegram** a cada etapa, incluindo duração total

---

## Pré-requisitos

| Ferramenta | Versão mínima | Necessário para |
|------------|--------------|-----------------|
| Terraform | >= 1.5.0 | Orquestração dos recursos GCP |
| Google Cloud CLI (`gcloud`) | qualquer recente | Autenticação e operações GCP |
| curl | — | Notificações Telegram |
| Git for Windows | — | **Apenas Windows**: bash para os provisioners Terraform |

---

## Passo a passo completo

### Linux

#### 1. Instalar o Google Cloud CLI

```bash
# Debian / Ubuntu
sudo apt-get install -y google-cloud-cli

# ou via script universal (qualquer distro)
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
```

Verifique:
```bash
gcloud --version
```

#### 2. Instalar o Terraform

```bash
# Ubuntu / Debian via apt
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# Verifique
terraform --version
```

---

### Windows

#### 1. Instalar o Google Cloud CLI

Baixe e execute o instalador oficial:

```powershell
# Via winget (Windows 11 / Windows 10 com App Installer)
winget install Google.CloudSDK

# ou baixe o instalador .exe em:
# https://cloud.google.com/sdk/docs/install#windows
```

Após a instalação, abra um novo terminal PowerShell e verifique:
```powershell
gcloud --version
```

#### 2. Instalar o Terraform

```powershell
# Via winget
winget install Hashicorp.Terraform

# ou via Chocolatey
choco install terraform

# ou via Scoop
scoop install terraform
```

Verifique:
```powershell
terraform --version
```

#### 3. Instalar o Git for Windows (obrigatório)

Os provisioners `local-exec` do Terraform executam comandos bash. Sem o Git for Windows o `terraform apply` vai falhar nos passos de notificação e operações gcloud.

```powershell
# Via winget
winget install Git.Git

# ou baixe em https://git-scm.com/download/win
```

Após instalar, feche e reabra o terminal. Verifique:
```powershell
bash --version
```

> Caso o `bash` não seja encontrado mesmo após instalar o Git, adicione `C:\Program Files\Git\bin` ao `PATH` do sistema em **Configurações → Sistema → Variáveis de Ambiente**.

#### 4. Permitir execução de scripts PowerShell

Por padrão o Windows bloqueia scripts `.ps1`. Libere para o usuário atual:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

### Autenticar na conta GCP (Linux e Windows)

Os comandos são iguais nos dois sistemas:

```bash
# Login interativo — abre o browser para autorizar
gcloud auth login

# Configura o projeto padrão (substitua pelo seu project_id)
gcloud config set project SEU-PROJECT-ID

# Credenciais de aplicação (usadas pelo Terraform)
gcloud auth application-default login
```

Confirme a autenticação:
```bash
gcloud auth list
gcloud config get-value project
```

---

### Clonar o repositório

```bash
git clone <url-do-repositorio>
cd gcp_changemodel
```

---

## Normalização de Quebras de Linha (Cross-platform)

Se você alterna entre ambientes **Windows** e **Linux/WSL**, as quebras de linha dos scripts podem ficar corrompidas (ERRO: `\r: command not found`). Para corrigir isso, utilize os scripts de normalização incluídos:

### No Windows (PowerShell)
Se você acabou de clonar ou puxar mudanças e vai rodar os scripts no Windows:
```powershell
.\normalize_files_for_windows.ps1
```

### No Linux / WSL / Bash
Se você vai executar os scripts ou o Terraform em ambiente Linux:
```bash
chmod +x normalize_files_for_linux.sh
./normalize_files_for_linux.sh
```

> **Automação:** O repositório inclui um arquivo `.gitattributes` que tenta gerenciar isso automaticamente durante o `git commit/checkout`. No entanto, os scripts acima são úteis para correções manuais rápidas.

---

---

### 5. Preencher as variáveis iniciais do tfvars

Copie o template e preencha apenas as três variáveis que o script de consulta precisa para funcionar:

```bash
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars   # ou vim, code, etc.
```

```hcl
project_id           = "meu-projeto-prod"
region               = "southamerica-east1"
zone                 = "southamerica-east1-b"
source_instance_name = "minha-vm"
```

---

### 6. Consultar informações da VM de origem

Com as variáveis iniciais preenchidas, execute o script de consulta para ver tudo que a VM possui antes de definir o destino:

**Linux** — dê permissão e execute:
```bash
chmod +x check_project.sh migrate.sh
./check_project.sh
```

**Windows (PowerShell):**
```powershell
.\check_project.ps1
```

O script exibe um relatório completo lendo direto do `terraform.tfvars`:

| Seção | O que mostra |
|-------|-------------|
| Instância | Tipo de máquina, família, vCPUs reais, RAM real, status |
| Disco de boot | Nome, tipo (`pd-balanced`, `hyperdisk-balanced`, etc.), tamanho |
| Discos secundários | Lista com tipo e tamanho de cada disco adicional |
| Rede | VPC, subrede, IP interno, IP externo, se o IP é estático ou efêmero |
| Network tags | Lista de tags (copiadas automaticamente para a nova VM) |
| Prévia da migração | Se `target_machine_family` já estiver preenchido, mostra o que acontecerá com disco e NIC |

Use as informações exibidas para decidir a família e o dimensionamento de destino.

---

### 7. Preencher as variáveis de destino no tfvars

Com o relatório em mãos, preencha o restante do `terraform.tfvars`:

```hcl
# ── Nome da VM de destino (opcional) ──────────────────────────────────────────
# Deixe vazio para gerar automaticamente: "<source_instance_name>-<target_machine_family>"
# Ex: source "marsala" + família "t2d" → "marsala-t2d"
final_instance_name = ""   # ex: "marsala-novo" ou "" para nome automático

# ── Rede (deixe vazio para herdar da VM de origem) ────────────────────────────
network    = ""   # ex: "default" ou self_link completo
subnetwork = ""   # ex: "default" ou self_link completo

# ── Modelo de Destino ─────────────────────────────────────────────────────────
# Famílias disponíveis: n4, n2, n2d, e2, c2, c2d, c3, c3d, m1, m3, t2a, t2d
target_machine_family = "n4"

# vCPUs e RAM desejados — o script resolve o tipo automaticamente.
# Se bater com um tipo predefinido, usa ele. Caso contrário, gera custom.
# Exemplos N4:  2 vCPU +  8 GB → n4-standard-2  |  2 vCPU + 16 GB → n4-highmem-2
# Exemplos N2:  4 vCPU + 16 GB → n2-standard-4  |  4 vCPU + 32 GB → n2-highmem-4
target_vcpus     = 2
target_memory_gb = 8

# Opcional: define o tipo diretamente, ignorando a resolução por vcpus/memory acima
# machine_type_override = "n4-standard-4"

# ── Disco de Destino ──────────────────────────────────────────────────────────
# Deixe vazio para usar o default da família:
#   N4, C3, C3D, M3  →  hyperdisk-balanced
#   Demais famílias   →  pd-balanced
#
# Se o tipo escolhido for IGUAL ao disco atual, ele é reutilizado (sem criar novo).
# O snapshot é sempre criado para segurança.
#
# Opções: pd-standard | pd-balanced | pd-ssd | pd-extreme
#         hyperdisk-balanced | hyperdisk-extreme | hyperdisk-throughput
target_disk_type = ""

# ── Telegram ──────────────────────────────────────────────────────────────────
# Como obter o token: fale com @BotFather no Telegram → /newbot
telegram_bot_token = "TOKEN_AQUI"

# Como obter o chat_id: adicione @userinfobot a um grupo ou envie /start para ele
telegram_chat_id = "ID_AQUI"
```

> **Segurança:** O `terraform.tfvars` contém o token do Telegram. Confirme que ele está no `.gitignore` antes de qualquer commit.

---

### 8. Executar em modo dry-run (validação sem aplicar)

Recomendado antes da migração real para revisar o plano sem fazer nenhuma mudança:

**Linux:**
```bash
./migrate.sh --dry-run
```

**Windows (PowerShell):**
```powershell
.\migrate.ps1 -DryRun
```

O script vai:
- Verificar os pré-requisitos
- Consultar a VM de origem via API GCP e exibir as specs reais (vCPUs, RAM, disco)
- Mostrar um resumo comparativo (origem vs. destino) com alertas de incompatibilidade
- Executar `terraform plan` e exibir o resultado detalhado

---

### 9. Executar a migração

**Linux:**
```bash
./migrate.sh
```

**Windows (PowerShell):**
```powershell
.\migrate.ps1
```

O fluxo completo é:

1. Verifica pré-requisitos (terraform, gcloud, curl, bash, tfvars)
2. Consulta a VM de origem via API GCP (vCPUs, RAM, disco, status)
3. Exibe resumo comparativo origem vs. destino com alertas de incompatibilidade
4. Detecta execuções anteriores incompletas e oferece retomada ou reinício
5. Executa `terraform init` e `terraform plan`
6. **Exibe o resumo completo novamente** para conferência final antes de aplicar
7. Aguarda confirmação digitando `sim`
8. Executa `terraform apply`
9. Exibe os outputs (IP, nome da nova VM, disco, duração)

**Flags disponíveis:**

| Linux | Windows | Descrição |
|-------|---------|-----------|
| `--dry-run` | `-DryRun` | Apenas `terraform plan`, sem aplicar |
| `-y` / `--yes` | `-AutoApprove` | Pula a confirmação interativa (CI/CD) |
| `-h` / `--help` | `-Help` | Exibe a ajuda |

---

### 10. Acompanhar pelo Telegram

Durante a migração você receberá 4 notificações:

| # | Quando |
|---|--------|
| 1 | Migração iniciada (origem, destino, ação no disco) |
| 2 | Snapshot criado |
| 3 | Novo disco criado (apenas se o tipo mudou) |
| 4 | Migração concluída (status da VM, IP, NIC, duração total) |

Em caso de erro no `terraform apply`, uma notificação de falha é enviada automaticamente com o código de saída.

---

## Famílias e tipos de disco suportados

| Família | Disco default | GVNIC |
|---------|--------------|-------|
| `n4` | `hyperdisk-balanced` | Obrigatório |
| `c3`, `c3d`, `m3` | `hyperdisk-balanced` | Obrigatório |
| `t2a` (ARM) | `pd-balanced` | Obrigatório |
| `n2`, `n2d`, `c2`, `c2d`, `t2d` | `pd-balanced` | Opcional |
| `e2`, `m1` | `pd-balanced` | Não suportado |

> **T2A**: arquitetura ARM — o SO da VM de origem precisa ser compatível (ex: Ubuntu 22.04 ARM).

---

## Redimensionamento de disco (upgrade / downgrade)

Por padrão a migração mantém o **mesmo tamanho** do disco de origem. Para alterar o tamanho do disco de boot (aumentar ou reduzir), use as variáveis em `terraform.tfvars`:

```hcl
change_disk_size = true   # ativa o redimensionamento
target_disk_size = 100    # novo tamanho em GB (inteiro)
```

Quando `change_disk_size = true`, o disco **sempre será recriado a partir do snapshot** — mesmo que o tipo escolhido seja igual ao da origem.

### Upgrade (aumentar disco)

Seguro e simples. Após a migração, expanda a partição/filesystem dentro da nova VM:

```bash
# Linux (ext4) — exemplo para /dev/sda1
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
```

### Downgrade do disco de BOOT — ⚠️ ATENÇÃO

**Por que o downgrade é diferente do upgrade?** Aumentar um disco é seguro: o GCP só estende o espaço e o `resize2fs` expande o filesystem por cima. **Reduzir** exige reduzir o filesystem **antes** do snapshot, senão o disco novo terá dados truncados e a VM não bootará.

E como o **disco de boot está montado como `/`** enquanto a VM roda, não há como reduzir o filesystem dentro da própria VM. A técnica correta é:

1. Parar a VM
2. Desanexar o disco de boot
3. Anexar esse disco numa **VM temporária** como disco secundário
4. Reduzir o filesystem e a partição na VM temporária (onde o disco está desmontado)
5. Devolver o disco para a VM de origem como `--boot`
6. Apagar a VM temporária
7. Rodar a migração normal (`./migrate.sh`), que cria o disco novo já com o tamanho menor a partir do snapshot

> **Regra de ouro:** `tamanho_do_filesystem_reduzido ≤ target_disk_size`

Este repositório fornece um **script que automatiza todos esses passos** — incluindo a VM temporária, o resize remoto e a limpeza.

##### Integração com `migrate.sh` / `migrate.ps1`

O `migrate.sh` (e `.ps1`) detecta **automaticamente** quando um downgrade é necessário:

1. Lê `change_disk_size = true` e `target_disk_size` do `terraform.tfvars`
2. Compara com o tamanho real do disco de boot no GCP
3. Se `target_disk_size < tamanho_atual`, verifica via SSH se o filesystem já foi reduzido
4. Se **não foi reduzido**: pergunta se você quer rodar o downgrade automático agora. Se responder `sim`, ele chama `./downgrade_boot_disk.sh` automaticamente antes de prosseguir
5. Se **já foi reduzido**: segue direto para a migração

Ou seja, você só precisa de **um comando**:

```bash
# Edite terraform.tfvars: change_disk_size = true, target_disk_size = 100
# Depois execute apenas:
./migrate.sh
```

O script pergunta se deve reduzir o disco → você confirma → ele reduz → depois migra. Tudo em sequência.

---

#### Método 1: AUTOMATIZADO (recomendado) — `downgrade_boot_disk.sh` / `.ps1`

**Escopo suportado pela automação:**

| Item | Suporte |
|------|---------|
| SO da VM | Linux (Debian/Ubuntu/CentOS/etc.) |
| Filesystem | **ext4 apenas** |
| Partição raiz | **Partição única em `/dev/sda1`** |
| LVM / criptografia LUKS | ❌ não suportado |
| xfs / btrfs / zfs | ❌ não suportado (xfs **não pode** reduzir; use método manual) |
| Disco de boot | ✅ |
| Disco de dados secundário | ❌ (downgrade de discos secundários ainda é manual) |

Se sua VM cai fora do escopo, o script aborta com mensagem clara e você deve usar o **Método 2 (manual)** abaixo.

##### Pré-requisito: configurar `terraform.tfvars`

```hcl
change_disk_size = true     # OBRIGATÓRIO — sem isso o migrate.sh manteria o tamanho original
target_disk_size = 100      # novo tamanho em GB
```

##### Execução

**Linux / WSL:**
```bash
chmod +x downgrade_boot_disk.sh
./downgrade_boot_disk.sh --dry-run    # confere o plano sem alterar nada
./downgrade_boot_disk.sh              # executa interativamente (confirmação 'sim')
```

**Windows (PowerShell):**
```powershell
.\downgrade_boot_disk.ps1 -DryRun
.\downgrade_boot_disk.ps1
```

Flags adicionais: `-y` / `--yes` (Linux) ou `-AutoApprove` (Windows) para pular confirmação.

##### O que o script faz, passo a passo

Usando o cenário deste repo (`marsala` em Linux/ext4, disco `pd-balanced` de 500 GB → 100 GB):

| # | Ação | Comando equivalente |
|---|------|---------------------|
| 1 | Lê `terraform.tfvars`, valida `change_disk_size=true` e `target_disk_size > 0` | — |
| 2 | Conecta SSH na `marsala`, verifica que é ext4 + sda1, e que **espaço usado < (target − 10) GB** | `df -B1G /` + `blkid` |
| 3 | Cria snapshot de segurança `marsala-pre-downgrade-YYYYMMDD-HHMMSS` (rollback total) | `gcloud compute disks snapshot` |
| 4 | Para a VM `marsala` | `gcloud compute instances stop marsala` |
| 5 | Cria VM temporária `marsala-resize-temp` (e2-small, Debian 12, 10 GB) | `gcloud compute instances create` |
| 6 | Desanexa o disco de boot da `marsala` e anexa na temporária com `device-name=resize-target` | `detach-disk` + `attach-disk` |
| 7 | Via SSH na temporária: detecta disco em `/dev/disk/by-id/google-resize-target`, valida ext4+1 partição, roda `e2fsck -fy` | `gcloud compute ssh` |
| 8 | Reduz filesystem para **`(target − 10)` GB** (ex: 90 GB) com `resize2fs` | `resize2fs /dev/sdX1 90G` |
| 9 | Reduz partição para **`(target − 5)` GB** (ex: 95 GB) com `parted resizepart` | `parted ... resizepart 1 95GB Yes` |
| 10 | `e2fsck -fy` final para confirmar consistência | — |
| 11 | Desanexa o disco da temporária | `detach-disk` |
| 12 | Reanexa o disco na `marsala` como `--boot` | `attach-disk --boot` |
| 13 | Apaga a VM temporária | `instances delete` |
| 14 | Imprime instruções para rodar `./migrate.sh` em seguida | — |

> **Por que 90/95 GB e não 100 GB?** Margens de segurança:
> - **Filesystem em `(target − 10)` GB** garante que ele caiba folgadamente no disco final de 100 GB e ainda deixa espaço para o `resize2fs` final expandir
> - **Partição em `(target − 5)` GB** fica entre o FS (90 GB) e o disco (100 GB), evitando que blocos finais da tabela de partições caiam fora do novo disco

##### Notificações Telegram

Se `telegram_bot_token` e `telegram_chat_id` estiverem preenchidos em `terraform.tfvars`, o script envia **10 mensagens** durante a execução: início, conclusão de cada um dos 8 passos, e conclusão final com duração total. Em caso de falha em qualquer ponto, uma mensagem de erro é enviada automaticamente com instruções para rollback via snapshot.

Se as variáveis não estiverem preenchidas, o script roda silenciosamente sem Telegram (sem falhar).

##### Após o script terminar

```bash
# (Opcional) Validar que a marsala sobe normalmente antes da migração
gcloud compute instances start marsala --zone=us-east1-c --project=romena
gcloud compute ssh marsala --zone=us-east1-c --project=romena
df -h /        # deve mostrar /dev/sda1 com ~90 GB
gcloud compute instances stop marsala --zone=us-east1-c --project=romena

# Rodar a migração
./migrate.sh
```

A migração criará a nova VM (`marsala-t2d`) com disco de **100 GB** contendo o filesystem de 90 GB.

##### Pós-migração: expandir o filesystem para usar todo o disco

```bash
gcloud compute ssh marsala-t2d --zone=us-east1-c --project=romena
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
df -h /        # agora ~100 GB
```

##### Limpeza final

1. Apague a VM antiga `marsala` no Console GCP
2. Apague o disco original `marsala` de 500 GB
3. Apague o snapshot `marsala-pre-downgrade-YYYYMMDD-HHMMSS` (somente após semanas de operação estável)

##### O que fazer se o script falhar no meio

O snapshot de segurança criado no passo 3 permite recuperação completa. O próprio script imprime os 3 comandos `gcloud` para devolver o disco à `marsala` e apagar a VM temporária. Em último caso:

```bash
# Recria o disco a partir do snapshot
gcloud compute disks create marsala-restored \
  --source-snapshot=marsala-pre-downgrade-YYYYMMDD-HHMMSS \
  --zone=us-east1-c --project=romena
```

---

#### Método 2: MANUAL (para cenários fora do escopo: xfs, LVM, multi-partição, etc.)

Use exatamente o mesmo fluxo do script, mas executando cada comando à mão. A diferença é que **você** identifica o filesystem, ajusta partições, lida com LVM/cripto, etc.

<details>
<summary><b>Passos manuais (clique para expandir)</b></summary>

##### 1. Verificar uso real e validar margem

```bash
gcloud compute ssh marsala --zone=us-east1-c --project=romena
df -h /
lsblk -f
```

Espaço usado deve estar **bem abaixo** do `target_disk_size`. Limpe `/var/log`, caches, snapshots APT, etc. se necessário.

##### 2. Snapshot manual de segurança

```bash
gcloud compute disks snapshot marsala \
  --zone=us-east1-c --project=romena \
  --snapshot-names=marsala-pre-downgrade-$(date +%Y%m%d) \
  --storage-location=us-east1
```

##### 3. Parar a VM

```bash
gcloud compute instances stop marsala --zone=us-east1-c --project=romena
```

##### 4. Criar VM temporária

```bash
gcloud compute instances create vm-resize-temp \
  --zone=us-east1-c --project=romena \
  --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=10GB
```

##### 5. Mover o disco para a temporária

```bash
gcloud compute instances detach-disk marsala \
  --disk=marsala --zone=us-east1-c --project=romena

gcloud compute instances attach-disk vm-resize-temp \
  --disk=marsala --device-name=resize-target \
  --zone=us-east1-c --project=romena
```

##### 6. Reduzir filesystem e partição (na temporária)

```bash
gcloud compute ssh vm-resize-temp --zone=us-east1-c --project=romena
```

Dentro da VM temporária — **identifique o disco/partição conforme seu cenário**:

```bash
# Disco anexado via device-name aparece como /dev/disk/by-id/google-resize-target
DISK=$(readlink -f /dev/disk/by-id/google-resize-target)   # ex: /dev/sdb
PART="${DISK}1"

sudo umount "$PART" 2>/dev/null || true

# Para ext4:
sudo e2fsck -fy "$PART"
sudo resize2fs "$PART" 90G

# Para xfs: NÃO É POSSÍVEL REDUZIR. Backup + recriar.
# Para LVM: lvreduce -L 90G /dev/vgX/lvY  (após reduzir o FS interno)

# Reduzir a partição (parted)
sudo parted "$DISK" ---pretend-input-tty <<EOF
resizepart 1
95GB
Yes
EOF

sudo parted "$DISK" print
sudo e2fsck -fy "$PART"
```

##### 7. Devolver o disco e apagar a temporária

```bash
gcloud compute instances detach-disk vm-resize-temp \
  --disk=marsala --zone=us-east1-c --project=romena

gcloud compute instances attach-disk marsala \
  --disk=marsala --boot \
  --zone=us-east1-c --project=romena

gcloud compute instances delete vm-resize-temp \
  --zone=us-east1-c --project=romena --quiet
```

##### 8. (Opcional) Validar boot da `marsala`

```bash
gcloud compute instances start marsala --zone=us-east1-c --project=romena
gcloud compute ssh marsala --zone=us-east1-c --project=romena
df -h /
systemctl --failed
gcloud compute instances stop marsala --zone=us-east1-c --project=romena
```

##### 9. Configurar `terraform.tfvars` e migrar

```hcl
change_disk_size = true
target_disk_size = 100
```

```bash
./migrate.sh
```

##### 10. Expandir o FS na nova VM

```bash
gcloud compute ssh marsala-t2d --zone=us-east1-c --project=romena
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
```

</details>

---

### Limites mínimos por tipo de disco

| Tipo | Tamanho mínimo |
|------|----------------|
| `pd-standard`, `pd-balanced`, `pd-ssd`, `hyperdisk-balanced` | 10 GB |
| `pd-extreme`, `hyperdisk-extreme` | 64 GB |
| `hyperdisk-throughput` | 2 TB |

---

## Ações pós-migração

Após confirmar que a nova VM está funcionando corretamente:

1. **Valide** o acesso SSH, serviços e aplicações na nova VM
2. **Exclua a VM de origem** pelo Console GCP (ela fica desligada, não é removida automaticamente)
3. **Se o disco foi reutilizado**: nenhum disco órfão para limpar
4. **Se um novo disco foi criado**: após validação, exclua o disco original pelo Console GCP
5. **Reconfigure políticas de backup** (Resource Policies) na nova VM, pois não são copiadas automaticamente

---

## Recuperação de falhas

Se o script falhar no meio da execução, execute-o novamente. Ele detectará automaticamente os recursos já criados no GCP e oferecerá duas opções:

- **Retomar**: importa os recursos existentes para o estado Terraform e continua do ponto onde parou
- **Reiniciar do zero**: remove os recursos órfãos e começa a migração novamente

> A VM de origem pode ter sido parada durante a falha. Verifique o status no Console GCP antes de retomar.
