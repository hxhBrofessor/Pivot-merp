#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="${HOME}/.pivot"
LOG_DIR="${CONTROL_DIR}/logs"
mkdir -p "${CONTROL_DIR}" "${LOG_DIR}"

GREEN="✔"
RED="✖"
YELLOW="⚠"

DEFAULT_SOCKS_PORT=1080
DEFAULT_LOCAL_PORT=8080
DEFAULT_CONTROL_PERSIST="10m"
SSH_LOG_LEVEL="${SSH_LOG_LEVEL:-ERROR}"

LOGFILE="${LOG_DIR}/pivot.log"

########################################
# LOGGING
########################################

log_ok()   { echo -e "[${GREEN}] $1" | tee -a "$LOGFILE"; }
log_fail() { echo -e "[${RED}] $1" | tee -a "$LOGFILE" >&2; exit 1; }
log_warn() { echo -e "[${YELLOW}] $1" | tee -a "$LOGFILE"; }
log_info() { echo -e "[*] $1" | tee -a "$LOGFILE"; }

########################################
# CLEANUP TRAP (FIXED)
########################################
# Only trigger cleanup on interruption signals, not normal exit

cleanup() {
  log_warn "Interrupt received — cleaning up pivots..."
  stop_all || true
}

trap cleanup INT TERM

########################################
# HELPERS
########################################

sock_path() {
  echo "${CONTROL_DIR}/${1}@${2}.ctl"
}

meta_path() {
  echo "${CONTROL_DIR}/${1}@${2}.meta"
}

pid_path() {
  echo "${CONTROL_DIR}/${1}@${2}.pid"
}

final_target() {
  echo "${1%%,*}"
}

need_bin() {
  command -v "$1" >/dev/null 2>&1 || log_fail "Missing binary: $1"
}

########################################
# SSH OPTIONS
########################################

ssh_base_opts() {
cat <<EOF
-o ExitOnForwardFailure=yes
-o ServerAliveInterval=60
-o ServerAliveCountMax=2
-o TCPKeepAlive=no
-o ControlMaster=auto
-o ControlPersist=${DEFAULT_CONTROL_PERSIST}
-o StrictHostKeyChecking=no
-o UserKnownHostsFile=/dev/null
-o LogLevel=${SSH_LOG_LEVEL}
-o PreferredAuthentications=publickey,password,keyboard-interactive
-o Compression=yes
EOF
}

join_ssh_opts() {
  awk 'NF{printf "%s ",$0}' <<< "$(ssh_base_opts)"
}

########################################
# PORT HANDLING
########################################

find_free_port() {
  local port="$1"
  while ss -ltn | awk '{print $4}' | grep -qE "[:.]${port}$"; do
    port=$((port+1))
  done
  echo "$port"
}

check_port_available() {
  local requested="$1"
  local chosen
  chosen="$(find_free_port "$requested")"

  [[ "$chosen" != "$requested" ]] \
    && log_warn "Port ${requested} in use -> using ${chosen}" \
    || log_ok "Port ${chosen} available"

  echo "$chosen"
}

########################################
# CONTROL SESSION
########################################

init_control() {
  local user="$1"
  local host="$2"
  local ctl target

  ctl="$(sock_path "$user" "$host")"
  target="$(final_target "$host")"

  if [[ -S "$ctl" ]]; then
    if ssh -S "$ctl" -O check "${user}@${target}" >/dev/null 2>&1; then
      log_ok "Reusing existing SSH control session"
      return
    else
      rm -f "$ctl"
    fi
  fi

  log_info "Establishing control session..."
  ssh $(join_ssh_opts) -M -S "$ctl" "${user}@${target}" -N -f \
    || log_fail "SSH failed"

  log_ok "Control session established"
}

########################################
# ROUTE DISCOVERY
########################################

discover_networks() {
  local user="$1"
  local host="$2"
  local ctl target

  ctl="$(sock_path "$user" "$host")"
  target="$(final_target "$host")"

  ssh -o ControlPath="$ctl" "${user}@${target}" \
    "ip route | grep -E '(^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\.)'" \
    2>/dev/null || true
}

