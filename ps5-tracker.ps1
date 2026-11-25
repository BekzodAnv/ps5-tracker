<#
  Трекер цен PS5 на OLX.uz.
  Обычный запуск (раз в день):  .\ps5-tracker.ps1
  Восстановить историю:         .\ps5-tracker.ps1 -Backfill -BackfillDays 10
  Только пересобрать отчёт:      .\ps5-tracker.ps1 -ReportOnly
  Узнать chat_id для Telegram:   .\ps5-tracker.ps1 -GetChatId
#>
param(
    [switch]$Backfill,
    [int]$BackfillDays = 10,
    [switch]$ReportOnly,
    [switch]$NoTelegram,
    [switch]$GetChatId
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = $PSScriptRoot
. (Join-Path $Root 'config.ps1')

$DataDir = Join-Path $Root 'data'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$CsvPath     = Join-Path $DataDir 'listings.csv'
$LogPath     = Join-Path $DataDir 'run.log'
$DocsDir     = Join-Path $Root 'docs'      # отсюда GitHub Pages раздаёт страницу
if (-not (Test-Path $DocsDir)) { New-Item -ItemType Directory -Path $DocsDir | Out-Null }
$ReportPath  = Join-Path $DocsDir 'index.html'
$StatusPath  = Join-Path $DocsDir 'status.json'
$SummaryPath = Join-Path $DataDir 'summary.txt'
$Ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
# Ташкент: UTC+5 без перехода на летнее время. Серверы GitHub живут по UTC.
function Get-TashkentNow { [DateTime]::UtcNow.AddHours(5) }
$Today = (Get-TashkentNow).ToString('yyyy-MM-dd')

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-TashkentNow).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Format-Num($n) { ([double]$n).ToString('N0', $Ru).Replace([char]0xA0, ' ').Replace([char]0x202F, ' ') }

