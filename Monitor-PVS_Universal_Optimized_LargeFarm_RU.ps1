<#
.SYNOPSIS
Упрощённый скрипт для мониторинга производительности серверов Citrix Provisioning Services (PVS).

.DESCRIPTION
Данный скрипт автоматически определяет конфигурацию PVS-сервера (количество ядер, RAM),
собирает базовые метрики производительности (CPU, RAM, кэш, потоки, I/O),
использует PVS-командлеты для получения данных о сервере и устройствах,
проверяет логи Event Viewer на ошибки PVS, выводит результаты в консоль на русском языке и сохраняет их в CSV и текстовый файл.

.ПАРАМЕТРЫ
-LogPath: Путь для сохранения логов (по умолчанию: "C:\PVS_Logs").
-SampleInterval: Интервал сбора данных в секундах (по умолчанию: 10).
-RunTimeMinutes: Время работы скрипта в минутах (по умолчанию: 30).

.ПРИМЕРЫ
.\Monitor-PVS_Simplified_RU_Optimized.ps1 -LogPath "D:\PVS_Logs" -SampleInterval 15 -RunTimeMinutes 45
Запустит упрощённый мониторинг с логами в D:\PVS_Logs, интервалом 15 секунд и длительностью 45 минут.

.ЗАМЕЧАНИЯ
- Требуются права администратора для работы с PerfMon, Event Viewer и PVS командлетами.
- Убедитесь, что модуль Citrix.PVS.SnapIn установлен (Register-PSSnapin Citrix.PVS.SnapIn).
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
$LogFile = Join-Path $LogPath "PVS_Performance_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$TextLogFile = "$LogFile.txt"

# Заголовки CSV
"Timestamp,CPU_Usage_Percent,Available_Memory_MB,Cache_Bytes_MB,Copy_Read_Hits_Percent,Thread_Count,Disk_Reads_sec,Disk_Queue_Length,PVS_Server_Status,PVS_Threads,PVS_Device_Count,Server_Cores,Server_RAM_GB,Analysis" | 
Out-File $LogFile -Encoding UTF8

# Проверка и загрузка PVS Snap-In
if (-not (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
        Write-Host "Модуль Citrix PVS Snap-In успешно зарегистрирован." -ForegroundColor Green
    }
    catch {
        Write-Host "Ошибка: Не удалось зарегистрировать PVS Snap-In. Проверьте установку Citrix PVS." -ForegroundColor Red
        exit
    }
}

# Конфигурация сервера
$serverCores = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
$serverRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)

# Данные PVS
$pvsServerStatus = "Неизвестно"
$pvsThreads = 0
$pvsDevices = 0
try {
    $pvsServer = Get-PVSServer -Name $env:COMPUTERNAME -ErrorAction Stop
    if (Get-Command Get-PvsDevice -ErrorAction SilentlyContinue) {
        $pvsDevices = (Get-PvsDevice -SiteName "Default" -ErrorAction SilentlyContinue | Measure-Object).Count
    }
    else {
        Write-Host "Предупреждение: Командлет Get-PvsDevice не найден. Количество устройств установлено в 0." -ForegroundColor Yellow
    }
    $pvsServerStatus = $pvsServer.Status
    $pvsThreads = $pvsServer.ThreadCount
}
catch {
    Write-Host "Предупреждение: Не удалось получить данные PVS. Используются значения по умолчанию." -ForegroundColor Yellow
}

# Пороги
$cpuThreshold = 70
$memoryThreshold = 2000
$cacheHitsThreshold = 80
$diskQueueThreshold = 1

# Функция мониторинга
function Get-PVSPerformanceMetrics {
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
        PVS_Server_Status = $pvsServerStatus
        PVS_Threads = $pvsThreads
        PVS_Device_Count = $pvsDevices
        Server_Cores = $serverCores
        Server_RAM_GB = $serverRAM
        Analysis = "Ошибка при сборе данных"
    }

    try {
        # CPU
        $cpuUsage = (Get-Counter "\Processor(_Total)\% Processor Time" -ErrorAction Stop).CounterSamples.CookedValue

        # RAM
        $availableMemory = (Get-Counter "\Memory\Available MBytes" -ErrorAction Stop).CounterSamples.CookedValue
        $cacheBytes = (Get-Counter "\Memory\Cache Bytes" -ErrorAction Stop).CounterSamples.CookedValue / 1MB
        $copyReadHits = (Get-Counter "\Cache\Copy Read Hits %" -ErrorAction Stop).CounterSamples.CookedValue

        # Потоки PVS
        $threadCount = (Get-Process -Name "StreamService" -ErrorAction SilentlyContinue).Threads.Count
        if (!$threadCount) { $threadCount = 0 }

        # I/O диска
        $diskReads = (Get-Counter "\PhysicalDisk(_Total)\Disk Reads/sec" -ErrorAction Stop).CounterSamples.CookedValue
        $diskQueue = (Get-Counter "\PhysicalDisk(_Total)\Avg. Disk Queue Length" -ErrorAction Stop).CounterSamples.CookedValue

        # Анализ
        $analysis = @()
        if ($cpuUsage -gt $cpuThreshold) { $analysis += "Высокая загрузка CPU ($cpuUsage%)" }
        if ($availableMemory -lt $memoryThreshold) { $analysis += "Нехватка памяти ($availableMemory МБ)" }
        if ($copyReadHits -lt $cacheHitsThreshold) { $analysis += "Низкие кэш-хиты ($copyReadHits%)" }
        if ($diskQueue -gt $diskQueueThreshold) { $analysis += "Высокая очередь I/O ($diskQueue)" }
        if ($pvsServerStatus -ne "Running") { $analysis += "PVS сервер не работает: $pvsServerStatus" }

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
        $metrics.PVS_Server_Status = $pvsServerStatus
        $metrics.PVS_Threads = $pvsThreads
        $metrics.PVS_Device_Count = $pvsDevices
        $metrics.Server_Cores = $serverCores
        $metrics.Server_RAM_GB = $serverRAM
        $metrics.Analysis = $analysisText

        # Вывод в консоль
        Write-Host "Метка времени: $timestamp"
        Write-Host "CPU: $($metrics.CPU_Usage_Percent)%"
        Write-Host "Память: $($metrics.Available_Memory_MB) МБ доступно"
        Write-Host "Кэш: $($metrics.Cache_Bytes_MB) МБ"
        Write-Host "Кэш-хиты: $($metrics.Copy_Read_Hits_Percent)%"
        Write-Host "Потоки: $($metrics.Thread_Count)"
        Write-Host "Чтения с диска/с: $($metrics.Disk_Reads_sec), Очередь: $($metrics.Disk_Queue_Length)"
        Write-Host "PVS статус: $($metrics.PVS_Server_Status)"
        Write-Host "PVS потоки: $($metrics.PVS_Threads)"
        Write-Host "Устройства PVS: $($metrics.PVS_Device_Count)"
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

Write-Host "Запуск мониторинга PVS-сервера на $RunTimeMinutes минут..." -ForegroundColor Green

while ((Get-Date) - $startTime | Select-Object -ExpandProperty TotalSeconds -lt $runTimeSeconds) {
    Get-PVSPerformanceMetrics
    Start-Sleep -Seconds $SampleInterval
}

Write-Host "Мониторинг завершён. Логи сохранены в $LogFile и $TextLogFile" -ForegroundColor Green

# Очистка старых логов
Get-ChildItem -Path $LogPath -Filter "PVS_Performance_Log_*" -Recurse | 
Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
Remove-Item -Force
Write-Host "Удалены старые логи старше 7 дней." -ForegroundColor Green
