# Estructura del proyecto

> Revisión: 2026-11-13. Este documento es el mapa de archivos: qué es cada cosa,
> qué se puede tocar y qué no. Para el "por qué" de las decisiones, ver
> [`ARQUITECTURA.md`](ARQUITECTURA.md). Para ejecutarlo, ver
> [`EJECUCION.md`](EJECUCION.md).

## 1. Vista general

```
GCP-infrastructure-automation/
├── README.md                     Punto de entrada (resumen + quick start)
├── LICENSE                       MIT
│
├── Terraform (infraestructura)   ── se ejecuta SOLO en local, nunca en CI
│   ├── main.tf                   VPC, subnet, firewall, VM, SA, bucket de
│   │                             backups, IP/snapshots opcionales
│   ├── variables.tf              Variables + validaciones estrictas de free tier
│   ├── outputs.tf                IP interna/pública, URL y comandos de túnel IAP
│   ├── terraform.tfvars.example  Plantilla versionada de valores reales
│   ├── terraform.tfvars          Valores reales (gitignored)
│   └── .terraform.lock.hcl       Versiones exactas del provider (versionado)
│
├── Ansible (configuración de la VM) ── una sola entrada: site.yml
│   ├── ansible.cfg               Inventario, SSH, caché de facts, callbacks
│   ├── site.yml                  Playbook único; importa tasks/ por tags
│   ├── requirements.yml          Colecciones (community.docker, ansible.posix…)
│   ├── inventory.example.ini     Inventario de ejemplo (sin IP real)
│   ├── hosts.ini                 Inventario local de la VM (gitignored)
│   ├── group_vars/all/main.yml   TODA la configuración: versiones, backups,
│   │                             SSH, swap, memoria, stacks y qué se sincroniza
│   ├── tasks/
│   │   ├── swap.yml              Swap 2 GB + swappiness + persistencia fstab
│   │   ├── docker.yml            Docker Engine + Compose v2 + grupo docker
│   │   ├── stacks.yml            Sincroniza definiciones y levanta los stacks
│   │   ├── backups.yml           Script de backup + cron + prueba real
│   │   ├── ssh_hardening.yml     Drop-in sshd validado con rollback
│   │   └── verify.yml            Salud real de contenedores + swap
│   └── templates/
│       ├── env.j2                .env de los stacks (0600, con secretos)
│       └── backup_npm.sh.j2      Backup SQLite consistente + subida a GCS
│
├── Stacks Docker                 ── definiciones versionadas, datos NO
│   ├── app/
│   │   ├── docker-compose.yml    nginx demo en 127.0.0.1:21680
│   │   └── html/index.html       Contenido estático
│   ├── proxy/
│   │   └── docker-compose.yml    Nginx Proxy Manager: 80/443 en el host, 81 local
│   └── monitoring/
│       ├── docker-compose.yml    Prometheus, node-exporter, Grafana, Alertmanager
│       ├── alertmanager.yml.j2   Config renderizada (webhook opcional)
│       ├── prometheus/
│       │   ├── prometheus.yml    Scrapes: prometheus, node_exporter, alertmanager
│       │   └── alerts.yml        Reglas: disponibilidad, recursos, capacidad
│       └── grafana/
│           ├── provisioning/
│           │   ├── datasources/prometheus.yml   Prometheus + Alertmanager
│           │   └── dashboards/dashboards.yml    Provider de dashboards
│           └── dashboards/
│               ├── build_dashboard.py           Generador del dashboard
│               └── node-overview.json           JSON generado (versionado)
│
├── CI/CD
│   └── .github/workflows/
│       ├── quality.yml           Lint/validación; nunca toca la nube
│       └── main.yml              Deploy: WIF + túnel IAP + Ansible
│
├── docs/
│   ├── README.md                 Índice de documentación
│   ├── FREE-TIER.md              Límites, costes y checklist del proyecto nuevo
│   ├── ESTRUCTURA.md             Este archivo
│   ├── ARQUITECTURA.md           Componentes, flujos y decisiones
│   ├── EJECUCION.md              Despliegue paso a paso desde cero
│   ├── OPERACION.md              Rutina, cambios y troubleshooting
│   ├── PROMPT-NUEVA-SESION.md    Traspaso listo para copiar en otra sesión
│   └── runbooks/
│       ├── alerting.md           Qué hacer cuando salta cada alerta
│       └── disaster-recovery.md  Restaurar backup / reconstruir instancia
│
├── Configuración transversal
│   ├── .env.example              Plantilla de variables de los stacks
│   ├── .gitignore                Ignora estado, secretos, hosts.ini, .sesion/
│   ├── .yamllint                 Reglas de lint YAML (120 columnas, comments)
│   └── .ai-context.md            Contexto para asistentes (gitignored)
│
└── Solo en local (nunca se versiona)
    ├── .terraform/               Binarios del provider (~86 MB)
    ├── terraform.tfstate         Estado del proyecto NUEVO (aún no existe)
    ├── .ansible_facts_cache/     Caché de facts de Ansible
    ├── .sesion/                  Notas de sesión (infra real, no commitear)
    └── .local/
        └── state-backups/
            ├── deleted-project/  Estado de devops-lab-orlando (archivado)
            └── *.backup          Copias antiguas del estado
```

