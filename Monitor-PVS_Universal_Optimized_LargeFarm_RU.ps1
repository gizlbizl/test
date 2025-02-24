<#
.SYNOPSIS
Оптимизированный универсальный скрипт для мониторинга и анализа производительности серверов Citrix Provisioning Services (PVS) с проверкой Event Viewer, логированием и PVS командлетами для больших ферм с улучшенной обработкой ошибок.

.DESCRIPTION
Данный скрипт автоматически определяет конфигурацию любого PVS-сервера (количество ядер, RAM, сетевые интерфейсы, количество Target Devices, версию PVS),
собирает оптимизированные метрики производительности (CPU, RAM, кэш, сеть, потоки, I/O),
использует оптимизированные PVS-командлеты для больших ферм с кэшированием и фильтрацией,
динамически адаптирует пороги, интервалы и метрики под среду, проверяет логи Event Viewer на ошибки PVS,
записывает результаты в лог-файлы (CSV и текстовый) с детальным логированием ошибок,
выводя данные в консоль на русском языке. Подходит для любых версий PVS с разделением сетей L3 (Target Devices) и L2 (NetApp CIFS) в больших фермах.

.ПАРАМЕТРЫ
-LogPath: Путь для сохранения логов (по умолчанию: "C:\PVS_Logs", адаптируется под доступное место на диске).
-RunTimeMinutes: Время работы скрипта в минутах (по умолчанию: 30, адаптируется под нагрузку).
-CacheDurationMinutes: Время кэширования данных PVS в минутах (по умолчанию: 5, для больших ферм).

.ПРИМЕРЫ
.\Monitor-PVS_Universal_Optimized_LargeFarm_ErrorHandling_RU_Final.ps1 -LogPath "D:\PVS_Logs" -RunTimeMinutes 45 -CacheDurationMinutes 10
Запустит оптимизированный мониторинг для больших ферм с логами в D:\PVS_Logs, длительностью 45 минут и кэшированием данных на 10 минут.

.ЗАМЕЧАНИЯ
- Требуются права администратора для работы с PerfMon, Event Viewer и PVS командлетами.
- Убедитесь, что модуль Citrix.PVS.SnapIn установлен (Register-PSSnapin Citrix.PVS.SnapIn).
- Скрипт автоматически определяет все параметры среды и адаптирует пороги и интервалы для больших ферм.
- Скрипт проверяет журналы "Application" и "System" на события от Citrix PVS (идентификаторы событий 1000-1999 или источник "Citrix PVS").
- Логи очищаются автоматически для файлов старше 7 дней.
- Для больших ферм рекомендуется увеличить CacheDurationMinutes (до 10–30 минут) и SampleInterval (до 20–30 секунд).

#>

# Параметры скрипта с локализацией
Param (
    [string]$LogPath = "C:\PVS_Logs", # Путь для сохранения логов, адаптируется под доступное место
    [int]$RunTimeMinutes = 30,         # Время работы скрипта в минутах, адаптируется под нагрузку
    [int]$CacheDurationMinutes = 5     # Время кэширования данных PVS в минутах
)

