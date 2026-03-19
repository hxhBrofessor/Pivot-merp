#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="${HOME}/.pivot"
LOG_DIR="${CONTROL_DIR}/logs"
KNOWN_HOSTS_FILE="${CONTROL_DIR}/known_hosts"

mkdir -p "${CONTROL_DIR}" "${LOG_DIR}"
touch "${KNOWN_HOSTS_FILE}"

chmod 700 "${CONTROL_DIR}" "${LOG_DIR}"
chmod 600 "${KNOWN_HOSTS_FILE}"

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

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_ok()   { echo -e "[$(ts)] [${GREEN}] $1" | tee -a "$LOGFILE"; }
log_fail() { echo -e "[$(ts)] [${RED}] $1" | tee -a "$LOGFILE" >&2; exit 1; }
log_warn() { echo -e "[$(ts)] [${YELLOW}] $1" | tee -a "$LOGFILE"; }
log_info() { echo -e "[$(ts)] [*] $1" | tee -a "$LOGFILE"; }

########################################
# HELPERS
########################################

sanitize() { tr ',:@/' '____' <<< "$1"; }
sid() { echo "$1@$(sanitize "$2")"; }

sock_path() { echo "${CONTROL_DIR}/$(sid "$1" "$2").ctl"; }
meta_path() { echo "${CONTROL_DIR}/$(sid "$1" "$2").meta"; }
pid_path()  { echo "${CONTROL_DIR}/$(sid "$1" "$2").pid"; }

final_target() { awk -F',' '{print $NF}' <<< "$1"; }
jump_chain()   { awk -F',' 'NF>1{for(i=1;i<NF;i++)printf "%s%s",$i,(i<NF-1?",":"")}' <<< "$1"; }

need_bin() {
  command -v "$1" >/dev/null 2>&1 || log_fail "Missing binary: $1"
}

########################################
# SSH OPTIONS
########################################

ssh_opts() {
  cat <<EOF
-o ExitOnForwardFailure=yes
-o ServerAliveInterval=60
-o ServerAliveCountMax=2
-o TCPKeepAlive=no
-o ControlMaster=auto
-o ControlPersist=${DEFAULT_CONTROL_PERSIST}
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=${KNOWN_HOSTS_FILE}
-o LogLevel=${SSH_LOG_LEVEL}
-o Compression=yes
EOF
}

join_opts() {
  awk 'NF{printf "%s ",$0}' <<< "$(ssh_opts)"
}

########################################
# CONTROL SESSION
########################################

init_control() {
  local user="$1" chain="$2"
  local ctl target jumps

  ctl="$(sock_path "$user" "$chain")"
  target="$(final_target "$chain")"
  jumps="$(jump_chain "$chain")"

  if [[ -S "$ctl" ]] && ssh -S "$ctl" -O check "${user}@${target}" >/dev/null 2>&1; then
    log_ok "Reusing control session"
    return
  fi

  rm -f "$ctl"

  log_info "Establishing control session..."
  ssh $(join_opts) ${jumps:+-J "$jumps"} \
    -M -S "$ctl" "${user}@${target}" -N -f \
    || log_fail "SSH failed"

  log_ok "Control session ready"
}

########################################
# SOCKS
########################################

start_socks() {
  local user="$1" chain="$2" port="${3:-$DEFAULT_SOCKS_PORT}"
  local ctl target

  ctl="$(sock_path "$user" "$chain")"
  target="$(final_target "$chain")"

  need_bin ssh
  init_control "$user" "$chain"

  log_info "Starting SOCKS on ${port}"
  ssh -S "$ctl" -D "127.0.0.1:${port}" -N -f "${user}@${target}"

  log_ok "SOCKS -> 127.0.0.1:${port}"
}

########################################
# LOCAL FORWARD
########################################

start_local() {
  local user="$1" chain="$2" lport="$3" rhost="$4" rport="$5"

  init_control "$user" "$chain"

  ssh -S "$(sock_path "$user" "$chain")" \
    -L "127.0.0.1:${lport}:${rhost}:${rport}" \
    -N -f "${user}@$(final_target "$chain")"

  log_ok "LOCAL ${lport} -> ${rhost}:${rport}"
}

