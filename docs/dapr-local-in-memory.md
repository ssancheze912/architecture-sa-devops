# Dapr en Desarrollo Local — Modo In-Memory

> **TL;DR:** En Modo A (in-memory), Dapr corre completamente offline. Pub/Sub y state store
> son simulados en RAM dentro de cada proceso. La única conexión real a GCP es Cloud SQL
> (vía Auth Proxy). Nada de lo que hagas en local con eventos afecta a GKE ni viceversa.

---

## Arquitectura local vs. GKE

```
╔══════════════════════════════════════════════════════════════════════╗
║  Tu laptop (Modo A — in-memory)                                      ║
║                                                                      ║
║  ┌───────────────────────────────────┐                               ║
║  │  proceso: base-config-api         │                               ║
║  │  puerto: 7014                     │                               ║
║  │                                   │                               ║
║  │  ┌───────────────────────────┐    │                               ║
║  │  │  daprd sidecar            │    │                               ║
║  │  │  (proceso hijo, 3514)     │    │                               ║
║  │  │                           │    │                               ║
║  │  │  pubsub.in-memory  ──── BUS #1 │  ← solo visible a este proceso│
║  │  │  state.in-memory   ──── RAM    │                               ║
║  │  │  secretstore ──── secrets.json │                               ║
║  │  └───────────────────────────┘    │                               ║
║  └───────────────────────────────────┘                               ║
║            │ SQL Auth Proxy                                          ║
║            │ localhost:5432                                          ║
╚════════════╪═════════════════════════════════════════════════════════╝
             │ TCP
╔════════════╪═════════════════════════════════════════════════════════╗
║  GCP       │                                                         ║
║            ▼                                                         ║
║  Cloud SQL pgsql-fin-sandbox-dev:5432  ← REAL                       ║
║                                                                      ║
║  (Pub/Sub, Redis, Dapr GKE control plane — NO conectados)           ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## Qué SÍ está conectado a GCP

| Componente | Conexión | Detalle |
|---|---|---|
| **Cloud SQL** | ✅ Real (TCP cifrado) | `cloud-sql-proxy` corre en background tras `dev-connect.sh`; tu app escribe y lee de la BD real en `us-east1` |
| **Secret Manager** | ✅ Solo al arrancar sesión | `dev-connect.sh` llama a `gcloud secrets versions access` UNA vez para leer la contraseña de BD; después no vuelve a contactar Secret Manager |

> **Importante:** Cloud SQL es compartido con GKE. Si GKE tiene un pod corriendo el mismo
> servicio, ambos (local y GKE) leen y escriben en la **misma base de datos**. Las proyecciones
> que actualices localmente son visibles en GKE y viceversa.

---

## Qué NO está conectado a GCP

| Componente | Estado | Consecuencia práctica |
|---|---|---|
| **Cloud Pub/Sub** | ❌ Desconectado | Los eventos que publiques localmente NO llegan a GKE. Los eventos de GKE NO llegan a tu proceso local |
| **Dapr control plane (GKE)** | ❌ Desconectado | Tu `daprd` local NO es parte del service mesh de GKE. No hay mTLS con sentry del cluster |
| **Redis (state store)** | ❌ Desconectado | State store local es in-memory en RAM; NO compartido con el Redis del cluster |
| **Placement (actores)** | ❌ Deshabilitado | `--placement-host-address ""` en `tasks.json`; ningún servicio usa actores |
| **Zipkin/Jaeger** | ❌ No disponible | Solo activo si Docker corre con `dapr_zipkin`. Las trazas locales se pierden |
| **GCP APIs (authn, IAM)** | ❌ No contactadas | El middleware de Access Manager puede estar en modo mock (`AccessManager:Mock:Enabled=true`) |

---

## Qué se simula vs. qué es real

### Pub/Sub — Simulado (aislado por proceso)

```
Tu proceso local (base-config)          Otro proceso local (segments)
┌─────────────────────────────┐         ┌─────────────────────────────┐
│  daprd                      │         │  daprd                      │
│  BUS A (in-memory)          │         │  BUS B (in-memory)          │
│                             │         │                             │
│  publish → BUS A            │         │  publish → BUS B            │
│  subscribe ← BUS A          │         │  subscribe ← BUS B          │
└─────────────────────────────┘         └─────────────────────────────┘
         ↕ NO SE COMUNICAN ↕
```

**Cada proceso tiene su propio bus in-memory aislado.** Si segments publica un
`CompanyCreatedEvent` localmente, base-config local NO lo recibe aunque ambos
estén corriendo. Los eventos solo "viajan" dentro del mismo proceso — es decir,
un handler en el mismo servicio puede publicar y otro handler del mismo servicio
puede recibirlo, pero no entre servicios distintos.

**¿Para qué sirve entonces el pub/sub local?** Sirve para:
- Verificar que los endpoints de suscripción se registran correctamente (`/dapr/subscribe`)
- Probar que el handler deserializa el envelope y actualiza la DB sin errores
- Invocar manualmente via `curl` el endpoint de evento para simular la recepción

### Service Invocation — Real entre procesos locales

```
segments (7012)  →→→  dapr invoke  →→→  base-config (7014)
                       (mDNS local)
