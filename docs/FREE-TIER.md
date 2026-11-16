# Capa gratuita: qué cubre y qué no

> Revisión: 2026-11-13. Fuente oficial:
> [Google Cloud Free Tier](https://cloud.google.com/free/docs/free-cloud-features)
> y [precios de VPC](https://cloud.google.com/vpc/network-pricing#ipaddress).
> Los límites pueden cambiar; Google avisa con 30 días de antelación.

Este proyecto está diseñado para que el **perfil por defecto** cueste **0,00 USD
al mes** en Google Cloud, no solo "casi gratis". Eso obliga a distinguir entre lo
que la capa gratuita cubre de verdad y lo que no.

## 1. Lo que sí cubre Always Free

| Recurso | Límite mensual | Cómo lo usa el proyecto |
|---|---|---|
| Compute Engine | 1 VM `e2-micro` no preventible | La única VM, en `us-central1-a` |
| Regiones válidas | `us-central1`, `us-west1`, `us-east1` | Validadas en `variables.tf` |
| Disco persistente | 30 GB-meses `pd-standard` | Disco de arranque de 30 GB |
| Egress | 1 GB/mes desde Norteamérica | Tráfico normal del laboratorio |
| Cloud Storage | 5 GB-meses regionales, 5.000 Class A, 50.000 Class B, 100 GB egress | Bucket de backups en la misma región |
| Regiones GCS válidas | `us-central1`, `us-west1`, `us-east1` | `backup_bucket_location` debe coincidir con `region` |
| IAP (túneles TCP) | Sin coste | SSH, web, Grafana, Prometheus y NPM admin |
| Cloud Logging | 50 GiB/proyecto/mes | Logs del sistema, si se envían |

La cuota de `e2-micro` es **por tiempo**, no por instancia: se pueden crear varias
mientras la suma de horas no supere las horas del mes. Este proyecto usa una sola.

## 2. Lo que NO cubre (y por eso está desactivado por defecto)

| Recurso | Coste real | Decisión en el proyecto |
|---|---|---|
| **IP externa** (estática o efímera) en una VM estándar | `$0.005/hora` ≈ **$3,65/mes**; solo 1 hora gratis al mes por cuenta | `enable_public_ip = false`: la VM no tiene IP externa |
| **Snapshots de disco** | ≈ `$0.026/GB-mes`; 30 GB con 7 días ≈ **$1/mes** | `enable_snapshots = false` |
| **VPC Flow Logs** | `$0.25/GiB` (primeros 10.240 GiB) | `enable_vpc_flow_logs = false` |
| Disco `pd-balanced` o `pd-ssd` | Facturado por GB-mes | Validación: solo `pd-standard` |
| `e2-small` o superior | Facturado por hora | Validación: solo `e2-micro` |
| Egress > 1 GB/mes | `$0.12/GiB` a Norteamérica | Depende del uso; un lab normal no lo alcanza |
| IP estática reservada y **sin usar** | `$0.01/hora` ≈ **$7,30/mes** | No se reserva ninguna si `enable_public_ip = false` |
| Load balancer / Cloud NAT / Cloud CDN | Facturación por hora y por tráfico | No se usan |

> **La trampa habitual:** reservar una IP estática "para luego" y dejar la VM
> apagada. Una IP reservada sin asignar cuesta el doble que una en uso. Con
> `enable_public_ip = false` este proyecto no crea ninguna.

## 3. Los dos perfiles

### Perfil gratuito (por defecto)

```hcl
enable_public_ip     = false
enable_snapshots     = false
enable_vpc_flow_logs = false
```

- La VM solo tiene IP interna.
- No hay reglas de firewall para 80/443: únicamente `tcp:22` desde IAP.
- Todo se accede con túneles IAP, que no se facturan:

```bash
# SSH
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap --zone us-central1-a

# Web (NPM) en http://localhost:8080
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap --zone us-central1-a \
  -L 8080:localhost:80

# Grafana / Prometheus / NPM admin
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap --zone us-central1-a \
  -L 3000:localhost:3000 -L 9090:localhost:9090 -L 8081:localhost:81
```

- El backup de la base de datos a Cloud Storage sigue activo si defines
  `backup_bucket_name`; entra en los 5 GB gratuitos.
- **Coste esperado: 0,00 USD/mes** (sin contar el `$300` del Free Trial, que no
  se necesita).

### Perfil demo público (opcional, con coste)

```hcl
enable_public_ip = true
```

- Crea `google_compute_address` y la regla `allow-web` (80/443).
- Nginx Proxy Manager puede emitir certificados Let's Encrypt y el portfolio es
  accesible desde cualquier navegador.
- **Coste esperado:** ≈ `$3,65/mes` por la IP, más el egress que supere 1 GB/mes.
- Si además activas snapshots, suma ≈ `$1/mes`.

No hay forma gratuita de tener 80/443 públicos en este diseño: un balanceador
externo también se factura. Elegir el perfil público es una decisión de
producto, no un olvido.

## 4. Cómo se fuerza en el código

`variables.tf` rechaza un `terraform plan` que se salga de la capa gratuita:

- `region` ∈ `{us-central1, us-west1, us-east1}`.
- `zone` debe empezar por `<region>-`.
- `machine_type` debe ser exactamente `e2-micro`.
- `boot_disk_type` debe ser exactamente `pd-standard`.
- `disk_size_gb` entre 10 y 30.
- `backup_bucket_location` ∈ regiones gratuitas y **igual** a `region`.
- `snapshot_retention_days` entre 1 y 7.
- `ssh_source_ranges` no puede contener `0.0.0.0/0`.

`main.tf` solo crea IP externa, firewall web y snapshots cuando las variables
correspondientes están activas.

## 5. Checklist al crear el proyecto nuevo

1. Crear el proyecto y una cuenta de facturación (aunque sea el Free Trial).
   Sin billing account no se puede usar la capa gratuita.
2. `gcloud config set project <TU_PROYECTO>`.
3. Crear una **alerta de presupuesto** de 1 USD en *Billing → Budgets and
   alerts*. Es la red de seguridad ante un recurso olvidado.
4. `cp terraform.tfvars.example terraform.tfvars` y rellenar `project_id`.
5. Dejar `enable_public_ip = false` para el perfil 0,00 USD.
6. `terraform init && terraform plan` y revisar que no haya recursos de pago.
7. Desplegar Ansible (por IAP o dentro de la VM).
8. Comprobar en *Billing → Reports* que el coste es 0,00 y que todo aparece como
   "Free Tier" o "Other savings".

## 6. Qué mirar si aparece un cobro

| Señal | Causa probable | Acción |
|---|---|---|
| `External IP address` | `enable_public_ip = true` o IP reservada sin usar | Poner `false` y aplicar; comprobar `gcloud compute addresses list` |
| `Snapshot storage` | `enable_snapshots = true` | Poner `false` o reducir retención |
| `Network Telemetry` | `enable_vpc_flow_logs = true` | Poner `false` |
| `Balanced PD` | `boot_disk_type` distinto de `pd-standard` | Volver a `pd-standard` (recrea la VM) |
| `E2 Instance Core` | `machine_type` distinto de `e2-micro` | Volver a `e2-micro` |
| Egress | Más de 1 GB/mes desde Norteamérica | Revisar tráfico; comprimir respuestas |

La instancia anterior (`devops-lab-orlando`) fue eliminada; este repositorio ya
no contiene su estado ni sus identificadores. El primer `apply` en el proyecto
nuevo crea todo desde cero.
