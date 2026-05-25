# Presentación de Arquitectura — Plataforma Business Financiero

> **Siesa Business** · GKE Autopilot · GCP `us-east1` · `finance.siesacloud.dev`

---

## Índice

| # | Diagrama | Descripción |
|---|---|---|
| 1 | [Contexto del Sistema](#1-contexto-del-sistema) | Ecosistema y actores externos |
| 2 | [Mapa de Servicios](#2-mapa-de-servicios) | 6 microservicios + app shell en Kubernetes |
| 3 | [Frontend — Micro-Frontends](#3-frontend--micro-frontends) | SPA distribuida con import map |
| 4 | [Gateway y Routing HTTP](#4-gateway-y-routing-http) | URL rewriting, Cloud Armor, HTTPRoutes |
| 5 | [Arquitectura Event-Driven](#5-arquitectura-event-driven) | Cloud Pub/Sub: topics y suscripciones |
| 6 | [Dapr — Service Mesh Ligero](#6-dapr--service-mesh-ligero) | mTLS, state, secrets, cron bindings |
| 7 | [Infraestructura GCP](#7-infraestructura-gcp) | Todos los recursos cloud |
| 8 | [Base de Datos — Cloud SQL](#8-base-de-datos--cloud-sql) | Auth Proxy + schemas por servicio |
| 9 | [Pipeline CI/CD](#9-pipeline-cicd) | GitHub Actions + Cloud Build |
| 10 | [Observabilidad](#10-observabilidad) | Jaeger + OpenTelemetry Collector |
| 11 | [Seguridad en Capas](#11-seguridad-en-capas) | Cloud Armor → WIF → mTLS → JWT |
| 12 | [Reconciliación de Proyecciones](#12-reconciliación-de-proyecciones) | Cron bindings + sincronización de eventos |
| 13 | [Patrones Implementados](#13-patrones-implementados) | Catálogo de patrones por capa |

---

## 1. Contexto del Sistema

Vista de alto nivel: quién interactúa con la plataforma y qué sistemas externos son necesarios.

```mermaid
flowchart TB
    classDef person   fill:#08427b,stroke:#052e56,color:#fff,rx:50
    classDef internal fill:#1168bd,stroke:#0b4884,color:#fff
    classDef external fill:#555,stroke:#333,color:#fff
    classDef cloud    fill:#1a6e2e,stroke:#0e4a1d,color:#fff

    P1(["👤 Contador / Analista<br/>Financiero"]):::person
    P2(["👤 Administrador<br/>de Plataforma"]):::person

    subgraph PLAT["🏦  Plataforma Business Financiero"]
        direction TB
        GW["🌐 GKE Gateway L7<br/>+ Cloud Armor WAF"]:::internal
        AS["📦 App Shell<br/>single-spa · React"]:::internal
        SVC["⚙️ 6 Microservicios<br/>.NET 10 + React MFEs"]:::internal
        AM["🔐 Access Manager<br/>Autorización centralizada"]:::internal
        GW --> AS --> SVC
        SVC <-->|"permisos JWT"| AM
    end

    subgraph GCP["☁️  Google Cloud Platform  ·  us-east1"]
        direction LR
        GKE["GKE Autopilot 1.31"]:::cloud
        SQL["Cloud SQL<br/>PostgreSQL 18"]:::cloud
        PS["Cloud Pub/Sub<br/>Topics & Subs"]:::cloud
        SM["Secret Manager"]:::cloud
        AR["Artifact Registry<br/>Docker images"]:::cloud
        CM["Certificate Manager<br/>TLS automático"]:::cloud
    end

    IDP(["🔑 Identity Provider<br/>JWT / OIDC"]):::external
    GH(["🐙 GitHub<br/>Código + CI/CD"]):::external
    CB(["🔧 Cloud Build<br/>Worker Pool"]):::external
    DEV(["👨‍💻 Developer"]):::person

    P1 & P2 -->|"HTTPS · finance.siesacloud.dev"| GW
    PLAT -->|"desplegado en"| GKE
    SVC -->|"datos"| SQL
    SVC -->|"eventos"| PS
    SVC -->|"secretos"| SM
    SVC -->|"auth tokens"| IDP
    GH -->|"docker push (SHA)"| AR
    GH -->|"trigger deploy"| CB
    CB -->|"kubectl apply"| GKE
    DEV -->|"git push"| GH
    CM --> GW
```

---

## 2. Mapa de Servicios

Cada servicio tiene su propio namespace Kubernetes con una API (.NET 10) y un Micro-Frontend (React + Vite), más un sidecar Dapr y un proxy Cloud SQL.

```mermaid
flowchart LR
    classDef api    fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef mfe    fill:#0288d1,stroke:#01579b,color:#fff
    classDef infra  fill:#37474f,stroke:#263238,color:#fff
    classDef dapr   fill:#7b1fa2,stroke:#4a148c,color:#fff
    classDef shared fill:#2e7d32,stroke:#1b5e20,color:#fff

    subgraph GI["gateway-infra"]
        GW["🌐 GKE Gateway<br/>L7 HTTPS · Cloud Armor<br/>gke-l7-global-external-managed"]:::infra
    end

    subgraph NS_AS["app-shell"]
        direction TB
        AS_APP["📦 app-shell<br/>nginx · port 80"]:::mfe
        AS_IM["📋 import-map<br/>ConfigMap ESM JSON"]:::infra
        AS_APP --- AS_IM
    end

    subgraph NS_AM["access-manager"]
        direction TB
        AM_API["🔐 access-manager-api<br/>.NET 10 · port 8080"]:::api
        AM_MFE["access-manager-mfe<br/>React + Vite · port 80"]:::mfe
        AM_DP["⬡ dapr sidecar<br/>pub/sub · state · secrets"]:::dapr
    end

    subgraph NS_SEG["segments"]
        direction TB
        SEG_API["📊 segments-api<br/>.NET 10 · port 8080<br/>10 rutas Gateway"]:::api
        SEG_MFE["segments-mfe<br/>React + Vite · port 80"]:::mfe
        SEG_DP["⬡ dapr sidecar<br/>pub/sub · state · secrets · cron×5"]:::dapr
    end

    subgraph NS_BC["base-config"]
        direction TB
        BC_API["⚙️ base-config-api<br/>.NET 10 · port 8080"]:::api
        BC_MFE["base-config-mfe<br/>React + Vite · port 80"]:::mfe
        BC_DP["⬡ dapr sidecar<br/>pub/sub · secrets · cron×4"]:::dapr
    end

    subgraph NS_TP["third-party"]
        direction TB
        TP_API["🏢 third-party-api<br/>.NET 10 · port 8080"]:::api
        TP_MFE["third-party-mfe<br/>React + Vite · port 80"]:::mfe
        TP_DP["⬡ dapr sidecar<br/>pub/sub · secrets · cron×2"]:::dapr
    end

    subgraph NS_ACC["accounting"]
        direction TB
        ACC_API["📒 accounting-api<br/>.NET 10 · port 8080"]:::api
        ACC_MFE["accounting-mfe<br/>React + Vite · port 80"]:::mfe
        ACC_DP["⬡ dapr sidecar<br/>pub/sub · secrets"]:::dapr
    end

    subgraph NS_LT["liquid-tax"]
        direction TB
        LT_API["💰 liquid-tax-api<br/>.NET 10 · port 8080"]:::api
        LT_MFE["liquid-tax-mfe<br/>React + Vite · port 80"]:::mfe
        LT_DP["⬡ dapr sidecar<br/>pub/sub · secrets"]:::dapr
    end

    subgraph SHARED["dapr-system  ·  recursos compartidos"]
        direction TB
        DAPR_SYS["⬡ Dapr Control Plane<br/>sentry · operator · placement<br/>mTLS automático"]:::dapr
        REDIS["🗄️ Redis StatefulSet<br/>dapr-redis:6379<br/>1 Gi AOF"]:::shared
        SQL_P["🔌 Cloud SQL Auth Proxy<br/>sidecar en cada pod<br/>localhost:5432"]:::infra
    end

    GW -->|"/"| NS_AS
    GW -->|"/mfe/{svc} → /"| NS_AM & NS_SEG & NS_BC & NS_TP & NS_ACC & NS_LT
    GW -->|"/api/{prefix} → /api/v1"| NS_AM & NS_SEG & NS_BC & NS_TP & NS_ACC & NS_LT
    NS_AM & NS_SEG & NS_BC & NS_TP & NS_ACC & NS_LT -->|"sidecar"| SHARED
```

---

## 3. Frontend — Micro-Frontends

El App Shell es el host single-spa. Carga el import map desde Kubernetes y cada MFE se monta dinámicamente desde el CDN de GKE.

```mermaid
flowchart LR
    classDef browser  fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
    classDef mfe      fill:#0288d1,stroke:#01579b,color:#fff
    classDef shell    fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef config   fill:#f57f17,stroke:#e65100,color:#fff
    classDef gw       fill:#37474f,stroke:#263238,color:#fff

    BROWSER["🌐 Navegador<br/>ESM nativo"]:::browser

    subgraph NGINX_AS["nginx · app-shell (port 80)"]
        AS["📦 App Shell SPA<br/>single-spa · TanStack Router"]:::shell
        IM_JSON["/importmap.json<br/>{ @siesa/xxx → /mfe/xxx/spa-entry.js }"]:::config
    end

    subgraph GW_GKE["GKE Gateway  /mfe/*"]
        GW_NODE["URLRewrite: /mfe/{service}/* → /"]:::gw
    end

    subgraph MFE_PODS["MFE Pods  (nginx · port 80)"]
        MFE_AM["/mfe/access-manager/spa-entry.js"]:::mfe
        MFE_SEG["/mfe/segments/spa-entry.js"]:::mfe
        MFE_BC["/mfe/base-config/spa-entry.js"]:::mfe
        MFE_TP["/mfe/third-party/spa-entry.js"]:::mfe
        MFE_ACC["/mfe/accounting/spa-entry.js"]:::mfe
        MFE_LT["/mfe/liquid-tax/spa-entry.js"]:::mfe
    end

    BROWSER -->|"GET /"| AS
    AS -->|"GET /importmap.json"| IM_JSON
    IM_JSON -->|"registra módulos · @siesa/xxx"| AS
    AS -->|"import @siesa/access-manager"| GW_NODE
    AS -->|"import @siesa/segments"| GW_NODE
    AS -->|"import @siesa/base-config"| GW_NODE
    AS -->|"import @siesa/third-party"| GW_NODE
    AS -->|"import @siesa/accounting"| GW_NODE
    AS -->|"import @siesa/liquid-tax"| GW_NODE
    GW_NODE --> MFE_AM & MFE_SEG & MFE_BC & MFE_TP & MFE_ACC & MFE_LT

    note1["💡 Cada MFE es un módulo ESM<br/>independiente. Sin SystemJS.<br/>El browser resuelve las importaciones."]
```

---

## 4. Gateway y Routing HTTP

El GKE Gateway API L7 aplica URL rewriting: el frontend llama `/api/{prefijo}/*` y el Gateway reescribe a `/api/v1/{prefijo}/*` antes de llegar al backend.

```mermaid
flowchart TB
    classDef client   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef gw       fill:#37474f,stroke:#263238,color:#fff
    classDef route    fill:#4a148c,stroke:#311b92,color:#fff
    classDef backend  fill:#1b5e20,stroke:#003300,color:#fff
    classDef armor    fill:#b71c1c,stroke:#7f0000,color:#fff

    BROWSER["Browser / MFE<br/>calls /api/{prefix}/*"]:::client

    subgraph INGRESS["Entrada  ·  finance.siesacloud.dev"]
        CA["🛡️ Cloud Armor WAF<br/>OWASP SQLi + XSS rules"]:::armor
        GW_NODE["🌐 GKE Gateway<br/>gke-l7-global-external-managed<br/>Certificate Map TLS 1.3<br/>HTTP 80 → HTTPS 443 redirect"]:::gw
    end

    subgraph ROUTES["HTTPRoutes  (por namespace)"]
        direction TB
        R_ROOT["/ → app-shell:80"]:::route
        R_AM["  /api/access-manager/*<br/>→ URLRewrite /api/v1/*<br/>  /mfe/access-manager/* → /"]:::route
        R_SEG["  /api/segments/*  /api/base/*<br/>  /api/operation-centers/*<br/>  /api/business-units/*  …(10 rutas)<br/>→ URLRewrite /api/v1/*<br/>  /mfe/segments/* → /"]:::route
        R_BC["  /api/base-config/*<br/>→ URLRewrite /api/v1/*<br/>  /mfe/base-config/* → /"]:::route
        R_TP["  /api/third-party/*<br/>→ URLRewrite /api/v1/*<br/>  /mfe/third-party/* → /"]:::route
        R_ACC["  /api/accounting/*<br/>→ URLRewrite /api/v1/*<br/>  /mfe/accounting/* → /"]:::route
        R_LT["  /api/liquid-tax/*<br/>→ URLRewrite /api/v1/*<br/>  /mfe/liquid-tax/* → /"]:::route
        R_OBS["  /observability/jaeger/*<br/>→ jaeger:16686"]:::route
    end

    subgraph BACKENDS["Backends  (K8s Services)"]
        direction LR
        B_AS["app-shell:80"]:::backend
        B_AM["access-manager-api:8080<br/>access-manager-mfe:80"]:::backend
        B_SEG["segments-api:8080<br/>segments-mfe:80"]:::backend
        B_BC["base-config-api:8080<br/>base-config-mfe:80"]:::backend
        B_TP["third-party-api:8080<br/>third-party-mfe:80"]:::backend
        B_ACC["accounting-api:8080<br/>accounting-mfe:80"]:::backend
        B_LT["liquid-tax-api:8080<br/>liquid-tax-mfe:80"]:::backend
        B_JAE["jaeger:16686"]:::backend
    end

    BROWSER --> CA --> GW_NODE
    GW_NODE --> R_ROOT & R_AM & R_SEG & R_BC & R_TP & R_ACC & R_LT & R_OBS
    R_ROOT --> B_AS
    R_AM --> B_AM
    R_SEG --> B_SEG
    R_BC --> B_BC
    R_TP --> B_TP
    R_ACC --> B_ACC
    R_LT --> B_LT
    R_OBS --> B_JAE
```

**Regla crítica de routing:** el frontend **NUNCA** usa `/api/v1/...` en sus llamadas. El Gateway es la capa de indirección que añade la versión.

| HealthCheck | Tipo | Puerto | Intervalo |
|---|---|---|---|
| Todos los APIs | TCP | 8080 | 15s / timeout 5s |
| Jaeger UI | TCP | 16686 | 15s / timeout 5s |

---

## 5. Arquitectura Event-Driven

Los servicios se comunican mediante **Google Cloud Pub/Sub** a través de Dapr. Cada servicio tiene un topic propio; los consumidores se suscriben selectivamente. `disableEntityManagement: true` — Terraform crea todos los topics y suscripciones.

```mermaid
flowchart TB
    classDef producer fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef consumer fill:#2e7d32,stroke:#1b5e20,color:#fff
    classDef topic    fill:#e65100,stroke:#bf360c,color:#fff
    classDef future   fill:#888,stroke:#555,color:#fff,stroke-dasharray:5
    classDef note     fill:#fffde7,stroke:#f9a825,color:#333

    subgraph PRODUCERS["Productores"]
        direction LR
        AM_P["🔐 Access Manager"]:::producer
        SEG_P["📊 Segments"]:::producer
        BC_P["⚙️ Base Config"]:::producer
        TP_P["🏢 Third Party"]:::producer
        LT_P["💰 Liquid Tax (futuro)"]:::future
        TR_P["🏦 Treasury (futuro)"]:::future
    end

    subgraph TOPICS["Cloud Pub/Sub — Topics"]
        direction LR
        T_AM["access-manager-events"]:::topic
        T_SEG["segments-events"]:::topic
        T_BC["base-config-events"]:::topic
        T_TP["third-party-events (futuro)"]:::future
        T_LT["liquid-tax-events (futuro)"]:::future
        T_TR["treasury-events (futuro)"]:::future
    end

    subgraph CONSUMERS["Consumidores — naming: {consumer}-{topic}"]
        direction LR
        AM_C["🔐 Access Manager<br/>accessmanager-access-manager-events<br/>(invalida caché Redis)"]:::consumer
        BC_C["⚙️ Base Config<br/>base-config-access-manager-events<br/>base-config-segments-events"]:::consumer
        SEG_C["📊 Segments<br/>segments-access-manager-events<br/>segments-segments-events (self)"]:::consumer
        TP_C["🏢 Third Party<br/>5 suscripciones<br/>(access-manager · segments<br/>base-config · liquid-tax · treasury)"]:::consumer
    end

    note1["⚠️ Idempotent Consumer Pattern obligatorio:<br/>1 · Check eventStore (Redis) — 2 · Process — 3 · MarkProcessed"]:::note

    AM_P -->|"publica"| T_AM
    SEG_P -->|"publica"| T_SEG
    BC_P -->|"publica"| T_BC
    TP_P -->|"publica"| T_TP
    LT_P -.->|"futuro"| T_LT
    TR_P -.->|"futuro"| T_TR

    T_AM -->|"consume"| AM_C & BC_C & SEG_C & TP_C
    T_SEG -->|"consume"| SEG_C & BC_C & TP_C
    T_BC -->|"consume"| TP_C
    T_LT -.->|"futuro"| SEG_C & TP_C
    T_TR -.->|"futuro"| TP_C

    CONSUMERS --> note1
```

### Transactional Outbox Pattern

```mermaid
sequenceDiagram
    participant SVC as Servicio (.NET)
    participant DB as "Cloud SQL (outbox_messages)"
    participant OP as "OutboxProcessor (BackgroundService)"
    participant DAPR as Dapr Sidecar
    participant PS as Cloud Pub/Sub

    SVC->>DB: BEGIN TRANSACTION
    SVC->>DB: INSERT domain entity
    SVC->>DB: INSERT outbox_message (status=pending)
    SVC->>DB: COMMIT
    Note over DB: Atomicidad garantizada

    loop cada 5 segundos · batch 20
        OP->>DB: SELECT status=pending LIMIT 20
        DB-->>OP: mensajes pendientes
        OP->>DAPR: publishEvent(topic, payload)
        DAPR->>PS: publish message
        PS-->>DAPR: ack
        DAPR-->>OP: 200 OK
        OP->>DB: UPDATE status=processed
    end

    Note over OP: max 5 retries · status=failed al agotar
```

---

## 6. Dapr — Service Mesh Ligero

Dapr reemplaza la complejidad de Istio. Cada pod tiene un sidecar `daprd` que gestiona mTLS, pub/sub, state store, secrets y cron bindings.

```mermaid
flowchart TB
    classDef app      fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef dapr     fill:#7b1fa2,stroke:#4a148c,color:#fff
    classDef infra    fill:#37474f,stroke:#263238,color:#fff
    classDef gcp      fill:#1a6e2e,stroke:#0e4a1d,color:#fff

    subgraph POD["Pod (por servicio)"]
        direction LR
        APP["🔷 App Container<br/>.NET 10<br/>port 8080"]:::app
        DAPRD["⬡ daprd sidecar<br/>Dapr 1.17.3<br/>port 3500 (HTTP)<br/>port 50001 (gRPC)"]:::dapr
        SQLP["🔌 Cloud SQL<br/>Auth Proxy<br/>127.0.0.1:5432"]:::infra
        APP <-->|"localhost"| DAPRD
        APP <-->|"localhost"| SQLP
    end

    subgraph DAPR_COMPONENTS["Componentes Dapr  (por namespace)"]
        direction TB
        C_PS["pubsub<br/>gcp.pubsub<br/>disableEntityManagement: true"]:::dapr
        C_SS["statestore<br/>Redis · dapr-redis.dapr-system:6379<br/>(access-manager + segments)"]:::dapr
        C_SEC["secretstore<br/>gcp.secretmanager"]:::dapr
        C_CRON["cron bindings<br/>Base Config: 4 jobs · @every 1h<br/>Segments: 5 jobs · @every 1h<br/>Third Party: 2 jobs · @every 1h"]:::dapr
        C_TRACE["tracing-config<br/>sampling: 1 (100%)<br/>→ otel-collector:9411"]:::dapr
    end

    subgraph DAPR_SYSTEM["dapr-system namespace"]
        CTRL["⬡ Dapr Control Plane<br/>dapr-operator<br/>dapr-sentry (CA mTLS)<br/>dapr-placement"]:::dapr
        REDIS["🗄️ Redis StatefulSet<br/>dapr-redis:6379<br/>1Gi AOF"]:::infra
    end

    subgraph GCP_BACK["GCP Backends"]
        GCP_PS["☁️ Cloud Pub/Sub"]:::gcp
        GCP_SM["🔑 Secret Manager"]:::gcp
    end

    DAPRD --> C_PS & C_SS & C_SEC & C_CRON
    C_TRACE --> CTRL
    DAPRD <-->|"mTLS certs"| CTRL
    C_PS --> GCP_PS
    C_SS --> REDIS
    C_SEC --> GCP_SM
```

### Cron Bindings — Reconciliación Horaria

| Servicio | Jobs | Schedule | Endpoint |
|---|---|---|---|
| `base-config` | 4 | `@every 1h` | `/jobs/reconcile-{companies,operation-centers,user-company-assignments,users}` |
| `segments` | 5 | `@every 1h` | `/reconcile-{cities,countries,neighborhoods,states,users}` |
| `third-party` | 2 | `@every 1h` | `/reconcile-{companies,users}` |

---

## 7. Infraestructura GCP

Toda la infraestructura es **Terraform** — ningún recurso se crea manualmente.

```mermaid
flowchart TB
    classDef gke    fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef sql    fill:#e65100,stroke:#bf360c,color:#fff
    classDef net    fill:#2e7d32,stroke:#1b5e20,color:#fff
    classDef iam    fill:#6a1b9a,stroke:#4a148c,color:#fff
    classDef obs    fill:#37474f,stroke:#263238,color:#fff
    classDef ps     fill:#f57f17,stroke:#e65100,color:#fff

    subgraph PROJECT["GCP Project: prj-sie-fin-financiero-dev  ·  us-east1"]

        subgraph COMPUTE["Compute"]
            GKE["☸️ GKE Autopilot<br/>gke-sie-fin-sandbox-dev<br/>K8s 1.31 REGULAR channel<br/>Shared VPC · nodos privados<br/>Master Authorized Networks"]:::gke
            CB["🔧 Cloud Build Worker Pool<br/>financieropool<br/>VPC peering → API server"]:::gke
        end

        subgraph DATABASE["Base de Datos"]
            CSQL["🐘 Cloud SQL<br/>pgsql-fin-sandbox-dev<br/>PostgreSQL 18 · db-g1-small<br/>IP pública (Auth Proxy)<br/>PITR 7 días · backup 04:00 UTC"]:::sql
            DB["finance-dev<br/>(base única, schema por servicio)"]:::sql
            CSQL --> DB
        end

        subgraph MESSAGING["Mensajería"]
            PS["☁️ Cloud Pub/Sub<br/>6 topics + 15 subscriptions<br/>ack 60s · retención 7 días"]:::ps
        end

        subgraph NETWORKING["Networking"]
            VPC["Shared VPC<br/>vpc-sie-shared-dev<br/>(prj-sie-com-vpc-host-dev)"]:::net
            SUBNET["snt-sie-bus-fin-use1-dev<br/>pods: pods-fin-use1-dev<br/>services: svc-fin-use1-dev"]:::net
            DNS["Cloud DNS<br/>finance.siesacloud.dev<br/>A → Gateway IP"]:::net
            CM["Certificate Manager<br/>finance-siesacloud-dev-cert<br/>TLS 1.3"]:::net
            GLB["Cloud Load Balancer<br/>Global External Managed<br/>IP: 34.110.139.114"]:::net
            CA["Cloud Armor<br/>WAF OWASP rules"]:::net
        end

        subgraph SECURITY["Seguridad e Identidad"]
            WIF["Workload Identity Federation<br/>github.com/SiesaTeams<br/>sin JSON keys"]:::iam
            SA1["sa-sie-fin-accmgr-sql-dev"]:::iam
            SA2["sa-sie-fin-segments-sql-dev"]:::iam
            SA3["sa-sie-fin-baseconfig-sql-dev"]:::iam
            SA4["sa-sie-fin-tprt-sql-dev"]:::iam
            SM["🔑 Secret Manager<br/>DB connection strings<br/>por servicio"]:::iam
        end

        subgraph REGISTRY["Artefactos"]
            AR["📦 Artifact Registry<br/>1 repo Docker por servicio<br/>tags: commit SHA"]:::obs
        end

        subgraph MONITORING["Monitoreo"]
            MON["Cloud Monitoring<br/>Alerta backup SQL (Audit Log)<br/>Alerta disco > 80%"]:::obs
        end

    end

    GKE --- VPC & SUBNET
    GLB --- CA --- GKE
    CSQL --- VPC
    DNS --> GLB
    CM --> GLB
    GKE -.->|"Workload Identity"| SA1 & SA2 & SA3 & SA4
    SA1 & SA2 & SA3 & SA4 --> CSQL & PS & SM
    WIF -.->|"GitHub Actions"| AR
    AR --> GKE
    CSQL --> MON
```

---

## 8. Base de Datos — Cloud SQL

Una instancia PostgreSQL 18, una base de datos `finance-dev`, con **schemas separados por servicio**. Cada servicio se conecta a través del Cloud SQL Auth Proxy (sidecar).

```mermaid
flowchart TB
    classDef svc   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef proxy fill:#e65100,stroke:#bf360c,color:#fff
    classDef db    fill:#2e7d32,stroke:#1b5e20,color:#fff
    classDef schema fill:#4a148c,stroke:#311b92,color:#fff

    subgraph K8S["Kubernetes · namespace por servicio"]
        direction LR
        AM_SVC["access-manager-api"]:::svc
        SEG_SVC["segments-api"]:::svc
        BC_SVC["base-config-api"]:::svc
        TP_SVC["third-party-api"]:::svc
        ACC_SVC["accounting-api"]:::svc
        LT_SVC["liquid-tax-api"]:::svc
    end

    subgraph PROXY_LAYER["Cloud SQL Auth Proxy  (sidecar por pod)"]
        P1["localhost:5432<br/>(proxy sidecar)"]:::proxy
    end

    subgraph CSQL["Cloud SQL  ·  pgsql-fin-sandbox-dev  ·  PostgreSQL 18"]
        direction TB
        DB["📀 finance-dev<br/>(base única)"]:::db

        subgraph SCHEMAS["Schemas (1 por servicio)"]
            direction LR
            S_AM["access_manager<br/>owner: accmgr"]:::schema
            S_SEG["segment<br/>owner: segments"]:::schema
            S_BC["base_config<br/>owner: base_config"]:::schema
            S_TP["tprt<br/>owner: third_party"]:::schema
            S_ACC["acct<br/>owner: accounting"]:::schema
            S_LT["liquid_tax<br/>owner: liquid_tax"]:::schema
        end

        DB --> S_AM & S_SEG & S_BC & S_TP & S_ACC & S_LT
    end

    AM_SVC & SEG_SVC & BC_SVC & TP_SVC & ACC_SVC & LT_SVC -->|"TCP 127.0.0.1:5432"| P1
    P1 -->|"IAM · Workload Identity · Cloud SQL Auth"| CSQL

    CONFIG["⚙️ Pool config<br/>Maximum Pool Size=3<br/>(db-g1-small)"]
    P1 --- CONFIG
```

**Convenciones de migrations:**
- `auto-migrate` en startup (`db.Database.MigrateAsync()`)
- `IEntityTypeConfiguration` siempre declara `builder.ToTable(tabla, "base_config")` con el schema correcto (sin guiones)
- `outbox_messages` en cada schema — parte del Transactional Outbox Pattern

---

## 9. Pipeline CI/CD

### Servicios (Backend + MFE)

```mermaid
sequenceDiagram
    actor DEV as Developer
    participant GH as "GitHub — repo servicio"
    participant GHA as GitHub Actions
    participant AR as "Artifact Registry us-east1"
    participant CB as "Cloud Build Worker Pool"
    participant GKE as "GKE Autopilot kubectl"

    DEV->>GH: git push → PR
    GH->>GHA: Quality Gate (tests, lint, build)
    DEV->>GH: Merge a main (develop)
    GH->>GHA: Trigger workflow on push
    GHA->>GHA: docker build API image (tag: SHA)
    GHA->>GHA: docker build MFE image (tag: SHA)
    GHA->>AR: docker push api:SHA
    GHA->>AR: docker push mfe:SHA
    GHA->>CB: Trigger Cloud Build
    CB->>GKE: Agregar IP Worker Pool a MAN
    CB->>GKE: kustomize build | kubectl apply
    Note over CB,GKE: kustomize regenera kustomization.yaml con tags SHA
    GKE-->>CB: rollout status --timeout=300s
    CB->>GKE: Restaurar MAN original
    GKE-->>GHA: Deploy OK
```

### Infraestructura (este repo)

```mermaid
sequenceDiagram
    actor DEV as Developer
    participant GH as "GitHub — deploy repo"
    participant GHA as GitHub Actions
    participant TF as "Terraform infra-pipeline"
    participant CB as Cloud Build
    participant K8S as kubectl apply

    DEV->>GH: PR con cambios IaC / K8s
    GH->>TF: terraform plan (comentario en PR)
    DEV->>GH: Merge a main
    GH->>GHA: Trigger infra-pipeline-dev.yml
    GHA->>TF: Job 1: terraform apply
    Note over TF: Aplica GKE, SQL, Pub/Sub, IAM, DNS, Certificates
    TF-->>GHA: Job 1 OK
    GHA->>CB: Job 2 (depende J1): Cloud Build
    CB->>K8S: kubectl apply redis/
    CB->>K8S: kubectl apply dapr/
    CB->>K8S: kubectl apply routes/dev/
    CB->>K8S: kubectl apply healthcheck/
    CB->>K8S: kubectl apply observability/
    CB-->>GHA: Deploy OK
```

> **⚠️ Race condition MAN:** Dos pipelines concurrentes causan `CLUSTER_ALREADY_HAS_OPERATION`. No hay retry automático — re-run manual.

---

## 10. Observabilidad

Distributed tracing al 100% en desarrollo. Dapr envía trazas via Zipkin al OTel Collector, que filtra ruido de Pub/Sub y reenvía a Jaeger.

```mermaid
flowchart LR
    classDef app   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef dapr  fill:#7b1fa2,stroke:#4a148c,color:#fff
    classDef otel  fill:#e65100,stroke:#bf360c,color:#fff
    classDef jaeg  fill:#2e7d32,stroke:#1b5e20,color:#fff
    classDef user  fill:#37474f,stroke:#263238,color:#fff

    subgraph SERVICES["Servicios  (cada namespace)"]
        SVC1["access-manager-api"]:::app
        SVC2["segments-api"]:::app
        SVC3["base-config-api"]:::app
        SVC4["...otros servicios"]:::app
    end

    subgraph DAPR_SIDE["Dapr Sidecars"]
        D1["⬡ daprd<br/>sampling: 1 (100%)<br/>Zipkin exporter"]:::dapr
        D2["⬡ daprd"]:::dapr
        D3["⬡ daprd"]:::dapr
    end

    subgraph OBSERVABILITY["namespace: observability"]
        OTEL["📡 OTel Collector 0.149.0<br/>port 9411 (Zipkin)<br/>Filtro: drop Pub/Sub StreamingPull noise<br/>(gRPC code 14/1 errors)"]:::otel
        JAEGER["🔍 Jaeger all-in-one 1.57<br/>UI: port 16686<br/>Zipkin ingest: port 9411<br/>Storage: in-memory (5000 trazas)<br/>UI path: /observability/jaeger"]:::jaeg
    end

    GW_ROUTE["🌐 Gateway<br/>/observability/jaeger"]:::user
    BROWSER["👤 Developer<br/>finance.siesacloud.dev/observability/jaeger"]:::user

    SVC1 --> D1
    SVC2 --> D2
    SVC3 --> D3
    D1 & D2 & D3 -->|"Zipkin HTTP · port 9411"| OTEL
    OTEL -->|"forward filtered spans"| JAEGER
    BROWSER --> GW_ROUTE --> JAEGER

    NOTE["⚠️ In-Memory: trazas se pierden<br/>al reiniciar el pod.<br/>Producción: migrar a Cloud Trace<br/>o Jaeger con backend persistente."]
```

---

## 11. Seguridad en Capas

La seguridad es **defense-in-depth**: cada capa añade una barrera adicional.

```mermaid
flowchart TB
    classDef layer fill:#37474f,stroke:#263238,color:#fff
    classDef threat fill:#b71c1c,stroke:#7f0000,color:#fff
    classDef ok    fill:#1b5e20,stroke:#003300,color:#fff

    INTERNET["🌐 Internet<br/>Requests HTTP/HTTPS"]

    subgraph L1["Capa 1 — Red (Cloud Armor WAF)"]
        CA["🛡️ Cloud Armor<br/>OWASP SQLi rules<br/>OWASP XSS rules<br/>Rate limiting<br/>IP reputation"]:::layer
    end

    subgraph L2["Capa 2 — TLS (Certificate Manager)"]
        TLS["🔒 TLS 1.3<br/>Certificate Manager<br/>finance.siesacloud.dev<br/>HTTP → HTTPS redirect"]:::layer
    end

    subgraph L3["Capa 3 — Autenticación (Access Manager)"]
        JWT["🎫 JWT Validation<br/>Access Manager middleware<br/>Bearer token requerido<br/>en todos los endpoints"]:::layer
        PERM["🔐 Autorización por permiso<br/>RequirePermission(\"prefix.entity.action\")<br/>Redis cache · invalidación por eventos"]:::layer
    end

    subgraph L4["Capa 4 — Service-to-Service (Dapr mTLS)"]
        MTLS["🔑 mTLS automático<br/>Dapr Sentry CA<br/>Rotación de certificados<br/>identidades SPIFFE"]:::layer
        GUARD["🚪 dapr-caller-app-id guard<br/>Endpoints /snapshot/*<br/>rechazan 403 si falta header"]:::layer
    end

    subgraph L5["Capa 5 — Identidad Cloud (Workload Identity)"]
        WIF["🪪 Workload Identity Federation<br/>GitHub Actions sin JSON keys<br/>assert.repository_owner == SiesaTeams<br/>K8s SA → GCP SA binding"]:::layer
        SA["🔑 Service Accounts dedicados<br/>por servicio<br/>principle of least privilege"]:::layer
    end

    subgraph L6["Capa 6 — Secretos (Secret Manager)"]
        SM["🗝️ GCP Secret Manager<br/>DB connection strings<br/>Rotación en Secret Manager<br/>Nunca en variables de entorno<br/>ni en código fuente"]:::layer
    end

    INTERNET --> L1 --> L2 --> L3 --> L4
    L4 --> L5 --> L6
```

### Matriz de Acceso por Servicio

| Servicio | GCP SA | Roles Pub/Sub | Cloud SQL | Secret Manager |
|---|---|---|---|---|
| Access Manager | `sa-sie-fin-accmgr-sql-dev` | publisher + subscriber | ✅ | ✅ |
| Segments | `sa-sie-fin-segments-sql-dev` | publisher + subscriber | ✅ | ✅ |
| Base Config | `sa-sie-fin-baseconfig-sql-dev` | publisher + subscriber | ✅ | ✅ |
| Third Party | `sa-sie-fin-tprt-sql-dev` | publisher + subscriber | ✅ | ✅ |
| Accounting | `sa-sie-fin-acct-sql-dev` | subscriber | ✅ | ✅ |
| Liquid Tax | `sa-sie-fin-liquid-tax-sql-dev` | publisher | ✅ | ✅ |

---

## 12. Reconciliación de Proyecciones

Dos capas de sincronización garantizan consistencia eventual entre servicios:

```mermaid
flowchart TB
    classDef layer  fill:#0d47a1,stroke:#01579b,color:#fff
    classDef cron   fill:#e65100,stroke:#bf360c,color:#fff
    classDef event  fill:#2e7d32,stroke:#1b5e20,color:#fff
    classDef store  fill:#4a148c,stroke:#311b92,color:#fff

    subgraph L1["Capa 1 — Tiempo Real (Eventos Dapr Pub/Sub)"]
        direction LR
        EV1["access-manager-events<br/>→ base-config actualiza UserPrj<br/>→ segments actualiza UserPrj<br/>→ third-party actualiza acceso"]:::event
        EV2["segments-events<br/>→ base-config actualiza proyecciones<br/>→ third-party actualiza segmentos"]:::event
        EV3["base-config-events<br/>→ third-party actualiza config"]:::event
    end

    subgraph L2["Capa 2 — Snapshot Completo (Cron Binding @every 1h)"]
        direction TB
        C_BC["⏰ base-config<br/>reconcile-companies (Dapr service invoke → segments.segments)<br/>reconcile-operation-centers<br/>reconcile-user-company-assignments<br/>reconcile-users (invoke → accessmanager.access-manager)"]:::cron
        C_SEG["⏰ segments<br/>reconcile-cities / states / countries / neighborhoods<br/>(invoke → base-config.base-config)<br/>reconcile-users (invoke → accessmanager.access-manager)"]:::cron
        C_TP["⏰ third-party<br/>reconcile-companies (invoke → base-config.base-config)<br/>reconcile-users (invoke → accessmanager.access-manager)"]:::cron
    end

    subgraph PROJ["Proyecciones locales (Cloud SQL por servicio)"]
        P_BC["CompanyPrj<br/>OperationCenterPrj<br/>UserCompanyAssignmentPrj<br/>UserPrj"]:::store
        P_SEG["UserPrj<br/>CountryPrj · StatePrj<br/>CityPrj · NeighborhoodPrj"]:::store
        P_TP["12 proyecciones<br/>(users, companies, segments,<br/>base-config entities…)"]:::store
    end

    L1 -->|"actualización incremental"| PROJ
    L2 -->|"snapshot completo · cada hora"| PROJ

    NOTE["⚠️ Cross-namespace: usar {app-id}.{namespace}<br/>Ej: segments.segments  /  accessmanager.access-manager<br/>NO usar solo el app-id sin namespace"]
```

---

## 13. Patrones Implementados

Catálogo de los patrones de diseño e integración aplicados en la plataforma, agrupados por capa.

### Mapa de Patrones por Capa

```mermaid
flowchart TB
    classDef frontend  fill:#0288d1,stroke:#01579b,color:#fff
    classDef backend   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef messaging fill:#e65100,stroke:#bf360c,color:#fff
    classDef infra     fill:#37474f,stroke:#263238,color:#fff
    classDef security  fill:#6a1b9a,stroke:#4a148c,color:#fff
    classDef data      fill:#2e7d32,stroke:#1b5e20,color:#fff

    subgraph L_FE["Frontend"]
        direction LR
        P_MFE["Micro-Frontend<br/>(Import Map + single-spa)"]:::frontend
        P_ESM["ESM Module Federation<br/>(browser-native, sin SystemJS)"]:::frontend
        P_I18N["i18n Reactivo<br/>(siesa:language-changed event)"]:::frontend
    end

    subgraph L_BE["Backend — por servicio"]
        direction LR
        P_CA["Clean Architecture<br/>(Domain · Application · Infrastructure)"]:::backend
        P_CQRS["CQRS<br/>(Commands / Queries separados)"]:::backend
        P_MIGRATE["Auto-Migrate on Startup<br/>(MigrateAsync en Program.cs)"]:::backend
    end

    subgraph L_MSG["Mensajería e Integración"]
        direction LR
        P_OUTBOX["Transactional Outbox<br/>(OutboxProcessor · batch 20 · retry 5)"]:::messaging
        P_IDEMPOTENT["Idempotent Consumer<br/>(eventStore · IsDuplicateAsync)"]:::messaging
        P_EDA["Event-Driven Architecture<br/>(Cloud Pub/Sub · Dapr pub/sub)"]:::messaging
        P_RECONCILE["Two-Layer Reconciliation<br/>(eventos tiempo real + cron snapshot)"]:::messaging
    end

    subgraph L_INFRA["Infraestructura"]
        direction LR
        P_SIDECAR["Sidecar Pattern<br/>(Dapr daprd + Cloud SQL Auth Proxy)"]:::infra
        P_GW["API Gateway + URL Rewriting<br/>(/api/{prefix} → /api/v1/{prefix})"]:::infra
        P_HC["Health Check Policy<br/>(TCP por servicio · GKE Gateway)"]:::infra
        P_IAC["Infrastructure as Code<br/>(Terraform · fuente única de verdad)"]:::infra
    end

    subgraph L_SEC["Seguridad"]
        direction LR
        P_WIF["Workload Identity Federation<br/>(GitHub Actions sin JSON keys)"]:::security
        P_MTLS["mTLS automático<br/>(Dapr Sentry CA · SPIFFE)"]:::security
        P_DID["Defense in Depth<br/>(Cloud Armor → TLS → JWT → mTLS → WIF → Secrets)"]:::security
        P_GUARD["Snapshot Guard<br/>(dapr-caller-app-id · 403 sin header)"]:::security
    end

    subgraph L_DATA["Datos"]
        direction LR
        P_SCHEMA["Schema per Service<br/>(DB única · schema aislado por servicio)"]:::data
        P_POOL["Connection Pool limitado<br/>(MaxPoolSize=3 · db-g1-small)"]:::data
        P_PITR["PITR + Backup diario<br/>(7 días WAL · 7 copias)"]:::data
    end

    L_FE --> L_BE --> L_MSG
    L_MSG --> L_INFRA
    L_INFRA --> L_SEC
    L_INFRA --> L_DATA
```

---

### Patrones de Mensajería

#### Transactional Outbox

| | |
|---|---|
| **Problema** | Publicar un evento y persistir la entidad son dos operaciones distintas — si una falla, el sistema queda inconsistente. |
| **Solución** | Ambas operaciones ocurren en la **misma transacción EF Core**. Un `BackgroundService` (`OutboxProcessor`) publica los mensajes pendientes a Dapr en segundo plano. |
| **Servicios** | `segments` · `base-config` · `third-party` · `accounting` |
| **Config** | Batch de 20 · cada 5 s · máx 5 reintentos · `status=failed` al agotar |
| **Tabla** | `{schema}.outbox_messages` |

```mermaid
flowchart LR
    classDef tx   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef bg   fill:#e65100,stroke:#bf360c,color:#fff
    classDef ext  fill:#2e7d32,stroke:#1b5e20,color:#fff

    T["BEGIN TRANSACTION"]:::tx
    E["INSERT entidad"]:::tx
    O["INSERT outbox_message<br/>status = pending"]:::tx
    C["COMMIT"]:::tx
    OP["OutboxProcessor<br/>BackgroundService<br/>cada 5 s · batch 20"]:::bg
    D["Dapr pub/sub"]:::ext
    PS["Cloud Pub/Sub"]:::ext

    T --> E --> O --> C
    C -->|"atómico"| OP
    OP -->|"publica · max 5 retries"| D --> PS
    OP -->|"UPDATE status=processed"| O
```

---

#### Idempotent Consumer

| | |
|---|---|
| **Problema** | Cloud Pub/Sub puede re-entregar el mismo mensaje. Procesar dos veces un evento puede corromper proyecciones. |
| **Solución** | Cada consumer verifica `eventStore` (Redis) antes de procesar. Si ya fue procesado, retorna `200 OK` inmediatamente. |
| **Obligatorio en** | Todos los consumers Dapr Pub/Sub de la plataforma |

```mermaid
flowchart TD
    classDef check fill:#f57f17,stroke:#e65100,color:#fff
    classDef ok    fill:#2e7d32,stroke:#1b5e20,color:#fff
    classDef proc  fill:#1565c0,stroke:#0d47a1,color:#fff

    MSG["Mensaje recibido<br/>del topic"]
    CHECK["EventHandlerGuard<br/>IsDuplicateAsync(eventId)"]:::check
    DUP{"¿Duplicado?"}
    SKIP["return Results.Ok()<br/>(descarta silenciosamente)"]:::ok
    PROC["Lógica de negocio<br/>(actualizar proyección)"]:::proc
    MARK["eventStore.MarkProcessedAsync(eventId)"]:::ok
    ACK["ACK a Pub/Sub"]:::ok

    MSG --> CHECK --> DUP
    DUP -->|"sí"| SKIP
    DUP -->|"no"| PROC --> MARK --> ACK
```

---

#### Two-Layer Reconciliation

| Capa | Mecanismo | Frecuencia | Propósito |
|---|---|---|---|
| **Capa 1 — Incremental** | Dapr Pub/Sub eventos | Tiempo real | Actualización delta por cada cambio |
| **Capa 2 — Snapshot** | Dapr cron binding → service invocation | Cada 1 hora | Re-sincronización completa como red de seguridad |

```mermaid
flowchart LR
    classDef src   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef event fill:#e65100,stroke:#bf360c,color:#fff
    classDef cron  fill:#6a1b9a,stroke:#4a148c,color:#fff
    classDef proj  fill:#2e7d32,stroke:#1b5e20,color:#fff

    SRC["Servicio fuente<br/>(Access Manager · Segments<br/>Base Config)"]:::src

    EV["Evento Pub/Sub<br/>(tiempo real)"]:::event
    CRON["Cron Binding<br/>@every 1h<br/>Dapr service invocation"]:::cron

    PROJ["Proyección local<br/>(Cloud SQL · schema propio)"]:::proj

    SRC -->|"produce evento"| EV -->|"actualización delta"| PROJ
    CRON -->|"snapshot completo · {app-id}.{namespace}"| PROJ
```

---

### Patrones de Infraestructura

#### Sidecar Pattern

Dos sidecars por pod, cada uno con una responsabilidad única:

| Sidecar | Imagen | Puerto | Responsabilidad |
|---|---|---|---|
| **Dapr daprd** | `daprd:1.17.3` | 3500 HTTP · 50001 gRPC | pub/sub · state · secrets · mTLS · cron |
| **Cloud SQL Auth Proxy** | `cloud-sql-proxy` | 127.0.0.1:5432 | Autenticación IAM con Cloud SQL sin IP privada |

```mermaid
flowchart LR
    classDef app   fill:#1565c0,stroke:#0d47a1,color:#fff
    classDef side  fill:#7b1fa2,stroke:#4a148c,color:#fff
    classDef ext   fill:#2e7d32,stroke:#1b5e20,color:#fff

    subgraph POD["Pod Kubernetes"]
        direction TB
        APP["🔷 App Container<br/>.NET 10 · :8080"]:::app
        DAPR["⬡ daprd sidecar<br/>:3500 / :50001"]:::side
        PROXY["🔌 Cloud SQL Auth Proxy<br/>127.0.0.1:5432"]:::side
    end

    GCP_DAPR["Cloud Pub/Sub<br/>Secret Manager<br/>Redis state"]:::ext
    GCP_SQL["Cloud SQL<br/>PostgreSQL 18"]:::ext

    APP <-->|"localhost:3500"| DAPR
    APP <-->|"localhost:5432"| PROXY
    DAPR <-->|"IAM · mTLS"| GCP_DAPR
    PROXY <-->|"IAM · Cloud SQL Auth"| GCP_SQL
```

---

#### API Gateway con URL Rewriting

El Gateway actúa como capa de versionado: los MFEs nunca incluyen `/v1` en sus URLs. Esto permite cambiar la versión del API sin tocar el frontend.

```mermaid
flowchart LR
    classDef fe  fill:#0288d1,stroke:#01579b,color:#fff
    classDef gw  fill:#37474f,stroke:#263238,color:#fff
    classDef be  fill:#1565c0,stroke:#0d47a1,color:#fff

    MFE["MFE / Browser<br/>GET /api/base-config/companies"]:::fe
    GW["GKE Gateway<br/>HTTPRoute URLRewrite"]:::gw
    BE["base-config-api<br/>GET /api/v1/companies"]:::be

    MFE -->|"/api/{prefix}/*"| GW
    GW -->|"reescribe → /api/v1/*"| BE
```

---

### Patrones de Seguridad

#### Defense in Depth — 6 Capas

```mermaid
flowchart LR
    classDef l fill:#6a1b9a,stroke:#4a148c,color:#fff

    L1["☁️ L1 · Cloud Armor<br/>WAF · SQLi · XSS<br/>Rate limiting"]:::l
    L2["🔒 L2 · TLS 1.3<br/>Certificate Manager<br/>HTTP → HTTPS"]:::l
    L3["🎫 L3 · JWT Bearer<br/>Access Manager middleware<br/>token requerido"]:::l
    L4["🔐 L4 · Autorización<br/>RequirePermission<br/>Redis cache"]:::l
    L5["🔑 L5 · mTLS Dapr<br/>Sentry CA · SPIFFE<br/>inter-service"]:::l
    L6["🪪 L6 · WIF + Secrets<br/>sin JSON keys<br/>Secret Manager"]:::l

    L1 --> L2 --> L3 --> L4 --> L5 --> L6
```

---

### Resumen — Catálogo Completo

| Patrón | Categoría | Dónde aplica | Beneficio clave |
|---|---|---|---|
| **Micro-Frontend + Import Map** | Frontend | App Shell + 6 MFEs | Deploy independiente por MFE sin recompilar el shell |
| **ESM Module Federation** | Frontend | Browser nativo | Sin SystemJS; import maps estándar W3C |
| **i18n Reactivo** | Frontend | Todos los MFEs | Cambio de idioma sin recargar la página |
| **Clean Architecture** | Backend | Todos los servicios | Separación Domain / Application / Infrastructure |
| **CQRS** | Backend | Todos los servicios | Queries y Commands con modelos optimizados |
| **Auto-Migrate on Startup** | Backend | Todos los servicios | Zero-downtime migration; OutboxProcessor no crashea |
| **Transactional Outbox** | Mensajería | segments · base-config · third-party · accounting | Publicación de eventos atómica con la persistencia |
| **Idempotent Consumer** | Mensajería | Todos los consumers | Re-entrega de Pub/Sub sin corrupción de datos |
| **Event-Driven Architecture** | Integración | Pub/Sub entre servicios | Desacoplamiento temporal entre productores y consumidores |
| **Two-Layer Reconciliation** | Integración | base-config · segments · third-party | Consistencia eventual garantizada: eventos + snapshot |
| **Sidecar** | Infraestructura | Todos los pods | Dapr y Auth Proxy sin modificar el código de la app |
| **API Gateway + URL Rewriting** | Infraestructura | GKE Gateway → todos los servicios | Versionado de API transparente al frontend |
| **Health Check Policy** | Infraestructura | Todos los servicios (TCP :8080) | GKE Gateway no enruta tráfico a pods no listos |
| **Infrastructure as Code** | Infraestructura | Terraform → todo GCP | Reproducibilidad; sin recursos manuales sin importar |
| **Workload Identity Federation** | Seguridad | GitHub Actions → GCP | Sin secretos de larga vida en repositorios |
| **mTLS automático** | Seguridad | Dapr Sentry CA | Cifrado y autenticación inter-servicio sin configuración manual |
| **Defense in Depth** | Seguridad | Cloud Armor → WIF | 6 capas independientes; fallo de una no compromete el sistema |
| **Snapshot Guard** | Seguridad | Endpoints `/snapshot/*` | Solo Dapr puede invocar snapshots; 403 a llamadas directas |
| **Schema per Service** | Datos | Cloud SQL finance-dev | Aislamiento lógico sin el costo de múltiples instancias |
| **Connection Pool limitado** | Datos | Todos los servicios | `MaxPoolSize=3` evita saturar `db-g1-small` |
| **PITR + Backup diario** | Datos | Cloud SQL | Recuperación a cualquier punto en 7 días |

---

## Resumen Ejecutivo

| Decisión Arquitectónica | Alternativa descartada | Razón |
|---|---|---|
| **Dapr** sobre Istio | Istio service mesh | Menor complejidad ops; mTLS, pub/sub y secrets en un solo plano |
| **GKE Gateway API** sobre Ingress | nginx Ingress Controller | Estándar nativo K8s; integración directa Cloud Armor + Certificate Manager |
| **single-spa + ESM nativo** sobre Nx Module Federation | Module Federation (Webpack) | Sin SystemJS; native browser imports; build independiente por MFE |
| **Cloud SQL Auth Proxy sidecar** sobre PSC | Private Service Connect | GKE ip-masq-agent bloquea PSA; sidecar más predecible |
| **WIF** sobre Service Account JSON keys | JSON key files | Seguridad: sin secretos de larga vida en repositorios |
| **Redis compartido** sobre Memorystore | Cloud Memorystore Redis | Dev: costo; PROD: migrar a Memorystore para HA |
| **Transactional Outbox** sobre dual writes | Publicar a Dapr dentro de la transacción | Atomicidad: si el evento falla, la entidad tampoco se guarda |
| **Un schema por servicio** sobre un DB por servicio | PostgreSQL separado por servicio | Dev: costo; aislamiento lógico suficiente; `db-g1-small` |

---

*Generado a partir del repositorio `business-financiero-deploy` · `finance.siesacloud.dev` · 2026-05-05*
