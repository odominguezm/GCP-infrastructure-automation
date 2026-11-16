# Operación y mantenimiento

> Guía única del proyecto: primera puesta en marcha, rutina de despliegue,
> cambios, backups, Terraform seguro y troubleshooting. Para límites y costes,
> [`FREE-TIER.md`](FREE-TIER.md); para incidentes, los
> [runbooks](runbooks/).
>
> El perfil por defecto no tiene IP externa: usa `terraform output -raw
> web_tunnel_command` o los comandos de túnel de §1.5.

## 1. Puesta en marcha desde cero

### 1.1 Requisitos

| Herramienta | Versión | Para qué |
|---|---|---|
| `gcloud` | reciente | Autenticación, IAP, inspección |
| Terraform | ≥ 1.9 (CI usa 1.16.2) | Infraestructura |
| Python | 3.10+ | Ansible y scripts |
| `ansible-core` | ≥ 2.17, < 2.20 | Configuración |
| Colecciones | ver `requirements.yml` | `community.docker`, `ansible.posix` |
| Docker | reciente | Solo para validar los compose en local |
| Clave SSH | ED25519 | Bootstrap de la VM (`~/.ssh/id_deploy_gcp`) |

```bash
gcloud auth login
gcloud auth application-default login     # Terraform usa ADC
gcloud config set project <TU_PROYECTO>
ansible-galaxy collection install -r requirements.yml
```

> **No hay backend remoto de Terraform.** El estado vive en
> `terraform.tfstate` en este equipo. Haz copia antes de operar y no lo borres.
> El proyecto anterior se eliminó: no hay estado antiguo que importar ni
> reutilizar.

### 1.2 Crear el proyecto y proteger el presupuesto

1. Crea el proyecto en la consola y vincúlalo a una cuenta de facturación. Sin
   billing account no se puede usar la capa gratuita.
2. Crea una **alerta de presupuesto** de 1 USD en *Billing → Budgets and
   alerts*. Es la red de seguridad si un recurso de pago queda activo.
3. Anota el **project ID** (no el nombre visible): es único y va en
   `terraform.tfvars`.

Comprueba que no hay recursos de una etapa anterior:

```bash
gcloud compute instances list --project <TU_PROYECTO>
gcloud compute addresses list --project <TU_PROYECTO>
gcloud storage buckets list --project <TU_PROYECTO>
gcloud compute snapshots list --project <TU_PROYECTO>
```

Todo debe estar vacío. Si no lo está, investiga antes de aplicar: una IP
reservada sin usar cuesta `$0.01/hora`.

### 1.3 Configuración local

```bash
git clone <repo> && cd GCP-infrastructure-automation

cp terraform.tfvars.example terraform.tfvars
cp .env.example .env                # solo para validar compose en local
```

Edita `terraform.tfvars`:

```hcl
project_id = "<TU_PROYECTO>"
region     = "us-central1"          # o us-west1 / us-east1
zone       = "us-central1-a"

enable_egress = false               # se abre solo durante el despliegue

backup_bucket_name = ""             # o "<proyecto>-backups-<sufijo>"
```

**No commitees** `terraform.tfvars` ni `.env` (ya están en `.gitignore`).

Comprueba la clave pública que se inyectará en la VM:

```bash
ls -l ~/.ssh/id_deploy_gcp.pub
# Si no existe:
ssh-keygen -t ed25519 -f ~/.ssh/id_deploy_gcp -C "gcp-deploy"
```

### 1.4 Terraform (solo infraestructura)

> ⚠️ **Regla de oro:** nunca ejecutes un `terraform apply` completo sin leer el
> plan. Un cambio en `image`, `boot_disk_type` o la IP puede reemplazar la
> instancia y destruir el disco. En un proyecto nuevo el plan debe ser todo
> "create", nunca "replace".

```bash
make init
make plan
terraform show tfplan | less       # revisar: create/destroy/replace
make apply
```

Salidas útiles:

```bash
terraform output deployment_profile        # free-tier | egress-window
terraform output internal_ip
terraform output -raw external_ip          # null en el perfil gratuito
terraform output -raw ssh_command
terraform output -raw web_tunnel_command
terraform output -raw grafana_tunnel_command
terraform output -raw backup_bucket_name
```

