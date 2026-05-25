# Pub/Sub — Topics y Eventos

> **Convención:** un topic por servicio, formato `{servicio}-events`.
> `disableEntityManagement: true` — Terraform es quien crea topics y suscripciones en GCP.
> Nombres de suscripciones: `{dapr-app-id}-{topic}`.

---

## Configuración del entorno

| Parámetro | Valor |
|---|---|
| GCP Project ID | `prj-sie-fin-financiero-dev` |
| Dapr pubsub component | `pubsub` |
| Dapr HTTP port | `3500` (sidecar local) |
| Dapr gRPC port | `50001` (sidecar local) |

---

## Topics activos

| Topic | GCP resource | Productor | Suscripciones |
|---|---|---|---|
| `access-manager-events` | `projects/prj-sie-fin-financiero-dev/topics/access-manager-events` | Access Manager | `base-config-access-manager-events`, `segments-access-manager-events` |
| `segments-events` | `projects/prj-sie-fin-financiero-dev/topics/segments-events` | Segments | `base-config-segments-events`, `segments-segments-events` (self) |
| `base-config-events` | `projects/prj-sie-fin-financiero-dev/topics/base-config-events` | Base Config | `segments-base-config-events` |
| `liquid-tax-events` | `projects/prj-sie-fin-financiero-dev/topics/liquid-tax-events` | LiquidTax *(futuro)* | `segments-liquid-tax-events` |
| `third-party-events` | `projects/prj-sie-fin-financiero-dev/topics/third-party-events` | ThirdParty *(futuro)* | `segments-third-party-events` |

---

## Cómo consumir eventos

### Opción A — Vía Dapr (recomendado para servicios en el cluster)

El componente Dapr `pubsub` ya está configurado en cada namespace. Solo se necesita registrar los endpoints de suscripción.

**Suscribirse a un topic (ASP.NET Core):**
```csharp
app.MapPost("/mi-handler",
    [Topic("pubsub", "segments-events")]
    async (MiEvento evt, ...) => { ... });
```

**Publicar un evento:**
```csharp
await daprClient.PublishEventAsync("pubsub", "segments-events", payload, ct);
```

**HTTP API del sidecar Dapr (publicar):**
```
POST http://localhost:3500/v1.0/publish/pubsub/{topic-name}
Content-Type: application/json

{ ...payload... }
```

**Prerequisito:** el `MapSubscribeHandler()` debe estar registrado en `Program.cs` antes de los endpoints de suscripción:
```csharp
app.UseCloudEvents();
app.MapSubscribeHandler();
```

---

### Opción B — Vía GCP Pub/Sub directo (servicios externos al cluster)

Requiere crear una suscripción propia en el topic. **No crear suscripciones manualmente** — agregarlas vía Terraform en `terraform/environments/dev/main.tf` siguiendo la convención `{dapr-app-id}-{topic}`.

**Pull de mensajes (REST):**
```
POST https://pubsub.googleapis.com/v1/projects/prj-sie-fin-financiero-dev/subscriptions/{subscription-name}:pull
Authorization: Bearer {access_token}
Content-Type: application/json

{ "maxMessages": 100 }
```

**Acknowledge de mensajes:**
```
POST https://pubsub.googleapis.com/v1/projects/prj-sie-fin-financiero-dev/subscriptions/{subscription-name}:acknowledge
Authorization: Bearer {access_token}
Content-Type: application/json

{ "ackIds": ["..."] }
```

**Suscripciones existentes por topic:**

| Suscripción | GCP resource |
|---|---|
| `base-config-access-manager-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/base-config-access-manager-events` |
| `segments-access-manager-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/segments-access-manager-events` |
| `base-config-segments-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/base-config-segments-events` |
| `segments-segments-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/segments-segments-events` |
| `segments-base-config-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/segments-base-config-events` |
| `segments-liquid-tax-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/segments-liquid-tax-events` |
| `segments-third-party-events` | `projects/prj-sie-fin-financiero-dev/subscriptions/segments-third-party-events` |

> **IAM requerido:** el SA del servicio consumidor necesita `roles/pubsub.subscriber` en el proyecto y `roles/pubsub.viewer` para leer metadatos de la suscripción.

---

## Formato del mensaje (CloudEvents via Dapr)

Dapr envuelve todos los eventos en el estándar CloudEvents 1.0:

