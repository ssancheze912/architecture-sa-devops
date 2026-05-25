# Módulo: Cloud Monitoring — Alertas de base de datos
#
# Crea:
#   - Canal de notificación por email
#   - Alerta: error en backup de Cloud SQL (condition_matched_log sobre Cloud Audit Logs)
#   - Alerta: uso de disco > 80% (condition_threshold sobre métrica time-series)
#   - Alerta: conexiones activas > 80% de max_connections (condition_threshold)
#
# Nota sobre la alerta de backup:
#   Se usa condition_matched_log (no condition_threshold ni condition_absent) porque:
#   - cloudsql.googleapis.com/database/backup_run_count no existe como métrica time-series
#   - condition_absent tiene límite de 23h30m (insuficiente para backups diarios — falsos positivos)
#   - condition_matched_log detecta el ERROR directamente en Cloud Audit Logs sin métricas intermedias
#
# Nota sobre max_connections:
#   db-f1-micro PostgreSQL → max_connections = 25 (GCP lo calcula por RAM: ~0.6 GB)
#   db-g1-small            → max_connections ≈ 50
#   db-n1-standard-1       → max_connections ≈ 100+
#   Ajustar cloudsql_max_connections al valor real de la instancia (SELECT current_setting('max_connections')).

variable "project_id" { type = string }

variable "alert_email" {
  type        = string
  description = "Email que recibe las alertas de Cloud Monitoring"
}

variable "cloudsql_instance_id" {
  type        = string
  description = "ID de la instancia Cloud SQL (ej: pgsql-fin-sandbox-dev)"
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "cloudsql_max_connections" {
  type        = number
  description = "Valor de max_connections de la instancia PostgreSQL. db-f1-micro = 25, db-g1-small ≈ 50. Alerta se dispara al 80%."
  default     = 25
}

# ── Canal de notificación — Email ─────────────────────────────────────────────

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Alertas Financiero — ${var.alert_email}"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }

  lifecycle {
    # Evitar recrear el canal si el email no cambia
    ignore_changes = [labels]
  }
}

# ── Alerta: error en backup de Cloud SQL ──────────────────────────────────────
# condition_matched_log: se dispara cuando Cloud Audit Logs registra un ERROR
# en una operación de backup (cloudsql.backupRuns.insert con severity=ERROR).
# notification_rate_limit = 86400s → máximo 1 alerta por día por este evento.

