# business-financiero-deploy

Repositorio de infraestructura y despliegue de la plataforma financiera **Siesa Business** sobre GCP. Contiene IaC (Terraform), manifiestos Kubernetes, templates CI/CD y documentación operativa. No hay código fuente de aplicaciones aquí.

---

## Arquitectura Hub-and-Spoke

La plataforma sigue el modelo Hub-and-Spoke de GCP:

```
Hub (prj-sie-sb-fin-common)
  └── Artifact Registry  ← imágenes Docker construidas UNA vez por GH Actions
         ↓ pull (mismo SHA, sin rebuild)
  ├── Spoke dev   prj-sie-fin-financiero-dev  → GKE + Cloud SQL + Pub/Sub
  ├── Spoke QA    prj-sie-fin-financiero-qa   → (próximo)
  └── Spoke PROD  prj-sie-fin-financiero-prod → (próximo)
```

| Concepto | Descripción |
|---|---|
| **Hub** | Proyecto GCP central de la BU. Aloja Artifact Registry y recursos compartidos entre ambientes. |
| **Spoke** | Proyecto GCP de un ambiente específico. Aloja GKE, Cloud SQL, secretos y cómputo. |
| **Transversal** | Un dominio de negocio completo (`financiero`, `comercial`, etc.) con su propio Hub + Spokes. |

---

## Flujo de Despliegue CI/CD

```
PR → Quality Gate → Merge a develop
  │
  └── GitHub Actions (ci-pipeline.yml)
        1. docker build API + MFE  (WIF, GITHUB_TOKEN para NuGet/npm)
        2. docker push → Artifact Registry en Hub  ({sha} inmutable)
        3. Cloud Build (cloudbuild-deploy.yaml, worker pool en Spoke)
              ├── agrega IP temporal a Master Authorized Networks
              ├── kubectl apply (kustomize overlays)
              ├── rollout status --timeout=300s
              └── restaura Master Authorized Networks
```

**Regla de oro:** una imagen por SHA. El mismo digest se promueve entre Spokes sin rebuild.

---

## Stack Técnico

| Capa | Tecnología |
|---|---|
| Orquestación | GKE Autopilot — K8s 1.31, REGULAR channel |
| Base de datos | Cloud SQL PostgreSQL v18 — una instancia por ambiente, BD única por BU, schemas por servicio |
| Registry | Artifact Registry — Hub project, 1 repo Docker por servicio |
| Gateway | GKE Gateway API v1 — L7 externo, HTTPS + HTTP redirect, Cloud Armor WAF |
| Service mesh | Dapr 1.17.3 — pub/sub, state, secrets, mTLS |
| State store | Redis — StatefulSet en `dapr-system` |
| Pub/Sub | Cloud Pub/Sub — `disableEntityManagement: true`, un topic por servicio |
| Secrets | GCP Secret Manager — Dapr component |
| Observabilidad | Jaeger all-in-one v1.57 + OTel Collector 0.149.0 |
| CI/CD | GitHub Actions + Cloud Build — WIF sin JSON keys |
| IaC | Terraform 1.14 — `environments/{env}.yaml` como fuente de verdad |

---

## Estructura del Repositorio

```
business-financiero-deploy/
├── environments/                  ← FUENTE DE VERDAD por ambiente
│   ├── shared.yaml               ← Hub project (AR), WIF, SAs, Worker Pool
│   ├── dev.yaml                  ← Ambiente dev activo
│   ├── staging.yaml              ← Template
│   └── prod.yaml                 ← Template
├── terraform/
│   ├── bootstrap/                ← Primer setup del proyecto GCP
│   ├── modules/                  ← Módulos genéricos reutilizables
│   └── environments/
│       ├── shared/main.tf        ← Lee shared.yaml — nunca destruir
│       └── dev/main.tf           ← Lee dev.yaml
├── k8s/
│   ├── base/                     ← Recursos genéricos (Dapr, Redis, Jaeger)
│   └── overlays/dev/             ← Recursos específicos del ambiente
│       ├── dapr/                 ← Components Dapr por servicio
│       ├── routes/               ← HTTPRoutes del Gateway
│       ├── healthcheck/          ← HealthCheckPolicies por servicio
│       └── import-map/           ← Import map de MFEs
├── cicd-templates/
│   └── .github/workflows/
│       └── ci-pipeline.yml       ← Template copiado a cada repo de servicio
├── scripts/
│   ├── dev-connect.sh            ← Conexión local a Cloud SQL
│   └── dapr-local/               ← Configuración Dapr in-memory para dev local
├── docs/
│   ├── troubleshooting.md        ← Problemas conocidos y soluciones
│   ├── tech-debt.md              ← Deuda técnica y decisiones pendientes
│   ├── developer-guide.md        ← Setup local, puertos, credenciales
│   ├── onboarding.md             ← Primer día en el proyecto
│   ├── mfe-conventions.md        ← Convenciones de MFEs (routing, build, i18n)
│   ├── architecture-presentation.md ← Diagramas Mermaid de la arquitectura
│   └── devops-org/               ← Skills SRE de referencia organizacional
│       ├── ip-plan.md            ← Plan de IPs Hub-and-Spoke (fuente de verdad)
│       ├── sre-skill-iac-sentinel.md
│       └── sre-skill-cicd-architect.md
└── .claude/commands/             ← Slash commands para Claude Code
    ├── flow-nueva-transversal.md
    ├── flow-nuevo-servicio.md
    ├── flow-nuevo-ambiente.md
    ├── flow-aplicar.md
    ├── flow-onboard-db.md
    ├── flow-registrar-permisos.md
    ├── flow-auditar-servicio.md
    └── agent-sre-sentinel.md
```