> En el perfil gratuito `external_ip` es `null` y no hay ningún puerto abierto.
> Eso es correcto.

### 1.5 Secretos y despliegue

`grafana_admin_password` es **obligatoria** y no tiene default: si falta, el play
falla antes de tocar nada. `alertmanager_webhook_url` es opcional.

**Recomendado:** un archivo de secretos con modo 0600 y `-e @archivo`, nunca la
contraseña en la línea de comandos (queda en `ps` y en los logs de Ansible):

```bash
cat > secrets.yml <<'YAML'
grafana_admin_password: "..."          # > 12 caracteres
# alertmanager_webhook_url: "https://hooks.example.invalid/services/..."
# backup_bucket: "<proyecto>-backups-<sufijo>"   # opcional, activa off-site
YAML
chmod 600 secrets.yml        # secrets.yml está en .gitignore
```

Ventana de egress, despliegue y cierre:

```bash
make egress-on
make deploy
make egress-off
```

`make deploy` (`scripts/deploy.sh`) hace, en orden:

1. Comprueba que `deployment_profile` es `egress-window`, **solo si el run
   necesita descargar algo** (deploy completo o tags `docker`, `stacks`,
   `backups`, `all`).
2. Abre el túnel IAP en `127.0.0.1:2222` y espera a que acepte conexiones.
3. Crea un inventario temporal y registra la clave del host con `ssh-keyscan`.
4. Ejecuta `ansible-playbook site.yml -i <inventario> -e @secrets.yml`.
5. Cierra el túnel y borra el inventario con `trap`, aunque Ansible falle.

Para un bloque concreto o un dry-run:

```bash
make deploy ARGS="--tags verify"   # no necesita ventana de egress
make verify                        # alias de --tags verify
make deploy ARGS="--check"         # tampoco necesita egress
```

Esto permite verificar o endurecer el host con la ventana cerrada, es decir, en
el perfil de coste 0,00 USD.

### 1.6 Verificar el despliegue

El play termina con `verify.yml`, que exige 6/6 contenedores `healthy` (espera
hasta 300 s) y reporta swap. Para comprobarlo a mano, dentro de la VM:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker compose -f ~/proxy/docker-compose.yml ps
swapon --show
free -h

curl -s -o /dev/null -w '%{http_code}\n' http://localhost/        # NPM
curl -s http://localhost:3000/api/health                          # Grafana
curl -s http://localhost:9090/-/healthy                           # Prometheus
curl -s http://localhost:9093/-/ready                             # Alertmanager
```

Un contenedor `Up` no significa sano: `verify.yml` falla si alguno queda
`unhealthy` después de 300 s.

Túneles para paneles y web:

```bash
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap \
  --project <TU_PROYECTO> --zone us-central1-a \
  -L 8080:localhost:80 -L 3000:localhost:3000 -L 9090:localhost:9090 \
  -L 8081:localhost:81 -L 9093:localhost:9093
