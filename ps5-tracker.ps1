<#
  Трекер цен PS5: OLX.uz + публичные Telegram-каналы.
  Обычный запуск (раз в день):  .\ps5-tracker.ps1
  Оценить историю OLX назад:    .\ps5-tracker.ps1 -Backfill -BackfillDays 10
  Только пересобрать страницу:  .\ps5-tracker.ps1 -ReportOnly
  Узнать chat_id для Telegram:  .\ps5-tracker.ps1 -GetChatId
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
$script:Rate = $FallbackRate
# Что вернул каждый источник за этот запуск. Пишется в docs/status.json, чтобы было видно,
# если какой-то сайт перестал отдавать данные (например, начал блокировать серверы GitHub).
$script:Health = [ordered]@{}
$Models = @('Digital', 'С дисководом', 'Pro', 'Не указано')

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

function Get-Model([string]$Title) {
    if ($Title -match $RxPro)     { return 'Pro' }
    if ($Title -match $RxDigital) { return 'Digital' }
    if ($Title -match $RxDisc)    { return 'С дисководом' }
    return 'Не указано'
}

# ---------------------------------------------------------------- Telegram-бот (сводка)
function Send-Telegram([string]$Text) {
    if (-not $TelegramToken -or -not $TelegramChatId) { return }
    $payload = @{ chat_id = $TelegramChatId; text = $Text; parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/sendMessage" -Method Post `
        -Body $bytes -ContentType 'application/json; charset=utf-8' | Out-Null
    Write-Log 'Сводка отправлена в Telegram'
}

if ($GetChatId) {
    if (-not $TelegramToken) { Write-Host 'Сначала задай токен: $env:TELEGRAM_TOKEN = "..."'; exit 1 }
    $u = Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/getUpdates"
    if (-not $u.result) { Write-Host 'Сообщений нет. Напиши своему боту что-нибудь в Telegram и запусти ещё раз.'; exit 0 }
    $u.result | ForEach-Object { $_.message.chat } | Where-Object { $_ } |
        Sort-Object id -Unique | ForEach-Object { Write-Host ("chat_id = {0}   ({1} {2})" -f $_.id, $_.first_name, $_.username) }
    exit 0
}

# ---------------------------------------------------------------- OLX
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

function Get-Price($Offer) {
    ($Offer.params | Where-Object { $_.key -eq 'price' } | Select-Object -First 1).value
}

function Invoke-CollectOlx {
    $raw = @{}
    foreach ($q in $Queries) {
        $items = Get-OlxOffers $q
        Write-Log ("OLX, запрос '{0}': {1} объявлений" -f $q, $items.Count)
        foreach ($o in $items) { $raw[[string]$o.id] = $o }
    }
    Write-Log ("OLX: уникальных объявлений {0}" -f $raw.Count)

    # Курс у.е. -> сум, вычисленный по самим объявлениям (нужен и для Telegram)
    $rates = foreach ($o in $raw.Values) {
        $p = Get-Price $o
        if ($p -and $p.currency -eq 'UYE' -and $p.value -gt 0 -and $p.converted_value -gt 0) { [double]$p.converted_value / [double]$p.value }
    }
    $rate = Get-Median @($rates)
    if ($rate) { $script:Rate = $rate }
    Write-Log ("Курс по объявлениям: 1 у.е. = {0} сум" -f (Format-Num $script:Rate))

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
        if ($p.currency -eq 'UYE') { $usd = [double]$p.value; $uzs = if ($p.converted_value) { [double]$p.converted_value } else { $usd * $script:Rate } }
        elseif ($p.currency -eq 'UZS') { $uzs = [double]$p.value; $usd = $uzs / $script:Rate }
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
            # OLX показывает как "Опубликовано" дату последнего поднятия/обновления, а не создания
            posted    = ConvertTo-TashkentDate $(if ($o.last_refresh_time) { $o.last_refresh_time } else { $o.created_time })
            title     = ($t -replace '[\r\n]+', ' ').Trim()
            url       = [string]$o.url
            origin    = 'olx'
        })
    }
    Write-Log ("OLX: отобрано PS5 {0} (не PS5: {1}, мусор: {2}, сразу несколько моделей: {3}, без цены: {4}, вне диапазона цен: {5})" -f `
        $rows.Count, $skipped.notps5, $skipped.junk, $skipped.multi, $skipped.noprice, $skipped.range)
    $script:Health['olx'] = "объявлений $($raw.Count), PS5 $($rows.Count)"
    return , $rows
}

# ---------------------------------------------------------------- Telegram-каналы
# Публичная веб-версия канала t.me/s/<имя>: ~20 постов на страницу, листается параметром ?before=<id поста>.
function Get-TgMessages([string]$Channel, [string]$SinceDate) {
    $out = @{}
    $before = $null
    for ($page = 0; $page -lt 25; $page++) {
        $url = "https://t.me/s/$Channel"
        if ($before) { $url += "?before=$before" }
        $resp = $null
        try { $resp = Invoke-WebRequest -Uri $url -Headers $Headers -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop } catch { }
        if (-not $resp -or $resp.StatusCode -ne 200) {
            if ($page -eq 0) {
                Write-Log ("Telegram @{0}: канал не открылся (закрыт или выключен веб-просмотр)" -f $Channel)
                $script:Health["tg:$Channel"] = 'не открылся'
            }
            break
        }
        $blocks = @(([string]$resp.Content) -split '<div class="tgme_widget_message_wrap' | Select-Object -Skip 1)
        if ($blocks.Count -eq 0) { break }
        $minId = [int]::MaxValue
        $oldest = '9999-99-99'
        foreach ($b in $blocks) {
            $mId = [regex]::Match($b, 'data-post="[^/"]+/(\d+)"')
            if (-not $mId.Success) { continue }
            $id = [int]$mId.Groups[1].Value
            if ($id -lt $minId) { $minId = $id }
            $mDt = [regex]::Match($b, 'class="tgme_widget_message_date"[^>]*>\s*<time datetime="([^"]+)"')
            if (-not $mDt.Success) { continue }
            $date = ConvertTo-TashkentDate ([DateTimeOffset]::Parse($mDt.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture))
            if ($date -lt $oldest) { $oldest = $date }
            $mTx = [regex]::Match($b, '<div class="tgme_widget_message_text[^"]*"[^>]*>([\s\S]*?)</div>')
            if (-not $mTx.Success) { continue }
            $text = $mTx.Groups[1].Value -replace '<br\s*/?>', "`n" -replace '<[^>]+>', ''
            $out[$id] = [pscustomobject]@{ channel = $Channel; id = $id; date = $date; text = [Net.WebUtility]::HtmlDecode($text) }
        }
        if ($minId -eq [int]::MaxValue -or $minId -le 1 -or $oldest -lt $SinceDate) { break }
        $before = $minId
        Start-Sleep -Milliseconds $PauseMs
    }
    return , @($out.Values)
}

