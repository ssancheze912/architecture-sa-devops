# Troubleshooting Conocido

> Este archivo contiene soluciones a problemas recurrentes. Se mantiene separado de CLAUDE.md para reducir el contexto cargado en cada conversación. Leer cuando se enfrente un problema específico.

## Claude Code — Sandbox y Flows

- **`gh api` con escritura a repos externos bloqueado por el sandbox:** El clasificador de intención (stage 2) de Claude Code bloquea `gh api` con métodos de escritura hacia repos de GitHub aunque `Bash(*)` esté en el allow list y `defaultMode: auto` esté activo. Aplica a cualquier operación que modifique repos externos (push de archivos, creación de PRs vía API, etc.). **Fix:** usar el prefijo `!` en el prompt de Claude Code para ejecutar el comando directamente en el shell del usuario, saltando el sandbox:
  ```
  ! gh api repos/SiesaTeams/{repo}/contents/.github/workflows/ci-pipeline.yml \
      --method PUT --field branch="develop" \
      --field content="$(base64 -i /tmp/archivo.yml)" --jq '.commit.sha'
  ```
  El prefijo `!` ejecuta en el shell del usuario sin pasar por el sandbox de Claude. **No es posible desactivar esta restricción** vía `permissions.allow` — opera en una capa superior al sistema de permisos. `/flow-nuevo-servicio` genera el archivo en `/tmp/ci-pipeline-{nombre}.yml` y muestra el comando `!` listo para copiar.

- **`gh repo clone` a repos externos bloqueado:** Mismo motivo que el punto anterior. El sandbox considera el clone como una operación de acceso a repo externo con potencial de modificación (checkout + eventual push). Fix: el usuario ejecuta el clone con `!` si necesita trabajar en un repo de servicio localmente.

## Infraestructura / Terraform

- **Terraform state vacío tras renombrar `environments/sandbox → environments/dev` (commit `58b28d6`):** El backend GCS cambió de `prefix = "terraform/environments/sandbox"` a `prefix = "terraform/environments/dev"`. El state en el prefix `sandbox` no existía previamente (nunca hubo un apply exitoso con ese prefix). La nueva ruta `dev` quedó vacía, Terraform intentó crear todos los recursos desde cero → 409 para GKE cluster, Cloud SQL, Pub/Sub topics, namespaces, etc. **Fix aplicado:** (1) Se intentó copiar state de `sandbox` a `dev` via `gsutil cp` (el step "Migrar prefix sandbox → dev" en el pipeline) pero no había state en sandbox. (2) Se agregaron `import` blocks en `main.tf` para todos los recursos existentes en GCP/K8s: `module.gke.google_container_cluster.autopilot`, `module.cloud_sql.google_sql_database_instance.postgres`, `module.cloud_sql.google_sql_user.postgres` (formato: `{project}/{instance}/{name}`), Pub/Sub topics (5), SA `base_config_runtime`, Certificate Manager completo (DNS Auth, Cert, Cert Map, Cert Map Entry), 6 namespaces K8s, Gateway K8s manifests, 7 subscriptions. En TF 1.7+, los import blocks son idempotentes: si el recurso ya está en state, el bloque se ignora en runs posteriores.
- **`moved` blocks incompatibles con `-target`:** Si el pipeline falla con "Moved resource instances excluded by targeting", es porque el paso de `terraform apply` usa `-target` y hay bloques `moved` en `main.tf`. Solución: reemplazar los `moved` blocks por `terraform state mv` en el paso "Terraform State — Migrate renamed resources" del pipeline, y eliminar los `moved` blocks de `main.tf`. Cada `state mv` debe llevar `2>/dev/null || true` para ser idempotente.
- **TF state tainted (cluster):** Si `terraform apply` falla a mitad y muestra "tainted, must be replaced", ejecutar `terraform untaint module.gke.google_container_cluster.autopilot` localmente — el cluster puede ya estar RUNNING aunque TF lo marque como tainted.
- **Master Authorized Networks bloqueando Terraform:** Si el `kubernetes provider` en Pass 2 recibe timeout, el cluster quedó con redes autorizadas habilitadas. Ejecutar `gcloud container clusters update <cluster> --region=us-east1 --no-enable-master-authorized-networks`.
- **A record del Gateway no creado:** El A record DNS se crea automáticamente si `gateway.external_ip` está definido en el project-config. Si no está (primer deploy), obtener IP con `kubectl get gateway <name> -n gateway-infra -o jsonpath='{.status.addresses[0].value}'`, agregarla y hacer push.
- **Gateway renombrado → DNS apunta a IP vieja → 404:** Si `project-config.dev.yaml` cambia `gateway.name` y el pipeline crea un nuevo Gateway (nombre nuevo, IP nueva), pero el DNS aún apunta a la IP del gateway viejo (que ya no tiene rutas), el sitio devuelve 404. Fix: (1) `gcloud dns record-sets update finance.siesacloud.dev. --type=A --ttl=300 --rrdatas=<nueva-IP> --zone=siesacloud-dev --project=<project>`; (2) actualizar `gateway.external_ip` en el config y agregar import block para `google_dns_record_set.domain_a_record[0]`.
- **Terraform resetea contraseña de SQL users con estado vacío:** Los `google_sql_user` que no tienen import block son creados por Terraform desde cero con `password = "change-me-use-secret-manager"`, sobreescribiendo la contraseña real → `28P01: password authentication failed`. El `lifecycle { ignore_changes = [password] }` solo previene cambios en UPDATES; en la creación inicial (recurso no está en state) sí aplica la contraseña del recurso. Fix: (1) `gcloud sql users set-password <user> --instance=<instance> --project=<project> --password=$(gcloud secrets versions access latest --secret=<secret> | python3 -c "import sys; ...")` para restaurar contraseña; (2) agregar import block para cada SQL user en `main.tf`. Afecta: `google_sql_user.base_config` y `google_sql_user.third_party` (commit `0c418f2`).
- **Los health checks del load balancer tardan ~1-2 min** en reflejarse tras un deploy.
- **Cloud Armor puede bloquear POSTs legítimos** si las reglas OWASP son muy agresivas — verificar con `gcloud compute security-policies rules describe`.

## IAM / Cloud Build

