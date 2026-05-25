# Guía Paso a Paso — Despliegue de una Transversal

> Guía para montar desde cero una plataforma de microservicios Siesa Business sobre GCP.
> Se construyó ejecutando los flows en la transversal **financiero** (`prj-sie-fin-financiero-dev`).
> Actualizar a medida que se ejecutan los pasos.

---

## Conceptos clave antes de empezar

| Término | Qué es |
|---|---|
| **Transversal** | Unidad de negocio completa (financiero, comercial, manufactura). Tiene su propio repo deploy (`business-{nombre}-deploy`), proyecto GCP y cluster GKE. |
| **Servicio** | Microservicio individual dentro de la transversal (ej: `third-party`, `accounting`). Tiene su propio repo de código y namespace K8s. |
| **Repo deploy** | Este repo — contiene SOLO infraestructura (Terraform, K8s manifests, CI/CD). Sin código de aplicaciones. |
| **Hub project** | Proyecto GCP compartido entre ambientes donde vive el Artifact Registry. Las imágenes Docker se publican ahí una sola vez. |
| **Spoke project** | Proyecto GCP por ambiente (dev, staging, prod) donde viven GKE, Cloud SQL, Pub/Sub. |
| **Flow** | Slash command de Claude Code (`/flow-*`) que genera artefactos automáticamente. |
| **Agent** | Slash command de Claude Code (`/agent-*`) que valida arquitectura antes de ejecutar un flow. |

**Regla de oro:** Los flows generan artefactos → `/flow-aplicar` hace commit/push y monitorea el pipeline → el CI/CD aplica los cambios a GCP. Claude Code nunca toca GCP directamente.

---

## Flujo general de una transversal nueva

```
/agent-sre-sentinel nueva-transversal ...   ← Valida primero
           ↓ ✅ APROBADO
/flow-nueva-transversal {nombre} {suite} {project-id}
           ↓ Genera environments/*.yaml + terraform/ + .github/workflows/
Bootstrap GCP (una sola vez)
           ↓
/flow-aplicar                                        ← Commit + push + monitoreo del pipeline
           ↓ infra-pipeline corre (~15-20 min primer apply)
/flow-nuevo-servicio {nombre} [api-port] [mfe-port] [--no-mfe|--no-api]   ← Repetir por cada servicio
           ↓ Genera k8s/overlays/dev/ + actualiza environments/
/flow-aplicar                                        ← Commit + push + monitoreo
/flow-onboard-db {schema} {owner-role}               ← Repetir por cada servicio
           ↓ Ejecutar SQL en Cloud SQL (manual, con psql)
Copiar ci-pipeline.yml al repo del servicio → primer deploy
           ↓
/flow-auditar-servicio {nombre}                      ← Verificar gaps
           ↓
/flow-nuevo-ambiente staging                         ← Cuando dev está estable
           ↓
/flow-aplicar                                        ← Commit + push + monitoreo
```

---

## PASO 1 — Nueva Transversal

### Comando

```
/flow-nueva-transversal financiero fin prj-sie-fin-financiero-dev
```

**Argumentos:**
- `financiero` = nombre de la transversal
- `fin` = suite (2-4 caracteres, identifica el producto)
- `prj-sie-fin-financiero-dev` = Project ID del Spoke dev en GCP

**Qué deriva el flow automáticamente:**
- `REPO_NAME` = `business-financiero-deploy`
- `REGION` = `us-east1`
- `HUB_PROJECT` = `prj-sie-sb-financiero-common`
- `STATE_BUCKET` = `bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev`

### Gates interactivos (el flow se detiene y pide confirmación)

El flow tiene 3 gates antes de generar archivos. No es automático:

**Gate 0 — Naming convention**
Valida que el `PROJECT_ID` cumpla el patrón `{type}-sie-{bu}-{workload}-{env}`.
`prj-sie-fin-financiero-dev` ✅ cumple.

**Gate 1 — Hub Project**
El flow pregunta si `prj-sie-sb-financiero-common` existe.
Si no existe, hay que crearlo ANTES con `gcloud projects create`.

```bash
# Verificar si existe:
gcloud projects describe prj-sie-sb-financiero-common 2>&1

# Si no existe, crearlo:
gcloud projects create prj-sie-sb-financiero-common \
  --name="SIESA financiero Common" \
  --folder=<FOLDER_ID_BU>

# Habilitar APIs en el Hub:
gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  clouddeploy.googleapis.com \
  --project=prj-sie-sb-financiero-common
```

