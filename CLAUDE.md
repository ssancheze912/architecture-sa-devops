# Business Financiero Deploy — Contexto del Proyecto

> **Troubleshooting:** `docs/troubleshooting.md` | **Deuda Técnica:** `docs/tech-debt.md`
> **Convenciones MFE:** `docs/mfe-conventions.md` | **Dev Setup:** `docs/developer-guide.md` | **Onboarding:** `docs/onboarding.md`
> **Flujo de desarrollo (roles):** `docs/flujo-desarrollo.md` — qué hace cada actor y cuándo
> **Cambios Masivos Multi-repo:** `docs/mass-service-changes.md` | **Idempotent Consumer:** `docs/idempotent-consumer-pattern.md`
> **Arquitectura (diagramas Mermaid):** `docs/architecture-presentation.md` | **Dapr Local In-Memory:** `docs/dapr-local-in-memory.md`
> **SRE Skills (referencia org):** `docs/devops-org/` — ip-plan, iac-sentinel, cicd-architect
> **Guía principiantes (nueva transversal):** `docs/guia-principiantes.md` | **Scaffold (fork limpio):** rama `scaffold`
> **DDL GRANTs QA:** `docs/qa-db-grants.md` — scripts psql para cada schema post-primer-deploy

## REGLAS OBLIGATORIAS

### Regla 1 — Terraform es la única fuente de verdad para infraestructura GCP

> **TODOS los recursos GCP deben gestionarse via Terraform y aplicarse por CI/CD.**
> Prohibido crear/modificar recursos manualmente sin importarlos a TF state después.
> Si existe un recurso manual: agregar a módulo TF + import block en `main.tf` + PR.
> Aplica a: certificados TLS, zonas DNS, SAs, clusters, DBs, gateways, cert maps, LBs, firewalls.

### Regla 2 — Actualización obligatoria de documentación

> **Cada cambio en este repo** requiere actualizar CLAUDE.md, .gemini/GEMINI.md y `docs/troubleshooting.md` si aplica.
> Sin actualización, los asistentes AI pierden capacidad de asistir correctamente.

---

## Descripción General

Repositorio de **infraestructura de despliegue** de la plataforma financiera Siesa Business sobre GCP. Solo IaC, manifiestos K8s, templates CI/CD y documentación — sin código fuente de aplicaciones.

## Repositorios Relacionados

| Repositorio | Descripción | Namespace K8s |
|---|---|---|
| `SiesaTeams/business-access-manager` | API + MFE gestión de acceso | `access-manager` |
| `SiesaTeams/business-financiero-app-shell` | App shell SPA (single-spa host) | `app-shell` |
| `SiesaTeams/business-financiero-segments-service` | Servicio de segmentos | `segments` |
| `SiesaTeams/business-financiero-base-config` | Servicio de configuración base | `base-config` |
| `SiesaTeams/business-financiero-third-party-service` | Servicio de terceros (TPRT) | `third-party` |
| `SiesaTeams/business-financiero-accounting-service` | Servicio de contabilidad | `accounting` |
| `SiesaTeams/business-financiero-liquid-tax-service` | Servicio de impuestos líquidos | `liquid-tax` |

## Stack Técnico

| Capa | Tecnología | Detalle |
|---|---|---|
| Orquestación | GKE Autopilot | K8s 1.31, REGULAR channel |
| Base de datos | Cloud SQL PostgreSQL | v18, IP pública (Auth Proxy), PITR |
| Registry | Artifact Registry | 1 repo Docker por servicio |
| Gateway | GKE Gateway API v1 | L7 externo, HTTPS + HTTP redirect |
| WAF | Cloud Armor | OWASP rules (SQLi, XSS) |
| Service mesh | Dapr 1.17.3 | state, pub/sub, secrets, mTLS |
| State store | Redis | StatefulSet `dapr-system`, PVC 1Gi AOF, fsGroup 999 |
| Pub/Sub | Cloud Pub/Sub | Dapr component, `disableEntityManagement: true` |
| Secrets | GCP Secret Manager | Dapr component |
| Observabilidad | Jaeger all-in-one v1.57 + OTel Collector 0.149.0 | namespace `observability`, in-memory (dev) |
| CI/CD | GitHub Actions + Cloud Build | WIF sin JSON keys |
| Backend | ASP.NET Core .NET 8/10 | Minimal APIs, Clean Arch + CQRS |
| Frontend | React + TypeScript + Vite | single-spa MFEs, ESM nativo |

## Proyecto GCP

- **Project ID:** `prj-sie-fin-financiero-dev` | **Región:** `us-east1`
- **Cluster:** `gke-sie-fin-sandbox-dev` (GKE Autopilot, Master Authorized Networks + nodos privados)
- **Cloud SQL:** `pgsql-fin-sandbox-dev` | **BD única:** `finance-dev` (schema por servicio)
- **Dominio:** `finance.siesacloud.dev`
- **Config centralizada:** `environments/dev.yaml` (dev) + `environments/shared.yaml` (DNS, AR, WIF, SAs, Worker Pool). Terraform usa `yamldecode()`, GitHub Actions usa `yq`.

## Estructura del Repositorio

