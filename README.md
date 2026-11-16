# 🚀 GCP DevOps Infrastructure Automation

Laboratorio de infraestructura como código en Google Cloud Platform, diseñado
para el **Always Free Tier real**: una instancia `e2-micro` (1 GB de RAM, 30 GB
de disco `pd-standard`) provisionada con **Terraform**, configurada con
**Ansible** y validada por un pipeline de **GitHub Actions**.

El perfil por defecto **no crea IP pública ni snapshots**: todo se accede por
túneles IAP, que son gratuitos. Así el coste mensual es **0,00 USD**, no "casi
gratis". Si quieres una demo pública en 80/443, `enable_public_ip = true` la
habilita y la documentación explica el coste (≈ `$3,65/mes` por la IP).

El objetivo no es solo que funcione, sino que sea reproducible, observable y
recuperable: firewalls mínimos, secretos fuera del repositorio, backups
verificados y un despliegue que falla si los servicios no quedan sanos.

## 🛠️ Stack

| Capa | Tecnología |
|---|---|
| Nube | GCP · `e2-micro` · Ubuntu 22.04 · disco `pd-standard` 30 GB |
| Infraestructura | Terraform ≥ 1.9 (provider `hashicorp/google` 6.x) |
| Configuración | Ansible (`site.yml` como entrada única) |
| Contenedores | Docker Engine + Docker Compose v2 |
| Proxy / TLS | Nginx Proxy Manager 2.16.0 (TLS público solo con `enable_public_ip`) |
| Observabilidad | Prometheus v3.15.0 · Grafana 13.2.3 · Alertmanager v0.34.1 · node-exporter v1.12.1 |
| CI/CD | GitHub Actions (Workload Identity Federation + túnel IAP) |
| Backups | SQLite backup API → GCS + snapshots diarios opcionales |
| Acceso | IAP para SSH, web, Grafana, Prometheus y NPM admin |

## 📚 Documentación

| Documento | Contenido |
|---|---|
| [`docs/FREE-TIER.md`](docs/FREE-TIER.md) | Qué cubre Always Free, qué cuesta y cómo desplegar a coste 0 |
| [`docs/README.md`](docs/README.md) | Índice y orden de lectura |
| [`docs/ESTRUCTURA.md`](docs/ESTRUCTURA.md) | Mapa de archivos, reglas y hallazgos de la revisión |
| [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) | Diagramas, red, seguridad, memoria y decisiones |
| [`docs/EJECUCION.md`](docs/EJECUCION.md) | Despliegue paso a paso desde cero |
| [`docs/OPERACION.md`](docs/OPERACION.md) | Rutina, cambios y troubleshooting |
| [`docs/PROMPT-NUEVA-SESION.md`](docs/PROMPT-NUEVA-SESION.md) | Traspaso listo para otra sesión |
| [`docs/runbooks/alerting.md`](docs/runbooks/alerting.md) | Qué hacer ante cada alerta |
| [`docs/runbooks/disaster-recovery.md`](docs/runbooks/disaster-recovery.md) | Restauración y reconstrucción |

## 🏗️ Arquitectura en una imagen

Perfil por defecto (coste 0,00 USD):

```text
Operador / GitHub Actions
        │  IAP (túnel SSH autenticado, gratuito)
        ▼
   VM e2-micro (sin IP externa)
   ├── Nginx Proxy Manager :80/:443  ──▶ demo-app (nginx)
   │        admin :81 loopback
   ├── Prometheus :9090 loopback ──▶ node-exporter
   ├── Grafana :3000 loopback
   ├── Alertmanager :9093 loopback
   └── backup_npm.sh ──▶ GCS (off-site, opcional)
```

Con `enable_public_ip = true` se añade una IP estática y la regla 80/443; es el
único cambio de arquitectura y el único coste fijo.

- **Público por defecto:** nada. Solo IAP.
- **SSH:** solo desde el rango de Identity-Aware Proxy (`35.235.240.0/20`).
- **Paneles admin** (NPM 81, Grafana 3000, Prometheus 9090, Alertmanager 9093)
  escuchan en `127.0.0.1` y se acceden por túnel IAP.
- **Sin claves de servicio en disco:** la VM usa su service account; el pipeline
  usa WIF.

## ⚡ Quick start

