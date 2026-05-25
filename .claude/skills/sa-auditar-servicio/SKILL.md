---
name: sa-auditar-servicio
description: 'Audits an existing service in this transversal, verifying every deploy-repo artifact is present and correct, detects architectural drift, and generates an updated ci-pipeline.yml aligned with the current standard. Use whenever the user wants to check whether a deployed services artifacts match the current standard or asks for a service audit.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Audita un servicio existente en esta transversal. Verifica que todos los artefactos en el repo de deploy estén presentes y correctos, detecta desalineaciones arquitectónicas y genera el `ci-pipeline.yml` alineado con el estándar actual. Al finalizar pregunta si corregir los gaps encontrados.

**Uso:** `/sa-auditar-servicio {nombre} [--no-mfe]`

**Ejemplos:**
- `/sa-auditar-servicio segments`
- `/sa-auditar-servicio liquid-tax --no-mfe`

---

## Instrucciones

Los argumentos son: `$ARGUMENTS`

Parsea:
- `NOMBRE` = primer argumento (ej: `segments`)
- `HAS_MFE` = `false` si `--no-mfe` está presente, `true` en caso contrario

Lee `environments/dev.yaml` para obtener:
- `PROJECT_ID` = `.gcp.project_id`
- `PROJECT_NUM` = `.gcp.project_number`
- `REGION` = `.gcp.region`
- `GKE_CLUSTER` = `.gke.cluster_name`
- `WORKER_POOL` = `.cloud_build.worker_pool`
- `SUITE` = `.naming.product_suite`
- `BUSINESS_UNIT` = `.naming.business_unit`
- `GATEWAY_NAME` = `.gateway.name`
- `DOMAIN` = `.dns.domain`
- `VITE_MODE` = `.frontend.vite_mode`

Lee `environments/shared.yaml` para obtener:
- `HUB_PROJECT` = `.hub.project_id` (puede no existir — ver G-S3)
- `WIF_POOL` = `.wif.pool_name`

Calcula:
- `SA_SHORT` = `NOMBRE` sin hyphens, truncado a 10 caracteres
- `SA_NAME` = `sa-sie-{SUITE}-{SA_SHORT}-cicd`
- `GITHUB_REPO` = `SiesaTeams/business-{BUSINESS_UNIT}-{NOMBRE}-service`

---

## Fase 1 — Auditoría de artefactos en el deploy repo

Verifica la existencia de cada archivo con Read (intenta leer; si falla → MISSING):

### Dapr Components

| Archivo | Estado |
|---|---|
| `k8s/overlays/dev/dapr/{NOMBRE}/pubsub.yaml` | PASS / MISSING |
| `k8s/overlays/dev/dapr/{NOMBRE}/secretstore.yaml` | PASS / MISSING |

Para cada archivo que existe, verifica que `projectId` sea `{PROJECT_ID}`. Si no coincide → DRIFT.

### Gateway Route

| Archivo | Estado |
|---|---|
| `k8s/overlays/dev/routes/{NOMBRE}-route.yaml` | PASS / MISSING |

Si existe, verifica:
- `parentRefs[0].name` = `{GATEWAY_NAME}`
- Regla `/api/{NOMBRE}` tiene URLRewrite a `/api/v1`
- Si HAS_MFE: regla `/mfe/{NOMBRE}` presente

### Health Checks

| Archivo | Estado |
|---|---|
| `k8s/overlays/dev/healthcheck/{NOMBRE}-api-hc.yaml` | PASS / MISSING |
| `k8s/overlays/dev/healthcheck/{NOMBRE}-mfe-hc.yaml` (si MFE) | PASS / MISSING / N/A |

### environments/dev.yaml

Lee `environments/dev.yaml`. Verifica:
- `services.{NOMBRE}` existe → PASS / MISSING
- `{NOMBRE}` está en la lista `namespaces:` → PASS / MISSING
- Si existe el servicio, `sa_name` = `{SA_NAME}` y `github_repo` = `{GITHUB_REPO}` → PASS / DRIFT

### environments/shared.yaml