```
business-financiero-deploy/
├── CLAUDE.md / .gemini/GEMINI.md
├── environments/                        ← FUENTE DE VERDAD POR AMBIENTE
│   ├── shared.yaml                     ← DNS, AR, WIF, SAs — nunca destruir
│   ├── dev.yaml                        ← Ambiente dev activo
│   ├── qa.yaml                         ← Ambiente QA (prj-sie-fin-financiero-qas)
│   ├── staging.yaml                    ← Template (completar placeholders)
│   └── prod.yaml                       ← Template (completar placeholders)
├── .github/workflows/
│   ├── infra-pipeline-dev.yml
│   ├── infra-pipeline-qa.yml
│   └── infra-pipeline-shared.yml
├── terraform/
│   ├── bootstrap/main.tf
│   ├── modules/                        ← Módulos genéricos (agnósticos de ambiente)
│   └── environments/
│       ├── shared/main.tf              ← Lee environments/shared.yaml
│       ├── dev/main.tf                 ← Lee environments/dev.yaml
│       └── qa/main.tf                  ← Lee environments/qa.yaml
├── k8s/
│   ├── base/                           ← Recursos genéricos (sin valores de ambiente)
│   │   ├── dapr/tracing-config.yaml
│   │   ├── redis/
│   │   └── observability/
│   └── overlays/
│       ├── dev/                        ← Recursos ambiente-específicos (dev)
│       │   ├── dapr/                   ← Components con projectId por servicio
│       │   ├── routes/                 ← HTTPRoutes (referencia gateway del ambiente)
│       │   ├── healthcheck/            ← HealthCheckPolicies por servicio
│       │   └── import-map/
│       └── qa/                         ← Recursos ambiente-específicos (qa)
│           ├── dapr/
│           ├── routes/
│           ├── healthcheck/
│           └── import-map/
├── cicd-templates/.github/workflows/   ← Templates copiados a repos de servicios
├── scripts/
│   ├── dev-connect.sh
│   └── dapr-local/
└── docs/
```

## Slash Commands — Flows y Agentes

Disponibles en Claude Code (`.claude/commands/`). Convención: `/flow-*` genera artefactos, `/agent-*` revisa y valida.

| Comando | Propósito |
|---|---|
| `/flow-nueva-transversal {nombre} {suite} {project-id}` | Scaffolding completo para un nuevo repo `business-{nombre}-deploy` |
| `/flow-nuevo-servicio {nombre} [api-port] [mfe-port] [--no-mfe] [--no-api]` | Agrega un microservicio: K8s, Dapr, routes, healthcheck, CI pipeline. `--no-mfe` = backend puro; `--no-api` = frontend puro |
| `/flow-nuevo-ambiente {staging\|prod}` | Genera `environments/{ambiente}.yaml` desde el template |
| `/flow-onboard-db {schema} {owner-role}` | DDL de GRANTs para habilitar el usuario `dev` en un schema nuevo |
| `/flow-registrar-permisos {servicio} {prefijo} {entidad...}` | Genera el `curl` de registro de permisos en access-manager |
| `/flow-auditar-servicio {nombre} [--no-mfe]` | Audita artefactos y CI/CD de un servicio existente — detecta gaps y ofrece corregirlos |
| `/agent-sre-sentinel {modo} {args}` | Revisor arquitectónico — valida propuestas contra guardrails SIESA antes de ejecutar un flow |

**`/agent-sre-sentinel` modos:**
- `nueva-transversal {nombre} {suite} {project-id}` — 7 guardrails: naming, Hub-First, IP overlap, Registry-First, AR en Hub, Host VPC, mandatory labels
- `nuevo-servicio {nombre}` — 7 guardrails: Production-Ready, API Guard, WI binding, AR en Hub, secret naming, immutable artifacts
- `propuesta "{texto libre}"` — 10 principios arquitectónicos evaluados contra la descripción

**Flujo recomendado:**
```
/agent-sre-sentinel {modo} {args}   ← valida primero
        ↓ ✅ APROBADO
/flow-{modo} {args}                 ← genera los artefactos
```

## Decisiones Arquitectónicas Clave

