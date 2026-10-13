# Buenas prácticas de GitHub Actions

Guía de los workflows de este repositorio (`.github/workflows/ci.yml`, `.github/workflows/cd.yml`) y de por qué están escritos así. Cada punto indica si ya está aplicado o es una tarea pendiente.

## Resumen del diseño

| Workflow | Cuándo corre | Qué hace | Credenciales de AWS |
|---|---|---|---|
| `ci.yml` | `pull_request` hacia `main` | `terraform fmt`, `validate`, `shellcheck` y plan comentado en el PR | Rol de solo lectura (`AWS_PLAN_ROLE_ARN`), solo el job de plan |
| `cd.yml` | `push` a `main` y `workflow_dispatch` | Plan y, tras aprobación manual, apply del mismo plan | Rol de apply (`AWS_ROLE_ARN`) |

Los puntos que siguen sin marcar no se pueden resolver con código de este repo: son ajustes de GitHub o de AWS, o hábitos de revisión.

## 1. Disparadores

- [x] **CI solo en `pull_request`.** No se repite en el `push` a `main`: el merge ya llega con los checks verdes. Para que eso sea cierto, los checks tienen que ser obligatorios en la protección de la rama (ver "Configuración del repositorio").
- [x] **CD solo en `push` a `main`** (más `workflow_dispatch` para relanzarlo a mano). Nunca se despliega desde una rama o un PR.
- [x] **`branches: [main]`** en el disparador de CI, para no gastar minutos en PRs hacia otras ramas.
- [x] **`concurrency`.** CI cancela la ejecución anterior de la misma rama (`cancel-in-progress: true`). CD usa un grupo único con `cancel-in-progress: false`: cancelar un apply a medias dejaría el state bloqueado o a medio aplicar, así que las ejecuciones esperan en cola.

## 2. Permisos y secretos

- [x] **`permissions: contents: read` a nivel de workflow** y permisos adicionales solo en el job que los necesita. `id-token: write` (OIDC) está únicamente en los jobs que asumen un rol de AWS. `pull-requests: write` está solo en el job de plan de CI.
- [x] **OIDC en lugar de claves de acceso.** No hay `AWS_ACCESS_KEY_ID` ni `AWS_SECRET_ACCESS_KEY` guardadas en GitHub. `aws-actions/configure-aws-credentials` obtiene credenciales temporales por ejecución.
- [x] **Dos roles distintos.** El plan de los PR usa un rol de solo lectura; el apply usa otro con permisos de escritura. Un PR nunca puede asumir el rol de apply.
- [x] **`persist-credentials: false`** en todos los `actions/checkout`, para que el token de Git no quede en `.git/config` del runner.
- [x] **Los valores de `terraform.tfvars` en variables de GitHub, una por valor** (`SUBNET_ID`, `ALLOWED_CLIENT_SECURITY_GROUP_IDS`, `OTLP_ENDPOINT_PARAMETERS`), que los workflows pasan a Terraform como `TF_VAR_<nombre>`. No son secretos (ids de subred y de security groups), así que no se escribe ningún archivo en el runner. El `terraform.tfvars` local sigue en `.gitignore`. Si añades un valor a tu `terraform.tfvars`, añade también su variable y su `TF_VAR_` en los dos workflows.
- [x] **Los secretos pasan por `env:`**, nunca interpolados directamente en el script (`run: printf ... ${{ secrets.X }}`). Así no se pueden inyectar comandos ni aparecer en el log expandidos.
- [x] **Política de confianza acotada** por repositorio y entorno (`ci_roles.tf`, variable `github_oidc_subject`). Campo `sub` del token OIDC:
  - Plan: `repo:<owner>/<repo>:environment:plan`
  - Apply: `repo:<owner>/<repo>:environment:production`

  Es la convención de los roles de los otros stacks de la cuenta (por ejemplo `coika-auth_service-infra-ci_plan-role`). En esta cuenta el `sub` lleva además los ids del propietario y del repo (`repo:acortescab@289379741/<repo>@<id>:environment:plan`).

  Con eso, ni siquiera un workflow modificado en otra rama puede asumir el rol de apply.

## 3. Dependencias de terceros (supply chain)

