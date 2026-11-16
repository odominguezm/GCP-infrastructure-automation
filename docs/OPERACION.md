# Operación y mantenimiento

> Rutina del proyecto una vez desplegado. Para la primera puesta en marcha ver
> [`EJECUCION.md`](EJECUCION.md); para límites y costes,
> [`FREE-TIER.md`](FREE-TIER.md); para alertas y desastres, los runbooks.

> El perfil por defecto no tiene IP pública: usa `terraform output -raw
> web_tunnel_command` y los comandos de túnel de [`EJECUCION.md`](EJECUCION.md#6-verificar-el-despliegue).
> Si algún recurso de pago aparece en *Billing*, revisa
> [`FREE-TIER.md`](FREE-TIER.md#6-qué-mirar-si-aparece-un-cobro).

## 1. Rutina de despliegue

El camino normal es **push a `main`**: `quality.yml` valida y `main.yml`
despliega por IAP.

```bash
git status
git add -A
git commit -m "FIX: descripción corta"
git push origin main
```

Antes de pushear, reproduce los gates en local (§6). El workflow de deploy:

- Espera hasta 90 min (Grafana tarda 18-27 min en e2-micro).
- Usa un inventario temporal con `127.0.0.1:2222` (extremo local del túnel IAP).
- Cierra el túnel con `if: always()` **al final**.

Si necesitas un deploy puntual sin push: *Actions → Deploy to GCP → Run
workflow*, y opcionalmente indica tags (`stacks`, `verify`, …).

### Checklist después de cada deploy

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'     # 6/6 healthy
curl -s http://localhost:3000/api/health               # Grafana
curl -s http://localhost:9090/-/healthy                # Prometheus
curl -s http://localhost:9093/-/ready                  # Alertmanager
swapon --show
free -h
```

Un contenedor `Up` no significa sano: `verify.yml` falla si alguno queda
`unhealthy` después de 300 s.

## 2. Actualizar versiones de imágenes

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
2. Commit + push (o `--tags stacks`).
3. Verifica: `docker compose ps` y los endpoints.

`pull: missing` descarga el tag nuevo porque no está en caché. No detecta un tag
re-subido con el mismo nombre; para eso habría que fijar digest.

> Grafana no publica tags flotantes tipo `13.2`: usa la versión completa.

## 3. Añadir o cambiar archivos de un stack

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
4. Commit + deploy.

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

Presupuesto de memoria: antes de añadir un servicio, suma su `mem_limit` a la
tabla de `monitoring/docker-compose.yml`. En 1 GB, un techo mal calculado se
convierte en OOM-kill.

## 4. Grafana

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
python3 monitoring/grafana/dashboards/build_dashboard.py
git diff -- monitoring/grafana/dashboards/node-overview.json
```

CI falla si el JSON no coincide con el generador. `allowUiUpdates: false`: los
cambios hechos en la UI se pierden, edita el generador.

## 5. Backups y recuperación

- Cron diario a las **03:00** (hora local de la VM), usuario `ubuntu`.
- Script: `~/backup_npm.sh`, backup consistente de SQLite + `integrity_check` +
  retención local de 7 días + subida a `gs://<bucket>/npm/` si `backup_bucket`
  está definido.
- `backup_bucket` **no** está hardcodeado: llega por `--extra-vars` desde CI,
  `group_vars/all/local.yml` o `-e`. Vacío = solo copia local.
- Snapshot de disco **opcional** a las **04:00 UTC**, retención 7 días. Solo se
  crea si `enable_snapshots = true` en Terraform; no es free tier.

Ejecución manual y verificación:

```bash
# El nombre real del bucket:
terraform output -raw backup_bucket_name

~/backup_npm.sh
ls -lh ~/backups/
gcloud storage ls -l "gs://$(terraform output -raw backup_bucket_name)/npm/"
```

Restauración y reconstrucción: [`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md).
Recuerda: **RPO 24 h**. Un cambio hecho a las 16:00 no está protegido hasta la
mañana siguiente. Sin snapshots, la recuperación de la instancia completa es
Terraform + Ansible + restaurar la base de datos desde GCS.

## 6. Terraform: rutina segura

```bash
terraform plan -no-color | grep -E '^  # |^Plan:'
```

- Si el plan propone **reemplazar** la instancia: **detente**. Revisa `image`,
  `boot_disk_type`, IP y metadata. Un reemplazo destruye el disco y los datos.
- En un proyecto nuevo, el primer plan debe ser todo `create`, nunca `replace`.
- `deletion_protection = true`: para destruir hay que desactivarlo primero.
- Recursos desacoplados de la instancia (bucket IAM, snapshot) se pueden aplicar
  con `-target` sin tocar la VM:

```bash
terraform apply \
  -target='google_compute_resource_policy.daily_snapshot[0]' \
  -target='google_compute_disk_resource_policy_attachment.snapshot_schedule[0]'
```

- Haz copia del estado antes de cambios delicados:

```bash
mkdir -p .local/state-backups
cp terraform.tfstate ".local/state-backups/$(date +%Y%m%d_%H%M%S).tfstate"
```

- El estado de la instancia eliminada está en
  `.local/state-backups/deleted-project/`. **No** lo devuelvas a la raíz: un
  `apply` intentaría reconciliar recursos que ya no existen.
- Riesgo abierto: no hay `backend` remoto. Si el equipo se pierde, se pierde el
  estado. Considerar migrar a un bucket GCS con versioning y locking.

### Cambiar de perfil gratuito a público (y volver)

```hcl
# terraform.tfvars
enable_public_ip = true    # crea IP estática + regla 80/443
```

```bash
terraform plan -out=tfplan
terraform show tfplan      # debe ser create de address + firewall, sin replace de la VM
terraform apply tfplan
terraform output -raw public_ip
```

Para volver al perfil gratuito, pon `false` y aplica. La IP se libera y deja de
facturarse; el firewall web se elimina. El resto de la infraestructura no cambia.

## 7. Alertas y observabilidad

- Reglas: `monitoring/prometheus/alerts.yml`.
- Entrega: `monitoring/alertmanager.yml.j2` (receiver `null` si no hay webhook).
- Runbook: [`runbooks/alerting.md`](runbooks/alerting.md).

Activar entrega real sin tocar el código:

```bash
ansible-playbook site.yml -i /tmp/inventory.ini --private-key ~/.ssh/id_deploy_gcp \
  -e @secrets.yml \
  -e "alertmanager_webhook_url=https://hooks.example.com/services/..."
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

## 8. Triage rápido de incidentes

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
| `wa` > 50 % sostenido | Disco saturado | Ver qué proceso está en `D`; revisar cAdvisor/backups/compaction |
| Load 9-11 | CPU/IO en cola | No reiniciar en bucle; identificar el proceso |
| Contenedor `unhealthy` intermitente | Carga puntual durante el deploy | Esperar la ventana de 300 s; si persiste, mirar healthcheck |
| Swap > 50 % 30 min | La carga normal no cabe en 1 GB | Reducir retención/scrape, quitar servicios |
| Disco < 15 % | Se llena | Logs sin rotación, TSDB, backups, imágenes viejas |
| OOM kill | Límite por contenedor o RAM del host | Ver `docker inspect .State.OOMKilled`; no subir límites a ciegas |

## 9. Seguridad operativa

- **Nunca** pasar secretos inline (`-e grafana_admin_password=...`): quedan en
  `ps` y en logs de Ansible. Usa `-e @secrets.yml` (0600) o `local.yml`.
- Rota la contraseña de Grafana si estuvo expuesta y verifica que la vieja deja
  de funcionar (401).
- No commitear `.env`, `hosts.ini`, `group_vars/all/local.yml`, `.sesion/`,
  `terraform.tfstate*` ni claves.
- Antes de push, el gate de `quality.yml` escanea claves privadas y `.env`.
- `.sesion/` contiene infraestructura real y fragmentos de comandos: es local,
  no se comparte.

## 10. Git: estado y siguientes pasos

Estado al 2026-11-13:

- `66380b9` está **1 commit por delante** de `origin/main` (sin push).
- Hay cambios sin commitear de la revisión de free tier: Terraform, outputs,
  variables, `group_vars`, workflows, dashboard y documentación.
- El estado de Terraform del proyecto eliminado está archivado en
  `.local/state-backups/deleted-project/` y no se versiona.

Secuencia sugerida (revisar antes de ejecutar):

```bash
git status
git diff
git add main.tf variables.tf outputs.tf terraform.tfvars.example \
        group_vars tasks site.yml requirements.yml \
        monitoring proxy app .github .gitignore .yamllint .env.example \
        inventory.example.ini README.md docs
git commit -m "FEAT: perfil Always Free real y despliegue en proyecto nuevo"
```

> El push a `main` dispara `main.yml`, que **fallará** hasta que existan el
> proyecto, el túnel y los secrets/variables de GitHub. Configúralos primero
> (ver [`EJECUCION.md`](EJECUCION.md#7-configurar-cicd-en-github)) o desactiva
> temporalmente el workflow en *Actions*.
