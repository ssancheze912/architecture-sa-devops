#!/usr/bin/env bash
# scripts/dev-connect.sh — Conectividad local a los ambientes de Business Financiero
#
# Uso (un solo comando):
#   source ./scripts/dev-connect.sh
#
# Eso es todo. El script:
#   - Abre el túnel SQL DEV → localhost:5432  (Cloud SQL Auth Proxy)
#   - Abre el túnel SQL QA  → localhost:5434  (kubectl port-forward → pod socat → PSC)
#   - Registra un hook de shell que detecta el directorio y carga
#     ConnectionStrings__DefaultConnection automáticamente.
#     dotnet run / docker run funcionan sin comandos extra.
#
# Para cerrar los túneles y limpiar MAN:
#   dev-disconnect
#
# Servicios accesibles via Gateway (sin túnel ni kubectl):
#   https://finance.siesacloud.dev/api/access-manager/*      → Access Manager (DEV)
#   https://finance.siesacloud.dev/api/segments/*            → Segments (DEV)
#   https://finance.siesacloud.dev/api/base-config/*         → Base Config (DEV)
#   https://finance.siesacloud.dev/api/third-party/*         → Third Party (DEV)
#   https://finance.siesacloud.dev/api/accounting/*          → Accounting (DEV)
#   https://finance.siesacloud.dev/api/liquid-tax/*          → Liquid Tax (DEV)
#   https://finance.siesacloud.dev/observability/jaeger      → Jaeger UI (trazas)
#   https://finance-qa.siesacloud.dev/api/access-manager/*  → Access Manager (QA)
#   https://finance-qa.siesacloud.dev/api/segments/*         → Segments (QA)
#
# Prerrequisitos:
#   gcloud, cloud-sql-proxy, kubectl
#   Roles GCP requeridos:
#     roles/cloudsql.client              → Cloud SQL Auth Proxy (DEV)
#     roles/secretmanager.secretAccessor → leer credenciales de DB
#     roles/container.admin              → actualizar Master Authorized Networks
#

# ── Detectar si el script está siendo sourced ─────────────────────────────────
_dev_is_sourced() {
  [[ -n "${BASH_VERSION:-}" && "${BASH_SOURCE[0]}" != "${0}" ]] ||
  [[ -n "${ZSH_VERSION:-}"  && "${ZSH_EVAL_CONTEXT:-}" == *:file* ]]
}

# set -euo pipefail solo cuando no es sourced (evita cerrar la terminal en errores)
if ! _dev_is_sourced; then
  set -euo pipefail
fi

# ── Config ────────────────────────────────────────────────────────────────────
# Quitar atributo readonly de ejecuciones anteriores (permite re-sourcear)
for _dc_v in _DC_PROJECT _DC_REGION _DC_CLOUDSQL_INSTANCE _DC_DOMAIN _DC_CLUSTER \
             _DC_PORT_SQL _DC_DB_SECRET _DC_ENV_FILE _DC_ENV_UPDATED_FLAG _DC_REFRESH_INTERVAL \
             _DC_QA_PROJECT _DC_QA_CLUSTER _DC_QA_PSC_IP _DC_QA_PORT_SQL _DC_QA_DB \
             _DC_QA_DOMAIN _DC_QA_SOCAT_POD; do
  [[ -n "${ZSH_VERSION:-}"  ]] && typeset +r "$_dc_v" 2>/dev/null || true
  [[ -n "${BASH_VERSION:-}" ]] && declare +r "$_dc_v" 2>/dev/null || true
done
unset _dc_v

# DEV
_DC_PROJECT="prj-sie-fin-financiero-dev"
_DC_REGION="us-east1"
_DC_CLOUDSQL_INSTANCE="${_DC_PROJECT}:${_DC_REGION}:pgsql-fin-sandbox-dev"
_DC_DOMAIN="finance.siesacloud.dev"
_DC_CLUSTER="gke-sie-fin-sandbox-dev"
_DC_PORT_SQL=5432
_DC_DB_SECRET="dev-sandbox-db-connection"
_DC_ENV_FILE="$HOME/.financiero-dev.env"
_DC_ENV_UPDATED_FLAG="${_DC_ENV_FILE}.updated"
# Intervalo de refresco del secreto en segundos (default: 30 min)
_DC_REFRESH_INTERVAL="${DEV_CONNECT_REFRESH_INTERVAL:-1800}"

# QA — conectividad via kubectl port-forward → pod socat → PSC (sin IP pública)
_DC_QA_PROJECT="prj-sie-fin-financiero-qas"
_DC_QA_CLUSTER="gke-sie-fin-financiero-qa"
_DC_QA_PSC_IP="10.20.39.250"
_DC_QA_PORT_SQL=5434
_DC_QA_DB="finance-qa"
_DC_QA_DOMAIN="finance-qa.siesacloud.dev"
_DC_QA_SOCAT_POD="sql-qa-proxy"
# Secrets QA en orden de preferencia (todos tienen el mismo usuario 'dev' y contraseña)
_DC_QA_DB_SECRETS="segments-qa-db-connection baseconfig-qa-db-connection accmgr-qa-db-connection acct-qa-db-connection liquid-tax-qa-db-connection tprt-qa-db-connection"

_DC_LOCAL_IP=""
_DC_TUNNEL_PID=""
_DC_REFRESH_PID=""
_DC_QA_TUNNEL_PID=""

# ── Colores ───────────────────────────────────────────────────────────────────
_DC_RED='\033[0;31m'
_DC_GREEN='\033[0;32m'
_DC_YELLOW='\033[1;33m'
_DC_BLUE='\033[0;34m'
_DC_CYAN='\033[0;36m'
_DC_BOLD='\033[1m'
_DC_NC='\033[0m'

_dc_info()  { echo -e "${_DC_BLUE}[INFO]${_DC_NC}  $*"; }
_dc_ok()    { echo -e "${_DC_GREEN}[ OK ]${_DC_NC}  $*"; }
_dc_warn()  { echo -e "${_DC_YELLOW}[WARN]${_DC_NC}  $*"; }
_dc_error() { echo -e "${_DC_RED}[ERR ]${_DC_NC}  $*" >&2; }
_dc_step()  { echo -e "\n${_DC_BOLD}${_DC_CYAN}▸ $*${_DC_NC}"; }

