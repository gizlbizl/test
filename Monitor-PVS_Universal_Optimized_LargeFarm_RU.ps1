<#
.SYNOPSIS
Упрощённый скрипт для мониторинга производительности сервера с учётом vDisk на CIFS.

.DESCRIPTION
Данный скрипт автоматически определяет конфигурацию сервера (количество ядер, RAM),
собирает базовые метрики производительности (CPU, RAM, кэш, потоки, I/O, сеть),
учитывает, что vDisk находится на CIFS, выводит результаты в консоль на русском языке и сохраняет их в CSV и текстовый файл.

.ПАРАМЕТРЫ
-LogPath: Путь для сохранения логов (по умолчанию: "C:\Server_Logs").
-SampleInterval: Интервал сбора данных в секундах (по умолчанию: 10).
-RunTimeMinutes: Время работы скрипта в минутах (по умолчанию: 30).

.ПРИМЕРЫ
.\Monitor_Server_Simplified_RU_CIFS.ps1 -LogPath "D:\Server_Logs" -SampleInterval 15 -RunTimeMinutes 45
Запустит упрощённый мониторинг с логами в D:\Server_Logs, интервалом 15 секунд и длительностью 45 минут.

.ЗАМЕЧАНИЯ
- Требуются права администратора для работы с PerfMon.
- Счётчики сети косвенно указывают на I/O для vDisk на CIFS, но не дают точной информации о производительности SMB/CIFS.
#>

# Параметры скрипта
Param (
    [string]$LogPath = "C:\Server_Logs", # Путь для логов
    [int]$SampleInterval = 10,           # Интервал сбора данных в секундах
    [int]$RunTimeMinutes = 30            # Время работы скрипта в минутах
)

# Создание директории логов, если её нет
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath | Out-Null
    Write-Host "Создано директория для логов: $LogPath" -ForegroundColor Green
}

# Имена файлов логов
$LogFile = Join-Path $LogPath "Server_Performance_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$TextLogFile = "$LogFile.txt"

# Заголовки CSV
"Timestamp,CPU_Usage_Percent,Available_Memory_MB,Cache_Bytes_MB,Copy_Read_Hits_Percent,Thread_Count,Disk_Reads_sec,Disk_Queue_Length,Network_Bytes_Received_Mbps,Network_Bytes_Sent_Mbps,Server_Cores,Server_RAM_GB,Analysis" | 
Out-File $LogFile -Encoding UTF8

# Конфигурация сервера
$serverCores = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
$serverRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)

# Пороги
$cpuThreshold = 70
$memoryThreshold = 2000
$cacheHitsThreshold = 80
$diskQueueThreshold = 1
$networkThreshold = 200  # Порог для сетевых операций (Мбит/с)

# Определение сетевого интерфейса (основной, предполагается для CIFS)
$networkAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if (!$networkAdapter) {
    Write-Host "Предупреждение: Не найден активный сетевой интерфейс. Используются значения по умолчанию для сети (0 Мбит/с)." -ForegroundColor Yellow
}

