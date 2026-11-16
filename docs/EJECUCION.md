# Ejecución paso a paso

> Guía para poner en marcha el proyecto **desde cero** en un proyecto GCP nuevo.
> Para el día a día ver [`OPERACION.md`](OPERACION.md); para límites y costes,
> [`FREE-TIER.md`](FREE-TIER.md); para entender el diseño,
> [`ARQUITECTURA.md`](ARQUITECTURA.md).
>
> La instancia y el proyecto anteriores (`devops-lab-orlando`) fueron eliminados
> de la cuenta. No hay nada que importar: el primer `terraform apply` crea todos
> los recursos desde cero.

## 0. Requisitos

En el equipo del operador:

| Herramienta | Versión | Para qué |
|---|---|---|
| `gcloud` | reciente | Autenticación, IAP, inspección |
| Terraform | ≥ 1.9 (CI usa 1.16.2) | Infraestructura |
| Python | 3.10+ | Ansible y scripts |
| `ansible-core` | ≥ 2.17, < 2.20 | Configuración |
| Colecciones | ver `requirements.yml` | `community.docker`, `ansible.posix`, `community.general` |
| Clave SSH | ED25519 | Bootstrap de la VM (`~/.ssh/id_deploy_gcp`) |

```bash
gcloud auth login
gcloud auth application-default login     # Terraform usa ADC
gcloud config set project <TU_PROYECTO>

ansible-galaxy collection install -r requirements.yml
```

> **No hay backend remoto de Terraform.** El estado vive en
> `terraform.tfstate` en este equipo. Haz copia antes de operar y no lo borres.
> El estado de la instancia eliminada se archivó en
> `.local/state-backups/deleted-project/`; no lo copies de vuelta.

## 1. Crear el proyecto y proteger el presupuesto

1. Crea el proyecto en la consola y vincúlalo a una cuenta de facturación. Sin
   billing account no se puede usar la capa gratuita.
2. Crea una **alerta de presupuesto** de 1 USD en *Billing → Budgets and
   alerts*. Es la red de seguridad si un recurso de pago queda activo.
3. Anota el **project ID** (no el nombre visible): es único y va en
   `terraform.tfvars`.

Comprueba que no hay recursos de una etapa anterior:

```bash
gcloud compute instances list --project <TU_PROYECTO>
gcloud compute addresses list --project <TU_PROYECTO>
gcloud storage buckets list --project <TU_PROYECTO>
```

Todo debe estar vacío. Si no lo está, investiga antes de aplicar: una IP
reservada sin usar cuesta `$0.01/hora`.

## 2. Preparar configuración local

```bash
git clone <repo> && cd GCP-infrastructure-automation

cp terraform.tfvars.example terraform.tfvars
cp .env.example .env                # solo para validar compose en local
```

Edita `terraform.tfvars`:

```hcl
project_id = "<TU_PROYECTO>"
region     = "us-central1"          # o us-west1 / us-east1
zone       = "us-central1-a"

enable_public_ip     = false        # perfil 0,00 USD
enable_snapshots     = false        # snapshots no son free tier
enable_vpc_flow_logs = false        # flow logs se facturan por GiB

backup_bucket_name = ""             # o "<proyecto>-backups-<sufijo>"
```

**No commitees** `terraform.tfvars` ni `.env` (ya están en `.gitignore`).

Comprueba la clave pública que se inyectará en la VM:

```bash
ls -l ~/.ssh/id_deploy_gcp.pub
# Si no existe:
ssh-keygen -t ed25519 -f ~/.ssh/id_deploy_gcp -C "gcp-deploy"
```

### Perfil público opcional

Si quieres que el portfolio sea accesible desde Internet:

```hcl
enable_public_ip = true
```

Esto crea una IP estática y abre 80/443. Coste ≈ `$3,65/mes` por la IP, más el
egress que supere 1 GB/mes. Nginx Proxy Manager podrá emitir certificados
Let's Encrypt. Si no lo necesitas, déjalo en `false`.

### Ventana de egress (obligatoria para desplegar)