- **`PERMISSION_DENIED: cloudbuild.workerpools.use`:** El SA tiene `workerPoolOwner` pero le falta `workerPoolUser`. `workerPoolOwner` da CRUD sobre el recurso pero NO el permiso para enviar builds. Se necesitan **ambos roles**.
- **`forbidden from accessing bucket prj-..._cloudbuild` (CI/CD SA):** Al usar `gcloud builds submit`, el SA de CI/CD necesita `roles/storage.admin` en el proyecto destino — `roles/cloudbuild.builds.editor` NO incluye permisos GCS. Recurso Terraform: `google_project_iam_member.cicd_sa_storage_admin`.
- **`763982348967-compute does not have storage.objects.get` (Compute SA):** El worker pool privado descarga el fuente desde el bucket `{project}_cloudbuild` usando el Compute Engine default SA. Ese SA necesita `roles/storage.admin`. Sin esto, el build falla al hacer `FETCHSOURCE`. Recurso Terraform: `google_project_iam_member.compute_sa_storage_admin`.
- **`no matches for kind Configuration in version dapr.io/v1alpha1` (primer deploy QA/staging):** Dapr CRDs no están instalados. El infra-pipeline instala Dapr vía Helm en el job `k8s-manifests`, pero ese job se salta si no hay cambios K8s. Solución: `gh workflow run infra-pipeline-{ambiente}.yml --ref main` (fuerza `has_changes=true`).
- **`PERMISSION_DENIED: caller does not have permission to act as service account`:** El worker pool usa el Compute Engine default SA. El SA llamante necesita `roles/iam.serviceAccountUser` sobre ese SA.
- **Cloud Build no alcanza el cluster:** Verificar que la IP del worker pool esté en Master Authorized Networks.
- **Cloud Build `availableSecrets` con mismo versionName dos veces:** GCP rechaza el build. Si NPM y NuGet usan el mismo PAT de GitHub, declarar solo `NPM_TOKEN` y referenciar `$$NPM_TOKEN` en ambos steps.

## Kubernetes / Deploy

- **Kustomize: `file is not in or below overlay dir`:** Agregar `--load-restrictor LoadRestrictionsNone` al comando `kubectl kustomize`.
- **GKE Gateway HTTPRoute sin `sectionName: https`:** Sin este campo en `parentRefs`, la route puede no asociarse al listener HTTPS → 503. Siempre agregar `sectionName: https`.
- **GKE HealthCheckPolicy HTTP + Dapr sidecar:** Si el health check usa HTTP `/health` y el endpoint verifica el sidecar Dapr (no instalado en sandbox), el LB retorna 503. Cambiar a TCP (`type: TCP, tcpHealthCheck: { port: 8080 }`).
- **API nueva sin HealthCheckPolicy → 503 en Gateway:** Sin una `HealthCheckPolicy` para un Service, el GKE L7 LB usa HTTP en puerto 80 por defecto. Si la API corre en puerto 8080 (no 80), el health check falla → LB marca el NEG como unhealthy → 503. Siempre crear `healthcheck/<service>-api-hc.yaml` y `healthcheck/<service>-mfe-hc.yaml` con `type: TCP` al agregar un nuevo servicio. El MFE en nginx puerto 80 funciona sin policy, pero la API en puerto 8080 requiere policy explícita. Patrón: `healthcheck/third-party-api-hc.yaml` (TCP:8080) y `healthcheck/third-party-mfe-hc.yaml` (TCP:80).
- **`cloudbuild-dev.yaml` sobreescribe `kustomization.yaml` con heredoc:** El deploy step regenera `k8s/overlays/dev/kustomization.yaml` en runtime. Nuevos patches son silenciosamente ignorados si no se agregan también al heredoc. Mantener ambos sincronizados.
- **access-manager — health check `dapr-sidecar` falla con puerto 3510 (`Cannot assign requested address`):** `appsettings.Development.json` fija `Dapr.HttpPort: 3510` para evitar conflictos en dev local. En GKE daprd corre en `3500`. `DAPR_HTTP_PORT` env var NO sobrescribe `Dapr:HttpPort` en ASP.NET Core. Fix aplicado en `k8s/base/api/deployment.yaml`: agregar `Dapr__HttpPort: "3500"` y `Dapr__GrpcPort: "50001"`.
- **access-manager — Redis connection string:** El Redis compartido está en `dapr-redis.dapr-system.svc.cluster.local:6379`. En el overlay dev existía `redis-dev.access-manager.svc.cluster.local:6379` (incorrecto — ese servicio no existe). Verificar en `k8s/overlays/dev/patches/api-env.yaml`.
- **access-manager — Cloud SQL instance name:** La instancia se llama `pgsql-fin-sandbox-dev`, no `pgsql-fin-dev`. El env var `CLOUD_SQL_INSTANCE` en `api-env.yaml` debe ser `prj-sie-fin-financiero-dev:us-east1:pgsql-fin-sandbox-dev`.
- **access-manager — auth callback 401 `"property encrypted_hash should not exist"`:** El `IdentityServiceClient` envía `encrypted_hash` en el body de `POST /api/v1/auth/validate-token-secure` cuando `IdentityService:BypassEncryptedHash = false` (default). La identity API (`identity-api-dev.siesacloud.com`) fue actualizada y ya no acepta ese campo → devuelve `VALIDATION_ERROR` → access-manager responde 401 → el login queda en "Loading..." sin avanzar. Fix: agregar `IdentityService__BypassEncryptedHash: "true"` en `k8s/overlays/dev/patches/api-env.yaml`.
- **access-manager — HTTPRoute pisa el route del infra-pipeline:** `k8s/base/httproute.yaml` tiene `parentRefs.name: financiero-dev-gateway`. Si este valor es incorrecto (ej. `financiero-gateway`), cada deploy sobrescribe la route correcta del deploy repo → Gateway sirve app-shell HTML para todas las rutas incluyendo `/api/access-manager/*` → login/API devuelve `Not Found`. Fix: corregir el nombre en `httproute.yaml`. Re-aplicar inmediatamente: `kubectl apply -f routes/dev/access-manager-route.yaml` (tarda ~2 min en propagarse).

## Docker / Build

- **MSB3277 — `Found conflicts between different versions of` al compilar Tests.csproj:** NuGet resuelve versiones de forma independiente por proyecto. Si `Tests.csproj` tiene `Microsoft.AspNetCore.Mvc.Testing` o `Microsoft.EntityFrameworkCore.InMemory` fijados a una versión menor que la que resuelven los proyectos hermanos (ej. `10.0.5` fijo vs. `10.0.7` flotante en el resto), el compilador emite MSB3277 porque el ensamblado final mezcla versiones distintas del mismo paquete. El build no falla pero la advertencia indica una regresión potencial en tiempo de ejecución. **Fix:** usar versiones flotantes `10.*` en `Tests.csproj` para los paquetes que comparte con el proyecto principal:
  ```xml
  <PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" Version="10.*" />
  <PackageReference Include="Microsoft.EntityFrameworkCore.InMemory" Version="10.*" />
  <PackageReference Include="Microsoft.EntityFrameworkCore.Relational" Version="10.*" />
  ```
  **Estado (2026-04-22):** Aplicado en los 5 repos con tests: `business-financiero-base-config`, `business-financiero-segments-service`, `business-financiero-third-party-service`, `business-financiero-accounting-service`, `business-financiero-liquid-tax-service`. El repo `business-access-manager` no fue afectado (usa versiones distintas). **⚠️ Evitar referencias duplicadas:** `third-party` tenía `EFCore.InMemory` declarado dos veces en el mismo `.csproj` — causa MSB3277 incluso con versiones idénticas. Al agregar o modificar referencias en `Tests.csproj`, verificar que no haya duplicados con `grep PackageReference`.