# Функция мониторинга
function Get-ServerPerformanceMetrics {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $metrics = [PSCustomObject]@{
        Timestamp = $timestamp
        CPU_Usage_Percent = 0
        Available_Memory_MB = 0
        Cache_Bytes_MB = 0
        Copy_Read_Hits_Percent = 0
        Thread_Count = 0
        Disk_Reads_sec = 0
        Disk_Queue_Length = 0
        Network_Bytes_Received_Mbps = 0
        Network_Bytes_Sent_Mbps = 0
        Server_Cores = $serverCores
        Server_RAM_GB = $serverRAM
        Analysis = "Ошибка при сборе данных"
    }

    try {
        # Мониторинг CPU
        $cpuUsage = (Get-Counter "\Processor(_Total)\% Processor Time" -ErrorAction Stop).CounterSamples.CookedValue

        # Мониторинг RAM
        $availableMemory = (Get-Counter "\Memory\Available MBytes" -ErrorAction Stop).CounterSamples.CookedValue
        $cacheBytes = (Get-Counter "\Memory\Cache Bytes" -ErrorAction Stop).CounterSamples.CookedValue / 1MB
        $copyReadHits = (Get-Counter "\Cache\Copy Read Hits %" -ErrorAction Stop).CounterSamples.CookedValue

        # Мониторинг потоков (предполагается сервер PVS, мониторим StreamService)
        $threadCount = (Get-Process -Name "StreamService" -ErrorAction SilentlyContinue).Threads.Count
        if (!$threadCount) { $threadCount = 0 }

        # Мониторинг I/O к диску (локальный диск)
        $diskReads = (Get-Counter "\PhysicalDisk(_Total)\Disk Reads/sec" -ErrorAction Stop).CounterSamples.CookedValue
        $diskQueue = (Get-Counter "\PhysicalDisk(_Total)\Avg. Disk Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Мониторинг сети (для CIFS, косвенно)
        $networkBytesReceived = 0
        $networkBytesSent = 0
        if ($networkAdapter) {
            try {
                $networkBytesReceived = [math]::Round((Get-Counter "\Network Interface($($networkAdapter.Name))\Bytes Received/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8, 2)  # Мбит/с
                $networkBytesSent = [math]::Round((Get-Counter "\Network Interface($($networkAdapter.Name))\Bytes Sent/sec" -ErrorAction Stop).CounterSamples.CookedValue / 1MB * 8, 2)  # Мбит/с
            }
            catch {
                Write-Host "Предупреждение: Ошибка при мониторинге сети. Используются значения по умолчанию (0 Мбит/с)." -ForegroundColor Yellow
            }
        }

        # Анализ
        $analysis = @()
        if ($cpuUsage -gt $cpuThreshold) { $analysis += "Высокая загрузка CPU ($cpuUsage%)" }
        if ($availableMemory -lt $memoryThreshold) { $analysis += "Нехватка памяти ($availableMemory МБ)" }
        if ($copyReadHits -lt $cacheHitsThreshold) { $analysis += "Низкие кэш-хиты ($copyReadHits%)" }
        if ($diskQueue -gt $diskQueueThreshold) { $analysis += "Высокая очередь I/O локального диска ($diskQueue)" }
        if ($networkBytesReceived -lt $networkThreshold -or $networkBytesSent -lt $networkThreshold) { 
            $analysis += "Низкий сетевой трафик ($networkBytesReceived/$networkBytesSent Мбит/с) — возможно, проблемы с CIFS." 
        }

        if ($analysis.Count -eq 0) { $analysis += "Производительность в норме." }
        $analysisText = $analysis -join "; "

        # Обновление метрик
        $metrics.CPU_Usage_Percent = [math]::Round($cpuUsage, 2)
        $metrics.Available_Memory_MB = [math]::Round($availableMemory, 2)
        $metrics.Cache_Bytes_MB = [math]::Round($cacheBytes, 2)
        $metrics.Copy_Read_Hits_Percent = [math]::Round($copyReadHits, 2)
        $metrics.Thread_Count = $threadCount
        $metrics.Disk_Reads_sec = [math]::Round($diskReads, 2)
        $metrics.Disk_Queue_Length = [math]::Round($diskQueue, 2)
        $metrics.Network_Bytes_Received_Mbps = $networkBytesReceived
        $metrics.Network_Bytes_Sent_Mbps = $networkBytesSent
        $metrics.Analysis = $analysisText

        # Вывод в консоль
        Write-Host "Метка времени: $timestamp"
        Write-Host "CPU: $($metrics.CPU_Usage_Percent)%"
        Write-Host "Память: $($metrics.Available_Memory_MB) МБ доступно"
        Write-Host "Кэш: $($metrics.Cache_Bytes_MB) МБ"
        Write-Host "Кэш-хиты: $($metrics.Copy_Read_Hits_Percent)%"
        Write-Host "Потоки: $($metrics.Thread_Count)"
        Write-Host "Чтения с диска/с: $($metrics.Disk_Reads_sec), Очередь: $($metrics.Disk_Queue_Length)"
        Write-Host "Сеть (CIFS): Приём: $($metrics.Network_Bytes_Received_Mbps) Мбит/с, Передача: $($metrics.Network_Bytes_Sent_Mbps) Мбит/с"
        Write-Host "Ядра: $($metrics.Server_Cores), RAM: $($metrics.Server_RAM_GB) ГБ"
        Write-Host "Анализ: $analysisText"
        Write-Host "---"

        # Логирование
        $metrics | Export-Csv -Path $LogFile -Append -NoTypeInformation -Encoding UTF8
        "[$timestamp] $analysisText" | Out-File $TextLogFile -Append -Encoding UTF8
    }
    catch {
        Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
        "[$timestamp] Ошибка: $($_.Exception.Message)" | Out-File $TextLogFile -Append -Encoding UTF8
    }
}

# Запуск мониторинга
$runTimeSeconds = $RunTimeMinutes * 60
$startTime = Get-Date

Write-Host "Запуск мониторинга сервера на $RunTimeMinutes минут..." -ForegroundColor Green

while (((Get-Date) - $startTime).TotalSeconds -lt $runTimeSeconds) {
    Get-ServerPerformanceMetrics
    Start-Sleep -Seconds $SampleInterval
}

Write-Host "Мониторинг завершён. Логи сохранены в $LogFile и $TextLogFile" -ForegroundColor Green

# Очистка старых логов
Get-ChildItem -Path $LogPath -Filter "Server_Performance_Log_*" -Recurse | 
Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
Remove-Item -Force
Write-Host "Удалены старые логи старше 7 дней." -ForegroundColor Green
