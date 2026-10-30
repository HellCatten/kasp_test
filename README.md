
# Observability & Application Platform (Dagger + Docker)

Стенд для развертывания веб-сервиса **Uptime Kuma** с базой данных **MariaDB** и контуром комплексной наблюдаемости (**Prometheus**, **Grafana**, **Node Exporter**, **cAdvisor**, **MySQLd Exporter**). 

Вся автоматизация управления инфраструктурой, настройки сервисов и тестирования отказоустойчивости реализована на базе **Dagger.io (Go SDK)**.

---

## 🏗 Архитектура решения

Стенд разделен на два независимых слоя (раздельные Compose-проекты):

1. **Слой 1 — Приложение и БД (`docker-compose.app.yaml`)**:
   * **MariaDB 11.4**: персистентное хранилище (volume `db_data`), выделенный пользователь мониторинга, healthcheck.
   * **Uptime Kuma**: сервис мониторинга доступности, подключенный к MariaDB, с healthcheck и хранением данных в volume `kuma_data`.
   * Создает общую изолированную bridge-сеть `platform_net`.

2. **Слой 2 — Наблюдаемость (`docker-compose.monitoring.yaml`)**:
   * **Prometheus**: сбор метрик хоста, БД и контейнеров.
   * **Grafana**: дашборд здоровья контура (CPU/RAM контейнеров, метрики MariaDB, статус Kuma).
   * **Node Exporter**: сбор метрик операционной системы хоста (`pid: host`).
   * **cAdvisor**: сбор метрик потребления ресурсов контейнерами (CPU, Memory Working Set).
   * **MySQLd Exporter**: сбор внутренней телеметрии MariaDB с безопасной аутентификацией через `.my.cnf`.
   * Подключается к сети первого слоя `platform_net` как к `external`.

---

## 💻 Системные требования

* **ОС**: Linux, macOS или Windows 10/11 (через **WSL2**).
* **Docker**: Docker Engine / Docker Desktop с поддержкой Compose v2.
* **Dagger CLI**: версии 0.11+.
  
**Корректная работа Cadvisor в WSL с использованием Docker Desktop невозможна из-за технических особенностей. Полный текст в конце файла.**

### Установка Dagger CLI (в Linux / WSL2)
```bash
curl -fsSL https://dl.dagger.io/dagger/install.sh | sudo BIN_DIR=/usr/local/bin sh
```

---

## 🚀 Подготовка к запуску

### 1. Клонирование и переход в каталог
В среде Linux / WSL2 перейдите в корень репозитория:
```bash
cd /path/to/project
```

### 2. Настройка переменных окружения (`.env`)

Скопируйте example файла .env.example .my.cnf.example
```bash
# Подготовка файлов конфигурации и учетных данных
cp .env.example .env
cp .my.cnf.example .my.cnf
chmod 600 .env .my.cnf
```

### 3. Конфигурация доступа для MySQLd Exporter (`.my.cnf`)
Создайте файл `.my.cnf` с учетными данными для мониторинга:
```bash
cat << 'EOF' > .my.cnf
[client]
user=exporter
password=GenerateStrongExporterPass789!
port=3306
EOF

chmod 600 .my.cnf
```

---

## 🛠 Управление стендом через Dagger CLI

Все операции выполняются через Dagger-модуль, взаимодействующий с хостовым демоном Docker через сокет `/var/run/docker.sock`.

### Обязательные команды

#### 1. Развертывание Слоя 1 (Приложение и БД)
Поднимает MariaDB и Uptime Kuma, дожидается успешного прохождения healthcheck:
```bash
dagger call deploy-app \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

Существует возможность разворачивания Galera конфигурации (кластер из 3 нод + HAProxy)
```bash
dagger call deploy-galera \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

#### 2. Развертывание Слоя 2 (Контур наблюдаемости)
Поднимает Prometheus, Grafana, Node Exporter, cAdvisor и MySQLd Exporter:
```bash
dagger call deploy-monitoring \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

#### 3. Настройка Grafana через REST API
Скрипт дожидается готовности Grafana API, создает Datasource Prometheus (`uid: prometheus`) и импортирует дашборд здоровья контура (для стандартной конфигурации и Galera):
```bash
dagger call configure-grafana \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

#### 4. Настройка Uptime Kuma для работы с Prometheus
Скрипт конфигурирует администратора Uptime Kuma, создает API ключ для Prometheus и сохраняет его в /secrets.
```bash
dagger call setup-kuma \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

---

### Бонусные команды

#### 1. End-to-End развертывание «под ключ» (`deploy-all`)
Выполняет полный цикл развертывания платформы:
1. Поднимает Слой 1 (App + DB).
2. Автоматически инициализирует первого администратора Uptime Kuma через WebSocket и выпускает API-токен для Prometheus.
3. Поднимает Слой 2 (Monitoring).
4. Накатывает Data Source и дашборд в Grafana через API.
5. Проводит автоматический Healthcheck доступности всех ключевых сервисов.

Возможность поднять Galera конфигурацию MariaDB с флагом `--galera=true`

```bash
# Развертывание с одиночной нодой MariaDB (по умолчанию):
dagger call deploy-all \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)

