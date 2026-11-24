# Настройки трекера цен PS5 на OLX.uz
# Меняй здесь, основной скрипт трогать не нужно.

# --- Поиск ---
$CategoryId = 101                                   # OLX.uz: "Игровые приставки"
$Queries    = @('ps5', 'playstation 5', 'плейстейшн 5')
$PauseMs    = 1200                                  # пауза между запросами, чтобы не нагружать OLX
$Headers    = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'Accept-Language' = 'ru' }

# --- Фильтры по заголовку (регулярки, регистр не важен) ---
# В заголовке обязательно должно быть упоминание PS5
$RxIsPs5    = 'ps\s?5|пс\s?5|playstation\s?5|плейстейшн\s?5|плейстейшен\s?5|playsteyshon\s?5'
# Мусор: другие консоли, оптовые "приманки", аренда, аксессуары, игры, ремонт, "куплю"
$RxExclude  = 'ps\s?[1-4]\b|пс\s?[1-4]\b|playstation\s?[1-4]\b|xbox|nintendo|switch|optom|оптом|оптов|optov|аренд|arenda|prokat|прокат|ijara|' +
              'куплю|sotib\s?olaman|обмен|almash|джойстик|джостик|jostik|joystik|djoystik|геймпад|gamepad|dualsense|controller|' +
              '\bvr\d?\b|portal|portable|руль|rul\b|компьютер|kompyuter|клуб|klub|' +
              'ремонт|remont|запчаст|сломан|chexol|чехол|наклейк|' +
              'подставк|зарядн|televizor|телевизор|monitor|монитор'
# Объявления сразу про несколько моделей ("Fat/Slim/Pro", "с дисководом и без") - цена там "от", портит минимум
$RxMulti    = '(fat|slim|pro)\s*[/\\|,]\s*(fat|slim|pro)|disk\s*/\s*no\s*disk|и\s+без\s+дисковод|va\s+disksiz'
# Взломанные / прошитые консоли (у них старая прошивка: GTA 6 и онлайн на них не пойдут)
$RxHacked   = 'vzlom|vzlim|взлом|прошит|прошив|proshiv|goldhen|jailbreak|yozdir|yozilgan|yozib|запис|zapis|\bhen\b|10\.01'
# Модели
$RxPro      = '(?<![a-zа-я])pro\b'
$RxDigital  = 'digital|digtal|dgtil|didjital|диджитал|цифров|без\s?диск|diskovodsiz|diskavodsiz|disksiz|disk\s?siz'
$RxDisc     = 'дисковод|дискавод|diskovod|diskavod|diskavot|diskovot|discovod|diskli|с\s?диск|\bdisc\b|\bdisk\b|\bcd\b|blu-?ray'

# --- Очистка цен ---
$MinUsd        = 200      # дешевле: почти всегда аксессуар, приманка или скам
$MaxUsd        = 2000     # дороже: бандлы и ошибки в цене
$LowFactor     = 0.6      # внутри модели: дешевле 60% медианы считаем выбросом
$HighFactor    = 1.7      # дороже 170% медианы считаем выбросом
$IncludeHacked = $false   # учитывать ли взломанные консоли в статистике
$FallbackRate  = 12100    # курс сум/$ на случай, если не удалось вычислить по объявлениям

# --- Telegram (необязательно) ---
# Создай бота у @BotFather, вставь токен, напиши боту любое сообщение,
# потом запусти:  .\ps5-tracker.ps1 -GetChatId   и вставь сюда chat_id.
# На GitHub их не пишут сюда, а кладут в Settings → Secrets → Actions
# (TELEGRAM_TOKEN и TELEGRAM_CHAT_ID), иначе токен будет виден всем.
$TelegramToken  = if ($env:TELEGRAM_TOKEN)   { $env:TELEGRAM_TOKEN }   else { '' }
$TelegramChatId = if ($env:TELEGRAM_CHAT_ID) { $env:TELEGRAM_CHAT_ID } else { '' }
