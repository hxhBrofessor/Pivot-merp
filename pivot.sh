#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="${HOME}/.pivot"
LOG_DIR="${CONTROL_DIR}/logs"
mkdir -p "${CONTROL_DIR}" "${LOG_DIR}"

GREEN="✔"
RED="✖"
YELLOW="⚠"

DEFAULT_SOCKS_PORT=1080
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
# CLEANUP TRAP
########################################

cleanup() {
  log_warn "Interrupt received — cleaning up pivots..."
  stop_all || true
}
trap cleanup INT TERM

########################################
# HELPERS
########################################

sock_path() { echo "${CONTROL_DIR}/${1}@${2}.ctl"; }
meta_path() { echo "${CONTROL_DIR}/${1}@${2}.meta"; }
pid_path()  { echo "${CONTROL_DIR}/${1}@${2}.pid"; }

final_target() { echo "${1%%,*}"; }

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

  if [[ "$chosen" != "$requested" ]]; then
    log_warn "Port ${requested} in use -> using ${chosen}"
  else
    log_ok "Port ${chosen} available"
  fi

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
# SOCKS
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
# SSHUTTLE (FIXED + SAFE BACKGROUND)
########################################

start_sshuttle() {
  local user="$1"
  local host="$2"
  local cidrs="$3"
  local dns="${4:-}"
  local pidfile meta

  pidfile="$(pid_path "$user" "$host")"
  meta="$(meta_path "$user" "$host")"

  need_bin sshuttle
  need_bin sudo

  if [[ -f "$pidfile" ]]; then
    if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      log_warn "sshuttle already running for ${user}@${host}"
      return
    fi
  fi

  ########################################
  # CLEAN SUDO FIRST
  ########################################
  log_info "Requesting sudo privileges..."
  sudo -v || log_fail "sudo authentication failed"

  ########################################
  # SAFE BACKGROUND MODE
  ########################################
  if sudo -n true >/dev/null 2>&1; then
    log_ok "sudo cached — launching sshuttle in background"

    sshuttle --daemon ${dns:-} -r "${user}@${host}" "${cidrs}"

    echo "MODE=SSHUTTLE" > "$meta"
    echo "CIDRS=${cidrs}" >> "$meta"

    log_ok "sshuttle running in background"
  else
    log_warn "sudo not cached — running interactive mode"
    log_info "You will be prompted for SSH password"

    sshuttle ${dns:-} -r "${user}@${host}" "${cidrs}"
  fi
}

########################################
# STATUS
########################################

show_status() {
  log_info "Pivot sessions:"

  shopt -s nullglob
  for f in "${CONTROL_DIR}"/*.meta; do
    echo "--- $(basename "$f" .meta) ---"
    cat "$f"
  done
  shopt -u nullglob

  log_info "SSH control sessions:"
  ls "${CONTROL_DIR}"/*.ctl 2>/dev/null || log_warn "None"

  log_info "SSH listeners:"
  ss -ltnp 2>/dev/null | grep ssh || log_warn "None"

  log_info "sshuttle processes:"
  pgrep -af sshuttle || log_warn "None"
}

########################################
# STOP
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
    if [[ "${2:-}" == "all" ]]; then
      stop_all
    else
      stop_target "$2" "$3"
    fi
    ;;
  *)
    echo "Usage:"
    echo "  socks <user> <host> [port]"
    echo "  sshuttle <user> <host> <cidr> [--dns]"
    echo "  status"
    echo "  stop <user host | all>"
    ;;
esac