# ── Master Authorized Networks — DEV ─────────────────────────────────────────
_dc_add_to_man() {
  _dc_step "Agregando IP local a Master Authorized Networks (DEV)..."
  # Forzar IPv4 — GKE Master Authorized Networks solo acepta CIDRs IPv4
  _DC_LOCAL_IP=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4 -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null \
    || curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null)
  # Quitar espacios/saltos de línea residuales
  _DC_LOCAL_IP=$(echo "$_DC_LOCAL_IP" | tr -d '[:space:]')

  if [[ -z "$_DC_LOCAL_IP" ]]; then
    _dc_warn "No se pudo obtener la IP pública IPv4 — kubectl no estará disponible"
    return
  fi

  # Validar que sea IPv4 válida antes de intentar agregar a MAN
  if ! echo "$_DC_LOCAL_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    _dc_warn "IP detectada no es IPv4 válida (${_DC_LOCAL_IP}) — MAN requiere IPv4, kubectl no estará disponible"
    return
  fi

  _dc_info "IP pública detectada: ${_DC_BOLD}${_DC_LOCAL_IP}${_DC_NC}"

  local current_cidrs
  current_cidrs=$(gcloud container clusters describe "$_DC_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_PROJECT" \
    --format="value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)" 2>/dev/null \
    | tr ';' ',' | tr '\n' ',')

  local new_cidr="${_DC_LOCAL_IP}/32"

  if echo "$current_cidrs" | grep -q "$new_cidr"; then
    _dc_ok "IP ya está en MAN DEV — kubectl disponible"
    return
  fi

  local updated_cidrs="${current_cidrs}${new_cidr}"
  updated_cidrs=$(echo "$updated_cidrs" | sed 's/^,//' | sed 's/,$//')

  gcloud container clusters update "$_DC_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_PROJECT" \
    --enable-master-authorized-networks \
    --master-authorized-networks="$updated_cidrs" \
    --quiet 2>/dev/null && _dc_ok "IP ${_DC_BOLD}${new_cidr}${_DC_NC} agregada a MAN DEV" \
    || _dc_warn "No se pudo actualizar MAN DEV — verifica roles/container.admin"

  gcloud container clusters get-credentials "$_DC_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_PROJECT" \
    --quiet 2>/dev/null && _dc_ok "kubeconfig DEV actualizado" || true
}

_dc_remove_from_man() {
  if [[ -z "$_DC_LOCAL_IP" ]]; then return; fi

  _dc_info "Removiendo ${_DC_LOCAL_IP}/32 de MAN DEV..."

  local current_cidrs
  current_cidrs=$(gcloud container clusters describe "$_DC_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_PROJECT" \
    --format="value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)" 2>/dev/null \
    | tr ';' '\n' | grep -v "^${_DC_LOCAL_IP}/32$" | tr '\n' ',' | sed 's/,$//')

  if [[ -z "$current_cidrs" ]]; then
    _dc_warn "No quedan CIDRs en MAN DEV tras remover la IP — se omite la actualización"
    return
  fi

  gcloud container clusters update "$_DC_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_PROJECT" \
    --enable-master-authorized-networks \
    --master-authorized-networks="$current_cidrs" \
    --quiet 2>/dev/null && _dc_ok "IP ${_DC_LOCAL_IP}/32 removida de MAN DEV" \
    || _dc_warn "No se pudo remover IP de MAN DEV — hazlo manualmente en GCP Console"
}

# ── Master Authorized Networks — QA ──────────────────────────────────────────
_dc_qa_add_to_man() {
  if [[ -z "$_DC_LOCAL_IP" ]]; then
    _dc_warn "IP local no detectada — omitiendo MAN QA"
    return
  fi

  _dc_step "Agregando IP local a Master Authorized Networks (QA)..."

  local current_cidrs
  current_cidrs=$(gcloud container clusters describe "$_DC_QA_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_QA_PROJECT" \
    --format="value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)" 2>/dev/null \
    | tr ';' ',' | tr '\n' ',')

  local new_cidr="${_DC_LOCAL_IP}/32"

  if echo "$current_cidrs" | grep -q "$new_cidr"; then
    _dc_ok "IP ya está en MAN QA — kubectl QA disponible"
  else
    local updated_cidrs="${current_cidrs}${new_cidr}"
    updated_cidrs=$(echo "$updated_cidrs" | sed 's/^,//' | sed 's/,$//')

    gcloud container clusters update "$_DC_QA_CLUSTER" \
      --region "$_DC_REGION" \
      --project "$_DC_QA_PROJECT" \
      --enable-master-authorized-networks \
      --master-authorized-networks="$updated_cidrs" \
      --quiet 2>/dev/null && _dc_ok "IP ${_DC_BOLD}${new_cidr}${_DC_NC} agregada a MAN QA" \
      || { _dc_warn "No se pudo actualizar MAN QA — túnel QA no disponible"; return 1; }
  fi

  gcloud container clusters get-credentials "$_DC_QA_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_QA_PROJECT" \
    --quiet 2>/dev/null && _dc_ok "kubeconfig QA actualizado" || true
}

_dc_qa_remove_from_man() {
  if [[ -z "$_DC_LOCAL_IP" ]]; then return; fi

  _dc_info "Removiendo ${_DC_LOCAL_IP}/32 de MAN QA..."

  local current_cidrs
  current_cidrs=$(gcloud container clusters describe "$_DC_QA_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_QA_PROJECT" \
    --format="value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)" 2>/dev/null \
    | tr ';' '\n' | grep -v "^${_DC_LOCAL_IP}/32$" | tr '\n' ',' | sed 's/,$//')

  if [[ -z "$current_cidrs" ]]; then
    _dc_warn "No quedan CIDRs en MAN QA tras remover la IP — se omite la actualización"
    return
  fi

  gcloud container clusters update "$_DC_QA_CLUSTER" \
    --region "$_DC_REGION" \
    --project "$_DC_QA_PROJECT" \
    --enable-master-authorized-networks \
    --master-authorized-networks="$current_cidrs" \
    --quiet 2>/dev/null && _dc_ok "IP ${_DC_LOCAL_IP}/32 removida de MAN QA" \
    || _dc_warn "No se pudo remover IP de MAN QA — hazlo manualmente en GCP Console"
}