1. **Dapr sobre Istio:** mTLS, state, pub/sub y secrets sin la complejidad de un service mesh completo.
2. **GKE Gateway API:** Estándar nativo K8s, integración directa con Cloud Armor y Certificate Manager.
3. **Cloud Build Worker Pool (`financiero-pool`):** GKE usa Master Authorized Networks. Worker pool peered a VPC para acceder al API server.
4. **WIF:** GitHub Actions sin JSON keys. `attribute_condition = "assertion.repository_owner == 'SiesaTeams'"` — **NO eliminar** (restricción de seguridad por organización).
5. **ESM nativo para MFEs:** Import maps del browser, sin SystemJS. AppShell carga `/importmap.json` → `@siesa/{service}` → `/mfe/{service}/spa-entry.js`. Ver `docs/mfe-conventions.md`.
6. **Redis compartido StatefulSet:** Una instancia en `dapr-system`, keys namespaced. PROD: migrar a Cloud Memorystore.
7. **Cloud SQL Auth Proxy sidecar (dev):** IP pública habilitada (`ipv4_enabled=true` — GKE ip-masq-agent bloquea PSA). Sidecar en `127.0.0.1:5432`. Staging/PROD: IP privada via Shared VPC, sin Auth Proxy. BD única por ambiente (`finance-dev`, `finance-stg`), schema por servicio (`access_manager`, `segment`, `base_config`, `tprt`, `acct`, `liquid_tax`).
7b. **Cloud SQL — Backup y mantenimiento:** Backup diario 04:00 UTC (11 PM COT), retención 7 copias, PITR 7 días WAL. Mantenimiento: domingo 06:00 UTC, track `stable`. `log_min_duration_statement=1000ms` (queries > 1s logueadas). `deletion_protection=true`. Alerta backup via `condition_matched_log`; alerta disco via `condition_threshold` > 80%. Módulo: `terraform/modules/monitoring/`.
7c. **Cloud SQL — Connection Pool:** `db-g1-small`. `Maximum Pool Size=3` en todos los servicios. Para actualizar sin CI/CD: patchear K8s secret + `rollout restart`. Ver `docs/troubleshooting.md § Cloud SQL`.
7e. **Cloud SQL — GRANTs DDL (QA/nuevo ambiente):** El usuario `postgres` en Cloud SQL es `cloudsqlsuperuser`, NO superuser real — no puede `GRANT` en schemas de otros roles. Patrón correcto: `GRANT {role} TO postgres` + `SET ROLE {role}` + grants + `RESET ROLE`. Sin `SET ROLE`, los grants fallan con "permission denied for schema". Ver `docs/qa-db-grants.md`. Tras cambiar la connection string en Secret Manager y propagar al K8s secret, los pods existentes no recargan el env var — verificar con `kubectl exec ... -- env | grep ConnectionStrings` y hacer `kubectl rollout restart` si el valor es el viejo.
7d. **Cloud SQL — Availability por ambiente:** Dev = `ZONAL` (sin HA). Staging = `REGIONAL` (HA, valida antes de PROD). PROD = `REGIONAL`. El módulo `terraform/modules/cloud-sql/main.tf` recibe `availability` como variable desde `environments/{env}.yaml`.
8. **Config centralizada en YAML:** `environments/{ambiente}.yaml` — fuente única de parámetros por ambiente. No duplicar valores.
9. **State compartido (`shared/`):** DNS, AR, WIF, SAs, Worker Pool. Nunca se destruye junto con ambientes.
9c. **Artifact Registry — Hub project (`prj-sie-sb-fin-common`):** Todas las imágenes Docker viven en el Hub, repo compartido `art-fin-shared`. URL: `us-east1-docker.pkg.dev/prj-sie-sb-fin-common/art-fin-shared/{service}/{service}-api:{sha}`. `environments/shared.yaml` tiene `hub.project_id: prj-sie-sb-fin-common` separado del `gcp.project_id` (Spoke). Los pipelines usan `HUB_PROJECT_ID` para push de imagen y `PROJECT_ID` para Cloud Build/GKE. Repos Spoke (`prj-sie-fin-financiero-dev`) quedan vacíos tras migración de cada servicio. IAM: TF en `shared/main.tf` otorga `roles/artifactregistry.writer` en Hub a cada SA CI/CD; Compute SA ya tiene `roles/artifactregistry.reader` en Hub (pre-configurado por org).
9e. **Cloud Build Triggers GitHub App — eliminados (2026-05-20):** Los triggers `fin-segments-service-cicd` y `fin-third-party-service-cicd` fueron creados manualmente en Hub (`prj-sie-sb-fin-common`) y luego eliminados. Causa raíz: eran PR triggers configurados con `filename = cloudbuild.yaml`, pero ese archivo no existe en los repos de servicio (el CI/CD completo vive en `ci-pipeline.yml` de GitHub Actions). Generaban checks fallidos en cada PR. **Lección:** NO crear Cloud Build triggers para repos de servicio — el CI/CD ya está 100% gestionado por GitHub Actions. Si en el futuro se necesita un trigger CB, debe ser push-to-branch (no PR trigger) y debe apuntar a un `cloudbuild.yaml` que realmente exista.
9d. **WIF + SAs CI/CD — Hub-First (migrado 2026-05-18):** El WIF pool `github-actions` y TODOS los SAs CI/CD (servicios + deploy + qa-deploy) viven en Hub (`prj-sie-sb-fin-common`). La SA email usa `@prj-sie-sb-fin-common.iam.gserviceaccount.com`. Los roles de IAM se conceden cross-project sobre el Spoke correspondiente. `shared/main.tf` separa: `project_id = hub` (donde viven las SAs) y `roles_project_id = dev-spoke` (donde se otorgan roles). `user_project_override = true` + `billing_project = project_id` evita 403 de quota project cuando la SA vive en Hub. El deploy SA QA tiene roles sobre `prj-sie-fin-financiero-qas` y además `roles/dns.admin` sobre el Spoke DEV (para crear CNAME de validación TLS en la zona compartida `siesacloud-dev`).
9b. **Import blocks en `environments/dev/main.tf`:** Todos los recursos pre-existentes tienen `import {}` blocks (idempotentes en TF 1.7+). **CRÍTICO:** Todo `google_sql_user` con `lifecycle { ignore_changes = [password] }` DEBE tener import block — sin él, Terraform crea el usuario con contraseña placeholder y rompe la autenticación.
10. **Certificate Manager vía TF:** Módulo `certificate-manager/`. Gateway usa anotación `networking.gke.io/certmap`. El módulo acepta `dns_project_id` (default `null` → usa `project_id`) para cuando la zona DNS compartida vive en un proyecto diferente al de los certificados (ej. QA certs en QA project, DNS zone `siesacloud-dev` en DEV Spoke).
11. **Ambientes activos:** dev (`finance.siesacloud.dev`) + QA (`finance-qa.siesacloud.dev`, `prj-sie-fin-financiero-qas`). QA usa Cloud SQL con `ipv4_enabled=false` (org policy `constraints/sql.restrictPublicIp` en proyecto QA). Dev usa `ipv4_enabled=true` + Auth Proxy sidecar. Connection string QA: `Host=10.20.39.250;Port=5432;Database=finance-qa;Username={user};Password={pass};Search Path={schema};SSL Mode=Disable;GssEncryptionMode=Disable`. DDL post-deploy: `docs/qa-db-grants.md`.
11b. **QA Cloud SQL — conectividad via PSC (Private Service Connect):** GKE Autopilot bloquea modificaciones a kube-system (GKE Warden: `managed-namespaces-limitation`) → ip-masq-agent ConfigMap no puede patchiarse via kubectl → pods con CIDR no-RFC-1918 (`100.82.x.x`) no pueden conectar directamente a Cloud SQL PSA IP (`192.168.160.20`) porque servicenetworking no rutea replies de vuelta. **Solución: PSC.** PSC hace SNAT propio: pods conectan al forwarding rule IP (`10.20.39.250`, RFC-1918 en subnet GKE) → PSC hace NAT hacia Cloud SQL → reply regresa por la infra PSC a `10.20.39.250` → VPC rutea al pod CIDR (GKE tiene rutas de retorno en el VPC). Recursos Terraform en `terraform/environments/qa/main.tf`: `google_compute_address.cloud_sql_psc` (IP `10.20.39.250` en `snt-sie-bus-fin-use1-qa`, host VPC project) + `google_compute_forwarding_rule.cloud_sql_psc` (target = `module.cloud_sql.psc_service_attachment_link`). Módulo cloud-sql tiene `psc_enabled=true` + `psc_allowed_consumer_projects=["238886086835","763982348967"]`. **Prerequisito IAM manual (una sola vez):** `roles/compute.networkAdmin` para `sa-sie-fin-qa-cicd@prj-sie-sb-fin-common.iam.gserviceaccount.com` en `prj-sie-com-vpc-host-qa` (ya aplicado 2026-05-19).
12. **Gateway rewrite como capa de indirección API:** MFEs llaman `/api/{prefijo}/*`, Gateway reescribe a `/api/v1/{prefijo}/*`. **NUNCA** usar `/api/v1/` desde el frontend. Ver `docs/mfe-conventions.md`.
13. **IAM desarrollo local vía Google Groups:** Admins: `g-gcp-fld-sie-bus-financiero-dev-admins@siesacloud.com` (abel.gonzalez, diego.santacruz). Devs: `g-gcp-fld-sie-bus-financiero-dev-devs@siesacloud.com` (jacastellanosm, fabian.capote, lvilora, cesar.rincon). Terraform agrega roles complementarios a nivel proyecto. Membresía gestionada en Google Workspace.

