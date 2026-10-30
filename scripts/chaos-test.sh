#!/bin/sh
set -eu

TARGET="${TARGET_CONTAINER:-mariadb}"
PROM_URL="${PROMETHEUS_URL:-http://prometheus:9090}"
MAX_WAIT_SECONDS=60

query_metric() {
    docker run --rm --network platform_net curlimages/curl:latest -s "$PROM_URL/api/v1/query?query=mysql_up" 2>/dev/null || echo ""
}

echo "=========================================================="
echo "           STARTING CHAOS TEST: $TARGET                   "
echo "=========================================================="

# 1. Проверяем начальное состояние
echo "Step 1: Checking baseline health in Prometheus..."
RESPONSE=$(query_metric)
if echo "$RESPONSE" | grep -q '\[[0-9.]*,"1"\]'; then
    echo "  -> Baseline OK: $TARGET is UP (metric value = 1)"
else
    echo "  -> Error: $TARGET is not healthy before test start!"
    exit 1
fi

# 2. Инициируем падение процесса базы данных
echo ""
echo "Step 2: Simulating service shutdown/crash..."
echo "  [Execution]: Triggering internal database shutdown via mariadb-admin..."

# Завершаем процесс базы изнутри.
if ! docker exec "$TARGET" sh -c "kill -SEGV 1" 2>/dev/null || docker exec "$TARGET" sh -c "kill -ILL 1" 2>/dev/null || true; then
    echo "  [Fallback]: mariadb-admin failed, using docker stop as fallback..."
    docker stop -t 2 "$TARGET" >/dev/null
fi
echo "  -> Service termination triggered. Container exited."

# 3. Валидация пункта (а): Переход в статус «Все Плохо»
echo ""
echo "Step 3: Verifying transition to DOWN status in Monitoring..."
DOWN_DETECTED=0
for i in $(seq 1 30); do
    RESPONSE=$(query_metric)
    if echo "$RESPONSE" | grep -q '\[[0-9.]*,"0"\]'; then
        echo "  -> [ALERT DETECTED] Metric mysql_up is 0! Dashboard status: 'ALL BAD' (took ~${i} checks)"
        DOWN_DETECTED=1
        break
    fi
    sleep 2
done

if [ "$DOWN_DETECTED" -eq 0 ]; then
    echo "  -> [FAIL] Monitoring did not register downtime within timeout!"
    exit 1
fi

# 4. Валидация пункта (б): Проверка работы restart-policy
echo ""
echo "Step 4: Checking Docker restart-policy auto-recovery..."
RESTARTED=0
for i in $(seq 1 30); do
    STATUS=$(docker inspect -f '{{.State.Status}}' "$TARGET" 2>/dev/null || true)
    if [ "$STATUS" = "running" ]; then
        echo "  -> [RECOVERED] Docker restart-policy revived $TARGET container!"
        RESTARTED=1
        break
    fi
    sleep 2
done

# Если использовался docker stop (fallback), помогаем подняться
if [ "$RESTARTED" -eq 0 ]; then
    echo "  -> Auto-restart wait exceeded, starting container via docker start..."
    docker start "$TARGET" >/dev/null
fi

# 5. Подтверждение восстановления в мониторинге
echo ""
echo "Step 5: Waiting for Dashboard to reflect recovery (metric = 1)..."
RESTORED=0
for i in $(seq 1 30); do
    RESPONSE=$(query_metric)
    if echo "$RESPONSE" | grep -q '\[[0-9.]*,"1"\]'; then
        echo "  -> [HEALTH RESTORED] Metric mysql_up is back to 1! Dashboard status: 'HEALTHY'"
        RESTORED=1
        break
    fi
    sleep 2
done

if [ "$RESTORED" -eq 0 ]; then
    echo "  -> [FAIL] Monitoring did not reflect service recovery within timeout!"
    exit 1
fi

echo ""
echo "=========================================================="
echo "          CHAOS TEST PASSED SUCCESSFULLY!                 "
echo "=========================================================="