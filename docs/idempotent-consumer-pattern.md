# Idempotent Consumer Pattern

Guía de implementación del patrón de consumidor idempotente para los servicios financieros Siesa.

## Índice

- [¿Por qué?](#por-qué)
- [Estado actual por servicio](#estado-actual-por-servicio)
- [Diseño del patrón](#diseño-del-patrón)
- [Piezas de implementación](#piezas-de-implementación)
- [Plan de implementación por servicio](#plan-de-implementación-por-servicio)
- [Checklist de validación](#checklist-de-validación)
- [Historial de cambios](#historial-de-cambios)

---

## ¿Por qué?

Dapr Pub/Sub usa semántica **at-least-once delivery**: un mensaje puede entregarse más de una vez por reintentos, fallos de red o reinicios de pod. Sin deduplicación:

- Un evento `CompanyCreatedEvent` podría intentar insertar la misma proyección dos veces → race condition o error de constraint único.
- Un evento `FiscalPeriodOpenedEvent` podría abrir el mismo período dos veces.
- Cualquier side effect (correos, llamadas externas) se ejecutaría múltiples veces.

Los handlers que solo hacen `UpsertAsync` son tolerantes a duplicados **por datos**, pero no a **duplicados de side effects** ni a situaciones donde la operación no es idempotente por naturaleza.

**Solución:** Registrar cada `EventID` procesado en una tabla de base de datos y rechazar duplicados con `200 OK` antes de ejecutar la lógica de negocio.

---

## Estado actual por servicio

| Servicio | Idempotencia | Tabla `processed_events` | Notas |
|---|---|---|---|
| `base-config` | ✅ Implementado | ✅ schema `base_config` | Referencia canónica |
| `liquid-tax` | ✅ Implementado | ✅ schema `liquid_tax` | Igual a base-config |
| `segments` | ✅ Implementado | ✅ schema `segment` | 14/14 endpoints con guardia (incl. `/user-projection-sync` tras envelope AM) |
| `third-party` | ✅ Implementado | ✅ schema `tprt` | 12/12 endpoints con guardia; `DomainEventEnvelope.EventId` agregado |
| `accounting` | ✅ Implementado | ✅ schema `acct` | Infraestructura lista; sin consumers Dapr activos aún |

**`base-config` y `liquid-tax` son la referencia canónica.**

### Nota sobre access-manager — `TenantId = Guid.Empty`

La entidad `User` de access-manager no expone `TenantId`. El `DomainEventEnvelope<UserChangedEvent>` se publica con `TenantId = Guid.Empty`. Los consumers que tengan `IsInvalidTenant` activo en el endpoint de user-changed descartarán el evento si su `TenantId` configurado != `Guid.Empty`. Verificar en third-party que el guard de tenant esté desactivado para este endpoint (o que acepte `Guid.Empty`).

El fix también corrigió un bug oculto: los consumers estaban bindeando a tipos planos pero el `OutboxProcessor` publica el `DomainEventEnvelope<T>` completo → todos los campos llegaban como default.

### Nota sobre third-party — `DomainEventEnvelope.EventId`

El `DomainEventEnvelope` de third-party no tenía campo `EventId`. Se agregó en `ThirdPartyService.Shared/Events/DomainEventEnvelope.cs` para poder usar la guardia. Los 12 endpoints de proyección tienen la guardia completa.

---

## Diseño del patrón

```
Dapr entrega mensaje (EventID: ABC)
        │
        ▼
EventHandlerGuard.IsDuplicateAsync(eventStore, EventID)
        │
   ┌────┴────┐
   │ Sí (ya  │──► return Results.Ok()   (descarte silencioso, Dapr no reintenta)
   │procesado│
   └─────────┘
        │ No
        ▼
EventHandlerGuard.IsInvalidTenant(tenantId, envelope.TenantID)
        │
   ┌────┴────┐
   │TenantID │──► return Results.Ok()   (descarte por tenant incorrecto)
   │inválido │
   └─────────┘
        │ Válido
        ▼
   Lógica de negocio (UpsertAsync, etc.)
        │
        ▼
eventStore.MarkProcessedAsync(EventID)
        │
        ▼
return Results.Ok()
```

**Puntos clave:**
- `MarkProcessedAsync` se llama **después** de la lógica de negocio, no antes. Si el handler falla, el evento no queda marcado y Dapr puede reintentarlo.
- El endpoint siempre retorna `200 OK` para duplicados: Dapr interpreta cualquier 2xx como entrega exitosa y no reintenta. Un 4xx/5xx haría que Dapr reintentara indefinidamente.
- La tabla `processed_events` usa el `EventID` (Guid) como PK → insert único garantizado por constraint de base de datos.

---

## Piezas de implementación

### 1. Entidad `ProcessedEvent`

**Ruta:** `{Service}.Infrastructure/EventStore/ProcessedEvent.cs`

```csharp
namespace {Service}.Infrastructure.EventStore;

public class ProcessedEvent
{
    public Guid EventId { get; set; }
    public DateTimeOffset ProcessedAt { get; set; }
}
```

### 2. Interfaz `IEventStore`

**Ruta:** `{Service}.Application/Common/IEventStore.cs`

```csharp
namespace {Service}.Application.Common;

public interface IEventStore
{
    Task<bool> IsProcessedAsync(Guid eventId, CancellationToken ct = default);
    Task MarkProcessedAsync(Guid eventId, CancellationToken ct = default);
}
```

### 3. Implementación `EventStoreRepository`

**Ruta:** `{Service}.Infrastructure/EventStore/EventStoreRepository.cs`

```csharp
namespace {Service}.Infrastructure.EventStore;

public class EventStoreRepository : IEventStore
{
    private readonly {Service}DbContext _dbContext;

    public EventStoreRepository({Service}DbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<bool> IsProcessedAsync(Guid eventId, CancellationToken ct = default)
    {
        return await _dbContext.ProcessedEvents
            .AsNoTracking()
            .AnyAsync(e => e.EventId == eventId, ct);
    }

    public async Task MarkProcessedAsync(Guid eventId, CancellationToken ct = default)
    {
        var exists = await _dbContext.ProcessedEvents
            .AnyAsync(e => e.EventId == eventId, ct);

        if (!exists)
        {
            _dbContext.ProcessedEvents.Add(new ProcessedEvent
            {
                EventId = eventId,
                ProcessedAt = DateTimeOffset.UtcNow
            });
            await _dbContext.SaveChangesAsync(ct);
        }
    }
}
```

### 4. Configuración EF Core

**Ruta:** `{Service}.Infrastructure/Data/Configurations/ProcessedEventConfiguration.cs`

```csharp
namespace {Service}.Infrastructure.Data.Configurations;

public class ProcessedEventConfiguration : IEntityTypeConfiguration<ProcessedEvent>
{
    public void Configure(EntityTypeBuilder<ProcessedEvent> builder)
    {
        builder.ToTable("processed_events", "{schema}");   // ← schema específico del servicio
        builder.HasKey(e => e.EventId);
        builder.Property(e => e.EventId).HasColumnName("event_id");
        builder.Property(e => e.ProcessedAt)
               .HasColumnName("processed_at")
               .HasDefaultValueSql("NOW()");
    }
}
```

### 5. DbSet en el DbContext

En `{Service}DbContext.cs`, agregar:

```csharp
public DbSet<ProcessedEvent> ProcessedEvents => Set<ProcessedEvent>();
```

### 6. Registro de dependencias

En `InfrastructureServiceExtensions.cs` (o donde se registren los repositorios):

```csharp
services.AddScoped<IEventStore, EventStoreRepository>();
```

### 7. Migración EF Core

```bash
dotnet ef migrations add AddProcessedEventsTable \
  --project src/backend/{Service}.Infrastructure \
  --startup-project src/backend/{Service}.API
```

La migración genera:

```csharp
migrationBuilder.CreateTable(
    name: "processed_events",
    schema: "{schema}",
    columns: table => new
    {
        event_id = table.Column<Guid>(type: "uuid", nullable: false),
        processed_at = table.Column<DateTimeOffset>(
            type: "timestamp with time zone",
            nullable: false,
            defaultValueSql: "NOW()")
    },
    constraints: table =>
    {
        table.PrimaryKey("pk_processed_events", x => x.event_id);
    });
```

### 8. Uso en endpoints Dapr

```csharp
app.MapPost("/events/entity-changed", async (
    DomainEventEnvelope<EntityChangedEvent> envelope,
    IProjectionService projectionService,
    IEventStore eventStore,
    CancellationToken ct) =>
{
    if (await EventHandlerGuard.IsDuplicateAsync(eventStore, envelope.EventID, ct))
        return Results.Ok();
    if (EventHandlerGuard.IsInvalidTenant(tenantId, envelope.TenantID))
        return Results.Ok();

    await projectionService.UpsertAsync(/* ... */, ct);
    await eventStore.MarkProcessedAsync(envelope.EventID, ct);
    return Results.Ok();
})
.WithTopic(new TopicOptions { /* ... */ });
```

---

---

## Checklist de validación

Por cada servicio, verificar después del cambio:

- [ ] `dotnet build` sin errores ni warnings
- [ ] `dotnet ef migrations list` muestra `AddProcessedEventsTable` como `Applied` (o pendiente de aplicar en CI/CD)
- [ ] `grep -r "IEventStore" src/` muestra registro en DI + uso en endpoints
- [ ] `grep -r "IsDuplicateAsync" src/` aparece en TODOS los handlers de eventos Dapr
- [ ] `grep -r "MarkProcessedAsync" src/` aparece en TODOS los handlers (después del upsert, no antes)
- [ ] El endpoint retorna `200 OK` para duplicados (no `400` ni `409`)
- [ ] Test manual: enviar el mismo mensaje dos veces vía `dapr publish` → segunda entrega no genera cambios en DB

---

## Historial de cambios

| Fecha | Servicio | Descripción | Commit |
|---|---|---|---|
| 2026-03-18 | `base-config` | Implementación inicial | migración `20260318152802_AddProcessedEventsTable` |
| — | `liquid-tax` | Implementación (replicando base-config) | migración `20260416193414_AddEventIdempotencyStore` |
| 2026-04-17 | `base-config` | Fix gap: guardia en `UserCompanyAssignmentsPrjEndpoints` | `664914f` |
| 2026-04-17 | `segments` | Infraestructura base + TODO en endpoints sin EventID | migración `20260417222429_AddProcessedEventsTable` |
| 2026-04-19 | `segments` | Fix consumers rotos + idempotencia completa (13/13 vía envelope) | `5888f618` |
| 2026-04-19 | `access-manager` | Agregar `DomainEventEnvelope<UserChangedEvent>` en `EntityEventPublisher` | `5b243dc` |
| 2026-04-19 | `base-config`, `liquid-tax`, `segments`, `third-party` | Actualizar consumer `/events/user-changed` y `/user-projection-sync` para usar envelope AM | commits en `develop` |
| 2026-04-17 | `third-party` | Implementación completa 12/12 endpoints + `EventId` en envelope | migración `20260417222556_AddProcessedEventsTable` |
| 2026-04-17 | `accounting` | Infraestructura base lista para futuros consumers | migración `20260417222308_AddProcessedEventsTable` |
