# ==============================================================================
# normalize_files_for_windows.ps1
# Converte arquivos do projeto para o padrão Windows (CRLF line endings)
# ==============================================================================

$extensions = @("*.sh", "*.tf", "*.tfvars", "*.tfvars.example")

Write-Host "--- Normalizando arquivos para WINDOWS (CRLF) ---" -ForegroundColor Cyan

foreach ($ext in $extensions) {
    $files = Get-ChildItem -Path . -Filter $ext -File
    foreach ($file in $files) {
        if ($file.Length -eq 0) {
            Write-Host "  Pulando arquivo vazio: $($file.Name)" -ForegroundColor Gray
            continue
        }

        Write-Host "Processando: $($file.Name)"
        
        # Lê o conteúdo ignorando as quebras de linha atuais e salva com CRLF
        # O PowerShell faz isso naturalmente ao ler e escrever linhas
        $content = Get-Content -Path $file.FullName
        $content | Set-Content -Path $file.FullName -LineEnding CRLF -Encoding UTF8
        
        Write-Host "  OK: $($file.Name)" -ForegroundColor Green
    }
}

Write-Host "--- Concluído ---" -ForegroundColor Cyan