function Get-Median([double[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2) { return [double]$s[$m] }
    return ([double]$s[$m - 1] + [double]$s[$m]) / 2
}

# ---------------------------------------------------------------- Telegram
function Send-Telegram([string]$Text) {
    if (-not $TelegramToken -or -not $TelegramChatId) { return }
    $payload = @{ chat_id = $TelegramChatId; text = $Text; parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/sendMessage" -Method Post `
        -Body $bytes -ContentType 'application/json; charset=utf-8' | Out-Null
    Write-Log 'Сводка отправлена в Telegram'
}

if ($GetChatId) {
    if (-not $TelegramToken) { Write-Host 'Сначала впиши $TelegramToken в config.ps1'; exit 1 }
    $u = Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/getUpdates"
    if (-not $u.result) { Write-Host 'Сообщений нет. Напиши своему боту что-нибудь в Telegram и запусти ещё раз.'; exit 0 }
    $u.result | ForEach-Object { $_.message.chat } | Where-Object { $_ } |
        Sort-Object id -Unique | ForEach-Object { Write-Host ("chat_id = {0}   ({1} {2})" -f $_.id, $_.first_name, $_.username) }
    exit 0
}

# ---------------------------------------------------------------- Сбор с OLX
function Get-OlxOffers([string]$Query) {
    $all = New-Object System.Collections.ArrayList
    $offset = 0
    do {
        $url = "https://www.olx.uz/api/v1/offers/?offset=$offset&limit=50&category_id=$CategoryId&query=" + [uri]::EscapeDataString($Query)
        $resp = $null
        for ($try = 1; $try -le 3 -and -not $resp; $try++) {
            try { $resp = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 30 }
            catch { Write-Log ("  ошибка запроса (попытка {0}): {1}" -f $try, $_.Exception.Message); Start-Sleep -Seconds (5 * $try) }
        }
        if (-not $resp) { break }
        foreach ($o in $resp.data) { [void]$all.Add($o) }
        $total = [int]$resp.metadata.total_elements
        $offset += 50
        Start-Sleep -Milliseconds $PauseMs
    } while ($offset -lt $total -and $offset -lt 1000 -and $resp.data.Count -gt 0)
    return , $all
}

function Get-Model([string]$Title) {
    if ($Title -match $RxPro)     { return 'Pro' }
    if ($Title -match $RxDigital) { return 'Digital' }
    if ($Title -match $RxDisc)    { return 'С дисководом' }
    return 'Не указано'
}

function Get-Price($Offer) {
    ($Offer.params | Where-Object { $_.key -eq 'price' } | Select-Object -First 1).value
}

function Invoke-Collect {
    $raw = @{}
    foreach ($q in $Queries) {
        $items = Get-OlxOffers $q
        Write-Log ("Запрос '{0}': {1} объявлений" -f $q, $items.Count)
        foreach ($o in $items) { $raw[[string]$o.id] = $o }
    }
    Write-Log ("Уникальных объявлений: {0}" -f $raw.Count)

    # Курс у.е. -> сум, вычисленный по самим объявлениям
    $rates = foreach ($o in $raw.Values) {
        $p = Get-Price $o
        if ($p -and $p.currency -eq 'UYE' -and $p.value -gt 0 -and $p.converted_value -gt 0) { [double]$p.converted_value / [double]$p.value }
    }
    $rate = Get-Median @($rates)
    if (-not $rate) { $rate = $FallbackRate }
    Write-Log ("Курс по объявлениям: 1 у.е. = {0} сум" -f (Format-Num $rate))

    $rows = New-Object System.Collections.ArrayList
    $skipped = @{ notps5 = 0; junk = 0; multi = 0; noprice = 0; range = 0 }
    foreach ($o in $raw.Values) {
        $t = [string]$o.title
        if ($o.offer_type -and $o.offer_type -ne 'offer') { $skipped.junk++; continue }
        if ($t -notmatch $RxIsPs5) { $skipped.notps5++; continue }
        if ($t -match $RxExclude)  { $skipped.junk++; continue }
        if ($t -match $RxMulti -or ($t -match $RxDigital -and $t -match $RxDisc -and $t -notmatch $RxPro)) { $skipped.multi++; continue }
        $p = Get-Price $o
        if (-not $p -or -not $p.value) { $skipped.noprice++; continue }
        if ($p.currency -eq 'UYE') { $usd = [double]$p.value; $uzs = if ($p.converted_value) { [double]$p.converted_value } else { $usd * $rate } }
        elseif ($p.currency -eq 'UZS') { $uzs = [double]$p.value; $usd = $uzs / $rate }
        else { $skipped.noprice++; continue }
        if ($usd -lt $MinUsd -or $usd -gt $MaxUsd) { $skipped.range++; continue }

        [void]$rows.Add([pscustomobject]@{
            date      = $Today
            source    = 'live'
            id        = [string]$o.id
            model     = Get-Model $t
            hacked    = [int]($t -match $RxHacked)
            business  = [int][bool]$o.business
            price_usd = [math]::Round($usd, 0)
            price_uzs = [math]::Round($uzs, 0)
            currency  = $p.currency
            city      = [string]$o.location.city.name
            created   = ConvertTo-TashkentDate $o.created_time
            title     = ($t -replace '[\r\n]+', ' ').Trim()
            url       = [string]$o.url
        })
    }
    Write-Log ("Отобрано PS5: {0} (не PS5: {1}, мусор: {2}, сразу несколько моделей: {3}, без цены: {4}, вне диапазона цен: {5})" -f `
        $rows.Count, $skipped.notps5, $skipped.junk, $skipped.multi, $skipped.noprice, $skipped.range)
    return , $rows
}

# ---------------------------------------------------------------- Хранение
# Дата в виде yyyy-MM-dd по Ташкенту. PowerShell 7 (на GitHub) сам превращает ISO-строки из JSON
# в DateTime, а PowerShell 5.1 оставляет строкой, поэтому разбираем оба варианта.
function ConvertTo-TashkentDate($Value) {
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.AddHours(5).ToString('yyyy-MM-dd') }
    if ($Value -is [DateTime])       { return $Value.ToUniversalTime().AddHours(5).ToString('yyyy-MM-dd') }
    $s = [string]$Value
    if ($s -match '^\d{4}-\d{2}-\d{2}')        { return $s.Substring(0, 10) }
    if ($s -match '^(\d{2})/(\d{2})/(\d{4})') { return '{0}-{1}-{2}' -f $Matches[3], $Matches[1], $Matches[2] }
    return $s
}

function Read-History {
    if (-not (Test-Path $CsvPath)) { return , @() }
    $rows = @(Import-Csv -Path $CsvPath -Encoding UTF8)
    # Починка строк, сохранённых в американском формате (MM/dd/yyyy) до исправления
    foreach ($r in $rows) { if ($r.created -notmatch '^\d{4}-') { $r.created = ConvertTo-TashkentDate $r.created } }
    return , $rows
}

function Save-History($Rows) {
    $Rows | Sort-Object date, id | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
}

# ---------------------------------------------------------------- Статистика
function Get-CleanRows($Rows) {
    $base = @($Rows | Where-Object { $IncludeHacked -or $_.hacked -eq '0' -or $_.hacked -eq 0 })
    $out = New-Object System.Collections.ArrayList
    foreach ($g in ($base | Group-Object date, model)) {
        $med = Get-Median @($g.Group | ForEach-Object { [double]$_.price_usd })
        foreach ($r in $g.Group) {
            $v = [double]$r.price_usd
            if ($v -ge $med * $LowFactor -and $v -le $med * $HighFactor) { [void]$out.Add($r) }
        }
    }
    return , $out
}

function Get-DayStats($Rows, [string]$Field) {
    $v = @($Rows | ForEach-Object { [double]$_.$Field })
    if ($v.Count -eq 0) { return $null }
    $m = $v | Measure-Object -Average -Minimum -Maximum
    return [ordered]@{
        avg = [math]::Round($m.Average, 0); median = [math]::Round((Get-Median $v), 0)
        min = [math]::Round($m.Minimum, 0); max = [math]::Round($m.Maximum, 0)
    }
}

$Models = @('Digital', 'С дисководом', 'Pro', 'Не указано')

function Build-Stats($History) {
    $clean = Get-CleanRows $History
    $days = New-Object System.Collections.ArrayList
    foreach ($g in ($clean | Group-Object date | Sort-Object Name)) {
        $byModel = [ordered]@{}
        foreach ($m in $Models) {
            $mr = @($g.Group | Where-Object { $_.model -eq $m })
            $byModel[$m] = [ordered]@{
                n   = $mr.Count
                usd = if ($mr.Count) { [math]::Round((Get-Median @($mr | ForEach-Object { [double]$_.price_usd })), 0) } else { $null }
                uzs = if ($mr.Count) { [math]::Round((Get-Median @($mr | ForEach-Object { [double]$_.price_uzs })), 0) } else { $null }
            }
        }
        $allDay = @($History | Where-Object { $_.date -eq $g.Name })
        [void]$days.Add([ordered]@{
            date     = $g.Name
            backfill = [bool](@($g.Group | Where-Object { $_.source -eq 'backfill' }).Count)
            n        = $g.Count
            hacked   = @($allDay | Where-Object { $_.hacked -eq '1' -or $_.hacked -eq 1 }).Count
            usd      = Get-DayStats $g.Group 'price_usd'
            uzs      = Get-DayStats $g.Group 'price_uzs'
            models   = $byModel
        })
    }
    return @{ days = $days; clean = $clean }
}

# ---------------------------------------------------------------- Отчёт и сводка
function Write-Report($Stats, $History) {
    $lastDate = ($Stats.days | Select-Object -Last 1).date
    $lastRows = @($Stats.clean | Where-Object { $_.date -eq $lastDate })
    $prevLiveIds = @{}
    $prevDate = @($History | Where-Object { $_.date -lt $lastDate } | ForEach-Object date | Sort-Object -Unique) | Select-Object -Last 1
    if ($prevDate) { $History | Where-Object { $_.date -eq $prevDate } | ForEach-Object { $prevLiveIds[$_.id] = 1 } }

    $cheapest = @($lastRows | Sort-Object { [double]$_.price_usd } | Select-Object -First 15 | ForEach-Object {
        [ordered]@{
            title = $_.title; model = $_.model; usd = [double]$_.price_usd; uzs = [double]$_.price_uzs
            city = $_.city; created = $_.created; url = $_.url; business = ($_.business -eq '1')
            isNew = ($prevDate -and -not $prevLiveIds.ContainsKey($_.id))
        }
    })
    $generated = (Get-TashkentNow).ToString('dd.MM.yyyy HH:mm')
    $data = [ordered]@{
        generated = $generated
        repo      = [string]$env:GITHUB_REPOSITORY
        days      = @($Stats.days)
        cheapest  = $cheapest
        models    = $Models
    }
    $json = ConvertTo-Json -InputObject $data -Depth 8 -Compress
    $tpl = [IO.File]::ReadAllText((Join-Path $Root 'report-template.html'), [Text.Encoding]::UTF8)
    $html = $tpl.Replace('/*__DATA__*/null', $json)
    [IO.File]::WriteAllText($ReportPath, $html, (New-Object Text.UTF8Encoding $false))
    # Маленький файл, по которому кнопка "Обновить" понимает, что новая версия уже выложена
    $status = ConvertTo-Json -Compress -InputObject ([ordered]@{ generated = $generated; days = @($Stats.days).Count })
    [IO.File]::WriteAllText($StatusPath, $status, (New-Object Text.UTF8Encoding $false))
    Write-Log "Отчёт: $ReportPath"
}

function Get-Delta($Now, $Before) {
    if ($null -eq $Before -or $null -eq $Now) { return '' }
    $d = [double]$Now - [double]$Before
    if ([math]::Abs($d) -lt 1) { return ' (без изменений)' }
    $arrow = if ($d -lt 0) { [char]0x25BC } else { [char]0x25B2 }
    return (' ({0} ${1})' -f $arrow, (Format-Num ([math]::Abs($d))))
}

function Write-Summary($Stats, $History) {
    $days = @($Stats.days)
    if ($days.Count -eq 0) { return '' }
    $t = $days[-1]
    $y = if ($days.Count -ge 2) { $days[-2] } else { $null }
    $w = $days | Where-Object { $_.date -le ([datetime]$t.date).AddDays(-7).ToString('yyyy-MM-dd') } | Select-Object -Last 1
    $enc = { param($s) [Net.WebUtility]::HtmlEncode($s) }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add(('{0} <b>PS5 на OLX.uz, {1}</b>' -f [char]::ConvertFromUtf32(0x1F3AE), ([datetime]$t.date).ToString('dd.MM.yyyy')))
    $L.Add('')
    $L.Add(('Объявлений: <b>{0}</b>{1}' -f $t.n, $(if ($y) { " (вчера $($y.n))" } else { '' })))
    $L.Add(('Медиана: <b>${0}</b>{1}' -f (Format-Num $t.usd.median), (Get-Delta $t.usd.median $y.usd.median)))
    $L.Add(('Средняя: ${0}{1}' -f (Format-Num $t.usd.avg), (Get-Delta $t.usd.avg $y.usd.avg)))
    if ($w) { $L.Add(('За неделю медиана: ${0} → ${1}' -f (Format-Num $w.usd.median), (Format-Num $t.usd.median))) }
    $L.Add(('Мин: ${0} · Макс: ${1}' -f (Format-Num $t.usd.min), (Format-Num $t.usd.max)))
    $L.Add('')
    $L.Add('<b>Медиана по моделям</b>')
    foreach ($m in $Models) {
        $cur = $t.models[$m]
        if (-not $cur.n) { continue }
        $prev = if ($y) { $y.models[$m].usd } else { $null }
        $L.Add(('• {0}: ${1}{2}, {3} шт.' -f $m, (Format-Num $cur.usd), (Get-Delta $cur.usd $prev), $cur.n))
    }
    $L.Add('')
    $L.Add('<b>Самые дешёвые сегодня</b>')
    $i = 0
    foreach ($r in ($Stats.clean | Where-Object { $_.date -eq $t.date } | Sort-Object { [double]$_.price_usd } | Select-Object -First 5)) {
        $i++
        $title = $r.title; if ($title.Length -gt 45) { $title = $title.Substring(0, 45) + '…' }
        $L.Add(('{0}. <b>${1}</b> · {2} · <a href="{3}">{4}</a>' -f $i, (Format-Num $r.price_usd), (& $enc $r.city), $r.url, (& $enc $title)))
    }
    if ($t.hacked) { $L.Add(''); $L.Add(("Взломанных не считал: {0} шт. (GTA 6 на них не запустится)" -f $t.hacked)) }
    $text = $L -join "`n"
    [IO.File]::WriteAllText($SummaryPath, $text, (New-Object Text.UTF8Encoding $false))
    return $text
}

# ---------------------------------------------------------------- Main
$history = Read-History

if (-not $ReportOnly) {
    Write-Log '=== Сбор цен PS5 с OLX.uz ==='
    $rows = Invoke-Collect
    if ($rows.Count -eq 0) { Write-Log 'Ничего не собрано: OLX недоступен или поменял API. История не тронута.'; exit 1 }

    # Сегодняшние данные заменяют прошлый запуск за сегодня
    $history = @($history | Where-Object { $_.date -ne $Today }) + @($rows)

    if ($Backfill) {
        # OLX не хранит историю цен. Восстанавливаем по дате публикации: объявление
        # считаем активным в день D, если оно создано не позже D (с текущей ценой).
        # Проданные и удалённые объявления сюда не попадут, так что это оценка.
        $liveDates = @{}
        $history | Where-Object { $_.source -eq 'live' } | ForEach-Object { $liveDates[$_.date] = 1 }
        $history = @($history | Where-Object { $_.source -ne 'backfill' })
        $added = 0
        for ($d = $BackfillDays; $d -ge 1; $d--) {
            $day = (Get-TashkentNow).AddDays(-$d).ToString('yyyy-MM-dd')
            if ($liveDates.ContainsKey($day)) { continue }
            foreach ($r in ($rows | Where-Object { $_.created -le $day })) {
                $c = $r.PSObject.Copy(); $c.date = $day; $c.source = 'backfill'
                $history += $c; $added++
            }
        }
        Write-Log ("Восстановлено {0} записей истории за {1} дней (оценка)" -f $added, $BackfillDays)
    }
    Save-History $history
    $history = Read-History
}

$stats = Build-Stats $history
if (@($stats.days).Count -eq 0) { Write-Log 'Нет данных для отчёта'; exit 1 }
Write-Report $stats $history
$summary = Write-Summary $stats $history
Write-Host ''
Write-Host ($summary -replace '<[^>]+>', '')
if (-not $NoTelegram -and -not $ReportOnly) {
    try { Send-Telegram $summary } catch { Write-Log ("Telegram: ошибка {0}" -f $_.Exception.Message) }
}
