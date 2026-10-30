#!/bin/sh
set -eu

TARGET="${TARGET_CONTAINER:-mariadb}"
PROM_URL="${PROMETHEUS_URL:-http://prometheus:9090}"
STABILITY_WINDOW=20

# Запрос в Prometheus: 1 - если UP и работает > 20 сек; 0 - если DOWN или только что упал/перезапустился
query_status() {
    docker run --rm --network platform_net curlimages/curl:latest -s -G "$PROM_URL/api/v1/query" \
        --data-urlencode "query=(mysql_up == bool 1) * (mysql_global_status_uptime > bool $STABILITY_WINDOW)" 2>/dev/null || echo ""
}

echo "=========================================================="
echo "           STARTING CHAOS TEST: $TARGET                   "
echo "=========================================================="

# 1. Проверяем начальное состояние
echo "Step 1: Checking baseline health in Prometheus..."
RESPONSE=$(query_status)
if echo "$RESPONSE" | grep -q '\[[0-9.]*,"1"\]'; then
    echo "  -> Baseline OK: $TARGET is UP and STABLE (status = 1)"
else
    echo "  -> Error: $TARGET is not ready or was restarted less than ${STABILITY_WINDOW}s ago!"
    echo "     Wait for the service to stabilize before starting the test."
    exit 1
fi

INITIAL_RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$TARGET" 2>/dev/null || echo "0")

# 2. Инициируем падение процесса через чистый SIGTERM
echo ""
echo "Step 2: Simulating service termination via SIGTERM to PID 1..."
# Сигнал заставляет MariaDB закрыть сокеты без порчи данных, 
# а Docker воспринимает завершение процесса как триггер для restart-policy.
docker exec "$TARGET" kill -TERM 1 >/dev/null 2>&1 || true
echo "  -> Termination signal sent."

# 3. Валидация пункта (а): Переход в статус «Все Плохо»
echo ""
echo "Step 3: Verifying transition to DOWN / UNSTABLE status in Monitoring..."
DOWN_DETECTED=0
for i in $(seq 1 30); do
    RESPONSE=$(query_status)
    if echo "$RESPONSE" | grep -q '\[[0-9.]*,"0"\]'; then
        echo "  -> [ALERT DETECTED] Status is 0! Dashboard status: 'ALL BAD' (took ~${i} checks)"
        DOWN_DETECTED=1
        break
    fi
    sleep 1
done

if [ "$DOWN_DETECTED" -eq 0 ]; then
    echo "  -> [FAIL] Monitoring did not register downtime/instability within timeout!"
    exit 1
fi

# 4. Валидация пункта (б, часть 1): Проверка автономной работы restart-policy
echo ""
echo "Step 4: Checking Docker restart-policy auto-recovery..."
RESTARTED=0
for i in $(seq 1 30); do
    STATUS=$(docker inspect -f '{{.State.Status}}' "$TARGET" 2>/dev/null || true)
    CURRENT_RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$TARGET" 2>/dev/null || echo "0")
    
    # Проверяем, что контейнер снова running И счетчик перезапусков вырос
    if [ "$STATUS" = "running" ] && [ "$CURRENT_RESTARTS" -gt "$INITIAL_RESTARTS" ]; then
        echo "  -> [RECOVERED] Docker restart-policy revived $TARGET! (RestartCount: $INITIAL_RESTARTS -> $CURRENT_RESTARTS)"
        RESTARTED=1
        break
    fi
    sleep 1
done

if [ "$RESTARTED" -eq 0 ]; then
    echo "  -> [FAIL] Docker restart-policy failed: container did not auto-restart!"
    exit 1
fi

# 5. Валидация пункта (б, часть 2): Подтверждение восстановления в мониторинге
echo ""
echo "Step 5: Waiting for service stability window to pass ($STABILITY_WINDOW seconds)..."
RESTORED=0
for i in $(seq 1 $((STABILITY_WINDOW + 25))); do
    RESPONSE=$(query_status)
    if echo "$RESPONSE" | grep -q '\[[0-9.]*,"1"\]'; then
        echo "  -> [HEALTH RESTORED] Metric is back to 1! Dashboard status: 'HEALTHY'"
        RESTORED=1
        break
    fi
    sleep 1
done

if [ "$RESTORED" -eq 0 ]; then
    echo "  -> [FAIL] Monitoring did not reflect recovery within timeout!"
    exit 1
fi

echo ""
echo "=========================================================="
echo "          CHAOS TEST PASSED SUCCESSFULLY!                 "
echo "=========================================================="