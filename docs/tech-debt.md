# Deuda Técnica y Pendientes

## [PENDIENTE] Zona DNS siesacloud.dev en Spoke financiero — debe moverse a proyecto central

**Contexto:** La zona Cloud DNS `siesacloud-dev` (cubre `siesacloud.dev.`) está gestionada en `prj-sie-fin-financiero-dev` (Spoke de financiero). Es el dominio compartido de toda la organización — otras transversales usarían `comercial.siesacloud.dev`, `manufactura.siesacloud.dev`, etc.

**Riesgo actual:** Si el proyecto financiero se elimina, el dominio de toda la org se pierde. Otras transversales dependen de un proyecto BU-específico para su DNS.

**Destino propuesto:** Mover al Hub de financiero (`prj-sie-sb-fin-common`) como paso intermedio, y eventualmente a un proyecto Platform central (`prj-sie-pla-*`).

**Por qué no se migra ahora:** Requiere acceso al registrador del dominio `siesacloud.dev` para actualizar NS records. La migración implica downtime de DNS durante propagación. Coordinar con Cloud Admin team.

**Pasos cuando se retome:**
1. Crear zona en Hub con mismo `dns_name: "siesacloud.dev."`
2. Obtener nuevos nameservers del Hub
3. Actualizar NS en el registrador → esperar propagación
4. Migrar A records al nuevo proyecto via Terraform
5. Eliminar zona del Spoke + limpiar TF state

---

## [RESUELTO] Artifact Registry migrado al Hub — Spoke vacío pendiente

**Contexto:** A partir de 2026-05-14, las imágenes Docker de todos los servicios se almacenan en el Hub (`prj-sie-sb-fin-common`), repo compartido `art-fin-shared`:
```
us-east1-docker.pkg.dev/prj-sie-sb-fin-common/art-fin-shared/{service}/{service}-api:{sha}
```

Los repos individuales del Spoke (`prj-sie-fin-financiero-dev/access-manager`, `/segments`, etc.) quedan vacíos. Se eliminan las imágenes existentes del Spoke durante la migración de cada servicio.

**Pendiente menor:** Los 7 repos Spoke siguen existiendo en GCP (vacíos). Una vez que todos los servicios hayan sido migrados y no haya rollbacks previstos, eliminar via Terraform: remover del `module.artifact_registry` en `shared/main.tf` y del `environments/shared.yaml`.

---

## [RESUELTO] segments — consumers Dapr sin idempotencia real por contrato de publicación

**Contexto:** El Idempotent Consumer Pattern se implementó en todos los servicios (2026-04-17). Sin embargo, los 13 consumers Dapr de `segments-service` no tienen guardia activa. Raíz del problema: el `OutboxProcessor` de los productores publica el **payload plano** (no el `DomainEventEnvelope<T>` completo) a Dapr. Los consumers de segments reciben tipos planos sin `EventId`, por lo que no hay ID de evento disponible para deduplicar.

**Productores afectados:**
- `base-config` → topic `base-config-events` (geographic sync events)
- `liquid-tax` → topic `liquid-tax-events` (tax class/withholding sync)
- `third-party` → topic `third-party-events` (social network sync)
- `segments` mismo → topic `segments-events` (fiscal period/year events — self-consumed)
- `access-manager` → topic `access-manager-events` — caso especial: **no usa DomainEventEnvelope en absoluto**; publica `UserChangedEvent` plano directamente

**Fix requerido (cambio de contrato multi-repo):**
Dos opciones mutuamente excluyentes:

| Opción | Descripción | Esfuerzo |
|---|---|---|
| **A — Envelope en publicación** | Cambiar `OutboxProcessor` en cada productor para publicar el `DomainEventEnvelope<T>` completo; actualizar consumers de segments para bindear a `DomainEventEnvelope<TPayload>` | Alto — multi-repo coordinado |
| **B — EventId en payload** | Agregar campo `EventId: Guid` a cada evento plano publicado; consumers de segments lo usan para la guardia | Medio — cambio de contrato de eventos |

