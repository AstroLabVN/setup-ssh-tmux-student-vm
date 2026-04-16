#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail
IFS=$'\n\t'

readonly STUDENT_USER='ben'
readonly TMUX_SESSION='class'
readonly LAN_CIDR='192.168.1.0/24'
readonly SSHD_DROPIN='/etc/ssh/sshd_config.d/99-classroom-ben.conf'
readonly BASHRC_SNIPPET_BEGIN='# >>> classroom tmux auto-attach >>>'
readonly BASHRC_SNIPPET_END='# <<< classroom tmux auto-attach <<<'

# Replace this with your real public key before using the script.
readonly TEACHER_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPy3I6/T99jJIvCcRNC32WWRGYChal9P39jrrsB2aOmB ssh_tmux_student_vm'

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=$1
  die "Script failed at line ${line_no} with exit code ${exit_code}"
}

trap 'on_error "${LINENO}"' ERR

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die 'Please run this script with sudo, for example: curl -fsSL URL | sudo bash'
  fi
}

require_debian_like() {
  if [[ ! -r /etc/os-release ]]; then
    die 'Cannot detect OS. This script supports Ubuntu/Debian-like systems only.'
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != 'ubuntu' && "${ID:-}" != 'debian' ]] && [[ "${ID_LIKE:-}" != *debian* ]]; then
    die 'Unsupported OS. This script supports Ubuntu/Debian-like systems only.'
  fi
}

install_packages() {
  log 'Updating apt package lists'
  apt update

  log 'Installing openssh-server and tmux'
  DEBIAN_FRONTEND=noninteractive apt install -y openssh-server tmux
}

ensure_user_exists() {
  if id "${STUDENT_USER}" >/dev/null 2>&1; then
    log "User ${STUDENT_USER} already exists"
  else
    log "Creating user ${STUDENT_USER}"
    adduser --disabled-password --gecos '' "${STUDENT_USER}"
  fi
}

configure_ssh_dir() {
  local user_home
  user_home="$(getent passwd "${STUDENT_USER}" | cut -d: -f6)"

  [[ -n "${user_home}" ]] || die "Could not determine home directory for ${STUDENT_USER}"

  log "Creating SSH directory for ${STUDENT_USER}"
  install -d -m 700 -o "${STUDENT_USER}" -g "${STUDENT_USER}" "${user_home}/.ssh"

  log "Writing authorized_keys for ${STUDENT_USER}"
  cat > "${user_home}/.ssh/authorized_keys" <<EOF
from="${LAN_CIDR}" ${TEACHER_PUBLIC_KEY}
EOF

  chown "${STUDENT_USER}:${STUDENT_USER}" "${user_home}/.ssh/authorized_keys"
  chmod 600 "${user_home}/.ssh/authorized_keys"
}

configure_sshd() {
  log 'Creating sshd drop-in configuration'
  install -d -m 755 /etc/ssh/sshd_config.d

  cat > "${SSHD_DROPIN}" <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers ${STUDENT_USER}
X11Forwarding no
AllowAgentForwarding no
PermitEmptyPasswords no
UsePAM yes
EOF

  log 'Validating sshd configuration'
  sshd -t

  log 'Enabling and starting SSH service'
  systemctl enable --now ssh

  log 'Reloading SSH service'
  systemctl reload ssh
}

install_tmux_auto_attach() {
  local user_home
  local bashrc_file
  local snippet_file

  user_home="$(getent passwd "${STUDENT_USER}" | cut -d: -f6)"
  bashrc_file="${user_home}/.bashrc"
  snippet_file="$(mktemp)"

  log "Installing tmux auto-attach snippet into ${bashrc_file}"

  cat > "${snippet_file}" <<EOF
${BASHRC_SNIPPET_BEGIN}
if [[ -n "\${PS1:-}" ]] && command -v tmux >/dev/null 2>&1; then
  if [[ -z "\${TMUX:-}" ]] && [[ "\$(id -un)" = '${STUDENT_USER}' ]]; then
    exec tmux new-session -A -s '${TMUX_SESSION}'
  fi
fi
${BASHRC_SNIPPET_END}
EOF

  if [[ -f "${bashrc_file}" ]] && grep -Fq "${BASHRC_SNIPPET_BEGIN}" "${bashrc_file}"; then
    log 'tmux auto-attach snippet already present'
  else
    cat "${snippet_file}" >> "${bashrc_file}"
    chown "${STUDENT_USER}:${STUDENT_USER}" "${bashrc_file}"
  fi

  rm -f "${snippet_file}"
}

ensure_tmux_session_exists() {
  log "Creating tmux session ${TMUX_SESSION} for ${STUDENT_USER} if missing"
  sudo -u "${STUDENT_USER}" tmux has-session -t "${TMUX_SESSION}" 2>/dev/null || \
    sudo -u "${STUDENT_USER}" tmux new-session -d -s "${TMUX_SESSION}"
}

print_summary() {
  local primary_ip

  primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  primary_ip="${primary_ip:-YOUR_VM_IP}"

  log 'Setup complete'
  printf '\n'
  printf 'User: %s\n' "${STUDENT_USER}"
  printf 'tmux session: %s\n' "${TMUX_SESSION}"
  printf 'Allowed SSH source range for your key: %s\n' "${LAN_CIDR}"
  printf '\n'
  printf 'Connect from your machine with:\n'
  printf 'ssh %s@%s\n' "${STUDENT_USER}" "${primary_ip}"
  printf '\n'
  printf 'Because tmux auto-attach is enabled, both of you should land in the same shared session.\n'
  printf 'If needed, manual tmux command is:\n'
  printf 'tmux new-session -A -s %s\n' "${TMUX_SESSION}"
  printf '\n'
  printf 'Reminder: replace the placeholder public key in this script before using it.\n'
}

main() {
  require_root
  require_debian_like
  install_packages
  ensure_user_exists
  configure_ssh_dir
  configure_sshd
  install_tmux_auto_attach
  ensure_tmux_session_exists
  print_summary
}

main "$@"