# Развертывание с отказоустойчивым кластером Galera (3 ноды + HAProxy):
dagger call deploy-all \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd) \
  --galera=true
```

#### 2. Chaos Testing (`chaos-test`)
Тестирует устойчивость контура к внезапным сбоям:
1. Проверяет начальный статус системы (`mysql_up == 1`).
2. Инициирует аварийный сбой MariaDB (`-TERM`).
3. Валидирует переход метрики в Prometheus и панели на дашборде в статус **«Все Плохо»** (`mysql_up == 0 и mysql_global_status_uptime<20`).
4. Ожидает автоматического восстановления сервиса политикой **`restart: unless-stopped`**.
5. Валидирует возвращение метрики на дашборде в статус **«Восстановление / UP»** (`mysql_up == 0 и mysql_global_status_uptime>20`).

**Примечание**: Тест отказа (chaos-test) предназначен для базовой конфигурации стенда (одиночная нода MariaDB). В режиме Galera Cluster аварийное падение отдельной ноды намеренно не переводит платформу в статус «Все Плохо», так как балансировщик HAProxy прозрачно переключает нагрузку на резервные узлы кластера (демонстрация High Availability).

```bash
dagger call chaos-test \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

#### 3. Полная очистка стенда (`destroy`)
Останавливает все контейнеры, удаляет сети и очищает связанные тома:
```bash
dagger call destroy \
  --docker-sock=/var/run/docker.sock \
  --host-path=$(pwd)
```

---

## 🌐 Доступ к сервисам и учетные данные

