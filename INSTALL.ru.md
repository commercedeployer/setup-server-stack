# Установка Setup Server Stack

**English:** [INSTALL.md](INSTALL.md)

Инструкция для первого запуска **Setup Server Stack**: подготовка, пароли, проверка после установки, эксплуатация.

---

## 1. Что это за «стек» простыми словами

На одном Linux-сервере (VPS) поднимаются контейнеры:

| Зачем | Сервис |
|-------|--------|
| HTTPS и маршруты к поддоменам | **Traefik** |
| Хранение Docker-образов | **Registry** + **docker_auth** (логин `docker login`) |
| Управление Docker с браузера | **Portainer** |
| Обновление образов по расписанию | **Watchtower** |
| CI/задачи | **Semaphore** |
| Обзор занятости диска Docker | **Doku** |
| Бэкапы | **Duplicati** |
| Мониторинг доступности сайтов | **Uptime Kuma** |
| Файловый менеджер | **Filebrowser** |
| Опционально приложение деплоя | **Deployer** (готовый образ из `DEPLOYER_IMAGE`) |
| Опционально БД и веб-морды | Mongo, Postgres, MariaDB, MySQL, mongo-express, pgAdmin, Adminer |

Всё открывается по адресам вида `https://имя-сервиса.ваш-домен.ru`. Один параметр **`DOMAIN`** в настройках задаёт все эти поддомены автоматически.

---

## 2. Что нужно ДО установки

### 2.1. Сервер

- **Linux** (обычно Ubuntu/Debian) с доступом по **SSH**.
- **Docker** и **Docker Compose v2** (`docker compose`, не старый `docker-compose` как отдельная команда). При **`INSTALL_DOCKER=1`** в `.env` скрипт **`setup-server-stack.sh`** может поставить Docker Engine с официального репозитория.
- При **`ENABLE_REGISTRY=1`** (по умолчанию) установщик сам ставит **`gettext-base`** на Debian/Ubuntu, если нет `envsubst` (нужен для `auth_config.yml` registry).
- Установщик рассчитан на запуск **`sudo bash ./setup-server-stack.sh`** из каталога `setup-server-stack` на этом сервере (не на Windows-домашнем ПК как «боевой» хост). Тонкая обёртка **`./install.sh`** вызывает то же самое.

### 2.2. Домен и DNS (обязательно для нормальных HTTPS-сертификатов)

1. Купите или используйте домен (например `company.ru`).
2. В панели регистратора создайте записи:
   - либо **одну запись** типа **A** для `*.company.ru` на **публичный IP** вашего VPS;
   - либо отдельные **A**-записи для каждого поддомена (`traefik`, `registry`, `portainer`, `kuma`, …) — тот же IP.

Пока DNS не указывает на сервер, **Let's Encrypt** не выдаст сертификаты — в браузере будут ошибки или редиректы не заработают как надо.

### 2.3. Почта для сертификатов

Нужен **реальный email** (например `admin@company.ru`) для соглашения Let's Encrypt. Он пишется в `.env` как **`ACME_EMAIL`**. Установщик не пропустит заглушки из `.env.example` (`example.com`, `you@example.com`).

### 2.4. Что скачать на сервер

Скопируйте на VPS папку **`setup-server-stack`** из репозитория (целиком: `docker-compose.yml`, `setup-server-stack.sh`, `install.sh`, `lib/`, `.env.example`, `config/`, …).

### 2.5. Установка удалённо с Windows