# ── Prerrequisitos ────────────────────────────────────────────────────────────
_dc_check_prereqs() {
  _dc_step "Verificando prerrequisitos..."
  local missing=()

  for cmd in gcloud cloud-sql-proxy kubectl; do
    if command -v "$cmd" &>/dev/null; then
      _dc_ok "$cmd → $(command -v "$cmd")"
    else
      _dc_error "$cmd no encontrado"
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    _dc_error "Faltan herramientas: ${missing[*]}"
    echo ""
    echo "  gcloud:          https://cloud.google.com/sdk/docs/install"
    echo "  cloud-sql-proxy: https://cloud.google.com/sql/docs/postgres/connect-auth-proxy#install"
    echo "  kubectl:         https://kubernetes.io/docs/tasks/tools/"
    return 1
  fi
}

# ── Autenticación GCP ─────────────────────────────────────────────────────────
_dc_check_auth() {
  _dc_step "Verificando autenticación GCP..."
  local account
  account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)

  if [[ -z "$account" ]]; then
    _dc_warn "No hay sesión activa. Iniciando login..."
    gcloud auth login --no-launch-browser
    gcloud auth application-default login --no-launch-browser
  else
    _dc_ok "Autenticado como: ${_DC_BOLD}$account${_DC_NC}"
  fi

  if ! gcloud auth application-default print-access-token &>/dev/null 2>&1; then
    _dc_warn "Application Default Credentials no configuradas. Ejecutando login ADC..."
    gcloud auth application-default login --no-launch-browser
  fi
}

# ── Variables de entorno de base de datos — DEV ───────────────────────────────
_dc_generate_db_env() {
  _dc_step "Obteniendo credenciales de base de datos (DEV)..."

  local raw_conn
  raw_conn=$(gcloud secrets versions access latest \
    --secret="$_DC_DB_SECRET" \
    --project="$_DC_PROJECT" 2>/dev/null) || {
    _dc_warn "No se pudo leer el secret '${_DC_DB_SECRET}' — verifica roles/secretmanager.secretAccessor"
    return 1
  }

  local db_pass
  db_pass=$(echo "$raw_conn" | sed 's/.*[Pp]assword=\([^;]*\).*/\1/')

  if [[ -z "$db_pass" ]]; then
    _dc_warn "No se encontró el campo Password en el secret '${_DC_DB_SECRET}'"
    return 1
  fi

  # Exportar en la sesión actual
  export DB_FINANCE_DEV_PASSWORD="$db_pass"

  # Archivo compartido (shell / docker / VS Code genérico)
  cat > "$_DC_ENV_FILE" <<EOF
# Business Financiero — Variables de entorno de base de datos (desarrollo local)
# Generado por scripts/dev-connect.sh — $(date '+%Y-%m-%d %H:%M:%S')
# NO editar manualmente. Para regenerar: source ./scripts/dev-connect.sh

DB_FINANCE_DEV_PASSWORD=${db_pass}
EOF
  chmod 600 "$_DC_ENV_FILE"

  # Archivos por servicio con ConnectionStrings__DefaultConnection completa.
  # VS Code envFile carga estas variables directamente al proceso — sin ${env:...}.
  local _dc_base="Host=127.0.0.1;Port=5432;Database=finance-dev;Username=dev;Password=${db_pass}"
  local _dc_suffix="SSL Mode=Disable;GssEncryptionMode=Disable"
  local _dc_hdr="# Generado por dev-connect.sh — $(date '+%Y-%m-%d %H:%M:%S') — NO editar"
  # Lista "servicio:schema" — compatible bash y zsh
  local _dc_entry _dc_svc _dc_schema _dc_svc_file
  for _dc_entry in \
      "access-manager:access_manager" \
      "segments:segment" \
      "base-config:base_config" \
      "third-party:tprt" \
      "accounting:acct" \
      "liquid-tax:liquid_tax"; do
    _dc_svc="${_dc_entry%%:*}"
    _dc_schema="${_dc_entry##*:}"
    _dc_svc_file="$HOME/.financiero-${_dc_svc}.env"
    cat > "$_dc_svc_file" <<EOF
${_dc_hdr}
DB_FINANCE_DEV_PASSWORD=${db_pass}
ConnectionStrings__DefaultConnection=${_dc_base};Search Path=${_dc_schema};${_dc_suffix}
EOF
    chmod 600 "$_dc_svc_file"
  done

  _dc_ok "Credenciales DEV exportadas — sesión, ${_DC_BOLD}${_DC_ENV_FILE}${_DC_NC} y archivos por servicio"
}

# ── Variables de entorno de base de datos — QA ───────────────────────────────
_dc_generate_qa_db_env() {
  _dc_step "Obteniendo credenciales de base de datos (QA)..."

  local raw_conn qa_pass secret
  for secret in $_DC_QA_DB_SECRETS; do
    raw_conn=$(gcloud secrets versions access latest \
      --secret="$secret" \
      --project="$_DC_QA_PROJECT" 2>/dev/null) && break
    raw_conn=""
  done

  if [[ -z "$raw_conn" ]]; then
    _dc_warn "No se encontró ningún secret QA accesible — verifica roles/secretmanager.secretAccessor en ${_DC_QA_PROJECT}"
    return 1
  fi

  qa_pass=$(echo "$raw_conn" | sed 's/.*[Pp]assword=\([^;]*\).*/\1/')

  if [[ -z "$qa_pass" ]]; then
    _dc_warn "No se encontró el campo Password en el secret QA '${secret}'"
    return 1
  fi

  export DB_FINANCE_QA_PASSWORD="$qa_pass"

  local _qa_env_file="$HOME/.financiero-qa.env"
  cat > "$_qa_env_file" <<EOF
# Business Financiero — Variables de entorno de base de datos (QA)
# Generado por scripts/dev-connect.sh — $(date '+%Y-%m-%d %H:%M:%S')
# Secret fuente: ${secret}
# NO editar manualmente.

DB_FINANCE_QA_PASSWORD=${qa_pass}
EOF
  chmod 600 "$_qa_env_file"

  _dc_ok "Credenciales QA exportadas (secret: ${_DC_BOLD}${secret}${_DC_NC})"
}