- [x] **Acciones fijadas por SHA de commit**, con el tag en un comentario (`@11d5960… # v4.4.0`). Un tag como `v4` se puede mover; un SHA no. Es especialmente importante en `cd.yml`, que maneja credenciales de AWS.
- [x] **Dependabot** (`.github/dependabot.yml`) actualiza cada semana los SHA de las acciones y el proveedor de Terraform. Sin él, los SHA fijados se quedarían obsoletos. Con `cooldown` de 7 días: no propone una versión hasta una semana después de publicarla, el tiempo en que suele detectarse una versión comprometida.
- [x] **Misma versión de Terraform en todos los jobs** (`terraform_version: "1.15.5"` escrito directamente en `ci.yml` y `cd.yml`), para que el plan lo aplique la misma versión que lo generó. Dependabot no la actualiza: al subirla, cambiar las cuatro apariciones (dos en cada workflow), siempre dentro de `required_version` de `versions.tf`.
- [x] **Lock file de proveedores** (`.terraform.lock.hcl`) versionado.
- [ ] **Revisar los cambios de Dependabot antes de fusionarlos.** Un SHA nuevo es código nuevo que corre con credenciales; mirar el changelog de la acción.

## 4. Seguridad de los PR

- [x] **El job de plan se salta en forks y en Dependabot** (`head.repo.full_name == github.repository` y `github.actor != 'dependabot[bot]'`). Ninguno recibe secretos ni OIDC, así que fallaría siempre.
- [ ] **Entender el riesgo del plan.** `terraform plan` ejecuta el Terraform de la rama del PR con credenciales de AWS. Un PR malicioso podría usar un `data "external"` o un proveedor modificado para ejecutar código con el rol de plan. Por eso el rol es de solo lectura, y conviene limitar quién puede abrir PRs en el repositorio.
- [ ] **No usar `pull_request_target`** para ejecutar código del PR. No se usa aquí; si algún día hace falta, hay que tratar el código del PR como no fiable.

## 5. Despliegue (CD)

- [x] **Plan y apply separados.** El job `plan` guarda el plan con `-out=tfplan` y el job `apply` aplica exactamente ese fichero. Terraform rechaza el plan si el state cambió entre medias.
- [x] **Aprobación manual** con el entorno `production` (revisores obligatorios) antes del apply.
- [x] **El apply solo corre si hay cambios** (`terraform plan -detailed-exitcode`: 0 sin cambios, 2 con cambios, 1 error).
- [x] **El plan guardado dura un día** (`retention-days: 1`) y solo lo lee el job de apply, porque puede contener valores sensibles.
- [x] **`TF_IN_AUTOMATION` y `TF_INPUT=false`:** Terraform no pregunta nada y ajusta su salida para CI.
- [x] **State con bloqueo.** El backend S3 usa `use_lockfile = true`. El plan de los PR usa `-lock=false` porque su rol no puede escribir el `.tflock` y un plan de revisión nunca debe bloquear un apply.
- [ ] **Entorno `production` con "Prevent self-review"** (el autor del merge no aprueba su propio despliegue), si hay más de una persona.
- [x] **Aviso de fallo del despliegue.** Si falla el plan o el apply, el job `notify-failure` abre un issue con el enlace al run (necesita los Issues activados en el repo). Para avisar a un canal habría que añadir un webhook como secreto.

## 6. Robustez de los workflows

- [x] **`timeout-minutes` en todos los jobs** (5 a 30 minutos), para que un job colgado no consuma minutos ni retenga el state.
- [x] **Los pasos de shell comprueban errores.** El paso de plan desactiva `set -e` solo para capturar el código de salida y lo restaura enseguida; el código 1 falla el job.
- [x] **`shellcheck` sobre `stack/*.sh`.** `bootstrap.sh`, `user_data.sh` y `data_disk.sh` son plantillas de Terraform (`%{ }`, `${ }`) y no son shell puro, por eso se excluyen.
- [x] **El comentario del plan se actualiza, no se acumula.** Se busca un comentario con el marcador `<!-- terraform-plan -->` y se edita; la salida se recorta a 60.000 caracteres (el límite de GitHub es 65.536).
- [x] **`tflint`** en CI (reglas en `.tflint.hcl`: preset recomendado de Terraform y reglas de AWS). Falla el check ante cualquier hallazgo. La versión del plugin AWS de `.tflint.hcl` y la de tflint en `ci.yml` se actualizan a mano: Dependabot no las ve.
- [x] **`trivy config`** en CI, **solo informativo** (`exit-code: "0"`, severidad `HIGH` y `CRITICAL`). Cuando los hallazgos estén corregidos o aceptados con `#trivy:ignore:<id>`, cambiar a `"1"` y hacerlo check obligatorio en `main`.
- [ ] **`checkov`:** descartado por ahora, hace casi lo mismo que Trivy. Se puede añadir si hacen falta reglas propias en Python.
- [x] **Validar los workflows en CI** (job `Lint workflows`): `actionlint` para errores de sintaxis y expresiones, y `zizmor` para seguridad (inyección por plantillas, permisos excesivos, acciones sin fijar). Fallan el check ante cualquier hallazgo. La versión de `actionlint` (`1.7.12`) y el SHA de su script de descarga en `ci.yml` se actualizan a mano.
## Configuración del repositorio

Lo que el código no puede hacer por sí solo y hay que crear en GitHub y en AWS.