resource "google_monitoring_alert_policy" "cloudsql_backup_failure" {
  project      = var.project_id
  display_name = "Cloud SQL — Error en backup (${var.cloudsql_instance_id})"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Backup falló — error en Cloud Audit Logs"

    condition_matched_log {
      filter = <<-EOT
        resource.type="cloudsql_database"
        resource.labels.database_id="${var.project_id}:${var.cloudsql_instance_id}"
        protoPayload.methodName="cloudsql.backupRuns.insert"
        severity=ERROR
      EOT
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "86400s" # máximo 1 notificación por día
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  documentation {
    content   = <<-EOT
      ## Error en backup diario de Cloud SQL

      La instancia `${var.cloudsql_instance_id}` registró un error en la operación
      de backup. **Schedule esperado:** 11 PM COT (04:00 UTC) diariamente.

      ### Pasos de diagnóstico

      1. Verificar estado en GCP Console:
         Cloud SQL → Instancias → `${var.cloudsql_instance_id}` → Backups

      2. Revisar logs del error:
         ```
         gcloud logging read 'resource.type="cloudsql_database" AND protoPayload.methodName="cloudsql.backupRuns.insert" AND severity=ERROR' \
           --project=${var.project_id} --limit=5
         ```

      3. Iniciar backup manual si es necesario:
         ```
         gcloud sql backups create --instance=${var.cloudsql_instance_id} \
           --project=${var.project_id}
         ```
    EOT
    mime_type = "text/markdown"
  }

  user_labels = var.labels
}

# ── Alerta: disco Cloud SQL > 80% ────────────────────────────────────────────

resource "google_monitoring_alert_policy" "cloudsql_disk_usage" {
  project      = var.project_id
  display_name = "Cloud SQL — Uso de disco alto (${var.cloudsql_instance_id})"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Disco utilizado > 80%"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND resource.labels.database_id = "${var.project_id}:${var.cloudsql_instance_id}"
        AND metric.type = "cloudsql.googleapis.com/database/disk/utilization"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0.80
      duration        = "300s" # Sostenido 5 min antes de alertar

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  documentation {
    content   = <<-EOT
      ## Disco Cloud SQL al límite

      La instancia `${var.cloudsql_instance_id}` superó el 80% de uso de disco.

      **Acción inmediata:**
      - Revisar tablas grandes: `SELECT pg_size_pretty(pg_total_relation_size(relid)), relname FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 20;`
      - Aumentar disco en TF: incrementar `disk_size` en el módulo cloud-sql y aplicar.
      - Los backups y logs WAL (PITR) también consumen espacio — verificar retención.
    EOT
    mime_type = "text/markdown"
  }

  user_labels = var.labels
}

# ── Alerta: conexiones activas Cloud SQL > 80% de max_connections ─────────────
# Métrica: cloudsql.googleapis.com/database/postgresql/num_backends
# Métrica oficial GCP para PostgreSQL — equivalente a pg_stat_activity count.
# Disponible desde el primer arranque (GAUGE, 60s). Ref: cloud.google.com/sql/docs/postgres/admin-api/metrics
#
# IMPORTANTE — métricas que NO funcionan para esta alerta:
#   - num_connections: falla con Error 404 si la instancia acaba de reiniciar (requiere datos previos)
#   - alert_strategy.notification_rate_limit: solo aplica a condition_matched_log, NO a condition_threshold

resource "google_monitoring_alert_policy" "cloudsql_connections" {
  project      = var.project_id
  display_name = "Cloud SQL — Conexiones activas altas (${var.cloudsql_instance_id})"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "num_backends > 80% de max_connections (${var.cloudsql_max_connections})"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND resource.labels.database_id = "${var.project_id}:${var.cloudsql_instance_id}"
        AND metric.type = "cloudsql.googleapis.com/database/postgresql/num_backends"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = floor(var.cloudsql_max_connections * 0.8)
      duration        = "120s" # 2 min sostenido — evita alertas fugaces por spikes de startup

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_SUM" # suma backends de todas las DBs de la instancia
        group_by_fields      = ["resource.labels.database_id"]
      }
    }
  }

  alert_strategy {
    # notification_rate_limit no aplica a condition_threshold (solo a condition_matched_log).
    # auto_close: cierra el incidente automáticamente si la condición no se dispara en 30 min.
    auto_close = "1800s"
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  documentation {
    content   = <<-EOT
      ## Conexiones de base de datos al límite

      La instancia `${var.cloudsql_instance_id}` superó el **${floor(var.cloudsql_max_connections * 0.8)} conexiones activas**
      (80% de `max_connections = ${var.cloudsql_max_connections}`).

      ### Diagnóstico inmediato

      1. **Ver conexiones activas por usuario/servicio (via Auth Proxy local):**
         ```bash
         # Tunnel local: scripts/dev-connect.sh (puerto 5432)
         psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev \
           -c "SELECT usename, count(*) FROM pg_stat_activity GROUP BY usename ORDER BY count DESC;"
         ```

      2. **Ver estado completo del pool:**
         ```bash
         psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev \
           -c "SELECT usename, application_name, state, count(*) FROM pg_stat_activity GROUP BY 1,2,3 ORDER BY count DESC LIMIT 20;"
         ```

      3. **Ver max_connections configurado en la instancia:**
         ```bash
         psql -h 127.0.0.1 -p 5432 -U postgres -d finance-dev \
           -c "SELECT current_setting('max_connections');"
         ```

      4. **Alternativa sin tunnel — via gcloud SQL:**
         ```bash
         gcloud sql connect ${var.cloudsql_instance_id} --user=postgres \
           --project=${var.project_id} --database=finance-dev
         ```

      ### Causas comunes

      - **Npgsql MaxPoolSize no configurado:** Default de Npgsql = 100 conexiones por string de conexión.
        Con 6 servicios × 1 pod × pool default = potencial de 600 conexiones. `db-f1-micro` solo soporta ${var.cloudsql_max_connections}.
      - **OutboxProcessor + app pool:** Cada servicio abre conexiones del pool principal + el BackgroundService de Outbox.
      - **Conexiones idle no retornadas:** Transacciones largas o leaks de `DbContext`.

      ### Fix inmediato (sin reiniciar la instancia)

      **Agregar `Maximum Pool Size=5` en la connection string de cada servicio** en Secret Manager:
      ```
      Host=127.0.0.1;Port=5432;Database=finance-dev;Username=<user>;Password=<pwd>;Maximum Pool Size=5;
      ```
      Actualizar cada secret + re-deploy. Con 6 servicios × 5 = 30 — todavía al límite; usar 3 o migrar tier.

      ### Fix estructural

      **Opción A — Upgrade de tier (recomendado):**
      En `environments/dev.yaml`:
      ```yaml
      database:
        tier: db-g1-small  # max_connections ≈ 50 (antes db-f1-micro = 25)
      ```
      Actualizar también `cloudsql_max_connections` en el módulo de monitoreo. Requiere restart de la instancia (~2 min downtime).

      **Opción B — Flag max_connections en Cloud SQL:**
      En `terraform/modules/cloud-sql/main.tf` bajo `settings.database_flags`:
      ```hcl
      database_flags {
        name  = "max_connections"
        value = "50"
      }
      ```
      También requiere restart.

      **Opción C — PgBouncer:** Connection pooler a nivel de infraestructura.
      Más complejo, pero permite muchos clientes con pocas conexiones reales a PostgreSQL.
    EOT
    mime_type = "text/markdown"
  }

  user_labels = var.labels
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "notification_channel_name" {
  value       = google_monitoring_notification_channel.email.name
  description = "Nombre del canal de notificación para referenciar en otras alertas"
}
