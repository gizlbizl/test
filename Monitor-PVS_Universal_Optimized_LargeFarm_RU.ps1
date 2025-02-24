<#
.SYNOPSIS
Упрощённый скрипт для мониторинга производительности серверов Citrix Provisioning Services (PVS).

.DESCRIPTION
Данный скрипт автоматически определяет конфигурацию PVS-сервера (количество ядер, RAM, сетевые интерфейсы),
собирает базовые метрики производительности (CPU, RAM, кэш, сеть, потоки, I/O),
использует PVS-командлеты для получения данных о сервере и устройствах,
проверяет логи Event Viewer на ошибки PVS, выводит результаты в консоль на русском языке и сохраняет их в CSV и текстовый файл.

.ПАРАМЕТРЫ
-LogPath: Путь для сохранения логов (по умолчанию: "C:\PVS_Logs").
-SampleInterval: Интервал сбора данных в секундах (по умолчанию: 10).
-RunTimeMinutes: Время работы скрипта в минутах (по умолчанию: 30).

.ПРИМЕРЫ
.\Monitor-PVS_Simplified_RU.ps1 -LogPath "D:\PVS_Logs" -SampleInterval 15 -RunTimeMinutes 45
Запустит упрощённый мониторинг с логами в D:\PVS_Logs, интервалом 15 секунд и длительностью 45 минут.

.ЗАМЕЧАНИЯ
- Требуются права администратора для работы с PerfMon, Event Viewer и PVS командлетами.
- Убедитесь, что модуль Citrix.PVS.SnapIn установлен (Register-PSSnapin Citrix.PVS.SnapIn).
- Скрипт проверяет журналы "Application" и "System" на события от Citrix PVS.
#>

# Параметры скрипта с локализацией
Param (
    [string]$LogPath = "C:\PVS_Logs", # Путь для сохранения логов
    [int]$SampleInterval = 10,        # Интервал сбора данных в секундах
    [int]$RunTimeMinutes = 30         # Время работы скрипта в минутах
)

# Создание директории и файлов логов, если их нет
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath | Out-Null
    Write-Host "Создано директория для логов: $LogPath" -ForegroundColor Green
}

# Автоматическое создание имени файла
$LogFile = Join-Path $LogPath "PVS_Performance_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$TextLogFile = "$LogFile.txt"

# Создание CSV-файла с заголовками
"Timestamp,CPU_Usage_Percent,Processor_Queue,Available_Memory_MB,Cache_Bytes_MB,Copy_Read_Hits_Percent,L2_Bytes_Received_Mbps,L2_Bytes_Sent_Mbps,L3_Bytes_Received_Mbps,L3_Bytes_Sent_Mbps,Thread_Count,Disk_Reads_sec,Disk_Queue_Length,PVS_Server_Status,PVS_Threads,PVS_Cache_Usage,PVS_Device_Count,Server_Cores,Server_RAM_GB,Server_Network_Speed_Gbps,PVS_Version,Analysis" | 
Out-File $LogFile -Encoding UTF8

# Регистрация PVS Snap-In (если не зарегистрирован)
try {
    if (-not (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
        Write-Host "Модуль Citrix PVS Snap-In успешно зарегистрирован." -ForegroundColor Green
    }
}
catch {
    Write-Host "Ошибка: Не удалось зарегистрировать PVS Snap-In. Проверьте установку Citrix PVS." -ForegroundColor Red
    exit
}

# Автоматическое определение конфигурации сервера
$serverCores = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum  # Количество ядер
$serverRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)  # RAM в ГБ

# Определение скорости сети (L3 и L2)
$networkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 2
$L3Adapter = $networkAdapters | Select-Object -First 1  # L3 (Target Devices)
$L2Adapter = $networkAdapters | Select-Object -Skip 1 -First 1  # L2 (NetApp CIFS)
if (!$L3Adapter -or !$L2Adapter) {
    Write-Host "Ошибка: Не удалось найти сетевые интерфейсы. Проверьте их через Get-NetAdapter." -ForegroundColor Red
    exit
}
$serverNetworkSpeed = ($L3Adapter.LinkSpeed -replace " Gbps", "")  # Скорость сети
if (!$serverNetworkSpeed) { $serverNetworkSpeed = 1 }  # Значение по умолчанию
Write-Host "L3 (Устройства Target): $($L3Adapter.Name), Скорость: $serverNetworkSpeed Гбит/с" -ForegroundColor Green
Write-Host "L2 (NetApp CIFS): $($L2Adapter.Name), Скорость: $serverNetworkSpeed Гбит/с" -ForegroundColor Green

# Получение данных PVS
try {
    $pvsServer = Get-PVSServer -Name $env:COMPUTERNAME -ErrorAction Stop
    $pvsDevices = (Get-PVSTargetDevice -Server $pvsServer -ErrorAction Stop | Measure-Object).Count  # Количество устройств
    $pvsServerStatus = $pvsServer.Status
    $pvsThreads = $pvsServer.ThreadCount
    $pvsCacheUsage = $pvsServer.CacheSizeMB
    $pvsVersion = $pvsServer.Version
}
catch {
    Write-Host "Ошибка: Не удалось получить данные PVS. Проверьте подключение к ферме PVS." -ForegroundColor Red
    $pvsDevices = 0
    $pvsServerStatus = "Неизвестно"
    $pvsThreads = 0
    $pvsCacheUsage = 0
    $pvsVersion = "Неизвестно"
}

