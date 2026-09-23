# Podkop Subscription Sync — OpenWrt 25.x

Автоматический синхронизатор VPN-подписки для **Podkop + sing-box** на OpenWrt 25.x.

Проект предназначен для сценария, когда у вас есть одна subscription URL с большим количеством VPN-серверов, а в Podkop нужно автоматически поддерживать актуальный список рабочих нод для режима **URLTest**.

## Что делает программа

`podkop-sub-sync` автоматически:

1. Скачивает VPN-подписку по URL.
2. Определяет формат подписки:
   - обычный текст;
   - Base64;
   - gzip;
   - Base64 + gzip.
3. Извлекает поддерживаемые ссылки:
   - VLESS;
   - Trojan;
   - Shadowsocks.
4. Отбрасывает протоколы, которые отключены в настройках.
5. При необходимости исключает XHTTP-ссылки.
6. Исключает серверы выбранных стран по флагу в имени ноды.
7. Реально проверяет каждую оставшуюся ноду через временный экземпляр sing-box.
8. Оставляет только рабочие серверы.
9. Вычисляет SHA256 итогового списка.
10. Если рабочий список не изменился — Podkop не перезапускается.
11. Если список изменился:
    - обновляет `urltest_proxy_links`;
    - перезапускает Podkop;
    - ждёт генерацию ruleset-файлов;
    - проверяет итоговый конфиг через `sing-box check`.
12. Если новая конфигурация невалидна — автоматически восстанавливает предыдущую.
13. После успешного обновления Podkop самостоятельно выбирает наиболее быстрый сервер через URLTest.

Таким образом, subscription может содержать десятки или сотни серверов, а в рабочую конфигурацию Podkop попадают только актуальные и реально доступные ноды.

## Основная логика

```text
Subscription URL
       |
       v
Download
       |
       v
Base64 / gzip decode
       |
       v
Protocol filtering
       |
       v
XHTTP filtering
       |
       v
Country filtering
       |
       v
Real proxy precheck
       |
       v
Only working proxies
       |
       v
SHA256 compare
       |
       +---- unchanged ----> nothing to restart
       |
       v
Update Podkop URLTest
       |
       v
Restart Podkop
       |
       v
sing-box check
       |
       +---- error ----> rollback
       |
       v
Success
```

## Компоненты

### `/usr/bin/podkop-sub-sync`

Основной updater.

Отвечает за:

- загрузку подписки;
- декодирование Base64/gzip;
- фильтрацию протоколов;
- исключение XHTTP;
- исключение стран;
- запуск proxy precheck;
- обновление UCI-конфигурации Podkop;
- проверку sing-box;
- rollback при ошибке.

### `/usr/bin/podkop-sub-precheck`

Проверяет ноды до помещения в Podkop.

Для каждой группы серверов:

- создаёт временный конфиг sing-box;
- поднимает локальные mixed proxy-порты;
- направляет каждый локальный порт в конкретный outbound;
- выполняет HTTP-проверку через этот proxy;
- оставляет только успешно прошедшие ноды.

Проверка выполняется реальным трафиком через конкретный VPN-сервер, а не простым TCP-connect к IP/порту.

### `/usr/bin/podkop-sub-sync-daemon`

Периодически запускает updater.

После успешной синхронизации ждёт:

```text
interval
```

После ошибки повторяет попытку через:

```text
retry_interval
```

### `/etc/init.d/podkop-sub-sync`

Сервис OpenWrt `procd`.

Обеспечивает:

- автозапуск после загрузки;
- автоматический respawn daemon;
- вывод stdout/stderr в `logread`.

### `/etc/config/podkop-sub-sync`

Основной UCI-конфиг программы.

## Требования

До установки должны быть установлены и настроены:

- OpenWrt 25.x;
- Podkop;
- sing-box;
- curl;
- jq.

Также должен существовать:

```text
/usr/lib/podkop/sing_box_config_facade.sh
```

## Установка

### Через installer

```sh
chmod +x install-podkop-sub-sync.sh

./install-podkop-sub-sync.sh \
    --url 'https://example.com/sub/xxxxx' \
    --interval 86400 \
    --exclude RU
```

Несколько исключаемых стран:

```sh
./install-podkop-sub-sync.sh \
    --url 'https://example.com/sub/xxxxx' \
    --interval 86400 \
    --exclude RU \
    --exclude UZ
```
## Установка одной командой

На OpenWrt BusyBox `ash` лучше использовать pipe, а не bash process substitution.

Не рекомендуется:

```sh
sh <(wget -O - URL)
```

Рекомендуется:

```sh
wget -qO- https://raw.githubusercontent.com/Trogvars/podkop-sub-sync/main/install.sh \
    | sh -s -- \
        --url 'https://example.com/sub/xxxxx' \
        --interval 86400 \
        --exclude RU
```

Несколько стран:

```sh
wget -qO- https://raw.githubusercontent.com/Trogvars/podkop-sub-sync/main/install.sh \
    | sh -s -- \
        --url 'https://example.com/sub/xxxxx' \
        --interval 86400 \
        --exclude RU \
        --exclude UZ
```


## Конфигурация

Пример:

