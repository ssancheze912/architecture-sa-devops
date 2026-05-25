# Guía de Desarrollo Local

## Estructura de directorios local

Todos los repos deben clonarse en el **mismo directorio padre**. Los flows de Claude Code (`/flow-nuevo-servicio`, etc.) asumen esta convención para copiar artefactos entre repos sin rutas absolutas.

```
~/SiesaTeams/                                  ← directorio padre compartido
├── business-financiero-deploy/                ← este repo (IaC)
├── business-access-manager/
├── business-financiero-app-shell/
├── business-financiero-segments-service/
├── business-financiero-base-config/
├── business-financiero-third-party-service/
├── business-financiero-accounting-service/
└── business-financiero-liquid-tax-service/
```

Para clonar un servicio que no tengas aún:
```bash
cd ~/SiesaTeams
gh repo clone SiesaTeams/{repo-name}
```

## Setup único por desarrollador (primera vez)

### 1. Herramientas requeridas

```bash
gcloud --version
cloud-sql-proxy --version
dapr --version        # >= 1.14
kubectl version --client
```

### 2. Inicializar Dapr local

```bash
dapr init   # instala daprd, placement y zipkin localmente (~/.dapr/)
```

> `dapr init` solo es necesario una vez por máquina. Instala el binario `daprd`,
> el servicio de placement (actores) y Zipkin. No toca los componentes de los repos.

---

## Dapr — Modos de desarrollo local

Cada repo de servicio tiene `dapr/components/` con los componentes usados cuando se
lanza `Backend: .NET + Dapr` desde VS Code (tarea `daprd-start` en `tasks.json`).

### Modo A — Standalone in-memory (defecto, sin dependencias)

Los componentes en `dapr/components/` de cada repo usan `pubsub.in-memory` y
`state.in-memory`. Dapr arranca sin errores, sin Redis ni credenciales GCP.

> **Nota sobre placement y Zipkin:** En desarrollo local, los servicios del cluster de `dapr init`
> (placement en `localhost:50005` y Zipkin en `localhost:9411`) no están disponibles a menos
> que Docker esté corriendo con los contenedores `dapr_placement` y `dapr_zipkin` activos.
> Los tasks.json de cada repo tienen `--placement-host-address ""` para deshabilitar la conexión
> a placement (ningún servicio usa actores Dapr). Los warnings de Zipkin son inofensivos.

```
dapr/components/
  pubsub.yaml      → pubsub.in-memory
  statestore.yaml  → state.in-memory
  secretstore.yaml → secretstores.local.file (./dapr/secrets/secrets.json)
```

**Qué funciona en Modo A:**
| Capacidad | Disponible |
|---|---|
| Service invocation entre procesos locales | ✅ vía mDNS |
| Pub/Sub dentro del mismo proceso | ✅ in-memory |
| Pub/Sub entre servicios locales distintos | ❌ cada proceso tiene su bus propio |
| Pub/Sub hacia/desde GKE | ❌ no hay conectividad |
| Secrets desde archivo local | ✅ `dapr/secrets/secrets.json` |
| State store local | ✅ in-memory |

**Cuándo usarlo:** desarrollo CRUD del día a día, debug de endpoints, pruebas unitarias
de lógica de negocio sin necesitar eventos reales.

---

### Modo B — GCP Pub/Sub real (eventos compartidos con el cluster GKE)

Permite que el servicio local publique y reciba eventos del mismo Pub/Sub que usan los
pods en GKE. Requiere autenticación GCP.

**Pre-requisitos:**
```bash
# 1. Autenticar con Application Default Credentials
gcloud auth application-default login

# 2. Verificar roles necesarios en prj-sie-fin-financiero-dev:
#    roles/pubsub.publisher  — publicar eventos
#    roles/pubsub.subscriber — recibir eventos
gcloud projects get-iam-policy prj-sie-fin-financiero-dev \
  --flatten="bindings[].members" \
  --filter="bindings.members:$(gcloud config get-value account)"
```

**Activar Modo B en un servicio:**
```bash
# Reemplazar temporalmente los componentes en dapr/components/
cp /path/to/business-financiero-deploy/scripts/dapr-local/pubsub.yaml \
   dapr/components/pubsub.yaml
```