## 2. Qué es cada archivo (detalle)

### Terraform

| Archivo | Responsabilidad | Notas |
|---|---|---|
| `main.tf` | Habilita APIs, VPC/subnet, firewall 22 solo IAP, VM e2-micro sin IP externa, SA dedicada, bucket de backups con versioning/lifecycle, IP/firewall web y snapshots **solo si se activan** | No define backend: el estado es local. Flow logs opt-in |
| `variables.tf` | Validaciones estrictas de free tier: región ∈ {us-central1, us-west1, us-east1}, zona coherente, `e2-micro`, `pd-standard`, disco 10-30 GB, bucket en la misma región, snapshots ≤ 7 días, SSH sin `0.0.0.0/0` | Un plan que se salga del free tier falla antes de crear nada |
| `outputs.tf` | `deployment_profile`, `internal_ip`, `public_ip` (null si no hay IP), `web_url`, comandos de túnel para SSH/web/Grafana/NPM, puertos públicos y bucket | En el perfil gratuito `public_ip = null` y `public_open_ports = []` |
| `terraform.tfvars.example` | Plantilla documentada con el perfil gratuito | `enable_public_ip`, `enable_snapshots` y `enable_vpc_flow_logs` en `false` |
| `terraform.tfvars` | Valores locales con placeholder de proyecto nuevo | Gitignored; bucket vacío hasta que se decida activar off-site |
| `.terraform.lock.hcl` | Fija el provider `hashicorp/google` 6.x | Sí se versiona (reproducibilidad) |

### Ansible

| Archivo | Responsabilidad | Notas |
|---|---|---|
| `site.yml` | Orden del despliegue: `swap → docker → stacks → backups → hardening → verify` | `verify` corre siempre; `hardening` va al final con reload |
| `ansible.cfg` | `hosts.ini`, usuario `ubuntu`, host key checking ON, timeout 30 s, caché de facts, pipelining | No desactivar host key checking |
| `hosts.ini` | `ansible_connection=local` | Solo válido **dentro de la VM**; está gitignored |
| `inventory.example.ini` | Ejemplo apuntando a `127.0.0.1:2222` (extremo local del túnel IAP) | El pipeline construye el mismo inventario en el runner |
| `group_vars/all/main.yml` | Fuente única de verdad: versiones de imágenes, retención, backup, SSH, swap, lista `compose_stacks` | Lo que se sincroniza se declara aquí, archivo por archivo |
| `tasks/swap.yml` | Crea/formatea/activa swap y `vm.swappiness=10` | Idempotente; verifica al final |
| `tasks/docker.yml` | Limpia sources legacy, repo deb822, instala Docker/Compose v2, añade `ubuntu` a `docker` | Falla si el usuario no existe |
| `tasks/stacks.yml` | Crea directorios, renderiza `.env` (0600), copia solo definiciones, detecta cambios por fingerprint y recrea solo los consumidores | **Nunca** sincroniza datos |
| `tasks/backups.yml` | Instala `backup_npm.sh`, ejecuta una prueba, instala `google-cloud-cli` si hay bucket, verifica la copia off-site y crea el cron 03:00 | Un backup no probado no cuenta |
| `tasks/ssh_hardening.yml` | Escribe `99-hardening.conf`, valida con `sshd -t`, rollback si falla, reload y verificación con `sshd -T` | No corta la conexión del play |
| `tasks/verify.yml` | Valida contenedores esperados, espera `healthy` (hasta 300 s) y reporta swap | Un pipeline verde = servicios sanos |
| `templates/env.j2` | Genera el `.env` por stack con contraseña y versiones | `no_log`, modo 0600 |
| `templates/backup_npm.sh.j2` | Backup con API de SQLite, `integrity_check`, retención 7 días y subida opcional a GCS | `flock` contra solapamientos |

