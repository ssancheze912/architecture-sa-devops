---
name: sa-nuevo-ambiente
description: 'Adds a new environment (staging or prod) to this transversal by reading environments/{env}.yaml and generating the matching Terraform, CI/CD, and Kubernetes overlay artifacts. Use whenever the user wants to add a new deploy target to an existing transversal.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Agrega un nuevo ambiente (staging o prod) a esta transversal. Lee el `environments/{ambiente}.yaml` ya configurado y genera los artefactos Terraform, CI/CD y K8s overlay correspondientes.

**Uso:** `/sa-nuevo-ambiente {ambiente}`

**Ejemplo:** `/sa-nuevo-ambiente staging`

**Prerequisito:** El archivo `environments/{ambiente}.yaml` debe existir y tener todos los `<PLACEHOLDER>` completados antes de invocar este flow.

---

## Instrucciones

El argumento es: `$ARGUMENTS`

`AMBIENTE` = el argumento (ej: `staging`, `prod`)

Primero lee `environments/{AMBIENTE}.yaml` y valida que no existan `<PLACEHOLDER>` sin completar. Si los hay, muestra cuáles faltan y detente.

Luego lee los valores:
- `PROJECT_ID` = `.gcp.project_id`
- `PROJECT_NUM` = `.gcp.project_number`
- `REGION` = `.gcp.region`
- `GATEWAY_NAME` = `.gateway.name`
- `GKE_CLUSTER` = `.gke.cluster_name`
- `WORKER_POOL` = `.cloud_build.worker_pool`
- `DEPLOY_SA` = `.deploy.sa_name`
- `SUITE` = `.naming.product_suite`
- `BUSINESS_UNIT` = `.naming.business_unit`
- `PROJECT_ID_DEV` = leyendo `environments/dev.yaml` → `.gcp.project_id` (para el bucket de estado)

Si `PROJECT_NUM` contiene `<PLACEHOLDER>` o está vacío, resuélvelo con Bash antes de continuar:
```bash
gcloud projects describe {PROJECT_ID} --format='value(projectNumber)'
```
Si el comando falla (proyecto no creado aún), detente y pide al usuario que cree el proyecto GCP primero.

Lee también `environments/dev.yaml` para obtener la lista de servicios y namespaces actuales.

---

### Paso 1 — `terraform/environments/{AMBIENTE}/main.tf`

Copia la estructura de `terraform/environments/qa/main.tf` (NO de dev — QA tiene los recursos IAM del worker pool privado) y aplica estos cambios:
- `bucket = "bkt-sie-{SUITE}-iac-state-{PROJECT_ID_DEV}"` — mismo bucket, distinto prefix
- `prefix = "terraform/environments/{AMBIENTE}"`
- `config = yamldecode(file("${path.module}/../../../environments/{AMBIENTE}.yaml"))`
- Comentario de cabecera: actualizar para describir el ambiente `{AMBIENTE}`
- El provider kubernetes apunta al cluster `{GKE_CLUSTER}`

**CRÍTICO — IAM para worker pool privado:** El deploy vía `gcloud builds submit k8s/` con worker pool requiere 4 recursos IAM que NO están en `dev/main.tf` pero SÍ en `qa/main.tf`. Asegúrate de incluirlos (copiando de QA):
1. `cicd_sa_storage_admin` — `roles/storage.admin` a cada CI/CD SA (escribir fuente al bucket `{project}_cloudbuild`)
2. `compute_sa_storage_admin` — `roles/storage.admin` al Compute SA (leer fuente desde el bucket en el worker pool)
3. `compute_sa_container_admin` — `roles/container.admin` al Compute SA (kubectl dentro del container)
4. `compute_sa_secret_accessor` — `roles/secretmanager.secretAccessor` al Compute SA (leer secrets al crear K8s secrets)

Sin estos 4, `gcloud builds submit` falla con `forbidden from accessing bucket`.

### Paso 2 — `.github/workflows/infra-pipeline-{AMBIENTE}.yml`

