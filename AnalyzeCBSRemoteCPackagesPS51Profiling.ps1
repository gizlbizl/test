# Скрипт для анализа CBS.log и восстановления через DISM с использованием \\server\c$\windows
# Требуются права администратора, совместим с PowerShell 5.1

param (
    [string]$CBSLogPath = "$env:windir\Logs\CBS\CBS.log",
    [string]$DISMLogPath = "$env:windir\Logs\DISM\dism.log",
    [string]$LogFile = "C:\Temp\RepairLog.txt",
    [int]$ProjectCount = 10
)

# Проверка на запуск от имени администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен с правами администратора."
    exit 1
}

# Создание файла лога
New-Item -Path $LogFile -ItemType File -Force | Out-Null

function Write-Log {
    param ([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$timestamp - $Message" -ForegroundColor $Color
    "$timestamp - $Message" | Out-File -FilePath $LogFile -Append
}

Write-Log "Начало анализа CBS.log..." "Cyan"

# Проверка существования CBS.log
if (-not (Test-Path $CBSLogPath)) {
    Write-Log "Ошибка: Файл CBS.log не найден по пути $CBSLogPath." "Red"
    exit 1
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

# Анализ CBS.log с потоковым чтением
$foundIssues = @()
$missingComponents = @()
$lineCount = (Get-Content $CBSLogPath -Raw | Measure-Object -Line).Lines
$progress = 0

Get-Content $CBSLogPath -ReadCount 1000 | ForEach-Object {
    $progress += 1000
    Write-Progress -Activity "Анализ CBS.log" -Status "$progress из $lineCount строк" -PercentComplete (($progress / $lineCount) * 100)
    foreach ($line in $_) {
        foreach ($pattern in $errorPatterns) {
            if ($line -match $pattern) {
                Write-Log "Найдено совпадение: $line" "Yellow"
                $foundIssues += $line
                if ($line -match "missing.*component.*(\S+)") {
                    $missingComponents += $Matches[1]
                } elseif ($line -match "CBS MUM Missing.*(\S+)") {
                    $missingComponents += $Matches[1]
                }
            }
        }
    }
}

# Функция для генерации имен серверов
function Get-ServerNames {
    param ([int]$count = 10)
    $servers = @()
    1..$count | ForEach-Object {
        $servers += "vdc01-pep{0:D2}s001" -f $_
    }
    return $servers
}

if ($foundIssues.Count -eq 0) {
    Write-Log "Ошибки или отсутствующие компоненты не найдены." "Green"
} else {
    Write-Log "Обнаружено проблем: $($foundIssues.Count). Отсутствующих компонентов: $($missingComponents.Count)." "Yellow"
    
    # Генерация списка серверов
    $serverList = Get-ServerNames -count $ProjectCount
    $sourceServer = $null
    $jobs = @()

    # Параллельная проверка серверов с помощью Start-Job и профилированием поиска
    foreach ($server in $serverList) {
        $jobs += Start-Job -ScriptBlock {
            param ($server, $missingComponents, $logFile)
            function Write-JobLog {
                param ([string]$Message)
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                "$timestamp - $Message" | Out-File -FilePath $logFile -Append
            }
            
            if (Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $sourcePath = "\\$server\c$\windows"
                if (Test-Path $sourcePath -ErrorAction SilentlyContinue) {
                    $winSxSPath = "\\$server\c$\windows\WinSxS"
                    $allComponentsPresent = $true
                    
                    foreach ($component in $missingComponents) {
                        # Профилирование поиска с Measure-Command
                        $searchTime = Measure-Command {
                            $found = Get-ChildItem -Path $winSxSPath -Filter "*$component*" -Directory -ErrorAction SilentlyContinue
                        }
                        Write-JobLog "Поиск компонента $component на $server занял $($searchTime.TotalSeconds) секунд"
                        if (-not $found) {
                            $allComponentsPresent = $false
                            break
                        }
                    }
                    
                    if ($allComponentsPresent -or $missingComponents.Count -eq 0) {
                        return $sourcePath
                    }
                }
            }
        } -ArgumentList $server, $missingComponents, $LogFile
    }

    # Ожидание завершения всех заданий и сбор результатов
    Write-Log "Ожидание проверки серверов..." "Cyan"
    $jobs | Wait-Job | Out-Null
    foreach ($job in $jobs) {
        $result = Receive-Job -Job $job
        if ($null -ne $result -and $null -eq $sourceServer) {
            $sourceServer = $result
            Write-Log "Выбран сервер с компонентами: $sourceServer" "Green"
        }
        Remove-Job -Job $job
    }

    if ($null -eq $sourceServer) {
        Write-Log "Ошибка: Не удалось найти сервер с необходимыми компонентами." "Red"
        exit 1
    }

    # Запуск DISM
    Write-Log "Запуск DISM с источником $sourceServer..." "Cyan"
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