На ПК с **Windows 10/11** можно не копировать файлы вручную: установите **OpenSSH Client** (Параметры → Приложения → Дополнительные компоненты), откройте PowerShell в каталоге `setup-server-stack` и выполните:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
.\deploy-from-windows.ps1
```

или явно:

```powershell
.\deploy-from-windows.ps1 -RemoteHost 203.0.113.50
```

**Хост SSH:** если в локальном `.env` задан **`DOMAIN`** (FQDN сервера), скрипт использует его как адрес подключения — **`-RemoteHost` не обязателен**. Если `DOMAIN` ещё не указывает на VPS (например, только что купили домен), передайте **`-RemoteHost`** с IP или временным хостом.

**Каталог на сервере:** по умолчанию **`/opt/setup-server-stack`**. Можно задать в локальном `.env` переменную **`SETUP_SERVER_STACK_ROOT`** (абсолютный путь, например `/opt/setup-server-stack`) или параметром **`-RemotePath`**. Это **не** то же самое, что **`STACK_ROOT`**: последний задаёт, где на диске лежат данные Traefik/сертификаты; при типичном `STACK_ROOT=.` они остаются внутри каталога setup-server-stack.

Подключение выполняется под **`root`**. Параметры PowerShell:

| Параметр | Значение |
|----------|----------|
| `-RemoteHost` | IP или DNS, если не задан `DOMAIN` в `.env` |
| `-RemotePath` | Абсолютный путь на VPS (иначе из `SETUP_SERVER_STACK_ROOT` или `/opt/setup-server-stack`) |
| `-SshPort` | Порт SSH, если не **22** (можно также **`SSH_PORT`** в `.env`) |
| `-SshIdentityFile` | Путь к приватному ключу — без пароля |
| `-RootPassword` | `SecureString` — пароль один раз без интерактивного ввода (опционально) |
| `-SkipInstall` | Только скопировать файлы, **не** запускать `setup-server-stack.sh` |
| `-ForceSecrets` | Пробросить в **`./setup-server-stack.sh --force-secrets`** на сервере |

**Важно:** перед запуском создайте локально **`cp .env.example .env`** и пропишите в `.env` хотя бы **`DOMAIN`** и **`ACME_EMAIL`** — иначе на сервер уедет шаблон с `example.com`. Скрипт `setup-server-stack.sh` при отсутствии `.env` на сервере завершится с ошибкой; удобнее один раз подготовить `.env` на ПК и дать скрипту залить его вместе с остальным.

Подключение под **`root`**. Пароль спрашивается **один раз** в начале (дальше копирование и установка идут по одной SSH-сессии); либо **`-SshIdentityFile`** / **`-RootPassword`**. Docker на VPS: уже установлен или **`INSTALL_DOCKER=1`** в `.env` (§2.1).

---

## 3. Установка по шагам

### Шаг 1. Зайти на сервер по SSH

Пример (подставьте пользователя и IP):

```bash
ssh ubuntu@203.0.113.50
```

### Шаг 2. Перейти в каталог стека

```bash
cd /путь/к/setup-server-stack
```

(Если положили репозиторий в `/opt/setup-server-stack`, то `cd /opt/setup-server-stack`.)

### Шаг 3. Создать файл настроек `.env`

Если файла `.env` ещё нет:

```bash
cp .env.example .env
nano .env
```

**Минимум, что нужно заполнить вручную:**

| Переменная | Пример | Зачем |
|------------|--------|--------|
| `DOMAIN` | `company.ru` | Все поддомены вида `kuma.company.ru` |
| `ACME_EMAIL` | `you@company.ru` | Let's Encrypt |

Остальное можно оставить как в примере; **пустые пароли** скрипт при первом запуске **сам допишет** в файл **`.setup-server-stack-secrets`** (см. ниже).

**Пример минимального фрагмента `.env`:**

```env
DOMAIN=company.ru
ACME_EMAIL=admin@company.ru
STACK_ROOT=.
TZ=Europe/Helsinki
```

`STACK_ROOT=.` означает: данные (сертификаты, конфиги) лежат **рядом** с `docker-compose.yml` внутри `setup-server-stack`. Можно указать абсолютный путь, например `/opt/setup-server-stack-data`.

### Шаг 4. Сделать скрипт исполняемым и запустить установку

```bash
chmod +x setup-server-stack.sh install.sh
sudo bash ./setup-server-stack.sh
```

При первом запуске скрипт:

- создаст сеть Docker **`proxynet`** (если её нет);
- создаст каталоги под `traefik/acme.json`, ключи registry, конфиги;
- сгенерирует **случайные пароли** там, где в `.env` они пустые, и запишет их в **`.setup-server-stack-secrets`**;
- подготовит **Traefik** basic-auth: `config/traefik/htpasswd` (dashboard) и `config/traefik/htpasswd-doku` (**Doku**); пароли в `.setup-server-stack-secrets` — `TRAEFIK_DASHBOARD_PASSWORD` и `DOKU_DASHBOARD_PASSWORD` (в `.env` их не дублируйте);
- сгенерирует **ключи JWT** для registry / `docker_auth`;
- соберёт **`auth_config.yml`** из шаблона;
- соберёт **`config/docker/config.json`** для Watchtower (чтобы тянуть образы с вашего registry);
- сгенерирует **`$STACK_ROOT/.env.stack`** (один файл для `docker compose --env-file`, chmod 600);
- выполнит **`docker compose --env-file .env.stack up -d`** (путь к `.env.stack` — в **`$STACK_ROOT`**).

В конце скрипт выведет список **HTTPS URL**.

**Повторный запуск** `sudo bash ./setup-server-stack.sh` без флагов:

- **не** удалит тома контейнеров;
- **не** перезапишет уже существующие секреты в `.setup-server-stack-secrets` без необходимости;
- **не** трогает `acme.json` с сертификатами так, чтобы сломать выдачу LE.

Если нужно **пересоздать секреты** (осторожно: сменятся пароли, может понадобиться заново залогиниться в registry и обновить клиенты):

```bash
sudo bash ./setup-server-stack.sh --force-secrets
```

### Шаг 5. Посмотреть сгенерированные пароли

Файл **`.setup-server-stack-secrets`** в каталоге `setup-server-stack` (права `600`). Просмотр:

```bash
cat .setup-server-stack-secrets
```

Там, например:

- `TRAEFIK_DASHBOARD_PASSWORD` — вход в **dashboard Traefik**;
- `REGISTRY_PASSWORD` — для `docker login` и для Watchtower;
- `SEMAPHORE_ADMIN_PASSWORD`, `SEMAPHORE_ACCESS_KEY_ENCRYPTION` — для Semaphore;
- при включённых БД — пароли Mongo/Postgres/MariaDB/MySQL и веб-морд.

**Не коммитьте** `.setup-server-stack-secrets` в git (он в `.gitignore`).

---

## 4. Что происходит «до» и «после» одной командой

| До `setup-server-stack.sh` | После успешного `setup-server-stack.sh` |
|-------------------|--------------------------------|
| Нет сети `proxynet` | Сеть создана |
| Нет `acme.json` или пустой | Файл создан, права 600; позже LE заполнит сертификаты |
| Нет `.setup-server-stack-secrets` | Появился с паролями |
| Нет `htpasswd` / `htpasswd-doku` | Появились (Traefik UI: **admin**; Doku: **doku**) |
| Контейнеры не запущены | `docker compose --env-file .env.stack up -d` — сервисы работают |

Проверка контейнеров (при **`STACK_ROOT=.`** файл `.env.stack` в текущем каталоге; иначе укажите **`$STACK_ROOT/.env.stack`**):

```bash
docker compose -f docker-compose.yml --env-file .env.stack ps
```

---

## 5. Порты: что торчит наружу

На **хосте** (VPS) наружу по смыслу стека открыты только:

- **22** — SSH (настраиваете вы сами в фаерволе);
- **80** — HTTP (редирект на HTTPS + проверка Let's Encrypt);
- **443** — HTTPS.

Порты **Mongo/Postgres/MariaDB/MySQL** в `docker-compose` **не** проброшены на `0.0.0.0` — к БД из интернета напрямую не подключиться, только из сети Docker или веб-морд через Traefik (см. §7).

---

## 6. Куда заходить после установки (URL)

Подставьте свой **`DOMAIN`** вместо `company.ru`:

| Сервис | Адрес | Как зайти (логин / пароль) |
|--------|-------|----------------------------|
| Traefik dashboard | `https://traefik.company.ru` | Логин **`admin`**, пароль **`TRAEFIK_DASHBOARD_PASSWORD`** из `.setup-server-stack-secrets` |
| Registry | `https://registry.company.ru` | Не веб-форма: **`docker login registry.company.ru`** (пользователь/пароль из `.env` / `.setup-server-stack-secrets`) |
| Portainer | `https://portainer.company.ru` | **Первый заход** — мастер создаёт админа в браузере |
| Semaphore | `https://semaphore.company.ru` | **`SEMAPHORE_ADMIN`** и пароль из `.env` / `.setup-server-stack-secrets` |
| Doku | `https://doku.company.ru` | **Basic Auth в Traefik:** логин **`doku`**, пароль **`DOKU_DASHBOARD_PASSWORD`** в `.setup-server-stack-secrets`; файл `config/traefik/htpasswd-doku` создаёт `setup-server-stack.sh` |
| Duplicati | `https://duplicati.company.ru` | **Первый заход** — пароль в UI; задания бэкапа настраиваются в UI (§8) |
| Uptime Kuma | `https://kuma.company.ru` | **Первый заход** — создаёте админа в UI |
| Filebrowser | `https://filebrowser.company.ru` | Логин **`admin`**, первичный пароль в `docker logs filebrowser`; каталог на хосте — `FILEBROWSER_ROOT_PATH` (пусто = `$STACK_ROOT/filebrowser/files`) |

