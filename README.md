# ☁️ GCP Infrastructure Automation with Terraform

Este repositorio contiene la configuración de **Infraestructura como Código (IaC)** para desplegar un entorno de laboratorio robusto en **Google Cloud Platform (GCP)**. 

Originalmente diseñado para Oracle Cloud, este proyecto fue migrado a GCP para garantizar la disponibilidad de recursos y demostrar capacidades **Multi-Cloud** y adaptabilidad técnica.

## 🚀 Arquitectura del Proyecto

El despliegue automatiza los siguientes componentes en la región `us-central1` (aprovechando la capa **Always Free** de Google):

* **VPC (Virtual Private Cloud):** Una red aislada personalizada (`vpc-devops-lab`).
* **Subred:** Configuración de direccionamiento privado en el segmento `10.0.1.0/24`.
* **Firewall:** Reglas de seguridad perimetral para permitir tráfico **SSH (Puerto 22)**.
* **Compute Engine:** Instancia `e2-micro` con **Ubuntu 22.04 LTS**, optimizada para el nivel gratuito.

## 🛠️ Requisitos Previos

1.  **Terraform** instalado en la máquina local (macOS).
2.  **Google Cloud SDK** configurado.
3.  Una **Service Account** en GCP con el rol de `Editor`.
4.  Archivo de credenciales JSON ubicado en `keys/gcp-auth.json` (excluido del control de versiones por seguridad).

## 📦 Estructura de Archivos

```text
.
├── main.tf            # Definición principal de recursos (Red, VM, Firewall)
├── .gitignore         # Protección de archivos sensibles (llaves y estado)
└── keys/
    └── gcp-auth.json  # Credenciales de Google Cloud (No incluido en Git)
