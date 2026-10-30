#!/bin/sh
set -eu

GRAFANA_URL="${GRAFANA_URL:-http://grafana:3000}"
USER="${GRAFANA_ADMIN_USER:-admin}"
PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"
GALERA_MODE="${GALERA_MODE:-false}"

echo "Waiting for Grafana API to be ready..."
until curl -s -f "$GRAFANA_URL/api/health" > /dev/null 2>&1; do
    echo "Grafana is warming up, retrying in 2 seconds..."
    sleep 2
done

# -------------------------------------------------------------------
# 1. Создаем или обновляем Prometheus Datasource с фиксированным UID
# -------------------------------------------------------------------
echo "1. Configuring Prometheus Datasource..."
curl -s -f -u "$USER:$PASS" \
    -X POST "$GRAFANA_URL/api/datasources" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "Prometheus",
        "type": "prometheus",
        "uid": "prometheus",
        "access": "proxy",
        "url": "http://prometheus:9090",
        "isDefault": true,
        "jsonData": {
            "httpMethod": "POST"
        }
    }' > /dev/null 2>&1 || echo "Datasource already exists, continuing..."

# -------------------------------------------------------------------
# 2. Выбираем локальный файл дашборда в зависимости от режима
# -------------------------------------------------------------------
echo "2. Selecting Dashboard (Galera Mode: $GALERA_MODE)..."
DASHBOARD_FILE=""

if [ "$GALERA_MODE" = "true" ]; then
    if [ -f "/payloads/dashboard.galera.json" ]; then
        DASHBOARD_FILE="/payloads/dashboard.galera.json"
    elif [ -f "/payloads/galera-dashboard.json" ]; then
        DASHBOARD_FILE="/payloads/galera-dashboard.json"
    fi
else
    if [ -f "/payloads/dashboard.json" ]; then
        DASHBOARD_FILE="/payloads/dashboard.json"
    elif [ -f "/payloads/health-dashboard.json" ]; then
        DASHBOARD_FILE="/payloads/health-dashboard.json"
    fi
fi

# Fallback: если файл под конкретный режим не найден, берем первый попавшийся .json
if [ -z "$DASHBOARD_FILE" ] || [ ! -f "$DASHBOARD_FILE" ]; then
    DASHBOARD_FILE=$(ls /payloads/*.json 2>/dev/null | head -n 1 || true)
fi

if [ -z "$DASHBOARD_FILE" ] || [ ! -f "$DASHBOARD_FILE" ]; then
    echo "Error: No dashboard JSON file found in /payloads!"
    exit 1
fi

echo "Selected dashboard file: $DASHBOARD_FILE"

# -------------------------------------------------------------------
# 3. Устранение "Invalid": заменяем ${DS_PROMETHEUS} на реальный UID
# -------------------------------------------------------------------
# Заменяем шаблонную переменную на конкретный uid "prometheus"
sed 's/\${DS_PROMETHEUS}/prometheus/g' "$DASHBOARD_FILE" > /tmp/clean_dashboard.json

# Формируем тело запроса для Grafana API
printf '{"dashboard":' > /tmp/import_payload.json
cat /tmp/clean_dashboard.json >> /tmp/import_payload.json
printf ',"overwrite":true}' >> /tmp/import_payload.json

# -------------------------------------------------------------------
# 4. Импорт дашборда в Grafana
# -------------------------------------------------------------------
RESPONSE=$(curl -s -w "\n%{http_code}" -u "$USER:$PASS" \
    -X POST "$GRAFANA_URL/api/dashboards/db" \
    -H "Content-Type: application/json" \
    -d @/tmp/import_payload.json)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "Dashboard imported successfully!"
    echo "Grafana API response: $BODY"
else
    echo "Failed to import dashboard (HTTP $HTTP_CODE):"
    echo "$BODY"
    exit 1
fi

echo "Grafana configuration successfully finished!"