# ── Refresco periódico del secreto DEV ───────────────────────────────────────
# Corre en background. Si la contraseña cambió en Secret Manager, actualiza
# ~/.financiero-dev.env y deja un flag para que el hook del shell la recargue.
_dc_refresh_loop() {
  while true; do
    sleep "$_DC_REFRESH_INTERVAL"

    local raw_conn db_pass
    raw_conn=$(gcloud secrets versions access latest \
      --secret="$_DC_DB_SECRET" \
      --project="$_DC_PROJECT" 2>/dev/null) || continue

    db_pass=$(echo "$raw_conn" | sed 's/.*[Pp]assword=\([^;]*\).*/\1/')
    [[ -z "$db_pass" ]] && continue

    # Solo actualizar si la contraseña cambió
    local current_pass="${DB_FINANCE_DEV_PASSWORD:-}"
    if [[ "$db_pass" != "$current_pass" ]]; then
      local header="# Actualizado por dev-connect.sh — $(date '+%Y-%m-%d %H:%M:%S') (secreto rotado)"
      cat > "$_DC_ENV_FILE" <<EOF
${header}
DB_FINANCE_DEV_PASSWORD=${db_pass}
EOF
      chmod 600 "$_DC_ENV_FILE"

      # Regenerar archivos por servicio con la nueva contraseña
      local _r_base="Host=127.0.0.1;Port=5432;Database=finance-dev;Username=dev;Password=${db_pass}"
      local _r_sfx="SSL Mode=Disable;GssEncryptionMode=Disable"
      local _r_entry _r_svc _r_schema _r_file
      for _r_entry in \
          "access-manager:access_manager" \
          "segments:segment" \
          "base-config:base_config" \
          "third-party:tprt" \
          "accounting:acct" \
          "liquid-tax:liquid_tax"; do
        _r_svc="${_r_entry%%:*}"
        _r_schema="${_r_entry##*:}"
        _r_file="$HOME/.financiero-${_r_svc}.env"
        cat > "$_r_file" <<EOF
${header}
DB_FINANCE_DEV_PASSWORD=${db_pass}
ConnectionStrings__DefaultConnection=${_r_base};Search Path=${_r_schema};${_r_sfx}
EOF
        chmod 600 "$_r_file"
      done

      touch "$_DC_ENV_UPDATED_FLAG"
    fi
  done
}

# Hook registrado en el shell (PROMPT_COMMAND / precmd): recarga ~/.financiero-dev.env
# automáticamente antes del próximo prompt si el secreto fue rotado.
_dc_check_env_update() {
  if [[ -f "$_DC_ENV_UPDATED_FLAG" ]]; then
    rm -f "$_DC_ENV_UPDATED_FLAG"
    # shellcheck source=/dev/null
    source "$_DC_ENV_FILE"
    echo -e "\n${_DC_YELLOW}[dev-connect]${_DC_NC} Secreto rotado — DB_FINANCE_DEV_PASSWORD actualizada"
    _dc_print_summary
    _dc_print_db_box
  fi
}

# ── Túnel QA via kubectl port-forward → pod socat → PSC ──────────────────────
_dc_start_qa_tunnel() {
  _dc_step "Iniciando túnel SQL QA (kubectl → socat → PSC ${_DC_QA_PSC_IP}:5432)..."

  # Eliminar pod socat anterior si quedó huérfano
  kubectl delete pod "$_DC_QA_SOCAT_POD" -n default --ignore-not-found=true \
    >/dev/null 2>&1 || true

  # Crear pod socat que proxifica TCP al endpoint PSC de Cloud SQL.
  # alpine/socat tiene 'socat' como ENTRYPOINT → pasar solo los argumentos, sin repetir 'socat'.
  # --overrides incluye resources.requests obligatorio en GKE Autopilot.
  local _socat_json
  _socat_json=$(printf '{
    "spec": {
      "containers": [{
        "name": "%s",
        "image": "alpine/socat",
        "args": ["TCP-LISTEN:5432,fork,reuseaddr", "TCP:%s:5432"],
        "resources": {
          "requests": {"cpu": "100m", "memory": "64Mi"},
          "limits":   {"cpu": "200m", "memory": "128Mi"}
        }
      }]
    }
  }' "$_DC_QA_SOCAT_POD" "$_DC_QA_PSC_IP")

  kubectl run "$_DC_QA_SOCAT_POD" \
    --image=alpine/socat \
    --restart=Never \
    -n default \
    --overrides="$_socat_json" \
    >/dev/null 2>&1

  # Esperar que el pod entre en Ready (máx 120s — primera vez puede tardarse por image pull)
  _dc_info "Esperando que el pod socat esté listo (máx 120s)..."
  if ! kubectl wait "pod/${_DC_QA_SOCAT_POD}" \
      -n default \
      --for=condition=Ready \
      --timeout=120s 2>/dev/null; then
    _dc_warn "Pod socat QA no alcanzó Ready — túnel QA no disponible"
    _dc_warn "  Estado actual: $(kubectl get pod ${_DC_QA_SOCAT_POD} -n default --no-headers 2>/dev/null | awk '{print $3}')"
    _dc_warn "  Logs: kubectl logs ${_DC_QA_SOCAT_POD} -n default"
    return 1
  fi

  _dc_ok "Pod socat QA en Running"

  # Port-forward del pod al puerto local
  kubectl port-forward "pod/${_DC_QA_SOCAT_POD}" "${_DC_QA_PORT_SQL}:5432" \
    -n default \
    >/tmp/sql-qa-proxy.log 2>&1 &
  _DC_QA_TUNNEL_PID=$!

  # Esperar hasta 15s a que el puerto local esté disponible
  local ok=false
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if (echo > /dev/tcp/127.0.0.1/$_DC_QA_PORT_SQL) 2>/dev/null; then
      ok=true
      break
    fi
  done
  unset _i

  if [[ "$ok" == "true" ]]; then
    _dc_ok "Túnel QA → ${_DC_BOLD}localhost:${_DC_QA_PORT_SQL}${_DC_NC} (port-forward → pod socat)"
  else
    _dc_warn "Túnel QA no respondió en 15s — revisa /tmp/sql-qa-proxy.log"
  fi
}

