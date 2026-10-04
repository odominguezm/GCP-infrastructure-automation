# Disaster recovery runbook

What to do when the data is wrong or gone, and how long each path takes.

The two recovery paths are not interchangeable. Picking the wrong one wastes the
first hour of an incident, so the decision table is first, once you can get in at
all.

## Access is IAP-only

The instance has **no public SSH**. The firewall opens `tcp:22` to Google's
Identity-Aware Proxy range (`35.235.240.0/20`) and nothing else, so
`ssh ubuntu@<public-ip>` does not work any more and is not supposed to.

```bash
# Interactive session
gcloud compute ssh instancia-devops-gcp \
  --project devops-lab-orlando --zone us-central1-a --tunnel-through-iap

# Ansible against the instance, which also needs the tunnel
gcloud compute start-iap-tunnel instancia-devops-gcp 22 \
  --local-host-port=localhost:2222 \
  --project devops-lab-orlando --zone us-central1-a &
ansible-playbook site.yml -i 'localhost:2222,' -c local -e ansible_ssh_common_args='-o ProxyCommand=none'

# Grafana, only reachable through the same tunnel
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap \
  --zone us-central1-a --project devops-lab-orlando -L 3000:localhost:3000
```

Ports 80 and 443 are the only other things open to the internet. Nginx Proxy
Manager's admin panel (81), Grafana (3000), Prometheus (9090) and the demo app
(21680) are all bound to `127.0.0.1` inside the VM and must be reached the same
way.

If you change `ssh_source_ranges`, re-check the rule before assuming you are
locked out:

```bash
gcloud compute firewall-rules describe vpc-devops-lab-allow-ssh-iap \
  --project devops-lab-orlando --format='value(sourceRanges)'
```

## Recovery objectives

| Objective | Value | Applies to |
|---|---|---|
| **RPO** (how much data can be lost) | 24 h | Nginx Proxy Manager database |
| **RTO** (how long until it is back) | ~30 min | Nginx Proxy Manager database |
| **RPO** | 24 h | Whole instance |
| **RTO** | ~45 min | Whole instance |

The database RPO is 24 h because the backup runs once a day at 03:00. It is
worth stating plainly rather than hiding: a change made at 16:00 is not
protected until the next morning. Raising it means moving to more frequent
backups, which on this instance means a decision about the memory budget.

## Which path do I need?

