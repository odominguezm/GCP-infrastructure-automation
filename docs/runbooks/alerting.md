# Alerting runbook

What to do when each alert fires. Referenced from the `runbook` annotations in
`monitoring/prometheus/alerts.yml`.

Access: the admin ports are not published to the internet. Everything goes
through an SSH tunnel over IAP, and in the default free profile the VM has no
public IP at all.

```bash
# Parameters of the current deployment
export PROJECT="$(gcloud config get-value project)"
export ZONE="us-central1-a"                 # terraform.tfvars
export INSTANCE="instancia-devops-gcp"      # terraform output -raw instance_name

# Expose Grafana, Prometheus and Alertmanager on localhost
gcloud compute ssh "$INSTANCE" --tunnel-through-iap \
  --project "$PROJECT" --zone "$ZONE" \
  -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093

# Nginx Proxy Manager admin (81) and the web endpoint (80), free profile
gcloud compute ssh "$INSTANCE" --tunnel-through-iap \
  --project "$PROJECT" --zone "$ZONE" \
  -L 8081:localhost:81 -L 8080:localhost:80
```

---

## Grafana is slow to start, and slower than it looks

On this e2-micro Grafana takes **18-27 minutes** to pass its own healthcheck.
That is normal here, not a fault, and it is why the compose file sets
`start_period: 1800s` and why the CI timeout is 90 minutes.

During that window:

- `docker ps` shows Grafana as `Up` and `(health: starting)`.
- The dashboard provisioning runs at startup, so datasources and dashboards only
  appear at the very end of it. An empty Grafana during boot is expected.
- Most of the wait is Grafana contacting the Grafana plugin catalogue on a slow
  link. `GF_PLUGINS_CHECK_FOR_UPDATES=false` removes that call and is what keeps
  the boot inside the timeout.

Do not "speed it up" by restarting it in a loop. Each restart begins the
`start_period` again, so restarting is what turns a slow boot into a container
that never becomes healthy.

### Changing the admin password on an existing volume

`GF_SECURITY_ADMIN_PASSWORD` is read **once**, when Grafana creates its database.
On an existing volume it is ignored, so changing the variable in
`docker-compose.yml` and redeploying silently keeps the old password and looks
like the deployment did not work.

To actually rotate it, reset through the Grafana API from inside the container:

```bash
docker exec -u 472 grafana \
  grafana cli --homepath /usr/share/grafana admin reset-admin-password '<new>'
```

And if you are starting from scratch on purpose, the volume has to go first:

```bash
docker compose down
docker volume rm monitoring_grafana_data   # destroys every dashboard and user
docker compose up -d
```

Only do that when the loss of local Grafana state is acceptable. It is not a
password reset, it is a rebuild.

---

## Memory

**Alerts:** `HostHighMemoryUsage`, `HostCriticalMemoryUsage`

1. Find what is using the memory:
   ```bash
   docker stats --no-stream --sort=-memusage
   ```
2. If it is Prometheus, the usual cause is high cardinality:
   ```bash
   curl -s localhost:9090/api/v1/status/tsdb | head -c 400
   ```
3. If it is Grafana, its cache grows with frequently viewed dashboards. The
   limit can be raised or retention reduced.
4. If no container explains it, restart the affected container and write it
   down. An unexplained restart is an incident to investigate, not a fix.

---

## Swap

**Alert:** `HostHighSwapUsage`

1. Confirm usage:
   ```bash
   swapon --show
   free -h
   ```
2. High and sustained usage almost always means the normal workload does not fit
   in 1 GB. Options, in order of preference:
   - Reduce Prometheus retention (`--storage.tsdb.retention.time`), the biggest
     RAM consumer in the stack.
   - Increase the scrape interval from 15s to 30s, which cuts series roughly in
     half.
   - Remove whatever is not being used from the stack.

**Do not** run `swapoff` while swap is in use. It can exhaust RAM and hang the
host.

---

## Disk

**Alerts:** `HostDiskSpaceLow`, `HostDiskSpaceCritical`

The 30 GB free tier disk cannot be enlarged, so space has to be reclaimed.

1. Find what is using it:
   ```bash
   sudo du -xh --max-depth=2 / | sort -h | tail -20
   sudo docker system df -v
   ```
2. Usual causes, in order:
   - **Docker logs without rotation.** The most common one. `max-size: 10m` and
     `max-file: 3` are already set in the compose files; check they took effect:
     ```bash
     docker inspect -f '{{.HostConfig.LogConfig}}' prometheus
     ```
   - **The Prometheus TSDB.** Lower retention and then, as a last resort:
     ```bash
     docker exec prometheus rm -rf /prometheus/*   # wipes all history
     ```
   - **Accumulated backups.** `ls -lh ~/backups` and adjust
     `backup_retention_days`.
   - **Old images.** `docker image prune -a` (careful: `docker system prune -a`
     also deletes volumes with data).
3. Target: reclaim at least 15% free, sustainably.

---

## Configuration reload

**Alert:** `PrometheusConfigReloadFailed`

1. Check the current config and validate it:
   ```bash
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   ```
2. Validate the rules separately, which is where the error usually is:
   ```bash
   docker compose exec prometheus promtool check rules /etc/prometheus/alerts.yml
   ```
