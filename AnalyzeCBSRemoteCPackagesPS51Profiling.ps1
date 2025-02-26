param (
    [string]$CBSLogPath = "$env:windir\Logs\CBS\CBS.log",
    [string]$DISMLogPath = "$env:windir\Logs\DISM\dism.log",
    [string]$LogDir = "C:\Temp",
    [int]$ProjectStart = 1,      # Начальный номер проекта
    [int]$ProjectEnd = 0,        # Конечный номер проекта (0 = не задан)
    [int]$ProjectCount = 0,      # Количество проектов от ProjectStart
    [int]$MaxLogDays = 7,        # Анализировать записи не старше N дней
    [int]$MaxConcurrentJobs = 5  # Максимум одновременных заданий для серверов
)

# Проверка на запуск от имени администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен с правами администратора. Запустите PowerShell от имени администратора."
    exit 1
}

# Создание директории для логов и файла лога
$LogDir = Join-Path $LogDir "RepairLogs"
try {
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
} catch {
    Write-Log "Ошибка: Не удалось создать директорию $LogDir. Проверьте права доступа. Ошибка: $_" "ERROR" "Red"
    exit 1
}
$LogFile = Join-Path $LogDir "RepairLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
try {
    New-Item -Path $LogFile -ItemType File -Force | Out-Null
} catch {
    Write-Log "Ошибка: Не удалось создать файл лога $LogFile. Проверьте права доступа. Ошибка: $_" "ERROR" "Red"
    exit 1
}

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO", [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] - $Message"
    Write-Host $logEntry -ForegroundColor $Color
    try {
        $logEntry | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch {
        Write-Host "Ошибка записи в лог: $_" -ForegroundColor Red
    }
}

Write-Log "Начало анализа CBS.log..." "INFO" "Cyan"

# Проверка существования CBS.log
if (-not (Test-Path $CBSLogPath)) {
    Write-Log "Ошибка: Файл CBS.log не найден по пути $CBSLogPath. Укажите правильный путь с -CBSLogPath." "ERROR" "Red"
    exit 1
}

# Определение кодировки CBS.log
function Get-FileEncoding {
    param ([string]$Path)
    try {
        $bytes = Get-Content -Path $Path -Encoding Byte -TotalCount 4 -ErrorAction Stop
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return "Unicode" }
        elseif ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return "BigEndianUnicode" }
        elseif ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return "UTF8" }
        else { return "Default" }
    } catch {
        Write-Log "Ошибка определения кодировки CBS.log: $_" "ERROR" "Red"
        return "Default"
    }
}

$cbsEncoding = Get-FileEncoding -Path $CBSLogPath
Write-Log "Обнаружена кодировка CBS.log: $cbsEncoding" "INFO" "Cyan"

$encodingParam = @{}
switch ($cbsEncoding) {
    "Unicode" { $encodingParam["Encoding"] = "Unicode" }
    "BigEndianUnicode" { $encodingParam["Encoding"] = "BigEndianUnicode" }
    "UTF8" { $encodingParam["Encoding"] = "UTF8" }
    "Default" { $encodingParam["Encoding"] = "Default" }
}

# Фильтрация по дате в CBS.log
$maxDate = (Get-Date).AddDays(-$MaxLogDays)
function Filter-LogByDate {
    param ([string]$Line)
    if ($Line -match "^\d{4}-\d{2}-\d{2}") {
        try {
            $logDate = [datetime]::ParseExact($Line.Substring(0, 10), "yyyy-MM-dd", $null)
            return $logDate -ge $maxDate
        } catch {
            Write-Log "Ошибка парсинга даты в строке: $Line. Ошибка: $_" "WARNING" "Yellow"
            return $false
        }
    }
    return $false
}

# Сложные маски для поиска отсутствующих компонентов
$errorPatterns = @(
    "\(p\) CBS Catalog Missing Package.*for",         # Отсутствующий пакет, например, KB4503267-...
    "CBS Manifest Corruption:\d+",                   # Коррупция манифеста, например, CBS Manifest Corruption:53
    "missing.*component",                            # Отсутствующий компонент
    "CBS MUM Missing.*for\s+\w+",                    # Отсутствующий MUM-файл
    "CSI Payload Corrupt",                           # Повреждённый полезный груз
    "corrupt.*file"                                  # Повреждённый файл
)

