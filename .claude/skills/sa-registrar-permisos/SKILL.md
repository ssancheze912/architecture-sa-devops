---
name: sa-registrar-permisos
description: 'Generates the exact curl command to register a services permissions in access-manager via POST /internal/v1/permissions/register. Use whenever the user needs to wire a new services permissions into the access-manager API.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Genera el curl exacto para registrar los permisos de un servicio en access-manager via POST /internal/v1/permissions/register.

**Uso:** `/sa-registrar-permisos {servicio} {prefijo} {entidad1} {entidad2} ...`

**Ejemplo:** `/sa-registrar-permisos treasury tax treasury-accounts treasury-transactions`

**Prefijos existentes por servicio:**
| Servicio | Prefijo |
|---|---|
| segments | `segment` |
| base-config | `base-config` |
| third-party | `third-party` |
| accounting | `acct` |
| liquid-tax | `tax` |

**Acciones estándar por entidad:** `create`, `read`, `update`, `delete`, `change_status`

---

## Instrucciones

Los argumentos son: `$ARGUMENTS`

- `SERVICIO` = primer argumento (ej: `treasury`)
- `PREFIJO` = segundo argumento (ej: `tax`)
- `ENTIDADES` = todos los argumentos restantes (ej: `treasury-accounts treasury-transactions`)

Lee `environments/dev.yaml` para obtener:
- `DOMINIO` = `.dns.domain` (ej: `finance.siesacloud.dev`)

---

### Paso 1 — Explicar el formato de permisos

```
Formato: Resource="{PREFIJO}.{entidad-plural-kebab}" + Action="{acción}"
Cadena en Redis = Resource + "." + Action

Ejemplo para prefijo "tax", entidad "treasury-accounts":
  Resource: "tax.treasury-accounts"
  Actions:  "create", "read", "update", "delete", "change_status"
  → Redis keys: "tax.treasury-accounts.create", "tax.treasury-accounts.read", etc.

IMPORTANTE:
  - Entidad: kebab-case (ej: treasury-accounts ✅ / treasuryAccounts ❌)
  - Acción:  snake_case (ej: change_status ✅ / changeStatus ❌)
  - Prefijo: siempre usar el prefijo del servicio (ej: "tax.treasury-accounts" ✅ / "treasury-accounts" ❌)
```

### Paso 2 — Generar el curl

Para cada entidad en ENTIDADES, genera permisos con las 5 acciones estándar.

```bash
# ============================================================
# Registrar permisos: servicio {SERVICIO}
# Ejecutar con acceso a https://{DOMINIO}
# Obtener X-Api-Key del Secret Manager: accmgr-sandbox-internal-api-key
# ============================================================

curl -X POST https://{DOMINIO}/api/access-manager/internal/v1/permissions/register \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: <INTERNAL_API_KEY>" \
  -H "X-Microservice-Source: {SERVICIO}" \
  -d '{
  "permissions": [
```

Para cada ENTIDAD genera:
```json
    { "resource": "{PREFIJO}.{ENTIDAD}", "action": "create" },
    { "resource": "{PREFIJO}.{ENTIDAD}", "action": "read" },
    { "resource": "{PREFIJO}.{ENTIDAD}", "action": "update" },
    { "resource": "{PREFIJO}.{ENTIDAD}", "action": "delete" },
    { "resource": "{PREFIJO}.{ENTIDAD}", "action": "change_status" },
```

Cierra el JSON:
```json
  ]
}'
```

### Paso 3 — Mostrar cómo usar en el código

```csharp
// En el endpoint del servicio {SERVICIO}:

// ✅ Correcto — con prefijo
[RequirePermission("{PREFIJO}.{ENTIDAD}.read")]

// ❌ Incorrecto — sin prefijo
[RequirePermission("{ENTIDAD}.read")]
```

### Paso 4 — Notas

```
⚠️  NOTAS:

  1. Obtener X-Api-Key:
       gcloud secrets versions access latest \
         --secret="accmgr-sandbox-internal-api-key" \
         --project={PROJECT_ID}

  2. Registro manual — NO auto-registrar en startup.
     El patrón de auto-registro fue eliminado.

  3. InternalApiKey (sin doble guión bajo) es la clave de configuración.
     InternalApi__Key mapea a InternalApi:Key — NO es leída por el filtro.

  4. Para validar que quedaron registrados:
       curl https://{DOMINIO}/api/access-manager/internal/v1/permissions \
         -H "X-Api-Key: <INTERNAL_API_KEY>"

  5. Si el servicio tiene más acciones personalizadas (ej: approve, export),
     agregarlas manualmente al JSON de permisos antes de ejecutar el curl.
```

---

## Inventario de permisos ya registrados en BD

> Re-ejecutar estos curls si se resetea `access_manager.permissions`.

### segments (`prefijo: segment`)

