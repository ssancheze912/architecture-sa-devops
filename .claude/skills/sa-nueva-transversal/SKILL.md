---
name: sa-nueva-transversal
description: 'Generates the full scaffolding for a new transversal deploy repo (e.g. comercial, manufactura). Produces every base file the new business-{name}-deploy repo needs, with zero financial-specific content. Use whenever the user is setting up a brand-new transversal and needs the deploy-repo skeleton.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Genera el scaffolding completo para un nuevo repo de transversal (ej: comercial, manufactura). Produce los archivos base que deben ir en el nuevo repo `business-{nombre}-deploy`, sin nada específico de financiero.

**Uso:** `/sa-nueva-transversal {nombre} {suite} {project-id-dev}`

**Ejemplo:** `/sa-nueva-transversal comercial com prj-sie-com-comercial-dev`

---

## Instrucciones

Los argumentos son: `$ARGUMENTS`

Parsea los argumentos:
- `NOMBRE` = primer argumento (ej: `comercial`)
- `SUITE` = segundo argumento, 2-4 caracteres (ej: `com`)
- `PROJECT_ID` = tercer argumento (ej: `prj-sie-com-comercial-dev`)

Deriva:
- `REPO_NAME` = `business-{NOMBRE}-deploy`
- `REGION` = `us-east1` (default para todos los proyectos Siesa)
- `HUB_PROJECT` = `prj-sie-sb-{NOMBRE}-common`
- `STATE_BUCKET` = `bkt-sie-{SUITE}-iac-state-{PROJECT_ID}`

**Valores que debes obtener antes de generar archivos** (usar Bash — son lecturas de solo lectura, no modifican infraestructura):

```bash
# Project number — necesario para WIF provider URL y ARs IAM members
gcloud projects describe {PROJECT_ID} --format='value(projectNumber)'
```

Si el comando falla (proyecto no existe aún), usa `<PLACEHOLDER: project_number>` y avisa al usuario.
Guarda el resultado como `PROJECT_NUM`.

---

### Paso 0 — Validación inicial (Gate)

**Naming convention:** Verifica que `PROJECT_ID` siga el patrón `{type}-sie-{bu}-{workload}-{env}` (regex: `^[a-z]+-sie-[a-z]+-[a-z]+-[a-z]+$`). Si no cumple, detente y muestra el error con el valor recibido.

**GCS state prefix:** Muestra el bucket calculado `{STATE_BUCKET}` y advierte que debe ser único — no puede existir otro estado con el mismo nombre. Pide confirmación antes de continuar.

---

### Paso 1 — Verificación Hub Project

Informa al usuario y detente hasta recibir confirmación:

```
🔍 HUB PROJECT CHECK

Verifica si el proyecto Hub ya existe:
  gcloud projects describe {HUB_PROJECT} 2>&1

Si NO existe, crearlo primero:
  gcloud projects create {HUB_PROJECT} \
    --name="SIESA {NOMBRE} Common" \
    --folder=<FOLDER_ID_BU>

  # Habilitar APIs del Hub:
  gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    clouddeploy.googleapis.com \
    --project={HUB_PROJECT}

⚠️  El Hub project debe existir antes de vender Spokes (Hub-First Mandate).
    Confirma que existe para continuar.
```

---

### Paso 2 — Asignación IP desde ip-plan.md

Lee `docs/devops-org/ip-plan.md`.

**A. Identificar el siguiente Slice Index libre** en la tabla §3.1 (fila con `FREE SLOT` o índice no asignado).
Sea `INDEX` el índice libre identificado.

**B. Calcular CIDRs para Development** usando la fórmula de §4:
- `PRIMARY_CIDR` = `10.4.{INDEX*8}.0/21`
- `PODS_CIDR` = `100.{64 + floor(INDEX*64/256)}.{(INDEX*64) mod 256}.0/18`
- `SERVICES_CIDR` = `100.100.{INDEX*8}.0/21`
- `MASTER_CIDR` = `172.16.{INDEX}.0/28` (Dev Env Octet = 16, fórmula §5.1)

**C. Validar zero-overlap:** Confirma que ninguno de los 3 CIDRs se superpone con rangos existentes en §3.1. Si hay overlap, seleccionar el siguiente índice libre.

**D. Proponer actualización de ip-plan.md — REGISTRY-FIRST:**

Muestra el bloque markdown a insertar en la tabla §3.1:
```
| {INDEX} | **{SUITE}** | {NOMBRE} | `us-east1` | `{PRIMARY_CIDR}` | `{PODS_CIDR}` | `{SERVICES_CIDR}` |
```

Detente y solicita confirmación:
```
⚠️  REGISTRY-FIRST: Agrega la fila anterior a docs/devops-org/ip-plan.md §3.1
    y haz commit antes de continuar. Ningún código Terraform puede generarse
    sin una reserva de IP registrada.
```

---

### Qué generar y qué NO generar

(solo continuar si el usuario confirmó Pasos 0, 1 y 2)