| Сервис | URL | Логин | Пароль | Описание |
|---|---|---|---|---|
| **Grafana** | [http://localhost:3000](http://localhost:3000) | `admin` | `AdminStrongPassword321!` | Панель мониторинга здоровья контура |
| **Prometheus** | [http://localhost:9090](http://localhost:9090) (Только из localhost хоста) | — | — | Хранилище метрик и база PromQL |
| **Uptime Kuma** | [http://localhost:3001](http://localhost:3001) (Только из localhost хоста) | `admin` | `AdminStrongPassword321!` | Веб-интерфейс мониторинга доступности |
| **Node Exporter** | `http://localhost:9100/metrics` (порт закрыт наружу) | — | — | Метрики хостовой ОС |
| **cAdvisor** | `http://localhost:8080/metrics` (порт закрыт наружу) | — | — | Метрики ресурсов контейнеров |
| **MySQLd Exporter**| `http://localhost:9104/metrics` (порт закрыт наружу) | — | — | Внутренние метрики БД MariaDB |

---

## 🔍 Проверка работоспособности компонентов

1. **Проверка дашборда Grafana:**
   * Откройте [http://localhost:3000](http://localhost:3000) и авторизуйтесь.
   * Перейдите в раздел **Dashboards** -> **Infra & Services Monitoring (MariaDB / Uptime Kuma)**.
   * Убедитесь, что статусы *MariaDB Status* и *Uptime Kuma Service* горят зеленым (**UP**), а графики cAdvisor отображают потребление CPU и RAM контейнерами.
2. **Проверка целей в Prometheus:**
   * Откройте [http://localhost:9090/targets](http://localhost:9090/targets).
   * Все цели (`mariadb`, `uptime-kuma`, `cadvisor`, `node-exporter`, `prometheus`) должны находиться в состоянии **UP** (зеленый цвет).
3. **Проверка авторизации Uptime Kuma:**
   * Убедитесь, что Prometheus собирает метрики Kuma без ошибок `401 Unauthorized`. Токен автоматически генерируется шагом `SetupKuma` и безопасно монтируется в Prometheus через директиву `password_file`.

---

## 🔬 Инженерные решения и архитектурные заметки (Engineering Decisions)

### 1. Тестирование `restart-policy` vs вызов `docker stop`
В формулировке задания упомянута остановка сервиса командой `docker stop` с проверкой `restart-policy`.

**Особенность реализации Docker Engine:**
По официальной спецификации Docker, при выполнении внешней команды `docker stop` демон взводит флаг ручной остановки (`HasBeenManuallyStopped = true`). В этом случае Docker **намеренно подавляет** автоматический перезапуск по политике `restart: unless-stopped` (или `always`), расценивая это как волю администратора, проводящего плановое обслуживание.

**Как реализован Chaos Test:**
В проекте выбрана политика **`restart: unless-stopped`** как наиболее безопасный и принятый в production-среде стандарт. Чтобы честно протестировать автоматический подъем контейнера демоном Docker, скрипт `scripts/chaos-test.sh` эмулирует реальный внезапный сбой (Kernel Crash / Segmentation Fault):
```bash
docker exec mariadb sh -c "kill -SEGV 1"
```
Сигнал `SIGSEGV` не подавляется ядром Linux, контейнер завершается с аварийным кодом `139`, флаг ручной остановки не выставляется, и демон Docker **автоматически перезапускает сервис по политике `unless-stopped`**, подтверждая отказоустойчивость.

### 2. Верификация статуса дашборда через Prometheus API
В автоматизированных тестах (CI/CD) проверка визуального интерфейса Grafana (скриншоты, DOM-парсинг) является антипаттерном. Источником истины для панели статуса дашборда является метрика `mysql_up`. Скрипт валидирует переход метрики в `0` (в UI дашборд окрашивается в красный статус «Все Плохо») и её возврат в `1` через официальный REST API Prometheus. В самом дашборде выставлен интервал обновления `"refresh": "5s"`, что позволяет наблюдателю в браузере видеть переход статусов в реальном времени.

### 3. Безопасность секретов (File-based secrets)
Вместо передачи токенов через переменные окружения (которые утекают через `docker inspect`) или хардкода в `prometheus.yml`, настроена связка:
Скрипт настройки генерирует токен через WebSocket и сохраняет его в файл secrets/kuma.token с правами 644 (необходимыми для чтения непривилегированным пользователем nobody в контейнере Prometheus). Prometheus считывает секрет на лету через директиву password_file: '/etc/prometheus/secrets/kuma.token'.

---

## Ограничения окружения: почему cAdvisor не работает в Docker Desktop (Windows / macOS)

Сервис мониторинга контейнеров **cAdvisor** предназначен для работы исключительно на **нативном Linux** (включая **Docker Engine внутри WSL2**) и архитектурно несовместим с **Docker Desktop**.

### Архитектурная причина

cAdvisor — это не обычное пользовательское приложение, а низкоуровневый системный профилировщик ядра Linux. Для сбора метрик и регистрации контейнеров ему требуется прямой доступ к файловой системе хоста и сокетам рантайма:

1. **Изоляция в виртуальной машине (`docker-desktop` VM):**
   * Docker Desktop запускает Docker Engine внутри отдельной скрытой служебной виртуальной машины.
   * Дистрибутив WSL (Ubuntu/Debian) или терминал Windows/macOS являются лишь клиентскими оболочками, отправляющими команды через проксированный сокет Docker API.
   * Физические файлы контейнеров и сокеты рантайма находятся **внутри виртуального диска VM**, а не в вашей хост-системе.

При выполнении команды `wsl -l -v` в Windows видно разделение на независимые подсистемы:
```text
  NAME              STATE           VERSION
* Ubuntu            Running         2
  docker-desktop    Running         2
```

2. **Недоступность каталога данных Docker (`/var/lib/docker`):**
   * При использовании драйвера хранения `overlay2` cAdvisor жестко закодирован на чтение файла метаданных слоя контейнера:  
     `/var/lib/docker/image/overlay2/layerdb/mounts/<container-id>/mount-id`
   * При монтировании `- /var/lib/docker:/var/lib/docker:ro` из дистрибутива WSL в контейнер пробрасывается пустая локальная папка, так как реальные файлы лежат внутри скрытой VM.
   * **Результат:** cAdvisor аварийно завершает регистрацию каждого контейнера с ошибкой:  
     `failed to identify the read-write layer ID ... open .../mount-id: no such file or directory`.

3. **Изоляция сокета containerd:**
   * В современных версиях Docker (со включенным Containerd Image Store / `overlayfs`) cAdvisor требует сокет `/run/containerd/containerd.sock`.
   * Docker Desktop не пробрасывает настоящий сокет containerd в пользовательский дистрибутив WSL.
   * **Результат:** cAdvisor не может обнаружить запущенные контейнеры и выдает:  
     `container "..." in namespace "moby": not found`.

### Решение для локальной разработки

Для работы мониторинга на базе cAdvisor локальная среда должна быть полностью идентична серверному Linux.

#### В Windows (WSL2):
1. Отключите интеграцию с дистрибутивом в настройках Docker Desktop:  
   `Settings` → `Resources` → `WSL Integration` → снять галочку с вашего дистрибутива (Ubuntu).
2. Установите **нативный Docker CE** непосредственно внутри терминала WSL2 по [официальной инструкции Docker для Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
3. Убедитесь, что в `/etc/wsl.conf` включен systemd:
   ```ini
   [boot]
   systemd=true
   ```
4. Перезапустите WSL (`wsl --shutdown` в PowerShell) и запустите Docker внутри дистрибутива.

После перехода на нативный Docker Engine пути `/var/lib/docker`, `/sys/fs/cgroup` и сокеты станут реальными, и cAdvisor запустится без модификации конфигурации.
