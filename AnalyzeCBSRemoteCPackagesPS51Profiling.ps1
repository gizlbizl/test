# Скрипт для анализа CBS.log и восстановления через DISM с использованием \\server\c$\windows
# Требуются права администратора, совместим с PowerShell 5.1, с гибкими диапазонами проектов

param (
    [string]$CBSLogPath = "$env:windir\Logs\CBS\CBS.log",
    [string]$DISMLogPath = "$env:windir\Logs\DISM\dism.log",
    [string]$LogFile = "C:\Temp\RepairLog.txt",
    [int]$ProjectStart = 1,      # Начальный номер проекта (по умолчанию 1)
    [int]$ProjectEnd = 0,        # Конечный номер проекта (0 = не задан)
    [int]$ProjectCount = 0       # Количество проектов от ProjectStart (0 = использовать диапазон)
)

# Проверка на запуск от имени администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен с правами администратора."
    exit 1
}

# Создание файла лога с явной кодировкой UTF-8
New-Item -Path $LogFile -ItemType File -Force | Out-Null
Set-Content -Path $LogFile -Value "" -Encoding UTF8

function Write-Log {
    param ([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$timestamp - $Message" -ForegroundColor $Color
    "$timestamp - $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

Write-Log "Начало анализа CBS.log..." "Cyan"

# Проверка существования CBS.log
if (-not (Test-Path $CBSLogPath)) {
    Write-Log "Ошибка: Файл CBS.log не найден по пути $CBSLogPath." "Red"
    exit 1
}

# Определение кодировки CBS.log
function Get-FileEncoding {
    param ([string]$Path)
    $bytes = Get-Content -Path $Path -Encoding Byte -TotalCount 4
    if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return "UTF16-LE" }
    elseif ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return "UTF16-BE" }
    elseif ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return "UTF8" }
    else { return "Default" }
}

$cbsEncoding = Get-FileEncoding -Path $CBSLogPath
Write-Log "Обнаружена кодировка CBS.log: $cbsEncoding" "Cyan"

$encodingParam = @{}
switch ($cbsEncoding) {
    "UTF16-LE" { $encodingParam["Encoding"] = "Unicode" }
    "UTF16-BE" { $encodingParam["Encoding"] = "BigEndianUnicode" }
    "UTF8" { $encodingParam["Encoding"] = "UTF8" }
    "Default" { $encodingParam["Encoding"] = "Default" }
}

# Сложные маски для поиска ошибок
$errorPatterns = @(
    "Error.*0x[0-9A-Fa-f]{8}",
    "failed.*HRESULT=0x[0-9A-Fa-f]{8}",
    "missing.*component",
    "corrupt.*file",
    "CSI Payload Corrupt",
    "CBS MUM Missing"
)

# Анализ CBS.log
$foundIssues = @()
$missingComponents = @()

Write-Log "Начало анализа файла CBS.log..." "Cyan"
Get-Content $CBSLogPath @encodingParam | ForEach-Object {
    foreach ($pattern in $errorPatterns) {
        if ($_ -match $pattern) {
            Write-Log "Найдено совпадение: $_" "Yellow"
            $foundIssues += $_
            if ($_ -match "missing.*component.*(\S+)") {
                $missingComponents += $Matches[1]
            } elseif ($_ -match "CBS MUM Missing.*(\S+)") {
                $missingComponents += $Matches[1]
            }
        }
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
        # Используем диапазон от start до end
        $start..$end | ForEach-Object {
            $servers += "vdc01-pep{0:D2}s001" -f $_
        }
    } elseif ($count -gt 0) {
        # Используем количество от start
        $start..($start + $count - 1) | ForEach-Object {
            $servers += "vdc01-pep{0:D2}s001" -f $_
        }
    } else {
        # По умолчанию берем только один сервер от start
        $servers += "vdc01-pep{0:D2}s001" -f $start
    }
    return $servers
}