**NO generar** (específico de financiero, construir desde cero):
- Ningún archivo de `k8s/overlays/dev/`
- Ningún servicio en `environments/dev.yaml` ni `environments/shared.yaml`
- Ningún contenido de `docs/`

**SÍ generar:**
- `environments/dev.yaml`
- `environments/shared.yaml`
- `environments/staging.yaml`
- `environments/prod.yaml`
- `terraform/environments/dev/main.tf`
- `terraform/environments/shared/main.tf`
- `.github/workflows/infra-pipeline-dev.yml`
- `.github/workflows/infra-pipeline-shared.yml`

---

### Archivo 1 — `environments/dev.yaml` para {REPO_NAME}

Usa como base `environments/dev.yaml` de este repo. Reemplaza:
- `financiero` → `{NOMBRE}`
- `fin` (product_suite) → `{SUITE}`
- `prj-sie-fin-financiero-dev` → `{PROJECT_ID}`
- `gke-sie-fin-sandbox-dev` → `gke-sie-{SUITE}-{NOMBRE}-dev`
- `pgsql-fin-sandbox-dev` → `pgsql-{SUITE}-{NOMBRE}-dev`
- `finance-dev` → `{NOMBRE}-dev`
- `finance.siesacloud.dev` → `{NOMBRE}.siesacloud.dev`
- `financiero-dev-gateway` → `{NOMBRE}-dev-gateway`
- `finance-siesacloud-dev-cert` → `{NOMBRE}-siesacloud-dev-cert`
- `finance-siesacloud-dev-map` → `{NOMBRE}-siesacloud-dev-map`
- `bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev` → `{STATE_BUCKET}`
- `sa-sie-fin-sandbox-dev-cicd` → `sa-sie-{SUITE}-{NOMBRE}-dev-cicd`
- `financiero-pool` → `{NOMBRE}-pool`
- Vaciar `services:` y `namespaces:` (solo gateway-infra, app-shell, observability)
- Grupos IAM → `<PLACEHOLDER: group:g-gcp-fld-sie-bus-{NOMBRE}-dev-admins@siesacloud.com>`
- `alert_email` → `<PLACEHOLDER: alertas-{NOMBRE}@siesa.com>`

Agrega la sección de red con los CIDRs calculados en el Paso 2:
```yaml
network:
  primary_cidr: "{PRIMARY_CIDR}"
  pods_cidr: "{PODS_CIDR}"
  services_cidr: "{SERVICES_CIDR}"
  master_cidr: "{MASTER_CIDR}"
  shared_vpc_host: "prj-sie-com-vpc-host-dev"
  subnetwork: "<PLACEHOLDER: snt-sie-{SUITE}-use1-01-dev>"
```

### Archivo 2 — `environments/shared.yaml` para {REPO_NAME}

Mismo proceso de reemplazo que dev.yaml pero con estructura de `environments/shared.yaml`. Sección `services:` vacía.

**Agrega obligatoriamente la sección `hub:`** con el proyecto Hub donde vivirá el Artifact Registry. Esto permite que dev, QA y PROD compartan las mismas imágenes:

```yaml
# --- Hub Project (Artifact Registry centralizado) ---
# Las imágenes Docker se publican aquí para ser compartidas entre ambientes.
# NUNCA crear AR repos en el Spoke — impediría promoción de imágenes entre entornos.
hub:
  project_id: "{HUB_PROJECT}"
```

**Modifica también la sección `gcp:` del shared.yaml:** el `project_id` es el Spoke dev (donde viven WIF pool, SAs, Worker Pool). El Hub solo aplica para AR repos:

```yaml
gcp:
  project_id: "{PROJECT_ID}"   # Spoke dev — WIF, SAs, Worker Pool
  region: "{REGION}"

hub:
  project_id: "{HUB_PROJECT}"  # Hub — Artifact Registry repos (compartido entre ambientes)
```

### Archivo 3 — `terraform/environments/dev/main.tf` para {REPO_NAME}

Lee `terraform/environments/dev/main.tf`. Reemplaza:
- Bucket de estado → `{STATE_BUCKET}`
- Comentarios que mencionen "financiero" → `{NOMBRE}`

**Agrega mandatory labels** en el bloque `locals`:
```hcl
locals {
  common_labels = {
    business-unit = var.config.naming.business_unit
    product-suite = var.config.naming.product_suite
    environment   = "dev"
    cost-center   = "${var.config.naming.product_suite}-dev"
  }
}
```

**Agrega referencia al Shared VPC Host** en el módulo GKE (solo como referencia, no modificar el Host VPC):
```hcl
# Shared VPC — solo referenciar, NUNCA modificar recursos del Host project
# Host project Dev: prj-sie-com-vpc-host-dev
network    = "projects/${var.config.network.shared_vpc_host}/global/networks/vpc-sie-com-shared-host-dev"
subnetwork = "projects/${var.config.network.shared_vpc_host}/regions/${var.config.gcp.region}/subnetworks/${var.config.network.subnetwork}"
```