```json
{
  "specversion": "1.0",
  "type": "com.dapr.event.sent",
  "source": "segments-api",
  "id": "uuid-v4",
  "datacontenttype": "application/json",
  "data": {
    "eventType": "SegmentCreatedEvent",
    "eventId": "uuid-v4",
    "occurredAt": "2026-04-06T16:00:00Z",
    "payload": { ...campos del evento... }
  }
}
```

> El campo `data.eventType` es el discriminador para identificar el tipo de evento dentro del topic.

---

## `segments-events` — Eventos publicados por Segments

### Company

| Evento | Disparado cuando |
|---|---|
| `CompanyCreatedEvent` | POST /companies exitoso |
| `CompanyUpdatedEvent` | PUT /companies/{id} exitoso |
| `CompanyStatusChangedEvent` | PATCH /companies/{id}/status |
| `UserCompanyAssignmentChangedEvent` | Asignación o revocación de usuario a empresa |

### Segment Configuration

| Evento | Disparado cuando |
|---|---|
| `SegmentConfigurationCreatedEvent` | Creación de configuración de segmento |
| `SegmentConfigurationUpdatedEvent` | Actualización de configuración de segmento |
| `SegmentConfigurationStatusChangedEvent` | Cambio de estado de configuración |
| `SegmentConfigurationCompanyAssignedEvent` | Empresa asignada a configuración |
| `SegmentConfigurationCompanyUnassignedEvent` | Empresa removida de configuración |

### Segment

| Evento | Disparado cuando |
|---|---|
| `SegmentCreatedEvent` | POST /segments exitoso |
| `SegmentUpdatedEvent` | PUT /segments/{id} exitoso |
| `SegmentStatusChangedEvent` | PATCH /segments/{id}/status |

### Cost Center

| Evento | Disparado cuando |
|---|---|
| `CostCenterCreatedEvent` | Creación de centro de costo |
| `CostCenterUpdatedEvent` | Actualización de centro de costo |
| `CostCenterStatusChangedEvent` | Cambio de estado de centro de costo |
| `CostCenterOverrideStatusChangedEvent` | Cambio de estado de override de empresa |
| `CostCenterOverrideRemovedEvent` | Override eliminado o estado cambiado |

### Cost Center Group

| Evento | Disparado cuando |
|---|---|
| `CostCenterGroupCreatedEvent` | Creación de grupo de centros de costo |
| `CostCenterGroupUpdatedEvent` | Actualización de grupo |
| `CostCenterGroupStatusChangedEvent` | Cambio de estado de grupo |

### Business Unit

| Evento | Disparado cuando |
|---|---|
| `BusinessUnitCreatedEvent` | Creación de unidad de negocio |
| `BusinessUnitUpdatedEvent` | Actualización de unidad de negocio |
| `BusinessUnitStatusChangedEvent` | Cambio de estado |
| `BusinessUnitHierarchyChangedEvent` | Cambio de padre o flag isTitle |
| `BusinessUnitDeletedEvent` | Eliminación de unidad de negocio |

### Business Unit Group

| Evento | Disparado cuando |
|---|---|
| `BusinessUnitGroupCreatedEvent` | Creación de grupo de unidades de negocio |
| `BusinessUnitGroupUpdatedEvent` | Actualización de grupo |
| `BusinessUnitGroupStatusChangedEvent` | Cambio de estado de grupo |

### Operation Center

| Evento | Disparado cuando |
|---|---|
| `OperationCenterCreatedEvent` | Creación de centro de operación |
| `OperationCenterUpdatedEvent` | Actualización de centro de operación |
| `OperationCenterStatusChangedEvent` | Cambio de estado |
| `OperationCenterAssignedEvent` | Asignación a empresa |
| `OperationCenterOverrideStatusChangedEvent` | Cambio de estado de override de empresa |
| `OperationCenterTreeUpdatedEvent` | Actualización del árbol de centros de operación |

### Operation Center Group

| Evento | Disparado cuando |
|---|---|
| `OperationCenterGroupCreatedEvent` | Creación de grupo de centros de operación |
| `OperationCenterGroupUpdatedEvent` | Actualización de grupo |
| `OperationCenterGroupStatusChangedEvent` | Cambio de estado de grupo |
| `OperationCenterGroupMembersUpdatedEvent` | Miembros agregados o removidos del grupo |

### Account Plan