Lee `environments/shared.yaml`. Verifica:
- `services.{NOMBRE}` existe → PASS / MISSING
- Tiene los 11 roles estándar (cloudbuild.builds.editor, artifactregistry.writer, container.developer, secretmanager.secretAccessor, cloudsql.client, cloudbuild.workerPoolUser, clouddeploy.releaser, iam.serviceAccountUser, storage.admin, pubsub.publisher, pubsub.subscriber) → PASS / MISSING_ROLES
- `hub.project_id` existe en el archivo → PASS / MISSING (G-S3)

### Import Map (solo si HAS_MFE)

| Archivo | Estado |
|---|---|
| `k8s/overlays/dev/import-map/import-map.yaml` contiene `@siesa/{NOMBRE}` | PASS / MISSING |

---

## Fase 2 — Auditoría arquitectónica CI/CD

Evalúa los puntos conocidos de desalineación comparando contra el estándar del repo. No se lee el archivo del servicio (repo separado) — se audita contra los valores correctos y se genera la versión alineada.

### G-C1 — Cluster name
El pipeline debe usar `GKE_CLUSTER: {GKE_CLUSTER}` (valor del dev.yaml).
- WARN: mostrar el valor correcto — confirmar que el pipeline del servicio lo tenga exactamente así.

### G-C2 — Image URL (Hub vs Spoke)
- Si `HUB_PROJECT` existe en shared.yaml: el pipeline DEBE usar `HUB_PROJECT_ID: {HUB_PROJECT}` para la URL de imagen → WARN si no está.
- Si `HUB_PROJECT` NO existe (financiero actual): imagen va a `PROJECT_ID` (Spoke) — documentado como deuda técnica → INFO.

### G-C3 — Smoke test pattern
El template estándar usa `sleep 60` fijo. El patrón recomendado es un retry loop de 15s hasta 5 min (evita fallos cuando Dapr sidecar o NEGs tardan más de 60s).
- WARN siempre: mostrar el patrón correcto de retry loop.

### G-C4 — Concurrency group
El pipeline debe tener:
```yaml
concurrency:
  group: deploy-gke-${{ github.repository }}
  cancel-in-progress: false
```
- WARN: verificar que el pipeline del servicio lo tenga.

### G-C5 — GitHub environment
Debe usar `environment: dev` (no `sandbox`). El environment `sandbox` fue eliminado.
- WARN: confirmar que no use `sandbox`.

### G-C6 — WIF permissions
Debe tener:
```yaml
permissions:
  contents: read
  id-token: write
```
- WARN: verificar que estén presentes.

### G-C7 — SA name formula
El SA debe seguir el patrón `sa-sie-{SUITE}-{SA_SHORT}-cicd`.
- Mostrar: `{SA_NAME}` — confirmar que coincide con el pipeline del servicio.

---

## Fase 3 — Resumen de auditoría

Muestra el reporte consolidado:

```
════════════════════════════════════════════════════════
AUDITORÍA DE SERVICIO: {NOMBRE}
Transversal: {BUSINESS_UNIT} | Suite: {SUITE} | Repo: {GITHUB_REPO}
════════════════════════════════════════════════════════

ARTEFACTOS EN DEPLOY REPO:
  [PASS/MISSING/DRIFT] k8s/overlays/dev/dapr/{NOMBRE}/pubsub.yaml
  [PASS/MISSING/DRIFT] k8s/overlays/dev/dapr/{NOMBRE}/secretstore.yaml
  [PASS/MISSING]       k8s/overlays/dev/routes/{NOMBRE}-route.yaml
  [PASS/MISSING]       k8s/overlays/dev/healthcheck/{NOMBRE}-api-hc.yaml
  [PASS/MISSING/N/A]   k8s/overlays/dev/healthcheck/{NOMBRE}-mfe-hc.yaml
  [PASS/MISSING]       environments/dev.yaml → services.{NOMBRE}
  [PASS/MISSING]       environments/dev.yaml → namespaces
  [PASS/MISSING/DRIFT] environments/shared.yaml → services.{NOMBRE}
  [PASS/MISSING]       environments/shared.yaml → hub.project_id
  [PASS/MISSING/N/A]   import-map → @siesa/{NOMBRE}

CI/CD PIPELINE (verificar en {GITHUB_REPO}):
  [WARN/INFO] G-C1 Cluster name: debe ser {GKE_CLUSTER}
  [WARN/INFO] G-C2 Image URL: {mensaje según Hub o Spoke}
  [WARN]      G-C3 Smoke test: usar retry loop, no sleep fijo
  [WARN]      G-C4 Concurrency group: verificar presente
  [WARN]      G-C5 GitHub environment: debe ser "dev", no "sandbox"
  [WARN]      G-C6 WIF permissions: id-token: write requerido
  [INFO]      G-C7 SA name esperado: {SA_NAME}

────────────────────────────────────────────────────────
RESUMEN:
  Artefactos faltantes : N
  Artefactos con drift  : N
  Advertencias CI/CD    : N
════════════════════════════════════════════════════════
```