```

- Web / NPM: <http://localhost:8080>
- Grafana: <http://localhost:3000>
- Prometheus: <http://localhost:9090>
- NPM admin: <http://localhost:8081>
- Alertmanager: <http://localhost:9093>

## 2. Cómo funciona

### 2.1 Capas

| Capa | Herramienta | Responsabilidad | Dónde se ejecuta |
|---|---|---|---|
| Infraestructura | Terraform | Red, firewall, VM, SA y bucket | **Local** (operador) |
| Configuración | Ansible | Swap, Docker, stacks, backups, hardening, verificación | Por túnel IAP o dentro de la VM |
| Servicios | Docker Compose | NPM, demo, Prometheus, Grafana, Alertmanager | En la VM |

La regla que ordena todo: **Terraform no configura servicios y Ansible no crea
infraestructura**. El pipeline de GitHub Actions solo ejecuta Ansible.

### 2.2 Qué crea Terraform

- **VPC** `vpc-devops-lab` + subnet `subnet-devops` `10.0.1.0/24`, con acceso
  privado a Google.
- **Firewall:** una única regla `allow-ssh-iap` (`tcp:22` solo desde
  `35.235.240.0/20`). No existe regla 80/443.
- **VM** e2-micro, Ubuntu 22.04, disco `pd-standard` 30 GB,
  `deletion_protection` activo, `block-project-ssh-keys=true`, SA dedicada
  `devops-backup`. Sin `access_config` no hay IP externa.
- **Bucket** de backups (`backup_bucket_name`, opcional): UBLA, acceso público
  bloqueado, versioning, lifecycle 7 días y expiración rápida de versiones no
  vigentes. La VM solo tiene `roles/storage.objectCreator`. Debe estar en
  `us-central1`, `us-west1` o `us-east1`, en la misma región que la VM.
- **Ventana de egress:** `enable_egress = true` añade un `access_config` con
  IP efímera. No crea firewall y desaparece al volver a `false`.

### 2.3 Orden de `site.yml`

1. **`swap`** — sin 2 GB de swap, el resto del play puede morir por OOM en 1 GB.
2. **`docker`** — limpia sources APT legacy antes de cualquier `apt update` (si
   no, APT falla por `Signed-By` en conflicto), instala Engine + Compose v2.
3. **`stacks`** — crea directorios, renderiza `.env` (0600, `no_log`), copia
   **solo definiciones**, detecta cambios por fingerprint y recrea únicamente
   `prometheus` y `alertmanager` cuando su configuración cambió. Grafana queda
   fuera a propósito: un recreate forzado cuesta ~20 minutos.
4. **`backups`** — instala el script, ejecuta una prueba real y crea el cron. Si
   `backup_bucket` está definido, instala `google-cloud-cli` (para `gsutil`) y la
   prueba corre con `BACKUP_STRICT_UPLOAD=1`: si la subida falla, el deploy
   falla. No lista el bucket, porque la SA no tiene permiso de lectura.
5. **`hardening`** — último y con `reload`, no `restart`: aplica SSH sin cortar
   la conexión que ejecuta el play. Si `sshd -t` falla, hace rollback.
6. **`verify`** (siempre) — exige los 6 contenedores esperados, espera hasta
   300 s a que estén `healthy` y reporta swap.

`group_vars/all/main.yml` es la fuente única de verdad. La lista
`compose_stacks` declara explícitamente **qué archivo es definición y cuál es
dato**; eso es lo que evita que un `synchronize` borre la base de datos de NPM.

### 2.4 Presupuesto de memoria (1 GB)

Los límites son techos, no reservas. La suma es deliberada para que el OOM
killer del kernel no elija víctimas por su cuenta.

| Servicio | Medido | Límite |
|---|---|---|
| Grafana | ~145 MiB | 288 MiB |
| Prometheus | ~46 MiB | 192 MiB |
| Nginx Proxy Manager | ~30 MiB | 128 MiB |
| Alertmanager | ~18 MiB | 48 MiB |
| node-exporter | ~14 MiB | 32 MiB |
| demo-app nginx | ~1 MiB | 24 MiB |
| **Total** | **~330 MiB** | **712 MiB** |

El resto queda para kernel, systemd, sshd, dockerd y journald, con 2 GB de swap
como red de seguridad para picos, no como memoria de trabajo.

### 2.5 Servicios y persistencia

| Stack | Servicio | Puerto | Persistencia |
|---|---|---|---|
| `proxy` | Nginx Proxy Manager 2.16.0 | 80/443 en el host; 81 loopback | `proxy/data`, `proxy/letsencrypt` |
| `app` | nginx demo | `127.0.0.1:21680` | `app/html` (solo lectura) |
| `monitoring` | Prometheus v3.15.0 | `127.0.0.1:9090` | volumen `prometheus_data` |
| `monitoring` | Grafana 13.2.3 | `127.0.0.1:3000` | volumen `grafana_data` |
| `monitoring` | Alertmanager v0.34.1 | `127.0.0.1:9093` | volumen `alertmanager_data` |
| `monitoring` | node-exporter v1.12.1 | `9100` interno | ninguno (read-only) |

## 3. Rutina de despliegue

### 3.1 Desde el operador (recomendado)

```bash
git pull
make test                   # gates locales
make egress-on
make deploy
make egress-off
```

### 3.2 Desde CI

El camino normal es **push a `main`**: `quality.yml` valida y `main.yml`
despliega por IAP. Antes de pushear, reproduce los gates en local (§11).

```bash
git status
git add -A
git commit -m "FIX: descripción corta"
git push origin main
```

La ventana de egress tiene que estar abierta en el momento del push; la SA del
pipeline solo abre túneles, no modifica la instancia. Si necesitas un deploy
puntual sin push: *Actions → Deploy to GCP → Run workflow*, opcionalmente con
tags (`stacks`, `verify`, …).

## 4. Actualizar versiones de imágenes

Las versiones viven **solo** en `group_vars/all/main.yml`. El `.env` del
servidor se renderiza desde ahí.

```yaml
# group_vars/all/main.yml
prometheus_version: "v3.15.0"
alertmanager_version: "v0.34.1"
node_exporter_version: "v1.12.1"
grafana_version: "13.2.3"
nginx_version: "1.31-alpine"
npm_version: "2.16.0"
```

1. Cambia la versión.
2. `make egress-on && make deploy && make egress-off` (o push).
3. Verifica: `docker compose ps` y los endpoints.

`pull: missing` descarga el tag nuevo porque no está en caché. No detecta un tag
re-subido con el mismo nombre; para eso habría que fijar digest.

> Grafana no publica tags flotantes tipo `13.2`: usa la versión completa.

## 5. Añadir o cambiar archivos de un stack

**Nunca** se sincroniza un directorio completo. Solo lo declarado en
`compose_stacks`:

```yaml
compose_stacks:
  - name: monitoring
    recreate_services: [prometheus, alertmanager]
    sync:
      - {src: monitoring/docker-compose.yml, dest: docker-compose.yml}
      - {src: monitoring/prometheus/prometheus.yml, dest: prometheus/prometheus.yml}
      # template: true  -> se renderiza con Jinja
      # owner/group     -> cuándo el contenedor corre con otro UID