Una VM sin IP externa tampoco tiene **salida** a Internet. Y sin salida no hay
`apt update`, ni `docker pull`, ni `gsutil`: el despliegue falla. Cloud NAT
resolvería el problema, pero se factura por hora y por GB (ver
[`FREE-TIER.md`](FREE-TIER.md#2-lo-que-no-cubre-y-por-eso-está-desactivado-por-defecto)).

`enable_egress` resuelve esto sin abrir ningún puerto entrante:

```bash
# Antes de Ansible: IP efímera solo de salida
terraform apply -var='enable_egress=true'

# ... primer despliegue o subida de versiones ...

# Al terminar: se libera la IP y el coste vuelve a 0
terraform apply -var='enable_egress=false'
```

- No crea reglas de firewall: SSH sigue siendo solo por IAP y 80/443 siguen
  cerrados. Se diferencia de `enable_public_ip`, que sí expone la web.
- Always Free incluye **1 hora/mes** de IP externa por cuenta. Una ventana
  normal cuesta entre `0,00` y `0,02 USD`; dejarla abierta 24/7 cuesta
  ≈ `$3,65/mes`.
- Con el túnel IAP abierto la ventana no es necesaria para *entrar*; solo para
  que la VM *salga*.
- En un despliegue ya configurado, `docker compose` usa `pull: missing` y no
  descarga nada si las imágenes ya están. Aun así `tasks/docker.yml` hace
  `apt-get update`: sin ventana, ese paso falla.

> Si el despliegue se lanza desde GitHub Actions, la ventana tiene que estar
> abierta en el momento del push: la service account del pipeline solo tiene
> permiso de túnel IAP y de lectura, no de modificar la instancia.

## 3. Terraform (solo infraestructura)

> ⚠️ **Regla de oro:** nunca ejecutes un `terraform apply` completo sin leer el
> plan. Un cambio en `image`, `boot_disk_type` o la IP puede reemplazar la
> instancia y destruir el disco. En un proyecto nuevo el plan debe ser todo
> "create", nunca "replace".

```bash
terraform init
terraform fmt -check -recursive
terraform validate

terraform plan -out=tfplan
terraform show tfplan | less       # revisar: create/destroy/replace
```

Solo si el plan es el esperado:

```bash
terraform apply tfplan
```

Salidas útiles:

```bash
terraform output deployment_profile        # free-tier | public-ip
terraform output internal_ip
terraform output -raw public_ip            # null en el perfil gratuito
terraform output -raw ssh_command
terraform output -raw web_tunnel_command
terraform output -raw grafana_tunnel_command
terraform output -raw backup_bucket_name
```

> En el perfil gratuito `public_ip` es `null` y `public_open_ports` es `[]`.
> Eso es correcto: no hay nada expuesto a Internet.

## 4. Elegir cómo ejecutar Ansible

Hay dos modos. **No mezclarlos**: `hosts.ini` (local) y el inventario por túnel
apuntan a sitios distintos.

> **Una VM nueva no trae el repositorio.** Terraform crea la instancia, la red y
> la clave SSH, pero no clona el código ni instala Ansible dentro. Por eso el
> **primer despliegue se lanza desde tu equipo** (Modo A). El Modo B solo sirve
> después de copiar el repositorio a la VM a mano.

### Modo A — desde tu equipo por túnel IAP (primer despliegue, recomendado)

Es el mismo patrón que usa GitHub Actions. SSH no está abierto en ninguna IP y
funciona igual con o sin `enable_public_ip`.

Primero crea el archivo de secretos (§5):

```bash
cat > secrets.yml <<'YAML'
grafana_admin_password: "cambia-esto-por-una-contrasena-larga"
# alertmanager_webhook_url: "https://hooks.example.invalid/services/..."
# backup_bucket: "<proyecto>-backups-<sufijo>"   # opcional, activa off-site
YAML
chmod 600 secrets.yml        # secrets.yml está en .gitignore
```

Después:

```bash
# 1. Levantar el túnel en segundo plano
gcloud compute start-iap-tunnel instancia-devops-gcp 22 \
  --local-host-port=localhost:2222 \
  --project=<TU_PROYECTO> --zone=us-central1-a &

# 2. Registrar la clave del host a través del túnel
ssh-keyscan -H -p 2222 127.0.0.1 >> ~/.ssh/known_hosts

# 3. Inventario local (no uses hosts.ini: ese es para la VM)
cat > /tmp/inventory.ini <<'INI'
[gcp_servers]
gcp-server ansible_host=127.0.0.1 ansible_port=2222 ansible_user=ubuntu
INI

# 4. Ejecutar
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml \
  -i /tmp/inventory.ini \
  --private-key ~/.ssh/id_deploy_gcp \
  -e ansible_python_interpreter=/usr/bin/python3 \
  -e @secrets.yml
```

Cuando termines, mata el proceso del túnel (`kill %1` o `pkill -f start-iap-tunnel`).

### Modo B — dentro de la VM (solo si el repositorio ya está allí)

Útil para operar después, pero **no funciona en una VM recién creada**: hay que
copiar el repositorio primero. `hosts.ini` usa `ansible_connection=local`, así
que Ansible se ejecuta contra sí mismo.

```bash
# 1. Entrar por IAP (funciona aunque la VM no tenga IP pública)
gcloud compute ssh instancia-devops-gcp \
  --project <TU_PROYECTO> --zone us-central1-a --tunnel-through-iap

# 2. Traer el repositorio y crear el inventario local (una sola vez)
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<TU_USUARIO>/GCP-infrastructure-automation.git \
  ~/GCP-infrastructure-automation
cd ~/GCP-infrastructure-automation
printf '[gcp_servers]\nlocalhost ansible_connection=local\n\n[gcp_servers:vars]\nansible_python_interpreter=/usr/bin/python3\n' \
  > hosts.ini

# 3. Colecciones y despliegue
export ANSIBLE_COLLECTIONS_PATH=/home/ubuntu/.ansible/collections
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml -e @secrets.yml
```

> El `ANSIBLE_COLLECTIONS_PATH` no es opcional: sin él, Ansible usa las
> colecciones del sistema (`community.docker` 1.2.2) y
> `community.docker.docker_compose_v2` no existe.
>
> `secrets.yml` no está en el repositorio (está gitignored). Créalo en la VM con
> `chmod 600` o usa `group_vars/all/local.yml`.

## 5. Secretos

`grafana_admin_password` es **obligatoria** y no tiene default: si falta, el play
falla antes de tocar nada. `alertmanager_webhook_url` es opcional.

Orden de precedencia:

1. `--extra-vars` (CI o línea de comandos).
2. `group_vars/all/local.yml` en la VM (gitignored).
3. Interactivo con `-e`.

**Recomendado:** un archivo de secretos con modo 0600 y `-e @archivo`, nunca la
contraseña en la línea de comandos (queda en `ps` y en los logs de Ansible):

```bash
cat > secrets.yml <<'YAML'
grafana_admin_password: "..."          # > 12 caracteres
# alertmanager_webhook_url: "https://hooks.example.invalid/services/..."
# backup_bucket: "<proyecto>-backups-<sufijo>"   # opcional, activa off-site
YAML
chmod 600 secrets.yml
```

En la VM, el equivalente persistente es `group_vars/all/local.yml` (mismo
formato, 0600). `main.yml` **no declara** esas variables a propósito, para no
sobrescribir el merge.

## 6. Verificar el despliegue

El play termina con `verify.yml`, que ya exige 6/6 contenedores `healthy`. Para
comprobarlo a mano (dentro de la VM):

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker compose -f ~/proxy/docker-compose.yml ps
swapon --show
free -h

curl -s -o /dev/null -w '%{http_code}\n' http://localhost/        # NPM
curl -s http://localhost:3000/api/health                          # Grafana
curl -s http://localhost:9090/-/healthy                           # Prometheus
curl -s http://localhost:9093/-/ready                             # Alertmanager
```

Comprobación externa: en el **perfil gratuito no hay puertos abiertos**:

```bash
nmap -Pn -p 22,80,443,81,3000,9090,9093,21680 <IP_INTERNA>
# Desde fuera de la VPC no hay ruta a la IP interna: es lo esperado.
```

Con `enable_public_ip = true`, desde tu equipo:

```bash
nmap -Pn -p 22,80,443,81,3000,9090,9093,21680 <IP_PUBLICA>
# Esperado: 80 y 443 abiertos; el resto cerrados/filtrados.
```

Túneles para paneles y web (perfil gratuito):

```bash
gcloud compute ssh instancia-devops-gcp --tunnel-through-iap \
  --project <TU_PROYECTO> --zone us-central1-a \
  -L 8080:localhost:80 -L 3000:localhost:3000 -L 9090:localhost:9090 \
  -L 8081:localhost:81 -L 9093:localhost:9093
```

- Web / NPM: <http://localhost:8080>
- Grafana: <http://localhost:3000>
- Prometheus: <http://localhost:9090>
- NPM admin: <http://localhost:8081>
- Alertmanager: <http://localhost:9093>

## 7. Configurar CI/CD en GitHub

`quality.yml` funciona sin configuración. `main.yml` **no arranca** hasta
configurar esto en *Settings → Secrets and variables → Actions*:

### Secrets

| Nombre | Valor |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<num>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` |
| `GCP_SERVICE_ACCOUNT` | Email de la SA que abre el túnel |
| `SSH_PRIVATE_KEY` | Clave privada ED25519 de `ubuntu` (la pareja de `id_deploy_gcp.pub`) |
| `GF_SECURITY_ADMIN_PASSWORD` | Contraseña inicial de Grafana |

### Variables

| Nombre | Ejemplo |
|---|---|
| `GCP_PROJECT_ID` | `<TU_PROYECTO>` |
| `GCP_INSTANCE_NAME` | `instancia-devops-gcp` |
| `GCP_ZONE` | `us-central1-a` |
| `GCP_USER` | `ubuntu` |
| `BACKUP_BUCKET` | Nombre del bucket o vacío (opcional) |

### Requisitos en GCP para Workload Identity

- Pool + provider OIDC de GitHub configurados.
- SA de despliegue con permiso para abrir túneles IAP sobre la instancia
  (`IAP-secured Tunnel User`, p. ej. `roles/iap.tunnelResourceAccessor`) y para
  consultar la instancia (`Compute Viewer`). No necesita Editor.
- El repositorio autorizado en la condición del provider.

El workflow hace, en orden: checkout → auth WIF → gcloud → **levanta** el túnel
en `127.0.0.1:2222` → prepara la clave → `ssh-keyscan` → instala Ansible →
`syntax-check` → `ansible-playbook` → **cierra** el túnel (`if: always()`).

El túnel IAP funciona igual con o sin IP pública: no depende de `enable_public_ip`.

## 8. Tags de Ansible

```bash
ansible-playbook site.yml --list-tags
ansible-playbook site.yml --tags swap          # solo swap
ansible-playbook site.yml --tags stacks        # solo despliegue de stacks
ansible-playbook site.yml --tags verify        # solo verificación
ansible-playbook site.yml --skip-tags hardening
```

`site.yml` solo tiene una tarea `always` (el assert de RAM); `verify` está
marcado `always` para que un deploy nunca termine verde con un stack caído.

## 9. Validar sin desplegar (gates)

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate

# Reproduce the free-tier default gate from quality.yml
for var in enable_public_ip enable_snapshots enable_vpc_flow_logs; do
  echo "var.$var" | terraform console -var project_id=ci
done

ansible-lint site.yml
yamllint .

export GF_SECURITY_ADMIN_USER=ci
export GF_SECURITY_ADMIN_PASSWORD=ci-only-not-a-real-secret
for s in app proxy monitoring; do
  docker compose -f "$s/docker-compose.yml" config --quiet
done

python3 monitoring/grafana/dashboards/build_dashboard.py
git diff --exit-code -- monitoring/grafana/dashboards/node-overview.json
```

Esto reproduce lo que corre `quality.yml`.

## 10. Troubleshooting de arranque

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Conflicting values set for option Signed-By` | Quedó un `.list` legacy de Docker | `tasks/docker.yml` lo limpia; si es manual: `rm /etc/apt/sources.list.d/*docker*.list` |
| `module docker_compose_v2 not found` | Faltó `ANSIBLE_COLLECTIONS_PATH` en la VM | Exportar y reinstalar colecciones |
| `Permission denied (publickey)` | Clave distinta o túnel caído | Revisar `--private-key`, que el túnel :2222 escuche y `ssh-keyscan` |
| Grafana `unhealthy` durante 20 min | Arranque lento normal en e2-micro | Esperar; **no** reiniciar en bucle |
| Contenedor pasa a `unhealthy` y vuelve | Carga alta durante el deploy | `verify.yml` espera 300 s; no bajar el margen |
| Cambio de config no se aplica | Bind mount con inode viejo | El fingerprint de `stacks.yml` recrea consumidores; o `--force-recreate` manual |
| `terraform plan` propone reemplazar la VM | `image`, disco o IP distintos | **No aplicar**; alinear la variable con la realidad |
| `public_ip` es `null` | Perfil gratuito (`enable_public_ip = false`) | Correcto; usar `web_tunnel_command` |
| Alertmanager `permission denied` en su config | Dueño/modo incorrecto | Debe ser `65534:65534`, modo 0600 |
| El deploy de CI falla al conectar | Túnel cerrado antes de tiempo | Ya corregido: el stop está al final del workflow |

Más casos en [`OPERACION.md`](OPERACION.md) y en los runbooks.