---

## Flows y Agentes (Claude Code)

Este repositorio usa **Claude Code** con slash commands para automatizar operaciones repetitivas. Convención: `/flow-*` genera artefactos, `/agent-*` revisa y valida.

### Flujo recomendado

```
/agent-sre-sentinel {modo} {args}     ← 1. Valida primero
        ↓  ✅ APROBADO
/flow-{modo} {args}                   ← 2. Genera los artefactos
        ↓
/flow-aplicar                         ← 3. Commit + push + monitoreo del pipeline
```

### Flows disponibles

| Comando | Propósito |
|---|---|
| `/flow-nueva-transversal {nombre} {suite} {project-id}` | Scaffolding completo para un nuevo repo `business-{nombre}-deploy` |
| `/flow-nuevo-servicio {nombre} {api-port} {mfe-port} [--no-mfe]` | Agrega un microservicio: Dapr, K8s routes, healthcheck, CI pipeline |
| `/flow-nuevo-ambiente {staging\|prod}` | Genera `environments/{ambiente}.yaml` desde el template |
| `/flow-aplicar` | Valida, commit con formato convencional, push a main y monitorea el pipeline. Si falla: diagnostica y repara o escala |
| `/flow-onboard-db {schema} {owner-role}` | DDL de GRANTs para habilitar el usuario `dev` en un schema PostgreSQL nuevo |
| `/flow-registrar-permisos {servicio} {prefijo} {entidad...}` | Genera el `curl` de registro de permisos en access-manager |
| `/flow-auditar-servicio {nombre} [--no-mfe]` | Audita artefactos y CI/CD de un servicio — detecta gaps y ofrece corregirlos |

### Agentes disponibles

| Comando | Propósito |
|---|---|
| `/agent-sre-sentinel nueva-transversal {nombre} {suite} {project-id}` | Valida 7 guardrails: naming, Hub-First, IP overlap, Registry-First, AR en Hub, Host VPC, mandatory labels |
| `/agent-sre-sentinel nuevo-servicio {nombre}` | Valida 7 guardrails: Production-Ready, API Guard, WI binding, AR en Hub, secret naming, immutable artifacts |
| `/agent-sre-sentinel propuesta "{descripción}"` | Evalúa cualquier propuesta arquitectónica libre contra los principios SIESA |

### Guardrails del Sentinel

El agente bloquea (`❌ FAIL`) si detecta:
- `PROJECT_ID` que no cumple `{type}-sie-{bu}-{workload}-{env}`
- Spoke vending sin Hub project existente (Hub-First Mandate)
- IP sin registrar en `ip-plan.md` antes de generar Terraform (Registry-First)
- Modificación de recursos en Host VPC projects (`prj-sie-com-vpc-host-*`)
- Secretos como variables de entorno planas
- JSON keys en lugar de WIF
- SystemJS en lugar de ESM nativo para MFEs

---

## Cloud SQL — Configuración por Ambiente

Una instancia por ambiente, base de datos única por BU (`finance-{env}`), schemas separados por servicio.

| Parámetro | Dev | Staging | Prod |
|---|---|---|---|
| Instancia | `pgsql-fin-sandbox-dev` | `pgsql-fin-financiero-stg` | TBD |
| Base de datos | `finance-dev` | `finance-stg` | TBD |
| Tier | `db-g1-small` | `db-g1-small` | TBD |
| Availability | `ZONAL` | `REGIONAL` (HA) | `REGIONAL` (HA) |
| Conectividad | IP pública + Auth Proxy sidecar | IP privada (Shared VPC) | IP privada (Shared VPC) |
| Shared VPC host | `prj-sie-com-vpc-host-dev` | `prj-sie-com-vpc-host-stg` | `prj-sie-com-vpc-host-prod` |

**Configuración del módulo (todos los ambientes):**
- Backup: diario 04:00 UTC (11 PM COT), 7 copias, PITR 7 días WAL
- Mantenimiento: domingo 06:00 UTC (1 AM COT), track `stable`
- Query logging: `log_min_duration_statement = 1000ms` (queries > 1s)
- `deletion_protection = true` — no se puede eliminar la instancia accidentalmente

**Schemas por servicio (BD única compartida):**

