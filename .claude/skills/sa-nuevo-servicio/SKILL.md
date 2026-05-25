---
name: sa-nuevo-servicio
description: 'Adds a new service to this transversal, generating every artifact needed in the deploy repo plus the CI/CD file ready to drop into the services own repo. Supports fullstack, backend-only, or frontend-only modes via flags. Use whenever the user wants to onboard a new service into the deploy infrastructure.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Agrega un nuevo servicio a esta transversal. Genera todos los artefactos necesarios en el repo deploy y el archivo CI/CD listo para copiar al repo del servicio.

**Uso:** `/sa-nuevo-servicio {nombre} [api-port] [mfe-port] [--no-mfe] [--no-api]`

- Ambos puertos → servicio fullstack (backend + MFE)
- Solo `api-port` con `--no-mfe` → servicio backend puro (sin MFE)
- Solo `mfe-port` con `--no-api` → servicio frontend puro (sin API backend, ej: app-shell)

**Ejemplos:**
- `/sa-nuevo-servicio treasury 7022 8022`           ← fullstack
- `/sa-nuevo-servicio payroll 7024 --no-mfe`        ← backend puro
- `/sa-nuevo-servicio app-shell 8000 --no-api`      ← frontend puro

---

## Instrucciones

Los argumentos son: `$ARGUMENTS`

### PRINCIPIO FUNDAMENTAL — El estándar siempre prevalece

**Cada artefacto generado por este flow SOBREESCRIBE lo que exista**, sin preguntar. Si el servicio ya existe parcialmente, sus artefactos se actualizan al estándar actual. Nada del estándar anterior se conserva por inercia.

- Archivos K8s → se sobreescriben con Write si difieren del template
- `environments/dev.yaml` y `environments/shared.yaml` → se actualizan si la entrada ya existe
- `ci-pipeline.yml` en el repo del servicio → se sobreescribe siempre con el template actual
- `cloudbuild-deploy.yaml` u otros artefactos del estándar anterior → se eliminan del repo del servicio si existen

La única excepción son acciones que puedan dejar un servicio sin desplegar en producción (como eliminar un deployment activo o borrar un secret en uso). En esos casos, sí se pregunta antes de actuar.

---

Parsea los argumentos:
- Detecta flags primero: `HAS_MFE` = `false` si `--no-mfe` está presente, `true` en caso contrario. `HAS_API` = `false` si `--no-api` está presente, `true` en caso contrario.
- `NOMBRE` = primer argumento posicional (sin contar flags)
- Si `HAS_API = true` y `HAS_MFE = true`: `API_PORT` = segundo arg, `MFE_PORT` = tercer arg
- Si `HAS_API = true` y `HAS_MFE = false` (--no-mfe): `API_PORT` = segundo arg, `MFE_PORT` = vacío
- Si `HAS_API = false` y `HAS_MFE = true` (--no-api): `API_PORT` = vacío, `MFE_PORT` = segundo arg

Lee `environments/dev.yaml` para obtener:
- `PROJECT_ID` = `.gcp.project_id`
- `PROJECT_NUM` = `.gcp.project_number`
- `REGION` = `.gcp.region`
- `GATEWAY_NAME` = `.gateway.name`
- `SUITE` = `.naming.product_suite`
- `BUSINESS_UNIT` = `.naming.business_unit`
- `GKE_CLUSTER` = `.gke.cluster_name`
- `WORKER_POOL` = `.cloud_build.worker_pool`

Si `PROJECT_NUM` contiene `<PLACEHOLDER>` o está vacío, resuélvelo con Bash antes de continuar:
```bash
gcloud projects describe {PROJECT_ID} --format='value(projectNumber)'
```
Si el comando falla, detente y pide al usuario que complete `gcp.project_number` en `environments/dev.yaml`.

Lee `environments/shared.yaml` para obtener:
- `HUB_PROJECT` = `.hub.project_id` (Hub donde vive el Artifact Registry)

Calcula:
- `SA_SHORT` = `NOMBRE` con hyphens removidos, truncado a 10 caracteres (ej: `treasury` → `treasury`, `third-party` → `thirdparty`)
- `SA_NAME` = `sa-sie-{SUITE}-{SA_SHORT}-cicd`
- `GITHUB_REPO` = `SiesaTeams/business-{BUSINESS_UNIT}-{NOMBRE}-service`

