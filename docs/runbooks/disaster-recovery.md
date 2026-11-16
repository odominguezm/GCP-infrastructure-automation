# Disaster recovery runbook

What to do when the data is wrong or gone, and how long each path takes.

The two recovery paths are not interchangeable. Picking the wrong one wastes the
first hour of an incident, so the decision table is first, once you can get in at
all.

> **Project parameters.** This runbook works for any deployment of this
> repository; it does not hardcode a project, zone, instance or bucket. Set them
> once per shell:
>
> ```bash
> export PROJECT="$(gcloud config get-value project)"
> export ZONE="us-central1-a"                      # must match terraform.tfvars
> export INSTANCE="instancia-devops-gcp"           # terraform output -raw instance_name
> export BUCKET="$(terraform output -raw backup_bucket_name)"  # empty = no off-site copy
> ```
>
> If `BUCKET` is empty, path A step 1 only has the local copies on the instance.

## Access is IAP-only

The instance has **no public IP** in the default free profile, and its firewall
opens `tcp:22` to Google's Identity-Aware Proxy range (`35.235.240.0/20`) and
nothing else. `ssh ubuntu@<public-ip>` is not supposed to work.

```bash
# Interactive session
gcloud compute ssh "$INSTANCE" --project "$PROJECT" --zone "$ZONE" --tunnel-through-iap

# Ansible can run ON the instance against a local inventory (hosts.ini uses
# ansible_connection=local). Log in first, then:
cd ~ && ANSIBLE_COLLECTIONS_PATH=~/.ansible/collections ansible-playbook site.yml

# Grafana, only reachable through the same tunnel
gcloud compute ssh "$INSTANCE" --project "$PROJECT" --zone "$ZONE" \
  --tunnel-through-iap -L 3000:localhost:3000
```

In the default profile there are no ports open to the internet at all: Nginx
Proxy Manager (80/443), its admin panel (81), Grafana (3000), Prometheus (9090),
Alertmanager (9093) and the demo app (21680) are all reached through an IAP
tunnel. With `enable_public_ip = true`, only 80/443 become reachable from the
internet.

If you change `ssh_source_ranges`, re-check the rule before assuming you are
locked out:

```bash
gcloud compute firewall-rules describe vpc-devops-lab-allow-ssh-iap \
  --project "$PROJECT" --format='value(sourceRanges)'
```

## Recovery objectives

| Objective | Value | Applies to |
|---|---|---|
| **RPO** (how much data can be lost) | 24 h | Nginx Proxy Manager database |
| **RTO** (how long until it is back) | ~30 min | Nginx Proxy Manager database |
| **RPO** | 24 h | Whole instance (only with `enable_snapshots = true`) |
| **RTO** | ~45 min | Whole instance |

The database RPO is 24 h because the backup runs once a day at 03:00. A change
made at 16:00 is not protected until the next morning. Raising it means more
frequent backups, which on this instance is a decision about the memory budget.

Whole-instance objectives only apply when scheduled snapshots are enabled. They
are **off by default** because snapshot storage is not part of the Always Free
tier (see [`../FREE-TIER.md`](../FREE-TIER.md)). Without them, path B rebuilds
from Terraform + Ansible and restores the database from Cloud Storage.

## Which path do I need?

