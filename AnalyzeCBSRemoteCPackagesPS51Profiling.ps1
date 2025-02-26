# Путь к файлу CBS.log
$cbsLogPath = "$env:SystemRoot\Logs\CBS\CBS.log"

# Проверяем существование файла
if (-Not (Test-Path $cbsLogPath)) {
    Write-Host "Файл CBS.log не найден!"
    exit
}

# Чтение файла CBS.log
$cbsLogContent = Get-Content -Path $cbsLogPath

# Поиск строк, указывающих на отсутствующие пакеты
$missingPackages = $cbsLogContent | Select-String -Pattern "MissingPackage_\d+_for_kB\d+" -AllMatches

# Вывод результатов
if ($missingPackages) {
    Write-Host "Найдены отсутствующие пакеты:"
    $missingPackages.Matches | ForEach-Object {
        Write-Host $_.Value
    }
} else {
    Write-Host "Отсутствующие пакеты не найдены."
}

# Поиск и вывод общего количества обнаруженных повреждений
$corruptionSummary = $cbsLogContent | Select-String -Pattern "Total Detected Corruption:\d+"
if ($corruptionSummary) {
    Write-Host "`nОбщее количество обнаруженных повреждений: $($corruptionSummary.Matches[0].Value)"
}

# Поиск и вывод результата операции
$operationResult = $cbsLogContent | Select-String -Pattern "Operation result: 0x\w+"
if ($operationResult) {
    Write-Host "Результат операции: $($operationResult.Matches[0].Value)"
}
