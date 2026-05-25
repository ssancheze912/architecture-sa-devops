# Guía de Bootstrap — Business Financiero Deploy

> **Audiencia:** Quien configure este proyecto por primera vez en un proyecto GCP nuevo, o quien retome el setup desde cero.
>
> **Objetivo:** Llevar el pipeline de infraestructura (`infra-pipeline.yml`) a su primera ejecución exitosa completamente autónoma via GitHub Actions.

---

## Índice

1. [Visión general del problema](#1-visión-general-del-problema)
2. [Prerrequisitos](#2-prerrequisitos)
3. [Paso 0 — Login y configuración del entorno](#paso-0--login-y-configuración-del-entorno)
4. [Paso 1 — Bootstrap del estado Terraform (GCS bucket)](#paso-1--bootstrap-del-estado-terraform-gcs-bucket)
5. [Paso 2 — Bootstrap del Deploy SA y WIF](#paso-2--bootstrap-del-deploy-sa-y-wif)
   - [Opción A — Terraform local (recomendado)](#opción-a--terraform-local-recomendado)
   - [Opción B — gcloud manual + import](#opción-b--gcloud-manual--import)
6. [Paso 3 — Verificar configuración en GitHub](#paso-3--verificar-configuración-en-github)
7. [Paso 4 — Primera ejecución del pipeline](#paso-4--primera-ejecución-del-pipeline)
8. [Paso 5 — Verificar que todo funciona](#paso-5--verificar-que-todo-funciona)
9. [Referencia rápida de valores del proyecto](#referencia-rápida-de-valores-del-proyecto)
10. [Troubleshooting](#troubleshooting)

---

## 1. Visión general del problema

El pipeline CI/CD (`infra-pipeline.yml`) se autentica contra GCP usando **Workload Identity Federation (WIF)**: GitHub Actions obtiene un token OIDC y lo intercambia por credenciales de la Service Account `sa-sie-fin-deploy-cicd`. Sin JSON keys.

El problema del arranque inicial es **circular**:

```
El pipeline necesita que exista la SA y el WIF Pool
        ↓
Terraform crea la SA y el WIF Pool
        ↓
Terraform necesita autenticarse para correr
        ↓
Terraform se autentica via la SA que aún no existe
```

**Solución:** Hacer una única ejecución de Terraform de forma local (con credenciales de usuario), que crea toda la infraestructura incluyendo la SA y el WIF. A partir de ahí, el pipeline corre autónomamente para siempre.

```
[Una vez, local]          [Todas las veces, automático]
gcloud auth login  →  terraform apply local  →  GitHub Actions + WIF
```

---

## 2. Prerrequisitos

### Herramientas locales

| Herramienta | Versión mínima | Instalación |
|---|---|---|
| `gcloud` CLI | Cualquier reciente | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| `terraform` | >= 1.9 | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| `git` | Cualquier | Sistema operativo |

Verificar que están instaladas:
```bash
gcloud version
terraform version
git --version
```

### Acceso GCP

Necesitas una cuenta GCP con rol **Owner** o **Editor** en el proyecto `prj-sie-fin-financiero-dev`.

Verificar acceso:
```bash
gcloud projects describe prj-sie-fin-financiero-dev
# Debe mostrar los detalles del proyecto sin errores
```

Si no tienes acceso, contactar al administrador del proyecto GCP.

### Acceso GitHub

- Acceso de escritura al repo `SiesaTeams/business-financiero-deploy`
- GitHub Actions habilitado en el repositorio (verificar en Settings → Actions)

---

## Paso 0 — Login y configuración del entorno

### 0.1 Autenticarse en gcloud

```bash
# Login interactivo (abre el browser)
gcloud auth login

# Configurar las credenciales por defecto que usa Terraform
gcloud auth application-default login

# Establecer el proyecto activo
gcloud config set project prj-sie-fin-financiero-dev
```

### 0.2 Verificar autenticación

```bash
# Debe mostrar tu cuenta como activa
gcloud auth list

# Debe mostrar prj-sie-fin-financiero-dev
gcloud config get-value project

# Debe devolver datos del proyecto (no error 403)
gcloud projects describe prj-sie-fin-financiero-dev
```

### 0.3 Clonar el repositorio

```bash
git clone git@github.com:SiesaTeams/business-financiero-deploy.git
cd business-financiero-deploy
```

---

## Paso 1 — Bootstrap del estado Terraform (GCS bucket)

Terraform necesita un bucket de GCS para almacenar su estado remoto. Este bucket se crea una sola vez con un Terraform independiente (bootstrap), usando estado **local** temporalmente.

El bucket a crear es: `bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev`

### 1.1 Ejecutar el bootstrap

```bash
cd terraform/bootstrap

# Inicializar con estado local (no tiene backend remoto configurado)
terraform init

# Verificar qué se va a crear
terraform plan

# Crear el bucket y habilitar APIs
terraform apply
```

El output mostrará:
```
state_bucket = "bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev"
```

> **Nota:** Si el bucket ya existe (proyecto no nuevo), este paso devolverá un error de recurso duplicado. En ese caso, puedes saltarlo y continuar con el Paso 2.

### 1.2 Verificar el bucket

```bash
gcloud storage ls gs://bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev
# Debe responder sin error (bucket existe y tienes acceso)
```

### 1.3 APIs habilitadas

El bootstrap también habilita las APIs necesarias. Verificar:

```bash
gcloud services list --enabled --filter="name:(container.googleapis.com OR cloudbuild.googleapis.com OR artifactregistry.googleapis.com OR secretmanager.googleapis.com OR sqladmin.googleapis.com)"
# Deben aparecer todas listadas como ENABLED
```

---

## Paso 2 — Bootstrap del Deploy SA y WIF

Este es el paso principal. Hay dos opciones: **A (recomendada)** y **B (manual)**.

---

### Opción A — Terraform local (recomendado)

Esta opción corre `terraform apply` localmente una sola vez. Terraform crea todo: el WIF Pool, el WIF Provider, todas las Service Accounts (incluyendo `sa-sie-fin-deploy-cicd`) y sus roles.

Después de este apply, el pipeline de GitHub Actions funcionará automáticamente sin ningún paso adicional.

#### A.1 Inicializar el entorno DEV

```bash
cd terraform/environments/dev
terraform init
```

El output debe mostrar:
```
Initializing the backend...
Successfully configured the backend "gcs"!
```

Si dice `Successfully configured the backend "gcs"`, el bucket del Paso 1 está accesible.

#### A.2 Revisar el plan

```bash
terraform plan
```

Revisar el output. En un proyecto limpio, debe mostrar recursos a crear. Los principales son:

- `google_iam_workload_identity_pool.github` — WIF Pool
- `google_iam_workload_identity_pool_provider.github` — WIF Provider
- `google_service_account.cicd["deploy"]` — SA principal de CI/CD
- `google_service_account.cicd["access-manager"]` — SA del servicio
- `google_service_account.cicd["app-shell"]` — SA del servicio
- `google_service_account.cicd["segments"]` — SA del servicio
- `google_project_iam_member.cicd_roles[...]` — Roles IAM
- Cluster GKE, Cloud SQL, Artifact Registry, DNS, Gateway, Namespaces

> **IMPORTANTE:** Si hay recursos que ya existen en GCP (por ejemplo, si el cluster ya fue creado antes), el plan mostrará un error de recurso duplicado. En ese caso, importar esos recursos primero con `terraform import` antes de correr el apply. Ver sección [Troubleshooting](#troubleshooting).

#### A.3 Aplicar

```bash
terraform apply
# Cuando pida confirmación, escribir: yes
```

La ejecución tarda entre 10 y 20 minutos dependiendo de los recursos (GKE Autopilot tarda más).

#### A.4 Verificar la SA creada

```bash
gcloud iam service-accounts describe \
  sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com

# Verificar los roles asignados
gcloud projects get-iam-policy prj-sie-fin-financiero-dev \
  --flatten="bindings[].members" \
  --filter="bindings.members:sa-sie-fin-deploy-cicd" \
  --format="table(bindings.role)"
```

#### A.5 Verificar el WIF Pool y Provider

```bash
gcloud iam workload-identity-pools describe github-actions \
  --location=global \
  --project=prj-sie-fin-financiero-dev

gcloud iam workload-identity-pools providers describe github \
  --workload-identity-pool=github-actions \
  --location=global \
  --project=prj-sie-fin-financiero-dev
```

Si ambos comandos devuelven datos (no error), el WIF está configurado. **Puedes saltar directamente al [Paso 3](#paso-3--verificar-configuración-en-github).**

---

### Opción B — gcloud manual + import

Usar esta opción solo si **no puedes correr Terraform localmente** o si el proyecto ya tiene recursos parcialmente creados que necesitas manejar manualmente.

> Esta opción requiere más pasos y es más propensa a errores. La Opción A es preferible.

#### B.1 Crear el WIF Pool

```bash
gcloud iam workload-identity-pools create github-actions \
  --location=global \
  --display-name="GitHub Actions" \
  --project=prj-sie-fin-financiero-dev
```

#### B.2 Crear el WIF Provider

```bash
gcloud iam workload-identity-pools providers create-oidc github \
  --location=global \
  --workload-identity-pool=github-actions \
  --display-name="GitHub" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --project=prj-sie-fin-financiero-dev
```

#### B.3 Crear la Service Account

```bash
gcloud iam service-accounts create sa-sie-fin-deploy-cicd \
  --display-name="CI/CD SA for deploy" \
  --project=prj-sie-fin-financiero-dev
```

#### B.4 Asignar roles

```bash
SA="sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com"
PROJECT="prj-sie-fin-financiero-dev"

for role in \
  roles/container.admin \
  roles/compute.securityAdmin \
  roles/artifactregistry.admin \
  roles/cloudsql.admin \
  roles/dns.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.workloadIdentityPoolAdmin \
  roles/secretmanager.admin \
  roles/pubsub.admin \
  roles/storage.admin \
  roles/resourcemanager.projectIamAdmin; do
  echo "Asignando $role..."
  gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:$SA" \
    --role="$role"
done
```

#### B.5 WIF binding (SA ↔ GitHub repo)

```bash
gcloud iam service-accounts add-iam-policy-binding \
  sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/641762852790/locations/global/workloadIdentityPools/github-actions/attribute.repository/SiesaTeams/business-financiero-deploy" \
  --project=prj-sie-fin-financiero-dev
```

#### B.6 Importar recursos a Terraform state

Esto es crítico. Sin el import, la próxima vez que corra `terraform apply` (via CI/CD), intentará crear recursos que ya existen → error.

```bash
cd terraform/environments/dev
terraform init

# Importar WIF Pool
terraform import \
  'module.iam.google_iam_workload_identity_pool.github' \
  'projects/prj-sie-fin-financiero-dev/locations/global/workloadIdentityPools/github-actions'

# Importar WIF Provider
terraform import \
  'module.iam.google_iam_workload_identity_pool_provider.github' \
  'projects/prj-sie-fin-financiero-dev/locations/global/workloadIdentityPools/github-actions/providers/github'

# Importar Deploy SA
terraform import \
  'module.iam.google_service_account.cicd["deploy"]' \
  'projects/prj-sie-fin-financiero-dev/serviceAccounts/sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com'
```

#### B.7 Verificar el state

```bash
terraform state list | grep iam
# Debe mostrar los recursos importados
```

#### B.8 Plan para verificar drift

```bash
terraform plan
# Idealmente: "No changes" para los recursos importados
# Si muestra cambios, revisarlos y aplicarlos si son correctos
```

---

## Paso 3 — Verificar configuración en GitHub

El pipeline usa WIF — **no se necesitan secrets** en GitHub. Solo verificar que Actions está habilitado.

### 3.1 Verificar que GitHub Actions está habilitado

1. Ir a `https://github.com/SiesaTeams/business-financiero-deploy`
2. Settings → Actions → General
3. Asegurarse que "Allow all actions and reusable workflows" está seleccionado (o al menos los de GitHub y acciones verificadas)

### 3.2 Verificar permisos del workflow

El archivo `.github/workflows/infra-pipeline.yml` declara:

```yaml
permissions:
  contents: read
  id-token: write      # Necesario para WIF / OIDC
  pull-requests: write # Para comentar el plan en PRs
```

El permiso `id-token: write` es el que permite a GitHub generar el token OIDC que WIF usa para autenticarse. No requiere configuración adicional, solo que el repo no tenga restricciones de seguridad que lo bloqueen.

### 3.3 Verificar que el WIF Provider acepta el repo

El binding de WIF está restringido al atributo `attribute.repository = SiesaTeams/business-financiero-deploy`. Esto significa que **solo** los workflows de ese repo pueden asumir la identidad de `sa-sie-fin-deploy-cicd`.

Verificar el binding:
```bash
gcloud iam service-accounts get-iam-policy \
  sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com \
  --project=prj-sie-fin-financiero-dev
```

Debe mostrar un binding similar a:
```yaml
- members:
  - principalSet://iam.googleapis.com/projects/641762852790/locations/global/workloadIdentityPools/github-actions/attribute.repository/SiesaTeams/business-financiero-deploy
  role: roles/iam.workloadIdentityUser
```

---

## Paso 4 — Primera ejecución del pipeline

Ahora que la infraestructura base existe y el WIF está configurado, el pipeline puede correr automáticamente.

### 4.1 Crear una rama de prueba

```bash
git checkout -b test/bootstrap-validation
```

### 4.2 Hacer un cambio inocuo en terraform/

```bash
# Agregar un comentario al final de main.tf
echo "" >> terraform/environments/dev/main.tf
echo "# Bootstrap validado: $(date -u +%Y-%m-%d)" >> terraform/environments/dev/main.tf
```

### 4.3 Push y crear PR

```bash
git add terraform/environments/dev/main.tf
git commit -m "test: validate bootstrap and CI/CD pipeline"
git push origin test/bootstrap-validation
```

Crear el PR en GitHub:
```bash
gh pr create \
  --title "test: validate bootstrap and CI/CD pipeline" \
  --body "Prueba de que el pipeline de infraestructura funciona correctamente tras el bootstrap." \
  --base main
```

### 4.4 Observar la ejecución

En GitHub → Actions, el workflow "Infrastructure Pipeline" debe aparecer ejecutándose.

Los jobs que se ejecutarán:
1. **Load Config** → parsea `project-config.yaml` con `yq`
2. **Terraform Plan** → `terraform init` + `terraform validate` + `terraform plan` → comenta en el PR

Verificar via CLI:
```bash
# Ver los runs de la rama
gh run list --branch test/bootstrap-validation

# Ver el detalle del run (reemplazar RUN_ID)
gh run view RUN_ID

# Ver los logs completos
gh run view RUN_ID --log
```

### 4.5 Verificar el comentario en el PR

```bash
gh pr view --comments
```

Debe aparecer un comentario con el output del `terraform plan`.

### 4.6 Merge y verificar el apply

Una vez que el plan sea correcto:

```bash
gh pr merge --squash
```

Después del merge, el pipeline ejecutará:
1. **Load Config**
2. **Terraform Apply** (si hay cambios en terraform/)
3. **K8s Manifests** (si hay cambios en routes/, redis/, dapr/, etc.)

Verificar el apply:
```bash
gh run list --branch main | head -5
gh run view RUN_ID --log
```

---

## Paso 5 — Verificar que todo funciona

### 5.1 Checklist de verificación

```
[ ] Load Config completa OK (outputs coinciden con project-config.yaml)
[ ] Terraform Plan no tiene errores (o muestra "No changes" si el apply ya estaba al día)
[ ] Terraform Apply completa sin errores
[ ] No hay errores 403 (permisos del SA)
[ ] No hay errores de autenticación WIF ("could not find default credentials")
[ ] terraform apply reporta "No changes" o aplica cambios esperados
```

### 5.2 Verificar autenticación WIF en los logs

En GitHub Actions → Run → Job "Terraform Apply" → Step "Authenticate to GCP":

```
Run google-github-actions/auth@v2
✓ Successfully authenticated
  Service Account: sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com
```

Si aparece este mensaje, WIF funciona correctamente.

### 5.3 Continuar con el plan de pruebas completo

Una vez validado que el pipeline básico funciona, seguir con las pruebas formales documentadas en:

📄 [`docs/infra-cicd-test-plan.md`](./infra-cicd-test-plan.md)

El orden recomendado:
```
A4 → A1 → A2 → A3 → A5 → B1 → B2 → B3 → C → D → E
```

---

## Referencia rápida de valores del proyecto

Todos estos valores están en `project-config.yaml` y son la fuente de verdad. Se documentan aquí solo para consulta rápida.

| Parámetro | Valor |
|---|---|
| Project ID | `prj-sie-fin-financiero-dev` |
| Project Number | `641762852790` |
| Región | `us-east1` |
| Cluster GKE | `gke-sie-fin-dev` |
| Deploy SA | `sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com` |
| WIF Pool | `github-actions` |
| WIF Provider | `github` |
| WIF Provider Full | `projects/641762852790/locations/global/workloadIdentityPools/github-actions/providers/github` |
| TF State Bucket | `bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev` |
| TF State Prefix | `terraform/environments/dev` |
| Cloud Build Worker Pool | `projects/prj-sie-fin-financiero-dev/locations/us-east1/workerPools/financiero-pool` |
| GitHub Repo (deploy) | `SiesaTeams/business-financiero-deploy` |

---

## Troubleshooting

### Error: "bucket does not exist" en terraform init

**Síntoma:**
```
Error: Failed to get existing workspaces: querying Cloud Storage failed: ...
```

**Causa:** El bucket de estado GCS no existe.

**Solución:** Ejecutar el Paso 1 (bootstrap del bucket).

---

### Error: "resource already exists" en terraform apply

**Síntoma:**
```
Error: Error creating WorkloadIdentityPool: googleapi: Error 409: ...already exists
```

**Causa:** El recurso ya existe en GCP pero no está en el TF state.

**Solución:** Importar el recurso al state:
```bash
# Para WIF Pool:
terraform import 'module.iam.google_iam_workload_identity_pool.github' \
  'projects/prj-sie-fin-financiero-dev/locations/global/workloadIdentityPools/github-actions'

# Para SA deploy:
terraform import 'module.iam.google_service_account.cicd["deploy"]' \
  'projects/prj-sie-fin-financiero-dev/serviceAccounts/sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com'
```

Luego correr `terraform plan` para verificar que no hay drift.

---

### Error: "could not find default credentials" en GitHub Actions

**Síntoma en Actions logs:**
```
Error: google: could not find default credentials
```

**Causas posibles:**

1. **WIF Pool o Provider no existe** → Verificar con `gcloud iam workload-identity-pools describe github-actions --location=global`
2. **WIF binding incorrecto** → Verificar con `gcloud iam service-accounts get-iam-policy sa-sie-fin-deploy-cicd@...`
3. **Permiso `id-token: write` falta en el workflow** → Verificar en `.github/workflows/infra-pipeline.yml`
4. **Repo incorrecto en el binding** → El binding debe tener exactamente `SiesaTeams/business-financiero-deploy`

---

### Error: "Permission denied" (403) en terraform apply

**Síntoma:**
```
Error: googleapi: Error 403: Permission 'X' denied on resource 'Y'
```

**Causa:** La SA `sa-sie-fin-deploy-cicd` no tiene el rol necesario.

**Solución:** Verificar roles asignados:
```bash
gcloud projects get-iam-policy prj-sie-fin-financiero-dev \
  --flatten="bindings[].members" \
  --filter="bindings.members:sa-sie-fin-deploy-cicd" \
  --format="table(bindings.role)"
```

Si falta algún rol, asignarlo manualmente o actualizar `project-config.yaml → deploy.roles` y hacer un apply local.

---

### Error: "backend configuration changed" en terraform init

**Síntoma:**
```
Error: Backend configuration changed
```

**Causa:** El backend GCS tiene un prefijo diferente al esperado.

**Solución:**
```bash
terraform init -reconfigure
```

---

### Pipeline no se ejecuta en el PR

**Causa:** El cambio no está en ninguno de los `paths` configurados en el workflow.

Los paths que disparan el pipeline son:
- `terraform/**`
- `routes/**`
- `redis/**`
- `dapr/**`
- `healthcheck/**`
- `import-map/**`
- `project-config.yaml`

Cambios en `docs/**`, `CLAUDE.md`, `.gemini/**`, etc. no disparan el pipeline (intencional).

---

---

## Apéndice — Bootstrap del SA Sandbox-Dev

El ambiente sandbox-dev tiene su propio SA (`sa-sie-fin-sandbox-dev-cicd`) que debe crearse manualmente antes de ejecutar el pipeline `infra-pipeline-sandbox.yml`. El SA **no es gestionado por Terraform** (para evitar conflictos de state con el ambiente dev).

> **Prerequisito:** El WIF pool `github-actions` ya debe existir (creado en el Paso 2 de esta guía con el apply del ambiente dev).

### SB.1 Crear el SA y asignar roles

```bash
PROJECT="prj-sie-fin-financiero-dev"
SA="sa-sie-fin-sandbox-dev-cicd"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"
PROJECT_NUM="641762852790"

# 1. Crear SA (si ya existe, saltear este paso)
gcloud iam service-accounts create $SA \
  --display-name="CI/CD SA for sandbox-dev deploy" \
  --project=$PROJECT

# 2. Asignar roles
for role in \
  roles/container.admin \
  roles/compute.securityAdmin \
  roles/compute.viewer \
  roles/artifactregistry.admin \
  roles/cloudsql.admin \
  roles/dns.admin \
  roles/iam.serviceAccountAdmin \
  roles/secretmanager.admin \
  roles/pubsub.admin \
  roles/storage.admin \
  roles/resourcemanager.projectIamAdmin \
  roles/cloudbuild.builds.editor \
  roles/cloudbuild.workerPoolUser \
  roles/certificatemanager.editor; do
  gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:$SA_EMAIL" --role="$role"
done

# 3. WIF binding (pool compartido con dev)
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github-actions/attribute.repository/SiesaTeams/business-financiero-deploy" \
  --project=$PROJECT
```

### SB.2 Verificar el SA

```bash
gcloud iam service-accounts describe \
  sa-sie-fin-sandbox-dev-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com

gcloud iam service-accounts get-iam-policy \
  sa-sie-fin-sandbox-dev-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com \
  --project=prj-sie-fin-financiero-dev
# Debe mostrar el binding con principalSet://...github-actions...
```

### SB.3 Ejecutar el pipeline sandbox

Con el SA creado, hacer merge a main de los archivos sandbox. El pipeline `infra-pipeline-sandbox.yml` se dispara automáticamente y:

1. Lee `project-config.sandbox.yaml` (cluster `gke-sie-fin-sandbox-dev`, dominio `finance-sandbox.siesacloud.dev`)
2. Ejecuta `terraform apply` en `terraform/environments/sandbox/` → crea cluster, Cloud SQL, namespaces, gateway
3. Aplica los manifiestos en `routes/sandbox/`, `redis/`, `dapr/`, `healthcheck/`, `import-map/` via Cloud Build

```bash
# Verificar que el pipeline se disparó
gh run list --branch main | head -5

# Ver logs
gh run view <RUN_ID> --log
```

### SB.4 Referencia rápida — valores sandbox

| Parámetro | Valor |
|---|---|
| Cluster GKE | `gke-sie-fin-sandbox-dev` |
| Cloud SQL | `pgsql-fin-sandbox-dev` |
| Deploy SA | `sa-sie-fin-sandbox-dev-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com` |
| Gateway | `financiero-sandbox-dev-gateway` |
| Cert map | `finance-sandbox-siesacloud-dev-map` |
| Dominio | `finance-sandbox.siesacloud.dev` |
| TF State Prefix | `terraform/environments/sandbox` |
| master_cidr GKE | `172.16.0.16/28` |
| WIF Pool | `github-actions` (compartido con dev) |
| Config file | `project-config.sandbox.yaml` |

---

## Apéndice — Bootstrap de SAs de servicio (app-shell, access-manager, segments)

Los SAs de servicio son los que usan los pipelines CI/CD de cada repo individual (ej. `deploy-sandbox.yml` en `business-financiero-app-shell`). **No son gestionados por el pipeline de infra** — se crean via gcloud una sola vez.

> **Nota:** Los SAs de servicio (accmgr, appshell, segments) son creados por Terraform en el módulo `iam/` al correr `terraform apply` del ambiente dev/sandbox. El bootstrap manual solo es necesario si el pipeline de infra aún no ha corrido o si se necesita un permiso adicional fuera de Terraform.

### SVC.1 Permisos requeridos por SA de servicio

Cada SA de servicio necesita los siguientes roles para ejecutar `gcloud builds submit` contra el worker pool privado:

| Rol | Para qué |
|---|---|
| `roles/artifactregistry.writer` | Push de imágenes Docker |
| `roles/cloudbuild.builds.editor` | Crear y ver builds |
| `roles/cloudbuild.workerPoolUser` | Usar el worker pool privado |
| `roles/container.developer` | `kubectl apply` en el cluster |
| `roles/secretmanager.secretAccessor` | Leer secrets (ej. NPM_TOKEN) |
| `roles/storage.admin` | Upload del source code al bucket `_cloudbuild` |

Adicionalmente, necesita `roles/iam.serviceAccountUser` **a nivel del Compute Engine SA** (no del proyecto):

```bash
gcloud iam service-accounts add-iam-policy-binding \
  641762852790-compute@developer.gserviceaccount.com \
  --member="serviceAccount:<SA_EMAIL>" \
  --role="roles/iam.serviceAccountUser" \
  --project=prj-sie-fin-financiero-dev
```

> **Por qué:** El worker pool de Cloud Build usa el Compute Engine default SA del proyecto. Al ejecutar `gcloud builds submit`, el SA del llamante debe poder "actuar como" ese SA. Sin este binding, el build falla con `PERMISSION_DENIED: caller does not have permission to act as service account`.

### SVC.2 Script de bootstrap para app-shell

```bash
PROJECT="prj-sie-fin-financiero-dev"
SA="sa-sie-fin-appshell-cicd"
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"
PROJECT_NUM="641762852790"
COMPUTE_SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"

# Roles a nivel de proyecto
for role in \
  roles/artifactregistry.writer \
  roles/cloudbuild.builds.editor \
  roles/cloudbuild.workerPoolUser \
  roles/container.developer \
  roles/secretmanager.secretAccessor \
  roles/storage.admin; do
  gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:$SA_EMAIL" --role="$role"
done

# serviceAccountUser sobre el Compute Engine SA (necesario para builds submit)
gcloud iam service-accounts add-iam-policy-binding $COMPUTE_SA \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/iam.serviceAccountUser" \
  --project=$PROJECT

# WIF binding para GitHub Actions
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github-actions/attribute.repository/SiesaTeams/business-financiero-app-shell" \
  --project=$PROJECT
```

Repetir para `sa-sie-fin-accmgr-cicd` y `sa-sie-fin-segments-cicd` cambiando el SA y el `attribute.repository` correspondiente.

### SVC.3 Secrets de aplicación para access-manager (sandbox)

El API de access-manager necesita credenciales adicionales en Secret Manager para arrancar en el cluster:

```bash
PROJECT="prj-sie-fin-financiero-dev"
COMPUTE_SA="641762852790-compute@developer.gserviceaccount.com"

# 1. Establecer contraseña del usuario postgres en Cloud SQL sandbox
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
gcloud sql users set-password postgres \
  --instance=pgsql-fin-sandbox-dev \
  --password="$DB_PASSWORD" \
  --project=$PROJECT

# 2. Guardar connection string
CONNECTION_STRING="Host=192.168.242.27;Database=finance-dev;Username=postgres;Password=${DB_PASSWORD};Search Path=access_manager;SSL Mode=Disable"
echo -n "$CONNECTION_STRING" | gcloud secrets create accmgr-sandbox-db-connection \
  --data-file=- --project=$PROJECT

# 3. Generar y guardar claves JWT RSA
openssl genrsa -out /tmp/jwt-private.pem 2048
openssl rsa -in /tmp/jwt-private.pem -pubout -out /tmp/jwt-public.pem
gcloud secrets create accmgr-sandbox-jwt-private --data-file=/tmp/jwt-private.pem --project=$PROJECT
gcloud secrets create accmgr-sandbox-jwt-public --data-file=/tmp/jwt-public.pem --project=$PROJECT
rm /tmp/jwt-private.pem /tmp/jwt-public.pem

# 4. Dar acceso al Compute Engine SA (usado por Cloud Build worker pool)
for secret in accmgr-sandbox-db-connection accmgr-sandbox-jwt-private accmgr-sandbox-jwt-public; do
  gcloud secrets add-iam-policy-binding $secret \
    --member="serviceAccount:$COMPUTE_SA" \
    --role="roles/secretmanager.secretAccessor" \
    --project=$PROJECT
done
```

> **Nota:** Cloud Build crea el K8s Secret `access-manager-config` en cada deploy, inyectando los valores desde estos secrets de SM. El Cloud SQL IP privado es `192.168.242.27` (obtenible con `gcloud sql instances describe pgsql-fin-sandbox-dev --format="value(ipAddresses[].ipAddress)"`).

---

### SVC.4 Secrets de aplicación para segments (sandbox)

El API de segments necesita acceso a la base de datos en Cloud SQL sandbox:

```bash
PROJECT="prj-sie-fin-financiero-dev"
COMPUTE_SA="641762852790-compute@developer.gserviceaccount.com"
INSTANCE="pgsql-fin-sandbox-dev"

# 1. Crear usuario en Cloud SQL sandbox
# BD única: finance-dev | Schema: segment | Usuario: dev
# (La BD finance-dev ya existe — compartida entre todos los servicios)
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
gcloud sql users create dev \
  --instance=$INSTANCE --password="$DB_PASSWORD" --project=$PROJECT

# 2. Guardar connection string en Secret Manager
# Host: 127.0.0.1 (Cloud SQL Auth Proxy sidecar escucha en localhost)
# El CI hace `sed 's/Host=[^;]*/Host=127.0.0.1/'` al leer este secret, pero
# mantener 127.0.0.1 directamente es más explícito.
CONNECTION_STRING="Host=127.0.0.1;Port=5432;Database=finance-dev;Username=dev;Password=${DB_PASSWORD};Search Path=segment;SSL Mode=Disable;GssEncryptionMode=Disable"
echo -n "$CONNECTION_STRING" | gcloud secrets create segments-sandbox-db-connection \
  --data-file=- --project=$PROJECT

# 3. Dar acceso al Compute Engine SA (usado por Cloud Build worker pool)
gcloud secrets add-iam-policy-binding segments-sandbox-db-connection \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT

# 4. El secret github-npm-token (NPM/NuGet PAT) también necesita acceso del Compute SA
#    (si no se hizo ya para access-manager)
gcloud secrets add-iam-policy-binding github-npm-token \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT
```

> **Notas:**
> - BD única `finance-dev` con schema `segment` — no se crea una BD separada por servicio.
> - `segments-sandbox-db-connection` es leído en cada deploy por el step de Cloud Build, que crea el K8s Secret `segments-config` con la connection string.
> - El Compute Engine SA necesita acceso a `github-npm-token` porque se usa en los steps de build (como `secretEnv`) — Cloud Build resuelve estos secrets usando el Compute SA del worker pool.
> - El Dockerfile del backend (`src/backend/Dockerfile`) espera el contexto desde la raíz del repo para incluir `nuget.config`. El `cloudbuild-sandbox.yaml` lo configura con `-f src/backend/Dockerfile .`.

---

### SVC.5 Secrets de aplicación para base-config (sandbox)

El API de base-config necesita acceso a la base de datos en Cloud SQL sandbox.

> **Prerequisito:** Ejecutar `terraform apply` en `environments/sandbox/` primero para que existan el SA de runtime (`sa-sie-fin-baseconfig-sql-dev`) y el usuario Cloud SQL (`base_config`).

```bash
PROJECT="prj-sie-fin-financiero-dev"
COMPUTE_SA="641762852790-compute@developer.gserviceaccount.com"
INSTANCE="pgsql-fin-sandbox-dev"

# 1. Establecer contraseña del usuario base_config (creado por Terraform)
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
gcloud sql users set-password base_config \
  --instance=$INSTANCE --password="$DB_PASSWORD" --project=$PROJECT

# 2. Guardar connection string en Secret Manager
# BD única: finance-dev | Schema: base_config | Usuario: base_config
CONNECTION_STRING="Host=127.0.0.1;Port=5432;Database=finance-dev;Username=base_config;Password=${DB_PASSWORD};Search Path=base_config;SSL Mode=Disable"
echo -n "$CONNECTION_STRING" | gcloud secrets create baseconfig-sandbox-db-connection \
  --data-file=- --project=$PROJECT

# 3. Dar acceso al Compute Engine SA (Cloud Build worker pool lo necesita durante deploy)
gcloud secrets add-iam-policy-binding baseconfig-sandbox-db-connection \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT

# 4. El secret github-npm-token también necesita acceso del Compute SA
#    (si no se hizo ya para access-manager o segments)
gcloud secrets add-iam-policy-binding github-npm-token \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT
```

> **Notas:**
> - El SA de runtime `sa-sie-fin-baseconfig-sql-dev` ya tiene `roles/secretmanager.secretAccessor` via Terraform (para Dapr secretstore en runtime).
> - El Compute SA necesita acceso separado para el step de Cloud Build que crea el K8s Secret `base-config-config` en cada deploy.
> - Convención del secret: `{short-name}-sandbox-db-connection` → `baseconfig-sandbox-db-connection`.
> - El K8s SA `base-config-api` debe tener la anotación `iam.gke.io/gcp-service-account: sa-sie-fin-baseconfig-sql-dev@prj-sie-fin-financiero-dev.iam.gserviceaccount.com` en el deployment del servicio.

### SVC.5.1 Otorgar permisos completos al usuario `dev` en todos los schemas (una sola vez por schema)

El usuario `dev` (credenciales en `dev-sandbox-db-connection`) es el usuario de desarrollo transversal: permite a los devs consultar, modificar datos **y ejecutar migraciones EF Core** localmente en todos los schemas de `finance-dev`. Los permisos incluyen DDL (CREATE TABLE, ALTER TABLE, CREATE INDEX) además de DML.

Este paso es **manual** — Terraform no gestiona permisos a nivel de schema PostgreSQL. Repetir cada vez que se agrega un nuevo servicio.

**Prerequisito:** El schema debe existir (lo crea EF Migrations al primer arranque del servicio, o el propio `dev` al correr `dotnet ef database update` localmente por primera vez).

**Paso 1 — Otorgar CREATE en la base de datos (solo una vez, como `postgres`)**

Necesario para que `dev` pueda crear nuevos schemas al onboardear servicios nuevos.

```bash
./scripts/dev-connect.sh
# En otra terminal:
PGPASSWORD="<postgres-password>" psql -h 127.0.0.1 -U postgres -d finance-dev
```

```sql
GRANT CREATE ON DATABASE "finance-dev" TO dev;
```

**Paso 2 — Otorgar permisos DDL + DML por schema (como owner del schema)**

Ejecutar para cada schema, conectando como el usuario propietario del mismo:

```bash
# Ejemplo para base_config (ajustar secret y usuario según el schema):
CONN=$(gcloud secrets versions access latest --secret=baseconfig-sandbox-db-connection --project=prj-sie-fin-financiero-dev)
PGPASSWORD=$(echo "$CONN" | sed 's/.*[Pp]assword=\([^;]*\).*/\1/')
PGPASSWORD="$PGPASSWORD" psql -h 127.0.0.1 -U base_config -d finance-dev
```

```sql
-- Reemplazar {schema} con: segment | base_config | access_manager | tprt | acct | liquid_tax

GRANT ALL PRIVILEGES ON SCHEMA {schema} TO dev;          -- incluye USAGE + CREATE (DDL)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA {schema} TO dev;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {schema} TO dev;

-- Para objetos creados en el futuro por EF Migrations
ALTER DEFAULT PRIVILEGES IN SCHEMA {schema}
  GRANT ALL PRIVILEGES ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA {schema}
  GRANT ALL PRIVILEGES ON SEQUENCES TO dev;
```

**Tabla de referencia — owner por schema:**

| Schema | Owner (conectar como) | Secret |
|---|---|---|
| `segment` | `segments` | `segments-sandbox-db-connection` |
| `base_config` | `base_config` | `baseconfig-sandbox-db-connection` |
| `access_manager` | `accmgr` | `accmgr-sandbox-db-connection` |
| `tprt` | `third_party` | `tprt-dev-db-connection` |
| `acct` | `accounting` | `acct-dev-db-connection` |
| `liquid_tax` | `liquid_tax` | `liquid-tax-dev-db-connection` |

> **Nota:** `GRANT ALL PRIVILEGES ON SCHEMA` otorga `USAGE` + `CREATE`. El `CREATE` en el schema es lo que permite a EF Core crear tablas e índices. Sin él, `dotnet ef database update` falla con `ERROR: permission denied for schema {schema}`.

---

## Apéndice — Gestión de certificados TLS con Terraform

> **REGLA:** Los certificados TLS y todos sus recursos asociados (cert maps, DNS authorizations) deben gestionarse **exclusivamente via Terraform**. No crear ni modificar certificados en la consola GCP o con gcloud directamente.

### CM.1 Cómo funciona el módulo certificate-manager

El módulo `terraform/modules/certificate-manager/` gestiona los siguientes recursos en secuencia lógica:

```
[DNS Authorization] → genera CNAME record de validación
        ↓
[google_dns_record_set] → crea el CNAME en la zona DNS (prueba de propiedad)
        ↓
[Certificate] → Google emite el certificado TLS (validado via DNS)
        ↓
[Certificate Map] → referenciado por el Gateway via anotación networking.gke.io/certmap
        ↓
[Certificate Map Entry] → asocia el certificado al hostname en el mapa
```

El Gateway solo necesita el nombre del cert map (configurado en `project-config.yaml → gateway.cert_map`). El resto del flujo es automático via Terraform.

### CM.2 Configurar el A record del Gateway (post-deploy)

El A record DNS (dominio → IP del Gateway) requiere que el Gateway tenga una IP asignada, lo que ocurre después de que GKE provisiona el Load Balancer (~2-5 min post-create).

**Paso 1 — Obtener la IP del Gateway:**

```bash
# Para sandbox:
kubectl get gateway financiero-sandbox-dev-gateway -n gateway-infra \
  -o jsonpath='{.status.addresses[0].value}'

# Para dev:
kubectl get gateway financiero-gateway -n gateway-infra \
  -o jsonpath='{.status.addresses[0].value}'
```

**Paso 2 — Agregar la IP al project-config:**

```yaml
# En project-config.sandbox.yaml (o project-config.yaml para dev):
gateway:
  name: financiero-sandbox-dev-gateway
  namespace: gateway-infra
  class: gke-l7-global-external-managed
  cert_map: finance-sandbox-siesacloud-dev-map
  external_ip: "34.120.x.x"  # <-- agregar esta línea
```

**Paso 3 — Hacer push:**

```bash
git add project-config.sandbox.yaml
git commit -m "chore: add sandbox gateway external IP for DNS A record"
git push
# El pipeline crea el A record automáticamente via terraform apply
```

### CM.3 Importar recursos de certificado DEV existentes

Los recursos de certificado del ambiente DEV (`finance-siesacloud-dev-cert` y `finance-siesacloud-dev-map`) fueron creados manualmente. Los import blocks en `terraform/environments/dev/main.tf` los importarán automáticamente en el próximo apply del pipeline.

Si el plan falla con error de import (nombre incorrecto), verificar los nombres reales:

```bash
# Listar DNS Authorizations
gcloud certificate-manager dns-authorizations list \
  --project=prj-sie-fin-financiero-dev

# Listar Certificados
gcloud certificate-manager certificates list \
  --project=prj-sie-fin-financiero-dev

# Listar Certificate Maps
gcloud certificate-manager maps list \
  --project=prj-sie-fin-financiero-dev

# Listar Certificate Map Entries
gcloud certificate-manager maps entries list \
  --map=finance-siesacloud-dev-map \
  --project=prj-sie-fin-financiero-dev

# Listar registros CNAME en la zona DNS (para encontrar el CNAME de validación)
gcloud dns record-sets list \
  --zone=siesacloud-dev \
  --project=prj-sie-fin-financiero-dev \
  --filter="type=CNAME"
```

Corregir los IDs en los bloques `import {}` de `terraform/environments/dev/main.tf` si difieren.

### CM.4 Añadir certificado para un nuevo ambiente

Al crear un nuevo ambiente (ej: QAS), agregar en su `main.tf`:

```hcl
module "certificate_manager" {
  source        = "../../modules/certificate-manager"
  project_id    = local.project_id
  domain        = local.config.dns.domain          # ej: finance-qas.siesacloud.dev
  dns_zone_name = local.config.dns.zone_name        # siesacloud-dev
  cert_name     = local.config.certificate.name     # finance-qas-siesacloud-dev-cert
  cert_map_name = local.config.gateway.cert_map     # finance-qas-siesacloud-dev-map
  labels        = local.labels
}
```

Y en el `project-config.yaml` del ambiente:

```yaml
gateway:
  cert_map: finance-qas-siesacloud-dev-map

certificate:
  name: finance-qas-siesacloud-dev-cert
```

---

*Última actualización: 2026-03-20*