```

Pasos para añadir un archivo:

1. Añade la entrada a `sync`.
2. Si necesita variables, añádelas a `templates/env.j2` y al compose.
3. Si es una plantilla, marca `template: true` y ajusta `owner`/`group`.
4. `make deploy` (con la ventana de egress abierta).

`tasks/stacks.yml` crea los directorios destino, copia/renderiza, comprueba que
los archivos con secretos quedan 0600 y calcula un fingerprint por stack. Si el
fingerprint cambia, recrea **solo** `recreate_services` (por defecto ninguno)
para evitar que un bind mount siga apuntando al inode viejo.

### Añadir un stack nuevo

1. Crea `<stack>/docker-compose.yml` (con `x-logging`, healthcheck, `mem_limit`).
2. Declara el stack en `compose_stacks` con sus `sync`.
3. Añade el nombre a la lista de contenedores esperados en `tasks/verify.yml`.
4. Si expone métricas, añade el scrape en `monitoring/prometheus/prometheus.yml`.
5. Valida: `docker compose -f <stack>/docker-compose.yml config --quiet`.
6. Deploy y comprueba `healthy`.

Antes de añadir un servicio, suma su `mem_limit` a la tabla de
`monitoring/docker-compose.yml`. En 1 GB, un techo mal calculado se convierte en
OOM-kill.

## 6. Grafana

### Cambiar la contraseña (de verdad)

`GF_SECURITY_ADMIN_PASSWORD` se lee **una sola vez**, al crear la base de datos
de Grafana. En un volumen existente se ignora: cambiarla en `.env` y desplegar
no hace nada.

```bash
# 1. Rotar en caliente (usuario admin)
docker exec -u 0 grafana grafana cli \
  --homepath /usr/share/grafana admin reset-admin-password '<nueva>'

# 2. Verificar
curl -s -o /dev/null -w '%{http_code}\n' -u "admin:<nueva>" \
  http://localhost:3000/api/orgs          # 200
