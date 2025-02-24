# Скрипт для анализа текущей конфигурации и узких мест Citrix PVS 1912
# Учитывает только Store текущего сервера, с обработкой ошибок
# Запуск на текущем сервере PVS с правами администратора

# Проверка и импорт модуля PVS
if (-not (Get-PSSnapin -Name "Citrix.PVS.SnapIn" -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
    } catch {
        Write-Host "ОШИБКА: Не удалось загрузить модуль Citrix PVS SnapIn. Запустите с правами администратора или установите модуль."
        exit 1
    }
}

# Инициализация отчёта
$Report = @("Анализ текущей конфигурации и узких мест Citrix PVS 1912 - $(Get-Date)", "Запущен на сервере: $env:COMPUTERNAME")
$OutputFile = "C:\PVS_Analysis_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Функция для записи в отчёт
function Write-Report {
    param ([string]$Message)
    Write-Host $Message
    $script:Report += $Message
}

# 1. Проверка состояния текущего сервера
Write-Report "`n=== Состояние сервера ==="
try {
    $cpu = Get-Counter -Counter "\Processor(_Total)\% Processor Time" -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop | 
           Measure-Object -Property CookedValue -Average | Select-Object -ExpandProperty Average
    $memory = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $memoryUsed = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1MB, 2)
    $memoryTotal = [math]::Round($memory.TotalVisibleMemorySize / 1MB, 2)
    
    Write-Report "CPU: $cpu% | Память: $memoryUsed GB / $memoryTotal GB"
    if ($cpu -gt 80) { Write-Report "ВНИМАНИЕ: Высокая нагрузка CPU - узкое место" }
    if ($memoryUsed / $memoryTotal -gt 0.9) { Write-Report "ВНИМАНИЕ: Критическая нехватка памяти - узкое место" }
    elseif ($memoryUsed / $memoryTotal -gt 0.7) { Write-Report "ПРЕДУПРЕЖДЕНИЕ: Высокое использование памяти" }
} catch {
    Write-Report "ОШИБКА: Не удалось собрать данные о состоянии сервера - $($_.Exception.Message)"
}

# 2. Анализ сетевых интерфейсов
Write-Report "`n=== Сетевые интерфейсы ==="
$pvsServer = Get-PvsServer -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
$streamingIp = if ($pvsServer) { $pvsServer.Ip } else { "Не определён" }
$nics = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }

foreach ($nic in $nics) {
    try {
        $nicIp = $nic.IPAddress[0] -join ", " # Обработка возможного массива IP-адресов
        $nicStats = Get-Counter -Counter "\Network Interface($($nic.Description))\Bytes Total/sec" -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop
        $nicBytesPerSec = [math]::Round(($nicStats.CounterSamples.CookedValue | Measure-Object -Average).Average / 1MB, 2)
        $nicErrors = Get-Counter -Counter "\Network Interface($($nic.Description))\Packets Received Errors" -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop | 
                     Measure-Object -Property CookedValue -Average | Select-Object -ExpandProperty Average
        
        Write-Report "NIC: $($nic.Description) | IP: $nicIp | Трафик: $nicBytesPerSec MB/s | Ошибки: $nicErrors/с"
        if ($nicIp -like "*$streamingIp*") { # Учитывает, что IP может быть в формате массива
            Write-Report "  Используется для стриминга (L3)"
            if ($nicBytesPerSec -gt 900) { Write-Report "  ВНИМАНИЕ: Высокая нагрузка на стриминг - узкое место" }
        } else {
            Write-Report "  Используется для vDisk Store или другого трафика"
            if ($nicBytesPerSec -gt 900) { Write-Report "  ВНИМАНИЕ: Высокая нагрузка на NIC - узкое место" }
        }
        if ($nicErrors -gt 0) { Write-Report "  ВНИМАНИЕ: Обнаружены ошибки сети - потенциальное узкое место" }
        
        $mtu = (Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.Description -eq $nic.Description }).MTU
        if ($mtu) { Write-Report "  MTU: $mtu" }
    } catch {
        Write-Report "ОШИБКА: Не удалось собрать данные для NIC $($nic.Description) - $($_.Exception.Message)"
    }
}