| Evento | Disparado cuando |
|---|---|
| `AccountPlanCreatedEvent` | POST /account-plans exitoso |
| `AccountPlanUpdatedEvent` | PUT /account-plans/{id} en contexto global |
| `AccountPlanStatusChangedEvent` | Cambio de estado global |
| `AccountPlanCompanyAssignedEvent` | POST /{id}/companies/{companyId} |
| `AccountPlanCompanyRevokedEvent` | DELETE /{id}/companies/{companyId} |
| `AccountPlanOverrideUpdatedEvent` | Actualización de override por empresa |

### Account

| Evento | Disparado cuando |
|---|---|
| `AccountCreatedEvent` | POST /accounts exitoso |
| `AccountUpdatedEvent` | PUT /accounts/{id} en contexto global |
| `AccountStatusChangedEvent` | PATCH /accounts/{id}/status |

### Fiscal Year *(interno — Segments publica y consume vía `segments-segments-events`)*

| Evento | Disparado cuando |
|---|---|
| `FiscalYearCreatedEvent` | POST /fiscal-years exitoso |
| `FiscalYearUpdatedEvent` | PUT /fiscal-years/{id} exitoso |
| `FiscalYearCompanyAssignedEvent` | Empresa asignada a año fiscal |
| `FiscalYearCompanyUnassignedEvent` | Empresa removida de año fiscal |
| `FiscalYearActivatedEvent` | Año fiscal pasa de NotActivated → Active al abrir su primer período |

### Fiscal Period *(interno — Segments publica y consume vía `segments-segments-events`)*

| Evento | Disparado cuando |
|---|---|
| `FiscalPeriodOpenedEvent` | Apertura de período fiscal |
| `FiscalPeriodClosedEvent` | Cierre de período fiscal |
| `FiscalPeriodReopenedEvent` | Reapertura de período (Closed → Active) |

### Fiscal Date *(interno)*

| Evento | Disparado cuando |
|---|---|
| `FiscalDateStatusChangedEvent` | Cambio de estado de módulos en fecha fiscal |
| `FiscalDateHolidayToggledEvent` | Toggle de IsHoliday en fecha fiscal por empresa |

---

## `access-manager-events` — Eventos consumidos por Segments

| Evento | Suscripción | Efecto en Segments |
|---|---|---|
| `UserProjectionSyncEvent` | `segments-access-manager-events` | Sincroniza `UserPrj` |

---

## `base-config-events` — Eventos consumidos por Segments

| Evento | Suscripción | Efecto en Segments |
|---|---|---|
| `CountryProjectionSyncEvent` | `segments-base-config-events` | Sincroniza `CountryPrj` |
| `StateProjectionSyncEvent` | `segments-base-config-events` | Sincroniza `StatePrj` |
| `CityProjectionSyncEvent` | `segments-base-config-events` | Sincroniza `CityPrj` |
| `NeighborhoodProjectionSyncEvent` | `segments-base-config-events` | Sincroniza `NeighborhoodPrj` |
| `CurrencyProjectionSyncEvent` | `segments-base-config-events` | Sincroniza `CurrencyPrj` |

---

## `liquid-tax-events` — Eventos consumidos por Segments *(productor futuro)*

| Evento | Suscripción | Efecto en Segments |
|---|---|---|
| `TaxClassProjectionSyncEvent` | `segments-liquid-tax-events` | Sincroniza `TaxClassPrj` |
| `TaxClassValueProjectionSyncEvent` | `segments-liquid-tax-events` | Sincroniza `TaxClassValuePrj` |
| `WithholdingClassProjectionSyncEvent` | `segments-liquid-tax-events` | Sincroniza `WithholdingClassPrj` |
| `WithholdingClassValueProjectionSyncEvent` | `segments-liquid-tax-events` | Sincroniza `WithholdingClassValuePrj` |

---

## `third-party-events` — Eventos consumidos por Segments *(productor futuro)*

| Evento | Suscripción | Efecto en Segments |
|---|---|---|
| `SocialNetworkProjectionSyncEvent` | `segments-third-party-events` | Sincroniza `SocialNetworkPrj` |

---

## Reconciliación periódica de proyecciones

Los eventos Pub/Sub sincronizan proyecciones en tiempo real, pero pueden perderse mensajes (restart de pod, lag en Pub/Sub, eventos históricos previos al deploy). La **reconciliación periódica** es la segunda capa de consistencia: obtiene un snapshot completo del servicio origen vía Dapr service invocation y realiza un upsert masivo + soft-deactivate de registros ausentes.

### Resumen de frecuencias