---

### Fase A — Validación previa (ejecutar antes de generar artefactos)

#### A1 — API Guard: Habilitar APIs obligatorias

```bash
gcloud services enable \
  container.googleapis.com \
  sqladmin.googleapis.com \
  pubsub.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  --project={PROJECT_ID}
```

Opcional según stack:
```bash
# Cloud Run (si aplica)
gcloud services enable run.googleapis.com --project={PROJECT_ID}
# Firestore
gcloud services enable firestore.googleapis.com --project={PROJECT_ID}
# Redis/Memorystore (PROD)
gcloud services enable redis.googleapis.com --project={PROJECT_ID}
```

#### A2 — Workload Identity Binding

El SA `{SA_NAME}` y su binding WIF se crean automáticamente vía Terraform tras agregar el servicio a `environments/shared.yaml` y ejecutar `infra-pipeline-shared`. Verificar que existen antes del primer CI/CD:

```bash
gcloud iam service-accounts describe {SA_NAME}@{PROJECT_ID}.iam.gserviceaccount.com \
  --project={PROJECT_ID}
```

Si falta el SA, es señal de que el pipeline `infra-pipeline-shared` no ha aplicado aún — no continuar hasta que esté aplicado.

#### A3 — Production-Ready Checklist

Verificar en el repo `{GITHUB_REPO}` antes de generar artefactos:

- [ ] **Secrets:** Solo Secret Manager. **PROHIBIDO** variables de entorno para datos sensibles. Usar `{NOMBRE}-dev-db-connection` (convención esta transversal) o `sec-sie-{NOMBRE}-dev-db` (estándar org).
- [ ] **Estructura K8s:** `k8s/base/` + `k8s/overlays/{env}/` presentes en el repo del servicio.
- [ ] **Migraciones:** Framework containerizado (EF Core `MigrateAsync`, Prisma, Liquibase). **PROHIBIDO** migraciones manuales o SQL suelto.

Si algún punto no se cumple, detener y coordinar con el equipo antes de continuar.

---

Luego genera los siguientes artefactos **en este orden**, creando o sobreescribiendo cada archivo con Write:

---

### Paso 1 — `k8s/overlays/dev/dapr/{NOMBRE}/pubsub.yaml`

```yaml
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: pubsub
  namespace: {NOMBRE}
spec:
  type: pubsub.gcp.pubsub
  version: v1
  metadata:
    - name: projectId
      value: {PROJECT_ID}
    - name: disableEntityManagement
      value: "true"
```

### Paso 2 — `k8s/overlays/dev/dapr/{NOMBRE}/secretstore.yaml`

```yaml
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: secretstore
  namespace: {NOMBRE}
spec:
  type: secretstores.gcp.secretmanager
  version: v1
  metadata:
    - name: projectId
      value: {PROJECT_ID}
```

### Paso 3 — `k8s/overlays/dev/routes/{NOMBRE}-route.yaml`

El contenido del route depende de qué componentes tiene el servicio:

**Si HAS_API = true Y HAS_MFE = true (fullstack):**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {NOMBRE}-route
  namespace: {NOMBRE}
  labels:
    app.kubernetes.io/name: {NOMBRE}
    app.kubernetes.io/part-of: {BUSINESS_UNIT}-platform
spec:
  parentRefs:
    - name: {GATEWAY_NAME}
      namespace: gateway-infra
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mfe/{NOMBRE}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: {NOMBRE}-mfe
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /api/{NOMBRE}/health
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /health
      backendRefs:
        - name: {NOMBRE}-api
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /api/{NOMBRE}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /api/v1
      backendRefs:
        - name: {NOMBRE}-api
          port: 8080
```

**Si HAS_API = true Y HAS_MFE = false (backend puro, --no-mfe):**
Omitir el bloque de regla MFE (`/mfe/{NOMBRE}`). Incluir solo las dos reglas de `/api/{NOMBRE}`.

**Si HAS_API = false Y HAS_MFE = true (frontend puro, --no-api):**
Incluir solo la regla del MFE (`/mfe/{NOMBRE}`). Omitir las dos reglas de `/api/{NOMBRE}`.

### Paso 4 — `k8s/overlays/dev/healthcheck/{NOMBRE}-api-hc.yaml` (solo si HAS_API)

Generar este archivo únicamente si `HAS_API = true`.

```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: {NOMBRE}-api-hc
  namespace: {NOMBRE}