# Первая цена в строке: "1 440$", "Narxi:630$", "$650", "5 500 000 сум", "5.5 млн"
function Get-TgPrice([string]$Line) {
    $l = $Line.ToLower().Replace([char]0xA0, ' ')
    $m = [regex]::Match($l, $RxTgUsd)
    if ($m.Success) {
        $usd = [double](($m.Groups[1].Value + $m.Groups[2].Value) -replace '[ .,]', '')
        return @{ usd = $usd; uzs = $usd * $script:Rate; cur = 'USD' }
    }
    $m = [regex]::Match($l, $RxTgUzs)
    if ($m.Success) {
        $uzs = [double]($m.Groups[1].Value -replace '[ .,]', '')
        return @{ usd = $uzs / $script:Rate; uzs = $uzs; cur = 'UZS' }
    }
    $m = [regex]::Match($l, $RxTgMln)
    if ($m.Success) {
        $uzs = [double]($m.Groups[1].Value.Replace(',', '.')) * 1e6
        return @{ usd = $uzs / $script:Rate; uzs = $uzs; cur = 'UZS' }
    }
    return $null
}

function Get-CleanTitle([string]$Text) {
    $t = ($Text -replace '[^\p{L}\p{N}\s\.,:;/()+\-$%№''"!?\u2019\u02BB]', ' ' -replace '\s+', ' ').Trim(' ', ':', '-', '.')
    if ($t.Length -gt 100) { $t = $t.Substring(0, 100).TrimEnd() + '…' }
    return $t
}