# Анализ CBS.log на отсутствующие компоненты
$foundIssues = @()
$missingComponents = @()

Write-Log "Начало анализа файла CBS.log на отсутствие компонентов (за последние $MaxLogDays дней)..." "INFO" "Cyan"
try {
    $totalLines = (Get-Content $CBSLogPath @encodingParam -ReadCount 0 -ErrorAction Stop).Count
} catch {
    Write-Log "Ошибка чтения CBS.log для подсчёта строк: $_" "ERROR" "Red"
    $totalLines = 0
}
$progress = 0

try {
    Get-Content $CBSLogPath @encodingParam -ReadCount 1000 -ErrorAction Stop | ForEach-Object {
        $_.Where({ Filter-LogByDate $_ }) | ForEach-Object {
            $progress++
            Write-Progress -Activity "Анализ CBS.log" -Status "$progress из $totalLines строк" -PercentComplete (($progress / $totalLines) * 100)
            
            foreach ($pattern in $errorPatterns) {
                if ($_ -match $pattern) {
                    Write-Log "Найдено совпадение (шаблон): $_" "WARNING" "Yellow"
                    $foundIssues += $_
                }
            }
            # Извлечение деталей отсутствующих компонентов с улучшенным регулярным выражением
            if ($_ -match "\(p\) CBS Catalog Missing Package\s+\d+\s+for\s+([A-Za-z0-9-]+(?:-[A-Za-z0-9]+)*)") {
                $packageName = $Matches[1]  # Извлекаем, например, KB4503267-31bf3856ad364e35-amd64-10.1.4
                Write-Log "Извлечен отсутствующий пакет: $packageName" "INFO" "Green"
                $missingComponents += $packageName
            }
            elseif ($_ -match "CBS Manifest Corruption:(\d+)") {
                $corruptionCode = $Matches[1]  # Извлекаем код, например, 53
                $corruptionKey = "CBS_Manifest_Corruption_$corruptionCode"
                Write-Log "Обнаружена коррупция манифеста CBS: Код $corruptionCode" "WARNING" "Yellow"
                $missingComponents += $corruptionKey
            }
            elseif ($_ -match "missing.*component\s+([A-Za-z0-9-]+(?:-[A-Za-z0-9]+)*)") {
                $componentName = $Matches[1]  # Извлекаем имя компонента, например, имя файла или пакета
                Write-Log "Обнаружен отсутствующий компонент: $componentName" "WARNING" "Yellow"
                $missingComponents += $componentName
            }
            elseif ($_ -match "CBS MUM Missing.*for\s+([A-Za-z0-9-]+(?:-[A-Za-z0-9]+)*)") {
                $mumName = $Matches[1]  # Извлекаем имя отсутствующего MUM-файла
                Write-Log "Обнаружен отсутствующий MUM-файл: $mumName" "WARNING" "Yellow"
                $missingComponents += $mumName
            }
            elseif ($_ -match "CSI Payload Corrupt.*for\s+([A-Za-z0-9-]+(?:-[A-Za-z0-9]+)*)") {
                $payloadName = $Matches[1]  # Извлекаем имя повреждённого полезного груза
                Write-Log "Обнаружен повреждённый полезный груз: $payloadName" "WARNING" "Yellow"
                $missingComponents += $payloadName
            }
            elseif ($_ -match "corrupt.*file\s+([A-Za-z0-9-]+(?:-[A-Za-z0-9]+)*)") {
                $fileName = $Matches[1]  # Извлекаем имя повреждённого файла
                Write-Log "Обнаружен повреждённый файл: $fileName" "WARNING" "Yellow"
                $missingComponents += $fileName
            }
            else {
                # Расширенный отладочный вывод для строк, соответствующих ключевым словам
                if ($_.Contains("(p)") -or $_.Contains("missing") -or $_.Contains("corrupt") -or $_.Contains("CBS Manifest Corruption")) {
                    Write-Log "Строка с потенциальным отсутствующим компонентом, но не обработана: $_" "WARNING" "Yellow"
                }
            }
        }
    }
} catch {
    Write-Log "Ошибка анализа CBS.log: $_" "ERROR" "Red"
    exit 1
}
Write-Progress -Activity "Анализ CBS.log" -Completed