# Базовые пороги (универсальные)
$cpuThreshold = 70
$queueThreshold = 10
$memoryThreshold = 2000
$cacheHitsThreshold = 80
$networkThreshold = 200
$diskQueueThreshold = 1

# Функция для получения и анализа метрик
function Get-PVSPerformanceMetrics {
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
        # Мониторинг CPU
        $cpuUsage = (Get-Counter "\Processor(_Total)\% Processor Time" -ErrorAction Stop).CounterSamples.CookedValue
        $processorQueue = (Get-Counter "\System\Processor Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Мониторинг RAM
        $availableMemory = (Get-Counter "\Memory\Available MBytes" -ErrorAction Stop).CounterSamples.CookedValue
        $cacheBytes = (Get-Counter "\Memory\Cache Bytes" -ErrorAction Stop).CounterSamples.CookedValue / 1MB  # В мегабайтах
        $copyReadHits = (Get-Counter "\Cache\Copy Read Hits %" -ErrorAction Stop).CounterSamples.CookedValue

        # Мониторинг сети (L3 и L2)
        $l3Rx = (Get-Counter "\Network Interface($($L3Adapter.Name))\Bytes Received/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
        $l3Tx = (Get-Counter "\Network Interface($($L3Adapter.Name))\Bytes Sent/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
        $l2Rx = (Get-Counter "\Network Interface($($L2Adapter.Name))\Bytes Received/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с
        $l2Tx = (Get-Counter "\Network Interface($($L2Adapter.Name))\Bytes Sent/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8  # Мбит/с

        # Мониторинг потоков PVS
        $threadCount = (Get-Process -Name "StreamService" -ErrorAction SilentlyContinue).Threads.Count
        if (!$threadCount) { $threadCount = 0 }

        # Мониторинг I/O к диску
        $diskReads = (Get-Counter "\PhysicalDisk(_Total)\Disk Reads/sec" -ErrorAction Stop).CounterSamples.CookedValue
        $diskQueue = (Get-Counter "\PhysicalDisk(_Total)\Avg. Disk Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Анализ данных
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

        # Проверка логов Event Viewer на ошибки PVS
        try {
            $eventErrors = @()
            $pvsEvents = Get-WinEvent -LogName "Application", "System" -ErrorAction Stop | 
                         Where-Object { 
                             ($_.ProviderName -like "*Citrix PVS*" -or $_.Id -in 1000..1999) -and 
                             ($_.Level -eq 2 -or $_.Level -eq 3)  # Уровни: Error (2), Warning (3)
                         } | 
                         Select-Object -Last 5
            if ($pvsEvents) {
                foreach ($event in $pvsEvents) {
                    $eventErrors += "Журнал: $($event.LogName), ID: $($event.Id), Время: $($event.TimeCreated), Сообщение: $($event.Message)"
                }
                $analysis += "Найдены ошибки в Event Viewer для PVS: $($eventErrors -join '; ')"
            }
        }
        catch {
            $analysis += "Ошибка при доступе к Event Viewer: Не удалось получить события PVS."
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

        # Вывод в консоль на русском
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

        # Запись в лог (CSV и текстовый формат)
        $metrics | Export-Csv -Path $LogFile -Append -NoTypeInformation -Encoding UTF8
        "[$timestamp] $($metrics.Analysis)" | Out-File -FilePath $TextLogFile -Append -Encoding UTF8
    }
    catch {
        Write-Host "Ошибка при сборе метрик: $($_.Exception.Message)" -ForegroundColor Red
        "[$timestamp] Ошибка при сборе метрик: $($_.Exception.Message)" | Out-File -FilePath $TextLogFile -Append -Encoding UTF8
    }
}

# Основной цикл мониторинга
$runTimeSeconds = $RunTimeMinutes * 60
$startTime = Get-Date
$elapsed = 0

Write-Host "Запуск мониторинга производительности PVS-сервера на $RunTimeMinutes минут..." -ForegroundColor Green

while ($elapsed -lt $runTimeSeconds) {
    Get-PVSPerformanceMetrics
    Start-Sleep -Seconds $SampleInterval
    $elapsed = (Get-Date) - $startTime | Select-Object -ExpandProperty TotalSeconds
}

Write-Host "Мониторинг завершён. Лог сохранён в $LogFile и $TextLogFile" -ForegroundColor Green

# Удаление старых логов (старше 7 дней)
Get-ChildItem -Path $LogPath -Filter "PVS_Performance_Log_*" -Recurse | 
Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
Remove-Item -Force
Write-Host "Очищены старые логи, созданные более 7 дней назад." -ForegroundColor Green