```bash
# 1. Configuración local (nunca commitear estos archivos)
cp terraform.tfvars.example terraform.tfvars
# edita project_id; deja enable_public_ip = false para coste 0
cp .env.example .env
gcloud auth application-default login

# 2. Infraestructura: SIEMPRE revisar el plan antes de aplicar
terraform init
terraform validate
terraform plan -out=tfplan
terraform show tfplan        # ¿algún recurso de pago? ¿algún "must be replaced"?
terraform apply tfplan

# 3. Configuración: desde tu equipo, por túnel IAP (primer despliegue)
#    La VM nueva NO tiene el repositorio ni Ansible; por eso el primer deploy se
#    lanza desde tu checkout, igual que hace GitHub Actions.
cat > secrets.yml <<'YAML'
grafana_admin_password: "cambia-esto-por-una-contrasena-larga"
YAML
chmod 600 secrets.yml

ansible-galaxy collection install -r requirements.yml
gcloud compute start-iap-tunnel instancia-devops-gcp 22 \
  --local-host-port=localhost:2222 \
  --project <TU_PROYECTO> --zone us-central1-a &
ssh-keyscan -H -p 2222 127.0.0.1 >> ~/.ssh/known_hosts
printf '[gcp_servers]\ngcp-server ansible_host=127.0.0.1 ansible_port=2222 ansible_user=ubuntu\n' \
  > /tmp/inventory.ini
ansible-playbook site.yml -i /tmp/inventory.ini \
  --private-key ~/.ssh/id_deploy_gcp -e @secrets.yml
kill %1 2>/dev/null || true
```

Guía completa, secretos, perfil público y modo CI en
[`docs/EJECUCION.md`](docs/EJECUCION.md). Límites y costes en
[`docs/FREE-TIER.md`](docs/FREE-TIER.md).

> ⚠️ **No hay backend remoto de Terraform.** El estado es local
> (`terraform.tfstate`). Haz copia antes de operar. El estado de la instancia
> anterior se movió a `.local/state-backups/deleted-project/` y **no** debe
> reutilizarse en el proyecto nuevo.

## 🔁 Pipeline CI/CD

`quality.yml` corre en cada push/PR y no toca la nube: `terraform fmt/validate`,
tflint, checkov, ansible-lint, yamllint, `docker compose config`, drift del
dashboard, validación de reglas de Prometheus y de la plantilla de Alertmanager,
y actionlint.

`main.yml` despliega en push a `main` (o manual) **solo Ansible**, por túnel IAP.
Configura en *Settings → Secrets and variables → Actions*:

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<num>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` |
| Secret | `GCP_SERVICE_ACCOUNT` | Email de la SA de despliegue |
| Secret | `SSH_PRIVATE_KEY` | Clave privada ED25519 de `ubuntu` |
| Secret | `GF_SECURITY_ADMIN_PASSWORD` | Password inicial de Grafana |
| Variable | `GCP_PROJECT_ID` | `<TU_PROYECTO>` |
| Variable | `GCP_INSTANCE_NAME` | `instancia-devops-gcp` |
| Variable | `GCP_ZONE` | `us-central1-a` |
| Variable | `GCP_USER` | `ubuntu` |
| Variable | `BACKUP_BUCKET` | Nombre del bucket o vacío (opcional) |

Notas: el timeout es de **90 minutos** porque Grafana tarda 18-27 min en arrancar
en una e2-micro. `BACKUP_BUCKET` activa la copia off-site; sin ella el backup
local sigue funcionando, pero no hay DRP. `Alertmanager` entrega a un receiver
`null` hasta que se configure `alertmanager_webhook_url` (opcional).

## 💸 Coste

| Concepto | Perfil gratuito | Perfil público |
|---|---|---|
| `e2-micro` + 30 GB `pd-standard` | 0,00 USD | 0,00 USD |
| IP externa | no se crea | ≈ 3,65 USD/mes |
| Snapshots | desactivados | ≈ 1 USD/mes si se activan |
| VPC Flow Logs | desactivados | opcional, por GiB |
| Egress | 1 GB/mes gratis | 1 GB/mes gratis; después `$0.12/GiB` |
| Backup GCS | dentro de 5 GB gratis | dentro de 5 GB gratis |

Detalle y verificación en [`docs/FREE-TIER.md`](docs/FREE-TIER.md).

## 🛡️ Continuidad de negocio

| Capa | Qué cubre | Frecuencia | Retención | Coste |
|---|---|---|---|---|
| Backup SQLite (API de backup + `integrity_check`) | Configuración de NPM | Diario 03:00 | 7 días · local + GCS | Gratis (5 GB) |
| Snapshot de disco (opcional) | Instancia completa | Diario 04:00 UTC | 7 días | ≈ 1 USD/mes |

**RPO 24 h / RTO ~30 min** para la base de datos. El snapshot es opcional: sin
él, la reconstrucción de la instancia se hace con Terraform + Ansible y se
restaura la base de datos desde GCS. Restauración paso a paso en
[`docs/runbooks/disaster-recovery.md`](docs/runbooks/disaster-recovery.md).

## ⚙️ Optimización para 1 GB

- **Swap 2 GB** con `vm.swappiness=10`: usa RAM primero y disco solo bajo
  presión; persistente en `/etc/fstab`.
- **Límites de memoria por contenedor** que suman 712 MiB, medidos con
  `docker stats` (consumo real en reposo ~330 MiB).
- **Sin cAdvisor:** su sondeo de metadatos llevaba el disco `pd-standard` a
  ~90 % de io-wait. Al retirarlo bajó a ~1.3 %. node-exporter cubre las métricas
  del host.
- **Grafana fuera de los recreate automáticos:** su arranque cuesta ~20 min.

## 👨‍💻 Autor

Orlando Domínguez M. — [MIT License](LICENSE)
