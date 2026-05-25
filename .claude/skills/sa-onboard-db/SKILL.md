---
name: sa-onboard-db
description: 'Generates the exact SQL block of GRANTs that must run in psql to enable the dev user on a new Cloud SQL schema, plus the connection command. Use whenever the user is provisioning a new database schema and needs the GRANT statements ready to copy-paste.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Genera el bloque SQL exacto de GRANTs que se debe ejecutar en psql para habilitar el usuario `dev` en un schema nuevo de Cloud SQL. También muestra el comando para conectarse.

**Uso:** `/sa-onboard-db {schema} {owner-role}`

**Ejemplo:** `/sa-onboard-db treasury treasury`

**Schemas existentes y sus owner-roles:**
| Schema | Owner role |
|---|---|
| `access_manager` | `accmgr` |
| `segment` | `segments` |
| `base_config` | `base_config` |
| `tprt` | `third_party` |
| `acct` | `accounting` |
| `liquid_tax` | `liquid_tax` |

---

## Instrucciones

Los argumentos son: `$ARGUMENTS`

- `SCHEMA` = primer argumento
- `OWNER_ROLE` = segundo argumento

Lee `environments/dev.yaml` para obtener:
- `PROJECT_ID` = `.gcp.project_id`
- `INSTANCE` = `.database.instance_name`
- `DB_NAME` = `.database.database_name`
- `REGION` = `.gcp.region`

---

### Paso 1 — Mostrar el comando de conexión

```bash
# Conectarse a Cloud SQL via Auth Proxy
./scripts/dev-connect.sh

# O directamente con cloud-sql-proxy:
cloud-sql-proxy {PROJECT_ID}:{REGION}:{INSTANCE} --port=5433 &

# Conectar con psql (usar PGPASSWORD del entorno):
psql "host=127.0.0.1 port=5433 dbname={DB_NAME} user=postgres"
```

### Paso 2 — Mostrar el bloque SQL a ejecutar

```sql
-- ============================================================
-- Grants para schema: {SCHEMA}
-- Owner role: {OWNER_ROLE}
-- Ejecutar como: postgres
-- ============================================================

-- 1. Crear el owner role si no existe
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{OWNER_ROLE}') THEN
    CREATE ROLE {OWNER_ROLE};
  END IF;
END $$;

-- 2. Crear el schema si no existe
CREATE SCHEMA IF NOT EXISTS {SCHEMA} AUTHORIZATION {OWNER_ROLE};

-- 3. Darle al usuario dev acceso al schema
GRANT USAGE ON SCHEMA {SCHEMA} TO dev;
GRANT ALL PRIVILEGES ON SCHEMA {SCHEMA} TO dev;

-- 4. Permisos sobre objetos existentes
GRANT ALL ON ALL TABLES IN SCHEMA {SCHEMA} TO dev;
GRANT ALL ON ALL SEQUENCES IN SCHEMA {SCHEMA} TO dev;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA {SCHEMA} TO dev;

-- 5. Permisos default para objetos FUTUROS (creados por migraciones EF Core)
ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}
  GRANT ALL ON TABLES TO dev;

ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}
  GRANT ALL ON SEQUENCES TO dev;

ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}
  GRANT ALL ON FUNCTIONS TO dev;

-- 6. Membresía del rol owner → dev puede hacer ALTER TABLE
GRANT {OWNER_ROLE} TO dev;

-- Verificar:
-- \dn+ {SCHEMA}
-- \dp {SCHEMA}.*
```

### Paso 3 — Notas importantes

Muestra:

```
⚠️  NOTAS CRÍTICAS:

  1. Usar psql, NO DBeaver — DBeaver falla con error 3F000 en GRANT DEFAULT PRIVILEGES.

  2. El GRANT {OWNER_ROLE} TO dev es obligatorio.
     Sin él, EF Core puede crear tablas pero no hacer ALTER TABLE en migraciones futuras.

  3. El schema en IEntityTypeConfiguration DEBE usar "{SCHEMA}" (guión bajo),
     nunca "{SCHEMA con guiones}" — genera un schema huérfano en PostgreSQL.

  4. Después de ejecutar los grants, el primer deploy correrá las migraciones
     automáticamente (db.Database.MigrateAsync() en Program.cs).

  5. La contraseña del usuario postgres está en Secret Manager:
       gcloud secrets versions access latest \
         --secret="{SCHEMA}-dev-db-connection" \
         --project={PROJECT_ID}
```