```

Service invocation FUNCIONA entre servicios locales si ambos están corriendo.
Dapr los descubre vía mDNS en la red local. Esto incluye los jobs de reconciliación:
`GET /api/v1/companies/snapshot` desde base-config hacia `segments.segments`.

**Condición:** ambos servicios deben estar corriendo localmente con sus respectivos
`--app-id` y puertos Dapr.

### Cloud SQL — Real

La base de datos es REAL. No hay mock ni seed de datos. Las migraciones EF Core
que corras localmente (`dotnet ef database update`) modifican la BD compartida.
Todos los desarrolladores usan la misma instancia `pgsql-fin-sandbox-dev`.

### Secrets — Simulado (archivo local)

```
dapr/secrets/secrets.json   ←  secretstore.local.file
```

Los secrets que Dapr lee localmente vienen del archivo `dapr/secrets/secrets.json`
en el repo del servicio. Este archivo contiene valores de desarrollo (placeholders o
valores reales para test). En GKE, el secret store apunta a GCP Secret Manager.

| Secret | Local | GKE |
|---|---|---|
| Connection string DB | `dapr/secrets/secrets.json` | GCP Secret Manager |
| `TenantId` | `appsettings.Development.json` | K8s env var (desde Secret Manager) |
| `InternalApiKey` | `appsettings.Development.json` | K8s env var (desde Secret Manager) |

### mTLS — Deshabilitado

En GKE, Dapr usa mTLS entre sidecars (via sentry). Localmente no hay sentry, por lo
que la comunicación entre `daprd` y la app es texto plano en `localhost`. Esto es
intencional y seguro para desarrollo local.

---

## Flujo completo: evento en GKE vs. evento local

### GKE (producción/dev desplegado)

```
Segments API
  └─ publica CompanyCreatedEvent
      └─ daprd sidecar → Cloud Pub/Sub → topic: segments-events
                                          └─ suscripción: base-config-segments-events
                                              └─ daprd de base-config (GKE pod)
                                                  └─ POST /events/company-created → base-config-api
                                                      └─ upsert en Cloud SQL
```

### Local Modo A (in-memory)

```
Segments API (local, puerto 7012)
  └─ publica CompanyCreatedEvent
      └─ daprd local → BUS A in-memory (solo visible dentro del proceso segments)
                        └─ ¿hay algún handler suscrito a segments-events en segments? NO
                            └─ evento se pierde (no hay consumidor en el mismo proceso)

Base-config API (local, puerto 7014)  ← proceso SEPARADO, NO recibe nada
```

**Para probar el handler de base-config localmente:**

```bash
# Simular la recepción de un CompanyCreatedEvent directamente en base-config
curl -X POST http://localhost:7014/events/company-created \
  -H "Content-Type: application/json" \
  -d '{
    "eventID": "550e8400-e29b-41d4-a716-446655440000",
    "tenantID": "843a387f-4ae1-42f7-af9e-0b5a85022ec7",
    "data": {
      "entityId": "...",
      "eventType": "CompanyCreatedEvent",
      "code": "001",
      "name": "Empresa Demo",
      "isActive": true,
      "timestamp": "2026-04-21T00:00:00Z"
    }
  }'
```

O invocar el job de reconciliación para poblar la proyección desde el snapshot real:

```bash
# Reconciliar companies desde segments (requiere ambos servicios corriendo localmente)
curl -X POST http://localhost:7014/reconcile-companies
```

---

## Verificar suscripciones activas

El endpoint `/dapr/subscribe` expone qué topics y handlers tiene registrados el sidecar.
Útil para verificar que las prioridades son únicas y los match expressions son correctos:

```bash
# Reemplazar 3514 con el puerto Dapr HTTP del servicio (ver tabla de puertos)
curl http://localhost:3514/dapr/subscribe | jq .
```

Ejemplo de respuesta correcta (base-config, segments-events):

```json
[
  {
    "pubsubname": "pubsub",
    "topic": "segments-events",
    "routes": {
      "rules": [
        { "match": "event.data.EventType == \"CompanyCreatedEvent\"",   "path": "/events/company-created",   "priority": 1 },
        { "match": "event.data.EventType == \"CompanyUpdatedEvent\"",   "path": "/events/company-updated",   "priority": 2 },
        { "match": "event.data.EventType == \"CompanyStatusChangedEvent\"", "path": "/events/company-status-changed", "priority": 3 },
        ...
      ],
      "default": "/events/segments-unhandled"
    }
  }
]
```

**Señales de alerta:**
- Si `default` está ausente → eventos no reconocidos serán NACKed y reintentados en GKE
- Si dos reglas tienen el mismo `priority` → Dapr loga `fail: duplicate priorities` al arrancar y el routing falla

---

## Resumen rápido

| Pregunta | Respuesta |
|---|---|
| ¿Puedo desarrollar sin internet? | ✅ Sí — excepto para Cloud SQL (requiere VPN o IP en MAN) |
| ¿Mis eventos locales llegan a GKE? | ❌ No — bus in-memory aislado |
| ¿Los eventos de GKE llegan a mi proceso? | ❌ No — misma razón |
| ¿Mis cambios en BD afectan a GKE? | ✅ Sí — Cloud SQL es compartido |
| ¿Los datos del cluster están disponibles localmente? | ✅ Sí — misma BD Cloud SQL |
| ¿Puedo testear reconciliación localmente? | ✅ Sí — via service invocation mDNS (requiere ambos servicios corriendo) |
| ¿Puedo testear pub/sub entre dos servicios locales? | ❌ No en Modo A — usar Modo B (GCP Pub/Sub real) |
| ¿Se graban trazas en Jaeger? | ❌ No en Modo A — requiere Docker con `dapr_zipkin` |

---

## Ver también

- `docs/developer-guide.md` — Setup completo, comandos de arranque, tabla de puertos
- `docs/developer-guide.md#modo-b` — Cómo activar Pub/Sub real contra GKE (Modo B)
- `docs/idempotent-consumer-pattern.md` — Deduplicación de eventos en consumers Dapr
- `CLAUDE.md § Checklist obligatorio al implementar un nuevo consumidor Dapr Pub/Sub`
