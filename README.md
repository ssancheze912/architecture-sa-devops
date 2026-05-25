# architecture-sa-devops

Infrastructure and deployment workspace for the **Siesa Business** financial platform on GCP. Contains IaC (Terraform), Kubernetes manifests, CI/CD templates, and operational documentation. There is no application source code here — only the artifacts that deploy the apps.

This repo is consumed by Siesa-Agents through the `/sa-init-devops` skill, which clones it into `_siesa-agents/devops/` so the DevOps skills (`/sa-aplicar`, `/sa-nuevo-servicio`, `/sa-auditar-servicio`, etc.) can operate against the deployment workspace they expect.

---

## Hub-and-Spoke Architecture

The platform follows GCP's Hub-and-Spoke model:

```
Hub (prj-sie-sb-fin-common)
  └── Artifact Registry  ← Docker images built ONCE by GH Actions
         ↓ pull (same SHA, no rebuild)
  ├── Spoke dev   prj-sie-fin-financiero-dev  → GKE + Cloud SQL + Pub/Sub
  ├── Spoke QA    prj-sie-fin-financiero-qa   → (upcoming)
  └── Spoke PROD  prj-sie-fin-financiero-prod → (upcoming)
```

| Concept | Description |
|---|---|
| **Hub** | Central GCP project for the BU. Hosts Artifact Registry and resources shared across environments. |
| **Spoke** | GCP project for a specific environment. Hosts GKE, Cloud SQL, secrets, and compute. |
| **Transversal** | A complete business domain (`financiero`, `comercial`, etc.) with its own Hub + Spokes. |

---

## CI/CD Deployment Flow

```
PR → Quality Gate → Merge to develop
  │
  └── GitHub Actions (ci-pipeline.yml)
        1. docker build API + MFE  (WIF, GITHUB_TOKEN for NuGet/npm)
        2. docker push → Artifact Registry in Hub  ({sha} immutable)
        3. Cloud Build (cloudbuild-deploy.yaml, worker pool in Spoke)
              ├── add temp IP to Master Authorized Networks
              ├── kubectl apply (kustomize overlays)
              ├── rollout status --timeout=300s
              └── restore Master Authorized Networks
```

**Golden rule:** one image per SHA. The same digest is promoted across Spokes without rebuilding.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Orchestration | GKE Autopilot — K8s 1.31, REGULAR channel |
| Database | Cloud SQL PostgreSQL v18 — one instance per env, single DB per BU, schemas per service |
| Registry | Artifact Registry — Hub project, 1 Docker repo per service |
| Gateway | GKE Gateway API v1 — external L7, HTTPS + HTTP redirect, Cloud Armor WAF |
| Service mesh | Dapr 1.17.3 — pub/sub, state, secrets, mTLS |
| State store | Redis — StatefulSet in `dapr-system` |
| Pub/Sub | Cloud Pub/Sub — `disableEntityManagement: true`, one topic per service |
| Secrets | GCP Secret Manager — Dapr component |
| Observability | Jaeger all-in-one v1.57 + OTel Collector 0.149.0 |
| CI/CD | GitHub Actions + Cloud Build — WIF, no JSON keys |
| IaC | Terraform 1.14 — `environments/{env}.yaml` as source of truth |

---

## Repository Structure

```
architecture-sa-devops/
├── environments/                  ← SOURCE OF TRUTH per environment
│   ├── shared.yaml               ← Hub project (AR), WIF, SAs, Worker Pool
│   ├── dev.yaml                  ← Active dev environment
│   ├── staging.yaml              ← Template
│   └── prod.yaml                 ← Template
├── terraform/
│   ├── bootstrap/                ← First-time GCP project setup
│   ├── modules/                  ← Reusable generic modules
│   └── environments/
│       ├── shared/main.tf        ← Reads shared.yaml — never destroy
│       └── dev/main.tf           ← Reads dev.yaml
├── k8s/
│   ├── base/                     ← Generic resources (Dapr, Redis, Jaeger)
│   └── overlays/dev/             ← Environment-specific resources
│       ├── dapr/                 ← Dapr components per service
│       ├── routes/               ← Gateway HTTPRoutes
│       ├── healthcheck/          ← HealthCheckPolicies per service
│       └── import-map/           ← MFE import map
├── cicd-templates/
│   └── .github/workflows/
│       └── ci-pipeline.yml       ← Template copied into each service repo
├── scripts/
│   ├── dev-connect.sh            ← Local Cloud SQL connection
│   └── dapr-local/               ← In-memory Dapr config for local dev
├── docs/
│   ├── troubleshooting.md        ← Known issues and fixes
│   ├── tech-debt.md              ← Tech debt and pending decisions
│   ├── developer-guide.md        ← Local setup, ports, credentials
│   ├── onboarding.md             ← Day one in the project
│   ├── mfe-conventions.md        ← MFE conventions (routing, build, i18n)
│   ├── architecture-presentation.md ← Mermaid architecture diagrams
│   └── devops-org/               ← Organizational SRE reference skills
│       ├── ip-plan.md            ← Hub-and-Spoke IP plan (source of truth)
│       ├── sre-skill-iac-sentinel.md
│       └── sre-skill-cicd-architect.md
├── CLAUDE.md                     ← Project context for Claude Code
└── README.md                     ← This file
```