**Access-manager** requiere también migrar a `DomainEventEnvelope` o agregar `EventId` al `UserChangedEvent`.

**Resuelto 2026-04-19:** El `OutboxProcessor` ya publicaba el `DomainEventEnvelope<T>` completo. Los consumers bindeaban a tipos planos → valores default en todos los campos (bug oculto). Fix: cambiar binding a `DomainEventEnvelope<TPayload>` + `envelope.Payload` + guardia idempotente. 13/13 endpoints con guardia. Excepción permanente: `/user-projection-sync` (access-manager publica sin envelope). Commit `5888f618` en `business-financiero-segments-service`.

---

## [DESCARTADO] CI/CD — Migrar Docker builds de GitHub Actions a Cloud Build triggers nativos (PR #3)

**Contexto:** PR #3 (`feat/cloud-build-triggers`, abierto desde 2026-04-13) propone migrar el paso de `docker build/push` de GitHub Actions a Cloud Build triggers nativos con repos v2 (GitHub App). Actualmente GitHub Actions hace build+push a Artifact Registry y luego llama a Cloud Build solo para el deploy en GKE.

**Qué incluye el PR:**
- Nuevo módulo `terraform/modules/cloud-build-triggers/` (connection GitHub App v2, repos, triggers)
- `project-config.shared.yaml`: nueva sección `cloud_build_triggers` con `build_api`/`build_mfe` por servicio
- `terraform/environments/shared/main.tf`: módulo `cloud_build_triggers` + IAM Cloud Build SA
- `cicd-templates/.github/workflows/ci-pipeline.yml` convertido a fallback manual (`workflow_dispatch`)

**Por qué se descartó (2026-05-13):**
La arquitectura queda definida como: **GH Actions → docker build + push a AR → Cloud Build + kubectl deploy**. Cloud Build triggers nativos agregarían complejidad sin beneficio real dado que:
1. GH Actions ya maneja correctamente el build + push con WIF (sin JSON keys)
2. Los triggers de Cloud Build correrían en el Spoke, no en el Hub — no resuelven el item 18 de Hub-and-Spoke enforcement tal como estaba diseñado el PR
3. La nueva arquitectura AR-en-Hub (`HUB_PROJECT_ID`) cubre la necesidad de multi-ambiente sin necesidad de mover el build a Cloud Build

**Rama cerrada:** `feat/cloud-build-triggers` — no retomar.

---

## [PENDIENTE] Dapr local — placement server del cluster vs standalone

**Contexto:** Los developers necesitan ejecutar servicios localmente con Dapr sidecar. El placement server del cluster (`dapr-system/dapr-placement-server:50005`) es accesible solo vía `kubectl port-forward`, lo que requiere Master Authorized Networks (MAN). Los developers no tienen ni deben tener permisos para modificar MAN.

**Estado actual:** La instrucción en CLAUDE.md es usar `dapr init` (standalone local), que instala un placement server local vía Docker. Los componentes GCP (pubsub, statestore, secretstore) se configuran en `~/.dapr/components/` usando ADC. Funciona para desarrollo, pero:
- Requiere Docker corriendo localmente
- El placement server local está aislado del cluster (no comparte actor state)
- Dapr 1.14+ tiene `dapr init --slim` que no requiere Docker

**Alternativas evaluadas:**

| Opción | Pros | Contras |
|---|---|---|
| `dapr init` local (status quo) | Sin cambios de infra, simple | Requiere Docker |
| `dapr init --slim` | Sin Docker | Solo placement, sin dashboard |
| Exponer placement via TCP LB | Transparente para el developer | Requiere TCP load balancer (costo, complejidad) |
| Cloud IAP Tunnel | Seguro, sin MAN | Setup complejo por developer |

**Recomendación:**
- **Corto plazo:** Documentar `dapr init --slim` como alternativa sin Docker.
- **Largo plazo:** Evaluar TCP load balancer interno cuando el equipo de desarrollo crezca.

**Archivos a modificar:**
- `scripts/dev-connect.sh` (agregar instrucciones slim si aplica)
- `docs/` (guía Dapr local)

---

## [RESUELTO] Snapshot endpoints expuestos públicamente sin autenticación