- **`libgssapi_krb5.so.2: cannot open shared object file` en startup (CrashLoopBackOff):** `Dapr.AspNetCore <1.17` intenta cargar librerías GSSAPI/Kerberos nativas al inicializar gRPC. La imagen `mcr.microsoft.com/dotnet/aspnet:10.0` no las incluye. Fix primario: usar `Dapr.AspNetCore >=1.17.0` (alineado con runtime Dapr 1.17.1 del cluster). Defensa: agregar `libgssapi-krb5-2` al runtime stage del Dockerfile (`apt-get install -y --no-install-recommends libgssapi-krb5-2`). Importante: el paquete correcto es `libgssapi-krb5-2` (provee `libgssapi_krb5.so.2`), NO `libkrb5-3` (que provee `libkrb5.so.3`, diferente). Segmentos usa 1.17.0 y funciona; access-manager usaba 1.14.0 y crasheaba.
- **Docker `COPY` falla porque `nuget.config` no está en el contexto:** El contexto de build debe ser la raíz del repo (`.`), no `src/backend`. Usar `-f src/backend/Dockerfile .`.
- **nginx MFE: `host not found in upstream`:** nginx intenta resolver hostnames literales en startup. Fix: agregar `resolver 1.1.1.1 valid=10s ipv6=off;` y usar variable (`set $backend nombre-servicio; proxy_pass http://$backend:8080;`) para resolución dinámica.

## Cloud SQL — Backups y Recuperación

- **Configuración de backups:** Backup automático diario a las **04:00 UTC (11 PM COT)**. Retención: 7 copias. PITR habilitado con 7 días de WAL logs. Ventana de mantenimiento: **domingos 06:00 UTC (1 AM COT)**. Configurado en `terraform/modules/cloud-sql/main.tf`.

- **Verificar estado del último backup:**
  ```bash
  gcloud sql backups list --instance=pgsql-fin-sandbox-dev \
    --project=prj-sie-fin-financiero-dev --limit=5
  ```

- **Crear backup manual (emergencia o pre-mantenimiento):**
  ```bash
  gcloud sql backups create --instance=pgsql-fin-sandbox-dev \
    --project=prj-sie-fin-financiero-dev
  ```

- **Restaurar a punto en el tiempo (PITR):**
  ```bash
  # Restaurar a una instancia NUEVA (nunca sobreescribir la instancia activa en producción)
  gcloud sql instances restore-backup pgsql-fin-sandbox-dev-restored \
    --backup-instance=pgsql-fin-sandbox-dev \
    --backup-id=<BACKUP_ID> \
    --project=prj-sie-fin-financiero-dev

  # Para PITR a timestamp específico (dentro de los últimos 7 días):
  gcloud sql instances restore-to-time pgsql-fin-sandbox-dev-restored \
    --source-instance=pgsql-fin-sandbox-dev \
    --restore-to-time="2026-04-20T03:00:00Z" \
    --project=prj-sie-fin-financiero-dev
  ```
  > **CRÍTICO:** Siempre restaurar a una instancia nueva, nunca `--restore-in-place` en el ambiente activo sin aprobación explícita. La instancia restaurada no tiene el mismo connection name — actualizar secrets y connection strings.

- **Alertas de backup:** Cloud Monitoring envía email al canal configurado en `project-config.dev.yaml → monitoring.alert_email` cuando: (1) no hay backup exitoso en 26 horas, (2) disco supera el 80%. Módulo: `terraform/modules/monitoring/`.

- **Cambiar email de alertas:** Actualizar `monitoring.alert_email` en `project-config.dev.yaml` y hacer `terraform apply`. Para notificar a múltiples personas usar una lista de distribución.

## Cloud SQL — Connection Pool Exhaustion

> **Síntoma:** Servicios reportan `53300: sorry, too many clients already` / `connection pool is full` en logs. Pods en CrashLoopBackOff o errores 500 intermitentes.

- **Causa raíz de dev:** La instancia `pgsql-fin-sandbox-dev` es `db-f1-micro` (0.6 GB RAM → **`max_connections = 25`** por PostgreSQL). Con 6+ servicios activos (access-manager, segments, base-config, third-party, accounting, liquid-tax) y Npgsql con pool default de 100 por string, el límite se alcanza fácilmente — especialmente con OutboxProcessors (BackgroundService) que abren conexiones adicionales.

- **Diagnóstico:**
  ```bash
  # 1. Tunnel local (port 5432 via Cloud SQL Auth Proxy):
  ./scripts/dev-connect.sh

  # 2. Conexiones por usuario/servicio:
  psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev \
    -c "SELECT usename, count(*) FROM pg_stat_activity GROUP BY usename ORDER BY count DESC;"

  # 3. Pool completo con estado:
  psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev \
    -c "SELECT usename, application_name, state, wait_event_type, count(*) \
        FROM pg_stat_activity GROUP BY 1,2,3,4 ORDER BY count DESC LIMIT 25;"

  # 4. max_connections actual:
  psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev \
    -c "SELECT current_setting('max_connections'), count(*) AS activas \
        FROM pg_stat_activity;"
  ```

- **Fix inmediato — Limitar pool en connection strings (sin downtime):**
  Agregar `Maximum Pool Size=3` en cada secret de Secret Manager Y actualizar el K8s secret directamente (el CI/CD lo hace en cada deploy, pero para aplicarlo sin pipeline usar `kubectl patch`).
  **Estado actual (2026-04-22):** `Maximum Pool Size=3` aplicado en los 6 secrets. Con `db-g1-small` (~50 max_connections): 6 servicios × 3 = 18 conexiones de app + ~23 del Auth Proxy = ~41 en uso bajo carga. Margen suficiente para `postgres` y herramientas de dev.
  ```bash
  # Paso 1 — Actualizar Secret Manager:
  current=$(gcloud secrets versions access latest --secret=<secret> --project=prj-sie-fin-financiero-dev)
  echo -n "${current};Maximum Pool Size=3" | gcloud secrets versions add <secret> --project=prj-sie-fin-financiero-dev --data-file=-

  # Paso 2 — Actualizar K8s secret directamente (sin esperar CI/CD):
  conn=$(gcloud secrets versions access latest --secret=<secret> --project=prj-sie-fin-financiero-dev)
  encoded=$(echo -n "$conn" | base64 | tr -d '\n')
  kubectl patch secret <ns>-config -n <ns> \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/data/ConnectionStrings__DefaultConnection\",\"value\":\"${encoded}\"}]"

  # Paso 3 — Rollout restart para tomar el nuevo K8s secret:
  kubectl rollout restart deployment/<ns>-api -n <ns>
  ```
  **⚠️ `kubectl rollout restart` NO re-lee Secret Manager** — solo reinicia el pod con el K8s secret que ya existe. Siempre actualizar el K8s secret con `kubectl patch` antes del restart, o esperar el próximo CI/CD deploy.