3. Once fixed, reload without restarting the container:
   ```bash
   curl -X POST http://localhost:9090/-/reload
   ```

---

## Target down

**Alert:** `TargetDown`

1. Check the container state:
   ```bash
   docker compose ps
   ```
2. Read the logs of the failing service:
   ```bash
   docker compose logs --tail=100 <service>
   ```
3. Confirm the container answers from the inside:
   ```bash
   docker compose exec <service> wget -qO- http://localhost:<port>/
   ```
4. If the service is fine and the scrape fails, check the Compose network:
   containers resolve each other by service name, not by `localhost`.

---

## Contenedores

There are **no container-level alerts any more.** They used to come from
cAdvisor (`ContainerMemoryLimitExceeded`, `ContainerKilledByOOM`,
`ContainerAbsentFromScrape`, ...) and were removed together with it.

The reason was the box, not the concept: on the e2-micro behind a `pd-standard`
boot disk, cAdvisor's per-container metadata polling was the single largest
disk consumer, driving `io-wait` to ~90% (measured) while the host was
otherwise idle. Removing it brought io-wait to ~1.3%. Container alerts simply
were not worth the host that produced them.

What is left answers the same question with host-level signals:

1. Which container is causing the pressure? Rank them against their own limits:
   ```bash
   docker stats --no-stream --format \
     'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'
   ```
2. If a container is at its ceiling, look at its logs before raising the limit.
   On 1 GB, raising `mem_limit` usually moves the problem onto the host, where
   the OOM killer picks a different victim (watch the `HostHighMemoryUsage`
   alert and `host_kill` metrics instead).
3. "Was the kernel the one that ended it?" still applies when a process dies:
   ```bash
   docker inspect --format '{{.State.OOMKilled}} {{.RestartCount}}' <container>
   ```

The Grafana panel "Memory vs limit, per container" was Removed with the alerts,
because it depended on the same cAdvisor data. Container memory is visible in
`docker stats` and at the host level in node-exporter metrics.

**To bring container alerts back** you have to restore cAdvisor first: add the
`cadvisor` service to `monitoring/docker-compose.yml`, the scrape job to
`monitoring/prometheus/prometheus.yml`, and the `containers` group to
`monitoring/prometheus/alerts.yml`. The comments left at each removal site
describe the exact shape, and the versions are pinned in
`group_vars/all/main.yml`. Do not do this on the live box without re-checking
io-wait afterwards: it is exactly the change that already cost this project a
week of false alarms.

---

## Delivery

Alerts are evaluated by Prometheus and delivered by Alertmanager. The two fail
differently and it matters which one is broken.

| Symptom | Where to look |
|---|---|
| No alert appears in `http://localhost:9090/alerts` | Prometheus: rule not evaluating |
| Alert is firing in Prometheus but the channel is silent | Delivery: see below |

```bash
# Is Prometheus sending to Alertmanager at all?
curl -s http://localhost:9090/api/v1/alertmanagers | python3 -m json.tool

# What has Alertmanager received and what is it doing with it?
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool | head -40

# Verify the rendered config before blaming the service
docker compose exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```

**Deliveries are dropping because no webhook is set.** This is the default state
of a fresh deployment: the receiver is a named `"null"` receiver that accepts the
notifications and discards them, so the pipeline is healthy end to end but no
human is told. Turn on real delivery with:

```bash
ansible-playbook site.yml -i inventory.example.ini \
  -e "alertmanager_webhook_url=https://hooks.example.com/services/..."
```

The URL is a credential to be passed like `grafana_admin_password`: both go in
`~/group_vars/all/local.yml` on the instance (mode `0600`, never committed, wins
the variable merge over `group_vars/all/main.yml` because files are read in
alphabetical order). `alertmanager.yml` is rendered from the `.j2` template with
mode `0600`, and omitting the variable renders the delivery-discarding `"null"`
receiver instead of failing.

**Note on YAML:** the receiver name is quoted, `"null"`, on purpose. Unquoted,
YAML reads it as the null value and Alertmanager refuses to start.

### Testing without waiting for a real failure

```bash
curl -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"critical"},
       "annotations":{"summary":"test"},
       "startsAt":"2026-01-01T00:00:00Z"}]'
```

`startsAt` in the past makes it fire immediately. It should appear in the channel
within `group_wait` (30 s). This is the only way to confirm delivery works
without waiting for a genuine outage.

### Silences

During maintenance, silence the alerts you are about to cause instead of muting
the channel for everyone:

```bash
amtool --alertmanager.url=http://localhost:9093 silence add \
  --alertname 'HostHighMemoryUsage' \
  --comment 'RAM upgrade window' --duration=2h

amtool --alertmanager.url=http://localhost:9093 silence query
```

---

## Escalation procedure

1. **Record** the exact fire time and what was observed.
2. **Mitigate** using the runbook for the symptom. Mitigate before investigating.
3. **Communicate** if there is end-user impact.
4. **Investigate** the root cause once stable.
5. **Close** with a short summary. If it was a false positive, fix or delete the
   rule: an alert that requires no action is either removed or downgraded to
   `info`.