O apuntar `--resources-path` directamente al repo de deploy en el `tasks.json`:
```json
"--resources-path", "/path/to/business-financiero-deploy/scripts/dapr-local"
```

**⚠️ Conflicto de suscripciones — LEER ANTES DE USAR:**

GCP Pub/Sub distribuye mensajes entre todos los consumidores de una suscripción.
Si el pod de GKE y el proceso local tienen el mismo `app-id`, **compiten por los
mismos mensajes** — cada evento llega a uno solo (GKE o local), nunca a ambos.

```
Ejemplo para base-config suscrita a segments-events:
  Suscripción: base-config-segments-events
  Si GKE pod + local compiten:
    Evento 1 → GKE pod     ✅
    Evento 2 → local        ✅
    Evento 3 → GKE pod     ✅ (pero local esperaba recibirlo)
```

**Para evitar conflictos:** escalar a cero el deployment en GKE mientras se desarrolla
localmente, o crear suscripciones dedicadas para dev local (requiere Terraform).

```bash
# Escalar a cero el pod del servicio en GKE antes de levantar localmente:
kubectl scale deployment base-config-api -n base-config --replicas=0

# Al terminar, restaurar:
kubectl scale deployment base-config-api -n base-config --replicas=1
```

**Cuándo usarlo:** testing de flujos pub/sub completos end-to-end (publicar → consumir
entre servicios). No usar para desarrollo rutinario.

---

### Modo C — Port-forward Redis del cluster (state store compartido)

Si se necesita acceder al state store Redis del cluster (actores, estado compartido):

```bash
kubectl port-forward -n dapr-system svc/redis 6379:6379
```

Luego restaurar `dapr/components/statestore.yaml` a `state.redis` apuntando a
`localhost:6379`. El Redis del cluster y el proceso local comparten el state.

**Cuándo usarlo:** solo si el servicio usa actores Dapr o state store compartido.
Actualmente ningún servicio de la plataforma usa actores.

### 3. Carga automática de credenciales (se hace sola al correr dev-connect.sh)

`dev-connect.sh` configura los perfiles de shell automáticamente. No es necesario editar
`~/.zshrc` manualmente — el script lo hace la primera vez que se ejecuta.

> Si preferís hacerlo manualmente, agrega una sola vez a `~/.zshrc` / `~/.bashrc`:
> `[ -f ~/.financiero-dev.env ] && { set -a; source ~/.financiero-dev.env; set +a; }`

---

## Flujo de arranque por sesión de desarrollo

### Paso 1 — Iniciar la sesión de desarrollo

```bash
source ./scripts/dev-connect.sh
```

El script:
- Abre `localhost:5432` vía Cloud SQL Auth Proxy (túnel en background)
- Agrega la IP local a Master Authorized Networks
- Lee la contraseña de Secret Manager y genera los archivos de entorno:
  - `~/.financiero-dev.env` — variable compartida `DB_FINANCE_DEV_PASSWORD`
  - `~/.financiero-<servicio>.env` — uno por servicio con `ConnectionStrings__DefaultConnection` completa
- Muestra las credenciales en un cuadro amarillo

Para cerrar el túnel y limpiar MAN al terminar:

```bash
dev-disconnect
```

---

### Paso 2 — Levantar un servicio

#### Opción A — VS Code (recomendado para debug)

Abrir el repo del servicio en VS Code y usar **Run & Debug** (`⇧F5` / `Ctrl+Shift+D`):

| Configuración | Cuándo usarla |
|---|---|
| `Backend: .NET` | Solo API, sin Dapr (debug rápido) |
| `Backend: .NET + Dapr` | API + sidecar Dapr (pub/sub, state, secrets) |
| `Frontend: Vite Dev` | Solo MFE |
| `Full Stack` | API + MFE simultáneo |
| `Full Stack + Dapr` | API + Dapr + MFE (sesión completa) |

> `envFile` en `launch.json` apunta a `~/.financiero-<servicio>.env` — las credenciales
> se inyectan directamente al proceso sin necesidad de variables adicionales.