---

## Fase 4 — Corrección interactiva

Tras mostrar el resumen, pregunta:

```
¿Qué deseas corregir?

  [1] Crear artefactos faltantes en deploy repo (K8s, Dapr, routes, healthcheck)
  [2] Corregir artefactos con drift (projectId, sa_name, github_repo)
  [3] Agregar servicio a environments/dev.yaml y/o shared.yaml
  [4] Generar ci-pipeline.yml alineado para copiar a {GITHUB_REPO}
  [5] Todo lo anterior
  [0] Nada — solo quería ver el reporte

Responde con los números separados por coma (ej: 1,3,4) o 5 para todo:
```

Espera la respuesta del usuario y ejecuta solo las correcciones seleccionadas:

### Si incluye [1] — Crear artefactos faltantes
Genera los archivos MISSING usando el mismo formato que `/sa-nuevo-servicio` (Pasos 1-5 y 8).

### Si incluye [2] — Corregir drift
Lee el archivo con drift, actualiza los valores incorrectos y guarda.

### Si incluye [3] — Agregar a environments
Agrega la entrada del servicio en `dev.yaml` (services + namespaces) y `shared.yaml` (services + roles), si faltan.

### Si incluye [4] — Generar ci-pipeline.yml alineado
Lee `cicd-templates/.github/workflows/ci-pipeline.yml` para obtener la plantilla base completa y actual. Es la fuente de verdad del pipeline — no regenerar desde cero.

Sustituye únicamente la sección `env:` y corrige los puntos de desalineación encontrados en Fase 2:
- `GKE_CLUSTER: {GKE_CLUSTER}` (del dev.yaml — G-C1)
- `WORKER_POOL: {WORKER_POOL}` (del dev.yaml)
- `PROJECT_ID: {PROJECT_ID}` y (si aplica) `HUB_PROJECT_ID: {HUB_PROJECT}` (G-C2)
- `SERVICE_NAME: {NOMBRE}` y `NAMESPACE: {NOMBRE}`
- `BUILD_MFE: "{HAS_MFE}"`
- `VITE_MODE: {VITE_MODE}`
- Smoke test con retry loop de 15s hasta 5 min en lugar de `sleep` fijo (G-C3)
- Concurrency group correcto (G-C4)
- `environment: dev` (no `sandbox`) (G-C5)
- `permissions: id-token: write` presente (G-C6)
- SA name: `{SA_NAME}@{PROJECT_ID}.iam.gserviceaccount.com` (G-C7)

Muestra el archivo completo resultante listo para copiar a `.github/workflows/ci-pipeline.yml` del repo `{GITHUB_REPO}`.

### Si incluye [5] — Todo
Ejecuta 1, 2, 3 y 4 en ese orden.

---

## Smoke test — patrón correcto (usar en [4])

```yaml
- name: Smoke test
  run: |
    DEADLINE=$((SECONDS+300))
    until [ $SECONDS -ge $DEADLINE ]; do
      STATUS=$(curl -sk -o /dev/null -w "%{http_code}" https://{DOMAIN}/api/{NOMBRE}/health)
      if [ "$STATUS" = "200" ]; then
        echo "Smoke test passed: HTTP $STATUS"
        exit 0
      fi
      echo "  Waiting... HTTP $STATUS ($(( DEADLINE - SECONDS ))s restantes)"
      sleep 15
    done
    echo "Smoke test failed: timeout 5 min"
    exit 1
```
