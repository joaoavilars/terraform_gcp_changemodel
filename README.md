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