| Schema | Owner role | Servicio |
|---|---|---|
| `access_manager` | `accmgr` | Access Manager |
| `segment` | `segments` | Segments |
| `base_config` | `base_config` | Base Config |
| `tprt` | `third_party` | Third Party |
| `acct` | `accounting` | Accounting |
| `liquid_tax` | `liquid_tax` | Liquid Tax |

**Conexión en dev:** Auth Proxy sidecar en cada pod → `127.0.0.1:5432`. `Maximum Pool Size=3`. Ver [`docs/developer-guide.md`](docs/developer-guide.md) para conexión local.

## Ambiente Activo

| Recurso | Valor |
|---|---|
| Proyecto GCP (Spoke dev) | `prj-sie-fin-financiero-dev` |
| Hub project | `prj-sie-sb-fin-common` *(pendiente migración AR)* |
| Cluster GKE | `gke-sie-fin-sandbox-dev` |
| Cloud SQL | `pgsql-fin-sandbox-dev` — BD `finance-dev` |
| Dominio | `finance.siesacloud.dev` |
| Región | `us-east1` |

### Servicios desplegados

| Servicio | Namespace | Repo |
|---|---|---|
| Access Manager | `access-manager` | `SiesaTeams/business-access-manager` |
| App Shell | `app-shell` | `SiesaTeams/business-financiero-app-shell` |
| Segments | `segments` | `SiesaTeams/business-financiero-segments-service` |
| Base Config | `base-config` | `SiesaTeams/business-financiero-base-config` |
| Third Party | `third-party` | `SiesaTeams/business-financiero-third-party-service` |
| Accounting | `accounting` | `SiesaTeams/business-financiero-accounting-service` |
| Liquid Tax | `liquid-tax` | `SiesaTeams/business-financiero-liquid-tax-service` |

---

## Onboarding Rápido

### Agregar un nuevo servicio

```bash
# 1. Validar antes de actuar
/agent-sre-sentinel nuevo-servicio treasury

# 2. Generar artefactos
/flow-nuevo-servicio treasury 7022 8022

# 3. Onboardear la base de datos
/flow-onboard-db treasury_schema treasury_owner

# 4. Registrar permisos en access-manager (tras primer deploy)
/flow-registrar-permisos treasury trs treasury-accounts treasury-transactions
```

### Agregar una nueva transversal

> **Guía completa para principiantes:** [`docs/guia-principiantes.md`](docs/guia-principiantes.md)

El punto de partida es la rama `scaffold` de este repo — contiene solo el contenido genérico (módulos TF, k8s/base, scripts, flows) sin nada específico de financiero:

```bash
# 1. Hacer fork de SiesaTeams/business-financiero-deploy y cambiar a rama scaffold
git checkout scaffold

# 2. Validar antes de generar (incluye IP plan y Hub project)
/agent-sre-sentinel nueva-transversal comercial com prj-sie-com-comercial-dev

# 3. Registrar CIDRs en docs/devops-org/ip-plan.md §3.1 y hacer commit

# 4. Generar todos los artefactos (environments, terraform, workflows)
/flow-nueva-transversal comercial com prj-sie-com-comercial-dev
```

### Setup local de desarrollo

Ver [`docs/developer-guide.md`](docs/developer-guide.md) para:
- Conexión a Cloud SQL via Auth Proxy (`scripts/dev-connect.sh`)
- Puertos locales por servicio (API `70xx`, MFE `80xx`)
- Credenciales y variables de entorno

---

## Reglas Obligatorias

1. **Terraform es la única fuente de verdad para infraestructura GCP.** Prohibido crear o modificar recursos manualmente. Todo cambio manual debe importarse al estado TF.

2. **Cada cambio en este repo requiere actualizar `CLAUDE.md`, `.gemini/GEMINI.md` y `docs/troubleshooting.md`** si aplica. Sin actualización, los asistentes AI pierden contexto.

3. **Host VPC Inviolability.** Nunca modificar recursos en `prj-sie-com-vpc-host-*`. Solo referenciar sus redes desde los Spokes.

4. **Zero-Touch Secrets.** Ningún secreto como variable de entorno plana. Todo vía Secret Manager.

5. **Immutable Artifacts.** Una imagen Docker por SHA. Nunca rebuild del mismo código para distintos ambientes — promover el digest.

---

## Documentación

| Doc | Contenido |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Contexto completo del proyecto para Claude Code |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Problemas conocidos y soluciones |
| [`docs/tech-debt.md`](docs/tech-debt.md) | Deuda técnica y decisiones pendientes |
| [`docs/developer-guide.md`](docs/developer-guide.md) | Setup local y convenciones de desarrollo |
| [`docs/mfe-conventions.md`](docs/mfe-conventions.md) | Routing, build y i18n de MFEs |
| [`docs/devops-org/ip-plan.md`](docs/devops-org/ip-plan.md) | Plan de IPs Hub-and-Spoke — fuente de verdad |