# Разбор поста построчно: строка с PS5 открывает позицию, первая подходящая цена после неё её закрывает.
# Так читаются и прайс-листы на несколько моделей, и анкеты "PlayStation:5 slim ... Narxi:630$".
function Get-TgItems($Msg) {
    $items = New-Object System.Collections.ArrayList
    $title = $null
    $ctx = New-Object System.Collections.Generic.List[string]
    $n = 0
    if ($Msg.text -match $RxTgSold) { return , $items }
    $city = if ($Msg.text -match $RxTgCity) { 'Ташкент' } else { '' }
    foreach ($raw in ($Msg.text -split "`n")) {
        $l = $raw.Trim()
        if (-not $l) { continue }
        if ($l -match $RxIsPs5) {
            if ($l -match $RxExclude -or $l -match $RxMulti) { $title = $null; $ctx.Clear(); continue }
            $title = $l; $ctx.Clear(); $ctx.Add($l)
        } elseif ($title) { $ctx.Add($l) }
        if (-not $title) { continue }
        $p = Get-TgPrice $l
        if (-not $p -or $p.usd -lt $MinUsd -or $p.usd -gt $MaxUsd) { continue }   # "+65$ за джойстик" не закрывает позицию

        $all = $ctx -join ' '
        $model = Get-Model $title
        if ($model -eq 'Не указано' -and -not ($all -match $RxDigital -and $all -match $RxDisc)) { $model = Get-Model $all }
        # Название: строка с PS5 и пара следующих коротких строк (б/у, память), без строки с ценой
        $parts = if ($ctx.Count -gt 1) { @($ctx | Select-Object -First ([math]::Min(3, $ctx.Count - 1))) } else { @($ctx) }
        $n++
        [void]$items.Add([pscustomobject]@{
            date      = ''
            source    = 'live'
            id        = ('tg:{0}/{1}-{2}' -f $Msg.channel, $Msg.id, $n)
            model     = $model
            hacked    = [int]($all -match $RxHacked)
            business  = 1
            price_usd = [math]::Round($p.usd, 0)
            price_uzs = [math]::Round($p.uzs, 0)
            currency  = $p.cur
            city      = $city
            created   = $Msg.date
            title     = Get-CleanTitle ($parts -join ' · ')
            url       = ('https://t.me/{0}/{1}' -f $Msg.channel, $Msg.id)
            origin    = 'tg:' + $Msg.channel
        })
        $title = $null; $ctx.Clear()
    }
    return , $items
}

function Invoke-CollectTelegram {
    $since = (Get-TashkentNow).AddDays(-($TgHistoryDays + $TgActiveDays)).ToString('yyyy-MM-dd')
    $items = New-Object System.Collections.ArrayList
    foreach ($ch in $TgChannels) {
        $msgs = Get-TgMessages $ch $since
        $cnt = 0
        foreach ($m in $msgs) { foreach ($it in (Get-TgItems $m)) { [void]$items.Add($it); $cnt++ } }
        Write-Log ("Telegram @{0}: постов {1}, позиций PS5 с ценой {2}" -f $ch, $msgs.Count, $cnt)
        if (-not $script:Health.Contains("tg:$ch")) { $script:Health["tg:$ch"] = "постов $($msgs.Count), позиций $cnt" }
    }
    return , $items
}

# Предложения из каналов, актуальные на день Day: опубликованы за последние $TgActiveDays дней.
# Одно и то же предложение (канал + модель + цена) каналы постят по много раз, оставляем самый свежий пост.
function Get-TgSnapshot($Items, [string]$Day) {
    $from = ([datetime]$Day).AddDays(-($TgActiveDays - 1)).ToString('yyyy-MM-dd')
    $active = @($Items | Where-Object { $_.created -le $Day -and $_.created -ge $from })
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($it in ($active | Sort-Object { $_.created }, { [int](($_.url -split '/')[-1]) } -Descending)) {
        $key = '{0}|{1}|{2}' -f $it.origin, $it.model, $it.price_usd
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = 1
        $c = $it.PSObject.Copy(); $c.date = $Day
        [void]$out.Add($c)
    }
    return , $out
}

