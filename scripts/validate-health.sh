#!/bin/sh
set -e

GALERA_MODE="${GALERA_MODE:-false}"

check_service() {
    name="$1"
    url="$2"
    printf "Checking %-25s " "[$name]..."
    if curl -s -f -o /dev/null "$url"; then
        echo "OK"
    else
        echo "FAILED"
        return 1
    fi
}

echo "=== Verifying Services Health (Galera Mode: $GALERA_MODE) ==="
check_service "Uptime Kuma"      "http://uptime-kuma:3001"
check_service "Prometheus"       "http://prometheus:9090/-/ready"
check_service "Grafana"          "http://grafana:3000/api/health"

if [ "$GALERA_MODE" = "true" ]; then
    check_service "HAProxy Metrics"     "http://haproxy:8404/metrics"
    check_service "MariaDB Node 1 Exp"  "http://mysqld-exporter-1:9104/metrics"
    check_service "MariaDB Node 2 Exp"  "http://mysqld-exporter-2:9104/metrics"
    check_service "MariaDB Node 3 Exp"  "http://mysqld-exporter-3:9104/metrics"
else
    check_service "MariaDB Exporter"    "http://mysqld-exporter:9104/metrics"
fi

echo "All services are HEALTHY!"