```bash
curl -X POST https://{DOMINIO}/api/access-manager/internal/v1/permissions/register \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: <INTERNAL_API_KEY>" \
  -H "X-Microservice-Source: segments" \
  -d '{
  "permissions": [
    {"resource": "segment.companies",              "action": "read",          "description": "Ver listado de compañías",                   "summary": "Leer compañías",                   "displayOrder": 1},
    {"resource": "segment.companies",              "action": "create",        "description": "Crear compañías",                            "summary": "Crear compañía",                   "displayOrder": 2},
    {"resource": "segment.companies",              "action": "update",        "description": "Editar compañías",                           "summary": "Editar compañía",                  "displayOrder": 3},
    {"resource": "segment.companies",              "action": "change_status", "description": "Activar/desactivar compañías",               "summary": "Cambiar estado compañía",          "displayOrder": 4},
    {"resource": "segment.cost-center-groups",     "action": "read",          "description": "Ver grupos de centros de costo",             "summary": "Leer grupos CC",                   "displayOrder": 10},
    {"resource": "segment.cost-center-groups",     "action": "create",        "description": "Crear grupos de centros de costo",           "summary": "Crear grupo CC",                   "displayOrder": 11},
    {"resource": "segment.cost-center-groups",     "action": "update",        "description": "Editar grupos de centros de costo",          "summary": "Editar grupo CC",                  "displayOrder": 12},
    {"resource": "segment.cost-center-groups",     "action": "change_status", "description": "Activar/desactivar grupos CC",               "summary": "Cambiar estado grupo CC",          "displayOrder": 13},
    {"resource": "segment.cost-center-groups",     "action": "assign",        "description": "Asignar centros de costo a grupos",          "summary": "Asignar CC a grupo",               "displayOrder": 14},
    {"resource": "segment.cost-center-groups",     "action": "update_global", "description": "Actualizar configuración global grupos CC",  "summary": "Actualizar global grupos CC",      "displayOrder": 15},
    {"resource": "segment.segment-configurations", "action": "read",          "description": "Ver configuraciones de segmentos",           "summary": "Leer configuraciones",             "displayOrder": 20},
    {"resource": "segment.segment-configurations", "action": "create",        "description": "Crear configuraciones de segmentos",         "summary": "Crear configuración",              "displayOrder": 21},
    {"resource": "segment.segment-configurations", "action": "update",        "description": "Editar configuraciones de segmentos",        "summary": "Editar configuración",             "displayOrder": 22},
    {"resource": "segment.segment-configurations", "action": "change_status", "description": "Activar/desactivar configuraciones",         "summary": "Cambiar estado configuración",     "displayOrder": 23},
    {"resource": "segment.segment-configurations", "action": "assign",        "description": "Asignar compañías a configuraciones",        "summary": "Asignar compañía a configuración", "displayOrder": 24},
    {"resource": "segment.segments",               "action": "read",          "description": "Ver segmentos",                              "summary": "Leer segmentos",                   "displayOrder": 30},
    {"resource": "segment.segments",               "action": "create",        "description": "Crear segmentos",                            "summary": "Crear segmento",                   "displayOrder": 31},
    {"resource": "segment.segments",               "action": "update",        "description": "Editar segmentos",                           "summary": "Editar segmento",                  "displayOrder": 32},
    {"resource": "segment.segments",               "action": "delete",        "description": "Eliminar segmentos",                         "summary": "Eliminar segmento",                "displayOrder": 33},
    {"resource": "segment.segments",               "action": "change_status", "description": "Activar/desactivar segmentos",               "summary": "Cambiar estado segmento",          "displayOrder": 34},
    {"resource": "segment.segments",               "action": "assign",        "description": "Asignar compañías a segmentos",              "summary": "Asignar compañía a segmento",      "displayOrder": 35}
  ]
}'
```

### third-party (`prefijo: third-party`)