# ---------------------------------------------------------------- Хранение
function Read-History {
    if (-not (Test-Path $CsvPath)) { return , @() }
    $rows = @(Import-Csv -Path $CsvPath -Encoding UTF8)
    if ($rows.Count -and -not ($rows[0].PSObject.Properties.Name -contains 'origin')) {
        foreach ($r in $rows) { $r | Add-Member -NotePropertyName origin -NotePropertyValue 'olx' }   # история до Telegram
    }
    # Починка строк, сохранённых в американском формате (MM/dd/yyyy)
    foreach ($r in $rows) { if ($r.created -notmatch '^\d{4}-') { $r.created = ConvertTo-TashkentDate $r.created } }
    Add-PostedColumn $rows
    return , $rows
}

# posted: дата, которую площадка показывает как дату публикации. В старых строках её нет, берём created.
function Add-PostedColumn($Rows) {
    foreach ($r in $Rows) {
        if (-not ($r.PSObject.Properties.Name -contains 'posted')) { $r | Add-Member -NotePropertyName posted -NotePropertyValue $r.created }
        elseif (-not $r.posted) { $r.posted = $r.created }
    }
}

function Save-History($Rows) {
    Add-PostedColumn $Rows
    $cols = 'date','source','id','model','hacked','business','price_usd','price_uzs','currency','city','created','posted','title','url','origin'
    $Rows | Sort-Object date, id | Select-Object $cols | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
}

# ---------------------------------------------------------------- Статистика
function Test-Hacked($r) { $r.hacked -eq '1' -or $r.hacked -eq 1 }

function Get-CleanRows($Rows) {
    $base = @($Rows | Where-Object { $IncludeHacked -or -not (Test-Hacked $_) })
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
    $v = @($Rows | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_.$Field })
    if ($v.Count -eq 0) { return $null }
    $m = $v | Measure-Object -Average -Minimum -Maximum
    return [ordered]@{
        avg = [math]::Round($m.Average, 0); median = [math]::Round((Get-Median $v), 0)
        min = [math]::Round($m.Minimum, 0); max = [math]::Round($m.Maximum, 0)
    }
}

function Build-SourceDays($Clean, $Hist, $Dates) {
    $byDate = @{}
    foreach ($r in $Clean) {
        if (-not $byDate.ContainsKey($r.date)) { $byDate[$r.date] = New-Object System.Collections.ArrayList }
        [void]$byDate[$r.date].Add($r)
    }
    $hacked = @{}
    foreach ($r in $Hist) { if (Test-Hacked $r) { $hacked[$r.date] = 1 + [int]$hacked[$r.date] } }
    $days = New-Object System.Collections.ArrayList
    foreach ($d in $Dates) {
        $g = @(if ($byDate.ContainsKey($d)) { $byDate[$d] })   # @() снаружи: пустой день = пустой массив, а не $null
        $byModel = [ordered]@{}
        foreach ($m in $Models) {
            $mr = @($g | Where-Object { $_.model -eq $m })
            $byModel[$m] = [ordered]@{
                n   = $mr.Count
                usd = if ($mr.Count) { [math]::Round((Get-Median @($mr | ForEach-Object { [double]$_.price_usd })), 0) } else { $null }
                uzs = if ($mr.Count) { [math]::Round((Get-Median @($mr | ForEach-Object { [double]$_.price_uzs })), 0) } else { $null }
            }
        }
        [void]$days.Add([ordered]@{
            date     = $d
            backfill = [bool](@($g | Where-Object { $_.source -eq 'backfill' }).Count)
            n        = $g.Count
            hacked   = [int]$hacked[$d]
            usd      = Get-DayStats $g 'price_usd'
            uzs      = Get-DayStats $g 'price_uzs'
            models   = $byModel
        })
    }
    return , $days
}