| Symptom | Path |
|---|---|
| A proxy host, certificate or user is missing or wrong, but the VM is fine | [A. Restore the database](#a-restore-the-database) |
| The VM is unreachable, the disk is corrupted, or the instance is gone | [B. Rebuild the instance](#b-rebuild-the-instance) |
| The database is corrupt and there is no usable backup | [C. Last resort](#c-last-resort-rebuild-the-npm-database) |

## Inventory

```bash
# Off-site database backups (skip if BUCKET is empty)
gcloud storage ls -l "gs://$BUCKET/npm/"

# Snapshots of the boot disk (empty unless enable_snapshots = true)
gcloud compute snapshots list --project "$PROJECT"

# Local copies still on the instance
ls -lh ~/backups/
```

`BUCKET` is the value of `backup_bucket_name` in `terraform.tfvars`, or
`terraform output -raw backup_bucket_name`. An empty value means Terraform
created no bucket and `backup_npm.sh` keeps local copies only.

## Before you run terraform apply

`terraform apply` can recreate the instance, so it should only be run when you
have decided to rebuild the machine. Know what it is about to do first.

```bash
terraform plan -out=tfplan
terraform show -no-color tfplan | less
```

In a freshly created project, the first plan must be all `create`, never
`replace`. If an existing deployment shows `must be replaced`, stop and read the
diff: a replacement destroys the boot disk and its data.

### Why the boot disk is pd-standard

`pd-standard` is the only disk class included in the Always Free tier, and
`variables.tf` rejects anything else. It is not a compromise: the ~90% io-wait
(PSI `avg60`) that used to sag this e2-micro was caused almost entirely by
cAdvisor hammering the disk with per-container metadata reads; the moment it was
removed, io-wait dropped to ~1.3% in repose with the stack healthy. 22-45
baseline IOPS on a 30 GB `pd-standard` disk is nowhere near the real limit, so
`pd-balanced` would buy IOPS nothing uses while making the lab billable. Change
it only with new evidence.

A plan can still show "must be replaced" for the instance for two reasons:

1. **Metadata drift.** The config injects the key from `ssh_public_key_path`;
   extra keys added by hand to the live instance are removed by Terraform. That
   is an in-place update, not a replacement, but check the `ssh-keys` diff before
   applying and only apply it deliberately.
2. **A newer 22.04 patch.** `ubuntu-2204-lts` is a family, not a pinned patch.
   When Canonical publishes a newer `ubuntu-2204-jammy-v20XXXXXX`, a plan may
   show the VM as replaceable so the disk is recreated from the new image. That
   is the normal roll of a tracking family: follow section B below.

Do not "fix" a plan by running `terraform apply` to see what happens.

### Optional resources are decoupled on purpose

The snapshot schedule attachment and the bucket IAM grant reference
`var.instance_name` and `google_service_account.backup` directly instead of
reading values off `google_compute_instance.vm`. That keeps a forced instance
replacement from dragging backups and snapshots into the same plan.

When `enable_snapshots = true`, those resources can be applied with `-target`
without touching the machine:

```bash
terraform apply \
  -target='google_compute_resource_policy.daily_snapshot[0]' \
  -target='google_compute_disk_resource_policy_attachment.snapshot_schedule[0]'
```

When `enable_snapshots = false`, those resources have `count = 0` and cannot be
targeted: enable the variable first.

## A. Restore the database

### 1. Choose the backup

```bash
gcloud storage ls -l "gs://$BUCKET/npm/"
```

Pick by timestamp. Object versioning is on, so a deleted or overwritten backup
can be recovered for 7 days after deletion, which turns "I overwrote it" from a
terminal event into a slow afternoon.

If `BUCKET` is empty there is no off-site copy. Use the local backup:

```bash
ls -lh ~/backups/
# copy the chosen file to /tmp/restore.sqlite before continuing
```

### 2. Verify it before touching anything

A backup that has not been opened is not a backup. Download and check it
without writing it anywhere near the live database:

```bash
gsutil cp "gs://$BUCKET/npm/npm_db_20261003_030000.sqlite" /tmp/restore.sqlite

python3 - <<'PY'
import sqlite3
db = sqlite3.connect('/tmp/restore.sqlite')
print('integrity:', db.execute('PRAGMA integrity_check').fetchone()[0])
print('tablas:   ', [r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type='table'")])
print('proxies:  ', db.execute('SELECT count(*) FROM proxy_host').fetchone()[0])
print('certificados:', db.execute('SELECT count(*) FROM certificate').fetchone()[0])
db.close()
PY
```

`integrity` must say `ok` and the counts must be plausible. A backup that passes
the integrity check but has zero proxy hosts is a backup of an empty database,
which happens when the service was misconfigured long before the failure.

### 3. Take a copy of the current state anyway

```bash
cp ~/proxy/data/database.sqlite ~/backups/database.sqlite.before-restore.$(date +%s)
```

If the restore turns out to restore the wrong thing, this is the only way back.

### 4. Stop the service and replace the database

```bash
cd ~/proxy
docker compose stop app
rm -f data/database.sqlite data/database.sqlite-wal data/database.sqlite-shm
cp /tmp/restore.sqlite data/database.sqlite
chown 1000:1000 data/database.sqlite   # the UID NPM runs as
docker compose up -d app
docker compose logs -f app
```

The `-wal` and `-shm` files matter. Leaving a stale write-ahead log next to a
restored database makes SQLite try to replay transactions that the restored file
does not contain, which produces a database that opens and then returns wrong
data. Deleting them is not optional.

### 5. Confirm

```bash
docker exec nginx-proxy-manager sh -c 'ls -l /data/database.sqlite'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/
```

Open the NPM panel through the IAP tunnel (`-L 8081:localhost:81`): the proxy
hosts and certificates from the backup date must be there.

## B. Rebuild the instance

For an unreachable VM, a corrupted disk, or a machine that has to be replaced.

### 1. Snapshot first, always

Even with scheduled snapshots disabled, take a manual one before touching the
instance. It is billed per GB-month, but it is the only state you cannot
recreate later. If you want to avoid the charge entirely, skip this step and
accept that anything not in the database backup is lost.

```bash
gcloud compute instances snapshot "$INSTANCE" --project "$PROJECT" --zone "$ZONE"
```

### 2. Restore the disk from a snapshot (only if one exists)

```bash
gcloud compute snapshots list --project "$PROJECT" \
  --filter='name~devops-daily' --sort-by='~creationTimestamp' --limit=1

gcloud compute disks create "$INSTANCE-restored" \
  --project "$PROJECT" --zone "$ZONE" \
  --source-snapshot SNAPSHOT_NAME
```

With `enable_snapshots = false` (the default) this list is empty and there is
nothing to restore from. Continue with step 3.

### 3. Replace the instance

```bash
cd ~/Developer/GitHub-Portafolio/GCP-infrastructure-automation

terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

Terraform recreates the instance from `image` (Ubuntu 22.04 by default), which
means a fresh disk. **Terraform is not what restores the data here.** The flow
is:

1. Terraform brings up an empty instance.
2. Ansible re-applies the configuration.
3. The database is restored from Cloud Storage following path A.

If the instance is unhealthy but still exists and you want to force a new boot
disk, `deletion_protection = true` has to be disabled first:

```bash
terraform apply -replace google_compute_instance.vm
# then restore the Grafana admin password into the instance, chmod 600:
#   ~/group_vars/all/local.yml
ansible-playbook site.yml
# then restore the database from Cloud Storage, path A
```

### 4. Rebuild from scratch, when there is no snapshot

The default free profile has no snapshots, so this is the normal rebuild path:

1. Create the infrastructure with `terraform apply` (or restore it in a new
   project if the old one is gone).
2. Run `ansible-playbook site.yml` by IAP or inside the VM.
3. Restore the database from Cloud Storage, path A.
4. Set `grafana_admin_password` again through `group_vars/all/local.yml` or
   `--extra-vars`; it is never stored in the repository.

## C. Last resort: rebuild the NPM database

Only when there is no usable backup at all. Nginx Proxy Manager stores its state
entirely in that SQLite file, so losing it loses the configuration.

```bash
cd ~/proxy
docker compose down
rm -rf data/database.sqlite*
docker compose up -d app
docker logs nginx-proxy-manager 2>&1 | sed -n '/Email:/,/Password:/p'
```

On first start NPM generates a random administrator email and password and prints
them **once**. Capture them immediately; they are not recoverable.

## Why the bucket uses objectCreator, not objectAdmin

The instance runs as the dedicated `devops-backup` service account, with no
keys: it authenticates through the instance metadata server, so there is no
private key on the disk to steal or rotate.

It can create backup objects and nothing else. It cannot read them, and it cannot
delete them.

- Expiry is handled by a GCS lifecycle rule, so the VM never needs delete
  permission.
- A compromised instance cannot erase the history of its own backups.

This is why the retention logic in `backup_npm.sh.j2` uses `find -delete` for the
local copies and says nothing about the bucket. The bucket deletes its own
objects.

Restores are an operator action with the owner's credentials, not something the
instance performs on its own.

## Verifying that recovery actually works

An untested backup is a hypothesis. The cheapest possible test, worth running
once after the first deploy:

```bash
# Take a backup, then restore it into /tmp and check it
~/backup_npm.sh
gsutil ls "gs://$BUCKET/npm/" | tail -1
gsutil cp "gs://$BUCKET/npm/$(gsutil ls "gs://$BUCKET/npm/" | tail -1 | xargs basename)" /tmp/check.sqlite
python3 -c "import sqlite3; print(sqlite3.connect('/tmp/check.sqlite').execute('PRAGMA integrity_check').fetchone()[0])"
```

If that prints `ok`, the RPO and RTO in this document are real numbers. If it
does not, they are guesses.