```text
config sync 'main'
        option enabled '1'
        option url 'https://example.com/sub/xxxxx'
        option target 'main'

        option interval '86400'
        option retry_interval '900'

        option user_agent 'podkop-sub-sync/1.0'
        option send_hwid '0'
        option allow_xhttp '0'

        option enable_vless '1'
        option enable_trojan '1'
        option enable_ss '1'

        list exclude_country 'RU'

        option precheck_enabled '1'
        option precheck_url 'https://www.gstatic.com/generate_204'
        option precheck_http_code '204'
        option precheck_connect_timeout '3'
        option precheck_timeout '7'
        option precheck_batch_size '6'
        option precheck_base_port '39000'
        option precheck_min_nodes '3'
        option precheck_min_percent '20'
```

## Основные параметры

### `enabled`

```text
option enabled '1'
```

Включает daemon.

### `url`

```text
option url 'https://example.com/sub/...'
```

Subscription URL.

### `target`

```text
option target 'main'
```

Секция `/etc/config/podkop`, в которую записывается список URLTest.

### `interval`

```text
option interval '86400'
```

Интервал успешной синхронизации в секундах.

`86400` = 24 часа.

### `retry_interval`

```text
option retry_interval '900'
```

Через сколько секунд повторить попытку после ошибки.

`900` = 15 минут.

### Включение протоколов

```text
option enable_vless '1'
option enable_trojan '1'
option enable_ss '1'
```

Можно отключить ненужные:

```sh
uci set podkop-sub-sync.main.enable_ss='0'
uci commit podkop-sub-sync
```

### Исключение XHTTP

```text
option allow_xhttp '0'
```

`0` — XHTTP-ссылки удаляются.

`1` — разрешаются.

### Исключение стран

Например:

```text
list exclude_country 'RU'
list exclude_country 'UZ'
```

Фильтрация выполняется по emoji-флагу страны в fragment/name VPN-ссылки.

### Precheck

```text
option precheck_enabled '1'
```

Включает реальную проверку proxy.

URL проверки:

```text
option precheck_url 'https://www.gstatic.com/generate_204'
```

Ожидаемый HTTP-код:

```text
option precheck_http_code '204'
```

Timeout:

```text
option precheck_connect_timeout '3'
option precheck_timeout '7'
```

Размер группы:

```text
option precheck_batch_size '6'
```

Для роутеров с небольшим объёмом RAM рекомендуется оставлять небольшой batch size.

### Защита от массового ложного отказа

```text
option precheck_min_nodes '3'
option precheck_min_percent '20'
```

Если проходит слишком мало серверов, программа считает, что проблема может быть в Интернете или test URL, и не заменяет текущую рабочую конфигурацию Podkop.

## Проверка вручную

Запустить updater:

```sh
/usr/bin/podkop-sub-sync
```

Проверить сервис:

```sh
ubus call service list '{"name":"podkop-sub-sync"}'
```

Посмотреть процессы:

```sh
ps w | grep '[p]odkop-sub-sync'
```

Логи:

```sh
logread | grep podkop-sub-sync
```

Последние 100 строк:

```sh
logread | grep podkop-sub-sync | tail -100
```

## Управление сервисом

```sh
/etc/init.d/podkop-sub-sync enable
/etc/init.d/podkop-sub-sync start
```

Перезапуск:

```sh
/etc/init.d/podkop-sub-sync restart
```

Остановка:

```sh
/etc/init.d/podkop-sub-sync stop
```

Отключение автозапуска:

```sh
/etc/init.d/podkop-sub-sync disable
```

## Проверка итогового списка

Количество URLTest links:

```sh
uci -q get podkop.main.urltest_proxy_links
```

Или:

```sh
uci show podkop.main | grep urltest_proxy_links
```

## Защита конфигурации

Перед обновлением программа делает backup:

```text
/etc/config/podkop
```

Если:

- Podkop не перезапустился;
- sing-box config не прошёл проверку;
- ruleset не сформировался корректно;
- sing-box не запустился;

предыдущая конфигурация автоматически восстанавливается.

## Обновление пакета

Для OpenWrt 25.x используется package manager:

```text
apk
```

Формат пакета:

```text
.apk
```

Проект можно собрать через OpenWrt 25.x SDK.

Так как внутри только shell/UCI-файлы:

```makefile
PKGARCH:=all
```

## Особенность OpenWrt 25.x

Эта ветка рассчитана на новую package infrastructure OpenWrt 25.x.

Для OpenWrt 24.x используется отдельная версия проекта:

```text
podkop-sub-sync-openwrt24
```

В ней:

- `opkg`;
- `.ipk`;
- совместимость со старыми curl/libcurl;
- не используется `curl --compressed`.

## Типичный рабочий сценарий

Например, subscription содержит:

```text
102 proxy links
```

После фильтрации:

```text
27 XHTTP removed
9 RU nodes removed
```

остаётся:

```text
66 candidates
```

После реального precheck:

```text
41 working
25 failed
```

Именно эти 41 рабочая нода записываются в Podkop URLTest.

Далее Podkop самостоятельно измеряет latency и выбирает лучший сервер по своим настройкам URLTest.

## Лицензия

MIT