**Gate 2 — IP Plan (REGISTRY-FIRST)**
El flow calcula CIDRs para la VPC del nuevo cluster GKE y pide que se registren en `docs/devops-org/ip-plan.md` **antes** de generar el Terraform. Esto evita solapamiento de IPs entre transversales.

Cómo leer la tabla:
- `PRIMARY_CIDR` → subred de los nodos del cluster
- `PODS_CIDR` → rango de IPs para Pods (secundario)
- `SERVICES_CIDR` → rango de IPs para Services de K8s
- `MASTER_CIDR` → `/28` para el plano de control de GKE (Master)

### Archivos generados

Después de confirmar los 3 gates, el flow crea:

```
environments/
  dev.yaml          ← Configuración del ambiente dev (CIDRs + valores del cluster)
  shared.yaml       ← DNS, AR, WIF, SAs, Worker Pool (nunca destruir)
  staging.yaml      ← Template con <PLACEHOLDER> (completar antes de /flow-nuevo-ambiente)
  prod.yaml         ← Template con <PLACEHOLDER>

terraform/
  environments/dev/main.tf        ← Lee dev.yaml, mandatory labels, Shared VPC ref
  environments/shared/main.tf     ← Lee shared.yaml

.github/workflows/
  infra-pipeline-dev.yml          ← tfsec + checkov + SIESA Guard + terraform apply + kubectl
  infra-pipeline-shared.yml       ← Similar para recursos compartidos (AR, WIF, SAs)
```

> `k8s/overlays/dev/` NO se genera aquí. Se crea con `/flow-nuevo-servicio` por cada servicio.

### Placeholders que completar manualmente en `environments/dev.yaml`

Después de que el flow genere el archivo, hay que llenar:

```yaml
gcp:
  project_number: "<PLACEHOLDER>"        # gcloud projects describe prj-sie-fin-financiero-dev --format='value(projectNumber)'

network:
  subnetwork: "<PLACEHOLDER>"            # Coordinar con Cloud Admin — Shared VPC Host

iam:
  dev_group: "<PLACEHOLDER>"             # g-gcp-fld-sie-bus-financiero-dev-admins@siesacloud.com
  devs_group: "<PLACEHOLDER>"            # g-gcp-fld-sie-bus-financiero-dev-devs@siesacloud.com

monitoring:
  alert_email: "<PLACEHOLDER>"           # alertas-financiero@siesa.com
```

---

## PASO 2 — Bootstrap GCP (una sola vez por transversal nueva)

> **¿Ya existe la transversal?** Si el bucket de estado existe y el pipeline ya corrió alguna vez, **salta este paso**. El bootstrap es irreversible y no debe repetirse.
>
> Verificar si aplica:
> ```bash
> gcloud storage ls gs://bkt-sie-{SUITE}-iac-state-{PROJECT_ID}/
> # Si devuelve contenido → el bootstrap ya se hizo → pasar al Paso 3
> # Si devuelve "not found" → ejecutar bootstrap
> ```