> **Note:** the original `business-financiero-deploy` repo carried a `.claude/commands/` folder with the DevOps slash commands. Those commands have been migrated to Siesa-Agents as Claude Code skills under `.claude/skills/sa-*/` (see "Claude Code skills" below) and are no longer present in this repo. GitHub Actions workflows (originally under `.github/workflows/`) also live in Siesa-Agents now, because GitHub only fires workflows from the repository they belong to.

---

## Claude Code skills

The DevOps automation that used to live in `.claude/commands/` has been promoted to Claude Code **skills** in the Siesa-Agents project. Convention: `/sa-*` skills generate or operate, with the SRE Sentinel reviewing first.

### Recommended flow

```
/sa-agent-sre-sentinel {mode} {args}     ← 1. Validate first
        ↓  ✅ APPROVED
/sa-{mode} {args}                        ← 2. Generate the artifacts
        ↓
/sa-aplicar                              ← 3. Commit + push + pipeline monitoring
```

### Available skills

| Skill | Purpose |
|---|---|
| `/sa-nueva-transversal {name} {suite} {project-id}` | Full scaffolding for a new `business-{name}-deploy` repo |
| `/sa-nuevo-servicio {name} {api-port} {mfe-port} [--no-mfe]` | Adds a microservice: Dapr, K8s routes, healthcheck, CI pipeline |
| `/sa-nuevo-ambiente {staging\|prod}` | Generates `environments/{env}.yaml` from the template |
| `/sa-aplicar` | Validates, commits with conventional format, pushes to main, and monitors the pipeline. On failure: diagnoses and repairs, or escalates |
| `/sa-onboard-db {schema} {owner-role}` | DDL GRANTs to enable the `dev` user on a new PostgreSQL schema |
| `/sa-registrar-permisos {service} {prefix} {entity...}` | Generates the `curl` to register permissions in access-manager |
| `/sa-auditar-servicio {name} [--no-mfe]` | Audits artifacts and CI/CD for a service — detects gaps and offers to fix them |

### Sentinel agent

| Skill | Purpose |
|---|---|
| `/sa-agent-sre-sentinel nueva-transversal {name} {suite} {project-id}` | Validates 7 guardrails: naming, Hub-First, IP overlap, Registry-First, AR in Hub, Host VPC, mandatory labels |
| `/sa-agent-sre-sentinel nuevo-servicio {name}` | Validates 7 guardrails: Production-Ready, API Guard, WI binding, AR in Hub, secret naming, immutable artifacts |
| `/sa-agent-sre-sentinel propuesta "{description}"` | Evaluates any free-form architectural proposal against SIESA principles |

### Sentinel guardrails

The agent blocks (`❌ FAIL`) on:
- A `PROJECT_ID` that does not match `{type}-sie-{bu}-{workload}-{env}`
- Spoke vending without an existing Hub project (Hub-First Mandate)
- IP not registered in `ip-plan.md` before generating Terraform (Registry-First)
- Modification of resources in Host VPC projects (`prj-sie-com-vpc-host-*`)
- Plain environment-variable secrets
- JSON keys instead of WIF
- SystemJS instead of native ESM for MFEs

---

## Cloud SQL — per-environment configuration

One instance per environment, single database per BU (`finance-{env}`), separate schemas per service.

| Parameter | Dev | Staging | Prod |
|---|---|---|---|
| Instance | `pgsql-fin-sandbox-dev` | `pgsql-fin-financiero-stg` | TBD |
| Database | `finance-dev` | `finance-stg` | TBD |
| Tier | `db-g1-small` | `db-g1-small` | TBD |
| Availability | `ZONAL` | `REGIONAL` (HA) | `REGIONAL` (HA) |
| Connectivity | Public IP + Auth Proxy sidecar | Private IP (Shared VPC) | Private IP (Shared VPC) |
| Shared VPC host | `prj-sie-com-vpc-host-dev` | `prj-sie-com-vpc-host-stg` | `prj-sie-com-vpc-host-prod` |

**Module configuration (all environments):**
- Backup: daily 04:00 UTC (11 PM COT), 7 copies, PITR 7 days WAL
- Maintenance: Sunday 06:00 UTC (1 AM COT), `stable` track
- Query logging: `log_min_duration_statement = 1000ms` (queries > 1s)
- `deletion_protection = true` — the instance cannot be accidentally deleted

