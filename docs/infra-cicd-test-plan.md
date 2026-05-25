# Plan de Pruebas — Infrastructure CI/CD Pipeline

Ref: `.github/workflows/infra-pipeline.yml`

> **Principio:** Ninguna prueba requiere acceso directo a GCP (gcloud, kubectl).
> Todo se valida a través de GitHub (PRs, Actions, logs) y Terraform (plan/apply).

---

## Pre-requisitos

### 1. Bootstrap del Deploy SA (única operación manual con GCP)

Esto se hace **una sola vez** antes de la primera ejecución del pipeline.
Después, el SA queda gestionado por Terraform.

```bash
# 1. Crear SA
gcloud iam service-accounts create sa-sie-fin-deploy-cicd \
  --display-name="CI/CD SA for deploy" \
  --project=prj-sie-fin-financiero-dev

# 2. Asignar roles
for role in container.admin compute.securityAdmin artifactregistry.admin \
  cloudsql.admin dns.admin iam.serviceAccountAdmin iam.workloadIdentityPoolAdmin \
  secretmanager.admin pubsub.admin storage.admin resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding prj-sie-fin-financiero-dev \
    --member="serviceAccount:sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com" \
    --role="roles/$role"
done

# 3. WIF binding
gcloud iam service-accounts add-iam-policy-binding \
  sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/641762852790/locations/global/workloadIdentityPools/github-actions/attribute.repository/SiesaTeams/business-financiero-deploy" \
  --project=prj-sie-fin-financiero-dev

# 4. Import a Terraform state
cd terraform/environments/dev
terraform import 'module.iam.google_service_account.cicd["deploy"]' \
  projects/prj-sie-fin-financiero-dev/serviceAccounts/sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com
```

### 2. Verificar que el repo tiene los permisos para WIF

En GitHub → Settings → Environments (o Actions secrets):
- No se necesitan secrets — WIF usa OIDC token nativo de GitHub Actions.
- Verificar que Actions está habilitado en el repo.

---

## Fase A — Validación del Pipeline (Terraform Plan en PR)

### Prueba A1: PR con cambio solo en `terraform/`

**Rama:** `test/tf-plan-only`

```bash
git checkout -b test/tf-plan-only
```

**Cambio:** Agregar un comentario inocuo en `terraform/environments/dev/main.tf`:

```hcl
# Test: validar que el pipeline de terraform plan funciona correctamente
```

**Pasos:**
1. Push de la rama a GitHub
2. Crear PR hacia `main`
3. Esperar que GitHub Actions ejecute

**Verificación (en GitHub):**
- [ ] Job `load-config` completa OK — los outputs coinciden con `project-config.yaml`
- [ ] Job `terraform-plan` se ejecuta
- [ ] `terraform init` exitoso (conecta al backend GCS)
- [ ] `terraform validate` exitoso
- [ ] `terraform plan` genera output con `No changes` (o cambios esperados)
- [ ] Comentario automático aparece en el PR con el plan
- [ ] Check del PR queda en verde

**Cómo verificar:** `gh run list --branch test/tf-plan-only` y `gh pr view`

---

### Prueba A2: PR con cambio solo en `routes/`

**Rama:** `test/routes-only`

**Cambio:** Agregar un comentario en `routes/access-manager-route.yaml`:

```yaml
# Test: validar que cambios en routes no disparan terraform plan
```

**Verificación (en GitHub):**
- [ ] Job `load-config` completa OK
- [ ] Job `terraform-plan` se ejecuta PERO `has_changes=false` → se salta TF
- [ ] No se genera comentario de Terraform en el PR
- [ ] El PR completa sin errores

---

### Prueba A3: PR con cambio en `project-config.yaml`

**Rama:** `test/config-change`

**Cambio:** Agregar un comentario al final de `project-config.yaml`:

```yaml
# Test: validar que cambios en config disparan terraform plan
```

**Verificación (en GitHub):**
- [ ] Pipeline se activa (project-config.yaml está en `paths`)
- [ ] Job `terraform-plan` detecta `has_changes=true` (project-config.yaml cambió)
- [ ] Plan se ejecuta y comenta en el PR

---

### Prueba A4: PR con cambio solo en `docs/`

**Rama:** `test/docs-only`

**Cambio:** Editar cualquier archivo en `docs/`

**Verificación (en GitHub):**
- [ ] Pipeline NO se ejecuta (docs/ no está en `paths`)
- [ ] `gh run list --branch test/docs-only` no muestra runs del Infrastructure Pipeline

---

### Prueba A5: Terraform plan falla intencionalmente

**Rama:** `test/tf-plan-fail`

**Cambio:** Introducir un error de sintaxis temporal en `terraform/environments/dev/main.tf`:

```hcl
resource "this_is_invalid" "test" {}
```

