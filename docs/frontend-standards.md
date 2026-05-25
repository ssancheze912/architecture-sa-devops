# Estándares Frontend MFE — Business Financiero

> Documento de referencia obligatorio para todos los servicios.
> Cualquier nuevo MFE o feature debe cumplir estos estándares antes de merge.
> Actualizar este documento cuando se descubra o corrija un nuevo patrón.

## 1. `apiClient` — Patrón Obligatorio

Todo servicio MFE debe tener un `src/core/api/client.ts` con **tres interceptores obligatorios**:

```ts
import axios from 'axios';
import i18n from '../i18n/config';

const apiClient = axios.create({
  // VITE_API_BASE_URL se pasa como build-arg en ci-pipeline.yml
  // Fallback: /api/{service-name} (nunca /api/v1 ni localhost)
  baseURL: import.meta.env.VITE_API_BASE_URL || '/api/{service-name}',
  headers: { 'Content-Type': 'application/json' },
});

apiClient.interceptors.request.use((config) => {
  // 1. Idioma para localización en backend (ASP.NET Core)
  config.headers['Accept-Language'] = i18n.language;

  // 2. Compañía activa (omitir si la request no necesita contexto de compañía)
  const companyId = sessionStorage.getItem('X-Company-Id');
  if (companyId) config.headers['X-Company-Id'] = companyId;

  // 3. JWT — OBLIGATORIO para que el middleware de access-manager autentique
  const token = localStorage.getItem('access_manager_user_token');
  if (token) config.headers['Authorization'] = `Bearer ${token}`;

  return config;
});

export default apiClient;

// apiClientDirect: igual que apiClient pero SIN X-Company-Id automático.
// Usar en endpoints donde el body ya lleva los company IDs (bulk assign).
export const apiClientDirect = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '/api/{service-name}',
  headers: { 'Content-Type': 'application/json' },
});

apiClientDirect.interceptors.request.use((config) => {
  config.headers['Accept-Language'] = i18n.language;
  const token = localStorage.getItem('access_manager_user_token');
  if (token) config.headers['Authorization'] = `Bearer ${token}`;
  return config;
});
```

### Checklist por servicio

| Servicio | baseURL fallback | Authorization | Accept-Language | X-Company-Id |
|---|---|---|---|---|
| segments | `/api` ✅ | ✅ | ✅ | ✅ |
| base-config | `/api/base-config` ✅ | ✅ | ✅ | ✅ |
| third-party | `/api/third-party` ✅ | ✅ (fix 2026-05-08) | ✅ | ✅ |
| accounting | `/api/accounting` ✅ | ✅ (fix 2026-05-08) | ✅ | ✅ |
| liquid-tax | `/api` ⚠️ (usa `access_token` en sessionStorage — pendiente alinear) | ✅ | ✅ | ✅ |

### Anti-patrones prohibidos

```ts
// ❌ NUNCA usar axios directamente en un service/hook
import axios from 'axios';
const response = await axios.get('/api/...');

// ❌ NUNCA hardcodear el token manualmente
config.headers['Authorization'] = `Bearer ${localStorage.getItem('access_manager_user_token')}`;
// (el interceptor de apiClient ya lo hace)

// ❌ NUNCA hardcodear localhost como fallback
baseURL: import.meta.env.VITE_API_BASE_URL || 'http://localhost:7018/api/v1'

// ❌ NUNCA hardcodear /api/v1 como fallback
baseURL: import.meta.env.VITE_API_BASE_URL || '/api/v1'

// ❌ NUNCA usar paths absolutos con /api/v1/ dentro de un service
await apiClient.get(`/api/v1/tax-keys/${id}`); // ← doble prefijo en producción
// ✅ Correcto:
await apiClient.get(`/tax-keys/${id}`); // baseURL ya tiene el prefijo
```

---

## 2. Permisos — Convención de Nombres

Formato: `{prefijo}.{entidad-kebab}.{acción_snake}`

