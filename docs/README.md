# Documentación

Índice y orden de lectura. Todo lo que hay aquí es documentación **operativa**:
está pensada para que alguien (o una sesión nueva) pueda entender, ejecutar y
mantener el proyecto sin leer el código línea por línea.

## Orden recomendado

| # | Documento | Para qué |
|---|---|---|
| 1 | [`FREE-TIER.md`](FREE-TIER.md) | Qué cubre Always Free, qué se factura, perfiles de coste y checklist del proyecto nuevo |
| 2 | [`ESTRUCTURA.md`](ESTRUCTURA.md) | Mapa completo de archivos, qué tocar y qué no, limpieza local y hallazgos de la revisión |
| 3 | [`ARQUITECTURA.md`](ARQUITECTURA.md) | Componentes, diagramas, red, seguridad, memoria, backups y decisiones |
| 4 | [`EJECUCION.md`](EJECUCION.md) | Puesta en marcha desde cero: Terraform, Ansible (dos modos), secretos, CI y verificación |
| 5 | [`OPERACION.md`](OPERACION.md) | Rutina de deploy, actualizar versiones, añadir stacks, Grafana, Terraform seguro y troubleshooting |
| 6 | [`PROMPT-NUEVA-SESION.md`](PROMPT-NUEVA-SESION.md) | Traspaso listo para copiar en otra sesión, con estado y pendientes |
| 7 | [`runbooks/alerting.md`](runbooks/alerting.md) | Qué hacer cuando salta cada alerta |
| 8 | [`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md) | Restaurar la base de datos o reconstruir la instancia |

## Atajos por tarea

| Quiero… | Ir a |
|---|---|
| Entender qué cuesta y qué es gratis | [`FREE-TIER.md`](FREE-TIER.md) |
| Desplegar por primera vez | [`EJECUCION.md`](EJECUCION.md) |
| Entender qué hace un archivo | [`ESTRUCTURA.md`](ESTRUCTURA.md) |
| Saber por qué SSH es solo IAP | [`ARQUITECTURA.md`](ARQUITECTURA.md#6-modelo-de-seguridad) |
| Actualizar una imagen o añadir un stack | [`OPERACION.md`](OPERACION.md) |
| Recuperar un backup o la instancia | [`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md) |
| Entender una alerta | [`runbooks/alerting.md`](runbooks/alerting.md) |
| Retomar en una sesión nueva | [`PROMPT-NUEVA-SESION.md`](PROMPT-NUEVA-SESION.md) |
| Ver el estado de git y pendientes | [`PROMPT-NUEVA-SESION.md`](PROMPT-NUEVA-SESION.md#3-estado-verificado-el-2026-11-13) |

## Convenciones

- Los documentos nuevos están en **español**; los runbooks existentes y los
  comentarios del código están en inglés.
- Los enlaces del tipo `docs/runbooks/...#ancla` se referencian desde las reglas
  de Prometheus (`runbook:`): no renombrar esos archivos sin actualizar
  `monitoring/prometheus/alerts.yml`.
- Las notas personales de sesión viven en `.sesion/` (gitignored) y **no** son
  documentación del proyecto. Lo que deba sobrevivir va en `docs/`.
