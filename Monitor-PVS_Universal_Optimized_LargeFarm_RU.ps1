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
    # Попробуем получить CPU через Get-Counter
    $cpu = 0
    try {
        $cpuSamples = Get-Counter -Counter "\Processor(_Total)\% Processor Time" -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop
        if ($cpuSamples.CounterSamples -and $cpuSamples.CounterSamples.CookedValue) {
            $cpu = [math]::Round(($cpuSamples.CounterSamples.CookedValue | Measure-Object -Average).Average, 2)
        }
    } catch {
        Write-Report "ПРЕДУПРЕЖДЕНИЕ: Не удалось получить данные CPU через Get-Counter, используется резервный метод"
        # Резервный метод через WMI (как в скриптах Guy Leech)
        $cpuWmi = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue | 
                  Measure-Object -Property PercentProcessorTime -Average | Select-Object -ExpandProperty Average
        if ($cpuWmi) { $cpu = [math]::Round($cpuWmi, 2) }
    }
    
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
$streamingIp = if ($pvsServer -and $pvsServer.Ip) { $pvsServer.Ip } else { "Не определён" }

# Получаем все сетевые интерфейсы с IP-адресами и фильтруем только активные
$nics = Get-CimInstance Win32_NetworkAdapterConfiguration | 
        Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -and $_.Description }

foreach ($nic in $nics) {
    try {
        # Получаем описание и IP-адреса интерфейса
        $nicDesc = $nic.Description
        $nicIps = $nic.IPAddress -join ", " # Обработка массива IP-адресов
        
        # Попробуем получить данные через Get-Counter
        $nicBytesPerSec = 0
        $nicErrors = 0
        try {
            # Экранируем и нормализуем описание интерфейса для корректной работы с Get-Counter
            $escapedDesc = $nicDesc -replace '[^a-zA-Z0-9\s#]', '' -replace '\s+', ' ' -replace '#', ' '
            $counterPathBytes = "\Network Interface($escapedDesc)\Bytes Total/sec"
            $counterPathErrors = "\Network Interface($escapedDesc)\Packets Received Errors"
            
            # Проверяем, существует ли счётчик, перед выполнением Get-Counter
            $counterExists = Get-Counter -ListSet "Network Interface" -ErrorAction SilentlyContinue | 
                            ForEach-Object { $_.PathsWithInstances } | 
                            Where-Object { $_ -like "*$escapedDesc*" }
            if ($counterExists) {
                $nicStats = Get-Counter -Counter $counterPathBytes -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop
                if ($nicStats.CounterSamples -and $nicStats.CounterSamples.CookedValue) {
                    $nicBytesPerSec = [math]::Round(($nicStats.CounterSamples.CookedValue | Measure-Object -Average).Average / 1MB, 2)
                }
                
                $errorsStats = Get-Counter -Counter $counterPathErrors -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop
                if ($errorsStats.CounterSamples -and $errorsStats.CounterSamples.CookedValue) {
                    $nicErrors = [math]::Round(($errorsStats.CounterSamples.CookedValue | Measure-Object -Average).Average, 2)
                }
            } else {
                Write-Report "ПРЕДУПРЕЖДЕНИЕ: Счётчик не найден для NIC $nicDesc, используется резервный метод"
            }
        } catch {
            Write-Report "ПРЕДУПРЕЖДЕНИЕ: Не удалось получить данные сети через Get-Counter для NIC $nicDesc, используется резервный метод"
        }
        
        # Резервный метод через WMI (проверяем несколько вариантов)
        if ($nicBytesPerSec -eq 0 -or $nicErrors -eq 0) {
            try {
                # Пробуем найти данные через Win32_PerfFormattedData_Tcpip_NetworkInterface
                $wmiNet = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -Filter "Name='$($nicDesc)'" -ErrorAction SilentlyContinue
                if (-not $wmiNet) {
                    # Альтернативный фильтр, если имя не совпадает
                    $wmiNet = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue | 
                              Where-Object { $_.Name -like "*$($nicDesc)*" }
                }
                if ($wmiNet) {
                    $nicBytesPerSec = [math]::Round($wmiNet.BytesTotalPersec / 1MB, 2)
                    $nicErrors = [math]::Round($wmiNet.PacketsReceivedErrors, 2)
                } else {
                    # Ещё один резервный метод через Win32_NetworkAdapter
                    $adapter = Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.Name -like "*$($nicDesc)*" }
                    if ($adapter) {
                        Write-Report "ПРЕДУПРЕЖДЕНИЕ: Используется базовый метод через Win32_NetworkAdapter для NIC $nicDesc"
                        $nicBytesPerSec = 0 # Без точных данных, только индикация
                        $nicErrors = 0
                    }
                }
            } catch {
                Write-Report "ПРЕДУПРЕЖДЕНИЕ: Резервный метод через WMI также не сработал для NIC $nicDesc"
            }
        }
        
        # Определяем, является ли интерфейс стримингом, сравнивая IP
        $isStreamingNic = $false
        if ($streamingIp -ne "Не определён") {
            # Разбиваем IP на части для точного сравнения
            $streamingIpParts = $streamingIp -split '\.'
            foreach ($ip in ($nic.IPAddress | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' })) {
                $nicIpParts = $ip -split '\.'
                if ($streamingIpParts[0..2] -join '.' -eq $nicIpParts[0..2] -join '.') {
                    $isStreamingNic = $true
                    break
                }
            }
        }
        
        Write-Report "NIC: $nicDesc | IP: $nicIps | Трафик: $nicBytesPerSec MB/s | Ошибки: $nicErrors/с"
        if ($isStreamingNic) {
            Write-Report "  Используется для стриминга (L3)"
            if ($nicBytesPerSec -gt 900) { Write-Report "  ВНИМАНИЕ: Высокая нагрузка на стриминг - узкое место" }
        } else {
            Write-Report "  Используется для vDisk Store или другого трафика"
            if ($nicBytesPerSec -gt 900) { Write-Report "  ВНИМАНИЕ: Высокая нагрузка на NIC - узкое место" }
        }
        if ($nicErrors -gt 0) { Write-Report "  ВНИМАНИЕ: Обнаружены ошибки сети - потенциальное узкое место" }
        
        $mtu = (Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.Description -eq $nicDesc -or $_.Name -like "*$nicDesc*" }).MTU
        if ($mtu) { Write-Report "  MTU: $mtu" }
    } catch {
        Write-Report "ОШИБКА: Не удалось собрать данные для NIC $nicDesc - $($_.Exception.Message)"
    }
}