### Archivo 4 — `terraform/environments/shared/main.tf` para {REPO_NAME}

Igual pero con estructura del shared, reemplazando el bucket de estado.

### Archivo 5 — `.github/workflows/infra-pipeline-dev.yml` para {REPO_NAME}

Lee `.github/workflows/infra-pipeline-dev.yml` de este repo. Reemplaza:
- `Infrastructure Pipeline — Dev` → `Infrastructure Pipeline — Dev ({NOMBRE})`

**Agrega los siguientes steps al job `terraform-plan`, DESPUÉS de `terraform validate` y ANTES de `terraform plan`:**

```yaml
      - name: Security SAST — tfsec
        run: |
          curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
          tfsec terraform/environments/dev/ --no-color --soft-fail

      - name: Security SAST — checkov
        run: |
          pip install checkov --quiet
          checkov -d terraform/environments/dev/ --quiet --compact --soft-fail

      - name: SIESA Guard — Host VPC inviolability
        run: |
          HOST_VPC_PROJECTS=(
            "prj-sie-com-vpc-host-dev" "prj-sie-com-vpc-host-qa" "prj-sie-com-vpc-host-prod"
            "prj-sie-sde-vpc-host-dev" "prj-sie-sde-vpc-host-qa" "prj-sie-sde-vpc-host-prod"
            "prj-sie-sde-leg-vpc-host-dev" "prj-sie-sde-leg-vpc-host-qa" "prj-sie-sde-leg-vpc-host-prod"
            "prj-sie-leg-vpc-host-dev" "prj-sie-leg-vpc-host-qa" "prj-sie-leg-vpc-host-prod"
          )
          PLAN_OUT=$(terraform -chdir=terraform/environments/dev show -no-color tfplan 2>/dev/null || echo "")
          for HOST in "${HOST_VPC_PROJECTS[@]}"; do
            if echo "$PLAN_OUT" | grep -q "\"$HOST\""; then
              echo "❌ GUARD VIOLATION: el plan muta recursos en Host VPC project: $HOST"
              exit 1
            fi
          done
          echo "✅ SIESA Guard: sin mutaciones en Host VPC projects."
```

### Archivo 6 — `.github/workflows/infra-pipeline-shared.yml` para {REPO_NAME}

Igual que el dev con los mismos steps de seguridad, apuntando a `terraform/environments/shared/`.

---

### Paso final — Mostrar checklist de bootstrap

```
📦 SCAFFOLDING GENERADO para {REPO_NAME}

IP RESERVADA (agregar a docs/devops-org/ip-plan.md §3.1 si aún no se hizo):
  Slice Index: {INDEX}
  Primary:     {PRIMARY_CIDR}
  Pods:        {PODS_CIDR}
  Services:    {SERVICES_CIDR}
  Master /28:  {MASTER_CIDR}
  Shared VPC:  prj-sie-com-vpc-host-dev

ESTRUCTURA A COPIAR DE business-financiero-deploy (sin cambios):
  terraform/bootstrap/     → copiar completo
  terraform/modules/       → copiar completo
  k8s/base/               → copiar completo
  cicd-templates/          → copiar completo
  scripts/                 → copiar completo

ARCHIVOS GENERADOS:
  environments/dev.yaml          ← incluye CIDRs calculados + Shared VPC ref
  environments/shared.yaml
  environments/staging.yaml      (copiar de financiero sin cambios)
  environments/prod.yaml         (copiar de financiero sin cambios)
  terraform/environments/dev/main.tf    ← mandatory labels + Shared VPC
  terraform/environments/shared/main.tf
  .github/workflows/infra-pipeline-dev.yml    ← tfsec + checkov + SIESA Guard
  .github/workflows/infra-pipeline-shared.yml

PASOS PARA ACTIVAR EL NUEVO REPO:

  0. Confirmar Hub project {HUB_PROJECT} existe (Paso 1).
     Si no: crear + habilitar AR, Cloud Build, Cloud Deploy APIs.

  1. Crear repo GitHub: SiesaTeams/{REPO_NAME}

  2. Crear proyecto GCP Spoke:
       gcloud projects create {PROJECT_ID} --name="SIESA {NOMBRE} Dev"

  3. Ejecutar bootstrap:
       cd terraform/bootstrap
       terraform init && terraform apply -var="project_id={PROJECT_ID}"

  4. Completar <PLACEHOLDER> en environments/dev.yaml:
     - project_number:
         gcloud projects describe {PROJECT_ID} --format='value(projectNumber)'
     - network.subnetwork: coordinar con Cloud Admin — Shared VPC Host
     - dev_access groups: crear en Google Workspace

  5. Crear SA de deploy:
       gcloud iam service-accounts create sa-sie-{SUITE}-{NOMBRE}-dev-cicd \
         --project={PROJECT_ID}

  6. Primer push a main → pipelines se disparan automáticamente.
     tfsec + checkov + SIESA Guard corren en cada PR.

  7. Agregar servicios con /sa-nuevo-servicio
```
