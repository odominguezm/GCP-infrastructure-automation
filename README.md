# 🚀 GCP Infrastructure Automation & CI/CD Pipeline

Este proyecto es un portafolio de automatización que demuestra el despliegue de una infraestructura completa en Google Cloud Platform (GCP) utilizando prácticas de **IaC (Infrastructure as Code)** y **CI/CD**.

## 🛠️ Tecnologías Utilizadas

* **Cloud:** Google Cloud Platform (GCP)
* **IaC:** Terraform
* **Config Management:** Ansible
* **Contenedores:** Docker & Docker Compose
* **CI/CD:** GitHub Actions / GitLab
* **OS:** Ubuntu Server (Remote) / Linux Workstation (Local)

## 🏗️ Arquitectura del Proyecto

El flujo de trabajo automatizado sigue estas etapas:
1.  **Provisionamiento:** Terraform crea la VPC, subredes, instancias de cómputo y reglas de Firewall en GCP.
2.  **Configuración:** Ansible gestiona el hardening del servidor, instala Docker, Docker Compose y prepara el entorno de ejecución.
3.  **Despliegue:** Docker Compose levanta un servidor web Nginx personalizado con despliegue de artefactos dinámicos.
4.  **Automatización:** Cada `git push` a la rama `main` dispara un pipeline que sincroniza el estado de la infraestructura y actualiza el servicio en tiempo real.

## 📈 Progreso del Proyecto

| Fase | Descripción | Estado |
| :--- | :--- | :--- |
| **Fase 1** | Provisionamiento de Infraestructura con Terraform | ✅ Completada |
| **Fase 2** | Gestión de Configuración con Ansible | ✅ Completada |
| **Fase 3** | Contenedorización con Docker & Docker Compose | ✅ Completada |
| **Fase 4** | Pipeline de CI/CD e Integración de Workstation | ✅ Completada |
| **Fase 5** | Observabilidad, Monitoreo y Métricas | 🕒 En Progreso |

## 🚀 Cómo funciona el CI/CD

El pipeline utiliza secretos cifrados para garantizar la seguridad en cada despliegue. Al detectar un cambio en el código:
1. Se valida la integridad de los manifiestos de Terraform.
2. Se establece una conexión segura mediante SSH.
3. Se ejecuta el Playbook de Ansible para sincronizar los archivos de la aplicación.
4. Se refrescan los contenedores garantizando la disponibilidad del servicio.

---
**Desarrollado por Orlando Dominguez - Systems Technologist**