**Verificación (en GitHub):**
- [ ] `terraform validate` o `terraform plan` falla
- [ ] Comentario en el PR muestra el error con icono de fallo
- [ ] Check del PR queda en rojo (step "Fail if plan failed")
- [ ] El PR queda bloqueado si hay branch protection rules

**Limpieza:** Cerrar el PR sin merge, eliminar la rama.

---

## Fase B — Validación del Apply (Merge a main)

### Prueba B1: Merge de cambio inocuo en Terraform

**Pre-requisito:** PR de la prueba A1 aprobado.

**Pasos:**
1. Merge del PR `test/tf-plan-only` a `main`
2. Esperar que GitHub Actions ejecute

**Verificación (en GitHub Actions logs):**
- [ ] Job `load-config` completa OK
- [ ] Job `terraform-apply` se ejecuta
- [ ] `terraform init` exitoso
- [ ] `terraform apply` reporta `No changes. Your infrastructure matches the configuration.`
- [ ] Job `k8s-manifests` se ejecuta PERO `has_changes=false` → se salta
- [ ] Run completo en verde

**Cómo verificar:** `gh run list --branch main` y `gh run view <run-id> --log`

---

### Prueba B2: Merge de cambio en manifiestos K8s

**Rama:** `test/k8s-manifests-apply`

**Cambio:** Agregar una annotation inocua en `routes/access-manager-route.yaml`:

```yaml
metadata:
  annotations:
    test.deploy/verified: "true"
```

**Pasos:**
1. Crear PR, verificar que pasa (Fase A)
2. Merge a `main`

**Verificación (en GitHub Actions logs):**
- [ ] Job `terraform-apply` se ejecuta pero `has_changes=false` → se salta TF
- [ ] Job `k8s-manifests` se ejecuta con `has_changes=true`
- [ ] Cloud Build submit exitoso
- [ ] Logs de Cloud Build muestran:
  - Worker IP obtenida
  - Authorized networks actualizado
  - `kubectl apply` de redis, dapr, routes, healthcheck, import-map
  - Authorized networks restaurado
- [ ] Build status: SUCCESS

---

### Prueba B3: Merge de cambio mixto (Terraform + manifiestos)

**Rama:** `test/mixed-change`

**Cambio:** Modificar un comentario en `terraform/environments/dev/main.tf` Y agregar una annotation en `routes/segments-route.yaml`

**Verificación (en GitHub Actions logs):**
- [ ] Job `terraform-apply` se ejecuta (`has_changes=true`)
- [ ] Job `k8s-manifests` espera a que `terraform-apply` complete (dependency)
- [ ] Ambos jobs completan exitosamente
- [ ] Orden correcto: terraform-apply → k8s-manifests

---

## Fase C — Validación de la configuración centralizada

### Prueba C1: project-config.yaml se lee correctamente en Terraform

**Rama:** `test/config-read-tf`

**Cambio:** En `project-config.yaml`, agregar un campo nuevo inofensivo:

```yaml
# Al final del archivo
_test:
  validation: "config-read-test"
```

**Verificación:**
- [ ] `terraform plan` no falla (YAML con campos extra es válido, Terraform solo lee lo que necesita)
- [ ] Los valores en el plan coinciden con los de `project-config.yaml`

**Limpieza:** Revertir el campo `_test` antes de merge.

---

### Prueba C2: project-config.yaml se lee correctamente en GitHub Actions

**Verificación (en logs del job `load-config`):**
- [ ] Output `project_id` = `prj-sie-fin-financiero-dev`
- [ ] Output `project_num` = `641762852790`
- [ ] Output `region` = `us-east1`
- [ ] Output `gke_cluster` = `gke-sie-fin-dev`
- [ ] Output `tf_version` = `1.9`
- [ ] Output `sa_email` = `sa-sie-fin-deploy-cicd@prj-sie-fin-financiero-dev.iam.gserviceaccount.com`
- [ ] Output `wif_provider` contiene `github-actions/providers/github`

Se valida automáticamente en cualquier run de las pruebas A1-A5 o B1-B3.

---

### Prueba C3: Cambio real de parámetro en config

**Rama:** `test/config-param-change`

**Cambio:** Modificar un campo cosmético en `project-config.yaml`, por ejemplo:

```yaml
database:
  tier: db-f1-micro  # Agregar comentario: probado 2026-03-13
```

**Verificación:**
- [ ] Pipeline se activa por el path `project-config.yaml`
- [ ] `terraform plan` muestra `No changes` (el comentario YAML no afecta el valor)

---

## Fase D — Validación de permisos y seguridad

### Prueba D1: WIF authentication funciona

Se valida implícitamente en todas las pruebas B1-B3. Si falla:

**Síntomas en logs:**
- `Error: google: could not find default credentials`
- `Error 403: Permission denied on resource`

**Diagnóstico (en GitHub Actions logs):**
- [ ] Step "Authenticate to GCP" muestra `Successfully authenticated`
- [ ] No hay errores de permisos en `terraform init` (acceso al bucket GCS)
- [ ] No hay errores de permisos en `terraform apply`

