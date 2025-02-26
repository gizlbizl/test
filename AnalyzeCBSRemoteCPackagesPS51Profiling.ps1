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
    Write-Error "Скрипт должен быть запущен с правами администратора."
    exit 1
}

# Создание директории для логов и файла лога
$LogDir = Join-Path $LogDir "RepairLogs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir "RepairLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
New-Item -Path $LogFile -ItemType File -Force | Out-Null

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO", [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] - $Message"
    Write-Host $logEntry -ForegroundColor $Color
    $logEntry | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

Write-Log "Начало анализа CBS.log..." "INFO" "Cyan"

# Проверка существования CBS.log
if (-not (Test-Path $CBSLogPath)) {
    Write-Log "Ошибка: Файл CBS.log не найден по пути $CBSLogPath." "ERROR" "Red"
    exit 1
}

# Определение кодировки CBS.log
function Get-FileEncoding {
    param ([string]$Path)
    $bytes = Get-Content -Path $Path -Encoding Byte -TotalCount 4
    if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return "Unicode" }
    elseif ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return "BigEndianUnicode" }
    elseif ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return "UTF8" }
    else { return "Default" }
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
        $logDate = [datetime]::ParseExact($Line.Substring(0, 10), "yyyy-MM-dd", $null)
        return $logDate -ge $maxDate
    }
    return $false
}

# Сложные маски для поиска ошибок
$errorPatterns = @(
    "Error.*0x[0-9A-Fa-f]{8}",
    "failed.*HRESULT=0x[0-9A-Fa-f]{8}",
    "missing.*component",
    "corrupt.*file",
    "CSI Payload Corrupt",
    "CBS MUM Missing",
    "\(p\) CBS Catalog Missing Package.*for"
)

# Анализ CBS.log
$foundIssues = @()
$missingComponents = @()

Write-Log "Начало анализа файла CBS.log (за последние $MaxLogDays дней)..." "INFO" "Cyan"
$totalLines = (Get-Content $CBSLogPath @encodingParam -ReadCount 0).Count
$progress = 0

Get-Content $CBSLogPath @encodingParam -ReadCount 1000 | ForEach-Object {
    $_.Where({ Filter-LogByDate $_ }) | ForEach-Object {
        $progress++
        Write-Progress -Activity "Анализ CBS.log" -Status "$progress из $totalLines строк" -PercentComplete (($progress / $totalLines) * 100)
        
        foreach ($pattern in $errorPatterns) {
            if ($_ -match $pattern) {
                Write-Log "Найдено совпадение (шаблон): $_" "WARNING" "Yellow"
                $foundIssues += $_
            }
        }
        # Улучшенное регулярное выражение для извлечения пакета
        if ($_ -match "\(p\) CBS Catalog Missing Package\s+\d+\s+for\s+(\w+-\w+(?:-\w+)*)") {
            $packageName = $Matches[1]  # Извлекаем, например, KB4503267-31bf3856ad364e35-amd64-10.1.4
            Write-Log "Извлечен пакет: $packageName" "INFO" "Yellow"
            $missingComponents += $packageName
        } else {
            # Отладочный вывод для строк, содержащих (p)
            if ($_ -match "\(p\)") {
                Write-Log "Строка с (p), но не обработана: $_" "WARNING" "Yellow"
            }
        }
    }
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
}

# Функция для генерации имен серверов
function Get-ServerNames {
    param (
        [int]$start = 1,
        [int]$end = 0,
        [int]$count = 0
    )
    $servers = @()
    if ($end -gt 0 -and $end -ge $start) {
        $start..$end | ForEach-Object { $servers += "vdc01-pep{0:D2}s001" -f $_ }
    } elseif ($count -gt 0) {
        $start..($start + $count - 1) | ForEach-Object { $servers += "vdc01-pep{0:D2}s001" -f $_ }
    } else {
        $servers += "vdc01-pep{0:D2}s001" -f $start
    }
    return $servers
}

# Генерация списка серверов
$serverList = Get-ServerNames -start $ProjectStart -end $ProjectEnd -count $ProjectCount
Write-Log "Сгенерирован список серверов: $($serverList -join ', ')" "INFO" "Cyan"

$sourceServer = $null
$jobs = @()
$jobCount = 0

# Параллельная проверка серверов
foreach ($server in $serverList) {
    if ($jobCount -ge $MaxConcurrentJobs) {
        $jobs | Wait-Job | ForEach-Object { Receive-Job -Job $_ } | Out-Null
        $jobs | Remove-Job
        $jobs = @()
        $jobCount = 0
    }

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
            }
        }
    } -ArgumentList $server, $missingComponents, $LogFile
    $jobCount++
}

# Ожидание завершения всех заданий и сбор результатов
Write-Log "Ожидание проверки серверов..." "INFO" "Cyan"
$jobs | Wait-Job | Out-Null
foreach ($job in $jobs) {
    $result = Receive-Job -Job $job
    if ($null -ne $result -and $null -eq $sourceServer) {
        $sourceServer = $result.Path
        $foundComponents = $result.Components
        Write-Log "Выбран сервер: $sourceServer. Найдены компоненты: $($foundComponents -join ', ')" "INFO" "Green"
    }
    Remove-Job -Job $job
}

if ($null -eq $sourceServer) {
    Write-Log "Ошибка: Не удалось найти сервер с необходимыми компонентами." "ERROR" "Red"
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
    Write-Log "Ошибка: Утилита DISM не найдена." "ERROR" "Red"
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
        Write-Log "Восстановление не удалось. См. $DISMLogPath." "ERROR" "Red"
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
    Write-Log "Ошибка: Утилита SFC не найдена." "ERROR" "Red"
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