curl -s -o /dev/null -w '%{http_code}\n' -u "admin:<vieja>" \
  http://localhost:3000/api/orgs          # 401
```

3. Actualiza `group_vars/all/local.yml` (o el secret de GitHub) para que el
   próximo arranque desde cero use la nueva.

Recrear el volumen (`docker volume rm monitoring_grafana_data`) **no** es un
reset de contraseña: borra dashboards y usuarios. Solo como rebuild deliberado.

### Dashboards

Se aprovisionan desde `monitoring/grafana/dashboards/node-overview.json`, que se
genera:

```bash
make dashboard
git diff -- monitoring/grafana/dashboards/node-overview.json
```

CI falla si el JSON no coincide con el generador. `allowUiUpdates: false`: los
cambios hechos en la UI se pierden, edita el generador.

## 7. Backups y recuperación

- Cron diario a las **03:00** (hora local de la VM), usuario `ubuntu`.
- Script: `~/backup_npm.sh`, backup consistente de SQLite + `integrity_check` +
  retención local de 7 días + subida a `gs://<bucket>/npm/` si `backup_bucket`
  está definido.
- `backup_bucket` **no** está hardcodeado: llega por `--extra-vars` desde CI,
  `group_vars/all/local.yml` o `-e`. Vacío = solo copia local.
- No hay snapshots de disco. La reconstrucción completa es Terraform + Ansible
  más restaurar la base de datos desde GCS.

Ejecución manual y verificación **desde el operador** (la SA de la VM no puede
listar el bucket, por diseño):

```bash
# El nombre real del bucket:
BUCKET="$(terraform output -raw backup_bucket_name)"

# La VM crea la copia local:
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap \
  --zone us-central1-a --command '~/backup_npm.sh && ls -lh ~/backups/'

# El operador la verifica en GCS (credenciales de owner/lector):
gcloud storage ls -l "gs://$BUCKET/npm/"
```