# Удаление дубликатов компонентов
$missingComponents = $missingComponents | Sort-Object -Unique

if ($foundIssues.Count -eq 0) {
    Write-Log "Ошибки или отсутствующие компоненты не найдены." "INFO" "Green"
    exit 0
} else {
    Write-Log "Обнаружено проблем: $($foundIssues.Count). Отсутствующих компонентов: $($missingComponents.Count)." "WARNING" "Yellow"
    
    if ($missingComponents.Count -eq 0) {
        Write-Log "Ошибка: Не удалось определить отсутствующие компоненты для восстановления. Проверьте отладочные сообщения в логе." "ERROR" "Red"
        exit 1
    }
    Write-Log "Список отсутствующих компонентов: $($missingComponents -join ', ')" "INFO" "Cyan"
}

# Функция для генерации имен серверов
function Get-ServerNames {
    param (
        [int]$start = 1,
        [int]$end = 0,
        [int]$count = 0
    )
    $servers = @()
    try {
        if ($end -gt 0 -and $end -ge $start) {
            $start..$end | ForEach-Object { $servers += "vdc01-pep{0:D2}s001" -f $_ }
        } elseif ($count -gt 0) {
            $start..($start + $count - 1) | ForEach-Object { $servers += "vdc01-pep{0:D2}s001" -f $_ }
        } else {
            $servers += "vdc01-pep{0:D2}s001" -f $start
        }
    } catch {
        Write-Log "Ошибка генерации списка серверов: $_" "ERROR" "Red"
        return @()
    }
    return $servers
}

# Генерация списка серверов
$serverList = Get-ServerNames -start $ProjectStart -end $ProjectEnd -count $ProjectCount
if ($serverList.Count -eq 0) {
    Write-Log "Ошибка: Список серверов пуст. Проверьте параметры ProjectStart, ProjectEnd, ProjectCount." "ERROR" "Red"
    exit 1
}
Write-Log "Сгенерирован список серверов: $($serverList -join ', ')" "INFO" "Cyan"

$sourceServer = $null
$jobs = @()
$jobCount = 0

# Параллельная проверка серверов
foreach ($server in $serverList) {
    if ($jobCount -ge $MaxConcurrentJobs) {
        $jobs | Wait-Job | ForEach-Object { 
            try { Receive-Job -Job $_ -ErrorAction Stop } catch { Write-Log "Ошибка получения результатов задания: $_" "ERROR" "Red" }
        } | Out-Null
        $jobs | Remove-Job -Force
        $jobs = @()
        $jobCount = 0
    }

    try {
        $jobs += Start-Job -ScriptBlock {
            param ($server, $missingComponents, $logFile)
            function Write-JobLog {
                param ([string]$Message, [string]$Level = "INFO")
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                "$timestamp [$Level] - $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
            }

            $timeoutSeconds = 10
            if (Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $sourcePath = "\\$server\c$\windows"
                if (Test-Path $sourcePath -ErrorAction SilentlyContinue) {
                    $winSxSPath = "\\$server\c$\windows\WinSxS"
                    $servicingPath = "\\$server\c$\windows\servicing\Packages"
                    $allComponentsPresent = $true
                    $foundComponents = @()

                    foreach ($component in $missingComponents) {
                        $searchTime = Measure-Command {
                            $foundInWinSxS = Get-ChildItem -Path $winSxSPath -Filter "*$component*" -Directory -ErrorAction SilentlyContinue
                            $foundInServicing = Get-ChildItem -Path $servicingPath -Filter "*$component*" -File -ErrorAction SilentlyContinue
                            $found = ($foundInWinSxS -or $foundInServicing)
                        }
                        Write-JobLog "Поиск компонента $component на $server занял $($searchTime.TotalSeconds) секунд"
                        if ($found) {
                            $location = if ($foundInWinSxS) { "WinSxS" } else { "servicing\Packages" }
                            Write-JobLog "Компонент $component найден в $location на $server" "INFO"
                            $foundComponents += $component
                        } else {
                            $allComponentsPresent = $false
                            Write-JobLog "Компонент $component НЕ найден на $server" "WARNING"
                        }
                    }

                    if ($allComponentsPresent) {
                        return [PSCustomObject]@{
                            Path = $sourcePath
                            Components = $foundComponents
                        }
                    }
                } else {
                    Write-JobLog "Не удалось получить доступ к $sourcePath" "ERROR"
                }
            } else {
                Write-JobLog "Сервер $server недоступен" "ERROR"
            }
        } -ArgumentList $server, $missingComponents, $LogFile -ErrorAction Stop
        $jobCount++
    } catch {
        Write-Log "Ошибка запуска задания для сервера $server: $_" "ERROR" "Red"
    }
}