# Функция для логирования ошибок в текстовый файл
function Write-ErrorLog {
    param ([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] Ошибка: $Message" | Out-File -FilePath $TextLogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Автоматическое определение пути для логов с учётом места на диске
try {
    $drives = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | Where-Object { $_.FreeSpace -gt 10GB }
    if ($drives) {
        $bestDrive = $drives | Sort-Object -Property FreeSpace -Descending | Select-Object -First 1
        $LogPath = Join-Path $bestDrive.DeviceID "PVS_Logs"
        if (-not (Test-Path $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -ErrorAction Stop | Out-Null
            Write-Host "Автоматически выбран путь для логов: $LogPath (доступно места: $($bestDrive.FreeSpace/1GB) ГБ)" -ForegroundColor Green
        }
    }
    else {
        Write-Host "Предупреждение: Недостаточно места на дисках для логов. Используется $LogPath." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Ошибка при определении пути для логов: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка при определении пути для логов: $($_.Exception.Message)"
    $LogPath = "C:\PVS_Logs"  # Резервный путь
}

# Автоматическое создание имени файла
$LogFile = Join-Path $LogPath "PVS_Performance_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$TextLogFile = "$LogFile.txt"

# Создание CSV-файла с заголовками
try {
    "Timestamp,CPU_Usage_Percent,Processor_Queue,Available_Memory_MB,Cache_Bytes_MB,Copy_Read_Hits_Percent,L2_Bytes_Received_Mbps,L2_Bytes_Sent_Mbps,L3_Bytes_Received_Mbps,L3_Bytes_Sent_Mbps,Thread_Count,Disk_Reads_sec,Disk_Queue_Length,PVS_Server_Status,PVS_Threads,PVS_Cache_Usage,PVS_Device_Count,Server_Cores,Server_RAM_GB,Server_Network_Speed_Gbps,PVS_Version,Analysis" | 
    Out-File $LogFile -Encoding UTF8
}
catch {
    Write-Host "Ошибка при создании CSV-файла логов: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка при создании CSV-файла логов: $($_.Exception.Message)"
}

# Регистрация PVS Snap-In (если не зарегистрирован)
try {
    if (-not (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
        Write-Host "Модуль Citrix PVS Snap-In успешно зарегистрирован." -ForegroundColor Green
    }
}
catch {
    Write-Host "Ошибка при регистрации PVS Snap-In: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка при регистрации PVS Snap-In: $($_.Exception.Message)"
    exit
}

# Кэш для данных PVS, оптимизирован для больших ферм
$pvsCache = $null
$pvsCacheTimestamp = $null

function Get-PVSCachedData {
    param ([int]$CacheDurationMinutes)
    $currentTime = Get-Date
    if ($pvsCache -and $pvsCacheTimestamp -and ($currentTime - $pvsCacheTimestamp).TotalMinutes -le $CacheDurationMinutes) {
        return $pvsCache
    }
    else {
        try {
            $pvsServer = Get-PVSServer -Name $env:COMPUTERNAME -ErrorAction Stop
            $pvsDevices = (Get-PVSTargetDevice -Server $pvsServer -ErrorAction Stop | Where-Object { $_.Status -eq "Active" } | Measure-Object).Count  # Фильтрация активных устройств
            $pvsData = [PSCustomObject]@{
                Server = $pvsServer
                DeviceCount = $pvsDevices
                Threads = $pvsServer.ThreadCount
                CacheUsage = $pvsServer.CacheSizeMB
                Status = $pvsServer.Status
                Version = $pvsServer.Version
            }
            $global:pvsCache = $pvsData
            $global:pvsCacheTimestamp = $currentTime
            return $pvsData
        }
        catch {
            Write-Host "Ошибка при кэшировании данных PVS: $($_.Exception.Message)" -ForegroundColor Red
            Write-ErrorLog "Ошибка при кэшировании данных PVS: $($_.Exception.Message)"
            return $null
        }
    }
}

# Автоматическое определение конфигурации сервера
try {
    $serverCores = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property NumberOfCores -Sum -ErrorAction Stop).Sum  # Количество ядер
    $serverRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum -ErrorAction Stop).Sum / 1GB, 2)  # RAM в ГБ
}
catch {
    Write-Host "Ошибка при определении конфигурации сервера: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка при определении конфигурации сервера: $($_.Exception.Message)"
    $serverCores = 1  # Значение по умолчанию
    $serverRAM = 4  # Значение по умолчанию
}

# Определение скорости сети (L3 и L2), универсально
try {
    $networkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 2
    $L3Adapter = $networkAdapters | Select-Object -First 1  # L3 (Target Devices)
    $L2Adapter = $networkAdapters | Select-Object -Skip 1 -First 1  # L2 (NetApp CIFS)
    if (!$L3Adapter -or !$L2Adapter) {
        throw "Не удалось найти сетевые интерфейсы"
    }
    $serverNetworkSpeed = ($L3Adapter.LinkSpeed -replace " Gbps", "")  # Скорость сети, адаптируется
    if (!$serverNetworkSpeed) { $serverNetworkSpeed = 1 }  # Значение по умолчанию, если не определено
    Write-Host "L3 (Устройства Target): $($L3Adapter.Name), Скорость: $serverNetworkSpeed Гбит/с" -ForegroundColor Green
    Write-Host "L2 (NetApp CIFS): $($L2Adapter.Name), Скорость: $serverNetworkSpeed Гбит/с" -ForegroundColor Green
}
catch {
    Write-Host "Ошибка при определении сетевых интерфейсов: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка при определении сетевых интерфейсов: $($_.Exception.Message)"
    $L3Adapter = $null
    $L2Adapter = $null
    $serverNetworkSpeed = 1  # Значение по умолчанию
}

# Динамические параметры, адаптированные под любую среду для больших ферм
try {
    $sampleInterval = [math]::Max(5, [math]::Min(30, [math]::Round($serverCores / 2, 0)))  # Интервал от 5 до 30 секунд, адаптирован под количество ядер
    $runTimeMinutes = [math]::Max(15, [math]::Min(240, [math]::Round($pvsDevices / 5, 0)))  # Время работы от 15 до 240 минут, адаптировано под количество устройств
    $cpuThreshold = [math]::Min(70, 100 - ($serverCores * 5))  # Порог CPU, сниженный для текущих ядер (макс. 70%)
    $queueThreshold = [math]::Min(10, $serverCores)  # Порог очереди задач, равный количеству ядер или меньше
    $memoryThreshold = [math]::Max(2000, $serverRAM * 1024 * 0.1)  # 10% от RAM в МБ (мин. 2000 МБ)
    $pvsData = Get-PVSCachedData -CacheDurationMinutes $CacheDurationMinutes
    if ($pvsData) {
        $pvsDevices = $pvsData.DeviceCount
        $pvsServerStatus = $pvsData.Status
        $pvsThreads = $pvsData.Threads
        $pvsCacheUsage = $pvsData.CacheUsage
        $pvsVersion = $pvsData.Version
    }
    else {
        $pvsDevices = 0
        $pvsServerStatus = "Неизвестно"
        $pvsThreads = 0
        $pvsCacheUsage = 0
        $pvsVersion = "Неизвестно"
    }
    $cacheHitsThreshold = 80 + ($pvsDevices / 1000)  # Адаптировано под количество устройств (макс. 90% для больших сред)
    $networkThreshold = [math]::Max(200, $serverNetworkSpeed * 400)  # Адаптировано под скорость сети (мин. 200 Мбит/с)
    $diskQueueThreshold = 1  # Низкий порог для стабильности

    Write-Host "Автоматически определено: $serverCores ядер, $serverRAM ГБ RAM, $serverNetworkSpeed Гбит/с сети, $pvsDevices устройств PVS, версия PVS: $pvsVersion" -ForegroundColor Green
    Write-Host "Динамические параметры: Интервал = $sampleInterval сек, Время работы = $runTimeMinutes мин, Пороги: CPU=$cpuThreshold%, Очередь=$queueThreshold, Память=$memoryThreshold МБ, Кэш-хиты=$cacheHitsThreshold%, Сеть=$networkThreshold Мбит/с, Диск=$diskQueueThreshold, Кэш PVS=$CacheDurationMinutes мин" -ForegroundColor Green
}
catch {
    Write-Host "Ошибка при определении динамических параметров: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка при определении динамических параметров: $($_.Exception.Message)"
    $sampleInterval = 10  # Значение по умолчанию
    $runTimeMinutes = 30  # Значение по умолчанию
    $cpuThreshold = 70
    $queueThreshold = 10
    $memoryThreshold = 2000
    $cacheHitsThreshold = 80
    $networkThreshold = 200
    $diskQueueThreshold = 1
    $pvsDevices = 0
    $pvsServerStatus = "Неизвестно"
    $pvsThreads = 0
    $pvsCacheUsage = 0
    $pvsVersion = "Неизвестно"
}

# Функция для получения и анализа метрик, оптимизирована для больших ферм с обработкой ошибок
function Get-PVSPerformanceMetrics {
    # Получаем текущую метку времени
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $metrics = [PSCustomObject]@{
        Timestamp = $timestamp
        CPU_Usage_Percent = 0
        Processor_Queue = 0
        Available_Memory_MB = 0
        Cache_Bytes_MB = 0
        Copy_Read_Hits_Percent = 0
        L2_Bytes_Received_Mbps = 0
        L2_Bytes_Sent_Mbps = 0
        L3_Bytes_Received_Mbps = 0
        L3_Bytes_Sent_Mbps = 0
        Thread_Count = 0
        Disk_Reads_sec = 0
        Disk_Queue_Length = 0
        PVS_Server_Status = $pvsServerStatus
        PVS_Threads = $pvsThreads
        PVS_Cache_Usage = $pvsCacheUsage
        PVS_Device_Count = $pvsDevices
        Server_Cores = $serverCores
        Server_RAM_GB = $serverRAM
        Server_Network_Speed_Gbps = $serverNetworkSpeed
        PVS_Version = $pvsVersion
        Analysis = "Ошибка при сборе данных"
    }

    try {
        # Мониторинг CPU, адаптировано под динамическое количество ядер
        $cpuUsage = (Get-Counter "\Processor(_Total)\% Processor Time" -ErrorAction Stop).CounterSamples.CookedValue
        $processorQueue = (Get-Counter "\System\Processor Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Мониторинг RAM, адаптировано под динамический объём RAM
        $availableMemory = (Get-Counter "\Memory\Available MBytes" -ErrorAction Stop).CounterSamples.CookedValue
        $cacheBytes = (Get-Counter "\Memory\Cache Bytes" -ErrorAction Stop).CounterSamples.CookedValue / 1MB  # В мегабайтах
        $copyReadHits = (Get-Counter "\Cache\Copy Read Hits %" -ErrorAction Stop).CounterSamples.CookedValue  # Переименовано для консистентности

        # Мониторинг сети (L3 и L2), адаптировано под динамическую скорость сети
        if ($L3Adapter -and $L2Adapter) {
            $l3Rx = (Get-Counter "\Network Interface($($L3Adapter.Name))\Bytes Received/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
            $l3Tx = (Get-Counter "\Network Interface($($L3Adapter.Name))\Bytes Sent/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
            $l2Rx = (Get-Counter "\Network Interface($($L2Adapter.Name))\Bytes Received/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
            $l2Tx = (Get-Counter "\Network Interface($($L2Adapter.Name))\Bytes Sent/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
        }
        else {
            $l3Rx = 0; $l3Tx = 0; $l2Rx = 0; $l2Tx = 0
        }

        # Мониторинг потоков PVS
        $threadCount = (Get-Process -Name "StreamService" -ErrorAction SilentlyContinue).Threads.Count
        if (!$threadCount) { $threadCount = 0 }

        # Мониторинг I/O к диску (NetApp через L2)
        $diskReads = (Get-Counter "\PhysicalDisk(_Total)\Disk Reads/sec" -ErrorAction Stop).CounterSamples.CookedValue
        $diskQueue = (Get-Counter "\PhysicalDisk(_Total)\Avg. Disk Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Обновление кэша PVS данных для больших ферм
        $pvsData = Get-PVSCachedData -CacheDurationMinutes $CacheDurationMinutes
        if ($pvsData) {
            $pvsServerStatus = $pvsData.Status
            $pvsThreads = $pvsData.Threads
            $pvsCacheUsage = $pvsData.CacheUsage
            $pvsDevices = $pvsData.DeviceCount
            $pvsVersion = $pvsData.Version
        }
        else {
            $pvsServerStatus = "Неизвестно"
            $pvsThreads = 0
            $pvsCacheUsage = 0
            $pvsDevices = 0
            $pvsVersion = "Неизвестно"
        }

        # Анализ данных, адаптированный под любую среду для больших ферм
        $analysis = @()
        if ($cpuUsage -gt $cpuThreshold) {
            $analysis += "Высокая загрузка CPU ($cpuUsage%) — возможно, ограничение потоков или ядер."
        }
        if ($processorQueue -gt $queueThreshold) {
            $analysis += "Длинная очередь задач ($processorQueue) — увеличьте Threads или добавьте ядра."
        }
        if ($availableMemory -lt $memoryThreshold) {
            $analysis += "Нехватка доступной памяти ($availableMemory МБ) — увеличьте объём RAM."
        }
        if ($copyReadHits -lt $cacheHitsThreshold) {
            $analysis += "Низкие кэш-хиты ($copyReadHits%) — проверьте NetApp, Oplocks, RAM."
        }
        if ($l2Rx -lt $networkThreshold -or $l2Tx -lt $networkThreshold) {
            $analysis += "Низкий трафик L2 ($l2Rx/$l2Tx Мбит/с) — проверьте NetApp (SMB, SSD, Oplocks)."
        }
        if ($l3Rx -lt $networkThreshold -or $l3Tx -lt $networkThreshold) {
            $analysis += "Низкий трафик L3 ($l3Rx/$l3Tx Мбит/с) — увеличьте Threads или проверьте сеть."
        }
        if ($diskQueue -gt $diskQueueThreshold) {
            $analysis += "Высокая очередь I/O к диску ($diskQueue) — оптимизируйте NetApp."
        }
        if ($pvsServerStatus -ne "Running") {
            $analysis += "Статус PVS-сервера: $pvsServerStatus — проверьте службу Stream Service."
        }
        if ($pvsThreads -lt 100 -or $pvsThreads -gt ($serverCores * 30)) {  # Адаптировано под количество ядер
            $analysis += "Необычное количество потоков PVS ($pvsThreads) — проверьте настройки Threads per Port."
        }
        if ($pvsCacheUsage -gt ($serverRAM * 1024 * 0.75)) {  # 75% от RAM
            $analysis += "Высокое использование кэша PVS ($pvsCacheUsage MB) — проверьте RAM или vDisk."
        }

        # Проверка логов Event Viewer на ошибки PVS, оптимизировано для больших ферм
        try {
            $eventErrors = @()
            $pvsEvents = Get-WinEvent -LogName "Application", "System" -ErrorAction Stop | 
                         Where-Object { 
                             ($_.ProviderName -like "*Citrix PVS*" -or $_.Id -in 1000..1999) -and 
                             ($_.Level -eq 2 -or $_.Level -eq 3)  # Уровни: Error (2), Warning (3)
                         } | 
                         Select-Object -Last 3  # Ещё больше уменьшено для производительности
            if ($pvsEvents) {
                foreach ($event in $pvsEvents) {
                    $eventErrors += "Журнал: $($event.LogName), ID: $($event.Id), Время: $($event.TimeCreated), Сообщение: $($event.Message)"
                }
                $analysis += "Найдены ошибки в Event Viewer для PVS: $($eventErrors -join '; ')"
            }
        }
        catch {
            $analysis += "Ошибка при доступе к Event Viewer: $($_.Exception.Message)"
            Write-ErrorLog "Ошибка при доступе к Event Viewer: $($_.Exception.Message)"
        }

        # Если нет проблем, добавляем нейтральный комментарий
        if ($analysis.Count -eq 0) {
            $analysis += "Производительность в норме."
        }

        $analysisText = $analysis -join "; "

        # Обновление метрик
        $metrics.CPU_Usage_Percent = [math]::Round($cpuUsage, 2)
        $metrics.Processor_Queue = [math]::Round($processorQueue, 2)
        $metrics.Available_Memory_MB = [math]::Round($availableMemory, 2)
        $metrics.Cache_Bytes_MB = [math]::Round($cacheBytes, 2)
        $metrics.Copy_Read_Hits_Percent = [math]::Round($copyReadHits, 2)
        $metrics.L2_Bytes_Received_Mbps = [math]::Round($l2Rx, 2)
        $metrics.L2_Bytes_Sent_Mbps = [math]::Round($l2Tx, 2)
        $metrics.L3_Bytes_Received_Mbps = [math]::Round($l3Rx, 2)
        $metrics.L3_Bytes_Sent_Mbps = [math]::Round($l3Tx, 2)
        $metrics.Thread_Count = $threadCount
        $metrics.Disk_Reads_sec = [math]::Round($diskReads, 2)
        $metrics.Disk_Queue_Length = [math]::Round($diskQueue, 2)
        $metrics.PVS_Server_Status = $pvsServerStatus
        $metrics.PVS_Threads = $pvsThreads
        $metrics.PVS_Cache_Usage = $pvsCacheUsage
        $metrics.PVS_Device_Count = $pvsDevices
        $metrics.Server_Cores = $serverCores
        $metrics.Server_RAM_GB = $serverRAM
        $metrics.Server_Network_Speed_Gbps = $serverNetworkSpeed
        $metrics.PVS_Version = $pvsVersion
        $metrics.Analysis = $analysisText

        # Вывод в консоль на русском, оптимизирован для читаемости
        Write-Host "Метка времени: $timestamp"
        Write-Host "Загрузка CPU: $($metrics.CPU_Usage_Percent)%"
        Write-Host "Доступная память: $($metrics.Available_Memory_MB) МБ"
        Write-Host "Кэшированная память: $($metrics.Cache_Bytes_MB) МБ"
        Write-Host "Процент кэш-хитов: $($metrics.Copy_Read_Hits_Percent)%"
        Write-Host "L2 Приём: $($metrics.L2_Bytes_Received_Mbps) Мбит/с, L2 Передача: $($metrics.L2_Bytes_Sent_Mbps) Мбит/с"
        Write-Host "L3 Приём: $($metrics.L3_Bytes_Received_Mbps) Мбит/с, L3 Передача: $($metrics.L3_Bytes_Sent_Mbps) Мбит/с"
        Write-Host "Количество потоков: $($metrics.Thread_Count)"
        Write-Host "Чтения с диска/с: $($metrics.Disk_Reads_sec), Очередь диска: $($metrics.Disk_Queue_Length)"
        Write-Host "Статус PVS-сервера: $($metrics.PVS_Server_Status)"
        Write-Host "Потоки PVS: $($metrics.PVS_Threads)"
        Write-Host "Использование кэша PVS: $($metrics.PVS_Cache_Usage) МБ"
        Write-Host "Количество устройств PVS: $($metrics.PVS_Device_Count)"
        Write-Host "Ядер сервера: $($metrics.Server_Cores), RAM сервера: $($metrics.Server_RAM_GB) ГБ"
        Write-Host "Скорость сети сервера: $($metrics.Server_Network_Speed_Gbps) Гбит/с, Версия PVS: $($metrics.PVS_Version)"
        Write-Host "Анализ: $analysisText"
        Write-Host "---"

        # Запись в лог (CSV и текстовый формат), оптимизировано для производительности
        try {
            $metrics | Export-Csv -Path $LogFile -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            "[$timestamp] $($metrics.Analysis)" | Out-File -FilePath $TextLogFile -Append -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Host "Ошибка при записи в лог: $($_.Exception.Message)" -ForegroundColor Red
            Write-ErrorLog "Ошибка при записи в лог: $($_.Exception.Message)"
        }
    }
    catch {
        Write-Host "Ошибка при сборе метрик: $($_.Exception.Message)" -ForegroundColor Red
        $metrics.Analysis = "Ошибка: $($_.Exception.Message)"
        Write-ErrorLog "Ошибка при сборе метрик: $($_.Exception.Message)"
    }
}

# Основной цикл мониторинга, адаптирован под динамическую нагрузку больших ферм
$runTimeSeconds = $RunTimeMinutes * 60
$startTime = Get-Date
$elapsed = 0

try {
    Write-Host "Запуск оптимизированного мониторинга и анализа производительности PVS-сервера для больших ферм на $runTimeMinutes минут..." -ForegroundColor Green

    while ($elapsed -lt $runTimeSeconds) {
        Get-PVSPerformanceMetrics
        Start-Sleep -Seconds $sampleInterval
        $elapsed = (Get-Date) - $startTime | Select-Object -ExpandProperty TotalSeconds
    }
}
catch {
    Write-Host "Ошибка в основном цикле: $($_.Exception.Message)" -ForegroundColor Red
    Write-ErrorLog "Ошибка в основном цикле: $($_.Exception.Message)"
}
finally {
    Write-Host "Мониторинг завершён. Лог сохранён в $LogFile и $TextLogFile" -ForegroundColor Green

    # Удаление старых логов (старше 7 дней), оптимизировано для производительности
    try {
        Get-ChildItem -Path $LogPath -Filter "PVS_Performance_Log_*" -Recurse -ErrorAction Stop | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
        Remove-Item -Force -ErrorAction Stop
        Write-Host "Очищены старые логи, созданные более 7 дней назад." -ForegroundColor Green
    }
    catch {
        Write-Host "Ошибка при очистке старых логов: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-ErrorLog "Ошибка при очистке старых логов: $($_.Exception.Message)"
    }
}