function Get-Cheapest($Clean, $Hist, [string]$LastDate) {
    $prevDate = @($Hist | Where-Object { $_.date -lt $LastDate } | ForEach-Object date | Sort-Object -Unique) | Select-Object -Last 1
    $prevIds = @{}
    if ($prevDate) { $Hist | Where-Object { $_.date -eq $prevDate } | ForEach-Object { $prevIds[$_.id] = 1 } }
    return , @($Clean | Where-Object { $_.date -eq $LastDate } | Sort-Object { [double]$_.price_usd } | Select-Object -First 15 | ForEach-Object {
        [ordered]@{
            title = $_.title; model = $_.model; usd = [double]$_.price_usd; uzs = [double]$_.price_uzs
            city = $_.city; created = $(if ($_.posted) { $_.posted } else { $_.created }); url = $_.url; business = ($_.business -eq '1')
            origin = $_.origin; isNew = [bool]($prevDate -and -not $prevIds.ContainsKey($_.id))
        }
    })
}

function Build-Stats($History) {
    $clean = Get-CleanRows $History
    $dates = @($History | ForEach-Object date | Sort-Object -Unique)
    $last = $dates[-1]
    $filters = [ordered]@{
        all = { $true }
        olx = { $_.origin -eq 'olx' }
        tg  = { $_.origin -like 'tg:*' }
    }
    $sources = [ordered]@{}
    foreach ($k in $filters.Keys) {
        $c = @($clean | Where-Object -FilterScript $filters[$k])
        $h = @($History | Where-Object -FilterScript $filters[$k])
        $sources[$k] = [ordered]@{ days = (Build-SourceDays $c $h $dates); cheapest = (Get-Cheapest $c $h $last) }
    }
    return @{ clean = $clean; dates = $dates; sources = $sources; days = $sources['all'].days }
}

# ---------------------------------------------------------------- Страница и сводка
function Write-Report($Stats) {
    $generated = (Get-TashkentNow).ToString('dd.MM.yyyy HH:mm')
    $data = [ordered]@{
        generated = $generated
        repo      = [string]$env:GITHUB_REPOSITORY
        models    = $Models
        tg        = [ordered]@{ channels = @($TgChannels); activeDays = $TgActiveDays }
        sources   = $Stats.sources
    }
    $json = ConvertTo-Json -InputObject $data -Depth 10 -Compress
    $tpl = [IO.File]::ReadAllText((Join-Path $Root 'report-template.html'), [Text.Encoding]::UTF8)
    $html = $tpl.Replace('/*__DATA__*/null', $json)
    [IO.File]::WriteAllText($ReportPath, $html, (New-Object Text.UTF8Encoding $false))
    # Маленький файл, по которому кнопка "Обновить" понимает, что новая версия уже выложена
    $status = ConvertTo-Json -Compress -InputObject ([ordered]@{ generated = $generated; days = @($Stats.dates).Count; sources = $script:Health })
    [IO.File]::WriteAllText($StatusPath, $status, (New-Object Text.UTF8Encoding $false))
    Write-Log "Страница: $ReportPath"
}

function Get-Delta($Now, $Before) {
    if ($null -eq $Before -or $null -eq $Now) { return '' }
    $d = [double]$Now - [double]$Before
    if ([math]::Abs($d) -lt 1) { return ' (без изменений)' }
    $arrow = if ($d -lt 0) { [char]0x25BC } else { [char]0x25B2 }
    return (' ({0} ${1})' -f $arrow, (Format-Num ([math]::Abs($d))))
}

function Write-Summary($Stats) {
    $days = @($Stats.days)
    if ($days.Count -eq 0) { return '' }
    $t = $days[-1]
    $y = if ($days.Count -ge 2) { $days[-2] } else { $null }
    $w = $days | Where-Object { $_.date -le ([datetime]$t.date).AddDays(-7).ToString('yyyy-MM-dd') } | Select-Object -Last 1
    $nOlx = @($Stats.sources['olx'].days)[-1].n
    $nTg  = @($Stats.sources['tg'].days)[-1].n
    $enc = { param($s) [Net.WebUtility]::HtmlEncode($s) }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add(('{0} <b>Цены на PS5, {1}</b>' -f [char]::ConvertFromUtf32(0x1F3AE), ([datetime]$t.date).ToString('dd.MM.yyyy')))
    $L.Add('')
    $L.Add(('Предложений: <b>{0}</b>{1} · OLX {2}, Telegram {3}' -f $t.n, $(if ($y) { " (вчера $($y.n))" } else { '' }), $nOlx, $nTg))
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
        $where = if ($r.origin -like 'tg:*') { '@' + $r.origin.Substring(3) } elseif ($r.city) { $r.city } else { 'OLX' }
        $L.Add(('{0}. <b>${1}</b> · {2} · <a href="{3}">{4}</a>' -f $i, (Format-Num $r.price_usd), (& $enc $where), $r.url, (& $enc $title)))
    }
    if ($t.hacked) { $L.Add(''); $L.Add(("Взломанных не считал: {0} шт. (GTA 6 на них не запустится)" -f $t.hacked)) }
    $text = $L -join "`n"
    [IO.File]::WriteAllText($SummaryPath, $text, (New-Object Text.UTF8Encoding $false))
    return $text
}