# 3. Проверка доступа к vDisk Store текущего сервера
Write-Report "`n=== vDisk Store текущего сервера ==="
if ($pvsServer) {
    try {
        # Получаем ID сайта текущего сервера
        $siteId = $pvsServer.SiteId
        
        # Получаем все Store, связанные с текущим сервером
        $serverStores = Get-PvsServerStore -ServerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
        if ($serverStores -and $serverStores.StoreId) {
            # Берем первый Store, связанный с сервером
            $storeId = $serverStores[0].StoreId
            $pvsStore = Get-PvsStore -StoreId $storeId -ErrorAction SilentlyContinue
            
            if ($pvsStore -and $pvsStore.Path) {
                $storePath = $pvsStore.Path
                Write-Report "Путь к vDisk Store: $storePath"
                # Проверяем доступность пути через Test-Path с обработкой UNC-путей
                if (Test-Path -Path $storePath -ErrorAction SilentlyContinue) {
                    try {
                        # Проверяем, есть ли права на запись, создавая временную директорию
                        $testDir = Join-Path $storePath "test"
                        if (-not (Test-Path $testDir -ErrorAction SilentlyContinue)) {
                            New-Item -Path $testDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        $startTime = Get-Date
                        $testFile = Join-Path $testDir "testfile_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
                        "Тест" | Out-File $testFile -Force -ErrorAction SilentlyContinue
                        $endTime = Get-Date
                        $latency = [math]::Round(($endTime - $startTime).TotalMilliseconds, 2)
                        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
                        Remove-Item $testDir -Force -ErrorAction SilentlyContinue
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
                Write-Report "Не удалось найти vDisk Store для StoreId $storeId"
            }
        } else {
            Write-Report "Не удалось определить Store, связанные с текущим сервером"
        }
    } catch {
        Write-Report "ОШИБКА: Не удалось обработать Store - $($_.Exception.Message)"
    }
} else {
    Write-Report "Не удалось получить информацию о сервере"
}

# 4. Проверка настроек PVS
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

# 5. Сохранение отчёта с проверкой пути
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
