# Changelog

Cambios relevantes del proyecto. Formato inspirado en
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).

## [2026-11-16]

### Cambiado

- **Perfil Always Free real.** Por defecto no se crea IP externa, ni snapshots,
  ni VPC Flow Logs, ni Shielded VM. El coste de base es **0,00 USD/mes**.
- **Disco `pd-standard`.** Se retira `pd-balanced`: el io-wait que lo justificaba
  lo causaba cAdvisor, no el disco.
- **Ventana de egress explícita.** `enable_egress` adjunta una IP efímera solo de
  salida para `apt` y `docker pull`. Se abre y cierra con `make egress-on` /
  `make egress-off`; no abre puertos entrantes.
- **Acceso solo por IAP.** SSH restringido a `35.235.240.0/20`; paneles y web en
  loopback, alcanzables por túnel.
- **Ansible unificado.** `site.yml` + `tasks/` sustituyen a `deploy_all.yml` y
  `config_swap.yml`. Swap, Docker, stacks, backups, hardening y verificación son
  idempotentes y se pueden ejecutar por tags.
- **Backups verificados.** SQLite backup API + `PRAGMA integrity_check` + cron
  03:00 + copia opcional a GCS con SA `objectCreator`. La prueba del despliegue
  usa `BACKUP_STRICT_UPLOAD=1`.
- **Observabilidad sin cAdvisor.** Prometheus, Grafana, Alertmanager y
  node-exporter con límites de memoria que suman 712 MiB.
- **CI con gates de calidad.** `quality.yml` valida Terraform, free tier,
  checkov, ansible-lint, yamllint, compose, dashboard y plantilla de Alertmanager.
  `main.yml` despliega por IAP con Workload Identity Federation.
- **Documentación consolidada.** `README.md`, `docs/FREE-TIER.md`,
  `docs/OPERACION.md` y los dos runbooks. Se eliminan `ARQUITECTURA`,
  `EJECUCION`, `ESTRUCTURA`, el índice `docs/README` y el prompt de sesión
  (conservado fuera del repositorio, en `.sesion/`).
- **Makefile y `scripts/deploy.sh`.** El flujo gratuito queda en `make plan`,
  `make egress-on`, `make deploy`, `make egress-off`; el túnel se cierra con
  `trap` aunque Ansible falle.

### Corregido

- El deploy fallaba con bucket configurado: `tasks/backups.yml` verificaba con
  `gsutil ls`, pero la SA solo tiene `objectCreator`. Ahora la prueba de subida
  es estricta y no lista el bucket.
- El README no mencionaba la ventana de egress, así que el quick start fallaba
  en `apt`.
- `templates/env.j2` no renderizaba `ALERTMANAGER_VERSION`, así que cambiar la
  versión en `group_vars` no tenía efecto.
- Inhibición muerta de Alertmanager para alertas de contenedores que ya no
  existen (cAdvisor retirado).
- `community.general` se instalaba sin usarse.
- El runbook de DR usaba `gsutil ls` desde la VM y mencionaba snapshots
  inexistentes.
- `tflint` corría sin `.tflint.hcl` ni plugin de Google; se retira del CI.
- El workflow de calidad ahora instala `pyyaml` y `jinja2` explícitamente.
