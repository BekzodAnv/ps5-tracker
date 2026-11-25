# Настройки трекера цен PS5 на OLX.uz
# Меняй здесь, основной скрипт трогать не нужно.

# --- Поиск ---
$CategoryId = 101                                   # OLX.uz: "Игровые приставки"
$Queries    = @('ps5', 'playstation 5', 'плейстейшн 5')
$PauseMs    = 1200                                  # пауза между запросами, чтобы не нагружать OLX
$Headers    = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'Accept-Language' = 'ru' }

# --- Telegram-каналы с ценами ---
# Только публичные каналы с включённым веб-просмотром (открываются по адресу t.me/s/имя).
# Kompyuter_playstation_texnikaa не добавлен: у него веб-просмотр выключен, без аккаунта его не прочитать.
$TgChannels    = @('topgameuzb', 'pllayboxuz', 'ps_malika_a34', 'GameTech_PS', 'Gamer_zone_uz', 'ps_promarket')
$TgActiveDays  = 4     # сколько дней после публикации пост считается актуальным предложением
$TgHistoryDays = 10    # на сколько дней назад восстанавливать историю из каналов (это настоящие посты, не оценка)
$RxTgUsd = '(?<![\d+])(\d{1,3}(?:[ .,]\d{3})+|\d{2,5})\s?(?:\$|у\.?\s?е\b|y\.?\s?e\b|dollar|долл)|\$\s?(\d{2,5})'
$RxTgUzs = '(?<![\d+])(\d{1,3}(?:[ .,]\d{3}){2,}|\d{6,9})\s?(?:сум|so[''`\u2019\u02BB]?m\b|sum\b|uzs)'
# "млн" считаем ценой только с валютой рядом: иначе "9,69 млн предзаказов" из новости становится ценой
$RxTgMln = '(?<![\d.,])(\d{1,2}(?:[.,]\d{1,3})?)\s?(?:млн|mln|million|миллион)\.?\s?(?:сум|so[''`\u2019\u02BB]?m\b|sum\b|uzs)'
$RxTgCity = 'toshkent|ташкент|tashkent|malika'

# --- Магазины (новые консоли с гарантией) ---
# Считаются отдельным источником и не смешиваются с ценами "с рук" (OLX + Telegram).
$ShopsEnabled   = $true
$AsaxiyUrl      = 'https://asaxiy.uz/product?key=playstation+5'
$GlotrUrl       = 'https://glotr.uz/search/?term=playstation+5'
# В магазинах в выдаче много аксессуаров "для PS5" / "PS5 uchun" - их отсекаем
$RxShopExclude  = '\bдля\b|uchun|камера|kamera|гарнитур|garnitura|шлем|станци|stansiya|дисковод для|drayver uchun'

# --- Фильтры по заголовку (регулярки, регистр не важен) ---
# В заголовке обязательно должно быть упоминание PS5
$RxIsPs5    = 'ps\s?5|пс\s?5|play\s?station\w{0,2}\W{0,3}5|плейстейшн\s?5|плейстейшен\s?5|playsteyshon\s?5'
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
$RxDisc     = 'disk\s?drayver|приводом|дисковод|дискавод|diskovod|diskavod|diskavot|diskovot|discovod|diskli|с\s?диск|\bdisc\b|\bdisk\b|\bcd\b|blu-?ray'

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
