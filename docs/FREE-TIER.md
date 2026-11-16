# Capa gratuita: qué cubre y qué no

> Revisión: 2026-11-16. Fuente oficial:
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

## 2. Lo que NO cubre (y por eso está retirado del proyecto)

| Recurso | Coste real | Decisión |
|---|---|---|
| **IP externa** (estática o efímera) en una VM estándar | `$0.005/hora` ≈ **$3,65/mes**; solo 1 hora gratis al mes por cuenta | Solo existe en la ventana de egress temporal |
| **Snapshots de disco** | ≈ `$0.026/GB-mes`; 30 GB con 7 días ≈ **$1/mes** | Retirados: la recuperación es Terraform + Ansible |
| **VPC Flow Logs** | `$0.25/GiB` (primeros 10.240 GiB) | Retirados: no hay regla de auditoría que justifique el coste |
| Disco `pd-balanced` o `pd-ssd` | Facturado por GB-mes | Validación: solo `pd-standard` |
| `e2-small` o superior | Facturado por hora | Validación: solo `e2-micro` |
| IP estática reservada y **sin usar** | `$0.01/hora` ≈ **$7,30/mes** | No se reserva ninguna dirección estática |
| Egress > 1 GB/mes | `$0.12/GiB` a Norteamérica | Depende del uso; un lab normal no lo alcanza |
| Load balancer / Cloud NAT / Cloud CDN | Facturación por hora y por tráfico | No se usan |

> **La trampa habitual:** reservar una IP estática "para luego" y dejar la VM
> apagada. Una IP reservada sin asignar cuesta el doble que una en uso. Este
> proyecto no reserva ninguna.

## 3. Los dos estados del proyecto

No hay perfiles de pago que activar. Hay un perfil gratuito y una ventana
temporal que se abre y se cierra con el Makefile.

### Perfil gratuito (por defecto)

```hcl
enable_egress = false
```

- La VM solo tiene IP interna y no hay reglas de firewall para 80/443:
  únicamente `tcp:22` desde IAP.
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

### Ventana de egress (obligatoria para desplegar)

Una VM sin IP externa tampoco tiene **salida** a Internet. Sin salida no hay
`apt update`, ni `docker pull`, ni `gsutil`: el despliegue falla. Cloud NAT lo
resolvería, pero se factura por hora y por GB.

```bash
make egress-on     # terraform apply -var='enable_egress=true'
make deploy        # apt, docker pull, Ansible, verificación
make egress-off    # terraform apply -var='enable_egress=false'
```

- Adjunta una **IP efímera** (`nat_ip = null`): no reserva dirección, no crea
  reglas de firewall y no abre ningún puerto entrante.
- Always Free incluye **1 hora/mes** por cuenta. Una ventana normal cuesta entre
  `0,00` y `0,02 USD`; dejarla abierta 24/7 cuesta ≈ `$3,65/mes`.
- Con el túnel IAP abierto la ventana no es necesaria para *entrar*; solo para
  que la VM *salga*.
- `docker compose` usa `pull: missing`, así que un redeploy no descarga nada si
  las imágenes ya están. Aun así `tasks/docker.yml` hace `apt-get update`: sin
  ventana, ese paso falla.
- Si el despliegue se lanza desde GitHub Actions, la ventana tiene que estar
  abierta en el momento del push: la service account del pipeline solo tiene
  permiso de túnel IAP y lectura, no de modificar la instancia.

## 4. Cómo se fuerza en el código

`variables.tf` rechaza un `terraform plan` que se salga de la capa gratuita:

- `region` ∈ `{us-central1, us-west1, us-east1}`.
- `zone` debe empezar por `<region>-`.
- `machine_type` debe ser exactamente `e2-micro`.
- `boot_disk_type` debe ser exactamente `pd-standard`.
- `disk_size_gb` entre 10 y 30.
- `backup_bucket_location` ∈ regiones gratuitas y **igual** a `region`.
- `ssh_source_ranges` no puede contener `0.0.0.0/0`.

`main.tf` solo adjunta `access_config` cuando `enable_egress = true`. No existe
ningún recurso de IP estática, snapshot, flow log ni firewall web.

El gate `Assert the default profile stays in the free tier` de
`.github/workflows/quality.yml` evalúa los defaults con `terraform console` y
falla si alguno se mueve fuera del free tier.

## 5. Checklist al crear el proyecto nuevo

1. Crear el proyecto y una cuenta de facturación (aunque sea el Free Trial).
   Sin billing account no se puede usar la capa gratuita.
2. `gcloud config set project <TU_PROYECTO>`.
3. Crear una **alerta de presupuesto** de 1 USD en *Billing → Budgets and
   alerts*. Es la red de seguridad ante un recurso olvidado.
4. `cp terraform.tfvars.example terraform.tfvars` y rellenar `project_id`.
5. Dejar `enable_egress = false` fuera de las ventanas de despliegue.
6. `make plan` y revisar que no haya recursos de pago antes de `make apply`.
7. Desplegar con `make egress-on && make deploy && make egress-off`.
8. Comprobar en *Billing → Reports* que el coste es 0,00 y que todo aparece como
   "Free Tier" o "Other savings".

## 6. Qué mirar si aparece un cobro

| Señal | Causa probable | Acción |
|---|---|---|
| `External IP address` | `enable_egress = true` olvidado, o una IP reservada de una etapa anterior | `make egress-off`; comprobar `gcloud compute addresses list` |
| `Snapshot storage` | Snapshots creados a mano | `gcloud compute snapshots list` y borrar los que no se usen |
| `Network Telemetry` | VPC Flow Logs activados fuera del código | Revisar la subred en la consola |
| `Balanced PD` | `boot_disk_type` distinto de `pd-standard` | Volver a `pd-standard` (recrea la VM) |
| `E2 Instance Core` | `machine_type` distinto de `e2-micro` | Volver a `e2-micro` |
| Egress | Más de 1 GB/mes desde Norteamérica | Revisar tráfico; comprimir respuestas |

La instancia anterior (`devops-lab-orlando`) fue eliminada; este repositorio ya
no contiene su estado ni sus identificadores. El primer `apply` en el proyecto
nuevo crea todo desde cero.
