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

# Фильтрация по дате в CBS.log
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

# Паттерны для поиска отсутствующих компонентов
$componentPatterns = @(
    "\(p\) CBS Catalog Missing Package.*for",         # Отсутствующий пакет, например, KB4503267-...
    "CBS Manifest Corruption:\d+"                    # Коррупция манифеста, например, CBS Manifest Corruption:53
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
    Get-Content $CBSLogPath @encodingParam -ReadCount 1000 -ErrorAction Stop | ForEach-Object {
        $_.Where({ Filter-LogByDate $_ }) | ForEach-Object {
            $progress++
            Write-Progress -Activity "Анализ CBS.log" -Status "$progress из $totalLines строк" -PercentComplete (($progress / $totalLines) * 100)
            
            foreach ($pattern in $componentPatterns) {
                if ($_ -match $pattern) {
                    Write-Log "Найдено совпадение (компонент): '$_'" "WARNING" "Yellow"
                    $foundIssues += $_
                }
            }
            # Извлечение деталей отсутствующих компонентов
            if ($_ -match "\(p\) CBS Catalog Missing Package\s+\d+\s+for\s+([A-Za-z0-9-]+\.[A-Za-z0-9-]+\.[A-Za-z0-9-]+(?:-[A-Za-z0-9]+)*)") {
                $packageName = $Matches[1]  # Извлекаем, например, KB4503267-31bf3856ad364e35-amd64-10.1.4
                Write-Log "Извлечен отсутствующий пакет: '$packageName'" "INFO" "Green"
                $missingComponents += $packageName
            }
            elseif ($_ -match "CBS Manifest Corruption:(\d+)") {
                $corruptionCode = $Matches[1]  # Извлекаем код, например, 53
                $corruptionKey = "CBS_Manifest_Corruption_$corruptionCode"
                Write-Log "Обнаружена коррупция манифеста CBS: Код $corruptionCode" "WARNING" "Yellow"
                $missingComponents += $corruptionKey
            }
            else {
                if ($_.Contains("(p)") -or $_.Contains("CBS Manifest Corruption")) {
                    Write-Log "Строка с потенциальным отсутствующим компонентом, но не обработана: '$_'" "WARNING" "Yellow"
                }
            }
        }
    }
} catch {
    Write-Log "Ошибка анализа CBS.log: $($_.Exception.Message)" "ERROR" "Red"
    exit 1
}
Write-Progress -Activity "Анализ CBS.log" -Completed

# Удаление дубликатов компонентов и фильтрация пустых значений
$missingComponents = $missingComponents | Sort-Object -Unique | Where-Object { $_ -ne $null -and $_ -ne "" }

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