Copia `.github/workflows/infra-pipeline-dev.yml` y aplica estos cambios:
- `name: Infrastructure Pipeline — Dev` → `name: Infrastructure Pipeline — {AMBIENTE}`
- Reemplaza todos los paths que dicen `environments/dev.yaml` → `environments/{AMBIENTE}.yaml`
- Reemplaza todos los paths que dicen `k8s/overlays/dev/` → `k8s/overlays/{AMBIENTE}/`
- Reemplaza en los triggers `paths:`:
  ```yaml
  - 'terraform/environments/{AMBIENTE}/**'
  - 'environments/{AMBIENTE}.yaml'
  - 'k8s/base/**'
  - 'k8s/overlays/{AMBIENTE}/**'
  ```
- Reemplaza todos los `yq` que leen `environments/dev.yaml` → `environments/{AMBIENTE}.yaml`
- Reemplaza `terraform/environments/dev/` → `terraform/environments/{AMBIENTE}/`
- Reemplaza `k8s/overlays/dev/` → `k8s/overlays/{AMBIENTE}/` en los kubectl apply y tar

Si el ambiente es `prod`, agrega al job `terraform-apply`:
```yaml
    environment:
      name: prod
      url: https://{DOMINIO}
```
(lee el dominio de `environments/prod.yaml` → `.dns.domain`)

### Paso 3 — `k8s/overlays/{AMBIENTE}/` (estructura completa)

Copia todos los archivos de `k8s/overlays/dev/` a `k8s/overlays/{AMBIENTE}/` y aplica estos reemplazos en el contenido de cada archivo YAML:

**En archivos `dapr/**/pubsub.yaml` y `dapr/**/secretstore.yaml`:**
- `value: {PROJECT_ID_DEV}` → `value: {PROJECT_ID}`

**En archivos `routes/*.yaml`:**
- `name: {GATEWAY_NAME_DEV}` → `name: {GATEWAY_NAME}`
  (donde `GATEWAY_NAME_DEV` se lee de `environments/dev.yaml` → `.gateway.name`)

**El resto de archivos** (healthcheck, import-map, cron bindings) se copian sin modificar.

---

### Paso 4 — Mostrar resumen

```
✅ GENERADO para ambiente {AMBIENTE}:

  terraform/environments/{AMBIENTE}/main.tf
  .github/workflows/infra-pipeline-{AMBIENTE}.yml
  k8s/overlays/{AMBIENTE}/
    dapr/*/* (pubsub, secretstore, statestore, crons)
    routes/*
    healthcheck/*
    import-map/

⚠️  PASOS MANUALES REQUERIDOS:

  1. Verificar que el proyecto GCP {PROJECT_ID} existe y tiene APIs habilitadas.

  2. Ejecutar bootstrap si es la primera vez con este proyecto:
       cd terraform/bootstrap
       terraform apply -var="project_id={PROJECT_ID}"

  3. Crear SA de deploy (si no existe):
       gcloud iam service-accounts create {DEPLOY_SA} --project={PROJECT_ID}

  4. Para cada servicio: crear el secret de conexión DB en el nuevo proyecto.
     IMPORTANTE — verificar el nombre real del secret antes de codificarlo en el pipeline:
       gcloud secrets list --project={PROJECT_ID} --filter="name:{AMBIENTE}"
     Convención QA: prefijo corto (`baseconfig`, `tprt`, `acct`) no el nombre del servicio completo.
     Crear si no existe:
       gcloud secrets create {servicio-corto}-{AMBIENTE}-db-connection \
         --project={PROJECT_ID} --data-file=-

  5. Commit + merge a main → el pipeline infra-pipeline-{AMBIENTE}.yml se dispara (Terraform apply).

  6. CRÍTICO — Instalar Dapr en el cluster (primera vez):
     El job k8s-manifests salta cuando no hay cambios K8s. Para forzarlo:
       gh workflow run infra-pipeline-{AMBIENTE}.yml --ref main
     Sin esto, los deploys de servicios fallan con:
       "no matches for kind Configuration in version dapr.io/v1alpha1"

  7. Aplicar DDL de grants en el nuevo Cloud SQL para cada servicio:
       /sa-onboard-db {schema} {owner-role}
```
