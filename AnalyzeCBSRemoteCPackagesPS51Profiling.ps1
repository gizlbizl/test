# Параметры скрипта
param (
    [string]$CBSLogPath = "$env:SystemRoot\Logs\CBS\CBS.log",  # Используем $env:SystemRoot для универсальности
    [string]$DISMLogPath = "$env:SystemRoot\Logs\DISM\dism.log",
    [string]$LogDir = "C:\Temp",
    [int]$ProjectStart = 1,      # Начальный номер проекта
    [int]$ProjectEnd = 0,        # Конечный номер проекта (0 = не задан)
    [int]$ProjectCount = 0,      # Количество проектов от ProjectStart
    [int]$MaxLogDays = 7,        # Анализировать записи не старше N дней (можно отключить для теста)
    [int]$MaxConcurrentJobs = 5  # Максимум одновременных заданий для серверов
)

# Проверка прав администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен с правами администратора. Запустите PowerShell от имени администратора."
    exit 1
}

# Инициализация логов
$logBaseDir = Join-Path $LogDir "RepairLogs"
try {
    if (-not (Test-Path $logBaseDir)) {
        New-Item -Path $logBaseDir -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Error "Не удалось создать директорию для логов '$logBaseDir'. Ошибка: $($_.Exception.Message)"
    exit 1
}
$logFile = Join-Path $logBaseDir "RepairLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
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
        Write-Log "Ошибка определения кодировки CBS.log: $($_.Exception.Message)" "ERROR" "Red"
        return "UTF8"  # Значение по умолчанию на случай ошибки
    }
}

$encoding = Get-FileEncoding -Path $CBSLogPath
Write-Log "Обнаружена кодировка CBS.log: $encoding" "INFO" "Cyan"

$encodingParam = @{}
switch ($encoding) {
    "Unicode" { $encodingParam["Encoding"] = "Unicode" }
    "BigEndianUnicode" { $encodingParam["Encoding"] = "BigEndianUnicode" }
    "UTF8" { $encodingParam["Encoding"] = "UTF8" }
    "Default" { $encodingParam["Encoding"] = "Default" }
}

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

# Паттерны для поиска отсутствующих компонентов (только необходимые)
$componentPatterns = @(
    "\(p\) CBS Catalog Missing Package.*for",         # Отсутствующий пакет, например, KB4503267-...
    "CBS Manifest Corruption:\d+"                    # Коррупция манифеста, например, CBS Manifest Corruption:53
)

# Анализ CBS.log на отсутствующие компоненты
$foundIssues = @()
$missingComponents = @()

Write-Log "Начало анализа файла CBS.log на отсутствие компонентов..." "INFO" "Cyan"
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

# Функция генерации имен серверов
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
        Write-Log "Ошибка генерации списка серверов: $($_.Exception.Message)" "ERROR" "Red"
        return @()
    }
    return $servers
}

# Генерация списка серверов
$serverList = Get-ServerNames -start $ProjectStart -end $ProjectEnd -count $ProjectCount
if ($serverList.Count -eq 0) {
    Write-Log "Список серверов пуст. Проверьте параметры ProjectStart, ProjectEnd, ProjectCount." "ERROR" "Red"
    exit 1
}
Write-Log "Сгенерирован список серверов: '$($serverList -join ', ')'" "INFO" "Cyan"

# Проверка серверов
$sourceServer = $null
$jobs = @()
$jobCount = 0

foreach ($server in $serverList) {
    if ($jobCount -ge $MaxConcurrentJobs) {
        $jobs | Wait-Job -Timeout 300 | ForEach-Object {
            try { Receive-Job -Job $_ -ErrorAction Stop | Out-Null } catch { Write-Log "Ошибка получения результатов задания: $($_.Exception.Message)" "ERROR" "Red" }
        }
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
                    $winSxSPath = Join-Path $sourcePath "WinSxS"
                    $servicingPath = Join-Path $sourcePath "servicing\Packages"
                    $allComponentsPresent = $true
                    $foundComponents = @()

                    foreach ($component in $missingComponents) {
                        $searchTime = Measure-Command {
                            $foundInWinSxS = Get-ChildItem -Path $winSxSPath -Filter "*$component*" -Directory -ErrorAction SilentlyContinue
                            $foundInServicing = Get-ChildItem -Path $servicingPath -Filter "*$component*" -File -ErrorAction SilentlyContinue
                            $found = ($foundInWinSxS -or $foundInServicing)
                        }
                        Write-JobLog "Поиск компонента '$component' на $server занял $($searchTime.TotalSeconds) секунд"
                        if ($found) {
                            $location = if ($foundInWinSxS) { "WinSxS" } else { "servicing\Packages" }
                            Write-JobLog "Компонент '$component' найден в $location на $server" "INFO"
                            $foundComponents += $component
                        } else {
                            $allComponentsPresent = $false
                            Write-JobLog "Компонент '$component' НЕ найден на $server" "WARNING"
                        }
                    }

                    if ($allComponentsPresent) {
                        return [PSCustomObject]@{
                            Path = $sourcePath
                            Components = $foundComponents
                        }
                    }
                } else {
                    Write-JobLog "Не удалось получить доступ к '$sourcePath'" "ERROR"
                }
            } else {
                Write-JobLog "Сервер $server недоступен" "ERROR"
            }
        } -ArgumentList $server, $missingComponents, $logFile -ErrorAction Stop
        $jobCount++
    } catch {
        Write-Log "Ошибка запуска задания для сервера '$server': $($_.Exception.Message)" "ERROR" "Red"
    }
}