| Parte | Formato | Ejemplo |
|---|---|---|
| Prefijo de servicio | kebab-case | `third-party`, `tax`, `segment`, `base-config`, `acct` |
| Entidad | kebab-case plural | `economic-activities`, `identification-types`, `fiscal-years` |
| Acción | snake_case | `read`, `create`, `update`, `change_status`, `update_global`, `assign` |

### Ejemplos correctos

```ts
usePermission('third-party.economic-activities.read')    // ✅
usePermission('third-party.customer-types.change_status') // ✅
usePermission('segment.fiscal-years.create')              // ✅
usePermission('tax.tax-groups.read')                      // ✅
```

### Anti-patrones prohibidos

```ts
usePermission('third_party.economic_activities.read')  // ❌ underscores en prefijo/entidad
usePermission('fiscal-years.read')                     // ❌ falta prefijo de servicio
usePermission('third-party.customer_types.read')       // ❌ snake en entidad
```

### Registro de permisos

Los permisos se registran manualmente vía `POST /internal/v1/permissions/register` (una vez por ambiente).
**No** se auto-registran en startup.

---

## 3. i18n — Cambio de Idioma Reactivo

### 3.1 `config.ts` — listener obligatorio

Todo MFE debe escuchar el evento del app-shell:

```ts
// Al final de config.ts, después de i18n.init(...)
window.addEventListener('siesa:language-changed', ((event: CustomEvent<{ language: string }>) => {
  i18n.changeLanguage(event.detail.language);
}) as EventListener);
```

### 3.2 `useMasterCrudLocale` — hook para MasterPatternView

```ts
// src/core/i18n/useMasterCrudLocale.ts
import { useTranslation } from 'react-i18next';

export function useMasterCrudLocale(): string {
  const { i18n } = useTranslation();
  return i18n.language.startsWith('en') ? 'en' : 'es';
}
```

### 3.3 Páginas con `<MasterPatternView>`

```tsx
// SIEMPRE incluir locale prop — sin ella MasterPatternView usa español fijo
const { t } = useTranslation('namespace');
const masterCrudLocale = useMasterCrudLocale();

<MasterPatternView
  locale={masterCrudLocale}  // ← OBLIGATORIO
  title={t('title')}
  // ...
/>
```

### 3.4 Definiciones de campos — PROBLEMA CONOCIDO

Los archivos `*.definition.ts` exportados como `const` tienen labels hardcodeados:

```ts
// ❌ PROBLEMA ACTUAL: no reactivo al cambio de idioma
export const fiscalYearDefinition: MasterPatternViewDefinition = {
  fields: [{ fieldName: 'code', label: 'Año' }]  // ← string fijo
};
```

**Solución pendiente:** Convertir a hooks `useXxxDefinition()` que usen `t()`:

```ts
// ✅ PATRÓN CORRECTO (pendiente implementar en todos los servicios)
export function useFiscalYearDefinition(): MasterPatternViewDefinition {
  const { t } = useTranslation('fiscal-years');
  return {
    fields: [{ fieldName: 'code', label: t('fields.code') }]
  };
}
```

**Servicios afectados:** segments, accounting, liquid-tax, third-party (todos los `.definition.ts`).
Tracking: issue pendiente de refactor en todos los servicios.

---

## 4. Rutas MFE — Convención

### Activación del MFE (app-shell `mfe-registry.ts`)

```ts
// El ID en route.tsx DEBE coincidir exactamente con la key en mfe-registry.ts
// mfe-registry.ts:
'banks': '@siesa/base-config',        // ← key debe existir
'process-numbers': '@siesa/base-config',

// route.tsx:
navigateTo('banks')        // ✅ coincide
navigateTo('process-numbers')  // ✅ coincide
navigateTo('bancos')       // ❌ no existe en mfe-registry → MFE nunca se activa
```

### Rutas Gateway y `VITE_API_BASE_URL`

