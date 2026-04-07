# ☁️ GCP Infrastructure & Configuration Automation

Este repositorio contiene el ciclo de vida de un entorno de laboratorio robusto en **Google Cloud Platform (GCP)**, utilizando **Infraestructura como Código (IaC)** y **Gestión de Configuración**.

## 🚀 Estado del Proyecto: Fase 2 Completada ✅

El proyecto ha evolucionado desde el aprovisionamiento básico hasta la preparación de un entorno listo para contenedores.

### 🏗️ Fase 1: Provisionamiento (Terraform)
* **VPC & Networking:** Red personalizada, subredes y reglas de firewall (SSH).
* **Compute:** Despliegue de instancia `e2-micro` (Ubuntu 22.04 LTS) en la capa gratuita.
* **Seguridad:** Gestión de llaves SSH específicas para el entorno GCP.

### 🛠️ Fase 2: Configuración (Ansible)
Se ha implementado la automatización del software sin intervención manual:
* **Actualización del Sistema:** Repositorios y parches de seguridad al día.
* **Tooling:** Instalación automática de `curl`, `git`, `unzip` y dependencias.
* **Docker Engine:** Instalación y configuración de Docker y Docker Compose para la siguiente fase.

## 📦 Estructura del Repositorio

```text
.
├── main.tf            # IaC: Definición de recursos en GCP
├── inventory.ini      # Ansible: Inventario de servidores y variables de conexión
├── setup_server.yml   # Ansible: Playbook de configuración y despliegue de Docker
├── .gitignore         # Protección de archivos sensibles (llaves y estados)
└── keys/
    └── gcp-auth.json  # Credenciales de Service Account (No trackeado)

🛠️ Requisitos para Ejecución Local:
    Terraform v1.2.x+
    Ansible 2.10.x+
    Archivo de credenciales en keys/gcp-auth.json.
    Llave privada SSH en ~/.ssh/id_rsa_gcp.

⏭️ Próximos Pasos (Roadmap)
    Fase 3: Contenedorización: Despliegue de aplicaciones propias mediante Docker Compose.
    Fase 4: CI/CD: Implementación de pipelines (GitHub Actions) para despliegue automático.
    Fase 5: Observabilidad: Monitoreo de recursos y logs del sistema.

Autor: Orlando Domínguez – System Technologist & DevOps Learner