Restauración y reconstrucción: [`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md).
Recuerda: **RPO 24 h**. Un cambio hecho a las 16:00 no está protegido hasta la
mañana siguiente.

## 8. Terraform: rutina segura

```bash
terraform plan -no-color | grep -E '^  # |^Plan:'
```

- Si el plan propone **reemplazar** la instancia: **detente**. Revisa `image`,
  `boot_disk_type`, IP y metadata. Un reemplazo destruye el disco y los datos.
- En un proyecto nuevo, el primer plan debe ser todo `create`, nunca `replace`.
- `deletion_protection = true`: para destruir hay que desactivarlo primero.
- Para la ventana de egress usa siempre el Makefile: `make egress-on` /
  `make egress-off`.
- Haz copia del estado antes de cambios delicados:

```bash
mkdir -p .local/state-backups
cp terraform.tfstate ".local/state-backups/$(date +%Y%m%d_%H%M%S).tfstate"
```

- El proyecto anterior se eliminó: no queda estado antiguo en el repositorio ni
  conviene recrearlo. Un `apply` solo debe reconciliar recursos del proyecto
  actual.
- Riesgo abierto: no hay `backend` remoto. Si el equipo se pierde, se pierde el
  estado. Considerar migrar a un bucket GCS con versioning y locking.

## 9. Configurar CI/CD en GitHub

`quality.yml` funciona sin configuración. `main.yml` **no arranca** hasta
configurar esto en *Settings → Secrets and variables → Actions*:

### Secrets

| Nombre | Valor |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<num>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` |
| `GCP_SERVICE_ACCOUNT` | Email de la SA que abre el túnel |
| `SSH_PRIVATE_KEY` | Clave privada ED25519 de `ubuntu` (la pareja de `id_deploy_gcp.pub`) |
| `GF_SECURITY_ADMIN_PASSWORD` | Contraseña inicial de Grafana |

### Variables

| Nombre | Ejemplo |
|---|---|
| `GCP_PROJECT_ID` | `<TU_PROYECTO>` |
| `GCP_INSTANCE_NAME` | `instancia-devops-gcp` |
| `GCP_ZONE` | `us-central1-a` |
| `GCP_USER` | `ubuntu` |
| `BACKUP_BUCKET` | Nombre del bucket o vacío (opcional) |

### Requisitos en GCP para Workload Identity

- Pool + provider OIDC de GitHub configurados.
- SA de despliegue con permiso para abrir túneles IAP sobre la instancia
  (`roles/iap.tunnelResourceAccessor`) y para consultar la instancia
  (`roles/compute.viewer`). No necesita Editor.
- El repositorio autorizado en la condición del provider.

El workflow hace, en orden: checkout → auth WIF → gcloud → **levanta** el túnel
en `127.0.0.1:2222` → prepara la clave → `ssh-keyscan` → instala Ansible →
`syntax-check` → `ansible-playbook` → **cierra** el túnel (`if: always()`).

## 10. Tags de Ansible

```bash
ansible-playbook site.yml --list-tags
make deploy ARGS="--tags swap"
make deploy ARGS="--tags stacks"
make deploy ARGS="--tags verify"
make deploy ARGS="--skip-tags hardening"
```

`site.yml` solo tiene una tarea `always` (el assert de RAM); `verify` está
marcado `always` para que un deploy nunca termine verde con un stack caído.

Si ejecutas Ansible **dentro** de la VM (solo si el repositorio ya está allí),
crea `hosts.ini` con `ansible_connection=local` (el bloque comentado de
`inventory.example.ini`) y exporta
`ANSIBLE_COLLECTIONS_PATH=/home/ubuntu/.ansible/collections`; sin eso Ansible
usa las colecciones del sistema y `docker_compose_v2` no existe.

## 11. Validar sin desplegar

```bash
make test
```

`make test` ejecuta `terraform init/validate`, `ansible-playbook
--syntax-check`, `docker compose config` de los tres stacks, regenera el
dashboard, comprueba que no hay drift, y verifica `terraform fmt` y
`git diff --check`.

Si prefieres los comandos sueltos:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
echo 'var.enable_egress' | terraform console -var project_id=ci

ansible-lint site.yml
yamllint .

export GF_SECURITY_ADMIN_USER=ci
export GF_SECURITY_ADMIN_PASSWORD=ci-only-not-a-real-secret
for s in app proxy monitoring; do
  docker compose -f "$s/docker-compose.yml" config --quiet
done

python3 monitoring/grafana/dashboards/build_dashboard.py
git diff --exit-code -- monitoring/grafana/dashboards/node-overview.json
```

Esto reproduce lo que corre `quality.yml`.

## 12. Alertas y observabilidad

- Prometheus scrapea cada 15 s: él mismo, node-exporter y Alertmanager.
- Retención doble: 15 días **y** 2 GB (lo que llegue primero).
- Alertas por grupos:
  - `availability`: `TargetDown`, `PrometheusConfigReloadFailed`, `Watchdog`.
  - `resources`: memoria >85 %/>95 %, swap >50 %, disco <15 %/<5 %, load15.
  - `capacity`: cardinalidad >5000 series.
- `Watchdog` siempre dispara: es el *dead man's switch*. Si deja de llegar, el
  problema es el propio sistema de alertas.
- Alertmanager entrega a un receiver `"null"` (descarta) si no hay webhook. Con
  `alertmanager_webhook_url` cambia a Slack/Discord compatible. Las alertas
  `info` nunca se envían. Las reglas de inhibición evitan tormentas cuando una
  causa común (`TargetDown`, memoria crítica) dispara varias alertas a la vez.

Activar entrega real sin tocar el código:

```bash
make deploy ARGS='-e "alertmanager_webhook_url=https://hooks.example.com/services/..."'
```

El archivo renderizado queda 0600 y propiedad de `65534:65534` (el UID con el
que corre Alertmanager). Si el contenedor reinicia con "permission denied" al
leer su config, ese es el primer sitio donde mirar.

Prueba de entrega sin esperar una caída:

```bash
curl -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"critical"},
       "annotations":{"summary":"test"},
       "startsAt":"2026-01-01T00:00:00Z"}]'
```

Silenciar durante mantenimiento:

```bash
amtool --alertmanager.url=http://localhost:9093 silence add \
  --alertname 'HostHighMemoryUsage' --comment 'ventana de mantenimiento' --duration=2h
