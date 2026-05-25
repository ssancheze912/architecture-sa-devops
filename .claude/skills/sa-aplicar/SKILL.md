---
name: sa-aplicar
description: 'Validates pending changes, creates a conventional-format commit, pushes to main, and monitors the GitHub Actions pipeline. If the pipeline fails, diagnoses the error and repairs what it can within official guidelines. Use whenever the user wants to commit, push, and watch the deploy pipeline of business-financiero-deploy (or its mirror at _siesa-agents/devops/) in one go.'
---

> **Contexto de ejecución:** este skill asume que el cwd está dentro de la carpeta del workspace de despliegue (`_siesa-agents/devops/` en Siesa-Agents tras correr `/sa-init-devops`, o la raíz de un clon directo de `architecture-sa-devops`). Las rutas relativas (`environments/`, `terraform/`, `k8s/`, `scripts/`, etc.) se resuelven contra ese cwd.

Valida, hace commit con formato convencional, push a main y monitorea el pipeline de GitHub Actions. Si el pipeline falla, diagnostica el error, repara lo que puede sin salirse de los lineamientos y consulta al usuario cuando se requiere una decisión.

**Uso:** `/sa-aplicar`

No recibe argumentos — opera sobre los cambios actuales del repositorio.

---

## Instrucciones

### Fase 1 — Validación previa al commit

**1.1 Verificar que hay cambios para commitear**

Ejecuta `git status --short`. Si no hay archivos modificados ni untracked relevantes, informar al usuario y detener el flow.

**1.2 Detectar archivos modificados y determinar pipelines afectados**

Ejecuta `git diff --name-only HEAD` más `git ls-files --others --exclude-standard` para listar todos los cambios pendientes.

Mapea los archivos a pipelines:
- `environments/shared.yaml` o `terraform/environments/shared/**` → pipeline `infra-pipeline-shared`
- `environments/dev.yaml` o `terraform/environments/dev/**` o `k8s/overlays/dev/**` → pipeline `infra-pipeline-dev`
- `environments/staging.yaml` o `terraform/environments/staging/**` o `k8s/overlays/staging/**` → pipeline `infra-pipeline-staging`
- `environments/prod.yaml` o `terraform/environments/prod/**` o `k8s/overlays/prod/**` → pipeline `infra-pipeline-prod`
- Solo `.claude/commands/**`, `docs/**`, `README.md`, `CLAUDE.md`, `.gemini/**` → sin pipeline (solo docs)

**1.3 Buscar `<PLACEHOLDER>` sin resolver**

Para cada archivo `environments/*.yaml` modificado, leer el contenido y buscar la cadena `<PLACEHOLDER`. Si se encuentra alguno:

```
❌ PLACEHOLDER sin resolver en {archivo}:
  línea {N}: {contenido}

Completa los valores antes de aplicar.
```

Detener el flow si hay placeholders en archivos que afectan un pipeline de infraestructura.

**1.4 Validar Terraform (si hay cambios en terraform/)**

Si hay archivos modificados en `terraform/environments/`:
- Intentar ejecutar `terraform validate` en el directorio afectado
- Si `terraform` no está instalado localmente: advertir pero no bloquear ("el pipeline validará en CI")
- Si `terraform validate` falla: mostrar el error y detener el flow

**1.5 Verificar que CLAUDE.md fue actualizado**

Si los cambios incluyen archivos que no son solo `docs/**` o `.claude/**` y CLAUDE.md NO está entre los archivos modificados, mostrar advertencia (no bloquear):

```
⚠️  CLAUDE.md no fue actualizado. Regla 2 del repo requiere actualizar CLAUDE.md
    en cada cambio. ¿Deseas continuar de todas formas? (s/n)
```

Esperar confirmación antes de continuar.

**1.6 Mostrar resumen de validación**

```
✅ Validación completa

Archivos a commitear: {N}
Pipelines que se dispararán: {lista o "ninguno (solo docs)"}
Placeholders: ninguno
Terraform: válido / no verificado localmente
```

---

### Fase 2 — Commit estructurado

**2.1 Detectar el tipo de cambio automáticamente**

Basándose en los archivos modificados:
- Solo `docs/**`, `README.md`, `CLAUDE.md`, `.gemini/**` → tipo `docs`
- Nuevos archivos en `terraform/`, `environments/`, `k8s/` → tipo `feat`
- Modificaciones a archivos existentes de infra → tipo `fix` o `feat` según contexto
- Solo `.claude/commands/**` → tipo `feat`
- Modificaciones menores/limpieza → tipo `chore`

**2.2 Pedir resumen al usuario**

```
📝 ¿Qué se hizo? (una línea, en español):
```

Leer la respuesta del usuario.

**2.3 Construir el mensaje de commit**

Formato:
```
{tipo}: {resumen del usuario}

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

Donde `{tipo}` es el detectado en 2.1.

Mostrar el mensaje al usuario para confirmación:
```
Commit que se creará:

  {tipo}: {resumen}

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>