| Symptom | Path |
|---|---|
| A proxy host, certificate or user is missing or wrong, but the VM is fine | [A. Restore the database](#a-restore-the-database) |
| The VM is unreachable, the disk is corrupted, or the instance is gone | [B. Rebuild the instance](#b-rebuild-the-instance) |
| The database is corrupt and there is no usable backup | [C. Last resort](#c-last-resort-rebuild-the-npm-database) |

## Inventory

```bash
# Off-site database backups
gcloud storage ls -l gs://$BUCKET/npm/

# Snapshots of the boot disk
gcloud compute snapshots list --project devops-lab-orlando

# Local copies still on the instance
ls -lh ~/backups/
```

`$BUCKET` is the value of `backup_bucket_name` in `terraform.tfvars`.

## Before you run terraform apply

`terraform apply` is destructive by design here: it recreates the instance, so it
should only be run when you have decided to rebuild the machine. Know what it is
about to do first.

```bash
terraform plan -no-color | grep -E '^  # |^Plan:'
terraform show -no-color terraform.tfplan | less    # with -out=terraform.tfplan
```

### The boot disk type forces a replacement

The live boot disk is `pd-standard`; `main.tf` declares `pd-balanced`. Disk type
is a `ForceNew` attribute, so **every plan shows the instance as "must be
replaced"**, and that is the one line in the plan that can destroy the machine
and everything on it.

That is a known, deliberate divergence rather than something to discover during an
incident. Two options:

- Leave it. The plan is honest about it and you confirm before applying.
- Make `main.tf` match reality (set the disk type to `pd-standard`) and lose the
  cheaper disk type on the next rebuild.

Do not "fix" it by running `terraform apply` to see what happens.

### What has been decoupled on purpose

The snapshot schedule attachment and the bucket IAM grant used to read their
values off `google_compute_instance.vm`, which made them depend on the instance
resource. Any forced replacement then pulled a backup and a scheduled snapshot
into the same plan, so a decision about backups implied rebuilding the VM.

They now reference `var.instance_name` and `google_service_account.backup`
directly. That is why they can be applied with `-target` without touching the
machine:

```bash
terraform apply -target='google_compute_resource_policy.daily_snapshot[0]' \
  -target='google_compute_disk_resource_policy_attachment.snapshot_schedule[0]'
```

## A. Restore the database

### 1. Choose the backup

```bash
gcloud storage ls -l gs://$BUCKET/npm/
```

Pick by timestamp. Object versioning is on, so a deleted or overwritten backup
can be recovered for 7 days after deletion, which turns "I overwrote it" from a
terminal event into a slow afternoon.

### 2. Verify it before touching anything

A backup that has not been opened is not a backup. Download and check it
without writing it anywhere near the live database:

```bash
gsutil cp gs://$BUCKET/npm/npm_db_20261003_030000.sqlite /tmp/restore.sqlite

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

Open the NPM panel: the proxy hosts and certificates from the backup date must be
there.

## B. Rebuild the instance

For an unreachable VM, a corrupted disk, or a machine that has to be replaced.

### 1. Snapshot first, always

```bash
gcloud compute instances snapshot instancia-devops-gcp \
  --project devops-lab-orlando --zone us-central1-a
```

Whatever the diagnosis, do this before touching anything. It is the only state
you cannot recreate later.

### 2. Restore the disk from the latest scheduled snapshot

```bash
gcloud compute snapshots list --project devops-lab-orlando \
  --filter='name~devops-daily' --sort-by='~creationTimestamp' --limit=1

gcloud compute disks create instancia-devops-gcp-restored \
  --project devops-lab-orlando --zone us-central1-a \
  --source-snapshot SNAPSHOT_NAME
```

### 3. Replace the instance

```bash
cd ~/Developer/GitHub-Portafolio/GCP-infrastructure-automation

terraform apply \
  -var 'image=ubuntu-os-cloud/ubuntu-2204-lts'
```

Important: Terraform recreates the instance from `image`, which means a fresh
disk. **Terraform is not what restores the data here.** The flow is:

1. Terraform brings up an empty instance.
2. Ansible re-applies the configuration.
3. The database is restored from Cloud Storage following path A.

Passing `-var 'image=ubuntu-os-cloud/ubuntu-2204-lts'` matters if the snapshot is
from 22.04: an instance booted from 24.04 against a 22.04 disk can fail on boot.

### 4. Rebuild from scratch, when there is no snapshot

```bash
terraform apply -replace google_compute_instance.vm
ansible-playbook site.yml -i inventory.example.ini \
  -e "grafana_admin_password=$(openssl rand -base64 24)"
# then restore the database from Cloud Storage, path A
```

## C. Last resort: rebuild the NPM database

Only when there is no usable backup at all. Nginx Proxy Manager can be
reconfigured from scratch: it stores its state entirely in that SQLite file, so
losing it loses the configuration but not the proxy host definitions if they are
documented elsewhere.

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

The instance runs as `devops-backup@devops-lab-orlando.iam.gserviceaccount.com`,
a dedicated account with no keys: it authenticates through the instance metadata
server, so there is no private key on the disk to steal or rotate.

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
gsutil ls gs://$BUCKET/npm/ | tail -1
gsutil cp "gs://$BUCKET/npm/$(gsutil ls gs://$BUCKET/npm/ | tail -1 | xargs basename)" /tmp/check.sqlite
python3 -c "import sqlite3; print(sqlite3.connect('/tmp/check.sqlite').execute('PRAGMA integrity_check').fetchone()[0])"
```

If that prints `ok`, the RPO and RTO in this document are real numbers. If it
does not, they are guesses.