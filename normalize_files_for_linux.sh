#!/usr/bin/env bash
# ==============================================================================
# normalize_files_for_linux.sh
# Converte arquivos do projeto para o padrão Linux (LF line endings)
# ==============================================================================

# Extensões para normalizar
EXTENSIONS=("*.sh" "*.tf" "*.tfvars" "*.tfvars.example")

echo "--- Normalizando arquivos para LINUX (LF) ---"

for ext in "${EXTENSIONS[@]}"; do
  # Usa find para lidar com arquivos que podem não existir para uma extensão
  find . -maxdepth 1 -name "$ext" -type f | while read -r file; do
    # Verifica se o arquivo é binário ou vazio
    if [ ! -s "$file" ]; then
      continue
    fi
    
    echo "Processando: $file"
    # Remove \r (CR) de forma segura
    # O comando extrai o conteúdo, remove \r e salva de volta
    tr -d '\r' < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    echo "  OK: $file"
  done
done

echo "--- Concluído ---"
chmod +x normalize_files_for_linux.sh 2>/dev/null || true
