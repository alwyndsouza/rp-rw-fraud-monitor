#!/usr/bin/env bash
# =============================================================================
# check_pipeline.sh — End-to-end pipeline health check
# Usage: bash scripts/check_pipeline.sh
# Returns 0 on all-green, 1 on any failure.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

NETWORK="rp-rw-fraud-monitor_fraud-net"
PSQL() {
    docker run --rm --network "$NETWORK" -e PGPASSWORD="" postgres:15-alpine \
        psql -h risingwave -p 4566 -U root -d dev -t -A -c "$1" 2>/dev/null || echo ""
}
RPK_CMD="docker compose exec -T redpanda rpk"

echo ""
echo "============================================================"
echo "  Fraud Detection Pipeline — Health Check"
echo "  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
echo "[ 1 ] Service Health"
# ---------------------------------------------------------------------------

for svc in fraud-redpanda fraud-risingwave fraud-producer fraud-grafana; do
    status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [[ "$status" == "running" ]]; then
        ok "Container $svc is running"
    else
        fail "Container $svc is NOT running (status: $status)"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "[ 2 ] Redpanda Topics"
# ---------------------------------------------------------------------------

EXPECTED_TOPICS=(transactions login_events card_events alert_events kyc_profile_events fraud_dlq)
for topic in "${EXPECTED_TOPICS[@]}"; do
    if $RPK_CMD topic describe "$topic" --brokers redpanda:29092 &>/dev/null; then
        ok "Topic '$topic' exists"
    else
        fail "Topic '$topic' NOT FOUND"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "[ 3 ] Producer Liveness Probe"
# ---------------------------------------------------------------------------

if curl -sf http://localhost:8001/health >/dev/null 2>&1; then
    body=$(curl -s http://localhost:8001/health)
    ok "Producer /health returned 200 — ${body}"
else
    fail "Producer /health is unreachable on :8001"
fi

# ---------------------------------------------------------------------------
echo ""
echo "[ 4 ] RisingWave Sources & Views"
# ---------------------------------------------------------------------------

SOURCES=(transactions login_events card_events alert_events kyc_profile_events)
for src in "${SOURCES[@]}"; do
    result=$(PSQL "SELECT COUNT(*) FROM pg_catalog.pg_class WHERE relname = '$src';" | tr -d ' \n')
    if [[ "${result:-0}" -gt 0 ]]; then
        ok "Source '$src' registered in RisingWave"
    else
        fail "Source '$src' NOT found in RisingWave"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "[ 5 ] Fraud Signal Views — Row Counts"
# ---------------------------------------------------------------------------

SIGNAL_VIEWS=(
    stg_transactions
    stg_login_events
    stg_alert_events
    stg_kyc_profiles
    mv_velocity_alerts
    mv_login_failure_storm
    mv_structuring_detection
    mv_cnp_spike
    mv_device_anomalies
    mv_correlated_alert_burst
)

for view in "${SIGNAL_VIEWS[@]}"; do
    rows=$(PSQL "SELECT COUNT(*) FROM $view;" | tr -d ' \n')
    if [[ -z "$rows" ]]; then
        fail "View '$view' query failed"
    elif [[ "$rows" -gt 0 ]]; then
        ok "View '$view' has $rows rows"
    else
        info "View '$view' has 0 rows (may need more warm-up time)"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "[ 6 ] Risk Score View"
# ---------------------------------------------------------------------------

risk_rows=$(PSQL "SELECT COUNT(*) FROM mv_account_risk_score_realtime;" | tr -d ' \n')
critical_rows=$(PSQL "SELECT COUNT(*) FROM mv_account_risk_score_realtime WHERE risk_tier = 'critical';" | tr -d ' \n')

if [[ "${risk_rows:-0}" -gt 0 ]]; then
    ok "mv_account_risk_score_realtime has $risk_rows accounts, ${critical_rows:-0} critical"
    if [[ "${critical_rows:-0}" -ge 5 ]]; then
        ok "At least 5 critical risk accounts detected (fraud injection working)"
    else
        info "Only ${critical_rows:-0} critical accounts — may need more warm-up time (target: 5+)"
    fi
else
    fail "mv_account_risk_score_realtime is empty"
fi

# ---------------------------------------------------------------------------
echo ""
echo "[ 7 ] Open Fraud Cases"
# ---------------------------------------------------------------------------

case_rows=$(PSQL "SELECT COUNT(*) FROM mv_open_fraud_cases;" | tr -d ' \n')
if [[ "${case_rows:-0}" -gt 0 ]]; then
    ok "mv_open_fraud_cases has $case_rows active cases"
else
    info "No open cases yet — warm-up in progress"
fi

# ---------------------------------------------------------------------------
echo ""
echo "[ 8 ] Grafana Reachability & Datasource"
# ---------------------------------------------------------------------------

if curl -sf http://localhost:3000/api/health >/dev/null; then
    ok "Grafana /api/health reachable at http://localhost:3000"

    ds_code=$(curl -s -o /tmp/grafana-ds.json -w '%{http_code}' \
        -u admin:admin -X POST 'http://localhost:3000/api/ds/query' \
        -H 'Content-Type: application/json' \
        -d '{"queries":[{"refId":"A","datasource":{"type":"grafana-postgresql-datasource","uid":"risingwave"},"rawSql":"SELECT 1","format":"table"}]}')
    if [[ "$ds_code" = "200" ]] && ! grep -Eq '"status"[[:space:]]*:[[:space:]]*[45][0-9][0-9]' /tmp/grafana-ds.json; then
        ok "Grafana datasource successfully queries RisingWave"
    else
        fail "Grafana datasource query failed (HTTP $ds_code)"
    fi
else
    fail "Grafana NOT reachable at http://localhost:3000"
fi

# ---------------------------------------------------------------------------
echo ""
echo "[ 9 ] Fraud KPI View"
# ---------------------------------------------------------------------------

fraud_rate=$(PSQL "SELECT ROUND(fraud_rate_pct::NUMERIC, 1) FROM mv_fraud_kpis_1min ORDER BY window_start DESC LIMIT 1;" | tr -d ' \n')
info "Current fraud rate: ${fraud_rate:-N/A}%"

if [[ -n "$fraud_rate" ]] && awk "BEGIN{exit !($fraud_rate > 0)}"; then
    ok "Fraud KPI view returning data"
else
    info "Fraud KPI view has no data yet (normal during first minute)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "[ 10 ] Data Quality Guardrails"
# ---------------------------------------------------------------------------

dup_txn=$(PSQL "SELECT COUNT(*) FROM (SELECT transaction_id FROM stg_transactions GROUP BY transaction_id HAVING COUNT(*) > 1) d;" | tr -d ' \n')
fresh_txn=$(PSQL "SELECT EXTRACT(EPOCH FROM (NOW() - MAX(occurred_at)))::BIGINT FROM stg_transactions;" | tr -d ' \n')

if [[ "${dup_txn:-0}" -eq 0 ]]; then
    ok "No duplicate transaction_id values detected in stg_transactions"
else
    fail "Detected ${dup_txn} duplicate transaction_id values"
fi

if [[ -n "${fresh_txn}" ]] && [[ "${fresh_txn:-99999}" -lt 180 ]]; then
    ok "Transaction stream freshness is ${fresh_txn}s (<180s)"
else
    info "Transaction freshness is ${fresh_txn:-N/A}s (check producer throughput)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "  ${RED}Pipeline has issues. Check logs: make logs${NC}"
    exit 1
else
    echo -e "  ${GREEN}All checks passed. Pipeline is healthy.${NC}"
    exit 0
fi