### Stacks Docker

| Archivo | Responsabilidad | Notas |
|---|---|---|
| `app/docker-compose.yml` | nginx demo, solo `127.0.0.1:21680` | Entra por NPM (HTTP por túnel o HTTPS con `enable_public_ip`) |
| `app/html/index.html` | Página estática | Sin placeholders Jinja: se copia tal cual, no se renderiza |
| `proxy/docker-compose.yml` | NPM 2.16.0: 80/443 en el host, 81 en loopback | Público solo con `enable_public_ip = true`; datos en `./data` y `./letsencrypt` |
| `monitoring/docker-compose.yml` | Prometheus, node-exporter, Grafana, Alertmanager; límites de memoria y healthchecks | cAdvisor deliberadamente ausente |
| `monitoring/prometheus/prometheus.yml` | Scrapes 15 s, retención 15d/2GB, envío a Alertmanager | Sin job de cAdvisor |
| `monitoring/prometheus/alerts.yml` | `availability`, `resources`, `capacity` | `info` = sin acción; `Watchdog` siempre activo |
| `monitoring/alertmanager.yml.j2` | Routing, inhibición, receiver `null` o webhook | Es plantilla porque Alertmanager no expande env vars |
| `monitoring/grafana/provisioning/*` | Datasources y provider de dashboards | El UID es estable para el JSON |
| `monitoring/grafana/dashboards/build_dashboard.py` | Genera el dashboard | El JSON se versiona a propósito |
| `monitoring/grafana/dashboards/node-overview.json` | Dashboard generado | CI falla si no coincide con el generador |

### CI/CD

| Archivo | Responsabilidad | Notas |
|---|---|---|
| `.github/workflows/quality.yml` | Terraform fmt/validate/tflint/checkov; ansible-lint/yamllint; escaneo de claves y `.env`; `docker compose config`; drift del dashboard; validación de reglas y plantilla de Alertmanager; actionlint | No usa credenciales de GCP |
| `.github/workflows/main.yml` | Deploy en push a `main` o manual: WIF → gcloud → túnel IAP → clave SSH → Ansible | **No ejecuta Terraform**; timeout 90 min |

### Documentación y configuración

| Archivo | Responsabilidad |
|---|---|
| `README.md` | Resumen, stack, quick start y enlaces |
| `docs/README.md` | Índice y orden de lectura |
| `docs/ARQUITECTURA.md` | Diagramas, red, seguridad, memoria, backups y decisiones |
| `docs/EJECUCION.md` | Puesta en marcha desde cero (local y CI) |
| `docs/OPERACION.md` | Rutina, cambios frecuentes y troubleshooting |
| `docs/PROMPT-NUEVA-SESION.md` | Prompt de traspaso para otra sesión |
| `docs/runbooks/*` | Alertas y recuperación ante desastre |
| `.env.example` | Plantilla de variables de los stacks (con placeholders) |
| `.yamllint` | Lint YAML: 120 columnas, `key-duplicates`, ignora `.terraform/` y `*.tfvars` |

## 3. Reglas de oro sobre archivos

1. **Datos del servidor, nunca en git ni en `synchronize`:**
   - `/home/ubuntu/proxy/data/` → SQLite de NPM y certificados.
   - `/home/ubuntu/proxy/letsencrypt/`.
   - `/home/ubuntu/monitoring/` → volúmenes de Prometheus/Grafana/Alertmanager.
   - `/home/ubuntu/backups/`.