**Contexto:** Los endpoints `/snapshot` de todos los servicios están decorados con `[AllowAnonymous]` / excluidos del `UseWhen` de auth para que otros servicios los consuman vía Dapr service invocation. Sin embargo, el Gateway los exponía públicamente sin ninguna protección adicional. Afectaba:
- `GET /api/v1/users/snapshot` en access-manager (PII: id, name, email, Firebase UID)
- `GET /api/v1/sales-agents/snapshot` en third-party (además, con `mockEnabled=true` en GKE el bloque `UseWhen` entero se omitía — cero protección)
- `GET /api/v1/{countries,states,cities,neighborhoods}/snapshot` en base-config
- `GET /api/v1/operation-centers/snapshot` y `contacts/snapshot` en segments

**Resuelto 2026-04-20/21:**
- `business-access-manager` commit `d574b9e2` — guard en `Program.cs` para `/api/v1/users/snapshot`
- `business-financiero-third-party-service` commit `c228f37` — guard incondicional en `UseAccessManager` para todos los paths `*/snapshot`
- `business-financiero-segments-service` commit `185a08a1` — ídem
- `business-financiero-base-config` commit `8d8aa0a9` — ídem

**Patrón aplicado (todos los servicios):** Middleware `app.Use(...)` incondicional antes del bloque de auth. Exige header `dapr-caller-app-id` en cualquier path que termine en `/snapshot`. Sin el header → 403. El header lo inyecta automáticamente el sidecar Dapr; llamadas directas desde internet nunca lo incluyen.

**Nota:** Cloud Armor (Opción B — infra) sigue pendiente para PROD como defensa en profundidad + OWASP WAF (SQLi, XSS). No implementado aún en Terraform.

**Archivos a modificar (Opción B):**
- `terraform/environments/dev/main.tf` (agregar `google_compute_security_policy` + `GCPGatewayPolicy`)
- `terraform/modules/gateway/main.tf` (opcional: módulo para la política)

---

## [RESUELTO] `verification_digit` NOT NULL en `base_config.companies_prj` — divergencia de constraints

**Contexto:** `segment.companies.verification_digit` es nullable, pero `base_config.companies_prj.verification_digit` tenía NOT NULL constraint. Empresas sin dígito de verificación causaban `23502 null value in column "verification_digit"` silencioso.

**Resuelto:** 2026-04-07 — migration `MakeCompanyPrjVerificationDigitNullable` aplicada en `business-financiero-base-config` commit `67ce1a2`.

---

## [RESUELTO] DaprClient sin `PropertyNameCaseInsensitive` — proyecciones con `ID = Guid.Empty`

**Contexto:** `AddDaprClient()` sin opciones JSON usaba `System.Text.Json` con `PropertyNameCaseInsensitive = false` (default). `InvokeMethodAsync<List<T>>` deserializaba snapshots donde el JSON tiene `"id"` (camelCase) pero las entidades C# tienen `ID` (PascalCase) → `Guid.Empty`. El `CreateAsync` fallaba con `23505 unique constraint` para registros subsecuentes (el primero insertaba `ID=00000000-...`). `ReconcileAsync` reportaba `N entities processed` sin indicar los fallos. Resultado: todas las proyecciones mantenidas via reconciliación tenían IDs incorrectos → FK violations al crear entidades que referencian esas proyecciones (`fk_fiscal_years_users_prj_created_by_user_id`).

**Verificado:** 2026-04-07 — `segment.users_prj` vacío o con IDs=00000000-..., bloquea creación de años fiscales con error 23503.

**Afecta:** `segments` (UserPrj) y `base-config` (UserPrj, CompanyPrj, OperationCenterPrj, UserCompanyAssignmentPrj).

**Resuelto:** 2026-04-07 — `AddDaprClient(options => options.UseJsonSerializationOptions(...PropertyNameCaseInsensitive = true))` en:
- `segments`: `MessagingExtensions.cs` (commit `2b855d4d`)
- `base-config`: `DatabaseExtensions.cs` (commit `9df2540`)

---