## Patrón de Despliegue (CI/CD)

**Servicios:**
```
PR → Quality Gate → Merge a develop → GitHub Actions (ci-pipeline.yml):
  1. docker build API+MFE (WIF, GITHUB_TOKEN para NuGet/npm)
     → docker push us-east1-docker.pkg.dev/prj-sie-sb-fin-common/art-fin-shared/{service}/{service}-{api|mfe}:{sha}
  2. Cloud Build (cloudbuild-deploy.yaml, worker pool en Spoke):
     agregar IP a MAN → kubectl apply (kustomize) → rollout status --timeout=300s → restaurar MAN
```

**GitHub Packages auth — GITHUB_TOKEN, no PAT:** El `ci-pipeline.yml` usa `permissions: packages: read` y pasa `secrets.GITHUB_TOKEN` como `NUGET_GITHUB_TOKEN` / `NPM_GITHUB_TOKEN` al docker build. El secret `github-npm-token` de Secret Manager es obsoleto (solo Cloud Build necesitaba el PAT; ahora el build está en GHA). Cloud Build (`cloudbuild-deploy.yaml`) solo hace deploy — no necesita token de GitHub Packages.

**⚠️ Race condition MAN — deploys concurrentes:** `CLUSTER_ALREADY_HAS_OPERATION` si dos pipelines corren a la vez. Sin retry automático — re-run manual. Evitar triggers simultáneos. El retry está implementado en `cloudbuild-deploy.yaml` (max 5 intentos, backoff exponencial).

**Smoke test — retry loop (patrón liquid-tax):** En lugar de `sleep 120` fijo, usar un retry loop de 15s hasta 5 min. `sleep` fijo falla cuando Dapr sidecar o NEGs del Gateway tardan >120s. Ejemplo: `DEADLINE=$((SECONDS+300)); while [ $SECONDS -lt $DEADLINE ]; do ... sleep 15; done`. Ver `.github/workflows/ci-pipeline.yml` en `business-financiero-liquid-tax-service`.

**Convención GitHub Environments:** Repos de servicio usan `environment: dev` (ci-pipeline) y `environment: qa` (qa-pipeline). El environment `sandbox` fue eliminado. El archivo Cloud Build es `cloudbuild-deploy.yaml`.

**QA Pipeline — `cicd-templates/.github/workflows/qa-pipeline.yml`:** Se activa en push a la rama `qa` o `workflow_dispatch`. Mismo SA Hub-First que dev. Enfoque **kustomize-based**: `gcloud builds submit k8s/` sube el directorio entero como fuente; Cloud Build genera `kustomization.yaml` en runtime y aplica con `kubectl kustomize | kubectl apply`. Variables clave por servicio: `SERVICE_NAME`, `NAMESPACE`, `DEPLOY_API`, `DEPLOY_MFE`, `HEALTH_PATH`. **`HEALTH_PATH`:** Ruta del health check en el smoke test (default `/health/live`). access-manager usa `/health`; todos los demás servicios .NET 8 usan `/health/live`. Si el smoke test falla con 404 constantemente, verificar qué endpoint expone el servicio en DEV antes de asumir problemas de conectividad.

**QA Pipeline — IAM obligatorio en `terraform/environments/qa/main.tf`:** El flujo usa un worker pool privado (VMs con Compute Engine default SA). Requiere 4 IAM resources ADICIONALES al `iam` module: (1) `cicd_sa_storage_admin` — `roles/storage.admin` a cada CI/CD SA: `gcloud builds submit` necesita escribir en el bucket `{project}_cloudbuild`. (2) `compute_sa_storage_admin` — `roles/storage.admin` al Compute SA `{project_num}-compute@developer.gserviceaccount.com`: el worker pool necesita leer el fuente desde ese bucket. (3) `compute_sa_container_admin` — `roles/container.admin` al Compute SA: para kubectl/MAN dentro del container. (4) `compute_sa_secret_accessor` — `roles/secretmanager.secretAccessor` al Compute SA: para leer secrets de QA SM al crear K8s secrets. Sin estos 4 recursos, `gcloud builds submit` falla con `forbidden from accessing bucket`.

**QA Pipeline — Dapr primer deploy:** El infra-pipeline solo instala Dapr (via Helm) cuando el job `k8s-manifests` corre, y ese job salta si no hay cambios en `k8s/`. En un ambiente nuevo, ejecutar manualmente: `gh workflow run infra-pipeline-{ambiente}.yml --ref main`. Esto fuerza `has_changes=true` e instala Dapr. Sin este paso, los deploys de servicios fallan con `no matches for kind "Configuration" in version "dapr.io/v1alpha1"`.

**QA Pipeline — Convención nombres secrets en Secret Manager:** Los secrets de QA usan el prefijo corto del servicio, NO el nombre largo: `baseconfig-qa-db-connection` (no `base-config-`), `tprt-qa-db-connection` (no `third-party-`), `acct-qa-db-connection` (no `accounting-`). Los pipelines de `segments` y `liquid-tax` usan el nombre completo (`segments-qa-db-connection`, `liquid-tax-qa-db-connection`). Verificar nombres reales antes de hacer el primer deploy: `gcloud secrets list --project={PROJECT_ID} --filter="name:qa"`.