- **Cloud SQL Auth Proxy tiene su propio pool independiente de Npgsql:** El Auth Proxy sidecar (dentro del pod) pre-calienta ~23 conexiones al arrancar, visibles en `pg_stat_activity` con `client_addr = NULL` y `application_name = ''`. Estas conexiones existen aunque Npgsql tenga `Maximum Pool Size=3`. Son conexiones del Proxy hacia Cloud SQL, no de la app. Para limitarlas, configurar `--max-connections` en el sidecar del Auth Proxy (no implementado en dev actualmente). Tener en cuenta al calcular el total de conexiones por pod.

- **Fix estructural A — Upgrade tier (recomendado):**
  En `project-config.dev.yaml` cambiar `tier: db-f1-micro` → `tier: db-g1-small` (max_connections ≈ 50, 1.7 GB RAM).
  También actualizar `cloudsql_max_connections` en el call al módulo monitoring en `environments/dev/main.tf`.
  **Requiere restart de la instancia (~2 min downtime).** CI/CD aplica el cambio en el siguiente push a `main`.

- **Fix estructural B — Flag max_connections vía Terraform:**
  En `terraform/modules/cloud-sql/main.tf` agregar bajo `settings { database_flags { } }`:
  ```hcl
  database_flags {
    name  = "max_connections"
    value = "50"
  }
  ```
  También requiere restart de instancia.

- **Monitoreo activo:** Cloud Monitoring envía email cuando los backends activos superan el 80% de `max_connections` (umbral configurable via variable `cloudsql_max_connections` en el módulo `terraform/modules/monitoring/`). Métrica: `cloudsql.googleapis.com/database/postgresql/num_backends` (oficial GCP para PostgreSQL — disponible desde el primer arranque, a diferencia de `num_connections` que falla con 404 si la instancia acaba de reiniciar).

## Cloud SQL / Base de Datos

- **Arquitectura BD:** Una sola instancia `pgsql-fin-sandbox-dev`, una sola base de datos `finance-dev`. Cada servicio tiene su propio **schema** y su propio **usuario Cloud SQL dedicado** (no usar `postgres`). Secrets de conexión: `{short-name}-sandbox-db-connection`. Tabla resumen:
  | Servicio | Schema | Owner (usuario Cloud SQL) | Secret |
  |---|---|---|---|
  | access-manager | `access_manager` | `accmgr` | `accmgr-sandbox-db-connection` |
  | segments | `segment` | `segments` | `segments-sandbox-db-connection` |
  | base-config | `base_config` | `base_config` | `baseconfig-sandbox-db-connection` |
  | third-party | `tprt` | `third_party` | `tprt-dev-db-connection` |
  | accounting | `acct` | `accounting` | `acct-dev-db-connection` |
  | liquid-tax | `liquid_tax` | `liquid_tax` | `liquid-tax-dev-db-connection` |
  > **Schema `TAXS` (mayúsculas):** existe en la BD, owner `liquid_tax`. Probablemente creado antes de adoptar la convención snake_case. No está referenciado en las migraciones actuales de EF Core. No eliminar sin confirmar que no hay objetos en uso.
- **Cloud SQL QA no alcanzable — TCP timeout desde pods GKE Autopilot (`System.TimeoutException`):** GKE Autopilot QA usa pod CIDR no-RFC-1918 (`100.82.0.0/18`). GKE Warden bloquea modificaciones a kube-system (`managed-namespaces-limitation`) → ip-masq-agent ConfigMap no puede patchiarse → pods envían su IP source (`100.82.x.x`) a Cloud SQL PSA (`192.168.160.20`) → servicenetworking VPC no puede rutear replies de vuelta. **Solución definitiva: PSC.** PSC hace SNAT propio en el forwarding rule → el pod destino pasa por el forwarding rule IP (`10.20.39.250`) → PSC NAT oculta la IP del pod → Cloud SQL ve una IP de PSC → reply vuelve por la infra PSC → VPC tiene rutas al pod CIDR (GKE las crea). Recursos Terraform: módulo cloud-sql con `psc_enabled=true`, `psc_allowed_consumer_projects=["238886086835","763982348967"]` + `google_compute_address.cloud_sql_psc` (IP `10.20.39.250`, subnet `snt-sie-bus-fin-use1-qa`) + `google_compute_forwarding_rule.cloud_sql_psc` (en `prj-sie-com-vpc-host-qa`). Connection strings: `Host=10.20.39.250` (en lugar de `Host=192.168.160.20`). **Prerequisito IAM** (aplicado 2026-05-19): `roles/compute.networkAdmin` en `prj-sie-com-vpc-host-qa` para `sa-sie-fin-qa-cicd@prj-sie-sb-fin-common.iam.gserviceaccount.com`. **No afecta DEV** (usa `ipv4_enabled=true` + Auth Proxy).
- **Cloud SQL no alcanzable desde pods GKE Autopilot (PSA peering) — DEV:** El ip-masq-agent incluye `192.168.0.0/16` en `nonMasqueradeCIDRs`, impidiendo SNAT hacia la IP privada PSA. **Solución adoptada:** `ipv4_enabled = true` + Cloud SQL Auth Proxy sidecar. El proxy escucha en `127.0.0.1:5432` y conecta via IP pública. Setup: (1) anotar K8s SA con `iam.gke.io/gcp-service-account`, (2) WIF binding `roles/iam.workloadIdentityUser`, (3) `roles/cloudsql.client`, (4) connection string con `Host=127.0.0.1`, (5) sidecar `gcr.io/cloud-sql-connectors/cloud-sql-proxy:2`.
- **`accmgr-sandbox-db-connection` debe usar `Host=127.0.0.1` y `Database=finance-dev`:** Schema de access-manager: `access_manager`. Si se recrea el secret, usar `Host=127.0.0.1;Port=5432;Database=finance-dev`.
- **`access-manager-config` K8s secret reconstruido en cada deploy:** El CI reconstruye el secret leyendo de Secret Manager. Si se parchea con `kubectl`, el siguiente deploy lo sobreescribirá. Siempre actualizar Secret Manager primero con `gcloud secrets versions add <secret> --data-file=-`.
- **`segments-sandbox-db-connection` reescrito a `Host=127.0.0.1`:** El CI hace `sed 's/Host=[^;]*/Host=127.0.0.1/'` antes de crear el K8s secret `segments-config`. Secret Manager conserva la IP original. BD: `finance-dev`; schema: `segment` (singular).
- **Usuario `dev` sin permisos DDL en un schema:** Al agregar un servicio nuevo, hay que otorgar permisos completos al usuario `dev` en el schema del servicio para que los devs puedan ejecutar migraciones (`dotnet ef database update`) y operar datos localmente. Síntoma: `ERROR: permission denied for schema {schema}` o `ERROR: permission denied for table` al conectar con `dev-sandbox-db-connection`. Fix (una vez por schema, conectando como el owner del schema):
  ```sql
  GRANT ALL PRIVILEGES ON SCHEMA {schema} TO dev;          -- USAGE + CREATE (DDL)
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA {schema} TO dev;
  GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {schema} TO dev;
  ALTER DEFAULT PRIVILEGES IN SCHEMA {schema} GRANT ALL PRIVILEGES ON TABLES TO dev;
  ALTER DEFAULT PRIVILEGES IN SCHEMA {schema} GRANT ALL PRIVILEGES ON SEQUENCES TO dev;
  ```
  Para poder crear schemas nuevos también se requiere `GRANT CREATE ON DATABASE "finance-dev" TO dev;` (ejecutar como `postgres`, solo una vez). Ver `docs/bootstrap-guide.md § SVC.5.1`.
  **Estado actual (2026-04-21):** GRANTs ya aplicados en todos los schemas (`segment`, `base_config`, `access_manager`, `tprt`, `acct`, `liquid_tax`). El secret `tprt-dev-db-connection` tenía `CHANGE_ME_PLACEHOLDER` — fue corregido con contraseña real (versión 2 del secret).