# 3. Мониторинг стриминга
Write-Report "`n=== Стриминг ==="
if ($pvsServer) {
    try {
        $udpPorts = $pvsServer.FirstPort..$pvsServer.LastPort
        $activeConnections = Get-NetUDPEndpoint -LocalPort $udpPorts -ErrorAction Stop
        $deviceCount = $activeConnections.Count
        Write-Report "Порты стриминга: $($pvsServer.FirstPort)-$($pvsServer.LastPort)"
        Write-Report "Подключённых устройств: $deviceCount"
        if ($deviceCount -gt 250) { Write-Report "ВНИМАНИЕ: Высокое количество устройств - потенциальное узкое место" }
    } catch {
        Write-Report "ОШИБКА: Не удалось проверить стриминг - $($_.Exception.Message)"
    }
} else {
    Write-Report "ОШИБКА: Не удалось определить порты стриминга - данные сервера недоступны"
}

# 4. Проверка доступа к vDisk Store текущего сервера
Write-Report "`n=== vDisk Store текущего сервера ==="
if ($pvsServer) {
    try {
        # Получаем сайт текущего сервера
        $siteId = $pvsServer.SiteId
        
        # Находим Store, связанный с текущим сервером
        $pvsStore = Get-PvsStore | Where-Object { 
            (Get-PvsServerStore -StoreId $_.StoreId -ErrorAction Stop).ServerName -contains $env:COMPUTERNAME 
        } | Select-Object -First 1
        
        if ($pvsStore) {
            $storePath = $pvsStore.Path
            Write-Report "Путь к vDisk Store: $storePath"
            if (Test-Path -Path $storePath -ErrorAction Stop) {
                try {
                    $startTime = Get-Date
                    $testFile = Join-Path $storePath "testfile_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
                    "Тест" | Out-File $testFile -Force -ErrorAction Stop
                    $endTime = Get-Date
                    $latency = [math]::Round(($endTime - $startTime).TotalMilliseconds, 2)
                    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
                    Write-Report "Доступ: Успешно | Задержка: $latency мс"
                    if ($latency -gt 100) { Write-Report "ВНИМАНИЕ: Высокая задержка доступа к хранилищу - узкое место" }
                    elseif ($latency -gt 50) { Write-Report "ПРЕДУПРЕЖДЕНИЕ: Заметная задержка доступа" }
                } catch {
                    Write-Report "ОШИБКА: Не удалось выполнить тест доступа к $storePath - $($_.Exception.Message)"
                }
            } else {
                Write-Report "ОШИБКА: Нет доступа к $storePath - критическое узкое место"
            }
        } else {
            Write-Report "Не удалось определить vDisk Store текущего сервера"
        }
    } catch {
        Write-Report "ОШИБКА: Не удалось обработать Store - $($_.Exception.Message)"
    }
} else {
    Write-Report "Не удалось получить информацию о сервере"
}

# 5. Проверка настроек PVS
Write-Report "`n=== Настройки PVS ==="
$pvsService = Get-Service -Name "StreamService" -ErrorAction SilentlyContinue
if ($pvsService -and $pvsService.Status -eq "Running") {
    Write-Report "Служба PVS: Работает"
    
    if ($pvsServer) {
        Write-Report "Threads per port: $($pvsServer.ThreadsPerPort)"
        Write-Report "Boot pause seconds: $($pvsServer.BootPauseSeconds)"
        Write-Report "Max devices booting: $($pvsServer.MaximumDevicesBooting)"
        if ($pvsServer.ThreadsPerPort -lt 8) { 
            Write-Report "ВНИМАНИЕ: Низкое значение Threads per port - потенциальное узкое место при стриминге" 
        }
        if ($pvsServer.BootPauseSeconds -eq 0) { 
            Write-Report "ВНИМАНИЕ: Boot pause отключён - риск перегрузки при массовой загрузке" 
        }
        if ($pvsServer.MaximumDevicesBooting -gt 250) { 
            Write-Report "ВНИМАНИЕ: Высокое значение Max devices - узкое место при boot storm" 
        }
    } else {
        Write-Report "ОШИБКА: Не удалось получить данные о сервере"
    }
} else {
    Write-Report "ОШИБКА: Служба PVS не запущена - критическое узкое место"
}

# 6. Сохранение отчёта с проверкой пути
try {
    $Report | Out-File $OutputFile -Encoding UTF8 -ErrorAction Stop
    Write-Report "`nОтчёт сохранён в $OutputFile"
} catch {
    Write-Report "ОШИБКА: Не удалось сохранить отчёт в $OutputFile - $($_.Exception.Message)"
    # Попробуем сохранить в другую локацию
    $altOutputFile = ".\PVS_Analysis_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    try {
        $Report | Out-File $altOutputFile -Encoding UTF8 -ErrorAction Stop
        Write-Report "Отчёт сохранён в $altOutputFile как резервный вариант"
    } catch {
        Write-Report "ОШИБКА: Не удалось сохранить отчёт в резервной локации - $($_.Exception.Message)"
    }
}