```bash
curl -X POST https://{DOMINIO}/api/access-manager/internal/v1/permissions/register \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: <INTERNAL_API_KEY>" \
  -H "X-Microservice-Source: third-party" \
  -d '{
  "permissions": [
    {"resource": "third-party.economic-activities",  "action": "read",          "description": "Ver listado de actividades económicas",               "summary": "Leer actividades económicas",        "displayOrder": 40},
    {"resource": "third-party.economic-activities",  "action": "create",        "description": "Crear actividades económicas",                        "summary": "Crear actividad económica",          "displayOrder": 41},
    {"resource": "third-party.economic-activities",  "action": "update",        "description": "Editar actividades económicas",                       "summary": "Editar actividad económica",         "displayOrder": 42},
    {"resource": "third-party.economic-activities",  "action": "update_global", "description": "Actualizar configuración global actividades económicas","summary": "Actualizar global act. económica",  "displayOrder": 43},
    {"resource": "third-party.economic-activities",  "action": "change_status", "description": "Activar/desactivar actividades económicas",            "summary": "Cambiar estado actividad económica", "displayOrder": 44},
    {"resource": "third-party.economic-activities",  "action": "delete",        "description": "Eliminar actividades económicas",                     "summary": "Eliminar actividad económica",       "displayOrder": 45},
    {"resource": "third-party.economic-activities",  "action": "assign",        "description": "Asignar actividades económicas",                      "summary": "Asignar actividad económica",        "displayOrder": 46},
    {"resource": "third-party.identification-types", "action": "read",          "description": "Ver listado de tipos de identificación",              "summary": "Leer tipos de identificación",       "displayOrder": 50},
    {"resource": "third-party.identification-types", "action": "create",        "description": "Crear tipos de identificación",                       "summary": "Crear tipo de identificación",       "displayOrder": 51},
    {"resource": "third-party.identification-types", "action": "update",        "description": "Editar tipos de identificación",                      "summary": "Editar tipo de identificación",      "displayOrder": 52},
    {"resource": "third-party.identification-types", "action": "update_global", "description": "Actualizar configuración global tipos de identificación","summary": "Actualizar global tipo ID",         "displayOrder": 53},
    {"resource": "third-party.identification-types", "action": "change_status", "description": "Activar/desactivar tipos de identificación",           "summary": "Cambiar estado tipo identificación", "displayOrder": 54},
    {"resource": "third-party.identification-types", "action": "delete",        "description": "Eliminar tipos de identificación",                    "summary": "Eliminar tipo de identificación",    "displayOrder": 55},
    {"resource": "third-party.identification-types", "action": "assign",        "description": "Asignar tipos de identificación",                     "summary": "Asignar tipo de identificación",     "displayOrder": 56}
  ]
}'
```

### liquid-tax (`prefijo: tax`)

```bash
curl -X POST https://{DOMINIO}/api/access-manager/internal/v1/permissions/register \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: <INTERNAL_API_KEY>" \
  -H "X-Microservice-Source: liquid-tax" \
  -d '{
  "permissions": [
    {"resource": "tax.withholding-keys", "action": "read",          "description": "Ver listado de claves de retención",     "summary": "Leer claves de retención",        "displayOrder": 60},
    {"resource": "tax.withholding-keys", "action": "create",        "description": "Crear claves de retención",              "summary": "Crear clave de retención",        "displayOrder": 61},
    {"resource": "tax.withholding-keys", "action": "update",        "description": "Editar claves de retención",             "summary": "Editar clave de retención",       "displayOrder": 62},
    {"resource": "tax.withholding-keys", "action": "change_status", "description": "Activar/desactivar claves de retención", "summary": "Cambiar estado clave retención",  "displayOrder": 63},
    {"resource": "tax.withholding-keys", "action": "delete",        "description": "Eliminar claves de retención",           "summary": "Eliminar clave de retención",     "displayOrder": 64},
    {"resource": "tax.tax_keys",         "action": "read",          "description": "Ver listado de claves de impuesto",      "summary": "Leer claves de impuesto",         "displayOrder": 65},
    {"resource": "tax.tax_keys",         "action": "create",        "description": "Crear claves de impuesto",               "summary": "Crear clave de impuesto",         "displayOrder": 66},
    {"resource": "tax.tax_keys",         "action": "update",        "description": "Editar claves de impuesto",              "summary": "Editar clave de impuesto",        "displayOrder": 67},
    {"resource": "tax.tax_keys",         "action": "change_status", "description": "Activar/desactivar claves de impuesto",  "summary": "Cambiar estado clave impuesto",   "displayOrder": 68}
  ]
}'
```

### accounting (`prefijo: acct`)

```bash
curl -X POST https://{DOMINIO}/api/access-manager/internal/v1/permissions/register \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: <INTERNAL_API_KEY>" \
  -H "X-Microservice-Source: accounting" \
  -d '{
  "permissions": [
    {"resource": "acct.accounting-concepts", "action": "read",          "description": "Ver listado de conceptos contables",               "summary": "Leer conceptos contables",          "displayOrder": 80},
    {"resource": "acct.accounting-concepts", "action": "create",        "description": "Crear conceptos contables",                        "summary": "Crear concepto contable",           "displayOrder": 81},
    {"resource": "acct.accounting-concepts", "action": "update",        "description": "Editar conceptos contables",                       "summary": "Editar concepto contable",          "displayOrder": 82},
    {"resource": "acct.accounting-concepts", "action": "update_global", "description": "Actualizar configuración global conceptos contables","summary": "Actualizar global concepto contable","displayOrder": 83},
    {"resource": "acct.accounting-concepts", "action": "change_status", "description": "Activar/desactivar conceptos contables",            "summary": "Cambiar estado concepto contable",  "displayOrder": 84},
    {"resource": "acct.accounting-concepts", "action": "assign",        "description": "Asignar conceptos contables a compañías",           "summary": "Asignar concepto contable",         "displayOrder": 85}
  ]
}'
```