# Ожидание завершения всех заданий и сбор результатов
Write-Log "Ожидание проверки серверов..." "INFO" "Cyan"
try {
    $jobs | Wait-Job -Timeout 300 | Out-Null  # Ограничение времени ожидания 5 минут
    foreach ($job in $jobs) {
        try {
            $result = Receive-Job -Job $job -ErrorAction Stop
            if ($null -ne $result -and $null -eq $sourceServer) {
                $sourceServer = $result.Path
                $foundComponents = $result.Components
                Write-Log "Выбран сервер: $sourceServer. Найдены компоненты: $($foundComponents -join ', ')" "INFO" "Green"
            }
        } catch {
            Write-Log "Ошибка получения результатов задания: $_" "ERROR" "Red"
        }
        Remove-Job -Job $job -Force
    }
} catch {
    Write-Log "Ошибка ожидания завершения заданий: $_" "ERROR" "Red"
    $jobs | Remove-Job -Force
}

if ($null -eq $sourceServer) {
    Write-Log "Ошибка: Не удалось найти сервер с необходимыми компонентами. Проверьте доступность серверов и пути." "ERROR" "Red"
    exit 1
}

# Проверка наличия всех компонентов перед запуском DISM
$missingStill = $missingComponents | Where-Object { $_ -notin $foundComponents }
if ($missingStill.Count -gt 0) {
    Write-Log "Ошибка: На сервере $sourceServer отсутствуют компоненты: $($missingStill -join ', ')" "ERROR" "Red"
    exit 1
}

# Запрос подтверждения перед запуском DISM
$dismConfirm = Read-Host "Запустить DISM для восстановления с источником $sourceServer? (Y/N)"
if ($dismConfirm -notin @("Y", "y")) {
    Write-Log "DISM не запущен — пользователь отказался." "WARNING" "Yellow"
    exit 0
}

# Проверка доступности DISM
if (-not (Get-Command "DISM" -ErrorAction SilentlyContinue)) {
    Write-Log "Ошибка: Утилита DISM не найдена. Проверьте установку Windows." "ERROR" "Red"
    exit 1
}

# Запуск DISM
Write-Log "Все необходимые компоненты найдены. Запуск DISM с источником $sourceServer..." "INFO" "Cyan"
$dismCommand = "DISM /Online /Cleanup-Image /RestoreHealth /Source:$sourceServer /LimitAccess /LogPath:$DISMLogPath"

try {
    $dismResult = Invoke-Expression $dismCommand 2>&1 | ForEach-Object { Write-Log "$_" "INFO" }
    if ($dismResult -match "The restore operation completed successfully") {
        Write-Log "Восстановление завершено успешно!" "INFO" "Green"
    } else {
        Write-Log "Восстановление не удалось. См. $DISMLogPath для деталей." "ERROR" "Red"
    }
} catch {
    Write-Log "Ошибка DISM: $_" "ERROR" "Red"
}

# Запрос подтверждения перед запуском SFC
$sfcConfirm = Read-Host "Запустить SFC /scannow для проверки системы? (Y/N)"
if ($sfcConfirm -notin @("Y", "y")) {
    Write-Log "SFC не запущен — пользователь отказался." "WARNING" "Yellow"
    exit 0
}

# Проверка доступности SFC
if (-not (Get-Command "sfc" -ErrorAction SilentlyContinue)) {
    Write-Log "Ошибка: Утилита SFC не найдена. Проверьте установку Windows." "ERROR" "Red"
    exit 1
}

# Запуск SFC
Write-Log "Запуск SFC /scannow..." "INFO" "Cyan"
try {
    $sfcResult = sfc /scannow 2>&1 | ForEach-Object { Write-Log "$_" "INFO" }
} catch {
    Write-Log "Ошибка SFC: $_" "ERROR" "Red"
}

Write-Log "Анализ и восстановление завершены." "INFO" "Green"
