🚀 GCP DevOps Infrastructure Automation
Este proyecto implementa una infraestructura automatizada en Google Cloud Platform (GCP) bajo el paradigma de Infrastructure as Code (IaC) y CI/CD, optimizada para ejecutarse en entornos de bajos recursos (Always Free Tier).

🛠️ Stack Tecnológico
Nube: Google Cloud Platform (Instancia e2-micro).

SO: Ubuntu 24.04 LTS (Optimizado con 2GB SWAP).

Automatización: Ansible & GitHub Actions.

Contenedorización: Docker & Docker Compose.

Proxy & Seguridad: Nginx Proxy Manager (NPM).

Observabilidad: Prometheus & Grafana.

📈 Roadmap del Proyecto
[x] Fase 1: Provisionamiento de instancia y red en GCP.

[x] Fase 2: Gestión de configuración base con Ansible.

[x] Fase 3: Contenedorización de servicios (Docker Stack).

[x] Fase 4: Pipeline CI/CD con GitHub Actions (Deploy Key ED25519).

[x] Fase 5: Observabilidad (Dashboard de métricas en tiempo real).

[x] Fase 6: Proxy Inverso y gestión de dominios.

[x] Fase 7: Continuidad de Negocio (Backups automatizados & DRP).

🛡️ Continuidad de Negocio & Disaster Recovery (DRP)
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
⚙️ Optimización de Recursos
Para operar en una instancia e2-micro (1GB RAM), se configuró:

SWAP de 2GB: Mitigación de errores Out of Memory (OOM).

Swappiness (10): Optimización del uso de RAM física antes de recurrir al disco.

Sincronización Blindada: Ansible configurado para actualizar definiciones sin sobrescribir datos persistentes.

👨‍💻 Autor
Orlando Dominguez M.