_dc_stop_qa_tunnel() {
  if [[ -n "$_DC_QA_TUNNEL_PID" ]]; then
    kill "$_DC_QA_TUNNEL_PID" 2>/dev/null && _dc_ok "Túnel QA (port-forward) cerrado" || true
    _DC_QA_TUNNEL_PID=""
  fi
  # Eliminar pod socat del cluster QA
  if kubectl get pod "$_DC_QA_SOCAT_POD" -n default --no-headers 2>/dev/null | grep -q .; then
    kubectl delete pod "$_DC_QA_SOCAT_POD" -n default --ignore-not-found=true \
      >/dev/null 2>&1 && _dc_ok "Pod socat QA eliminado" || true
  fi
}

# ── Setup automático de perfiles de shell ────────────────────────────────────
# Agrega la carga de ~/.financiero-dev.env a cada perfil que exista.
# Es idempotente: si la línea ya está, no la duplica.
_dc_setup_shell_profiles() {
  _dc_step "Configurando perfiles de shell..."

  local marker='financiero-dev.env'
  local sh_line='[ -f ~/.financiero-dev.env ] && { set -a; source ~/.financiero-dev.env; set +a; }'
  local sh_comment='# Business Financiero — credenciales locales de base de datos'
  # Bloque del hook auto-use — se inyecta en los perfiles zsh/bash
  local auto_use_marker='_financiero_auto_use'
  local auto_use_block
  # shellcheck disable=SC2016
  auto_use_block='# Business Financiero — hook: carga ConnectionStrings__DefaultConnection al entrar a un repo
_financiero_auto_use() {
  local svc=""
  case "${PWD:-}" in
    *business-access-manager*)             svc="access-manager" ;;
    *financiero-segments-service*)         svc="segments" ;;
    *financiero-base-config*)              svc="base-config" ;;
    *financiero-third-party-service*)      svc="third-party" ;;
    *financiero-accounting-service*)       svc="accounting" ;;
    *financiero-liquid-tax-service*)       svc="liquid-tax" ;;
  esac
  [ -z "$svc" ] && return
  local f="$HOME/.financiero-${svc}.env"
  [ -f "$f" ] || return
  [ "${_FINANCIERO_ACTIVE_SVC:-}" = "$svc" ] && return
  local _fau_line _fau_key _fau_val
  while IFS= read -r _fau_line || [ -n "$_fau_line" ]; do
    case "$_fau_line" in '"'"'#'"'"'*|'"'"''"'"') continue ;; esac
    _fau_key="${_fau_line%%=*}"
    _fau_val="${_fau_line#*=}"
    [ -z "$_fau_key" ] && continue
    export "${_fau_key}=${_fau_val}"
  done < "$f"
  unset _fau_line _fau_key _fau_val
  _FINANCIERO_ACTIVE_SVC="$svc"
}
if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _financiero_auto_use
elif [ -n "${BASH_VERSION:-}" ]; then
  PROMPT_COMMAND="_financiero_auto_use${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
_financiero_auto_use'
  local added=0

  # Helper: asegura que el archivo sea escribible.
  # Si es nuestro pero está en solo lectura, lo corrige con chmod u+w.
  # Si es de otro usuario, no podemos tocarlo → retorna 1.
  _dc_ensure_writable() {
    local file="$1"
    [[ -w "$file" ]] && return 0
    local file_uid; file_uid=$(stat -f '%u' "$file" 2>/dev/null || stat -c '%u' "$file" 2>/dev/null)
    if [[ "$file_uid" == "$(id -u)" ]]; then
      chmod u+w "$file" && return 0
    fi
    return 1
  }
  _dc_can_write() {
    [[ -f "$1" ]] && _dc_ensure_writable "$1"
  }
  _dc_skip_no_write() { _dc_warn "$(basename "$1") — pertenece a otro usuario, omitiendo"; }

  # ── zsh / bash (misma sintaxis POSIX) ────────────────────────────────────────
  local profile
  for profile in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [[ -f "$profile" ]] || continue
    # Línea de carga básica (~/.financiero-dev.env)
    if grep -q "$marker" "$profile" 2>/dev/null; then
      _dc_ok "$(basename "$profile") — ya configurado"
    elif _dc_can_write "$profile"; then
      { echo ""; echo "$sh_comment"; echo "$sh_line"; } >> "$profile"
      _dc_ok "$(basename "$profile") — línea agregada"
      (( added++ )) || true
    else
      _dc_skip_no_write "$profile"
    fi
    # Hook auto-use (ConnectionStrings automático por directorio)
    if [[ -f "$profile" ]] && ! grep -q "$auto_use_marker" "$profile" 2>/dev/null; then
      if _dc_can_write "$profile"; then
        { echo ""; echo "$auto_use_block"; } >> "$profile"
        _dc_ok "$(basename "$profile") — hook auto-use agregado"
        (( added++ )) || true
      fi
    fi
  done

  # ── fish ──────────────────────────────────────────────────────────────────────
  local fish_cfg="$HOME/.config/fish/config.fish"
  if [[ -f "$fish_cfg" ]]; then
    if grep -q "$marker" "$fish_cfg" 2>/dev/null; then
      _dc_ok "config.fish — ya configurado"
    elif _dc_can_write "$fish_cfg"; then
      cat >> "$fish_cfg" <<'EOF'

# Business Financiero — credenciales locales de base de datos
if test -f ~/.financiero-dev.env
    while read -l line
        if not string match -q '#*' -- $line; and string match -q '*=*' -- $line
            set -gx (string split -m1 = -- $line)[1] (string split -m1 = -- $line)[2]
        end
    end < ~/.financiero-dev.env
