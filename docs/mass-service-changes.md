# Cambios Masivos en Servicios (Multi-repo Paralelo)

Guía para aplicar cambios homogéneos a todos los servicios de la plataforma financiera de forma simultánea usando sub-agentes Claude Code.

## Servicios Activos

| Servicio | Ruta Local | Namespace K8s |
|---|---|---|
| `business-financiero-segments-service` | `/Users/diegosantacruz/Documents/SiesaTeams/business-financiero-segments-service` | `segments` |
| `business-financiero-base-config` | `/Users/diegosantacruz/Documents/SiesaTeams/business-financiero-base-config` | `base-config` |
| `business-financiero-third-party-service` | `/Users/diegosantacruz/Documents/SiesaTeams/business-financiero-third-party-service` | `third-party` |
| `business-financiero-accounting-service` | `/Users/diegosantacruz/Documents/SiesaTeams/business-financiero-accounting-service` | `accounting` |
| `business-financiero-liquid-tax-service` | `/Users/diegosantacruz/Documents/SiesaTeams/business-financiero-liquid-tax-service` | `liquid-tax` |

## Patrón de Ejecución Paralela

### Principio

Lanzar un sub-agente `general-purpose` por cada servicio en un único mensaje (todas las llamadas en paralelo). Cada agente recibe contexto completo del stack, la tarea exacta y cómo validar que quedó correcto.

### Estructura del prompt por agente

Cada agente debe recibir:

1. **Stack técnico** — .NET 8/10, Dapr 1.17.3, Clean Arch + CQRS, K8s/GKE Autopilot
2. **Ruta absoluta del servicio** — para que no asuma paths
3. **Cambio exacto a realizar** — sin ambigüedad (qué archivo, qué línea, qué valor)
4. **Criterio de validación** — cómo verificar que el cambio quedó correcto (build, grep, test)
5. **Convenciones del repo** — rama `develop`, sin push directo, branch `feat/` o `fix/`

### Template de llamada paralela

```
Mensaje único con N tool calls Agent en paralelo:

Agent #1 → segments-service   → prompt con contexto completo
Agent #2 → base-config        → mismo prompt adaptado a su ruta
Agent #3 → third-party        → mismo prompt adaptado a su ruta
Agent #4 → accounting-service → mismo prompt adaptado a su ruta
Agent #5 → liquid-tax-service → mismo prompt adaptado a su ruta
```

### Contexto mínimo a pasar siempre

```
Stack: .NET 8/10 ASP.NET Core Minimal APIs, Dapr 1.17.3, Clean Architecture + CQRS
Repo: {nombre-repo}
Ruta local: {ruta-absoluta}
Rama base: develop
Convenciones:
- No hacer push; solo commits locales en branch feat/xxx o fix/xxx
- Dapr sidecar en 127.0.0.1:3500
- Cloud SQL Auth Proxy sidecar en 127.0.0.1:5432
- Namespace K8s: {namespace}
- Secrets via GCP Secret Manager (Dapr secrets component)
```

### Validación post-ejecución

Después de que todos los agentes terminen, verificar:

1. **Consistencia** — que el mismo cambio quedó aplicado en todos los servicios
2. **Build** — `dotnet build` sin errores en cada servicio
3. **Diff homogéneo** — `git diff` debe mostrar el mismo patrón de cambio en todos
4. **Sin regresiones** — ningún archivo no relacionado fue modificado

## Cuándo usar este patrón

- Actualizar versión de un paquete NuGet compartido en todos los servicios
- Agregar/modificar un middleware o configuración en `Program.cs`
- Cambiar una convención de naming o estructura de carpetas
- Aplicar un fix de seguridad transversal
- Actualizar configuración de Dapr (componentes, app-id, puerto)
- Cambios en `appsettings.json` (ej: TenantId, nuevas claves)

## Historial de cambios masivos

| Fecha | Cambio | Servicios afectados | PR/commit |
|---|---|---|---|
| 2026-04-17 | Idempotent Consumer Pattern — infraestructura base (`IEventStore`, `EventStoreRepository`, `ProcessedEventConfiguration`, migración `processed_events`, registro DI, guardia en endpoints Dapr) | segments, third-party, accounting | commits en `develop` de cada repo |
