# GCP Infrastructure Automation & Observability Stack

Este repositorio contiene la arquitectura completa de una infraestructura escalable en **Google Cloud Platform**, desplegada mediante **IaC (Terraform)**, configurada con **Ansible** y gestionada a través de un pipeline de **CI/CD con GitHub Actions**.

El proyecto demuestra habilidades avanzadas en automatización de infraestructura, seguridad (SSL/TLS), observabilidad y gestión de contenedores.

## 🚀 Arquitectura del Proyecto

El ecosistema está diseñado bajo el principio de "Everything as Code" y se divide en las siguientes capas:

* **Infraestructura (IaC):** Google Cloud Platform (VPC, Compute Engine, Firewall Rules) gestionado con **Terraform**.
* **Configuración (CaC):** Automatización del sistema operativo y despliegue de servicios con **Ansible**.
* **Orquestación:** Contenedores gestionados con **Docker & Docker Compose**.
* **CI/CD:** Pipeline automatizado en **GitHub Actions** para despliegues continuos.
* **Observabilidad:** Stack de monitoreo con **Prometheus, Grafana y Node Exporter**.
* **Networking & Seguridad:** Reverse Proxy con **Nginx Proxy Manager** y certificados **SSL/TLS (Let's Encrypt)**.

## 🛠️ Stack Tecnológico

| Herramienta | Función |
| :--- | :--- |
| **GCP** | Proveedor de nube pública. |
| **Terraform** | Aprovisionamiento de infraestructura. |
| **Ansible** | Gestión de configuración y despliegue de apps. |
| **Docker** | Contenedorización de microservicios. |
| **GitHub Actions** | Automatización de despliegue (Pipeline). |
| **NPM** | Gestión de dominios y terminación SSL. |
| **Stack TIG** | Monitoreo y métricas en tiempo real. |

## 📦 Estructura del Repositorio

```bash
├── .github/workflows/   # Definición del pipeline de CI/CD
├── app/                 # Código y Docker Compose de la aplicación web
├── monitoring/          # Configuración de Prometheus y Grafana
├── proxy/               # Nginx Proxy Manager setup
├── main.tf              # Definición de infraestructura en Terraform
├── deploy_all.yml       # Playbook maestro de Ansible
├── ansible.cfg          # Configuración de comportamiento de Ansible
└── README.md            # Documentación del proyecto
⚙️ Configuración del Pipeline
El pipeline está configurado para ejecutarse en cada push a la rama main, realizando las siguientes acciones:

Checkout del código.

Configuración de identidad SSH (RSA con algoritmos de intercambio de llaves específicos).

Despliegue automático mediante Ansible hacia la instancia de GCP.

📊 Acceso al Entorno
Actualmente, el proyecto es accesible de forma segura bajo el dominio:
🔗 https://devops.dommatt.com

📈 Roadmap del Proyecto
[x] Fase 1: Provisionamiento (Terraform)

[x] Fase 2: Configuración (Ansible)

[x] Fase 3: Contenedorización (Docker)

[x] Fase 4: Pipeline CI/CD (GitHub Actions)

[x] Fase 5: Observabilidad (Prometheus/Grafana)

[x] Fase 6: Seguridad (SSL/Dominio)

[ ] Fase 7: Continuidad de Negocio (Backups & Disaster Recovery) - EN PROGRESO

Autor: Orlando Domínguez – Systems Technologist