end
EOF
      _dc_ok "config.fish — bloque agregado"
      (( added++ )) || true
    else
      _dc_skip_no_write "$fish_cfg"
    fi
    # Hook auto-use para fish (--on-variable PWD dispara al cambiar de directorio)
    if ! grep -q "$auto_use_marker" "$fish_cfg" 2>/dev/null && _dc_can_write "$fish_cfg"; then
      cat >> "$fish_cfg" <<'EOF'

# Business Financiero — hook: carga ConnectionStrings__DefaultConnection al entrar a un repo
function _financiero_auto_use --on-variable PWD
    set -l svc ""
    switch $PWD
        case "*business-access-manager*"
            set svc "access-manager"
        case "*financiero-segments-service*"
            set svc "segments"
        case "*financiero-base-config*"
            set svc "base-config"
        case "*financiero-third-party-service*"
            set svc "third-party"
        case "*financiero-accounting-service*"
            set svc "accounting"
        case "*financiero-liquid-tax-service*"
            set svc "liquid-tax"
    end
    test -z "$svc" && return
    set -l f "$HOME/.financiero-$svc.env"
    test -f $f || return
    test "$_FINANCIERO_ACTIVE_SVC" = "$svc" && return
    while read -l line
        if not string match -q '#*' -- $line; and string match -q '*=*' -- $line
            set -gx (string split -m1 = -- $line)[1] (string split -m1 = -- $line)[2]
        end
    end < $f
    set -gx _FINANCIERO_ACTIVE_SVC $svc
end
EOF
      _dc_ok "config.fish — hook auto-use agregado"
      (( added++ )) || true
    fi
  fi

  # ── nushell ───────────────────────────────────────────────────────────────────
  local nu_cfg="$HOME/.config/nushell/env.nu"
  if [[ -f "$nu_cfg" ]]; then
    if grep -q "$marker" "$nu_cfg" 2>/dev/null; then
      _dc_ok "env.nu (nushell) — ya configurado"
    elif _dc_can_write "$nu_cfg"; then
      cat >> "$nu_cfg" <<'EOF'

# Business Financiero — credenciales locales de base de datos
if (($env.HOME | path join ".financiero-dev.env") | path exists) {
    open ($env.HOME | path join ".financiero-dev.env")
    | lines
    | where { |l| ($l | str trim | str length) > 0 and not ($l | str starts-with "#") }
    | each { |l|
        let kv = ($l | split row "=" --max 2)
        load-env { ($kv | first | str trim): ($kv | last) }
    }
    | ignore
}
EOF
      _dc_ok "env.nu (nushell) — bloque agregado"
      (( added++ )) || true
    else
      _dc_skip_no_write "$nu_cfg"
    fi
  fi

  # ── PowerShell (pwsh) ─────────────────────────────────────────────────────────
  local pwsh_cfg="$HOME/.config/powershell/Microsoft.PowerShell_profile.ps1"
  if [[ -f "$pwsh_cfg" ]]; then
    if grep -q "$marker" "$pwsh_cfg" 2>/dev/null; then
      _dc_ok "Microsoft.PowerShell_profile.ps1 — ya configurado"
    elif _dc_can_write "$pwsh_cfg"; then
      cat >> "$pwsh_cfg" <<'EOF'

# Business Financiero — credenciales locales de base de datos
if (Test-Path "$HOME/.financiero-dev.env") {
    Get-Content "$HOME/.financiero-dev.env" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        [System.Environment]::SetEnvironmentVariable($kv[0].Trim(), $kv[1].Trim(), 'Process')
    }
}
EOF
      _dc_ok "Microsoft.PowerShell_profile.ps1 — bloque agregado"
      (( added++ )) || true
    else
      _dc_skip_no_write "$pwsh_cfg"
    fi
  fi

  # ── elvish ────────────────────────────────────────────────────────────────────
  local elv_cfg="$HOME/.config/elvish/rc.elv"
  if [[ -f "$elv_cfg" ]]; then
    if grep -q "$marker" "$elv_cfg" 2>/dev/null; then
      _dc_ok "rc.elv (elvish) — ya configurado"
    elif _dc_can_write "$elv_cfg"; then
      cat >> "$elv_cfg" <<'EOF'

# Business Financiero — credenciales locales de base de datos
if (path:is-regular ~/.financiero-dev.env) {
    cat ~/.financiero-dev.env | each {|line|
        if (and (!=s $line '') (not (str:has-prefix $line '#'))) {
            var kv = [(str:split &max=2 = $line)]
            set-env $kv[0] $kv[1]
        }
    }
}
EOF
      _dc_ok "rc.elv (elvish) — bloque agregado"
      (( added++ )) || true
    else
      _dc_skip_no_write "$elv_cfg"
    fi
  fi

  if [[ $added -gt 0 ]]; then
    _dc_info "Abre VS Code desde una terminal nueva (o reinícialo) para que tome efecto."
  fi
}

_dc_register_shell_hook() {
  if [[ -n "${BASH_VERSION:-}" ]]; then
    PROMPT_COMMAND="_dc_check_env_update; _financiero_auto_use${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz add-zsh-hook 2>/dev/null
    add-zsh-hook precmd _dc_check_env_update
    add-zsh-hook precmd _financiero_auto_use
  fi
}