**En GitHub** (Settings)

1. **Variables** (Settings > Secrets and variables > Actions > Variables):
   - `AWS_ROLE_ARN`: rol de apply (usado por `cd.yml`).
   - `AWS_PLAN_ROLE_ARN`: rol de solo lectura (usado por el plan de `ci.yml`).
2. **Variables con los valores de `terraform.tfvars`** (mismo sitio que las anteriores):
   - `SUBNET_ID`: el id tal cual, sin comillas (`subnet-0123456789abcdef0`).
   - `ALLOWED_CLIENT_SECURITY_GROUP_IDS`: lista JSON (`["sg-0123456789abcdef0"]`). Si no hay ninguno, `[]`: vacía hace fallar el plan.
   - `OTLP_ENDPOINT_PARAMETERS`: lista JSON (`["/coika/auth_service/app/OTEL_EXPORTER_OTLP_ENDPOINT"]`), o `[]`.
3. **Entornos:** `production` con revisores obligatorios (apply) y `plan` sin revisores (plan de los PR; solo sirve para que el token OIDC lleve `environment:plan`).
4. **Protección de la rama `main`** (Settings > Branches):
   - Exigir pull request antes de fusionar.
   - Checks obligatorios: `Terraform fmt and validate`, `TFLint`, `Shellcheck stack scripts` y `Lint workflows`. Añadir `Terraform plan` cuando el rol funcione. `Trivy config` no, mientras sea informativo.
   - Prohibir el push directo y el force-push.
5. **Actions**: "Allow actions created by GitHub" o una lista de acciones permitidas; flujos de trabajo de forks con aprobación obligatoria.

**En AWS** (IAM). Todo está en `ci_roles.tf`; el proveedor OIDC de GitHub ya existe en la cuenta y se referencia con un `data`, no se crea.

1. Rol de **apply** (`observability-ci_apply-role`): confianza limitada a `...:environment:production`. Permisos sobre la clave `observability/*` del bucket de state (incluido el `.tflock`) y sobre los recursos del stack: EC2, EBS, los roles y el perfil del host, el bucket de telemetría, dos tipos de parámetros SSM (`TELEMETRY_BUCKET` y los `otlp_endpoint_parameters`), DLM y las alarmas de CloudWatch. No puede tocar sus propios roles ni el boundary.
2. Rol de **plan** (`observability-ci_plan-role`): confianza limitada a `...:environment:plan`. Solo lectura de esos mismos recursos y del state. No escribe el state ni el `.tflock`, y no lee `GRAFANA_PASSWORD`, porque el plan ejecuta código del PR.
3. **Boundary** (`observability-ci-boundary`) en los dos roles de CI y en los dos roles del host (instancia y DLM). Prohíbe crear roles sin boundary, quitárselo o editarlo.
4. **Primer apply a mano** desde una estación de trabajo, porque el pipeline necesita que los roles existan. Después, los ARN salen en los outputs `ci_plan_role_arn` y `ci_apply_role_arn`, que van a las variables `AWS_PLAN_ROLE_ARN` y `AWS_ROLE_ARN` de GitHub. Los cambios en `ci_roles.tf` se aplican a mano, porque el rol de apply no puede modificarse a sí mismo.

## Cómo llega `stack/` al host

`cd.yml` solo aplica Terraform, pero ese apply despliega la configuración: `deploy.tf` define un documento SSM con el script de `bootstrap.sh` (que lleva `stack/` incrustado) y una association que lo ejecuta en la instancia cuando cambia. `user_data` se sigue ignorando para no reemplazar el host (punto 3 de `docs/REVIEW.md`).

- [x] **Despliegue de `stack/` en el apply.** Si falla en el host, el apply falla (`wait_for_success_timeout_seconds`).
- [ ] **Verificar en el primer apply real** que el documento corre bien en el host actual (Systems Manager > Run Command) y que el rol de apply tiene todos los permisos de `ssm:*Document*` y `ssm:*Association*`.
- Cada despliegue recrea los contenedores (`--force-recreate`): unos segundos sin telemetría; los juegos descartan lo que no pueden enviar.

## Checklist al tocar un workflow

- [ ] ¿La acción nueva está fijada por SHA y con el tag en un comentario?
- [ ] ¿El job pide solo los permisos que usa?
- [ ] ¿Los valores de `${{ ... }}` que no son de confianza (nombre de rama, título de PR) pasan por `env:` y no se interpolan en el script?
- [ ] ¿Tiene `timeout-minutes`?
- [ ] ¿Puede ejecutarse desde un fork o desde Dependabot? Si usa secretos, ¿hay un `if:` que lo evite?
- [ ] ¿Un cambio en el trigger evita que CI y CD corran dos veces sobre el mismo commit?
