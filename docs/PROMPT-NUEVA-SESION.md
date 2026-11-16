# Prompt para una sesión nueva

Copia **todo el bloque de la sección 2** en una sesión nueva. La sección 1 es el
contexto por si necesitas ajustarlo antes; la 3 es el estado verificado a fecha
de hoy.

## 1. Cómo usarlo

1. Abre una sesión en el directorio del proyecto.
2. Pega el bloque completo.
3. Si cambió algo desde el 2026-11-13, actualiza primero el estado de git y la
   lista de pendientes.

## 2. Prompt listo para copiar

```text
Trabaja en /home/odominguezm/Developer/GitHub-Portafolio/GCP-infrastructure-automation,
rama main. Es un laboratorio DevOps en GCP con Terraform (infraestructura) +
Ansible (configuración de la VM) + stacks Docker (Nginx Proxy Manager, demo,
Prometheus, Grafana, Alertmanager). Responde en español.

ANTES DE TOCAR NADA, lee en este orden:
1. docs/FREE-TIER.md       -> qué cubre Always Free, qué se factura y perfiles
2. docs/ESTRUCTURA.md      -> qué es cada archivo y hallazgos de la revisión
3. docs/ARQUITECTURA.md    -> componentes, red, seguridad, backups, decisiones
4. docs/EJECUCION.md       -> cómo se despliega (dos modos de Ansible)
5. docs/OPERACION.md       -> rutina, cambios, troubleshooting
6. docs/runbooks/alerting.md y docs/runbooks/disaster-recovery.md

ESTADO REAL (IMPORTANTE)
- El proyecto anterior devops-lab-orlando y su bucket fueron ELIMINADOS.
  No hay infraestructura viva ni nada que importar.
- El repositorio está preparado para un proyecto NUEVO: terraform.tfvars tiene
  project_id = "tu-proyecto-nuevo" como placeholder.
- El estado antiguo está archivado en .local/state-backups/deleted-project/.
  NO devolverlo a la raíz ni reutilizarlo.
- Perfil por defecto: Always Free estricto.
    enable_public_ip     = false   (sin IP externa; IP ≈ $3,65/mes)
    enable_snapshots     = false   (no free tier; ≈ $1/mes)
    enable_vpc_flow_logs = false   (se factura por GiB)
  Todo se accede por túneles IAP, que son gratuitos. Coste esperado: 0,00 USD.
- Perfil público opcional: enable_public_ip = true (80/443 + IP estática).

INFRAESTRUCTURA ESPERADA (proyecto nuevo)
- Región us-central1 (o us-west1 / us-east1), zona us-central1-a.
- VM: instancia-devops-gcp (e2-micro, Ubuntu 22.04, disco pd-standard 30 GB).
- Sin IP pública por defecto. SSH SOLO por IAP:
  gcloud compute ssh instancia-devops-gcp --tunnel-through-iap \
    --project <TU_PROYECTO> --zone us-central1-a
- Bucket de backups: opcional (backup_bucket_name; vacío = solo copia local).
  Si existe, en la misma región gratuita; SA devops-backup solo objectCreator.
- Puertos públicos: ninguno por defecto. Con enable_public_ip = true: 80/443.
  22 solo IAP. 81/3000/9090/9093/21680 en loopback.

CÓMO EJECUTAR ANSIBLE
- Primer despliegue (VM nueva, sin repo dentro): desde tu equipo por túnel IAP,
  igual que main.yml. Inventario con 127.0.0.1:2222 y --private-key.
  Ver docs/EJECUCION.md §4.
- Después, dentro de la VM también es posible (hosts.ini con
  ansible_connection=local), pero solo si antes clonaste el repositorio allí:
    export ANSIBLE_COLLECTIONS_PATH=/home/ubuntu/.ansible/collections
    ansible-playbook site.yml
  Sin esa variable usa colecciones del sistema (community.docker 1.2.2) y
  docker_compose_v2 no existe.
- Secretos con -e @secrets.yml (0600) o group_vars/all/local.yml; NUNCA inline.

ESTADO DE GIT (verificar al empezar)
- main tiene 66380b9 por delante de origin/main, SIN push.
- Hay cambios de la revisión de free tier sin commitear (Terraform, docs,
  group_vars, dashboard, workflows).
- No commitear ni pushear sin pedirlo. Si se pide, separar en bloques.

PENDIENTES, EN ORDEN DE PRIORIDAD
1. Crear el proyecto nuevo, cuenta de facturación y alerta de presupuesto de 1 USD.
   Rellenar project_id en terraform.tfvars. Ver docs/EJECUCION.md.
2. terraform init/plan/apply y comprobar que el plan es todo "create" y que no
   hay recursos de pago. Desplegar Ansible y verificar 6/6 healthy.
3. Rotar la contraseña de Grafana del despliegue anterior (quedó expuesta en
   logs/CLI). En el despliegue nuevo, usar secretos fuera del repo:
   - No imprimir la contraseña en el chat ni commitearla.
   - Verificar login con la nueva y 401 con la vieja.
4. Configurar en GitHub los secrets/variables que faltan (los pone el usuario):
   secrets: GCP_WORKLOAD_IDENTITY_PROVIDER, GCP_SERVICE_ACCOUNT, SSH_PRIVATE_KEY,
   GF_SECURITY_ADMIN_PASSWORD.
   variables: GCP_PROJECT_ID, GCP_INSTANCE_NAME, GCP_ZONE, GCP_USER, BACKUP_BUCKET.
5. Decidir backend remoto de Terraform. Hoy el estado es local. NO migrar sin
   copia y sin pedirlo.
6. Commits + push y prueba final end-to-end: deploy all-tags verde, 6/6 healthy,
   backup off-site descargado con integrity_check=ok y facturación a 0,00.

REGLAS QUE NO SE ROMPEN
- NUNCA `terraform apply` completo sin leer el plan: puede reemplazar la instancia.
- NUNCA sincronizar directorios completos ni borrar datos: /home/ubuntu/proxy/data,
  /home/ubuntu/proxy/letsencrypt, /home/ubuntu/monitoring, /home/ubuntu/backups.
  Solo se sincroniza lo declarado en compose_stacks.
- No dejar secretos en el repo, en logs ni en notas. terraform.tfstate*,
  .sesion/ y .local/ son locales.
- No salirse del free tier: e2-micro, pd-standard ≤ 30 GB, región válida, sin IP
  externa salvo decisión explícita.
- La instancia es frágil: ante fallos, mirar primero vmstat (wa), procesos en
  estado D y docker stats antes de culpar a la configuración.
- Grafana tarda 18-27 min en arrancar en e2-micro. No reiniciar en bucle.

VERIFICACIÓN RÁPIDA
- Gates: terraform fmt/validate, ansible-lint site.yml, yamllint ., compose
  config de los 3 stacks, drift del dashboard.
- Post-deploy: docker ps (6/6 healthy), /api/health, /-/healthy, /-/ready,
  swapon --show, túneles IAP y facturación 0,00.

CRITERIO DE TERMINADO
Todos los gates verdes, deploy reproducible por CI, 6/6 contenedores healthy,
backup off-site verificado, facturación a 0,00 y documentación actualizada.
```

## 3. Estado verificado el 2026-11-13

| Área | Estado |
|---|---|
| Infraestructura | **No existe**: el proyecto anterior fue eliminado. Pendiente crear el nuevo |
| Terraform | Perfil free tier por defecto; validaciones estrictas; sin backend remoto |
| Ansible | Play único `site.yml`; swap, Docker, stacks, backups, hardening y verify |
| Seguridad de red | Sin IP pública ni puertos abiertos; SSH solo IAP; admin solo loopback |
| Backups | Cron 03:00 + GCS opcional; snapshots 04:00 UTC opcionales (no free tier) |
| Observabilidad | Prometheus + Grafana + Alertmanager; 6/6 contenedores; sin cAdvisor |
| CI | `quality.yml` completo; `main.yml` usa WIF + IAP (bug del túnel corregido) |
| Git | `66380b9` sin push + cambios de la revisión sin commitear |
| Bloqueos externos | Proyecto nuevo, secrets/variables de GitHub y rotación de contraseña |

> Los detalles de por qué cada decisión está así viven en
> [`ARQUITECTURA.md`](ARQUITECTURA.md#10-decisiones-registradas) y los límites de
> facturación en [`FREE-TIER.md`](FREE-TIER.md).