spec:
  default:
    checkIntervalSec: 15
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: TCP
      tcpHealthCheck:
        port: 8080
  targetRef:
    group: ""
    kind: Service
    name: {NOMBRE}-api
```

### Paso 5 — `k8s/overlays/dev/healthcheck/{NOMBRE}-mfe-hc.yaml` (solo si HAS_MFE)

```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: {NOMBRE}-mfe-hc
  namespace: {NOMBRE}
spec:
  default:
    checkIntervalSec: 15
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: TCP
      tcpHealthCheck:
        port: 80
  targetRef:
    group: ""
    kind: Service
    name: {NOMBRE}-mfe
```

### Paso 6 — Actualizar `environments/dev.yaml`

Lee el archivo actual. Si ya existe la entrada para `{NOMBRE}` bajo `services:`, sobreescríbela con los valores calculados. Si no existe, agrégala. Mismo criterio para `namespaces:`.

```yaml
  {NOMBRE}:
    sa_name: {SA_NAME}
    github_repo: {GITHUB_REPO}
    description: "Docker images for {NOMBRE} service"
```

Agrega `- {NOMBRE}` a la lista `namespaces:` si no está ya.

### Paso 7 — Actualizar `environments/shared.yaml`

Lee el archivo actual. Si ya existe la entrada para `{NOMBRE}` bajo `services:`, sobreescríbela con los valores calculados. Si no existe, agrégala.

```yaml
  {NOMBRE}:
    sa_name: {SA_NAME}
    github_repo: {GITHUB_REPO}
    description: "Docker images for {NOMBRE} service"
    roles:
      - roles/cloudbuild.builds.editor
      - roles/artifactregistry.writer
      - roles/container.developer
      - roles/secretmanager.secretAccessor
      - roles/cloudsql.client
      - roles/cloudbuild.workerPoolUser
      - roles/clouddeploy.releaser
      - roles/iam.serviceAccountUser
      - roles/storage.admin
      - roles/pubsub.publisher
      - roles/pubsub.subscriber
```

### Paso 8 — Actualizar `k8s/overlays/dev/import-map/import-map.yaml` (solo si HAS_MFE)

Lee el archivo actual. Agrega al JSON de imports si no está ya:
```json
"@siesa/{NOMBRE}": "/mfe/{NOMBRE}/spa-entry.js"
```

### Paso 9 — Generar y aplicar el CI/CD pipeline en el repo del servicio

**El pipeline se sobreescribe siempre. El estándar prevalece sobre cualquier pipeline anterior.**

#### 9a — Detectar estructura del repo del servicio

Calcula `LOCAL_REPO_PATH` = directorio padre de este repo + `/{GITHUB_REPO última parte}`.
- Ejemplo: deploy en `~/SiesaTeams/business-financiero-deploy` + `GITHUB_REPO = SiesaTeams/business-financiero-segments-service` → `LOCAL_REPO_PATH = ~/SiesaTeams/business-financiero-segments-service`

Si el repo no está clonado localmente, clónalo:
```bash
git clone https://github.com/{GITHUB_REPO}.git {LOCAL_REPO_PATH}
```

Detecta las rutas de Dockerfile ejecutando:
```bash
# API Dockerfile
if [ -f "{LOCAL_REPO_PATH}/api/Dockerfile" ]; then
  echo "API_DOCKERFILE=api/Dockerfile"
  echo "API_CONTEXT=api/"
elif [ -f "{LOCAL_REPO_PATH}/src/backend/Dockerfile" ]; then
  echo "API_DOCKERFILE=src/backend/Dockerfile"
  echo "API_CONTEXT=."
fi

# MFE Dockerfile
if [ -f "{LOCAL_REPO_PATH}/mfe/Dockerfile" ]; then
  echo "MFE_DOCKERFILE=mfe/Dockerfile"
  echo "MFE_CONTEXT=mfe/"
elif [ -f "{LOCAL_REPO_PATH}/src/frontend/Dockerfile" ]; then
  echo "MFE_DOCKERFILE=src/frontend/Dockerfile"
  echo "MFE_CONTEXT=src/frontend"
fi