#### Opción B — `dotnet run` desde terminal

```bash
# Después de source ./scripts/dev-connect.sh:
dev-use base-config      # carga ConnectionStrings__DefaultConnection en la sesión
dotnet run               # el proceso hereda la variable del entorno
```

`dev-use` está disponible en cualquier terminal nueva gracias al perfil de shell
configurado por `dev-connect.sh`. También se puede usar con Docker:

```bash
dev-use base-config
docker run --env ConnectionStrings__DefaultConnection="$ConnectionStrings__DefaultConnection" ...
```

Servicios disponibles para `dev-use`:

```
dev-use access-manager
dev-use segments
dev-use base-config
dev-use third-party
dev-use accounting
dev-use liquid-tax
```

---

## Base de datos — Cloud SQL

Todos los servicios comparten la instancia `pgsql-fin-sandbox-dev`, base de datos
`finance-dev`. Cada servicio tiene su propio schema y usuario de runtime en producción,
pero en desarrollo **todos usan el usuario `dev`** con acceso a todos los schemas.

| Servicio | Schema | Puerto API | Puerto MFE |
|---|---|---|---|
| `access-manager` | `access_manager` | 7010 | 8010 |
| `segments` | `segment` | 7012 | 8012 |
| `base-config` | `base_config` | 7014 | 8014 |
| `third-party` | `tprt` | 7016 | 8016 |
| `accounting` | `acct` | 7018 | 8018 |
| `liquid-tax` | `liquid_tax` | 7020 | 8020 |

**Connection string local** (generada en `~/.financiero-<servicio>.env`):

```
Host=127.0.0.1;Port=5432;Database=finance-dev;Username=dev;Password=<secret>;
Search Path=<schema>;SSL Mode=Disable;GssEncryptionMode=Disable
```

> `appsettings.Development.json` de cada servicio tiene `PLACEHOLDER_USE_DB_FINANCE_DEV_PASSWORD`
> como contraseña — el valor real viene siempre del entorno (`ConnectionStrings__DefaultConnection`
> o `dev-use`). Nunca hardcodear la contraseña en archivos versionados.

## Puertos locales por servicio

| Servicio | Backend (API) | Frontend (MFE) | Dapr HTTP | Dapr gRPC |
|---|---|---|---|---|
| `app-shell` | — | 8011 | — | — |
| `access-manager` | 7010 | 8010 | 3510 | 50010 |
| `segments` | 7012 | 8012 | 3512 | 50012 |
| `base-config` | 7014 | 8014 | 3514 | 50014 |
| `third-party` | 7016 | 8016 | 3516 | 50016 |
| `accounting` | 7018 | 8018 | 3518 | 50018 |
| `liquid-tax` | 7020 | 8020 | 3520 | 50020 |

> Convención: backends en **70xx** (incrementos de 2), MFEs en **80xx**, Dapr HTTP en **35xx**, Dapr gRPC en **500xx**.

## Servicios del cluster

| Servicio | URL / Host |
|---|---|
| PostgreSQL | `localhost:5432` (via `dev-connect.sh`) |
| Access Manager API | `https://finance.siesacloud.dev/api/access-manager/` |
| Segments API | `https://finance.siesacloud.dev/api/segments/` |
| Base Config API | `https://finance.siesacloud.dev/api/base-config/` |
| Third Party API | `https://finance.siesacloud.dev/api/third-party/` |
| Accounting API | `https://finance.siesacloud.dev/api/accounting/` |
| Liquid Tax API | `https://finance.siesacloud.dev/api/liquid-tax/` |
| Jaeger UI | `https://finance.siesacloud.dev/observability/jaeger` |

## Roles GCP requeridos

| Rol | Para qué |
|---|---|
| `roles/cloudsql.client` | Cloud SQL Auth Proxy |
| `roles/secretmanager.secretAccessor` | Leer credenciales de DB (`dev-sandbox-db-connection`) |
| `roles/container.admin` | Actualizar Master Authorized Networks (kubectl) |

> `container.admin` solo es necesario si usás `kubectl`. Para solo correr servicios
> localmente, `cloudsql.client` + `secretmanager.secretAccessor` son suficientes.
