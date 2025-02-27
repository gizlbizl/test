# Параметры скрипта
param (
    [string]$CBSLogPath = "$env:SystemRoot\Logs\CBS\CBS.log",  # Путь к локальному CBS.log
    [string]$LogDir = "C:\Temp",                               # Каталог для логов
    [string]$Encoding = "UTF8",                                # Кодировка файла
    [int]$MaxLines = 10000,                                    # Максимум строк для анализа
    [string]$DateFilter = $null,                               # Фильтр по дате
    [switch]$Quiet = $false,                                   # Тихий режим
    [switch]$RemoteComponentSearch = $false,                   # Искать компоненты на удалённых серверах
    [string]$ServerMask = "vdc01-pep##s001",                  # Маска для серверов
    [int]$ServerRangeStart = 1,                                # Начало диапазона серверов
    [int]$ServerRangeEnd = 10                                  # Конец диапазона серверов
)

# Проверка прав администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен с правами администратора."
    exit 1
}

# Инициализация логов
$logBaseDir = Join-Path $LogDir "CBSAnalysisLogs"
$startTime = Get-Date
try {
    if (-not (Test-Path $logBaseDir)) {
        New-Item -Path $logBaseDir -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Error "Не удалось создать директорию для логов '$logBaseDir': $($_.Exception.Message)"
    exit 1
}
$logFile = Join-Path $logBaseDir "CBSAnalysis_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
try {
    New-Item -Path $logFile -ItemType File -Force | Out-Null
} catch {
    Write-Error "Не удалось создать файл лога '$logFile': $($_.Exception.Message)"
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
    if (-not $Quiet) { Write-Host $logEntry -ForegroundColor $Color }
    try {
        $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Error "Ошибка записи в лог: $($_.Exception.Message)"
    }
}

Write-Log "Начало анализа CBS.log..." "INFO" "Cyan"
Write-Log "Версия PowerShell: $($PSVersionTable.PSVersion)" "INFO" "Cyan"

# Установка кодировки
$encodingParam = @{}
switch ($Encoding.ToUpper()) {
    "UNICODE" { $encodingParam["Encoding"] = "Unicode" }
    "BIGENDIANUNICODE" { $encodingParam["Encoding"] = "BigEndianUnicode" }
    "UTF8" { $encodingParam["Encoding"] = "UTF8" }
    "DEFAULT" { $encodingParam["Encoding"] = "Default" }
    default { $encodingParam["Encoding"] = "UTF8"; Write-Log "Неизвестная кодировка, используется UTF8." "WARNING" "Yellow" }
}
Write-Log "Используется кодировка: $($encodingParam['Encoding'])" "INFO" "Cyan"

# Паттерн для поиска пакетов
$componentPattern = "\(p\)\s*CBS\s*Catalog\s*Missing\s*([A-Za-z0-9_]+_for_[A-Za-z0-9]+~[A-Za-z0-9]+~[A-Za-z0-9]+~~[\d\.]+)"

# Анализ локального CBS.log
$foundIssues = @()
$missingComponents = @()

if (-not (Test-Path $CBSLogPath)) {
    Write-Log "Ошибка: Файл CBS.log не найден по пути '$CBSLogPath'." "ERROR" "Red"
    exit 1
}

$fileSize = (Get-Item $CBSLogPath).Length / 1MB
if ($fileSize -gt 50) {
    Write-Log "Размер файла: $fileSize MB. Обработка может занять время." "WARNING" "Yellow"
}

Write-Log "Поиск последней строки 'Checking System Update Readiness'..." "INFO" "Cyan"
try {
    $startLines = Select-String -Path $CBSLogPath -Pattern "Checking\s*System\s*Update\s*Readiness" -Encoding $encodingParam.Encoding -ErrorAction Stop
    if (-not $startLines) {
        Write-Log "Строка 'Checking System Update Readiness' не найдена." "ERROR" "Red"
        exit 1
    }

    $lastStartLine = $startLines | Sort-Object LineNumber -Descending | Select-Object -First 1
    $startLineNumber = $lastStartLine.LineNumber
    Write-Log "Найдена строка: '$($lastStartLine.Line)' (строка $startLineNumber)" "INFO BORDEAUX" "Green"

    $reader = [System.IO.StreamReader]::new($CBSLogPath, [System.Text.Encoding]::$($encodingParam["Encoding"]))
    $lineNumber = 0
    $relevantLines = @()
    while (($line = $reader.ReadLine()) -ne $null -and $relevantLines.Count -lt $MaxLines) {
        $lineNumber++
        if ($lineNumber -le $startLineNumber) { continue }
        if ($line -match "\(p\)") {
            if ($DateFilter -and [datetime]::ParseExact($line.Substring(0,19), "yyyy-MM-dd HH:mm:ss", $null) -lt [datetime]$DateFilter) { continue }
            $relevantLines += $line
        }
    }
    $reader.Close()

    Write-Log "Найдено релевантных строк: $($relevantLines.Count)" "INFO" "Cyan"
    $progress = 0

    foreach ($line in $relevantLines) {
        $progress++
        Write-Progress -Activity "Анализ строк" -Status "$progress из $($relevantLines.Count)" -PercentComplete (($progress / $relevantLines.Count) * 100)
        if ($line -match $componentPattern) {
            Write-Log "Найден пакет: '$line'" "WARNING" "Yellow"
            $foundIssues += $line
            $packageName = $Matches[1].Trim()
            if ($packageName -match "[A-Za-z0-9]") {
                Write-Log "Извлечён: '$packageName'" "INFO" "Green"
                $missingComponents += $packageName
            }
        }
    }
} catch {
    Write-Log "Ошибка анализа: $($_.Exception.Message). Позиция: $($_.InvocationInfo.PositionMessage)" "ERROR" "Red"
    exit 1
}
Write-Progress -Activity "Анализ строк" -Completed

$missingComponents = $missingComponents | Sort-Object -Unique | Where-Object { $_ }

if ($foundIssues.Count -eq 0) {
    Write-Log "Отсутствующие пакеты не найдены." "INFO" "Green"
} else {
    Write-Log "Обнаружено проблем: $($foundIssues.Count). Уникальных пакетов: $($missingComponents.Count)" "WARNING" "Yellow"
    if ($missingComponents.Count -eq 0) {
        Write-Log "Не удалось извлечь пакеты." "ERROR" "Red"
        exit 1
    }
    Write-Log "Список отсутствующих пакетов:" "INFO" "Cyan"
    $missingComponents | ForEach-Object { Write-Log "  - $_" "INFO" "Cyan" }

    $csvPath = Join-Path $logBaseDir "MissingPackages_Local_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $missingComponents | Select-Object @{Name="Package";Expression={$_}} | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log "Список сохранён в: $csvPath" "INFO" "Green"
}

# Поиск компонентов на удалённых серверах и восстановление
if ($RemoteComponentSearch) {
    Write-Log "RemoteComponentSearch активирован. Проверка количества компонентов: $($missingComponents.Count)" "INFO" "Cyan"
    if ($missingComponents.Count -eq 0) {
        Write-Log "Нет компонентов для поиска на удалённых серверах." "WARNING" "Yellow"
    } else {
        Write-Log "Поиск компонентов на удалённых серверах по маске '$ServerMask' ($ServerRangeStart-$ServerRangeEnd)..." "INFO" "Cyan"
        for ($i = $ServerRangeStart; $i -le $ServerRangeEnd; $i++) {
            $serverNum = "{0:D2}" -f $i
            $serverName = $ServerMask -replace "##", $serverNum
            Write-Log "Проверка сервера: $serverName" "INFO" "Cyan"
            if (Test-Connection -ComputerName $serverName -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                Write-Log "Сервер $serverName доступен. Поиск компонентов..." "INFO" "Green"
                $searchPaths = @(
                    "\\$serverName\c$\Windows\winsxs",
                    "\\$serverName\c$\Windows\Servicing\Packages"
                )
                try {
                    $foundComponents = @()
                    $foundPaths = @{}
                    foreach ($component in $missingComponents) {
                        foreach ($path in $searchPaths) {
                            Write-Log "Поиск '$component' в $path..." "INFO" "Cyan"
                            $searchPattern = "*$component*"
                            $foundFiles = Get-ChildItem -Path $path -Recurse -Directory -Filter $searchPattern -ErrorAction SilentlyContinue
                            if ($foundFiles) {
                                Write-Log "[$serverName] Найден компонент '$component' в:" "INFO" "Green"
                                $foundFiles | ForEach-Object { 
                                    Write-Log "[$serverName]   - $($_.FullName)" "INFO" "Green" 
                                    $foundPaths[$component] = $_.Parent.FullName
                                }
                                $foundComponents += $component
                                break
                            }
                        }
                    }
                    if ($foundComponents.Count -eq 0) {
                        Write-Log "[$serverName] Компоненты не найдены." "WARNING" "Yellow"
                    } else {
                        $csvPath = Join-Path $logBaseDir "FoundComponents_${serverName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                        $foundComponents | Select-Object @{Name="Component";Expression={$_}} | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                        Write-Log "[$serverName] Найденные компоненты сохранены в: $csvPath" "INFO" "Green"

                        # Запрос подтверждения для DISM
                        Write-Log "[$serverName] Обнаружены компоненты. Запустить DISM /RestoreHealth с источником $serverName? (Y/N)" "INFO" "Cyan"
                        $response = Read-Host "Введите Y для продолжения"
                        if ($response -eq "Y" -or $response -eq "y") {
                            Write-Log "[$serverName] Запуск DISM /Online /RestoreHealth..." "INFO" "Cyan"
                            $sourcePath = ($foundPaths.Values | Select-Object -First 1) -replace "\\\\$serverName\\c\$", ""
                            $dismCommand = "DISM /Online /RestoreHealth /Source:\\$serverName\c$\$sourcePath /LimitAccess"
                            Write-Log "[$serverName] Выполняется: $dismCommand" "INFO" "Cyan"
                            $dismResult = Invoke-Expression $dismCommand 2>&1
                            $dismResult | ForEach-Object { Write-Log "[$serverName] DISM: $_" "INFO" "Green" }
                            if ($LASTEXITCODE -eq 0) {
                                Write-Log "[$serverName] DISM успешно завершён." "INFO" "Green"
                            } else {
                                Write-Log "[$serverName] Ошибка DISM. Код: $LASTEXITCODE" "ERROR" "Red"
                            }

                            # Запрос подтверждения для SFC
                            Write-Log "[$serverName] Запустить SFC /ScanNow? (Y/N)" "INFO" "Cyan"
                            $sfcResponse = Read-Host "Введите Y для продолжения"
                            if ($sfcResponse -eq "Y" -or $sfcResponse -eq "y") {
                                Write-Log "[$serverName] Запуск SFC /ScanNow..." "INFO" "Cyan"
                                $sfcResult = Invoke-Expression "SFC /ScanNow" 2>&1
                                $sfcResult | ForEach-Object { Write-Log "[$serverName] SFC: $_" "INFO" "Green" }
                                if ($LASTEXITCODE -eq 0) {
                                    Write-Log "[$serverName] SFC успешно завершён." "INFO" "Green"
                                } else {
                                    Write-Log "[$serverName] Ошибка SFC. Код: $LASTEXITCODE" "ERROR" "Red"
                                }
                            } else {
                                Write-Log "[$serverName] SFC пропущен." "INFO" "Yellow"
                            }
                        } else {
                            Write-Log "[$serverName] DISM пропущен." "INFO" "Yellow"
                        }
                    }
                } catch {
                    Write-Log "[$serverName] Ошибка поиска: $($_.Exception.Message)" "ERROR" "Red"
                }
            } else {
                Write-Log "Сервер $serverName недоступен. Пропущен." "WARNING" "Yellow"
            }
        }
    }
} else {
    Write-Log "RemoteComponentSearch не активирован. Используйте -RemoteComponentSearch для поиска на удалённых серверах." "INFO" "Yellow"
}

$endTime = Get-Date
$executionTime = $endTime - $startTime
Write-Log "Анализ завершён. Время: $($executionTime.TotalSeconds) сек" "INFO" "Green"
