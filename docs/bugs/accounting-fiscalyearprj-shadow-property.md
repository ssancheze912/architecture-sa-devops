# BUG: accounting-service — FiscalYearPrj shadow property sin tipo

**Repo:** `SiesaTeams/business-financiero-accounting-service`
**Detectado:** 2026-05-20 durante primer deploy en QA
**Severidad:** Alta — las migraciones EF Core no corren; el schema `acct` nunca se crea
**Estado:** Abierto

---

## Síntoma

El pod `accounting-api` arranca (K8s readiness pasa) pero el schema `acct` no existe en Cloud SQL QA. El `OutboxProcessor` crashea con:

```
Npgsql.PostgresException: 42P01: relation "acct.outbox_messages" does not exist
```

## Error raíz

`MigrateAsync()` falla en el paso de validación (`HasPendingModelChanges → BuildModel`) con:

```
fail: Microsoft.EntityFrameworkCore.Database.Command[20102]
warn: AccountingService.Infrastructure.Data.AccountingServiceDbContext[0]
      Database migration skipped: The property 'Code' cannot be added to the type
      'AccountingService.Domain.Entities.Projected.Segment.FiscalYearPrj
      (Dictionary<string, object>)' because no property type was specified and there
      is no corresponding CLR property or field. To add a shadow state property,
      the property type must be specified.

      System.InvalidOperationException: ...
         at AccountingServiceDbContextModelSnapshot.<>c.<BuildModel>b__0_99(EntityTypeBuilder b)
            in /src/AccountingService.Infrastructure/Data/Migrations/
               AccountingServiceDbContextModelSnapshot.cs:line 6696
         at AccountingServiceDbContextModelSnapshot.BuildModel(ModelBuilder modelBuilder)
            in /src/AccountingService.Infrastructure/Data/Migrations/
               AccountingServiceDbContextModelSnapshot.cs:line 6654
         at Microsoft.EntityFrameworkCore.Migrations.Internal.Migrator.HasPendingModelChanges()
         at Microsoft.EntityFrameworkCore.Migrations.Internal.Migrator.MigrateAsync(...)
```

## Causa

`FiscalYearPrj` es una entidad de tipo `Dictionary<string, object>` (shared-type entity). En `AccountingServiceDbContextModelSnapshot.cs` línea 6696, hay una propiedad shadow `Code` configurada sin tipo explícito:

```csharp
// ❌ Probablemente así (sin tipo):
b.Property("Code");

// ✅ Debe ser así (tipo explícito):
b.Property<string>("Code");
```

EF Core no puede inferir el tipo de una propiedad shadow en entidades `Dictionary<string, object>` — requiere tipo explícito.

## Por qué no falla en DEV

El try/catch en `Program.cs` atrapa la excepción y loguea un warning. El pod arranca de todos modos. En DEV, si el schema ya existe de una migración anterior válida, el `OutboxProcessor` funciona. En QA es el primer deploy — el schema nunca existió.

## Fix

En `business-financiero-accounting-service`:

1. Localizar `AccountingServiceDbContextModelSnapshot.cs:6696` (dentro del lambda `b__0_99`).
2. Encontrar `b.Property("Code")` en la configuración de `FiscalYearPrj`.
3. Cambiar a `b.Property<string>("Code")` (o el tipo correcto según el dominio).
4. Verificar que no haya otras propiedades shadow sin tipo en entidades `Dictionary<string, object>`.
5. Si la entidad tiene propiedades en el modelo de dominio, considerar usar una clase CLR en lugar de `Dictionary<string, object>`.

**Nota:** No se necesita una nueva migración — solo corregir el snapshot. Pero si la propiedad también está mal en el archivo de migración `.cs` correspondiente, corregirla también.

## Impacto en QA

- Schema `acct` no existe en `finance-qa`
- El grant DDL no se pudo ejecutar (`acct` no existe)
- Todos los endpoints de accounting que tocan DB fallan con `42P01`
- El `OutboxProcessor` de accounting crashea en loop (controlado por try/catch, no causa CrashLoopBackOff)

## Pasos para verificar el fix

```bash
# 1. Después del fix + redeploy a QA, verificar que el schema existe:
kubectl exec -n accounting deploy/accounting-api -- env | grep ConnectionStrings
# Conectarse al psql y verificar:
# SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'acct';

# 2. Ejecutar el grant DDL pendiente (usar SET ROLE como en los otros schemas):
# SET ROLE accounting;
# GRANT ALL PRIVILEGES ON SCHEMA acct TO accounting;
# GRANT ALL ON ALL TABLES IN SCHEMA acct TO accounting;
# ...
# Ver docs/qa-db-grants.md para el script completo
```