# ---------------------------------------------------------------- Main
$history = Read-History

if (-not $ReportOnly) {
    Write-Log '=== Сбор цен PS5 ==='
    $olxRows = Invoke-CollectOlx
    if ($olxRows.Count -eq 0) { Write-Log 'С OLX ничего не собрано: сайт недоступен или поменял API. История не тронута.'; exit 1 }
    $tgItems = if ($TgChannels) { Invoke-CollectTelegram } else { @() }
    $tgToday = Get-TgSnapshot $tgItems $Today
    Write-Log ("Telegram: актуальных предложений сегодня {0}" -f $tgToday.Count)

    # Сегодняшние данные заменяют прошлый запуск за сегодня
    $history = @($history | Where-Object { $_.date -ne $Today }) + @($olxRows) + @($tgToday)

    if ($Backfill) {
        # OLX не хранит историю цен. Восстанавливаем по дате публикации: объявление
        # считаем активным в день D, если оно создано не позже D (с текущей ценой).
        # Проданные и удалённые объявления сюда не попадут, так что это оценка.
        $liveDates = @{}
        $history | Where-Object { $_.origin -eq 'olx' -and $_.source -eq 'live' } | ForEach-Object { $liveDates[$_.date] = 1 }
        $history = @($history | Where-Object { $_.source -ne 'backfill' })
        $added = 0
        for ($d = $BackfillDays; $d -ge 1; $d--) {
            $day = (Get-TashkentNow).AddDays(-$d).ToString('yyyy-MM-dd')
            if ($liveDates.ContainsKey($day)) { continue }
            foreach ($r in ($olxRows | Where-Object { $_.created -le $day })) {
                $c = $r.PSObject.Copy(); $c.date = $day; $c.source = 'backfill'
                $history += $c; $added++
            }
        }
        Write-Log ("OLX: восстановлено {0} записей истории за {1} дней (оценка)" -f $added, $BackfillDays)
    }

    # История Telegram за прошлые дни настоящая (посты с датами), поэтому дозаполняем её всегда:
    # для каждого прошлого дня и канала, где данных ещё нет.
    $haveTg = @{}
    $history | Where-Object { $_.origin -like 'tg:*' } | ForEach-Object { $haveTg["$($_.date)|$($_.origin)"] = 1 }
    $fromDay = (Get-TashkentNow).AddDays(-$TgHistoryDays).ToString('yyyy-MM-dd')
    $pastDays = @($history | ForEach-Object date | Sort-Object -Unique | Where-Object { $_ -lt $Today -and $_ -ge $fromDay })
    $addedTg = 0
    foreach ($day in $pastDays) {
        foreach ($ch in $TgChannels) {
            if ($haveTg.ContainsKey("$day|tg:$ch")) { continue }
            foreach ($r in (Get-TgSnapshot @($tgItems | Where-Object { $_.origin -eq "tg:$ch" }) $day)) { $history += $r; $addedTg++ }
        }
    }
    if ($addedTg) { Write-Log ("Telegram: добавлено {0} записей истории за прошлые дни" -f $addedTg) }

    Save-History $history
    $history = Read-History
}

if (@($history).Count -eq 0) { Write-Log 'Нет данных для страницы'; exit 1 }
$stats = Build-Stats $history
Write-Report $stats
$summary = Write-Summary $stats
Write-Host ''
Write-Host ($summary -replace '<[^>]+>', '')
if (-not $NoTelegram -and -not $ReportOnly) {
    try { Send-Telegram $summary } catch { Write-Log ("Telegram-бот: ошибка {0}" -f $_.Exception.Message) }
}