---

### Prueba D2: SA tiene permisos suficientes para todos los recursos

**Verificación:** Se valida durante la prueba B1 o B3. Un `terraform apply` exitoso confirma que el SA tiene:
- [ ] `storage.admin` → acceso al state bucket
- [ ] `container.admin` → gestión del cluster GKE
- [ ] `cloudsql.admin` → gestión de Cloud SQL
- [ ] `dns.admin` → gestión de la zona DNS
- [ ] `iam.serviceAccountAdmin` → gestión de SAs
- [ ] `iam.workloadIdentityPoolAdmin` → gestión del WIF pool
- [ ] `artifactregistry.admin` → gestión de repos Docker
- [ ] `secretmanager.admin` → gestión de secrets
- [ ] `pubsub.admin` → gestión de pub/sub

Si algún permiso falta, el `terraform apply` fallará con un error `403` claro indicando qué rol falta.

---

### Prueba D3: Cloud Build worker pool puede acceder al cluster

Se valida durante la prueba B2. Si falla:

**Síntomas en Cloud Build logs:**
- `Unable to connect to the server`
- `Error from server (Forbidden)`

**Diagnóstico (en GitHub Actions logs → Cloud Build output):**
- [ ] Worker IP obtenida correctamente
- [ ] `gcloud container clusters update` exitoso
- [ ] `gcloud container clusters get-credentials` exitoso
- [ ] `kubectl apply` exitoso

---

## Fase E — Idempotencia y estabilidad

### Prueba E1: Re-run del pipeline sin cambios

**Pasos:**
1. Ir a GitHub Actions → Infrastructure Pipeline → último run exitoso
2. Click "Re-run all jobs"

**Verificación:**
- [ ] `terraform apply` reporta `No changes`
- [ ] `kubectl apply` de manifiestos completa sin errores (K8s es idempotente)
- [ ] Authorized networks se restauran correctamente

---

### Prueba E2: Authorized networks se restauran tras fallo

**Verificación:** En los logs de Cloud Build de cualquier prueba B:
- [ ] Paso 2 guarda `CURRENT_NETWORKS` antes de modificar
- [ ] Paso 6 restaura exactamente los mismos CIDRs
- [ ] Los CIDRs de entrada y salida coinciden en los logs

---

## Checklist de ejecución

| # | Prueba | Rama | Estado | Notas |
|---|--------|------|--------|-------|
| A1 | TF plan en PR | `test/tf-plan-only` | [ ] | |
| A2 | Routes no trigger TF | `test/routes-only` | [ ] | |
| A3 | Config change trigger TF | `test/config-change` | [ ] | |
| A4 | Docs no trigger pipeline | `test/docs-only` | [ ] | |
| A5 | TF plan falla | `test/tf-plan-fail` | [ ] | Cerrar sin merge |
| B1 | TF apply inocuo | merge A1 | [ ] | |
| B2 | K8s manifests apply | `test/k8s-manifests-apply` | [ ] | |
| B3 | Cambio mixto | `test/mixed-change` | [ ] | |
| C1 | Config extra fields | `test/config-read-tf` | [ ] | Revertir antes de merge |
| C2 | Config outputs en GHA | (cualquier run) | [ ] | |
| C3 | Config param cosmético | `test/config-param-change` | [ ] | |
| D1 | WIF auth | (implícito en B*) | [ ] | |
| D2 | SA permisos | (implícito en B1/B3) | [ ] | |
| D3 | Cloud Build → GKE | (implícito en B2) | [ ] | |
| E1 | Re-run idempotente | (re-run manual) | [ ] | |
| E2 | Networks restore | (implícito en B2) | [ ] | |

## Limpieza post-pruebas

```bash
# Eliminar ramas de test (desde GitHub o local)
for branch in test/tf-plan-only test/routes-only test/config-change \
  test/docs-only test/tf-plan-fail test/k8s-manifests-apply \
  test/mixed-change test/config-read-tf test/config-param-change; do
  gh api repos/SiesaTeams/business-financiero-deploy/git/refs/heads/$branch \
    -X DELETE 2>/dev/null || true
done
```

## Orden recomendado de ejecución

```
A4 → A1 → A2 → A3 → A5 → B1 (merge A1) → B2 → B3 → C1 → C3 → E1
         ↓
       C2 (verificar outputs en logs de A1)
         ↓
       D1, D2, D3 (verificar en logs de B1, B2)
         ↓
       E2 (verificar en logs de B2)
```

1. Empezar por A4 (más rápido, confirma que el paths filter funciona)
2. A1 valida el flujo completo de plan
3. A2/A3 validan los filtros de cambio
4. A5 valida el flujo de error
5. B1 valida el apply (mergeando A1)
6. B2/B3 validan manifiestos y cambios mixtos
7. C/D/E se verifican en los logs de las pruebas anteriores