## [RESUELTO] Fiscal Years — `Cannot read properties of undefined (reading 'forEach')`

**Contexto:** La página de años fiscales lanzaba `Cannot read properties of undefined (reading 'forEach')` en `FiscalYearListPage.tsx:123`. `res.data` era `undefined`.

**Causa raíz:** `fiscalYearService.ts`, `fiscalYearApiService.ts` y `fiscalDateService.ts` tenían `const BASE = 'fiscal-years'`. Con `VITE_API_BASE_URL=/api` (Docker ARG), las llamadas iban a `/api/fiscal-years` — sin match en el Gateway HTTPRoute. El app-shell devolvía HTML, axios lo ponía en `response.data` (string), y `res.data` era `undefined` al acceder `.data` en un string.

**Resuelto:** 2026-04-08 — cambio de `'fiscal-years'` → `'segments/fiscal-years'` en los 3 archivos. URL resultante: `/api/segments/fiscal-years` → Gateway reescribe a `/api/v1/segments/fiscal-years` → backend correcto. Commit `0518b693`.

---

## [RESUELTO] Columnas NOT NULL en proyecciones de Segments y Base Config causan fallos silenciosos

**Contexto:** Múltiples tablas de proyección tenían columnas NOT NULL pero los eventos/snapshots no siempre incluían esos campos. El consumer retornaba 200 OK (para evitar retry de Dapr/GCP), pero la proyección no se actualizaba. Confirmado en pruebas 2026-04-20.

**Tablas afectadas:**
- `segment.countries_prj.description` — NOT NULL, pero `CountryProjectionSyncEvent` no incluye `description`
- `segment.social_networks_prj.icon` — NOT NULL, pero el payload de terceros no incluye `icon`
- `base_config.companies_prj.description` — NOT NULL, pero el snapshot de companies de segments no incluye `description`

**Resuelto 2026-04-20:**
- `business-financiero-segments-service` commit `f6ab974c`: `CountryPrj.Description` e `SocialNetworkPrj.Icon` → `string?`, `.IsRequired()` removido, migración `MakeProjectionColumnsNullable`.
- `business-financiero-base-config` commit `e825e82`: `CompanyPrj.Description` → `string?`, `.IsRequired()` removido, migración `MakeCompanyPrjDescriptionNullable`.
- Verificado: `/reconcile-countries` y `/reconcile-companies` retornan 200; social network sync con `Icon: null` retorna 200.

---

## [RESUELTO] Migración `AddProcessedEventsTable` en Segments — schema drift y rename `operation_center_contacts`

**Contexto:** La migración `20260417222429_AddProcessedEventsTable` en segments acumuló schema drift al generarse (incluía ~90 operaciones). Al aplicarse fallaba con `42P01: relation "segment.base_contact_operation_center" does not exist` — la migración intentaba modificar una tabla que existía bajo el nombre `operation_center_contacts` (nombre del InitialCreate).

**Workaround aplicado 2026-04-20:**
1. La migración fue corregida para usar `IF EXISTS`/`IF NOT EXISTS` en drops/creates.
2. La tabla `segment.processed_events` fue creada manualmente con SQL y la migración marcada como aplicada en `__EFMigrationsHistory`.
3. Commit `6635e31b` en `business-financiero-segments-service`.

**Resuelto 2026-04-20 — commit `cd0df3cd`:** Nueva migración `RenameOperationCenterContactsTable` renombra `segment.operation_center_contacts` → `segment.base_contact_operation_center` y aplica las FK constraints a `cities_prj` y `neighborhoods_prj` que habían quedado pendientes del schema drift. Deploy exitoso — endpoints `/api/v1/operation-centers/contacts/` operativos.

---

## [RESUELTO] `GetCallerId()` siempre retornaba `Guid.Empty` — FK violations y datos corruptos

**Contexto:** **Todos** los endpoints del segments service usaban `ctx.User.FindFirst("sub")` / `Guid.CreateVersion7()` / `DevUserId` para obtener el caller ID. El middleware de AccessManager almacena los claims en `ctx.Items` (no en `ctx.User`), por lo que `ctx.User` siempre era el `ClaimsPrincipal` anónimo. `FindFirst("sub")` siempre retornaba `null` → `GetCallerId()` retornaba `Guid.Empty`.