# ── Auto-carga de ConnectionStrings por directorio ────────────────────────────
# Detecta el servicio según $PWD y exporta ConnectionStrings__DefaultConnection.
# Se registra como precmd (zsh) / PROMPT_COMMAND (bash): corre antes de cada prompt.
# Idempotente: si el servicio activo no cambió, no re-lee el archivo.
# IMPORTANTE: parsea el archivo línea a línea — NO usa source/. para evitar que
# los ';' de la connection string sean interpretados como separadores de comando.
_financiero_auto_use() {
  local svc=""
  case "${PWD:-}" in
    *business-access-manager*)             svc="access-manager" ;;
    *financiero-segments-service*)         svc="segments" ;;
    *financiero-base-config*)              svc="base-config" ;;
    *financiero-third-party-service*)      svc="third-party" ;;
    *financiero-accounting-service*)       svc="accounting" ;;
    *financiero-liquid-tax-service*)       svc="liquid-tax" ;;
  esac
  [[ -z "$svc" ]] && return
  local f="$HOME/.financiero-${svc}.env"
  [[ -f "$f" ]] || return
  [[ "${_FINANCIERO_ACTIVE_SVC:-}" == "$svc" ]] && return
  # Parseo manual: split en el primer '=' para preservar ';' y espacios del valor
  local _fau_line _fau_key _fau_val
  while IFS= read -r _fau_line || [[ -n "$_fau_line" ]]; do
    case "$_fau_line" in '#'*|'') continue ;; esac
    _fau_key="${_fau_line%%=*}"
    _fau_val="${_fau_line#*=}"
    [[ -z "$_fau_key" ]] && continue
    export "${_fau_key}=${_fau_val}"
  done < "$f"
  unset _fau_line _fau_key _fau_val
  _FINANCIERO_ACTIVE_SVC="$svc"
}