```

Runbook: [`runbooks/alerting.md`](runbooks/alerting.md).

## 13. Triage rápido de incidentes

La instancia es frágil por diseño (1 GB, disco de red). Antes de culpar a la
configuración, mira el recurso:

```bash
vmstat 1 5                 # wa alto = I/O; r/b en cola
ps -eo stat,pid,comm | awk '$1 ~ /D/'   # procesos en I/O ininterrumpible
docker stats --no-stream --sort=-memusage
df -h / && sudo du -xh --max-depth=2 / | sort -h | tail -20
sudo journalctl -k --since '1 hour ago' | grep -i oom
```

| Señal | Significado | Acción |
|---|---|---|
| `wa` > 50 % sostenido | Disco saturado | Ver qué proceso está en `D`; revisar backups/compaction |
| Load 9-11 | CPU/IO en cola | No reiniciar en bucle; identificar el proceso |
| Contenedor `unhealthy` intermitente | Carga puntual durante el deploy | Esperar la ventana de 300 s; si persiste, mirar healthcheck |
| Swap > 50 % 30 min | La carga normal no cabe en 1 GB | Reducir retención/scrape, quitar servicios |
| Disco < 15 % | Se llena | Logs sin rotación, TSDB, backups, imágenes viejas |
| OOM kill | Límite por contenedor o RAM del host | Ver `docker inspect .State.OOMKilled`; no subir límites a ciegas |

## 14. Seguridad operativa

- **Nunca** pasar secretos inline (`-e grafana_admin_password=...`): quedan en
  `ps` y en logs de Ansible. Usa `-e @secrets.yml` (0600) o `local.yml`.
- Rota la contraseña de Grafana si estuvo expuesta y verifica que la vieja deja
  de funcionar (401).
- No commitear `.env`, `hosts.ini`, `group_vars/all/local.yml`, `.sesion/`,
  `terraform.tfstate*` ni claves.
- Antes de push, el gate de `quality.yml` escanea claves privadas y `.env`.
- `.sesion/` contiene infraestructura real y fragmentos de comandos: es local,
  no se comparte.
- La VM no puede leer ni borrar sus backups (`objectCreator`); las
  restauraciones las hace el operador con sus credenciales.

## 15. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `apt`/`docker pull` falla con timeout | Ventana de egress cerrada | `make egress-on`, desplegar, `make egress-off` |
| El deploy dice "The instance has no egress" | `deployment_profile` es `free-tier` y el run descarga paquetes o imágenes | `make egress-on`; `make verify` no lo necesita |
| `Conflicting values set for option Signed-By` | Quedó un `.list` legacy de Docker | `tasks/docker.yml` lo limpia; manual: `rm /etc/apt/sources.list.d/*docker*.list` |
| `module docker_compose_v2 not found` | Faltó `ANSIBLE_COLLECTIONS_PATH` en la VM | Exportar y reinstalar colecciones |
| `Permission denied (publickey)` | Clave distinta o túnel caído | Revisar `--private-key`, que el túnel :2222 escuche y `ssh-keyscan` |
| Grafana `unhealthy` durante 20 min | Arranque lento normal en e2-micro | Esperar; **no** reiniciar en bucle |
| Contenedor pasa a `unhealthy` y vuelve | Carga alta durante el deploy | `verify.yml` espera 300 s; no bajar el margen |
| Cambio de config no se aplica | Bind mount con inode viejo | El fingerprint de `stacks.yml` recrea consumidores; o `--force-recreate` manual |
| `terraform plan` propone reemplazar la VM | `image`, disco o metadata distintos | **No aplicar**; alinear la variable con la realidad |
| `external_ip` es `null` | Perfil gratuito | Correcto; usar `web_tunnel_command` |
| Alertmanager `permission denied` en su config | Dueño/modo incorrecto | Debe ser `65534:65534`, modo 0600 |
| El deploy de CI falla al conectar | Túnel cerrado antes de tiempo o egress cerrado | El stop está al final del workflow; abrir `make egress-on` antes del push |

Más casos en los runbooks.
