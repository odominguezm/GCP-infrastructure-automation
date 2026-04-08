# 🚀 GCP Infrastructure Automation & CI/CD Pipeline

Este proyecto es un portafolio de automatización que demuestra el despliegue de una infraestructura completa en Google Cloud Platform (GCP) utilizando prácticas de **IaC (Infrastructure as Code)** y **CI/CD**.

## 🛠️ Tecnologías Utilizadas
* **Cloud:** Google Cloud Platform (GCP)
* **IaC:** Terraform
* **Config Management:** Ansible
* **Contenedores:** Docker & Docker Compose
* **CI/CD:** GitHub Actions
* **OS:** Ubuntu Server

## 🏗️ Arquitectura del Proyecto
El flujo de trabajo automatizado sigue estas etapas:
1. **Provisionamiento:** Terraform crea la instancia de cómputo y las reglas de Firewall en GCP.
2. **Configuración:** Ansible instala Docker, Docker Compose y prepara el entorno.
3. **Despliegue:** Docker Compose levanta un servidor web Nginx personalizado.
4. **Automatización:** Cada `git push` a la rama `main` dispara un pipeline de GitHub Actions que actualiza el servidor en tiempo real.

## 📈 Progreso del Proyecto

| Fase | Descripción | Estado |
| :--- | :--- | :--- |
| **Fase 1** | Provisionamiento de Infraestructura con Terraform | ✅ Completada |
| **Fase 2** | Gestión de Configuración con Ansible | ✅ Completada |
| **Fase 3** | Contenedorización con Docker & Docker Compose | ✅ Completada |
| **Fase 4** | Pipeline de CI/CD con GitHub Actions | ✅ Completada |
| **Fase 5** | Observabilidad y Monitoreo (Métricas) | 🕒 En Progreso |

## 🚀 Cómo funciona el CI/CD
El pipeline de **GitHub Actions** utiliza secretos cifrados (`GCP_IP`, `GCP_USER`, `SSH_PRIVATE_KEY`) para garantizar la seguridad. Al detectar un cambio en el código:
1. Inicia un Runner de Ubuntu.
2. Configura la autenticación SSH.
3. Ejecuta el Playbook de Ansible para sincronizar archivos y refrescar los contenedores con `--force-recreate`.

---
*Desarrollado por **Orlando Dominguez** - Systems Technologist*