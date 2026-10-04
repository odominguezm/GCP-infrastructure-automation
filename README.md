# 🚀 GCP DevOps Infrastructure Automation
Este proyecto implementa una infraestructura automatizada en Google Cloud Platform (GCP) bajo el paradigma de Infrastructure as Code (IaC) y CI/CD, optimizada para ejecutarse en entornos de bajos recursos (Always Free Tier).

# 🛠️ Stack Tecnológico
Nube: Google Cloud Platform (Instancia e2-micro).

SO: Ubuntu 24.04 LTS (Optimizado con 2GB SWAP).

Automatización: Ansible & GitHub Actions.

Contenedorización: Docker & Docker Compose.

Proxy & Seguridad: Nginx Proxy Manager (NPM).

Observabilidad: Prometheus & Grafana.

# 📈 Roadmap del Proyecto
[x] Fase 1: Provisionamiento de instancia y red en GCP.

[x] Fase 2: Gestión de configuración base con Ansible.

[x] Fase 3: Contenedorización de servicios (Docker Stack).

[x] Fase 4: Pipeline CI/CD con GitHub Actions (Deploy Key ED25519).

[x] Fase 5: Observabilidad (Dashboard de métricas en tiempo real).

[x] Fase 6: Proxy Inverso y gestión de dominios.

[x] Fase 7: Continuidad de Negocio (Backups automatizados & DRP).

# 🚀 Pipeline CI/CD (GitHub Actions)

El deploy se ejecuta sobre el **túnel IAP**, no contra la IP pública: la
instancia solo abre `tcp:22` para el rango de Identity-Aware Proxy
(`35.235.240.0/20`). El pipeline se autentica en GCP con Workload Identity
Federation (sin llaves JSON en el repositorio) y levanta el túnel antes de
invocar Ansible.

Configuración requerida en el repositorio:

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<num>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` |
| Secret | `GCP_SERVICE_ACCOUNT` | Correo de la SA que la PI ejecuta |
| Secret | `SSH_PRIVATE_KEY` | Llave privada ED25519 de acceso a la instancia |
| Secret | `GF_SECURITY_ADMIN_PASSWORD` | Password inicial de Grafana |
| Variable | `GCP_PROJECT_ID` | `devops-lab-orlando` |
| Variable | `GCP_INSTANCE_NAME` | `instancia-devops-gcp` |
| Variable | `GCP_ZONE` | `us-central1-a` |
| Variable | `GCP_USER` | `ubuntu` |
| Variable | `BACKUP_BUCKET` | Bucket de backups off-site |

Notas operativas: el timeout es de 90 minutos porque Grafana tarda 18-27 min en
arrancar en una e2-micro, y `BACKUP_BUCKET` es lo que activa la copia off-site:
sin esa variable el backup local sigue funcionando, pero no hay DRP.

# 🛡️ Continuidad de Negocio & Disaster Recovery (DRP)
Estrategia de Backup
Se implementó un script de respaldo automatizado (backup_npm.sh) que realiza copias diarias de la base de datos de Nginx Proxy Manager (SQLite) hacia un directorio de persistencia, manteniendo una retención de 7 días para optimizar el almacenamiento.

Procedimiento de Restauración
En caso de pérdida total de la instancia:

Redespliegue: Ejecutar el pipeline de GitHub Actions para levantar la infraestructura base.

Inyección de Datos:

Bash
# Detener servicios
docker compose down
# Restaurar base de datos
cp ~/backups/npm_db_fecha.sqlite ~/proxy/data/database.sqlite
# Reiniciar servicios
docker compose up -d
# ⚙️ Optimización de Recursos
Para operar en una instancia e2-micro (1GB RAM), se configuró:

SWAP de 2GB: Mitigación de errores Out of Memory (OOM).

Swappiness (10): Optimización del uso de RAM física antes de recurrir al disco.

Sincronización Blindada: Ansible configurado para actualizar definiciones sin sobrescribir datos persistentes.

👨‍💻 Autor
Orlando Dominguez M.