# ¿Necesita build args de GitHub Packages?
grep -l "NUGET_GITHUB_TOKEN\|NPM_GITHUB_TOKEN" \
  {LOCAL_REPO_PATH}/src/backend/Dockerfile \
  {LOCAL_REPO_PATH}/api/Dockerfile \
  {LOCAL_REPO_PATH}/src/frontend/Dockerfile \
  {LOCAL_REPO_PATH}/mfe/Dockerfile 2>/dev/null && echo "NEEDS_GITHUB_PACKAGES=true"
```

Con estos valores, construye el pipeline adaptado.

#### 9b — Eliminar artefactos del estándar anterior

Si el repo del servicio tiene `cloudbuild-deploy.yaml` en la raíz, eliminarlo:
```bash
rm -f {LOCAL_REPO_PATH}/cloudbuild-deploy.yaml
```

Si tiene `cloudbuild-sandbox.yaml`, eliminarlo también:
```bash
rm -f {LOCAL_REPO_PATH}/cloudbuild-sandbox.yaml
```

#### 9c — Construir el pipeline estándar

Lee `cicd-templates/.github/workflows/ci-pipeline.yml` como base. Genera el pipeline final con:

1. **Sección `env:`** — siempre estos valores:
```yaml
env:
  PROJECT_ID: {PROJECT_ID}
  HUB_PROJECT_ID: {HUB_PROJECT}
  PROJECT_NUM: "{PROJECT_NUM}"
  REGION: {REGION}
  GKE_CLUSTER: {GKE_CLUSTER}
  WORKER_POOL: {WORKER_POOL}
  SERVICE_NAME: {NOMBRE}
  NAMESPACE: {NOMBRE}
  BUILD_API: "{HAS_API}"
  BUILD_MFE: "{HAS_MFE}"
  VITE_MODE: development
```

2. **Sección `permissions:`** — siempre incluir `packages: read`:
```yaml
permissions:
  contents: read
  id-token: write
  packages: read
```

3. **Paso "Build & Push API image"** — adaptar rutas según detección:

Si `API_DOCKERFILE = api/Dockerfile`:
```yaml
- name: Build & Push API image
  if: env.BUILD_API == 'true'
  run: |
    IMAGE="${{ env.REGION }}-docker.pkg.dev/${{ env.HUB_PROJECT_ID }}/art-fin-shared/${{ env.SERVICE_NAME }}/${{ env.SERVICE_NAME }}-api"
    docker build -t ${IMAGE}:${{ github.sha }} -f api/Dockerfile api/
    docker push ${IMAGE}:${{ github.sha }}
```

Si `API_DOCKERFILE = src/backend/Dockerfile`:
```yaml
- name: Build & Push API image
  if: env.BUILD_API == 'true'
  run: |
    IMAGE="${{ env.REGION }}-docker.pkg.dev/${{ env.HUB_PROJECT_ID }}/art-fin-shared/${{ env.SERVICE_NAME }}/${{ env.SERVICE_NAME }}-api"
    docker build \
      --build-arg NUGET_GITHUB_USER=x-access-token \
      --build-arg NUGET_GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }} \
      -t ${IMAGE}:${{ github.sha }} \
      -f src/backend/Dockerfile .
    docker push ${IMAGE}:${{ github.sha }}
```

4. **Paso "Build & Push MFE image"** — adaptar rutas según detección:

Si `MFE_DOCKERFILE = mfe/Dockerfile`:
```yaml
- name: Build & Push MFE image
  if: env.BUILD_MFE == 'true'
  run: |
    IMAGE="${{ env.REGION }}-docker.pkg.dev/${{ env.HUB_PROJECT_ID }}/art-fin-shared/${{ env.SERVICE_NAME }}/${{ env.SERVICE_NAME }}-mfe"
    docker build \
      --build-arg VITE_MODE=${{ env.VITE_MODE }} \
      -t ${IMAGE}:${{ github.sha }} \
      -f mfe/Dockerfile mfe/
    docker push ${IMAGE}:${{ github.sha }}