**Filebrowser:** по умолчанию открыт только каталог `$STACK_ROOT/filebrowser/files`, не весь сервер. `FILEBROWSER_ROOT_PATH=/` монтирует весь хост (rw) — на проде не используйте. См. [SECURITY.ru.md](SECURITY.ru.md#веб-панели-край-https).
| Deployer (если включён) | `https://deployer.company.ru` | Логин/пароль из `DEPLOYER_ADMIN_USER` / `DEPLOYER_ADMIN_PASSWORD` |

Поддомен **`auth.company.ru`** — сервис **docker_auth** (для протокола Docker, не «панель для людей» в том же смысле).

**Безопасность:** Traefik Basic Auth есть только у **Traefik** и **Doku**. Остальные панели в таблице — логин приложения или «первый заход»; подробнее [SECURITY.ru.md](SECURITY.ru.md#веб-панели-край-https).

---

## 7. Опционально: базы данных и веб-морды

В **`.env`** выставьте флаги **`1`** и **заполните пароли** (или оставьте пустыми — тогда при первом запуске `setup-server-stack.sh` допишет их в `.setup-server-stack-secrets` там, где скрипт это поддерживает):

```env
ENABLE_MONGO=1
ENABLE_POSTGRES=1
ENABLE_MARIADB=1
ENABLE_MYSQL=1
ENABLE_MONGO_EXPRESS=1
ENABLE_PGADMIN=1
ENABLE_ADMINER=1
```

Правила:

- `ENABLE_MONGO_EXPRESS=1` только если **`ENABLE_MONGO=1`**;
- `ENABLE_PGADMIN=1` только если **`ENABLE_POSTGRES=1`**;
- `ENABLE_ADMINER=1` только если включена **хотя бы одна** БД (Mongo, Postgres, MariaDB и/или MySQL).

Скрипт `setup-server-stack.sh` сам выставляет переменную окружения **`COMPOSE_PROFILES`** (список профилей compose). Вручную то же самое:

```bash
export COMPOSE_PROFILES=mongo,postgres,mariadb,mysql,mongo-express,pgadmin,adminer
docker compose --env-file .env.stack -f docker-compose.yml up -d
```

Примеры URL:

- `https://mongo-express.company.ru`
- `https://pgadmin.company.ru` — после входа в pgAdmin сервер **Postgres** уже в списке (как mongo-express к Mongo).
- `https://adminer.company.ru`

Пароли — переменные `MONGO_EXPRESS_*`, `PGADMIN_*` и т.д. в `.env` / `.setup-server-stack-secrets`.

---

## 8. Как пользоваться стеком в обычной жизни

### Обновить контейнеры после правки `.env`

```bash
sudo bash ./setup-server-stack.sh
```

или (если уже есть актуальный **`.env.stack`**):

```bash
docker compose --env-file .env.stack -f docker-compose.yml up -d
```

### Остановить всё

```bash
docker compose --env-file .env.stack -f docker-compose.yml down
```

(Тома с данными **не** удаляются, если не указать `-v`.)

### Залить образ в свой registry с ноутбука

```bash
docker tag my-app:latest registry.company.ru/my-app:latest
docker login registry.company.ru
docker push registry.company.ru/my-app:latest
```

Логин и пароль — те же, что для **registry** (см. `REGISTRY_USER` / `REGISTRY_PASSWORD`).

### Автозаливка списка образов при установке стека

Если registry включен (`ENABLE_REGISTRY=1`), можно заранее указать список локальных образов в `.env`:

```env
REGISTRY_SEED_IMAGES=myapp:latest,registry.remote.tld/acme/api:1.4;redis:7
```

`setup-server-stack.sh` при установке сам выполнит для каждого образа `docker tag` + `docker push` в `registry.${DOMAIN}`.

- Пустой `REGISTRY_SEED_IMAGES` — шаг пропускается.
- Если образ не найден локально, скрипт покажет предупреждение и продолжит.
- Для образов с внешним registry (`registry.remote.tld/...`) хост срезается, и тег в локальном registry будет вида `registry.${DOMAIN}/acme/api:1.4`.
- Сетевые операции registry (`docker login/pull/push` и подъем registry-сервисов) выполняются с ретраями; число попыток задаётся `REGISTRY_OPERATION_RETRIES` (по умолчанию `3`).
- Между попытками используется экспоненциальный backoff (`REGISTRY_RETRY_BACKOFF_BASE_SEC`, `REGISTRY_RETRY_BACKOFF_MAX_SEC`), по умолчанию: `2s`, `4s`, `8s` (не выше `10s`).

### Дополнительные внешние registry при установке

Если нужно, чтобы на хосте после установки уже были выполнены `docker login` в сторонние registry, задайте в `.env`:

```env
EXTRA_REGISTRY_COUNT=2
EXTRA_REGISTRY_1_HOST=registry.remote.tld
EXTRA_REGISTRY_1_USER=myuser
EXTRA_REGISTRY_1_PASSWORD=token1
EXTRA_REGISTRY_2_HOST=registry.other.tld
EXTRA_REGISTRY_2_USER=registry-user
EXTRA_REGISTRY_2_PASSWORD=token2
```

`setup-server-stack.sh` при установке выполнит логин в каждый registry (с теми же retry/backoff настройками).  
Эти auth-данные также автоматически попадут в `config/docker/config.json`, чтобы Watchtower мог тянуть образы из этих приватных registry.
Эти же креды автоматически передаются в Deployer как `REGISTRY_CREDENTIALS_JSON`, чтобы deploy через UI тоже работал с несколькими приватными registry.

### Deployer

Deployer — **отдельный** open-source продукт ([github.com/commerce-deployer/deployer](https://github.com/commerce-deployer/deployer)). Образ собирается CI и публикуется в Docker Hub и GHCR (публичный `docker pull`) — стек только **скачивает** его, как Traefik или Portainer.

```env
ENABLE_DEPLOYER=1
DEPLOYER_IMAGE=docker.io/commercedeployer/deployer:latest
# Или GHCR: ghcr.io/commerce-deployer/deployer:latest
```

Укажите нужный тег образа при фиксации релиза (например `:v1.2.0`). Для **приватного** образа задайте `DEPLOYER_IMAGE_REGISTRY_HOST`, `DEPLOYER_IMAGE_REGISTRY_USER`, `DEPLOYER_IMAGE_REGISTRY_PASSWORD` до установки.

При включённом registry стека Deployer использует `registry.${DOMAIN}` для образов приложений.

Политика pull внутри Deployer (для образов приложений): `DEPLOYER_DEFAULT_PULL_POLICY=always` | `ifNotPresent`, попытки — `DEPLOYER_PULL_MAX_ATTEMPTS`.

### Duplicati (бэкапы)

Стек поднимает **веб-UI Duplicati** и хранит его настройки в Docker-томе `duplicati_config`. **Задания бэкапа** установщик не создаёт:

- **Источник** — какие файлы или тома копировать
- **Назначение** — S3, Backblaze, SFTP, другой сервер и т.д.
- **Расписание** — когда запускать job

После установки откройте `https://duplicati.${DOMAIN}`, задайте пароль и создайте задание в UI.

По умолчанию Duplicati видит только свой `/config` внутри контейнера. Чтобы бэкапить данные стека (`${STACK_ROOT}`, именованные тома Docker), добавьте **read-only** bind mount в сервис `duplicati` в `docker-compose.yml` (примеры в комментариях к сервису), затем `docker compose ... up -d`. Пути должны быть читаемы для `DUP_PUID` / `DUP_PGID` (по умолчанию `1000`).

### Проверить конфиг compose без запуска

На сервере (после установки) или у контрибьютора без VPS:

```bash
docker compose --env-file .env.stack -f docker-compose.yml config
bash tests/run-ci.sh
```

Фикстуры для `run-ci.sh`: `tests/fixtures/*.env.stack`.

---

## 9. Настройка безопасности хоста из `setup-server-stack.sh`

По умолчанию в `.env` уже включены безопасные значения (Ubuntu/Debian):

| Переменная | Значение | Что делает |
|------------|----------|------------|
| `CREATE_ADMIN_USER` | `1` | Создаёт главного пользователя `ADMIN_USERNAME` (sudo + docker) |
| `ADMIN_SUDO_NOPASSWD` | `1` | Даёт `NOPASSWD` через `/etc/sudoers.d` для этого пользователя |
| `APPLY_SSH_HARDENING` | `1` | Отключает root/password login в SSH (только по ключу) |
| `UFW_ENABLE` | `1` | Открывает `SSH_PORT`, 80, 443 и включает UFW (с fallback на iptables-legacy) |
| `INSTALL_FAIL2BAN` | `1` | На Debian/Ubuntu ставит fail2ban через apt |
| `INSTALL_UNATTENDED_UPGRADES` | `1` | Включает автоматические security-обновления |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA...` | Ключ для `ADMIN_USERNAME` и безопасного SSH-hardening |

---

## 10. Если что-то пошло не так

1. **Нет зелёного замочка в браузере** — подождите DNS, проверьте `ACME_EMAIL` и что порты 80/443 доступны с интернета.
2. **502 / нет ответа** — `docker compose ... ps` и `docker logs имя-контейнера`.
3. **Не пускает в registry** — проверьте `REGISTRY_USER` / `REGISTRY_PASSWORD` в `.env` и `.setup-server-stack-secrets`; перезапустите `sudo bash ./setup-server-stack.sh`. Убедитесь, что `config/docker_auth/auth_config.yml` и ключи в `certs/` согласованы (генерируются скриптом). Клиент: `docker login registry.${DOMAIN}`.
4. **Забыли пароль Traefik или Doku** — смотрите `.setup-server-stack-secrets` (`TRAEFIK_DASHBOARD_PASSWORD`, `DOKU_DASHBOARD_PASSWORD`) или пересоздайте соответствующий `htpasswd*` через `sudo bash ./setup-server-stack.sh --force-secrets` (осторожно: пересоздаст и другие секреты).

---

## 11. Каталоги и тома (day-2)

| Путь | Назначение |
|------|------------|
| `docker-compose.yml` | Стек и Compose profiles |
| `.env` / `.env.stack` | Настройки; `.env.stack` собирается скриптом (chmod 600) |
| `.setup-server-stack-secrets` | Автогенерируемые пароли (не в git) |
| `${STACK_ROOT}/traefik/acme.json` | Сертификаты Let's Encrypt |
| `${STACK_ROOT}/certs/registry-token*.pem` | JWT для registry + `docker_auth` |
| `${STACK_ROOT}/config/traefik/htpasswd*` | Basic Auth Traefik / Doku |
| `${STACK_ROOT}/config/pgadmin/` | Автоподключение pgAdmin (если включён) |

**Watchtower** не обновляет Traefik и СУБД (`watchtower.enable=false`). Остальные сервисы — по `WATCHTOWER_SCHEDULE`.

**Duplicati:** из compose — только UI и том `duplicati_config`; источники, хранилище и расписание — в UI Duplicati (§8).

**Доступ к БД с другого VPS:** предпочтительно HTTPS API на этом хосте; если нужен прямой доступ — UFW только с IP приложения; для админа — веб-морды или SSH-туннель (`ssh -N -L 27018:127.0.0.1:27017 user@vps`).

**Чеклист приёмки:** DNS → HTTPS на панелях → `docker login registry.${DOMAIN}` → порты БД не на `0.0.0.0` → повторный `setup-server-stack.sh` не ломает `acme.json` без `--force-secrets`.

Подробнее про Traefik Basic Auth vs логин приложения — [SECURITY.ru.md](SECURITY.ru.md#веб-панели-край-https).
