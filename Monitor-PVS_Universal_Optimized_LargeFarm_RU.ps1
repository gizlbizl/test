<#
.SYNOPSIS
Упрощённый скрипт для мониторинга производительности сервера с проверкой ошибок PVS в Event Viewer.

.DESCRIPTION
Данный скрипт автоматически определяет конфигурацию сервера (количество ядер, RAM),
собирает базовые метрики производительности (CPU, RAM, кэш, потоки, I/O),
проверяет логи Event Viewer на ошибки PVS, выводит результаты в консоль на русском языке и сохраняет их в CSV и текстовый файл.

.ПАРАМЕТРЫ
-LogPath: Путь для сохранения логов (по умолчанию: "C:\PVS_Logs").
-SampleInterval: Интервал сбора данных в секундах (по умолчанию: 10).
-RunTimeMinutes: Время работы скрипта в минутах (по умолчанию: 30).

.ПРИМЕРЫ
.\Monitor_Server_Simplified_RU.ps1 -LogPath "D:\PVS_Logs" -SampleInterval 15 -RunTimeMinutes 45
Запустит упрощённый мониторинг с логами в D:\PVS_Logs, интервалом 15 секунд и длительностью 45 минут.

.ЗАМЕЧАНИЯ
- Требуются права администратора для работы с PerfMon и Event Viewer.
- Скрипт проверяет журналы "Application" и "System" на события от Citrix PVS.
#>

# Параметры скрипта
Param (
    [string]$LogPath = "C:\PVS_Logs", # Путь для логов
    [int]$SampleInterval = 10,        # Интервал сбора данных в секундах
    [int]$RunTimeMinutes = 30         # Время работы скрипта в минутах
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
"Timestamp,CPU_Usage_Percent,Available_Memory_MB,Cache_Bytes_MB,Copy_Read_Hits_Percent,Thread_Count,Disk_Reads_sec,Disk_Queue_Length,Server_Cores,Server_RAM_GB,Analysis" | 
Out-File $LogFile -Encoding UTF8

# Конфигурация сервера
$serverCores = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
$serverRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)

# Пороги
$cpuThreshold = 70
$memoryThreshold = 2000
$cacheHitsThreshold = 80
$diskQueueThreshold = 1

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

        # Мониторинг потоков (предполагается, что это сервер PVS, мониторим StreamService)
        $threadCount = (Get-Process -Name "StreamService" -ErrorAction SilentlyContinue).Threads.Count
        if (!$threadCount) { $threadCount = 0 }

        # Мониторинг I/O к диску
        $diskReads = (Get-Counter "\PhysicalDisk(_Total)\Disk Reads/sec" -ErrorAction Stop).CounterSamples.CookedValue
        $diskQueue = (Get-Counter "\PhysicalDisk(_Total)\Avg. Disk Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Анализ
        $analysis = @()
        if ($cpuUsage -gt $cpuThreshold) { $analysis += "Высокая загрузка CPU ($cpuUsage%)" }
        if ($availableMemory -lt $memoryThreshold) { $analysis += "Нехватка памяти ($availableMemory МБ)" }
        if ($copyReadHits -lt $cacheHitsThreshold) { $analysis += "Низкие кэш-хиты ($copyReadHits%)" }
        if ($diskQueue -gt $diskQueueThreshold) { $analysis += "Высокая очередь I/O ($diskQueue)" }

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
                $analysis += "Найдены ошибки PVS: $($eventErrors -join '; ')"
            }
        }
        catch {
            $analysis += "Ошибка при доступе к Event Viewer: Не удалось получить события PVS."
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
        $metrics.Analysis = $analysisText

        # Вывод в консоль
        Write-Host "Метка времени: $timestamp"
        Write-Host "CPU: $($metrics.CPU_Usage_Percent)%"
        Write-Host "Память: $($metrics.Available_Memory_MB) МБ доступно"
        Write-Host "Кэш: $($metrics.Cache_Bytes_MB) МБ"
        Write-Host "Кэш-хиты: $($metrics.Copy_Read_Hits_Percent)%"
        Write-Host "Потоки: $($metrics.Thread_Count)"
        Write-Host "Чтения с диска/с: $($metrics.Disk_Reads_sec), Очередь: $($metrics.Disk_Queue_Length)"
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

while ((Get-Date) - $startTime | Select-Object -ExpandProperty TotalSeconds -lt $runTimeSeconds) {
    Get-ServerPerformanceMetrics
    Start-Sleep -Seconds $SampleInterval
}

Write-Host "Мониторинг завершён. Логи сохранены в $LogFile и $TextLogFile" -ForegroundColor Green

# Очистка старых логов
Get-ChildItem -Path $LogPath -Filter "Server_Performance_Log_*" -Recurse | 
Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
Remove-Item -Force
Write-Host "Удалены старые логи старше 7 дней." -ForegroundColor Green
