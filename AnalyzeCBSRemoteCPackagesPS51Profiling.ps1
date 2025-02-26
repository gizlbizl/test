# Параметры скрипта
param (
    [string]$CBSLogPath = "$env:SystemRoot\Logs\CBS\CBS.log",  # Путь к CBS.log
    [string]$LogDir = "C:\Temp",                               # Каталог для логов
    [int]$MaxLogDays = 7,                                      # Анализировать записи не старше N дней
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

# Функция логирования
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

Write-Log "Начало анализа CBS.log на отсутствие компонентов..." "INFO" "Cyan"

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

# Фильтрация по дате в CBS.log (временно отключена для диагностики)
$maxDate = (Get-Date).AddDays(-$MaxLogDays)
function Filter-LogByDate {
    param ([string]$Line)
    if ($Line -match "^\d{4}-\d{2}-\d{2}") {
        try {
            $logDate = [datetime]::ParseExact($Line.Substring(0, 10), "yyyy-MM-dd", $null)
            return $logDate -ge $maxDate
        } catch {
            Write-Log "Ошибка парсинга даты в строке: '$Line'. Ошибка: $($_.Exception.Message)" "WARNING" "Yellow"
            return $false
        }
    }
    return $false
}

# Паттерны для поиска всех отсутствующих компонентов (обновлены для универсальности)
$componentPatterns = @(
    "\(p\) CBS Catalog Missing Package.*for\s+(.+)",               # Любые отсутствующие пакеты, например, Package_4018_for_KB4516044~...
    "CBS Manifest Corruption:\d+",                                # Коррупция манифеста, например, CBS Manifest Corruption:53
    "missing.*component\s+(.+)",                                  # Отсутствующий компонент (любой формат)
    "CBS MUM Missing.*for\s+(.+)",                                # Отсутствующий MUM-файл (любой формат)
    "CSI Payload Corrupt.*for\s+(.+)",                            # Повреждённый полезный груз (любой формат)
    "corrupt.*file\s+(.+)"                                        # Повреждённый файл (любой формат)
)

# Анализ CBS.log на отсутствующие компоненты
$foundIssues = @()
$missingComponents = @()

Write-Log "Начало анализа файла CBS.log на отсутствие компонентов (за последние $MaxLogDays дней)..." "INFO" "Cyan"
try {
    $totalLines = (Get-Content $CBSLogPath @encodingParam -ReadCount 0 -ErrorAction Stop).Count
} catch {
    Write-Log "Ошибка чтения CBS.log для подсчёта строк: $($_.Exception.Message)" "ERROR" "Red"
    $totalLines = 0
}
$progress = 0

try {
    # Временно отключаем фильтр по дате для диагностики
    Get-Content $CBSLogPath @encodingParam -ReadCount 1000 -ErrorAction Stop | ForEach-Object {
        $progress++
        Write-Progress -Activity "Анализ CBS.log" -Status "$progress из $totalLines строк" -PercentComplete (($progress / $totalLines) * 100)
        
        foreach ($pattern in $componentPatterns) {
            if ($_ -match $pattern) {
                Write-Log "Найдено совпадение (компонент): '$_'" "WARNING" "Yellow"
                $foundIssues += $_
            }
        }
        # Извлечение деталей всех отсутствующих компонентов
        foreach ($pattern in $componentPatterns) {
            if ($_ -match $pattern) {
                $componentName = $Matches[1]  # Извлекаем имя компонента (первая захваченная группа)
                if ($componentName -and $componentName -ne "") {
                    # Очистка имени компонента от лишних пробелов и символов
                    $componentName = $componentName.Trim()
                    # Проверка на валидность (не пустое и не только пробелы)
                    if ($componentName -match "[A-Za-z0-9]") {
                        Write-Log "Извлечен отсутствующий компонент: '$componentName'" "INFO" "Green"
                        $missingComponents += $componentName
                    } else {
                        Write-Log "Не удалось извлечь валидное имя компонента из строки: '$_'" "WARNING" "Yellow"
                    }
                } else {
                    Write-Log "Не удалось извлечь имя компонента из строки: '$_'" "WARNING" "Yellow"
                }
            }
        }
        # Отладочный вывод для строк, соответствующих ключевым словам, но не обработанных
        if ($_.Contains("(p)") -or $_.Contains("missing") -or $_.Contains("corrupt") -or $_.Contains("CBS Manifest Corruption")) {
            $isProcessed = $false
            foreach ($pattern in $componentPatterns) {
                if ($_ -match $pattern) { $isProcessed = $true; break }
            }
            if (-not $isProcessed) {
                Write-Log "Строка с потенциальным отсутствующим компонентом, но не обработана: '$_'" "WARNING" "Yellow"
            }
        }
    }
} catch {
    Write-Log "Ошибка анализа CBS.log: $($_.Exception.Message)" "ERROR" "Red"
    exit 1
}
Write-Progress -Activity "Анализ CBS.log" -Completed

# Удаление дубликатов компонентов и фильтрация пустых или невалидных значений
$missingComponents = $missingComponents | Sort-Object -Unique | Where-Object { 
    $_ -ne $null -and $_ -ne "" -and $_ -match "[A-Za-z0-9]" 
}

if ($foundIssues.Count -eq 0) {
    Write-Log "Отсутствующие компоненты не найдены." "INFO" "Green"
    exit 0
} else {
    Write-Log "Обнаружено проблем: $($foundIssues.Count). Отсутствующих компонентов: $($missingComponents.Count)" "WARNING" "Yellow"
    
    if ($missingComponents.Count -eq 0) {
        Write-Log "Не удалось определить отсутствующие компоненты. Проверьте отладочные сообщения в логе." "ERROR" "Red"
        exit 1
    }
    Write-Log "Список отсутствующих компонентов: '$($missingComponents -join ', ')'" "INFO" "Cyan"
}

Write-Log "Анализ CBS.log завершён." "INFO" "Green"
