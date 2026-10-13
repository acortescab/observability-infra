# Revisión de buenas prácticas para producción

Marca cada punto cuando esté corregido. La numeración coincide con la revisión original.

## Críticos

- [x] **1. Bloqueo de estado en el backend S3** (`versions.tf`). Hecho: `use_lockfile = true` y `required_version >= 1.10.0`. Pendiente verificar: `terraform init -reconfigure`, permisos `s3:PutObject`/`s3:DeleteObject` sobre el `.tflock` y versionado del bucket.
- [ ] **2. Single point of failure y datos en el disco raíz** (`main.tf`).
  - [x] Volumen EBS de datos separado (30 GiB), montado en `/var/lib/docker` (`aws_ebs_volume` + `aws_volume_attachment`) y `prevent_destroy`; raíz reducida a 12 GiB
  - [x] Tag `Snapshot` en el volumen de datos para DLM
  - [x] Alarma `StatusCheckFailed_System` con acción `recover`
  - [x] Alarma `StatusCheckFailed_Instance` con acción `reboot`
  - [x] `stop_grace_period` de 60 s en Prometheus, Loki y Tempo
  - [x] Primer `terraform apply` y comprobación del disco de datos montado en `/var/lib/docker`, también tras un reinicio (verificado el 2026-10-13)
  - [ ] (Más adelante) S3 como backend de Loki y Tempo / multi-AZ
- [ ] **3. Los cambios en `stack/` nunca llegan al host** (`ignore_changes = [ami, user_data]`). Falta un mecanismo de despliegue de config (SSM Association/Run Command desde S3, o pipeline).
- [ ] **4. Sin alarmas ni meta-monitoreo.**
  - [ ] Alarmas de CloudWatch (CPU, estado de la instancia, disco, memoria)
  - [ ] node-exporter / cAdvisor
  - [ ] Alertmanager y reglas de alerta
  - [ ] `healthcheck` en los servicios del compose
- [ ] **5. OTLP en texto plano y sin autenticación** (`otel-collector.yaml`, `outputs.tf`).
  - [ ] Validar que `allowed_client_cidrs` no acepte `0.0.0.0/0`
  - [ ] TLS en el receiver
  - [ ] Autenticación (`bearertokenauth` o mTLS)

## Altos

- [ ] **6. Retención sin límite de tamaño** frente a un disco de 30 GB: `--storage.tsdb.retention.size`, límites de ingesta en Loki y `max_bytes_per_trace` en Tempo.
- [ ] **7. SO e imágenes sin parchar.**
  - [ ] `unattended-upgrades` o SSM Patch Manager
  - [ ] Imágenes actualizadas y fijadas por digest
  - [ ] Proceso de actualización
- [ ] **8. El endpoint depende de la IP privada** (`aws_ssm_parameter.otlp_endpoint`): registro en zona privada de Route53 o ENI con IP fija.
- [ ] **9. La contraseña de Grafana no se puede rotar** (`GF_SECURITY_ADMIN_PASSWORD`, visible en `docker inspect`): usar `__FILE` o `grafana cli admin reset-admin-password`.
- [ ] **10. `GRAFANA_PASSWORD` se crea a mano fuera de Terraform**, y el servicio reintenta sin avisar si falta.
- [ ] **11. Descargas sin verificar en `user_data.sh`:** firma del AWS CLI, versiones de Docker fijadas, reintentos de `apt-get`.

## Medios

- [ ] **12. Egress totalmente abierto** (`-1` a `0.0.0.0/0`): limitar a 443 o usar VPC endpoints (ssm, ssmmessages, ec2messages, s3).
- [ ] **13. Límites de memoria (3.3 GB) frente a una `t3.medium` de 4 GB;** el comentario de `instance_type` dice 1.5 GiB. Revisar también créditos de CPU burstable.
- [ ] **14. Collector sin resiliencia:** `sending_queue` persistente (`file_storage`), `spike_limit_mib`, extensión `health_check` y telemetría propia.
- [ ] **15. `depends_on` sin `condition: service_healthy`** (requiere el healthcheck del punto 4).
- [ ] **16. Contenedores sin endurecer:** `no-new-privileges`, `cap_drop: [ALL]`, `read_only`, usuario no root; el usuario `ubuntu` está en el grupo `docker`.
- [ ] **17. Dashboards de Grafana no provisionados** (solo hay datasources).
- [ ] **18. Backups limitados:** copia cross-region/cross-account y pruebas de restauración.
- [ ] **19. Sin logging de las sesiones de SSM** (S3 o CloudWatch).

## Bajos / higiene del repo

- [ ] **20. Bucket e ID de cuenta escritos en `versions.tf`:** usar `-backend-config` o `backend.hcl`.
- [ ] **21. Pin de proveedor extraño** (`~> 6.0, < 6.65.0`): documentarlo o usar `~> 6.64`.
- [ ] **22. Falta `default_tags` y `allowed_account_ids`** en el provider.
- [ ] **23. Variables sin validación:** `subnet_id`, `snapshot_retention_days`, `allowed_client_cidrs`, `ssm_prefix`.
- [ ] **24. Higiene del repo:**
  - [ ] Primer commit (incluyendo `.terraform.lock.hcl`)
  - [ ] CI con `terraform fmt` y `validate`
  - [ ] `tflint` y `checkov`/`trivy`
  - [ ] `pre-commit`
- [ ] **25. Sin entorno de prueba ni `prevent_destroy`** en la instancia.