**Afecta:** `fiscal_years`, `fiscal_periods`, `fiscal_dates` (FK IMMEDIATE a `users_prj`) → error 23503. Todas las demás entidades almacenaban `Guid.Empty` como `created_by_user_id` silenciosamente (corrupción de datos sin excepción).

**Causa raíz secundaria:** `TokenClaims` del AM SDK no incluía el `UserId` (claim `sub` del JWT). `ExtractClaimsFromToken` extraía `identity_id`, `tenant_id`, `email`, `sid` — pero no `sub`.

**Fix aplicado — 2026-04-07:**

1. **`business-access-manager` (commit `a615015`):**
   - `TokenClaims.cs`: se agrega `Guid UserId` como 5º parámetro (del claim JWT `sub`)
   - `AuthenticationService.cs`: extrae `sub` y lo pasa a `TokenClaims`
   - `HttpContextExtensions.cs`: se agrega `GetUserId()` → `GetAccessManagerClaims()?.UserId ?? Guid.Empty`
   - Tests actualizados. Publicado como `Siesa.AccessManager 0.1.2`.

2. **`business-financiero-segments-service` (commit `2973e44b`):**
   - 14 endpoints modificados: todos usan `ctx.GetUserId()` via el nuevo método del SDK
   - Archivos: `FiscalYearEndpoints`, `FiscalDateEndpoints`, `CompanyEndpoints`, `CompanyContactEndpoints`, `CostCenterEndpoints`, `CostCenterGroupsEndpoints`, `BusinessUnitsEndpoints`, `BusinessUnitGroupsEndpoints`, `OperationCenterGroupsEndpoints`, `SegmentEndpoints`, `SegmentConfigurationEndpoints`, `UserCompaniesEndpoints`
   - `SegmentsService.API.csproj`: bump `0.1.1` → `0.1.2`

**Pendiente verificar:** Tras el deploy, crear un año fiscal en la UI — debe retornar 201 en vez de 500.

---

## [PENDIENTE] Cloud SQL Auth Proxy sidecar-por-pod → PgBouncer u alternativa

**Contexto:** Cada pod backend corre un sidecar `cloud-sql-proxy` dedicado. Con 2 servicios el overhead es mínimo (~20m CPU / 64Mi RAM), pero escala linealmente. Cloud SQL PostgreSQL tiene límite de ~100 conexiones en instancias pequeñas.

**Alternativas:**

| Opción | Pros | Contras |
|---|---|---|
| PgBouncer centralizado | Un pool compartido, bajo overhead | SPOF, rompe min-privilege |
| PgBouncer por namespace | Aislamiento por SA, sin SPOF global | Pod dedicado siempre encendido |
| CloudSQL Connector embebido (.NET) | Sin sidecar, autenticación WI nativa | Dependencia en cada app |
| AlloyDB + IP privada | Sin proxy, conectividad directa VPC | Costo alto, migración de datos |
| Mantener sidecar (status quo) | Simple, aislado, fácil de depurar | Escala mal en prod |

**Recomendación:**
- **Sandbox/dev:** Mantener sidecar (despreciable con 2-3 servicios).
- **QAS/PROD (5+ servicios):** PgBouncer por namespace (`transaction` mode) — `Deployment` en cada namespace, `ClusterIP` en `:5432`. Los pods apuntan al service interno en vez de `127.0.0.1`.
- **Largo plazo:** AlloyDB con conector nativo.

**Archivos a modificar:**
- `k8s/base/deployment-api.yaml` de cada servicio (eliminar sidecar cloud-sql-proxy)
- `k8s/overlays/dev/patches/cloud-sql-proxy.yaml` (reemplazar por PgBouncer)
- `terraform/modules/iam/` (SA del PgBouncer con `cloudsql.client`)
- `cloudbuild-dev.yaml` heredoc de cada repo
- Connection string: `Host=pgbouncer-svc;Port=5432`