if ($foundIssues.Count -eq 0) {
    Write-Log "Ошибки или отсутствующие компоненты не найдены." "Green"
} else {
    Write-Log "Обнаружено проблем: $($foundIssues.Count). Отсутствующих компонентов: $($missingComponents.Count)." "Yellow"
    
    # Если компоненты не найдены в логе, прерываем выполнение
    if ($missingComponents.Count -eq 0) {
        Write-Log "Ошибка: Не удалось определить отсутствующие компоненты для восстановления." "Red"
        exit 1
    }

    # Генерация списка серверов с учетом параметров
    $serverList = Get-ServerNames -start $ProjectStart -end $ProjectEnd -count $ProjectCount
    Write-Log "Сгенерирован список серверов: $($serverList -join ', ')" "Cyan"
    $sourceServer = $null
    $jobs = @()

    # Параллельная проверка серверов с учетом WinSxS и servicing\Packages
    foreach ($server in $serverList) {
        $jobs += Start-Job -ScriptBlock {
            param ($server, $missingComponents, $logFile)
            function Write-JobLog {
                param ([string]$Message)
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                "$timestamp - $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
            }
            
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
                            Write-JobLog "Компонент $component найден в $location на $server"
                            $foundComponents += $component
                        } else {
                            $allComponentsPresent = $false
                            Write-JobLog "Компонент $component НЕ найден на $server" "Yellow"
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
    }

    # Ожидание завершения заданий и сбор результатов
    Write-Log "Ожидание проверки серверов..." "Cyan"
    $jobs | Wait-Job | Out-Null
    foreach ($job in $jobs) {
        $result = Receive-Job -Job $job
        if ($null -ne $result -and $null -eq $sourceServer) {
            $sourceServer = $result.Path
            $foundComponents = $result.Components
            Write-Log "Выбран сервер: $sourceServer. Найдены компоненты: $($foundComponents -join ', ')" "Green"
        }
        Remove-Job -Job $job
    }

    if ($null -eq $sourceServer) {
        Write-Log "Ошибка: Не удалось найти сервер с необходимыми компонентами." "Red"
        exit 1
    }

    # Проверка наличия всех компонентов перед запуском DISM
    $missingStill = $missingComponents | Where-Object { $_ -notin $foundComponents }
    if ($missingStill.Count -gt 0) {
        Write-Log "Ошибка: На сервере $sourceServer отсутствуют компоненты: $($missingStill -join ', ')" "Red"
        exit 1
    }

    # Запрос подтверждения перед запуском DISM
    $dismConfirm = Read-Host "Запустить DISM для восстановления с источником $sourceServer? (Y/N)"
    if ($dismConfirm -ne "Y" -and $dismConfirm -ne "y") {
        Write-Log "DISM не запущен — пользователь отказался." "Yellow"
        exit 0
    }

    # Запуск DISM
    Write-Log "Все необходимые компоненты найдены. Запуск DISM с источником $sourceServer..." "Cyan"
    $dismCommand = "DISM /Online /Cleanup-Image /RestoreHealth /Source:$sourceServer /LimitAccess /LogPath:$DISMLogPath"
    
    try {
        $dismResult = Invoke-Expression $dismCommand 2>&1
        $dismResult | ForEach-Object { Write-Log "$_" }
        if ($dismResult -match "The restore operation completed successfully") {
            Write-Log "Восстановление завершено успешно!" "Green"
        } else {
            Write-Log "Восстановление не удалось. См. $DISMLogPath." "Red"
        }
    } catch {
        Write-Log "Ошибка DISM: $_" "Red"
    }

    # Запрос подтверждения перед запуском SFC
    $sfcConfirm = Read-Host "Запустить SFC /scannow для проверки системы? (Y/N)"
    if ($sfcConfirm -ne "Y" -and $sfcConfirm -ne "y") {
        Write-Log "SFC не запущен — пользователь отказался." "Yellow"
        exit 0
    }

    # Запуск SFC
    Write-Log "Запуск SFC /scannow..." "Cyan"
    try {
        $sfcResult = sfc /scannow 2>&1
        $sfcResult | ForEach-Object { Write-Log "$_" }
    } catch {
        Write-Log "Ошибка SFC: $_" "Red"
    }
}

Write-Log "Анализ и восстановление завершены." "Green"