########################################
# REMOTE FORWARD
########################################

start_remote() {
  local user="$1" chain="$2" rport="$3" lhost="$4" lport="$5"

  init_control "$user" "$chain"

  ssh -S "$(sock_path "$user" "$chain")" \
    -R "0.0.0.0:${rport}:${lhost}:${lport}" \
    -N -f "${user}@$(final_target "$chain")"

  log_ok "REMOTE ${rport} -> ${lhost}:${lport}"
}

########################################
# AUTO ROUTE DISCOVERY
########################################

discover_routes() {
  local user="$1" chain="$2"
  local target="$(final_target "$chain")"

  ssh ${chain:+-J "$(jump_chain "$chain")"} \
    "${user}@${target}" \
    "ip route | awk '{print \$1}' | grep -E '^(10\.|172\.|192\.168)' | sort -u" \
    2>/dev/null || true
}

########################################
# SSHUTTLE (FINAL FIXED VERSION)
########################################

start_sshuttle() {
  local user="$1" chain="$2" cidrs="${3:-auto}"
  local dns="${4:-}"

  local pidfile meta target jumps
  pidfile="$(pid_path "$user" "$chain")"
  meta="$(meta_path "$user" "$chain")"
  target="$(final_target "$chain")"
  jumps="$(jump_chain "$chain")"

  need_bin sshuttle
  need_bin sudo

  ########################################
  # AUTO ROUTES
  ########################################
  if [[ "$cidrs" == "auto" ]]; then
    log_info "Discovering remote routes..."
    cidrs="$(discover_routes "$user" "$chain" | tr '\n' ' ')"

    [[ -z "$cidrs" ]] && log_fail "No routes discovered"
    log_ok "Discovered: $cidrs"
  fi

  ########################################
  # SUDO PRE-AUTH
  ########################################
  log_info "Requesting sudo..."
  sudo -v || log_fail "sudo failed"

  ########################################
  # BUILD SSH CMD (ONLY FOR JUMPS)
  ########################################
  local ssh_cmd=""
  if [[ -n "$jumps" ]]; then
    ssh_cmd="ssh -J $jumps"
  fi

  ########################################
  # START SSHUTTLE (DAEMON SAFE)
  ########################################
  log_info "Starting sshuttle..."

  if [[ -n "$ssh_cmd" ]]; then
    sshuttle --daemon ${dns:-} \
      --ssh-cmd "$ssh_cmd" \
      -r "${user}@${target}" ${cidrs}
  else
    sshuttle --daemon ${dns:-} \
      -r "${user}@${target}" ${cidrs}
  fi

  sleep 2

  local pid
  pid="$(pgrep -f "sshuttle.*${user}@${target}" | head -n1 || true)"

  if [[ -n "$pid" ]]; then
    echo "$pid" > "$pidfile"
    echo "MODE=SSHUTTLE" > "$meta"
    echo "CIDRS=$cidrs" >> "$meta"
    log_ok "sshuttle running (PID $pid)"
  else
    log_fail "sshuttle failed"
  fi
}

########################################
# STATUS
########################################

status() {
  log_info "Active pivots:"
  ls "${CONTROL_DIR}"/*.meta 2>/dev/null || log_warn "None"

  log_info "sshuttle:"
  pgrep -af sshuttle || log_warn "None"
}

########################################
# STOP
########################################

stop_all() {
  pkill -f sshuttle >/dev/null 2>&1 || true
  rm -f "${CONTROL_DIR}"/* >/dev/null 2>&1 || true
  log_ok "All stopped"
}

########################################
# MAIN
########################################

case "${1:-}" in
  socks) start_socks "$2" "$3" "${4:-}" ;;
  local) start_local "$2" "$3" "$4" "$5" "$6" ;;
  remote) start_remote "$2" "$3" "$4" "$5" "$6" ;;
  sshuttle) start_sshuttle "$2" "$3" "${4:-auto}" "${5:-}" ;;
  status) status ;;
  stop) stop_all ;;
  *) echo "Usage: socks|local|remote|sshuttle|status|stop" ;;
esac