2. **Solo se sincroniza lo declarado** en `compose_stacks` (`group_vars/all/main.yml`). Añadir un archivo nuevo exige declararlo ahí.
3. **Secretos:** `.env`, `group_vars/all/local.yml`, `hosts.ini`, `.sesion/` y `terraform.tfstate*` están gitignored. No los commitees.
4. **Terraform:** no hay backend remoto. El estado vive en este equipo; no lo borres ni lo muevas sin copia.
5. **No mover Terraform/Ansible a subcarpetas** sin actualizar CI, `.gitignore`, documentación y la ruta de ejecución en la VM. La estructura plana está cableada en `quality.yml`, `main.yml` y los runbooks.

## 4. Limpieza local (ya aplicada)

La raíz del repositorio ya no contiene estado de Terraform. El estado del
proyecto eliminado (`devops-lab-orlando`) se archivó y las copias antiguas se
movieron a `.local/` (ignorado por git):

```bash
.local/state-backups/
├── deleted-project/        terraform.tfstate + .backup del proyecto eliminado
└── terraform.tfstate.*.backup
```

- **No** devuelvas el estado archivado a la raíz. El proyecto nuevo se crea desde
  cero con `terraform init` + `terraform apply`; un estado viejo intentaría
  reconciliar recursos que ya no existen.
- El `terraform.tfstate` nuevo aparecerá en la raíz en el primer `apply` del
  proyecto nuevo. Es el archivo que usa Terraform: haz copia antes de operar.
- `.terraform/` se puede borrar y regenerar con `terraform init` cuando haga
  falta (≈86 MB).
- No borres `.sesion/`: son notas de traspaso, aunque no se versionen.

## 5. Hallazgos de la revisión (2026-11-13)

Problemas detectados al revisar archivo por archivo. Todos los corregibles sin
acceso a GCP se corrigieron en esta sesión; el resto queda como pendiente
operativo.

| # | Archivo | Hallazgo | Estado |
|---|---|---|---|
| 1 | `.github/workflows/main.yml` | El paso "Stop the IAP tunnel" estaba **antes** del deploy con `if: always()`: mataba el túnel antes de que Ansible conectara. | Corregido: movido al final |
| 2 | `terraform.tfvars.example` | Declaraba `ubuntu-2404-lts` mientras la VM usa 22.04; un apply desde la plantilla forzaría reemplazo. | Corregido a `ubuntu-2204-lts` + `boot_disk_type` |
| 3 | `inventory.example.ini` | Contenía la IP pública real en un archivo versionado. | Corregido: inventario por túnel IAP |
| 4 | `.gitignore` | Decía que el estado vive en un bucket GCS, pero `main.tf` no define `backend`: el estado es local. | Corregido el comentario; backend remoto sigue pendiente |
| 5 | `monitoring/grafana/dashboards/build_dashboard.py` | Conservaba la fila y 4 paneles "Containers (cAdvisor)" aunque cAdvisor se retiró; eran paneles sin datos. | Corregido: sección eliminada y JSON regenerado (18 paneles) |
| 6 | `app/html/index.html` | Usaba `{{ ansible_date_time.date }}`, pero se copia con `copy`, no con `template`: se publicaba el placeholder literal. | Corregido: texto estático |
| 7 | `.env.example` | Declaraba `CADVISOR_VERSION`, que ya no usa ningún compose. | Corregido: variable eliminada |
| 8 | Free tier | IP externa, snapshots y flow logs estaban activos por defecto aunque no están cubiertos por Always Free. | Corregido: `false` por defecto + validaciones estrictas |
| 9 | `group_vars/all/main.yml` + docs + runbooks | Bucket, proyecto, IP e instancia reales hardcodeados. | Corregido: bucket vacío, parámetros `PROJECT`/`ZONE`/`INSTANCE`/`BUCKET` |
| 10 | `.sesion/PENDIENTES-2026-10-07.md` | La rotación de la contraseña de Grafana quedó a medias y expuesta en logs/CLI. | Pendiente: rotar cuando exista el despliegue nuevo |
| 11 | CI/CD | `main.yml` no podrá funcionar hasta configurar secrets/variables en GitHub. | Pendiente del usuario (ver `EJECUCION.md`) |
| 12 | Terraform | No hay backend remoto: sin bloqueo ni copia remota del estado. | Pendiente de decisión (coste/operación) |
| 13 | Git | Cambios de esta revisión sin commitear. | Pendiente: revisar, commitear en bloques y push |