**Infraestructura (este repo):**
```
PR → terraform plan (comentario PR) → Merge a main →
  Job 1: terraform apply | Job 2 (depende J1): Cloud Build → kubectl apply (redis, dapr, routes, etc.)
```

**Pre-requisitos de primer deploy por servicio (una sola vez):**
- Crear secret en Secret Manager con la connection string antes del primer CI/CD: `tprt-dev-db-connection`, `acct-dev-db-connection`, `liquid-tax-dev-db-connection`.
- La contraseña DB se genera como `change-me-use-secret-manager` — cambiar vía Cloud SQL console y actualizar el secret.
- Orden: 1) push deploy repo (infra-pipeline-shared + infra-pipeline-dev) → 2) push develop del servicio.
- **Usuario `dev` — DDL obligatorio por schema nuevo:** `GRANT ALL PRIVILEGES ON SCHEMA`, `GRANT ALL ON ALL TABLES/SEQUENCES`, `ALTER DEFAULT PRIVILEGES` + membresía de rol: `GRANT {owner_role} TO dev;` (como postgres — `GRANT ALL` no permite `ALTER TABLE`). Usar psql, no DBeaver (error 3F000). Owners: `segment`→`segments`, `base_config`→`base_config`, `access_manager`→`accmgr`, `tprt`→`third_party`, `acct`→`accounting`, `liquid_tax`→`liquid_tax`. Ver `docs/troubleshooting.md § Cloud SQL`.
- **Variables de entorno DB local:** `scripts/dev-connect.sh` genera `~/.financiero-dev.env` con `DB_FINANCE_DEV_PASSWORD`. `launch.json` referencia `${env:DB_FINANCE_DEV_PASSWORD}` — nunca hardcodear la contraseña.

## Pub/Sub — Topics y Suscripciones

Convención: **un topic por servicio**, formato `{servicio}-events`. `disableEntityManagement: true` en componente Dapr.

| Topic | Productor | Consumidores |
|---|---|---|
| `access-manager-events` | Access Manager | Base Config, Segments, Third Party |
| `segments-events` | Segments | Base Config, Segments (fiscal interno), Third Party |
| `base-config-events` | Base Config | Segments, Third Party |
| `liquid-tax-events` | (futuro) | Segments, Third Party |
| `third-party-events` | Third Party | Segments |
| `treasury-events` | (futuro) | Third Party |

Suscripciones: `{dapr-app-id}-{topic}`. SAs productores: `roles/pubsub.publisher`. Segments y Base Config también: `roles/pubsub.subscriber`.
**Nota:** Segments se suscribe a su propio topic para eventos internos de fiscal period/year. Un topic por servicio — no crear topics por feature.

## Reconciliación de Proyecciones

Patrón: 2 capas — **eventos Dapr** (tiempo real) + **cron binding** (snapshot completo via Dapr service invocation). Cron bindings en `k8s/overlays/{env}/dapr/{service-name}/`.

**⚠️ Dapr service invocation cross-namespace:** Usar `{app-id}.{namespace}` (ej: `segments.segments`, `accessmanager.access-manager`, `base-config.base-config`). Sin namespace, Dapr busca en el namespace actual.

**⚠️ `UseWhen` + rutas de reconciliación:** Usar `ctx.Request.Path.Value.StartsWith("/reconcile")` — NO `StartsWithSegments` (no matchea `/reconcile-companies`). Una sola condición para todos los `/reconcile-*`.

**⚠️ FKs entre proyecciones — PROHIBIDO:** EF Core infiere FK constraints desde navigation properties. Regla: FKs de tablas de dominio → proyecciones ✅ OK; FKs de proyección → proyección ❌ Prohibido. Cada proyección reconcilia desde fuente distinta; el orden de llegada de eventos no está garantizado → FK violation en reconciliación. Eliminar navigation properties en entidades `Prj` y el `HasOne/WithMany/HasForeignKey` en su `IEntityTypeConfiguration`. Crear migración que elimine los FK constraints.

**Trigger manual (dev):** `kubectl -n {ns} port-forward svc/{ns}-api 8080:8080` + `curl -X POST http://localhost:8080/reconcile-{entity}`.
**Trigger geográfico:** Workflow `reconcile-geographic-projections.yml` → `gh workflow run`.

| Servicio | Proyecciones | Fuente snapshot |
|---|---|---|
| base-config | CompanyPrj, OperationCenterPrj, UserCompanyAssignmentPrj (1h) / UserPrj (15min) | segments.segments / accessmanager.access-manager |
| segments | UserPrj (1h) / CountryPrj, StatePrj, CityPrj, NeighborhoodPrj (1h) | accessmanager.access-manager / base-config.base-config |
| third-party | 12 proyecciones; `/reconcile-users`, `/reconcile-companies` y `/reconcile-user-company-assignments` activos con cron bindings | accessmanager.access-manager / segments.segments |

## Tests de Integración — Patrón SQLite (segments-service)

`segments-service` migró sus tests de integración de Testcontainers/Docker a SQLite in-memory. Patrón replicable en otros servicios:

- **`SqliteTestHelper`** (`TestSetup/`): central — contiene `CreateSharedConnection`, `BuildOptions`, `InitializeForTestsAsync`, `StripMasterDefinitionSchemas`.
- **`SqliteCompatibleModelCustomizer`**: convierte xid→INTEGER, jsonb→TEXT, uuidv7→`SequentialGuidValueGenerator`, schemas→null, `ILike`→función escalar, `DateTimeOffset`→ISO 8601 UTC-aware. xmin default = `2u` (para que `version=1` sea stale como en Postgres).
- **`SqliteTestModelValidator`**: omite `ValidateDbFunctions` — necesario porque `ILike` con `HasTranslation` tiene parámetro `DbFunctions` no válido para SQLite.
- **`SqliteXminRefreshInterceptor`** (`SaveChangesInterceptor`): tras cada `SaveChanges`, recarga entidades con concurrency token `uint` para compensar que `RETURNING` de SQLite captura el valor pre-trigger. Sin esto, el cliente envía versión stale en la siguiente operación.
- **`AddXminTriggersAsync`**: crea triggers `AFTER UPDATE ... WHEN OLD.xmin = NEW.xmin` para simular el auto-incremento de xmin de PostgreSQL.
- **Todos los `AddDbContext` en WAF** deben incluir: `.ReplaceService<IModelCustomizer, SqliteCompatibleModelCustomizer>()`, `.ReplaceService<IModelValidator, SqliteTestModelValidator>()`, `.AddInterceptors(new SqliteXminRefreshInterceptor())`.
- **Raw SQL con GUIDs**: siempre usar SQL parametrizado (`{0}`) — nunca string interpolation (`'{guid}'`). EF Core 8+ almacena Guid como BLOB; la interpolación genera TEXT y rompe las FK constraints.
- **`CURRENT_TIMESTAMP` en SQLite**: retorna UTC sin offset. El converter parsea strings sin offset como UTC (`DateTimeStyles` no aplica zona local).
- **Resultado**: 2219 tests, 13 fallos pre-existentes (CompanyApi/ContactApi sin DB real, HealthCheck, OperationCenterContact snapshot).

## Convenciones

- **Namespaces K8s:** kebab-case (`access-manager`, `app-shell`, `segments`, `base-config`, `observability`)
- **API Gateway:** `/api/{prefijo}/*` → reescribe → `/api/v1/{prefijo}/*`. Ver `docs/mfe-conventions.md`
- **MFE Gateway:** `/mfe/{service-name}/*` → reescribe a `/` → nginx del MFE
- **Docker tags:** commit SHA (inmutables)
- **Terraform modules:** `terraform/modules/{recurso}/` | **Dapr components base:** `k8s/base/dapr/` | **Dapr components overlay:** `k8s/overlays/{env}/dapr/{service-name}/`
- **`cloudbuild-deploy.yaml` heredoc:** regenera `kustomization.yaml` en runtime — nuevos patches van en el archivo del repo Y en el heredoc del Cloud Build config
- **MFE build:** `vite-plugin-single-spa` con `type: 'mife'`, `base: '/mfe/{service-name}/'`. Ver `docs/mfe-conventions.md`
- **Puertos locales:** backends `70xx` (inc. 2), MFEs `80xx`. Tabla canónica: app-shell —/8011, access-manager 7010/8010, segments 7012/8012, base-config 7014/8014, third-party 7016/8016, accounting 7018/8018, liquid-tax 7020/8020. Ver `docs/developer-guide.md`.

## i18n — Internacionalización MFE

Cambio de idioma del app-shell → event `siesa:language-changed` en `window`. Aplicar en todo MFE nuevo:

| Archivo | Cambio |
|---|---|
| `src/frontend/src/core/i18n/config.ts` | Leer `localStorage.getItem('language')` + listener `siesa:language-changed` → `i18n.changeLanguage` |
| `src/frontend/src/core/api/client.ts` | `config.headers['Accept-Language'] = i18n.language` en interceptor de request |
| `src/frontend/src/core/i18n/useMasterCrudLocale.ts` | Hook: `i18n.language.startsWith('en') ? 'en' : 'es'` |
| Cada página con `<MasterCrud>` | `locale={masterCrudLocale}` — sin esto MasterCrud siempre muestra español |

> `siesa-ui-kit` MasterCrud ignora el contexto i18n de la app. `useTranslation()` hace el locale reactivo al cambio de idioma. El header `Accept-Language` activa localización en ASP.NET Core.

**Column labels en grid — patrón `useXxxDefinition()`:** Los archivos `*.definition.ts` deben exportar un hook `useXxxDefinition()` (NO un `const`) que use `useTranslation()`. Un `const` se evalúa una sola vez y los labels no reaccionan al cambio de idioma. Keys en JSON: `columns.{fieldName}`, `sections.{sectionKey}`.

```typescript
// ✅ Correcto — reactivo al idioma
export function useFiscalYearDefinition(): MasterPatternViewDefinition {
  const { t } = useTranslation('fiscal-years');
  return { fields: [{ fieldName: 'code', label: t('columns.code'), ... }] };
}

// ❌ Incorrecto — hardcodeado
export const fiscalYearDefinition: MasterPatternViewDefinition = {
  fields: [{ fieldName: 'code', label: 'Código', ... }],
};
```

## Access Manager — Patrón de Permisos

