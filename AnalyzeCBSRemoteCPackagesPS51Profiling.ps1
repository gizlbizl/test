# Параметры скрипта
param (
    [string]$CBSLogPath = "$env:SystemRoot\Logs\CBS\CBS.log",  # Путь к CBS.log
    [string]$LogDir = "C:\Temp",                               # Каталог для логов
    [string]$Encoding = "UTF8"                                 # Кодировка файла (UTF8, Unicode, Default)
)

# Проверка прав администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен с правами администратора. Запустите PowerShell от имени администратора."
    exit 1
}

# Инициализация логов
$logBaseDir = Join-Path $LogDir "CBSAnalysisLogs"
try {
    if (-not (Test-Path $logBaseDir)) {
        New-Item -Path $logBaseDir -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Error "Не удалось создать директорию для логов '$logBaseDir'. Ошибка: $($_.Exception.Message)"
    exit 1
}
$logFile = Join-Path $logBaseDir "CBSAnalysis_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
try {
    New-Item -Path $logFile -ItemType File -Force | Out-Null
} catch {
    Write-Error "Не удалось создать файл лога '$logFile'. Ошибка: $($_.Exception.Message)"
    exit 1
}

# Функция логирования (минимальный вывод для скорости)
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] - $Message"
    Write-Host $logEntry -ForegroundColor $Color
    try {
        $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Error "Ошибка записи в лог: $($_.Exception.Message)"
    }
}

Write-Log "Начало ускоренного анализа CBS.log на отсутствие пакетов (p) CBS Catalog Missing после последней 'Checking System Update Readiness'..." "INFO" "Cyan"

# Проверка существования CBS.log
if (-not (Test-Path $CBSLogPath)) {
    Write-Log "Ошибка: Файл CBS.log не найден по пути '$CBSLogPath'. Укажите правильный путь с -CBSLogPath." "ERROR" "Red"
    exit 1
}

# Установка кодировки
$encodingParam = @{}
switch ($Encoding.ToUpper()) {
    "UNICODE" { $encodingParam["Encoding"] = "Unicode" }
    "BIGENDIANUNICODE" { $encodingParam["Encoding"] = "BigEndianUnicode" }
    "UTF8" { $encodingParam["Encoding"] = "UTF8" }
    "DEFAULT" { $encodingParam["Encoding"] = "Default" }
    default { $encodingParam["Encoding"] = "UTF8"; Write-Log "Неизвестная кодировка, используется UTF8 по умолчанию." "WARNING" "Yellow" }
}
Write-Log "Используется кодировка: $($encodingParam['Encoding'])" "INFO" "Cyan"

# Паттерн для поиска только (p) CBS Catalog Missing пакетов (обновлён по примеру из форума)
$componentPattern = "\(p\)\s*CBS\s*Catalog\s*Missing\s*\(n\)\s*([A-Za-z0-9_]+_for_[A-Za-z0-9]+~[A-Za-z0-9]+~[A-Za-z0-9]+~~[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"

# Ускоренный анализ CBS.log на отсутствующие пакеты начиная с последней 'Checking System Update Readiness'
$foundIssues = @()
$missingComponents = @()

Write-Log "Начало поиска последней строки 'Checking System Update Readiness'..." "INFO" "Cyan"
try {
    # Используем Select-String для быстрого поиска всех строк 'Checking System Update Readiness'
    $startLines = Select-String -Path $CBSLogPath -Pattern "Checking\s*System\s*Update\s*Readiness" -Encoding $encodingParam.Encoding -ErrorAction Stop
    if (-not $startLines) {
        Write-Log "Строка 'Checking System Update Readiness' не найдена в CBS.log." "ERROR" "Red"
        exit 1
    }

    # Находим последнюю строку (с максимальным номером строки)
    $lastStartLine = $startLines | Sort-Object LineNumber -Descending | Select-Object -First 1
    $startLineNumber = $lastStartLine.LineNumber
    Write-Log "Найдена последняя строка начала анализа: '$($lastStartLine.Line)' (строка $startLineNumber)" "INFO" "Green"

    # Считываем только строки после последней найденной с использованием Select-String для (p)
    $relevantLines = Select-String -Path $CBSLogPath -Pattern "\(p\)" `
        -AfterContext 0 `
        -Context ($startLineNumber, [int]::MaxValue) `
        -Encoding $encodingParam.Encoding `
        -ErrorAction Stop | ForEach-Object { $_.Line }

    Write-Log "Общее количество релевантных строк после последней 'Checking System Update Readiness': $($relevantLines.Count)" "INFO" "Cyan"
    $progress = 0

    # Анализируем только релевантные строки
    foreach ($line in $relevantLines) {
        $progress++
        Write-Progress -Activity "Анализ релевантных строк" -Status "Строка $progress из $($relevantLines.Count)" -PercentComplete (($progress / $relevantLines.Count) * 100)
        
        Write-Log "Обработка строки: '$line'" "DEBUG" "Gray"
        
        if ($line -match $componentPattern) {
            Write-Log "Найдено совпадение (пакет): '$line'" "WARNING" "Yellow"
            $foundIssues += $line
            
            # Извлечение пакета
            $packageName = $Matches[1]
            if ($packageName -and $packageName -ne "") {
                $packageName = $packageName.Trim()
                if ($packageName -match "[A-Za-z0-9]") {
                    Write-Log "Извлечён пакет: '$packageName'" "INFO" "Green"
                    $missingComponents += $packageName
                } else {
                    Write-Log "Не удалось извлечь валидное имя пакета из строки: '$line'" "WARNING" "Yellow"
                }
            } else {
                Write-Log "Не удалось извлечь имя пакета из строки: '$line'" "WARNING" "Yellow"
            }
        } else {
            Write-Log "Строка не соответствует паттерну: '$line'" "DEBUG" "Gray"
        }
        
        # Отладочный вывод для нераспознанных строк с (p)
        if ($line.Contains("(p)")) {
            $isProcessed = $false
            if ($line -match $componentPattern) { $isProcessed = $true }
            if (-not $isProcessed) {
                Write-Log "Строка с потенциальным отсутствующим пакетом, но не обработана: '$line'" "WARNING" "Yellow"
            }
        }
    }
} catch {
    Write-Log "Ошибка анализа CBS.log: $($_.Exception.Message)" "ERROR" "Red"
    exit 1
}
Write-Progress -Activity "Анализ релевантных строк" -Completed

# Удаление дубликатов пакетов и фильтрация пустых или невалидных значений
$missingComponents = $missingComponents | Sort-Object -Unique | Where-Object { 
    $_ -ne $null -and $_ -ne "" -and $_ -match "[A-Za-z0-9]" 
}

if ($foundIssues.Count -eq 0) {
    Write-Log "Отсутствующие пакеты не найдены после последней 'Checking System Update Readiness'." "INFO" "Green"
    exit 0
} else {
    Write-Log "Обнаружено проблем: $($foundIssues.Count). Отсутствующих пакетов: $($missingComponents.Count)" "WARNING" "Yellow"
    
    if ($missingComponents.Count -eq 0) {
        Write-Log "Не удалось определить отсутствующие пакеты. Проверьте отладочные сообщения в логе." "ERROR" "Red"
        exit 1
    }
    Write-Log "Список отсутствующих пакетов: '$($missingComponents -join ', ')'" "INFO" "Cyan"
}

Write-Log "Анализ CBS.log завершён. Обработано релевантных строк: $progress" "INFO" "Green"