- **`42501: must be owner of table {tabla}` al ejecutar migraciones EF Core con usuario `dev`:** `GRANT ALL ON TABLES` otorga privilegios DML (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`) pero **NO transfiere la propiedad** (`ALTER TABLE`, `DROP TABLE`, `CREATE INDEX`, etc. en tablas existentes requieren ser owner). Las tablas son propiedad del usuario de servicio (ej. `base_config`, `segments`), no de `dev`. Error exacto: `Npgsql.PostgresException '42501: must be owner of table states_overrides'`.

  **Diagnóstico:** El error ocurre cuando EF Core intenta `ALTER TABLE`, `DROP COLUMN`, `CREATE UNIQUE INDEX ON`, `RENAME COLUMN` u otras operaciones DDL sobre tablas ya existentes en el schema. PostgreSQL valida ownership, no solo GRANT.

  **Fix — dos pasos, dos usuarios distintos:**

  **Paso 1 — como `postgres` (GRANTs de membresía de rol):**
  ```bash
  source ./scripts/dev-connect.sh
  psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev
  ```
  ```sql
  GRANT accmgr TO dev; GRANT segments TO dev; GRANT base_config TO dev; GRANT third_party TO dev; GRANT accounting TO dev; GRANT liquid_tax TO dev;
  ```

  **Paso 2 — como `dev` (ALTER DEFAULT PRIVILEGES para objetos futuros):**
  `ALTER DEFAULT PRIVILEGES FOR ROLE dev` falla con `postgres` en Cloud SQL — `postgres` es `cloudsqlsuperuser`, no superuser real, y no puede modificar defaults de otro rol. Conectar como `dev` y ejecutar SIN `FOR ROLE`:
  ```bash
  PGPASSWORD='...' psql -h 127.0.0.1 -p 5432 -U dev -d finance-dev
  ```
  ```sql
  ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON TABLES TO accmgr; ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON SEQUENCES TO accmgr; ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON TABLES TO segments; ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON SEQUENCES TO segments; ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON TABLES TO base_config; ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON SEQUENCES TO base_config; ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON TABLES TO third_party; ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON SEQUENCES TO third_party; ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON TABLES TO accounting; ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON SEQUENCES TO accounting; ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON TABLES TO liquid_tax; ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON SEQUENCES TO liquid_tax; ALTER DEFAULT PRIVILEGES IN SCHEMA "TAXS" GRANT ALL ON TABLES TO liquid_tax; ALTER DEFAULT PRIVILEGES IN SCHEMA "TAXS" GRANT ALL ON SEQUENCES TO liquid_tax;
  ```
  **⚠️ Ejecutar via `psql` directo, NO desde DBeaver u otros clientes SQL** — algunos clientes fallan con `3F000: schema "liquid_tax" does not exist` aunque el schema exista y el usuario tenga privilegios.

  **Por qué funciona:** `GRANT {role} TO dev` convierte a `dev` en miembro del rol propietario. PostgreSQL verifica ownership con `pg_has_role(current_user, owner_role, 'MEMBER')`. Permite `ALTER TABLE` sin `SET ROLE` explícito ni cambios en la connection string.

  **Estado actual (2026-04-22):** Aplicado. GRANTs de membresía ejecutados como `postgres`; ALTER DEFAULT PRIVILEGES ejecutados como `dev` via psql en todos los schemas incluyendo `TAXS` (schema legacy de liquid-tax).
- **`tprt-dev-db-connection` con contraseña placeholder:** Si el secret tiene `CHANGE_ME_PLACEHOLDER`, el servicio third-party no puede conectarse a Cloud SQL ni el usuario `dev` puede hacer GRANTs sobre el schema `tprt`. Resetear la contraseña del usuario `third_party` via `gcloud sql users set-password` y actualizar el secret con `gcloud secrets versions add`. Ver `docs/bootstrap-guide.md § SVC.5.1` para los GRANTs posteriores.
- **Inspección de mensajes Pub/Sub:** `gcloud pubsub subscriptions pull <subscription> --project=prj-sie-fin-financiero-dev --limit=10 --format=json`. GoPubSub descartado — no funciona como servicio K8s persistente.
- **Proyecciones Company/UserCompanyAssignment no aparecen en base-config:** 3 bugs combinados: (1) `CompanyService` y `CompanyUserAssignmentService` publicaban eventos RAW sin `DomainEventEnvelope` — base-config siempre esperó envelope; (2) los campos del evento tenían nombres distintos (`Id`→`EntityId`, `CreatedAt`→`Timestamp`) y faltaban 11 campos en `CompanyCreatedEvent`; además `UserCompanyAssignmentChangedEvent` no incluía el campo `ID` (PK de la asignación); (3) `DomainEventEnvelope<T>.Data` en base-config no tenía `[JsonPropertyName("payload")]` para coincidir con `Payload` del lado segments. Fix: ambos repos corregidos — `CompanyEvents.cs` + `CompanyService.cs` + `CompanyUserAssignmentService.cs` en segments; `DomainEventEnvelope.cs` en base-config.

## Dapr

- **Dapr instalado por el pipeline:** `infra-pipeline-dev.yml` instala/actualiza Dapr via Helm (`helm upgrade --install dapr dapr/dapr --version 1.17.1`). Anotaciones mínimas para inyección del sidecar: `dapr.io/enabled`, `dapr.io/app-id`, `dapr.io/app-port`, `dapr.io/app-protocol`. Servicios activos: `access-manager` (app-id: `accessmanager`), `segments` (app-id: `segments`), `base-config` (app-id: `base-config`). `app-shell` no usa Dapr.
- **Pub/Sub IAM para Dapr:** SAs de servicios necesitan `roles/pubsub.publisher` + `roles/pubsub.subscriber`. Se declaran en `project-config.shared.yaml` bajo `services.{name}.roles`.
- **Pub/Sub topics deben pre-existir (`disableEntityManagement: true`):** Dapr no crea topics/subscriptions automáticamente. Crearlos con `google_pubsub_topic` + `google_pubsub_subscription` en `terraform/environments/dev/main.tf`.
- **GKE Gateway HealthCheckPolicy — backend UNHEALTHY con puerto no-estándar (Shared VPC):** La regla de firewall `allow-glbc-health-checks` en el proyecto VPC host `prj-sie-com-vpc-host-dev` controla qué puertos pueden recibir probes de los health checkers de GCP (`35.191.0.0/16`, `130.211.0.0/22`). Puertos actualmente permitidos: `80, 443, 3000, 8080, 16686`. Si se expone un nuevo servicio en un puerto diferente y el backend queda UNHEALTHY aunque el pod esté sano, agregar el puerto con: `gcloud compute firewall-rules update allow-glbc-health-checks --project=prj-sie-com-vpc-host-dev --allow=tcp:80,tcp:443,tcp:3000,tcp:8080,tcp:16686,tcp:<NUEVO_PUERTO>`. **Requiere acceso de admin al proyecto VPC host** — el SA del CI/CD (`sa-sie-fin-sandbox-dev-cicd`) no tiene permisos de firewall en ese proyecto. Propagación: ~2 min tras actualizar la regla.
- **Dapr service invocation cross-namespace — `failed to resolve address for '{app-id}-dapr.{namespace}.svc.cluster.local'`:** Dapr resuelve el destino buscando `{app-id}-dapr.{namespace-del-caller}.svc.cluster.local`. Para llamadas entre namespaces distintos se requiere el formato `{app-id}.{namespace-destino}` en el InvokeMethodAsync. Ej desde `base-config` → `segments`: usar `"segments.segments"` (NO `"segments"`). Mapa actual: `segments.segments`, `accessmanager.access-manager`.
- **`StartsWithSegments("/reconcile")` no excluye `/reconcile-companies`:** `PathString.StartsWithSegments` compara segmentos delimitados por `/`. El path `/reconcile-companies` es un solo segmento y NO matchea `/reconcile`. Usar `ctx.Request.Path.Value.StartsWith("/reconcile", StringComparison.OrdinalIgnoreCase)` para exclusiones de prefijo. **Afecta a `UseWhen` en base-config**.
- **Dapr retry loop en pub/sub — evento con campo requerido nulo:** Dapr 1.17 trata respuestas HTTP 400 como retriable en pub/sub → loop infinito con el mismo message-id. Fix: si el evento está malformado, retornar `Results.Ok()` (ACK) con `LogWarning` para descartar y detener el retry.
- **`fail: duplicate priorities for 0` al arrancar con Dapr local — múltiples handlers mismo topic:** Dapr 1.16.8+ valida que todos los `TopicOptions` con `Match` en el mismo topic tengan valores `Priority` únicos. Si N handlers tienen `Priority = 0`, el runtime falla en startup con `DaprTopicSubscription: A subscription to topic X on pubsub Y has duplicate priorities for 0: found N occurrences`. Fix: asignar `Priority = 1, 2, 3, ...` a cada handler. El catch-all (sin `Match`) NO debe tener `Priority`. Convención base-config: Company 1/2/3, UserCompanyAssignment 4, OperationCenter 5/6/7.
- **`ERRO: Failed to connect to placement localhost:50005` en desarrollo local:** El servicio de placement de Dapr (actor coordinator) corre como contenedor Docker inicializado por `dapr init`. Si Docker no está activo, el proceso de placement no está disponible. Como ningún servicio de la plataforma usa actores Dapr, se deshabilitó la conexión a placement en todos los tasks.json: `"--placement-host-address", ""`. Esto silencia los ERRO de reconexión que spameaban el terminal cada segundo. El warning de Zipkin (`http://localhost:9411`) es inofensivo por el mismo motivo.
- **Jaeger — tracing distribuido:**
  - Namespace `observability`, `observability/jaeger/`. Imagen `jaegertracing/all-in-one:1.57`. In-memory (dev) — trazas se pierden al reiniciar.
  - Ingesta Zipkin en `svc/jaeger:9411`. Dapr envía a `http://jaeger.observability.svc.cluster.local:9411/api/v2/spans`.
  - Config: `dapr/tracing-config.yaml`, `samplingRate: "1"` (100%). Aplicada en `access-manager` y `segments`.
  - Activar en servicio: anotación `dapr.io/config: "tracing-config"` en pod template + agregar patch al heredoc de `cloudbuild-dev.yaml`.
  - Acceso local: `kubectl port-forward svc/jaeger 16686:16686 -n observability` o via `./scripts/dev-connect.sh`.
  - Verificar sampler: `kubectl logs <pod> -c daprd -n <ns> | grep -i sampl` → debe mostrar `AlwaysOnSampler`.

## Redis

- **Migración Redis Deployment → StatefulSet:** El pipeline incluye `kubectl delete deployment dapr-redis -n dapr-system --ignore-not-found=true` (idempotente). El PVC `redis-data-dapr-redis-0` persiste en reinicios. Para eliminarlo: `kubectl delete pvc redis-data-dapr-redis-0 -n dapr-system`.
- **Redis CrashLoopBackOff: `Permission denied appendonlydir`:** `redis:8-alpine` corre como UID 999. En GKE Autopilot el PVC monta con ownership root. Fix: `securityContext: { fsGroup: 999, runAsUser: 999, runAsGroup: 999 }` en `spec.template.spec` del StatefulSet.

## EF Core Migrations

- **access-manager:** `MigrateAsync()` en startup, todos los ambientes. Schema: `access_manager`. Seed data manual. Usuario semilla sandbox: `diego.santacruz@siesa.com` (id: `22222222-2222-2222-2222-222222222222`), `identity_id=NULL` (se vincula en primer login).
- **`column "migration_id" does not exist` en startup (access-manager):** `UseSnakeCaseNamingConvention()` hace que Npgsql EF Core query `migration_id` y `product_version` en `access_manager."__EFMigrationsHistory"`, pero la tabla existente tenía columnas PascalCase (`MigrationId`, `ProductVersion`). Fix: `ALTER TABLE access_manager."__EFMigrationsHistory" RENAME COLUMN "MigrationId" TO migration_id; ALTER TABLE access_manager."__EFMigrationsHistory" RENAME COLUMN "ProductVersion" TO product_version;`. Ejecutar como user `accmgr` (owner de la tabla) via Cloud SQL Auth Proxy.
- **segments-service:** `MigrateAsync()` en startup. Schema: `segment` (singular). Historial: `segment.__EFMigrationsHistory`. UN SOLO directorio: `SegmentsService.Infrastructure/Data/Migrations/`. Estado 2026-03-26: schema creado desde cero con `20260326183602_InitialCreate`. Sin seed data.
- **Schema `base-config` (con guión) creado en DB — base-config:** `ExchangeRateConfiguration.cs` usaba `builder.ToTable("exchange_rates", "base-config")` desde su creación (`cebea02`). El commit `37c69eb` corrigió todas las migraciones a `base_config` pero NO actualizó el archivo de configuración. EF Core detecta la discrepancia modelo↔snapshot y puede generar migraciones espurias que vuelven a crear el schema `base-config`. Síntoma visible: en producción existen dos schemas `base-config` y `base_config` con las mismas tablas. Fix: cambiar a `builder.ToTable("exchange_rates", "base_config")` en `ExchangeRateConfiguration.cs` — corregido en commit `1f41b29`. Para eliminar el schema huérfano: conectar como `base_config` user via Auth Proxy y ejecutar `DROP SCHEMA "base-config" CASCADE;`. **Regla:** cualquier `IEntityTypeConfiguration` con `ToTable(tabla, esquema)` explícito debe usar `"base_config"` (snake_case) — nunca `"base-config"`.

- **`UpdateData` falla con `There is no entity type mapped to the table` en migración:** EF Core `UpdateData()` y `DeleteData()` requieren que el entity type esté registrado en el DbContext actual para inferir los tipos de columna. Si se llama `UpdateData(table: "base_config.document_class_groups", ...)` pero `document_class_groups` no está en el modelo, la migración lanza `System.InvalidOperationException: There is no entity type mapped to the table` al ejecutarse en startup. **Fix:** reemplazar con `migrationBuilder.Sql(@"UPDATE base_config.document_class_groups SET name = '...' WHERE id = '...'")`. Ocurrió en `base-config` migración `20260331152329_FixDocumentClassAndGroupSeedSpelling` — corregido en commit `14ba133`.

- **`CS0115: BuildTargetModel cannot override` — archivo `.Designer.cs` huérfano:** Si existe un `*.Designer.cs` (genera EF Core `dotnet ef migrations add`) pero se eliminó el `.cs` de la migración correspondiente, la `partial class` hereda de `Migration` pero sin override válido. El compilador falla con CS0115. **Fix:** `git rm` del `.Designer.cs` huérfano. Ocurrió en segments con `20260319144603_AddSegmentMasterProjectionTables.Designer.cs`.

- **Doble directorio de migraciones en segments (bug histórico):** Si el repo vuelve a tener `SegmentsService.Infrastructure/Migrations/` Y `SegmentsService.Infrastructure/Data/Migrations/` con el mismo `[DbContext]`, EF Core descubrirá ambos intercalados por timestamp → duplicados → pod crashea con 42703 o 42P07. **Solución:** un solo directorio. Para resetear DB: `cloud-sql-proxy prj-sie-fin-financiero-dev:us-east1:pgsql-fin-sandbox-dev --port=9470` + psql + `DROP SCHEMA IF EXISTS segment CASCADE; CREATE SCHEMA segment;` → push para que CI corra `MigrateAsync()` sobre schema limpio.

## MFE (aplica a todos los servicios con frontend)

- **`process is not defined` — MFE en estado LOADING_SOURCE_CODE o crash inmediato:** Vite no reemplaza `process.env.NODE_ENV` en builds de librería (`formats: ['es']`). Fix definitivo: agregar en `vite.config.ts`:
  ```ts
  define: { 'process.env.NODE_ENV': JSON.stringify(mode) }
  ```
  Y pasar `--mode $VITE_MODE` en el Dockerfile. `mode` viene del flag `--mode` del build de Vite, que se inyecta via `ARG VITE_MODE=production`.

- **MFE no carga / assets 404:** Verificar que `base` en `vite.config.ts` coincida con la ruta donde nginx sirve los assets. Debe ser `'/mfe/{service-name}/'`. Si falta, los assets se generan con rutas `/assets/...` en lugar de `/mfe/{service-name}/assets/...` y el browser no los encuentra.

- **MFE no usa `vite-plugin-single-spa`:** Todos los MFEs DEBEN usar `vite-plugin-single-spa` con `type: 'mife'`. Sin este plugin el entry point no se genera correctamente para single-spa. Verificar `spaEntryPoints: 'src/spa-entry.tsx'`. Versión actual compatible: `^1.1.0` (la última disponible — no existe v5+).

- **`BUILD_MODE` vs `VITE_MODE` en Dockerfile:** Si el Dockerfile declara `ARG BUILD_MODE=standalone` pero el cloudbuild pasa `--build-arg VITE_MODE=development`, Docker ignora el arg y construye en modo standalone (SPA con chunks hasheados, sin `spa-entry.js`). Solución: reemplazar `ARG BUILD_MODE` por `ARG VITE_MODE=production` y agregar `--mode $VITE_MODE` al comando `vite build`. Ocurrió en `base-config` — corregido en commit `c473d0e`.

- **`Cannot read properties of undefined (reading 'length')` — crash en MFE (errorBoundary):** `MasterCrud` intenta leer `.length` en la respuesta de la API, pero recibe `undefined` porque la llamada falla. Causa habitual: `baseURL: '/api/v1'` en `shared/http/apiClient.ts` — no hay HTTPRoute para `/api/v1` en el Gateway, la petición cae al catch-all del app-shell y devuelve HTML (no JSON). Fix: cambiar `baseURL` a `'/api/base-config'` (el Gateway sí tiene esa ruta y la reescribe a `/api/v1` en el backend). Además, agregar `Authorization: Bearer` desde `localStorage['access_manager_user_token']` en los interceptores de `apiClient`, `apiClientDirect` y `lookupFetcher`. Mismo patrón que segments. Ocurrió en `base-config` — corregido en commit `a454092`. **⚠️ Regresión conocida:** el commit `e3afc31` revirtió este fix sin darse cuenta (cambió `baseURL` de vuelta a `/api/v1` en un refactor de servicios geográficos). Al hacer refactors que toquen `apiClient.ts`, verificar siempre que `baseURL` sea `'/api/base-config'` y NO `'/api/v1'`. Re-corregido en commit `fcb1316`.

- **`usePermission must be used within a PermissionProvider` — crash al montar MFE:** El `spa-entry.ts` usaba `App` como `rootComponent` pero `App.tsx` no tenía `PermissionProvider`. En producción, el shell guarda el token en `localStorage` bajo `access_manager_permissions_token`. El entry point de producción (`spa-entry.tsx`) debe seguir este patrón (igual que segments): crear un `MfeRoot` con `PermissionProvider` leyendo ese key, más `ThemeProvider`, `QueryClientProvider` y `BrowserRouter basename="/app"`. `App.tsx` es solo para dev standalone. Ocurrió en `base-config` — corregido en commit `f043425`.

- **`No routes matched location "/app/countries"` — warnings de React Router en MFE:** `BrowserRouter` sin `basename` hace que el router vea la URL completa (`/app/countries`) pero las rutas estén definidas como `/countries`. Fix: `<BrowserRouter basename="/app">` en `spa-entry.tsx`. Los keys en `mfe-registry.ts` del app-shell deben coincidir exactamente con los paths del MFE. URLs siempre en inglés. Ocurrió en `base-config` — corregido en commits `bf47e49` (MFE) y `747fd0c` (app-shell).

- **`'text/html' is not a valid JavaScript MIME type` — MFE muere en LOADING_SOURCE_CODE:** El import-map apunta a un archivo JS que no existe (ej. `siesa-base-config.js`). nginx sirve `index.html` como fallback SPA, single-spa lo recibe con MIME `text/html` y el MFE muere. Fix: verificar que `import-map/import-map.yaml` apunte a `spa-entry.js` (el archivo que genera `vite-plugin-single-spa`). Ocurrió en `@siesa/base-config` — corregido en commit `89dbb60`.

- **API calls retornan HTML del app-shell:** El app-shell tiene una HTTPRoute catch-all (`/`). Cualquier path no cubierto por otras rutas más específicas llega al app-shell. Causas habituales:
  1. `createFetcher('/api/v1')` — usa `/api/v1/...` que no está en el Gateway → catch-all.
  2. `axios.get('/api/v1/...')` hardcodeado — mismo problema.
  3. `fetch('/api/v1/...')` hardcodeado — mismo problema.
  **Fix:** Usar siempre `/api/{prefijo}/...` donde el prefijo tiene HTTPRoute definida. Ejemplos:
  ```ts
  // Correcto
  createFetcher('/api')  →  entity: 'segments/companies'  →  POST /api/segments/companies/search ✓
  createFetcher('/api')  →  entity: 'base/currencies'     →  POST /api/base/currencies/search ✓
  apiClient.get('/segments/companies')                    →  GET /api/segments/companies ✓

  // Incorrecto — retorna HTML
  createFetcher('/api/v1')
  axios.get('/api/v1/segments/companies')
  fetch('/api/v1/segments/companies/123/contacts')
  ```

- **`createFetcher` con entity sin prefijo de servicio:** Si `createFetcher('/api')` y `entity='countries'`, llama a `POST /api/countries/search` — no existe HTTPRoute → catch-all → HTML. La entity debe incluir el prefijo del servicio: `entity='base/countries'`.

- **`VITE_API_BASE_URL` no inyectado en build Docker:** Si el build no recibe `--build-arg VITE_API_BASE_URL=/api`, el fallback en `client.ts` es `/api/v1` → todas las llamadas via `apiClient` fallan. Verificar que el pipeline pase el argumento y que el Dockerfile lo declare como `ARG`.

- **`VITE_API_BASE_URL=/api/segments` incorrecto:** Los `BASE` paths de los services ya incluyen `segments/` (ej. `companies`), por lo que `/api/segments` + `companies` → `/api/segments/companies` ✓. Pero con `/api/segments` + entidades `base/...` → `/api/segments/base/currencies` ✗ (no ruteable). Usar siempre `VITE_API_BASE_URL=/api`.

## Access Manager — Pub/Sub Self-Subscription (fix 2026-04-07)

- **Síntoma:** Dapr sidecar reportaba `Resource not found (resource=accessmanager-access-manager-events)` al arrancar, agotando 30 intentos de reconexión. Access Manager usa Redis para invalidar caché de permisos entre réplicas — si la suscripción falla, los cambios de permisos no se propagan entre pods.

- **Causa raíz:** El `SubscriptionController.GetSubscriptions()` declaraba suscripciones a `permission-events` y `reconciliation-events` (topics de una arquitectura anterior a la regla "un topic por servicio"). GCP tenía 3 topics/suscripciones huérfanos no gestionados por Terraform. La suscripción `accessmanager-access-manager-events` (self-subscription correcta) nunca fue creada.

- **Fix aplicado (commits `fb56cb3` en AM, `db5cdc6` en deploy):**
  1. `SubscriptionController.GetSubscriptions()` → retorna SOLO `access-manager-events`
  2. `HandleAccessManagerEvent` despacha por `eventType`: `UserPermissionsChanged`, `RolePermissionsChanged`, `UserChangedEvent`, `UsersReconciliationEvent`
  3. GCP: eliminados topics `permission-events`, `reconciliation-events`, `accessmanager-events` y sus suscripciones
  4. GCP: creada suscripción `accessmanager-access-manager-events` → topic `access-manager-events`
  5. Terraform: `access_manager_self_events` + IAM `pubsub.subscriber` para el SA + import block

- **Verificación post-fix:** `kubectl logs -c daprd -n access-manager <pod>` debe mostrar `app is subscribed to the following topics: [[access-manager-events]]` sin errores `NotFound`.

## Access Manager — Snapshot expuesto en Gateway externo (hallazgo 2026-04-07)

- **Hallazgo:** `GET https://finance.siesacloud.dev/api/access-manager/users/snapshot` retorna HTTP 200 con lista completa de usuarios sin autenticación. El HTTPRoute mapea `/api/access-manager/*` → `/api/v1/*`, exponiendo inadvertidamente el endpoint snapshot que debería ser solo accesible internamente vía Dapr mTLS.

- **Impacto:** El endpoint expone `id, name, code, email, description, identityID, isActive` de todos los usuarios sin ninguna protección.

- **Fix pendiente:** Agregar una regla de precedencia en `routes/dev/access-manager-route.yaml` para el path `/api/access-manager/users/snapshot` que retorne 404, o agregar validación de header Dapr en el endpoint a nivel de aplicación (`dapr-app-id` header).
