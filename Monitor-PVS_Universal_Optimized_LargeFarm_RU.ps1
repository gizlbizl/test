# Скрипт для анализа узких мест Citrix PVS 1912 на текущем сервере
# Требуется модуль Citrix PVS SnapIn
# Запуск с правами администратора на любом PVS-сервере

# Импорт модуля PVS
Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction SilentlyContinue

# Рекомендованные значения
$RecommendedThreadsPerPort = 12
$RecommendedBootPauseSeconds = 2
$RecommendedMaxDevicesBooting = 200
$RecommendedMtu = 9000

# Инициализация отчёта
$Report = @("Анализ узких мест Citrix PVS 1912 - $(Get-Date)", "Запущен на сервере: $env:COMPUTERNAME")
$OutputFile = "C:\PVS_Analysis_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Функция для записи в отчёт
function Write-Report {
    param ([string]$Message)
    Write-Host $Message
    $script:Report += $Message
}

# 1. Проверка состояния текущего сервера
Write-Report "`n=== Состояние сервера ==="
$cpu = Get-Counter -Counter "\Processor(_Total)\% Processor Time" -SampleInterval 2 -MaxSamples 3 | 
       Measure-Object -Property CookedValue -Average | Select-Object -ExpandProperty Average
$memory = Get-CimInstance Win32_OperatingSystem
$memoryUsed = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1024 / 1024, 2)
$memoryTotal = [math]::Round($memory.TotalVisibleMemorySize / 1024 / 1024, 2)

Write-Report "CPU: $cpu% | Память: $memoryUsed GB / $memoryTotal GB"
if ($cpu -gt 80) { Write-Report "ВНИМАНИЕ: Высокая нагрузка CPU - возможное узкое место" }
if ($memoryUsed / $memoryTotal -gt 0.8) { Write-Report "ВНИМАНИЕ: Нехватка памяти - возможное узкое место" }

# 2. Анализ сетевых интерфейсов
Write-Report "`n=== Сетевые интерфейсы ==="
$pvsServer = Get-PvsServer -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
$streamingIp = if ($pvsServer) { $pvsServer.Ip } else { "Не определён" }
$nics = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }

foreach ($nic in $nics) {
    $nicIp = $nic.IPAddress[0]
    $nicStats = Get-Counter -Counter "\Network Interface($($nic.Description))\Bytes Total/sec" -SampleInterval 2 -MaxSamples 3
    $nicBytesPerSec = [math]::Round(($nicStats.CounterSamples.CookedValue | Measure-Object -Average).Average / 1024 / 1024, 2)
    
    Write-Report "NIC: $($nic.Description) | IP: $nicIp | Трафик: $nicBytesPerSec MB/s"
    if ($nicIp -eq $streamingIp) {
        Write-Report "  Используется для стриминга (L3)"
        if ($nicBytesPerSec -gt 900) { Write-Report "  ВНИМАНИЕ: Высокая нагрузка на стриминг - узкое место" }
    } else {
        Write-Report "  Используется для vDisk Store или другого трафика"
        if ($nicBytesPerSec -gt 900) { Write-Report "  ВНИМАНИЕ: Высокая нагрузка на NIC - возможное узкое место" }
    }
    
    $mtu = (Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.Description -eq $nic.Description }).MTU
    if ($mtu -and $mtu -ne $RecommendedMtu) {
        Write-Report "  ВНИМАНИЕ: MTU = $mtu (рекомендуется $RecommendedMtu) - потенциальное узкое место"
    }
}

# 3. Мониторинг стриминга
Write-Report "`n=== Стриминг ==="
if ($pvsServer) {
    $udpPorts = $pvsServer.FirstPort..$pvsServer.LastPort
    $activeConnections = Get-NetUDPEndpoint -LocalPort $udpPorts -ErrorAction SilentlyContinue
    $deviceCount = $activeConnections.Count
    Write-Report "Подключённых устройств: $deviceCount"
    if ($deviceCount -gt $RecommendedMaxDevicesBooting) {
        Write-Report "ВНИМАНИЕ: Превышено рекомендуемое количество устройств ($RecommendedMaxDevicesBooting) - узкое место"
    }
} else {
    Write-Report "Не удалось определить порты стриминга"
}

# 4. Проверка доступа к vDisk Store
Write-Report "`n=== vDisk Store ==="
$pvsStore = Get-PvsStore -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pvsStore) {
    $storePath = $pvsStore.Path
    if (Test-Path -Path $storePath) {
        $startTime = Get-Date
        $testFile = Join-Path $storePath "testfile_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        "Тест" | Out-File $testFile -Force
        $endTime = Get-Date
        $latency = [math]::Round(($endTime - $startTime).TotalMilliseconds, 2)
        Remove-Item $testFile -Force
        Write-Report "Доступ к $storePath: Успешно | Задержка: $latency мс"
        if ($latency -gt 50) { Write-Report "ВНИМАНИЕ: Высокая задержка доступа к хранилищу - узкое место" }
    } else {
        Write-Report "ОШИБКА: Нет доступа к $storePath - критическое узкое место"
    }
} else {
    Write-Report "Не удалось определить vDisk Store"
}

# 5. Проверка настроек PVS
Write-Report "`n=== Настройки PVS ==="
$pvsService = Get-Service -Name "StreamService" -ErrorAction SilentlyContinue
if ($pvsService -and $pvsService.Status -eq "Running") {
    Write-Report "Служба PVS: Работает"
    
    if ($pvsServer) {
        $threadsPerPort = $pvsServer.ThreadsPerPort
        $bootPause = $pvsServer.BootPauseSeconds
        $maxDevices = $pvsServer.MaximumDevicesBooting
        
        Write-Report "Threads per port: $threadsPerPort (рекомендуется $RecommendedThreadsPerPort)"
        if ($threadsPerPort -lt $RecommendedThreadsPerPort) { 
            Write-Report "ВНИМАНИЕ: Низкое значение - потенциальное узкое место при стриминге" 
        }
        
        Write-Report "Boot pause seconds: $bootPause (рекомендуется $RecommendedBootPauseSeconds)"
        if ($bootPause -lt $RecommendedBootPauseSeconds) { 
            Write-Report "ВНИМАНИЕ: Низкое значение - риск перегрузки при boot storm" 
        }
        
        Write-Report "Max devices booting: $maxDevices (рекомендуется $RecommendedMaxDevicesBooting)"
        if ($maxDevices -gt $RecommendedMaxDevicesBooting) { 
            Write-Report "ВНИМАНИЕ: Высокое значение - узкое место при массовой загрузке" 
        }
    } else {
        Write-Report "ОШИБКА: Не удалось получить данные о сервере"
    }
} else {
    Write-Report "ОШИБКА: Служба PVS не запущена - критическое узкое место"
}

# Сохранение отчёта
$Report | Out-File $OutputFile -Encoding UTF8
Write-Report "`nОтчёт сохранён в $OutputFile"
