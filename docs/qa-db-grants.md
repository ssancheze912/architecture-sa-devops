# DDL GRANTs para Cloud SQL QA

> **Instancia:** `pgsql-fin-financiero-qa` — IP privada `192.168.160.20` (PSA) / PSC endpoint `10.20.39.250` (sin Auth Proxy, sin IP pública)
> **Base de datos:** `finance-qa`
> **Cuándo ejecutar:** Después del primer deploy de cada servicio (las migraciones EF Core crean el schema)

---

## Método de conexión

Cloud SQL QA solo tiene IP privada — hay que conectarse desde dentro de la VPC del cluster QA.

### Opción 1 — Pod temporal en GKE QA (recomendado)

```bash
# 1. Autenticarse en el cluster QA
gcloud container clusters get-credentials gke-sie-fin-financiero-qa \
  --region us-east1 \
  --project prj-sie-fin-financiero-qas

# 2. Lanzar pod efímero con psql
kubectl run psql-tmp --rm -it \
  --image=postgres:18 \
  --restart=Never \
  --namespace=default \
  -- bash

# 3. Dentro del pod, conectarse a Cloud SQL (pedir contraseña de postgres a Secret Manager)
psql "host=10.20.39.250 port=5432 dbname=finance-qa user=postgres sslmode=disable"
```

### Opción 2 — kubectl exec en pod existente

```bash
# Cualquier pod corriendo en QA con bash disponible
kubectl exec -it -n segments deploy/segments-api -- bash

# Instalar psql si no está (solo si la imagen base lo permite)
apt-get install -y postgresql-client 2>/dev/null

psql "host=10.20.39.250 port=5432 dbname=finance-qa user=postgres sslmode=disable"
```

### Obtener contraseña de postgres

```bash
# La contraseña del superusuario postgres está gestionada por Terraform
# Buscarla en Secret Manager del proyecto QA:
gcloud secrets list --project=prj-sie-fin-financiero-qas | grep postgres

# O bien, desde la consola de Cloud SQL:
# Cloud SQL Studio → Instancia pgsql-fin-financiero-qa → Conectar
```

---

## Scripts DDL por schema

> **⚠️ Cloud SQL QA — `postgres` es `cloudsqlsuperuser`, NO superuser real.**
> No puede ejecutar `GRANT` sobre schemas que pertenecen a otros roles.
> Solución validada (2026-05-20): conectarse como `postgres` y usar `SET ROLE {owner}`
> antes de los grants de cada schema. Requiere primero `GRANT {role} TO postgres`.

Conectarse como `postgres` y ejecutar el bloque completo de una vez (todos los schemas):

```bash
PGPASS=$(gcloud secrets versions access latest --secret=pgsql-qa-superuser-tmp --project=prj-sie-fin-financiero-qas)
kubectl run psql-grants --rm -i --restart=Never --namespace=default \
  --image=postgres:18 --env="PGPASSWORD=$PGPASS" \
  -- psql "host=10.20.39.250 port=5432 dbname=finance-qa user=postgres sslmode=disable" \
  -v ON_ERROR_STOP=1 <<'SQLEOF'
-- Habilitar SET ROLE a cada owner
GRANT accmgr TO postgres;
GRANT segments TO postgres;
GRANT base_config TO postgres;
GRANT third_party TO postgres;
GRANT accounting TO postgres;
GRANT liquid_tax TO postgres;
-- Luego ejecutar los bloques por schema (ver abajo)
SQLEOF
```

O bien ejecutar los schemas individualmente como se muestra a continuación.

---

### access_manager (servicio: access-manager)

```sql
-- ============================================================
-- Schema: access_manager | Owner role: accmgr
-- Ejecutar DESPUÉS del primer deploy de access-manager
-- ============================================================

-- Prerrequisito: GRANT accmgr TO postgres (ver bloque superior)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'accmgr') THEN
    RAISE EXCEPTION 'Rol accmgr no encontrado. Verificar que el SQL user fue creado por Terraform.';
  END IF;
END $$;

SET ROLE accmgr;
GRANT ALL PRIVILEGES ON SCHEMA access_manager TO accmgr;
GRANT ALL ON ALL TABLES IN SCHEMA access_manager TO accmgr;
GRANT ALL ON ALL SEQUENCES IN SCHEMA access_manager TO accmgr;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA access_manager TO accmgr;
ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON TABLES TO accmgr;
ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON SEQUENCES TO accmgr;
ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON FUNCTIONS TO accmgr;
RESET ROLE;

-- Verificar: \dn+ access_manager
```

---

### segment (servicio: segments)

