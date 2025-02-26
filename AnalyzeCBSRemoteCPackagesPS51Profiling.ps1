# Путь к CBS.log
$logPath = "C:\Windows\Logs\CBS\CBS.log"

# Проверяем существование файла
if (Test-Path $logPath) {
    Write-Host "Анализ CBS.log начат..."

    # Читаем файл и фильтруем строки с ошибками
    $errorLines = Get-Content $logPath | Where-Object {
        $_ -match "Error\s+CBS" -and 
        ($_ -match "missing" -or $_ -match "cannot find" -or $_ -match "0x80070002" -or $_ -match "Failed to resolve")
    }

    # Извлекаем названия компонентов
    $missingComponents = foreach ($line in $errorLines) {
        if ($line -match "'([^']+)'") {
            $matches[1]  # Извлекаем имя компонента в кавычках
        } elseif ($line -match "file\s+([^ ]+)") {
            $matches[1]  # Извлекаем имя файла после "file"
        }
    }

    # Убираем дубликаты и выводим результат
    $uniqueMissing = $missingComponents | Sort-Object | Get-Unique

    if ($uniqueMissing.Count -gt 0) {
        Write-Host "Найдены отсутствующие компоненты:"
        $uniqueMissing | ForEach-Object {
            Write-Host $_
        }
        # Опционально: сохранить в файл
        # $uniqueMissing | Out-File "missing_components.txt"
    } else {
        Write-Host "Отсутствующие компоненты не найдены."
    }
} else {
    Write-Host "Файл CBS.log не найден по пути: $logPath"
}