El bootstrap crea los recursos base del proyecto GCP que Terraform necesita para funcionar: bucket de estado, APIs habilitadas, WIF pool, SA de bootstrap.

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="project_id={PROJECT_ID}"
```

Solo se ejecuta una vez por transversal. Después todo va por CI/CD.

---

## PASO 3 — Aplicar cambios

```
/flow-aplicar
```

Este comando reemplaza el ciclo manual de git add/commit/push/monitorear. Lo hace todo:

### Qué hace internamente

1. **Valida** que no haya `<PLACEHOLDER>` sin resolver en `environments/*.yaml`, que `terraform validate` pase (si está instalado localmente) y que CLAUDE.md esté actualizado
2. **Te pide un resumen** de una línea de lo que se hizo
3. **Hace commit** con formato convencional (`feat:`, `fix:`, `docs:`, `chore:`) detectado automáticamente
4. **Push a main** — esto dispara los pipelines de GitHub Actions
5. **Monitorea** en tiempo real el pipeline que se disparó:
   - `infra-pipeline-shared` → aplica Terraform shared (AR repos, WIF, SAs)
   - `infra-pipeline-dev` → aplica Terraform dev (GKE cluster, Cloud SQL, Gateway, etc.)
6. **Si falla**: lee el log del step fallido, diagnostica, y:
   - Repara automáticamente si es un error de K8s o timeout de red
   - Te pregunta antes de actuar si es un error de IAM, Terraform drift, o secret faltante
   - Detiene y escala si falla 3 veces consecutivas

### Tiempos esperados

| Situación | Duración aprox. |
|---|---|
| Primer apply (crea cluster GKE) | 15-20 min |
| Apply incremental (recursos nuevos) | 3-5 min |
| Apply sin cambios de infra (solo K8s) | 1-2 min |
| Solo docs (sin pipeline) | Inmediato |

---

## PASO 4 — Agregar cada servicio

Repetir por cada microservicio de la transversal.

### Comando

```
/flow-nuevo-servicio {nombre} [api-port] [mfe-port] [--no-mfe] [--no-api]
```

Los puertos son opcionales según el tipo de servicio:

| Tipo | Ejemplo |
|---|---|
| Fullstack (API + MFE) | `/flow-nuevo-servicio treasury 7022 8022` |
| Backend puro (sin MFE) | `/flow-nuevo-servicio payroll 7024 --no-mfe` |
| Frontend puro (sin API) | `/flow-nuevo-servicio app-shell 8000 --no-api` |

**Ejemplo para los servicios de financiero:**

```
/flow-nuevo-servicio access-manager 7010 8010
/flow-nuevo-servicio app-shell 8011 --no-api
/flow-nuevo-servicio segments 7012 8012
/flow-nuevo-servicio base-config 7014 8014
/flow-nuevo-servicio third-party 7016 8016
/flow-nuevo-servicio accounting 7018 8018
/flow-nuevo-servicio liquid-tax 7020 8020
```

### Qué genera por cada servicio

```
k8s/overlays/dev/
  dapr/{nombre}/
    pubsub.yaml         ← Componente Dapr pub/sub (con PROJECT_ID)
    secretstore.yaml    ← Componente Dapr secrets (con PROJECT_ID)
  routes/{nombre}-route.yaml        ← HTTPRoute del Gateway API (reglas según HAS_API/HAS_MFE)
  healthcheck/{nombre}-api-hc.yaml  ← HealthCheckPolicy TCP:8080 (solo si HAS_API)
  healthcheck/{nombre}-mfe-hc.yaml  ← HealthCheckPolicy TCP:80 (solo si HAS_MFE)

environments/dev.yaml               ← Agrega el servicio en `services:` y en `namespaces:`
environments/shared.yaml            ← Agrega el servicio con sus roles IAM
k8s/overlays/dev/import-map/import-map.yaml  ← Agrega entry del MFE (solo si HAS_MFE)
```

Y muestra listo para copiar:
```
.github/workflows/ci-pipeline.yml  ← Para pegar en el repo del servicio
```

### Pasos manuales después de cada `/flow-nuevo-servicio`

1. **Crear el secret de base de datos** en Secret Manager — **solo si el servicio tiene API backend** (no aplica a `--no-api`):
   ```bash
   gcloud secrets create {nombre}-dev-db-connection \
     --project=prj-sie-fin-financiero-dev \
     --data-file=<(echo "Host=127.0.0.1;Port=5432;Database=finance-dev;Username=dev;Password=CHANGE_ME")
   ```
   > Cambiar la contraseña después vía Cloud SQL console.

2. **Ejecutar DDL de grants** en Cloud SQL — ver Paso 5. Solo si el servicio tiene API backend.

3. **Copiar `ci-pipeline.yml`** al repo del servicio en `.github/workflows/`.

4. **Registrar permisos** en access-manager después del primer deploy — ver Paso 6. Solo si el servicio tiene API backend.

---

## PASO 5 — Onboard de base de datos por servicio

Cada servicio tiene su propio schema en la BD compartida. Este paso habilita el usuario `dev` para crear y modificar tablas en ese schema.

### Comando

```
/flow-onboard-db {schema} {owner-role}
```

**Schemas de financiero:**

| Servicio | Schema | Owner role |
|---|---|---|
| access-manager | `access_manager` | `accmgr` |
| segments | `segment` | `segments` |
| base-config | `base_config` | `base_config` |
| third-party | `tprt` | `third_party` |
| accounting | `acct` | `accounting` |
| liquid-tax | `liquid_tax` | `liquid_tax` |

### Qué hace

Genera el bloque SQL con los GRANTs necesarios + el comando de conexión via Cloud SQL Auth Proxy.

### Cómo ejecutarlo

1. Conectarse a Cloud SQL:
   ```bash
   ./scripts/dev-connect.sh
   ```
2. Conectar con `psql` (NO DBeaver — falla con error 3F000):
   ```bash
   psql "host=127.0.0.1 port=5433 dbname=finance-dev user=postgres"
   ```
3. Pegar el SQL que generó el flow y ejecutar.

> Sin este paso, el primer deploy del servicio falla porque EF Core no puede crear tablas en un schema sin permisos.

---

## PASO 6 — Registrar permisos en access-manager

Después del primer deploy exitoso, registrar las entidades y acciones del servicio en access-manager. Solo necesario si el servicio usa control de acceso por permisos.

### Comando

```
/flow-registrar-permisos {servicio} {prefijo} {entidad1} {entidad2} ...
```

El flow genera el `curl` exacto a ejecutar contra `POST /internal/v1/permissions/register`.

---

## PASO 7 — Auditar un servicio existente

Cuando un servicio ya existe (ya está en el repo deploy y en el repo del servicio), usar este comando para detectar gaps.

### Comando

```
/flow-auditar-servicio {nombre}
/flow-auditar-servicio {nombre} --no-mfe
```

### Qué revisa (7 guardrails G-C1..G-C7)

| Guardrail | Qué verifica |
|---|---|
| G-C1 | Archivos K8s overlay presentes (dapr, routes, healthcheck, import-map) |
| G-C2 | `workflow_dispatch` en el pipeline (para re-runs manuales) |
| G-C3 | Smoke test usa retry loop de 15s hasta 5 min (no `sleep 120` fijo) |
| G-C4 | `environment: dev` en el job de deploy |
| G-C5 | Imagen Docker usa SHA del commit (no `latest`) |
| G-C6 | `cloudbuild-deploy.yaml` (no el nombre viejo `cloudbuild-sandbox.yaml`) |
| G-C7 | `GITHUB_TOKEN` para packages (no PAT de usuario) |

Ofrece corregir automáticamente los gaps que detecta.

---

## PASO 8 — Nuevo ambiente (staging / prod)

Solo cuando el ambiente dev está estable y se quiere promover a staging o producción.

### Prerrequisito

Completar los `<PLACEHOLDER>` en `environments/staging.yaml` (o `prod.yaml`) antes de ejecutar el flow.

### Comando

```
/flow-nuevo-ambiente staging
/flow-nuevo-ambiente prod
```

### Qué genera

```
terraform/environments/staging/main.tf
.github/workflows/infra-pipeline-staging.yml
k8s/overlays/staging/
  dapr/**/*.yaml       ← Mismos components con PROJECT_ID del nuevo ambiente
  routes/*.yaml        ← Mismas rutas con el gateway del nuevo ambiente
  healthcheck/*.yaml   ← Sin cambios
  import-map/          ← Sin cambios
```

> El flow copia `k8s/overlays/dev/` como template y reemplaza el `projectId` de Dapr y el nombre del Gateway.

---

## Validación arquitectónica previa (opcional pero recomendada)

Antes de ejecutar cualquier flow, el agente SRE valida que la propuesta cumpla los guardrails de la organización Siesa:

```
/agent-sre-sentinel nueva-transversal financiero fin prj-sie-fin-financiero-dev
/agent-sre-sentinel nuevo-servicio treasury
/agent-sre-sentinel propuesta "quiero agregar una caché Redis por servicio en lugar de la instancia compartida"
```

Revisa 7-10 principios arquitectónicos (Hub-First, IP Plan, naming, Host VPC inviolability, etc.) y devuelve `✅ APROBADO` o una lista de problemas a resolver.

---

## Referencia rápida — todos los flows

| Comando | Cuándo usar |
|---|---|
| `/flow-nueva-transversal {nombre} {suite} {project-id}` | Al crear una nueva unidad de negocio desde cero |
| `/flow-nuevo-servicio {nombre} [api-port] [mfe-port] [--no-mfe\|--no-api]` | Al agregar un microservicio a la transversal (fullstack, backend puro o frontend puro) |
| `/flow-nuevo-ambiente {staging\|prod}` | Al promover la transversal a un nuevo ambiente |
| `/flow-aplicar` | Después de cualquier flow que genere artefactos — hace commit/push y monitorea el pipeline |
| `/flow-onboard-db {schema} {owner-role}` | Antes del primer deploy de cada servicio (habilita DB) |
| `/flow-registrar-permisos {servicio} {prefijo} {entidades...}` | Después del primer deploy (registra permisos en access-manager) |
| `/flow-auditar-servicio {nombre} [--no-mfe]` | Para detectar y corregir gaps en servicios existentes |

---

## Notas acumuladas durante la ejecución

> Esta sección se actualiza a medida que se ejecutan los pasos en la transversal financiero.

<!-- Agregar observaciones, errores encontrados y soluciones aquí -->