```sql
-- ============================================================
-- Schema: segment | Owner role: segments
-- Ejecutar DESPUÉS del primer deploy de segments
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'segments') THEN
    RAISE EXCEPTION 'Rol segments no encontrado. Verificar que el SQL user fue creado por Terraform.';
  END IF;
END $$;

SET ROLE segments;
GRANT ALL PRIVILEGES ON SCHEMA segment TO segments;
GRANT ALL ON ALL TABLES IN SCHEMA segment TO segments;
GRANT ALL ON ALL SEQUENCES IN SCHEMA segment TO segments;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA segment TO segments;
ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON TABLES TO segments;
ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON SEQUENCES TO segments;
ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON FUNCTIONS TO segments;
RESET ROLE;

-- Verificar: \dn+ segment
```

---

### base_config (servicio: base-config)

```sql
-- ============================================================
-- Schema: base_config | Owner role: base_config
-- Ejecutar DESPUÉS del primer deploy de base-config
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'base_config') THEN
    RAISE EXCEPTION 'Rol base_config no encontrado. Verificar que el SQL user fue creado por Terraform.';
  END IF;
END $$;

SET ROLE base_config;
GRANT ALL PRIVILEGES ON SCHEMA base_config TO base_config;
GRANT ALL ON ALL TABLES IN SCHEMA base_config TO base_config;
GRANT ALL ON ALL SEQUENCES IN SCHEMA base_config TO base_config;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA base_config TO base_config;
ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON TABLES TO base_config;
ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON SEQUENCES TO base_config;
ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON FUNCTIONS TO base_config;
RESET ROLE;

-- Verificar: \dn+ base_config
```

---

### tprt (servicio: third-party)

```sql
-- ============================================================
-- Schema: tprt | Owner role: third_party
-- Ejecutar DESPUÉS del primer deploy de third-party
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'third_party') THEN
    RAISE EXCEPTION 'Rol third_party no encontrado. Verificar que el SQL user fue creado por Terraform.';
  END IF;
END $$;

SET ROLE third_party;
GRANT ALL PRIVILEGES ON SCHEMA tprt TO third_party;
GRANT ALL ON ALL TABLES IN SCHEMA tprt TO third_party;
GRANT ALL ON ALL SEQUENCES IN SCHEMA tprt TO third_party;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA tprt TO third_party;
ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON TABLES TO third_party;
ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON SEQUENCES TO third_party;
ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON FUNCTIONS TO third_party;
RESET ROLE;

-- Verificar: \dn+ tprt
```

---

### acct (servicio: accounting)

> ⚠️ **Pendiente fix en accounting-service** (2026-05-20): el schema `acct` no existe porque
> `MigrateAsync()` falla — bug en `AccountingServiceDbContextModelSnapshot.cs:6696`
> (`FiscalYearPrj` shadow property `Code` sin tipo explícito). Ver `docs/bugs/accounting-fiscalyearprj-shadow-property.md`.
> Ejecutar estos grants DESPUÉS de que el fix llegue a QA y el schema sea creado.

```sql
-- ============================================================
-- Schema: acct | Owner role: accounting
-- Ejecutar DESPUÉS del primer deploy de accounting (con bug fix)
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'accounting') THEN
    RAISE EXCEPTION 'Rol accounting no encontrado. Verificar que el SQL user fue creado por Terraform.';
  END IF;
END $$;

SET ROLE accounting;
GRANT ALL PRIVILEGES ON SCHEMA acct TO accounting;
GRANT ALL ON ALL TABLES IN SCHEMA acct TO accounting;
GRANT ALL ON ALL SEQUENCES IN SCHEMA acct TO accounting;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA acct TO accounting;
ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON TABLES TO accounting;
ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON SEQUENCES TO accounting;
ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON FUNCTIONS TO accounting;
RESET ROLE;

-- Verificar:
-- \dn+ acct
```

---

### liquid_tax (servicio: liquid-tax)

```sql
-- ============================================================
-- Schema: liquid_tax | Owner role: liquid_tax
-- Ejecutar DESPUÉS del primer deploy de liquid-tax
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'liquid_tax') THEN
    RAISE EXCEPTION 'Rol liquid_tax no encontrado. Verificar que el SQL user fue creado por Terraform.';
  END IF;
END $$;

SET ROLE liquid_tax;
GRANT ALL PRIVILEGES ON SCHEMA liquid_tax TO liquid_tax;
GRANT ALL ON ALL TABLES IN SCHEMA liquid_tax TO liquid_tax;
GRANT ALL ON ALL SEQUENCES IN SCHEMA liquid_tax TO liquid_tax;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA liquid_tax TO liquid_tax;
ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON TABLES TO liquid_tax;
ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON SEQUENCES TO liquid_tax;
ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON FUNCTIONS TO liquid_tax;
RESET ROLE;

-- Verificar: \dn+ liquid_tax
```

