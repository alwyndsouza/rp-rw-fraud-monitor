# Operations Runbook

## Starting the Pipeline

```bash
git clone https://github.com/alwyndsouza/rp-rw-fraud-monitor
cd rp-rw-fraud-monitor
make up
```

Wait 90–120 seconds, then verify:
```bash
make validate
```

All checks should be green. If some are yellow (0 rows), wait another 60 seconds — the initial KYC seed and first tumbling windows need time to populate.

---

## Common Operations

### Check current fraud rate
```bash
make fraud-rate
```

### View critical accounts
```bash
make risk
```

### View investigation queue
```bash
make cases
```

### Connect directly to RisingWave
```bash
make psql
# Then run any SQL:
SELECT * FROM mv_open_fraud_cases ORDER BY risk_score DESC LIMIT 5;
```

### Follow producer logs
```bash
make logs-producer
```

---

## Adjusting Fraud Rate

Edit `.env`:
```
FRAUD_RATE=0.20   # 20% fraudulent transactions
```

Restart producer:
```bash
docker compose restart producer
```

To validate the pipeline (confirm fraud injection is the signal source):
```
FRAUD_RATE=0.0
```
After restart, `make risk` should show 0 critical accounts within 2 minutes.

---

## Troubleshooting

### RisingWave materialized views are empty

**Symptom**: `SELECT COUNT(*) FROM mv_velocity_alerts` returns 0.

**Causes and fixes**:
1. **Topics are empty** — check `make logs-producer`. If producer errors, check broker connectivity: `docker compose exec producer env | grep REDPANDA`
2. **SQL init didn't run** — check `docker compose logs risingwave-init`. Re-run manually: `make psql` then paste contents of SQL files.
3. **Not enough events yet** — velocity and structuring windows need multiple events. Wait 60–120 seconds.

### Producer exits immediately

**Symptom**: `docker compose ps` shows producer as `Exited`.

**Fix**: Check logs: `make logs-producer`. Common cause: broker not ready. The producer retries with exponential backoff (up to 10 attempts), but if Redpanda takes > 5 minutes to start, the producer gives up. Restart: `docker compose restart producer`.

### High memory usage

The default configuration targets ~4GB RAM total. If constrained:
1. Reduce `CUSTOMER_POOL_SIZE=100` in `.env`
2. Reduce Redpanda memory: edit `docker-compose.yml` command `--memory=256M`
3. Reduce `TRANSACTION_RATE=5`

---

## Resetting Everything

```bash
make reset
```

This destroys all volumes (Redpanda data, RisingWave state, Grafana data) and rebuilds from scratch.

---

## Monitoring Producer Metrics

Prometheus metrics are exposed at http://localhost:8000/metrics:

```
fraud_producer_events_total{topic="transactions"}
fraud_producer_fraud_injections_total{scenario="velocity"}
fraud_producer_dlq_total
fraud_producer_fraud_rate
```

---

## Adding a New Topic

1. Add topic creation to the `seed-topics` service in `docker-compose.yml`
2. Add a new `CREATE SOURCE` in `sql/01_sources.sql`
3. Add a staging MV in `sql/02_staging.sql`
4. Rebuild: `make reset`