| Servicio | Proyección | Frecuencia | Expresión cron |
|---|---|---|---|
| `base-config` | `UserPrj` | cada 15 min | `@every 15m` |
| `base-config` | `CompanyPrj` | cada 1 hora | `@every 1h` |
| `base-config` | `OperationCenterPrj` | cada 1 hora | `@every 1h` |
| `base-config` | `UserCompanyAssignmentPrj` | cada 1 hora | `@every 1h` |
| `segments` | `UserPrj` | cada 1 hora | `@every 1h` |

> `UserPrj` en base-config reconcilia cada 15 min (más frecuente) porque los usuarios son el dato de acceso más crítico y cambian con mayor frecuencia que las otras entidades.

### Mecanismo

```
Dapr Cron Binding
  → POST /{binding-name} en el pod destino
    → ReconciliationJob.RunAsync()
      → DaprClient.InvokeMethodAsync("{app-id}.{namespace}", "api/v1/{entidad}/snapshot")
        → GET /api/v1/{entidad}/snapshot en el servicio origen
          → ReconcileAsync(snapshot, timestamp)
            → Upsert de todos los registros del snapshot
            → Soft-deactivate (is_active = false) de registros locales ausentes en el snapshot
```

> **Dapr service invocation cross-namespace:** el app-id debe incluir el namespace destino (`{app-id}.{namespace-destino}`). Sin él, Dapr busca `{app-id}-dapr.{namespace-caller}.svc.cluster.local` y falla con DNS not found.

### Jobs activos

#### base-config (`dapr/base-config/`)

| Proyección | Job | Endpoint | Cron Binding | Frecuencia | Origen (`app-id.namespace`) | Snapshot path |
|---|---|---|---|---|---|---|
| `UserPrj` | `UserReconciliationJob` | `POST /reconcile-users` | `cron-reconcile-users.yaml` | 15 min | `accessmanager.access-manager` | `/api/v1/users/snapshot` |
| `CompanyPrj` | `CompanyReconciliationJob` | `POST /reconcile-companies` | `cron-reconcile-companies.yaml` | 1 hora | `segments.segments` | `/api/v1/companies/snapshot` |
| `OperationCenterPrj` | `OperationCenterReconciliationJob` | `POST /reconcile-operation-centers` | `cron-reconcile-operation-centers.yaml` | 1 hora | `segments.segments` | `/api/v1/operation-centers/snapshot` |
| `UserCompanyAssignmentPrj` | `UserCompanyAssignmentReconciliationJob` | `POST /reconcile-user-company-assignments` | `cron-reconcile-user-company-assignments.yaml` | 1 hora | `segments.segments` | `/api/v1/user-company-assignments/snapshot` |

#### segments (`dapr/segments/`)

| Proyección | Job | Endpoint | Cron Binding | Frecuencia | Origen (`app-id.namespace`) | Snapshot path |
|---|---|---|---|---|---|---|
| `UserPrj` | `UserReconciliationJob` | `POST /reconcile-users` | `cron-reconcile-users.yaml` | 1 hora | `accessmanager.access-manager` | `/api/v1/users/snapshot` |

### Endpoints snapshot en servicios origen

| Servicio | Endpoint | Auth | Notas |
|---|---|---|---|
| access-manager | `GET /api/v1/users/snapshot` | `[AllowAnonymous]` | Solo accesible via Dapr sidecar (mTLS), no expuesto en Gateway |
| segments | `GET /api/v1/companies/snapshot` | excluido de JWT en `UseWhen` | — |
| segments | `GET /api/v1/operation-centers/snapshot` | excluido de JWT en `UseWhen` | — |
| segments | `GET /api/v1/user-company-assignments/snapshot` | excluido de JWT en `UseWhen` | — |

### Trigger manual (sandbox)

```bash
# base-config
kubectl -n base-config port-forward svc/base-config-api 8080:8080
curl -X POST http://localhost:8080/reconcile-users
curl -X POST http://localhost:8080/reconcile-companies
curl -X POST http://localhost:8080/reconcile-operation-centers
curl -X POST http://localhost:8080/reconcile-user-company-assignments

# segments
kubectl -n segments port-forward svc/segments-api 8081:8080
curl -X POST http://localhost:8081/reconcile-users
```

### Estado actual (sandbox, 2026-04-07)

| Tabla | Schema | Registros activos |
|---|---|---|
| `users_prj` | `base_config` | 13 |
| `companies_prj` | `base_config` | 1 |
| `operation_centers_prj` | `base_config` | 0 |
| `user_company_assignments_prj` | `base_config` | 0 |
| `users_prj` | `segment` | 13 |