# ── Box de credenciales de base de datos — DEV ───────────────────────────────
_dc_print_db_box() {
  [[ -z "${DB_FINANCE_DEV_PASSWORD:-}" ]] && return

  local Y="${_DC_BOLD}${_DC_YELLOW}"
  local R="${_DC_NC}"
  local pw="$DB_FINANCE_DEV_PASSWORD"

  # Ancho interior dinámico según longitud de la contraseña (mínimo 46)
  local prefix_len=16   # "  Contraseña:   " = 16 chars
  local needed=$(( prefix_len + ${#pw} + 2 ))
  local w=$(( needed > 46 ? needed : 46 ))
  local border; border=$(printf '%*s' "$w" '' | tr ' ' '═')

  # Función interna: imprime una línea del box con padding exacto
  _dc_db_line() { printf "${Y}║%-${w}s║${R}\n" "$1"; }

  echo ""
  echo -e "${Y}╔${border}╗${R}"
  _dc_db_line "  Base de datos DEV — Credenciales locales"
  _dc_db_line ""
  _dc_db_line "  Host:         127.0.0.1:${_DC_PORT_SQL}"
  _dc_db_line "  Base:         finance-dev"
  _dc_db_line "  Usuario:      dev"
  _dc_db_line "  Contraseña:   ${pw}"
  _dc_db_line ""
  _dc_db_line "  \$DB_FINANCE_DEV_PASSWORD exportada en esta sesión"
  echo -e "${Y}╚${border}╝${R}"

  unset -f _dc_db_line
}

# ── Box de credenciales de base de datos — QA ────────────────────────────────
_dc_print_qa_db_box() {
  [[ -z "${DB_FINANCE_QA_PASSWORD:-}" ]] && return

  local M="${_DC_BOLD}\033[0;35m"   # magenta para distinguir QA de DEV
  local R="${_DC_NC}"
  local pw="$DB_FINANCE_QA_PASSWORD"

  local prefix_len=16
  local needed=$(( prefix_len + ${#pw} + 2 ))
  local w=$(( needed > 46 ? needed : 46 ))
  local border; border=$(printf '%*s' "$w" '' | tr ' ' '═')

  _dc_qa_db_line() { printf "${M}║%-${w}s║${R}\n" "$1"; }

  echo ""
  echo -e "${M}╔${border}╗${R}"
  _dc_qa_db_line "  Base de datos QA — Credenciales locales"
  _dc_qa_db_line ""
  _dc_qa_db_line "  Host:         127.0.0.1:${_DC_QA_PORT_SQL}"
  _dc_qa_db_line "  Base:         finance-qa"
  _dc_qa_db_line "  Usuario:      dev"
  _dc_qa_db_line "  Contraseña:   ${pw}"
  _dc_qa_db_line ""
  _dc_qa_db_line "  \$DB_FINANCE_QA_PASSWORD exportada en esta sesión"
  echo -e "${M}╚${border}╝${R}"

  unset -f _dc_qa_db_line
}

# ── Resumen de conexiones activas ────────────────────────────────────────────
_dc_print_summary() {
  # Interior del box: 78 chars
  local G="${_DC_BOLD}${_DC_GREEN}"
  local R="${_DC_NC}"

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════════════════════════════╗${R}"
  echo -e "${G}║  Conexiones activas                                                          ║${R}"
  echo -e "${G}║                                                                              ║${R}"
  echo -e "${G}║  [SQL] DEV  PostgreSQL  localhost:${_DC_PORT_SQL}  (Cloud SQL Auth Proxy)             ║${R}"
  echo -e "${G}║  [SQL] QA   PostgreSQL  localhost:${_DC_QA_PORT_SQL}  (kubectl port-fwd -> PSC)        ║${R}"
  echo -e "${G}║  [K8S]      kubectl     GKE ${_DC_CLUSTER}                             ║${R}"
  echo -e "${G}║                                                                              ║${R}"
  echo -e "${G}║  [GW DEV]  Access Manager    https://${_DC_DOMAIN}/api/access-manager/  ║${R}"
  echo -e "${G}║  [GW DEV]  Segments          https://${_DC_DOMAIN}/api/segments/        ║${R}"
  echo -e "${G}║  [GW DEV]  Base Config       https://${_DC_DOMAIN}/api/base-config/     ║${R}"
  echo -e "${G}║  [GW DEV]  Third Party       https://${_DC_DOMAIN}/api/third-party/     ║${R}"
  echo -e "${G}║  [GW DEV]  Accounting        https://${_DC_DOMAIN}/api/accounting/      ║${R}"
  echo -e "${G}║  [GW DEV]  Liquid Tax        https://${_DC_DOMAIN}/api/liquid-tax/      ║${R}"
  echo -e "${G}║                                                                              ║${R}"
  echo -e "${G}║  [GW QA]   Access Manager    https://${_DC_QA_DOMAIN}/api/access-manager/  ║${R}"
  echo -e "${G}║  [GW QA]   Segments          https://${_DC_QA_DOMAIN}/api/segments/        ║${R}"
  echo -e "${G}║                                                                              ║${R}"
  echo -e "${G}║  [OBS] Jaeger UI         https://${_DC_DOMAIN}/observability/jaeger ║${R}"
  echo -e "${G}║                                                                              ║${R}"
  echo -e "${G}║  Logs DEV: /tmp/cloudsql-proxy.log   Logs QA: /tmp/sql-qa-proxy.log          ║${R}"
  echo -e "${G}╚══════════════════════════════════════════════════════════════════════════════╝${R}"
}

# ── Función de desconexión (disponible en el shell tras source) ───────────────
dev-disconnect() {
  echo ""
  _dc_step "Cerrando conexiones..."

  # Túnel DEV
  if [[ -n "$_DC_TUNNEL_PID" ]]; then
    kill "$_DC_TUNNEL_PID" 2>/dev/null && _dc_ok "Túnel DEV (Cloud SQL Proxy) cerrado" || true
    _DC_TUNNEL_PID=""
  fi

  # Túnel QA + pod socat
  _dc_stop_qa_tunnel

  # Loop de refresco
  if [[ -n "$_DC_REFRESH_PID" ]]; then
    kill "$_DC_REFRESH_PID" 2>/dev/null || true
    _DC_REFRESH_PID=""
  fi

  rm -f "$_DC_ENV_UPDATED_FLAG"
  _dc_remove_from_man
  _dc_qa_remove_from_man
  _dc_ok "Limpieza completa. ¡Hasta luego!"
}

# ── Main ──────────────────────────────────────────────────────────────────────
_dc_main() {
  echo ""
  echo -e "${_DC_BOLD}${_DC_BLUE}╔══════════════════════════════════════════════════╗${_DC_NC}"
  echo -e "${_DC_BOLD}${_DC_BLUE}║   Business Financiero — Dev Connect              ║${_DC_NC}"
  echo -e "${_DC_BOLD}${_DC_BLUE}║   DEV (finance.siesacloud.dev)    → :5432        ║${_DC_NC}"
  echo -e "${_DC_BOLD}${_DC_BLUE}║   QA  (finance-qa.siesacloud.dev) → :5434        ║${_DC_NC}"
  echo -e "${_DC_BOLD}${_DC_BLUE}╚══════════════════════════════════════════════════╝${_DC_NC}"

  _dc_check_prereqs || return 1
  _dc_check_auth
  _dc_setup_shell_profiles

  # ── DEV: MAN + Cloud SQL Auth Proxy ──────────────────────────────────────────
  _dc_add_to_man

  _dc_step "Iniciando túnel SQL DEV..."
  _dc_info "Cloud SQL Auth Proxy → localhost:${_DC_PORT_SQL}..."

  cloud-sql-proxy \
    --port="$_DC_PORT_SQL" \
    --address=127.0.0.1 \
    "$_DC_CLOUDSQL_INSTANCE" \
    >/tmp/cloudsql-proxy.log 2>&1 &
  _DC_TUNNEL_PID=$!

  # Esperar hasta 15s en incrementos de 1s
  local proxy_ok=false
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if (echo > /dev/tcp/127.0.0.1/$_DC_PORT_SQL) 2>/dev/null; then
      proxy_ok=true
      break
    fi
  done
  unset _i

  if [[ "$proxy_ok" == "true" ]]; then
    _dc_ok "Cloud SQL Auth Proxy → ${_DC_BOLD}localhost:${_DC_PORT_SQL}${_DC_NC}"
  else
    _dc_warn "Cloud SQL Auth Proxy no respondió en 15s — revisa /tmp/cloudsql-proxy.log"
  fi

  _dc_generate_db_env

  # ── QA: credenciales siempre; túnel solo si MAN QA es accesible ──────────────
  # Las credenciales vienen de Secret Manager (no necesitan kubectl).
  # El túnel necesita kubectl → requiere MAN. Se intenta en best-effort.
  _dc_generate_qa_db_env || true
  if _dc_qa_add_to_man; then
    _dc_start_qa_tunnel || true
  else
    _dc_warn "Túnel QA no disponible — sin acceso al cluster QA (MAN). Credenciales disponibles."
  fi

  # Cargar ConnectionStrings del servicio actual si el directorio es reconocido
  _financiero_auto_use

  _dc_print_summary
  _dc_print_db_box
  _dc_print_qa_db_box

  echo ""

  if _dev_is_sourced; then
    # Iniciar loop de refresco del secreto DEV en background
    _dc_refresh_loop &
    _DC_REFRESH_PID=$!

    # Registrar hook en el shell para recarga automática tras rotación
    _dc_register_shell_hook

    # Sourced: túneles corren en background, terminal queda libre
    local interval_min=$(( _DC_REFRESH_INTERVAL / 60 ))
    echo -e "${_DC_CYAN}Túneles activos en background — DEV PID ${_DC_BOLD}${_DC_TUNNEL_PID}${_DC_NC}${_DC_CYAN}, QA PID ${_DC_BOLD}${_DC_QA_TUNNEL_PID:-N/A}${_DC_NC}${_DC_CYAN}.${_DC_NC}"
    echo -e "${_DC_CYAN}Refresco DEV cada ${_DC_BOLD}${interval_min} min${_DC_NC}${_DC_CYAN} — se actualiza automáticamente si el secreto rota.${_DC_NC}"
    echo -e "${_DC_CYAN}Para cerrar:${_DC_NC}  ${_DC_BOLD}dev-disconnect${_DC_NC}"
  else
    # Ejecutado directamente: bloquear hasta Ctrl+C
    trap '_dc_cleanup_exit' SIGINT SIGTERM EXIT
    echo -e "${_DC_CYAN}Ctrl+C para cerrar (remueve IPs de MAN automáticamente)${_DC_NC}"
    echo ""
    wait "$_DC_TUNNEL_PID" 2>/dev/null || true
  fi
}

_dc_cleanup_exit() {
  echo ""
  _dc_step "Cerrando conexiones..."
  [[ -n "$_DC_TUNNEL_PID" ]] && kill "$_DC_TUNNEL_PID" 2>/dev/null || true
  _dc_stop_qa_tunnel
  _dc_remove_from_man
  _dc_qa_remove_from_man
  _dc_ok "Limpieza completa. ¡Hasta luego!"
  exit 0
}

_dc_main
