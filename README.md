# 🚀 GCP Infrastructure Automation & CI/CD Pipeline

Este proyecto es un portafolio de automatización de alto nivel que demuestra el despliegue de una infraestructura profesional en Google Cloud Platform (GCP) utilizando prácticas de **IaC (Infrastructure as Code)**, **CaC (Configuration as Code)** y **GitOps**.

## 🛠️ Tecnologías Utilizadas

* **Cloud:** Google Cloud Platform (GCP)
* **IaC:** Terraform
* **Config Management:** Ansible
* **Contenedores:** Docker & Docker Compose
* **CI/CD:** GitHub Actions
* **OS:** Ubuntu Server (Remote) / Linux Workstation (Local)

## 🏗️ Arquitectura del Proyecto

El flujo de trabajo automatizado sigue estas etapas:
1.  **Provisionamiento:** Terraform gestiona de forma declarativa la VPC, subredes, instancias y reglas de firewall.
2.  **Configuración:** Ansible aplica playbooks para el hardening del sistema y la preparación del runtime de Docker.
3.  **Despliegue:** Orquestación de servicios mediante Docker Compose con una estrategia de actualización sin tiempo de inactividad.
4.  **Automatización:** Pipeline de CI/CD que garantiza que cada cambio en el código se refleje de forma segura en producción.

## 📈 Hoja de Ruta del Proyecto (Roadmap)

| Fase | Descripción | Estado |
| :--- | :--- | :--- |
| **Fase 1** | Provisionamiento de Infraestructura con Terraform | ✅ Completada |
| **Fase 2** | Gestión de Configuración con Ansible | ✅ Completada |
| **Fase 3** | Contenedorización con Docker & Docker Compose | ✅ Completada |
| **Fase 4** | Integración de Workstation y Pipeline CI/CD | ✅ Completada |
| **Fase 5** | Observabilidad y Monitoreo (Métricas en tiempo real) | 🕒 En Progreso |
| **Fase 6** | Seguridad Avanzada: Dominio, SSL/TLS y HTTPS | 📅 Pendiente |
| **Fase 7** | Continuidad de Negocio: Backup & Disaster Recovery | 📅 Pendiente |

## 🚀 Detalles del Pipeline CI/CD

El flujo utiliza secretos cifrados para proteger la integridad de la infraestructura. Al detectar un cambio:
1. Valida los archivos de configuración.
2. Establece un túnel seguro vía SSH con llaves RSA.
3. Ejecuta tareas de Ansible para sincronizar el estado deseado.
4. Realiza un despliegue "Blue/Green" simplificado mediante el refresco de contenedores.

---
**Desarrollado por Orlando Dominguez - Systems Technologist**