extract_private_cidrs() {
  local user="$1"
  local host="$2"

  discover_networks "$user" "$host" \
    | awk '$1 ~ /\// {print $1}' \
    | sort -u
}

########################################
# SOCKS (SAFE METADATA)
########################################

start_socks() {
  local user="$1"
  local host="$2"
  local ctl target port meta MODE PORT

  ctl="$(sock_path "$user" "$host")"
  meta="$(meta_path "$user" "$host")"
  target="$(final_target "$host")"

  need_bin ssh
  need_bin ss

  # Safe metadata parsing (no source)
  if [[ -f "$meta" ]]; then
    MODE=$(grep '^MODE=' "$meta" | cut -d= -f2 || true)
    PORT=$(grep '^PORT=' "$meta" | cut -d= -f2 || true)

    if [[ "$MODE" == "SOCKS" && -n "$PORT" ]]; then
      log_ok "Reusing SOCKS on port ${PORT}"
      log_info "proxychains: socks5 127.0.0.1 ${PORT}"
      return
    fi
  fi

  port="$(check_port_available "${3:-$DEFAULT_SOCKS_PORT}")"
  init_control "$user" "$host"

  log_info "Starting SOCKS proxy..."
  ssh -o ControlPath="$ctl" -D "127.0.0.1:${port}" -N -f "${user}@${target}"

  echo "MODE=SOCKS" > "$meta"
  echo "PORT=${port}" >> "$meta"

  log_ok "SOCKS -> 127.0.0.1:${port}"
}

########################################
# SSHUTTLE (PID SAFETY)
########################################

start_sshuttle() {
  local user="$1"
  local host="$2"
  local cidrs="$3"
  local dns="${4:-}"
  local pidfile

  pidfile="$(pid_path "$user" "$host")"

  need_bin sshuttle

  # Prevent duplicate sshuttle
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log_warn "sshuttle already running for ${user}@${host}"
    return
  fi

  log_info "Starting sshuttle for ${cidrs}"

  # NOTE: sshuttle does NOT reuse ControlMaster sessions
  sshuttle ${dns:-} -r "${user}@${host}" "${cidrs}" &

  echo $! > "$pidfile"
  sleep 2

  if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log_ok "sshuttle started"
  else
    log_fail "sshuttle failed"
  fi
}

########################################
# STATUS (ENHANCED)
########################################

show_status() {
  log_info "Pivot sessions (metadata):"

  for f in "${CONTROL_DIR}"/*.meta 2>/dev/null; do
    [[ -f "$f" ]] || continue
    echo "--- $(basename "$f" .meta) ---"
    cat "$f"
  done

  log_info "SSH control sessions:"
  ls "${CONTROL_DIR}"/*.ctl 2>/dev/null || log_warn "None"

  log_info "SSH listeners:"
  ss -ltnp | grep ssh || log_warn "None"

  log_info "sshuttle processes:"
  pgrep -af sshuttle || log_warn "None"
}

########################################
# STOP FUNCTIONS
########################################

stop_target() {
  local user="$1"
  local host="$2"

  rm -f "$(sock_path "$user" "$host")" \
        "$(meta_path "$user" "$host")" \
        "$(pid_path "$user" "$host")"

  log_ok "Stopped pivot for ${user}@${host}"
}

stop_all() {
  rm -f "${CONTROL_DIR}"/*.ctl "${CONTROL_DIR}"/*.meta "${CONTROL_DIR}"/*.pid 2>/dev/null || true
  pkill -f sshuttle >/dev/null 2>&1 || true
  log_ok "All pivots stopped"
}

########################################
# MAIN
########################################

case "${1:-}" in
  socks) start_socks "$2" "$3" "${4:-}" ;;
  sshuttle) start_sshuttle "$2" "$3" "$4" "${5:-}" ;;
  status) show_status ;;
  stop)
    [[ "${2:-}" == "all" ]] && stop_all || stop_target "$2" "$3"
    ;;
  *)
    echo "Usage: socks | sshuttle | status | stop <user host | all>"
    ;;
esac