**Schemas per service (shared single DB):**

| Schema | Owner role | Service |
|---|---|---|
| `access_manager` | `accmgr` | Access Manager |
| `segment` | `segments` | Segments |
| `base_config` | `base_config` | Base Config |
| `tprt` | `third_party` | Third Party |
| `acct` | `accounting` | Accounting |
| `liquid_tax` | `liquid_tax` | Liquid Tax |

**Dev connection:** Auth Proxy sidecar in each pod → `127.0.0.1:5432`. `Maximum Pool Size=3`. See [`docs/developer-guide.md`](docs/developer-guide.md) for local connection details.

## Active environment

| Resource | Value |
|---|---|
| GCP project (Spoke dev) | `prj-sie-fin-financiero-dev` |
| Hub project | `prj-sie-sb-fin-common` *(pending AR migration)* |
| GKE cluster | `gke-sie-fin-sandbox-dev` |
| Cloud SQL | `pgsql-fin-sandbox-dev` — DB `finance-dev` |
| Domain | `finance.siesacloud.dev` |
| Region | `us-east1` |

### Deployed services

| Service | Namespace | Repo |
|---|---|---|
| Access Manager | `access-manager` | `SiesaTeams/business-access-manager` |
| App Shell | `app-shell` | `SiesaTeams/business-financiero-app-shell` |
| Segments | `segments` | `SiesaTeams/business-financiero-segments-service` |
| Base Config | `base-config` | `SiesaTeams/business-financiero-base-config` |
| Third Party | `third-party` | `SiesaTeams/business-financiero-third-party-service` |
| Accounting | `accounting` | `SiesaTeams/business-financiero-accounting-service` |
| Liquid Tax | `liquid-tax` | `SiesaTeams/business-financiero-liquid-tax-service` |

---

## Quick onboarding

### Add a new service

```bash
# 1. Validate before acting
/sa-agent-sre-sentinel nuevo-servicio treasury

# 2. Generate the artifacts
/sa-nuevo-servicio treasury 7022 8022

# 3. Onboard the database
/sa-onboard-db treasury_schema treasury_owner

# 4. Register permissions in access-manager (after the first deploy)
/sa-registrar-permisos treasury trs treasury-accounts treasury-transactions
```

### Add a new transversal

> **Full beginner's guide:** [`docs/guia-principiantes.md`](docs/guia-principiantes.md)

The starting point is the `scaffold` branch of this repo — it contains only the generic content (TF modules, k8s/base, scripts, skills) without anything financial-specific:

```bash
# 1. Fork SiesaTeams/architecture-sa-devops and switch to the scaffold branch
git checkout scaffold

# 2. Validate before generating (includes IP plan and Hub project)
/sa-agent-sre-sentinel nueva-transversal comercial com prj-sie-com-comercial-dev

# 3. Register CIDRs in docs/devops-org/ip-plan.md §3.1 and commit

# 4. Generate every artifact (environments, terraform, workflows)
/sa-nueva-transversal comercial com prj-sie-com-comercial-dev
```

### Local development setup

See [`docs/developer-guide.md`](docs/developer-guide.md) for:
- Cloud SQL connection via Auth Proxy (`scripts/dev-connect.sh`)
- Local ports per service (API `70xx`, MFE `80xx`)
- Credentials and environment variables

---

## Mandatory rules

1. **Terraform is the only source of truth for GCP infrastructure.** Manual creation or modification of resources is forbidden. Every manual change must be imported into TF state.

2. **Every change in this repo requires updating `CLAUDE.md` and `docs/troubleshooting.md`** when applicable. Without these updates, AI assistants lose context. (`.gemini/GEMINI.md` from the original `business-financiero-deploy` repo is not mirrored here.)

3. **Host VPC Inviolability.** Never modify resources in `prj-sie-com-vpc-host-*`. Only reference their networks from the Spokes.

4. **Zero-Touch Secrets.** No secret as a plain environment variable. Everything via Secret Manager.

5. **Immutable Artifacts.** One Docker image per SHA. Never rebuild the same code for different environments — promote the digest.

---

## Documentation

| Doc | Content |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Full project context for Claude Code |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Known issues and fixes |
| [`docs/tech-debt.md`](docs/tech-debt.md) | Tech debt and pending decisions |
| [`docs/developer-guide.md`](docs/developer-guide.md) | Local setup and development conventions |
| [`docs/mfe-conventions.md`](docs/mfe-conventions.md) | MFE routing, build, and i18n |
| [`docs/devops-org/ip-plan.md`](docs/devops-org/ip-plan.md) | Hub-and-Spoke IP plan — source of truth |