- **Snapshot endpoints — guard `dapr-caller-app-id` obligatorio:** Todo `*/snapshot` requiere middleware `app.Use(...)` que rechace con 403 si falta el header `dapr-caller-app-id`. El guard va ANTES del `UseWhen` de auth, independiente del environment/mockEnabled. Aplicar en todo servicio nuevo con `/snapshot`.
- **Registro de permisos:** Manual (una vez por entorno) vía `POST /internal/v1/permissions/register`. Headers: `X-Api-Key` + `X-Microservice-Source`. **No auto-registrar en startup** (patrón eliminado).
- **`InternalApiKey` vs `InternalApi__Key`:** El filtro lee `configuration["InternalApiKey"]` (clave plana). El env var `InternalApi__Key` mapea a `InternalApi:Key` — **no es leído**. Configurar `InternalApiKey` sin doble guión bajo.
- **Formato del permiso:** `Resource="{prefix}.{entity-plural-kebab}"` + `Action="{acción}"`. Cadena en Redis = `Resource + "." + Action`. Prefijos: `segment`, `base-config`, `third-party`, `tax`, `acct`. Entidad/prefijo: kebab-case; acción: snake_case. Ver `docs/troubleshooting.md#access-manager--permisos`.
- **`RequirePermission` — prefijo obligatorio:** `"segment.fiscal-years.read"` ✅ / `"fiscal-years.read"` ❌.
- **Schema en `IEntityTypeConfiguration` — siempre `"base_config"`:** `builder.ToTable(tabla, "base_config")`. El schema `"base-config"` (con guión) genera un schema huérfano. Ver `docs/troubleshooting.md § EF Core Migrations`.
- **`apiClient.baseURL` — NUNCA `/api/v1`:** El `baseURL` en `shared/http/apiClient.ts` DEBE ser `'/api/base-config'`. No existe HTTPRoute para `/api/v1` en el Gateway.
- **`VITE_API_BASE_URL` — alinear con patrón HTTPRoute:** Patrón 1 (base-config): un HTTPRoute `/api/base-config/*` → `VITE_API_BASE_URL=/api/base-config`. Patrón 2 (segments): un HTTPRoute por recurso → `VITE_API_BASE_URL=/api`. Si no coincide, Gateway devuelve HTML → `MasterPatternView` crashea en `.filter()`.
- **Llamadas cross-service desde MFE — NUNCA usar `apiClient` del servicio propio:** `apiClient` tiene `baseURL` del servicio y enruta al servicio equivocado. Usar siempre `fetch()` con path absoluto `/api/{entity-prefix}/...` + headers `Authorization: Bearer` y `X-Company-Id`. Actualizar también el proxy Vite dev. Ver `docs/troubleshooting.md § LookupField`.
- **`createFetcher` de siesa-ui-kit — NO incluye `Authorization: Bearer`:** En servicios con JWT global (segments, accounting, third-party), usar un `Fetcher` custom en `lookupConfig.fetcher` que lea `access_manager_user_token` de localStorage. `createFetcher` omite el header → 401. El fetcher custom debe definirse a nivel de módulo (nunca dentro de un hook/componente — patrón UIK-007). Ver `docs/troubleshooting.md § createFetcher`.
- **`BuildUserContext` / `ResolveUserId` — fallback JWT obligatorio:** `GeographicEndpointHelpers.ResolveUserId` debe parsear JWT desde `Authorization` header como fallback. Sin él, `Guid.Empty` → `ValidateUserCompanyAssignmentsAsync` rechaza todos los companyIds con 403.
- **`useCompanyContext` / hooks compañías — `apiClientDirect`, nunca `axios.create()` ad-hoc:** `axios.create()` local produce cliente sin interceptor `Authorization` → 401 y selector de compañías vacío. `apiClientDirect` tiene auth sin X-Company-Id.
- **Idempotent Consumer Pattern — obligatorio en todo consumer Pub/Sub:** (1) `IEventStore eventStore` inyectado; (2) `if (await EventHandlerGuard.IsDuplicateAsync(...)) return Results.Ok();`; (3) `await eventStore.MarkProcessedAsync(...)` tras la lógica. Ver `docs/idempotent-consumer-pattern.md`.
- **Checklist nuevo consumer Dapr Pub/Sub — 3 bugs silenciosos (endpoint retorna 200 pero descarta):** (1) TenantId productor = `ctx.GetTenantID()`, nunca `Guid.Empty` — `EventHandlerGuard.IsInvalidTenant` descarta silenciosamente; (2) `TenantId` en `appsettings.json` debe coincidir con JWT real (dev: `843a387f-4ae1-42f7-af9e-0b5a85022ec7`), no usar placeholder `00000000-...-0001`; (3) múltiples handlers en mismo topic → `TopicOptions { Match = "event.data.EventType == \"XxxEvent\"", Priority = N }` con `N` **único** por handler (Dapr 1.16+ falla con `duplicate priorities for 0`) + catch-all sin Match (evita NACK loop en GKE). Verificar: `curl http://localhost:{dapr-http-port}/dapr/subscribe`. Ver convenciones de Priority en `docs/troubleshooting.md`.
- **Transactional Outbox Pattern — implementado en segments, base-config, third-party, accounting:** `IDomainEventDispatcher` → `OutboxDomainEventDispatcher` escribe `DomainEventEnvelope<T>` a `{schema}.outbox_messages` dentro de la misma transacción EF. `OutboxProcessor` (BackgroundService) publica a Dapr cada 5s, batch 20, max 5 retries, `status='failed'` al agotar. Al onboardear nuevo servicio, implementar mismo patrón.
- **third-party — auth en GKE con `AccessManager:Mock:Enabled`:** 4 ajustes obligatorios: (1) omitir `AddAccessManagerAuthentication` en mock; (2) omitir middleware AM en mock; (3) bypass en endpoint filters cuando `IsDevelopment() || mockEnabled` — NO solo `IsDevelopment()`; (4) `SecurityExtensions`: cuando `mockEnabled=true` pero `!IsDevelopment()`, registrar `AllPermissionsGrantedService` (always-true) en lugar de `MockPermissionServiceAdapter` — en Production, `appsettings.Development.json` NO se carga → `DefaultPermissions` vacío → `MockPermissionServiceAdapter` retorna `false` → 403. Lo mismo aplica a `CompanyEndpoints`: el bypass `if (env.IsDevelopment() || mockEnabled)` retorna todas las empresas. Agregar `AccessManager__Mock__Enabled=true` en `k8s/base/deployment-api.yaml`.
- **`ISecurityServiceClient` — registrar `DevBypassSecurityClient` cuando `AccessManager:Mock:Enabled=true`:** `BaseMasterService.CreateAsync/UpdateAsync/DeleteAsync` llaman a `ISecurityServiceClient.CheckPermissionAsync(userId, Definition.Name, operation, companyId)` donde `Definition.Name` es el nombre C# de la entidad (ej. `"AccountingConcept"`), NO el formato de permiso registrado (`"acct.accounting-concepts"`). `SecurityServiceClient` (HTTP real) envía ese formato a access-manager → 403. Patrón correcto (tomado de segments-service): en `AddXxxSecurityClient()` registrar el HTTP client base + si `Development || mockEnabled` → `RemoveAll<ISecurityServiceClient>()` + `AddSingleton<ISecurityServiceClient, DevBypassSecurityClient>()` (siempre retorna `true`). Sin esto, `AccessManager:Mock:Enabled=true` no tiene efecto y todas las operaciones CRUD del MasterPattern devuelven "No tiene permisos".
- **Dapr — `tracing-config.yaml` obligatorio por namespace:** Sin él, `daprd` falla con `PermissionDenied` al solicitar certificado mTLS → CrashLoopBackOff. Aplicar: `kubectl apply -f k8s/base/dapr/tracing-config.yaml -n {namespace}`. Crear siempre `k8s/overlays/{env}/dapr/{service}/pubsub.yaml` y `secretstore.yaml` al agregar un servicio.
- **GKE Gateway — `HealthCheckPolicy` obligatoria por servicio:** Sin ella, GET a `/` → 404 en APIs .NET → 503. Usar TCP en puerto 8080 (API) y 80 (MFE). Patrón: `checkIntervalSec: 15`, `timeoutSec: 5`, `healthyThreshold: 1`, `unhealthyThreshold: 3`. Archivos en `k8s/overlays/{env}/healthcheck/{service}-{api|mfe}-hc.yaml`.
- **auto-migrate en startup:** `Program.cs` llama `db.Database.MigrateAsync()` en try/catch con log warning. Sin esto, `OutboxProcessor` crashea con `42P01` en primer arranque.
- **`Dapr__HttpPort` override obligatorio en GKE con `ASPNETCORE_ENVIRONMENT=Development`:** Si `appsettings.Development.json` fija `Dapr.HttpPort` a un puerto local (ej. `3510` en access-manager), el health check `dapr-sidecar` intentará conectar a ese puerto en lugar del `3500` estándar de GKE → `Cannot assign requested address (localhost:3510)` → CrashLoopBackOff. Fix: agregar `Dapr__HttpPort: "3500"` y `Dapr__GrpcPort: "50001"` en el `deployment.yaml` base. `DAPR_HTTP_PORT` (sin dobles guiones) NO sobrescribe `Dapr:HttpPort` — se necesita la forma con dobles guiones bajos.
- **access-manager — secrets K8s creados por `cloudbuild-deploy.yaml`:** Los secrets `access-manager-jwt-keys` (desde `accmgr-sandbox-jwt-private` y `accmgr-sandbox-jwt-public`) y `access-manager-secrets` (desde `accmgr-sandbox-db-connection`) son creados idempotentemente por el Cloud Build antes del `kubectl apply`. Esto es específico de access-manager — los demás servicios crean sus secrets via Terraform o manualmente.
- **access-manager — `IdentityService__BypassEncryptedHash: "true"` obligatorio en dev:** La identity API (`identity-api-dev.siesacloud.com`) no acepta el campo `encrypted_hash` en el body de validación de token. Si `BypassEncryptedHash=false` (default), access-manager envía ese campo → identity responde `VALIDATION_ERROR` → callback devuelve 401 → login queda en "Loading...". El env var debe estar en `k8s/overlays/dev/patches/api-env.yaml`.
- **Siesa.DocumentPattern NuGet — `ModelBuilderExtensions` obligatorio en DbContext:** Llamar `modelBuilder.ApplyDocumentPatternConfigurationsExcludingConsecutive()` para registrar `DocumentClassState` y `DocumentClassTransition` sin incluir `DocumentConsecutiveRowConfiguration` (cuando el servicio tiene su propia tabla de consecutivos). Usar `ApplyDocumentPatternConfigurations()` cuando se comparte la tabla estándar. Versión mínima: `0.1.2`.
- **Siesa.DocumentPattern — alinear versión en TODOS los proyectos del servicio:** Si `AccountingService.Infrastructure` → `0.1.2` pero `AccountingService.API` → `0.1.0-alpha.1`, NuGet lanza `NU1605` (downgrade detectado). Actualizar el `<PackageReference>` en API, Domain, Application e Infrastructure a la misma versión.
- **Accounting MFE — `BrowserRouter` con `basename="/app"`:** El app-shell monta el MFE bajo `/app/*`. Sin `basename`, las rutas relativas (`conceptos-contables`) no coinciden con la URL real (`/app/conceptos-contables`) → pantalla en blanco. Aplicar en todo MFE nuevo que use `react-router-dom`.
- **Accounting MFE — `AuthProvider` con `permissionsToken` prop:** El token de permisos llega via evento `siesa:tokens-updated` del app-shell. `App.tsx` escucha el evento con `useState` + `useEffect` y pasa el token a `<AuthProvider permissionsToken={token}>`. Sin esto, el MFE siempre usa el mock token y los permisos fallan en GKE.
- **MFE — NO externalizar `react`/`react-dom`/`single-spa-react` en `build.lib`:** El import map del proyecto solo tiene entradas para los MFEs de siesa, no para `react` ni `single-spa-react`. Externalizar causa `Failed to resolve module specifier "react"` en el browser. Bundlear todo (patrón segments): omitir `rollupOptions.external` en `vite.config.ts`.
- **Access Manager — expiración de sesión automática:** `AuthLayout` tiene `setupSessionTimer(userToken)` que dispara `initiateLogin(loginUrl, returnUrl)` exactamente cuando expira el `userToken`, sin esperar page reload. También hay `visibilitychange` listener que valida el token cuando el usuario vuelve a la pestaña. `returnUrl = pathname + search` para devolver al usuario al mismo lugar. Publicado en `@siesateams/access-manager@0.1.0-develop.20260511.143534`.
- **`@siesateams/access-manager` — versión correcta en MFEs:** Las versiones estables `0.1.1`, `0.1.2`, `0.1.3` cambiaron `extractPermissions` para esperar `permissions` como **array plano** — incompatible con el JWT del backend que genera formato objeto `{"resource": ["action"]}`. Usar siempre `0.1.0-develop.20260511.143534` (o `0.1.0-develop.20260416.194837`) que usa `Object.entries` y es compatible con el backend. Con versiones `0.1.1+` todos los permisos retornan `false` en `usePermissions` → "No tiene permisos para crear registros" en MasterPatternView.
