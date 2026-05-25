# Convenciones Frontend (MFE)

> Aplica a **todos** los repos de servicio con frontend (`src/frontend/`). Seguir al pie de la letra — desviarse causó el bug de MFE no cargando.

## Build (vite.config.ts obligatorio)

| Elemento | Valor obligatorio | Motivo |
|---|---|---|
| Plugin Vite | `vite-plugin-single-spa` con `type: 'mife'` | Estándar single-spa; genera entry point correcto |
| `base` | `'/mfe/{service-name}/'` | Assets en la ruta donde nginx los sirve |
| `define` | `'process.env.NODE_ENV': JSON.stringify(mode)` | Vite no reemplaza `process.env.*` en lib mode |
| `spaEntryPoints` | `'src/spa-entry.tsx'` | Entry point del MFE para single-spa |
| `VITE_MODE` Docker ARG | `development` (dev), `production` (prod) | Controla warnings de React y optimizaciones |
| `VITE_API_BASE_URL` Docker ARG | `/api` (dev/prod), sin pasar (local) | Base URL del cliente HTTP |

```ts
// vite.config.ts mínimo
singleSpaPlugin({ serverPort: 5173, type: 'mife', spaEntryPoints: 'src/spa-entry.tsx' })
define: { 'process.env.NODE_ENV': JSON.stringify(mode) }
base: '/mfe/{service-name}/'
```

## Routing de API desde el frontend

**Regla absoluta:** El frontend siempre llama a `/api/{prefijo}/...`. El Gateway reescribe. **Nunca** hardcodear `/api/v1/` en código frontend.

| URL que llama el frontend | Gateway reescribe a | Backend destino |
|---|---|---|
| `/api/segments/*` | `/api/v1/segments/*` | `segments-api:8080` |
| `/api/base/*` | `/api/v1/base/*` | `segments-api:8080` |
| `/api/operation-centers/*` | `/api/v1/operation-centers/*` | `segments-api:8080` |
| `/api/liquidtax/*` | `/api/v1/liquidtax/*` | `segments-api:8080` |
| `/api/access-manager/*` | `/api/v1/*` | `access-manager-api:8080` |

**`createFetcher` (siesa-ui-kit):**
```ts
// CORRECTO
const fetcher = createFetcher('/api');
<LookupField entity="segments/account-plans/principals" fetcher={fetcher} />

// INCORRECTO — bypasea Gateway, retorna HTML del app-shell
const fetcher = createFetcher('/api/v1');
```

**`apiClient` (axios):** `src/core/api/client.ts` → `baseURL = import.meta.env.VITE_API_BASE_URL || '/api/v1'`. Con `VITE_API_BASE_URL=/api` inyectado, `apiClient.get('/segments/companies')` → `/api/segments/companies` → Gateway ✓.

## i18n — Sincronización de idioma con el app-shell

El app-shell gestiona el idioma activo en `localStorage('language')` y despacha un evento en `window` cada vez que el usuario cambia el idioma. Cada MFE debe escuchar ese evento para actualizar su instancia de i18next.

### 1. Leer idioma inicial al arrancar (`core/i18n/config.ts`)

```typescript
// Segments: leer de localStorage explícitamente
lng: localStorage.getItem('language') || 'es-CO',

// Base-config: usa LanguageDetector con order: ['localStorage', ...]
// — ya lee de localStorage automáticamente, no se requiere cambio.
```

### 2. Escuchar cambios en runtime (`core/i18n/config.ts`)

```typescript
// Al final del archivo, después de i18n.init(...)
window.addEventListener('siesa:language-changed', ((event: CustomEvent<{ language: string }>) => {
  i18n.changeLanguage(event.detail.language);
}) as EventListener);
```

### 3. Header `Accept-Language` en API (`core/api/client.ts`)

```typescript
import i18n from '../i18n/config';

apiClient.interceptors.request.use((config) => {
  config.headers['Accept-Language'] = i18n.language;  // ← agregar esta línea
  // ... resto del interceptor
  return config;
});
```

### 4. Prop `locale` en MasterCrud (`useMasterCrudLocale.ts` + cada página)

`siesa-ui-kit` MasterCrud tiene un diccionario interno `{ es, en }`. Sin el prop `locale`, siempre muestra sus labels internos en español.

```typescript
// src/core/i18n/useMasterCrudLocale.ts
import { useTranslation } from 'react-i18next';
export function useMasterCrudLocale(): string {
  const { i18n } = useTranslation();
  return i18n.language.startsWith('en') ? 'en' : 'es';
}
```

```typescript
// En cada página con <MasterCrud>
import { useMasterCrudLocale } from '@core/i18n/useMasterCrudLocale';

const masterCrudLocale = useMasterCrudLocale();

<MasterCrud locale={masterCrudLocale} ... />
```

> `useTranslation()` re-renderiza el componente cuando cambia el idioma — sin listeners manuales adicionales.

**Estado actual (2026-04-01):** `segments-service` (13 MasterCrud) y `base-config` (9 MasterCrud) implementados.

## Patrón HTTPRoute para nuevo servicio

```yaml
# namespace: {service-name} | parentRefs[0].sectionName: https
rules:
  # MFE — /mfe/{service}/* → / → nginx
  - matches:
      - path: { type: PathPrefix, value: /mfe/{service-name} }
    filters:
      - type: URLRewrite
        urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: / } }
    backendRefs:
      - name: {service-name}-mfe
        port: 80
  # API principal — /api/{service-name}/* → /api/v1/{service-name}/*
  - matches:
      - path: { type: PathPrefix, value: /api/{service-name} }
    filters:
      - type: URLRewrite
        urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: /api/v1/{service-name} } }
    backendRefs:
      - name: {service-name}-api
        port: 8080
  # Rutas adicionales si el backend expone otros prefijos
  - matches:
      - path: { type: PathPrefix, value: /api/{otro-prefijo} }
    filters:
      - type: URLRewrite
        urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: /api/v1/{otro-prefijo} } }
    backendRefs:
      - name: {service-name}-api
        port: 8080
```