¿Confirmar? (s/n)
```

**2.4 Ejecutar el commit**

```bash
git add -A
git commit -m "{mensaje}"
```

Si el pre-commit hook falla: mostrar el error, NO hacer `--amend`. Pedir al usuario que corrija el problema antes de reintentar.

---

### Fase 3 — Push

```bash
git push origin main
```

Si falla:
- `rejected (non-fast-forward)`: ejecutar `git pull --rebase origin main` y reintentar el push una vez
- Cualquier otro error: mostrar el mensaje y detener el flow

---

### Fase 4 — Monitoreo del pipeline

**4.1 Identificar el run recién disparado**

Si hay pipelines esperados (detectados en Fase 1), esperar 10 segundos y ejecutar:

```bash
gh run list --branch main --limit 5 --json databaseId,name,status,conclusion,createdAt
```

Identificar los runs correspondientes a los pipelines afectados. Mostrar:

```
🔍 Pipelines disparados:
  • infra-pipeline-dev   → run #12345 (queued)
  • infra-pipeline-shared → run #12346 (queued)
```

Si no hay pipelines (solo docs): informar que no hay pipeline que monitorear y terminar.

**4.2 Monitorear en tiempo real**

Para cada run identificado, ejecutar en loop (cada 30 segundos):

```bash
gh run view {run_id} --json status,conclusion,jobs
```

Mostrar progreso por job:
```
⏳ infra-pipeline-dev [2m 30s]
   ✅ load-config
   ✅ terraform-plan
   🔄 terraform-apply (en progreso)
```

Continuar hasta que todos los runs tengan `status = completed`.

**4.3 Resultado final**

Si todos los pipelines terminaron con `conclusion = success`:
```
✅ DEPLOY COMPLETO

  infra-pipeline-dev    → success (4m 12s)
  infra-pipeline-shared → success (1m 48s)
```

Si alguno falló: ir a Fase 5.

---

### Fase 5 — Diagnóstico y reparación

**5.1 Leer el log del step fallido**

```bash
gh run view {run_id} --log-failed
```

Leer el output completo del step que falló.

**5.2 Clasificar el error**

Categorías y respuesta esperada:

| Categoría | Señales en el log | Acción |
|---|---|---|
| **Drift de Terraform** | `Error: Provider produced inconsistent final plan` o `Plan: X to add, Y to destroy` inesperado | Proponer import block o ajuste en `main.tf` → preguntar antes de aplicar |
| **Import faltante** | `Resource already exists` | Agregar import block al `main.tf` correspondiente → preguntar al usuario |
| **Error de IAM/permisos** | `403 Permission denied` o `required permission` | Listar el permiso faltante, proponer agregarlo a `deploy.roles` en el YAML → SIEMPRE preguntar antes (toca IAM compartido) |
| **K8s manifest inválido** | `error validating` o `unknown field` | Leer el manifiesto, corregir el campo incorrecto, re-aplicar automáticamente |
| **Secret no existe** | `Secret Manager: not found` | Mostrar el comando `gcloud secrets create` exacto para que el usuario lo ejecute → no continuar sin confirmación |
| **Timeout / error de red** | `context deadline exceeded` o `connection refused` | Reintentar el pipeline una vez con `gh run rerun {run_id}` → volver a Fase 4 |
| **Error desconocido** | Cualquier otro | Mostrar el log completo al usuario, explicar lo que se entiende, preguntar cómo proceder |

**5.3 Acciones que NO requieren confirmación**

- Corregir un campo inválido en un manifiesto K8s (typo, campo deprecado)
- Reintentar un pipeline después de timeout de red

**5.4 Acciones que SIEMPRE requieren confirmación**

- Agregar o modificar roles IAM
- Agregar import blocks a Terraform (pueden cambiar el state)
- Destruir o recrear recursos (`-/+` en el plan)
- Cualquier cambio que afecte recursos compartidos (WIF pool, AR repos, SAs de CI/CD)

**5.5 Si se aplica una corrección**

Volver a Fase 2 (commit de la corrección) con tipo `fix` y descripción automática del problema resuelto. Luego continuar por Fase 3 → 4.

**5.6 Límite de intentos**

Si el pipeline falla 3 veces consecutivas sin que se pueda reparar automáticamente:

```
🛑 El pipeline falló 3 veces. Intervención manual requerida.

Último error:
  {log del step fallido}

Opciones:
  1. Ver el run completo: gh run view {run_id} --log
  2. Reintentarlo manualmente: gh run rerun {run_id}
  3. Abrir en GitHub: {url del run}
```

Detener el flow.

---

### Fase 6 — Cierre

```
🎉 /sa-aplicar completado

  Commit:   {hash corto} {mensaje}
  Push:     main → origin/main
  Pipelines: todos exitosos

Próximo paso sugerido: {según contexto}
  - Si fue scaffolding inicial: /sa-nuevo-servicio {nombre} {api-port} {mfe-port}
  - Si fue un servicio nuevo: /sa-onboard-db {schema} {owner-role}
  - Si fue un ambiente nuevo: verificar que los <PLACEHOLDER> de staging/prod.yaml estén completos
```