```

Si `MFE_DOCKERFILE = src/frontend/Dockerfile`:
```yaml
- name: Build & Push MFE image
  if: env.BUILD_MFE == 'true'
  run: |
    IMAGE="${{ env.REGION }}-docker.pkg.dev/${{ env.HUB_PROJECT_ID }}/art-fin-shared/${{ env.SERVICE_NAME }}/${{ env.SERVICE_NAME }}-mfe"
    docker build \
      --build-arg NPM_GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }} \
      --build-arg VITE_MODE=${{ env.VITE_MODE }} \
      -t ${IMAGE}:${{ github.sha }} \
      -f src/frontend/Dockerfile src/frontend
    docker push ${IMAGE}:${{ github.sha }}
```

5. El resto del pipeline (secciones Deploy via Cloud Build y Smoke test) se toma intacto del template.

Guarda el pipeline generado en `/tmp/ci-pipeline-{NOMBRE}.yml` y también en:
```
{LOCAL_REPO_PATH}/.github/workflows/ci-pipeline.yml
```

#### 9d — Commit y push al repo del servicio

```bash
cd {LOCAL_REPO_PATH}
git checkout develop
git add .github/workflows/ci-pipeline.yml
# Si se eliminaron artefactos del estándar anterior:
git add -u cloudbuild-deploy.yaml cloudbuild-sandbox.yaml 2>/dev/null || true
git commit -m "ci: migrar a pipeline estándar build & deploy DEV

- Imagen: Hub AR (prj-sie-sb-fin-common/art-fin-shared/{NOMBRE})
- Deploy: Cloud Build config inline (sin cloudbuild-deploy.yaml externo)
- Tag: SHA completo del commit"
git push origin develop
```

---

### Paso 10 — Mostrar resumen

```
✅ GENERADO/ACTUALIZADO AUTOMÁTICAMENTE:
  k8s/overlays/dev/dapr/{NOMBRE}/pubsub.yaml
  k8s/overlays/dev/dapr/{NOMBRE}/secretstore.yaml
  k8s/overlays/dev/routes/{NOMBRE}-route.yaml
  [k8s/overlays/dev/healthcheck/{NOMBRE}-api-hc.yaml]  (si HAS_API)
  [k8s/overlays/dev/healthcheck/{NOMBRE}-mfe-hc.yaml]  (si HAS_MFE)
  environments/dev.yaml  ← service + namespace
  environments/shared.yaml  ← service + roles IAM
  [k8s/overlays/dev/import-map/import-map.yaml]  (si HAS_MFE)
  {LOCAL_REPO_PATH}/.github/workflows/ci-pipeline.yml  ← pipeline estándar aplicado

⚠️  PASOS MANUALES REQUERIDOS (en orden):

  0. Ejecutar Fase A — Validación previa:
     - API Guard: habilitar APIs en {PROJECT_ID}
     - Confirmar WI Binding existente para {SA_NAME}
     - Verificar Production-Ready checklist en {GITHUB_REPO}

  1. Puertos locales — agregar en docs/developer-guide.md:
     {NOMBRE}: [API {API_PORT}]  (si HAS_API) / [MFE {MFE_PORT}]  (si HAS_MFE)

  [Si HAS_API = true]
  2. Secret Manager — crear antes del primer CI/CD:
     gcloud secrets create {NOMBRE}-dev-db-connection \
       --project={PROJECT_ID} \
       --data-file=<(echo "Host=127.0.0.1;Port=5432;Database=finance-dev;Username=dev;Password=CHANGE_ME")

     ⚠️  Naming: esta transversal usa `{NOMBRE}-dev-db-connection`.
         Estándar org: `sec-sie-{NOMBRE}-dev-db`. Referenciar desde Secret Manager en
         ambos casos — nunca pasar contraseñas como variable de entorno plana.

  [Si HAS_API = true]
  3. Cloud SQL — ejecutar DDL de grants (usar /sa-onboard-db {schema} {owner-role}):
     Reemplaza {schema} con el nombre del schema PostgreSQL del servicio.

  4. Registrar permisos en access-manager (usar /sa-registrar-permisos):
     Después del primer deploy exitoso. Solo aplica si HAS_API = true.

  5. Commit en este repo deploy + push a main → infra-pipeline-dev disparará automáticamente.

  6. Artefactos inmutables — verificar en el pipeline:
     - Docker images se etiquetan con el SHA completo del commit (inmutables por diseño).
     - NUNCA re-buildear el mismo código para distintos ambientes.
     - Para QAS/PROD: promover el digest existente de dev — no hacer nuevo build.
```