# Ожидание завершения заданий
Write-Log "Ожидание проверки серверов..." "INFO" "Cyan"
try {
    $jobs | Wait-Job -Timeout 300 | ForEach-Object {
        try { Receive-Job -Job $_ -ErrorAction Stop | Out-Null } catch { Write-Log "Ошибка получения результатов задания: $($_.Exception.Message)" "ERROR" "Red" }
    }
    foreach ($job in $jobs) {
        try {
            $result = Receive-Job -Job $job -ErrorAction Stop
            if ($null -ne $result -and $null -eq $sourceServer) {
                $sourceServer = $result.Path
                $foundComponents = $result.Components
                Write-Log "Выбран сервер: '$sourceServer'. Найдены компоненты: '$($foundComponents -join ', ')'" "INFO" "Green"
            }
        } catch {
            Write-Log "Ошибка обработки результата задания: $($_.Exception.Message)" "ERROR" "Red"
        }
        Remove-Job -Job $job -Force
    }
} catch {
    Write-Log "Ошибка ожидания завершения заданий: $($_.Exception.Message)" "ERROR" "Red"
    $jobs | Remove-Job -Force
}

if ($null -eq $sourceServer) {
    Write-Log "Не удалось найти сервер с необходимыми компонентами. Проверьте доступность серверов и пути." "ERROR" "Red"
    exit 1
}

# Проверка наличия всех компонентов
$missingStill = $missingComponents | Where-Object { $_ -notin $foundComponents }
if ($missingStill.Count -gt 0) {
    Write-Log "На сервере '$sourceServer' отсутствуют компоненты: '$($missingStill -join ', ')'" "ERROR" "Red"
    exit 1
}

# Запрос подтверждения перед запуском DISM
$dismConfirm = Read-Host "Запустить DISM для восстановления с источником '$sourceServer'? (Y/N)"
if ($dismConfirm -notin @("Y", "y")) {
    Write-Log "DISM не запущен — пользователь отказался." "WARNING" "Yellow"
    exit 0
}

# Проверка наличия DISM
if (-not (Get-Command "DISM" -ErrorAction SilentlyContinue)) {
    Write-Log "Утилита DISM не найдена. Проверьте установку Windows." "ERROR" "Red"
    exit 1
}

# Запуск DISM
Write-Log "Запуск DISM с источником '$sourceServer'..." "INFO" "Cyan"
$dismCommand = "DISM /Online /Cleanup-Image /RestoreHealth /Source:`"$sourceServer`" /LimitAccess /LogPath:`"$DISMLogPath`""
try {
    $dismResult = & $dismCommand 2>&1 | ForEach-Object { Write-Log "$_" "INFO" }
    if ($dismResult -match "The restore operation completed successfully") {
        Write-Log "Восстановление завершено успешно!" "INFO" "Green"
    } else {
        Write-Log "Восстановление не удалось. Проверьте лог '$DISMLogPath' для деталей." "ERROR" "Red"
    }
} catch {
    Write-Log "Ошибка выполнения DISM: $($_.Exception.Message)" "ERROR" "Red"
}

# Запрос подтверждения перед запуском SFC
$sfcConfirm = Read-Host "Запустить SFC /scannow для проверки системы? (Y/N)"
if ($sfcConfirm -notin @("Y", "y")) {
    Write-Log "SFC не запущен — пользователь отказался." "WARNING" "Yellow"
    exit 0
}

# Проверка наличия SFC
if (-not (Get-Command "sfc" -ErrorAction SilentlyContinue)) {
    Write-Log "Утилита SFC не найдена. Проверьте установку Windows." "ERROR" "Red"
    exit 1
}

# Запуск SFC
Write-Log "Запуск SFC /scannow..." "INFO" "Cyan"
try {
    $sfcResult = sfc /scannow 2>&1 | ForEach-Object { Write-Log "$_" "INFO" }
} catch {
    Write-Log "Ошибка выполнения SFC: $($_.Exception.Message)" "ERROR" "Red"
}

Write-Log "Анализ и восстановление завершены." "INFO" "Green"