---

## Grants para usuario dev (opcional — aplicar cuando existan los grupos de QA)

Una vez que se creen los grupos de Google Workspace y se habilite `dev_access.enabled: true`, crear también un usuario `dev` en Cloud SQL QA y ejecutar:

```sql
-- Verificar que el usuario dev existe antes de ejecutar
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dev') THEN
    RAISE EXCEPTION 'Usuario dev no encontrado. Crear primero el Cloud SQL user dev en QA.';
  END IF;
END $$;

-- Ejecutar para cada schema una vez que el servicio haya desplegado:

-- access_manager
GRANT USAGE ON SCHEMA access_manager TO dev;
GRANT ALL ON ALL TABLES IN SCHEMA access_manager TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA access_manager TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA access_manager GRANT ALL ON SEQUENCES TO dev;
GRANT accmgr TO dev;

-- segment
GRANT USAGE ON SCHEMA segment TO dev;
GRANT ALL ON ALL TABLES IN SCHEMA segment TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA segment TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA segment GRANT ALL ON SEQUENCES TO dev;
GRANT segments TO dev;

-- base_config
GRANT USAGE ON SCHEMA base_config TO dev;
GRANT ALL ON ALL TABLES IN SCHEMA base_config TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA base_config TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA base_config GRANT ALL ON SEQUENCES TO dev;
GRANT base_config TO dev;

-- tprt
GRANT USAGE ON SCHEMA tprt TO dev;
GRANT ALL ON ALL TABLES IN SCHEMA tprt TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA tprt TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA tprt GRANT ALL ON SEQUENCES TO dev;
GRANT third_party TO dev;

-- acct
GRANT USAGE ON SCHEMA acct TO dev;
GRANT ALL ON ALL TABLES IN SCHEMA acct TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA acct TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA acct GRANT ALL ON SEQUENCES TO dev;
GRANT accounting TO dev;

-- liquid_tax
GRANT USAGE ON SCHEMA liquid_tax TO dev;
GRANT ALL ON ALL TABLES IN SCHEMA liquid_tax TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA liquid_tax TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA liquid_tax GRANT ALL ON SEQUENCES TO dev;
GRANT liquid_tax TO dev;
```

---

## Notas importantes

1. **Orden**: Ejecutar el DDL de un schema DESPUÉS del primer deploy exitoso del servicio correspondiente. Las migraciones EF Core crean el schema y las tablas — los GRANTs fijan la propiedad para migraciones futuras.

2. **psql obligatorio**: NO usar DBeaver — falla con `ERROR 3F000` en `ALTER DEFAULT PRIVILEGES`. Usar siempre psql desde el pod temporal con stdin (`-i`), no interactivo (`-it`).

3. **Conectividad**: Usar el PSC endpoint `10.20.39.250` (forwarding rule en host VPC). La IP PSA `192.168.160.20` no es alcanzable directamente desde pods GKE Autopilot (CIDR `100.82.x.x` no mascarado). Desde un pod en GKE, usar `10.20.39.250`.

4. **SSL**: `sslmode=disable` para conexiones desde dentro del cluster (ya están en la red privada).

5. **`GRANT {role} TO dev` es obligatorio**: Sin este grant, EF Core puede crear tablas pero no hacer `ALTER TABLE` en migraciones futuras (error `42501`).

6. **`SET ROLE` obligatorio (Cloud SQL QA)**: El usuario `postgres` en Cloud SQL es `cloudsqlsuperuser`, NO un superuser real de PostgreSQL. No puede ejecutar `GRANT ALL PRIVILEGES ON SCHEMA foo TO owner` cuando el schema pertenece a otro rol. Siempre hacer primero `GRANT {role} TO postgres` y luego `SET ROLE {role}` antes de los grants de cada schema. Validado 2026-05-20.

7. **Verificar IP en pods existentes tras cambio de connection string**: Si el K8s secret se actualiza (ej. cambio de PSA IP a PSC endpoint), los pods ya corriendo NO recargan el valor — el env var se fija al inicio del pod. Si el CI/CD no fuerza un rollout (ej. misma imagen SHA), hacer `kubectl rollout restart deployment/{svc}-api -n {ns}` manualmente y verificar: `kubectl exec -n {ns} deploy/{svc}-api -- env | grep ConnectionStrings`.