| Servicio | `VITE_API_BASE_URL` (ci-pipeline) | HTTPRoute Gateway | Backend recibe |
|---|---|---|---|
| base-config | `/api/base-config` | `/api/base-config/*` → rewrite `/api/v1/*` | `/api/v1/...` |
| segments | `/api` | `/api/segments/*` | `/api/v1/...` |
| third-party | `/api/third-party` | `/api/third-party/*` → rewrite `/api/v1/*` | `/api/v1/...` |
| accounting | `/api/accounting` | `/api/accounting/*` → rewrite `/api/v1/*` | `/api/v1/...` |
| liquid-tax | `/api/liquid-tax` | `/api/liquid-tax/*` → rewrite `/api/v1/*` | `/api/v1/...` |

**Regla:** Los services del MFE usan paths **relativos** (sin prefijo /api/v1/). El baseURL + gateway rewrite produce la ruta correcta.

---

## 5. Historial de Bugs y Fixes

### 2026-05-08 — Auditoría cross-service

| # | Servicio | Bug | Causa | Fix | Commit |
|---|---|---|---|---|---|
| 1 | app-shell | Bancos y Consecutivos no se mostraban | IDs `bancos`/`consecutivos` en route.tsx no existían en mfe-registry | Cambiar a `banks`/`process-numbers` | `d0ca6be` |
| 2 | third-party | 401 en todos los endpoints | `client.ts` sin interceptor Authorization | Agregar interceptor con `access_manager_user_token` | `6aa36cb` |
| 3 | third-party | 403 en 4 features | Permisos `third_party.entity_snake` en lugar de `third-party.entity-kebab` | Corregir strings en 4 pages | `6aa36cb` |
| 4 | third-party | 404 en tax-keys/tax-classes | Paths `/api/v1/tax-keys/` hardcodeados dentro del service (doble prefijo) | Cambiar a paths relativos `/tax-keys/` | `6aa36cb` |
| 5 | accounting | 401 en todos los endpoints | `client.ts` sin interceptor Authorization + localhost fallback | Agregar interceptor + corregir fallback | `405740a` |
| 6 | segments | 401 en maestro-cuentas | `accountService.ts` usaba `axios` directo sin Authorization | Migrar a `apiClient` | `aa9da577` |
| 7 | segments | Texto i18n fijo en MasterPatternView | Faltaba `locale={masterCrudLocale}` en 12 páginas | Agregar hook y prop en todas las páginas | `aa9da577` |
| 8 | accounting | Texto i18n fijo en MasterPatternView | Faltaba `locale={masterCrudLocale}` | Agregar en páginas (commit anterior) | — |
| 9 | liquid-tax | Texto i18n fijo en MasterPatternView | Faltaba `locale={masterCrudLocale}` | Agregar en 6 features (commit anterior) | — |
| 10 | base-config | Texto i18n fijo en MasterPatternView | Faltaba `locale={masterCrudLocale}` | Agregar en features (commit anterior) | — |

### Pendientes conocidos

| # | Servicio | Problema | Causa raíz | Acción requerida |
|---|---|---|---|---|
| P1 | Todos | Columnas del grid no cambian de idioma | `*.definition.ts` son consts con labels hardcodeados en español | Refactor a hooks `useXxxDefinition()` con `t()` |
| P2 | segments | `useBusinessUnitMutations`, `useUserCompanies` usan axios directo | Hooks legacy sin migrar | Migrar a `apiClient` |
| P3 | liquid-tax | `client.ts` lee token de `sessionStorage('access_token')` en vez de `localStorage('access_manager_user_token')` | Token key inconsistente | Alinear con estándar |
| P4 | base-config | Error en `/app/exchange-rate-types-by-doc-class` | Causa pendiente de investigar | Investigar respuesta API |
| P5 | base-config | Textos i18n como claves en `/app/document-types` | Namespace no cargado o registro faltante | Investigar config.ts |
