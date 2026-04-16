#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly STUDENT_USER='vagrant'
readonly TMUX_SESSION='class'
readonly SSHD_DROPIN='/etc/ssh/sshd_config.d/99-classroom-vagrant.conf'
readonly BASHRC_SNIPPET_BEGIN='# >>> classroom tmux auto-attach >>>'
readonly BASHRC_SNIPPET_END='# <<< classroom tmux auto-attach <<<'
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
    die "Please run this script with sudo, for example: curl -fsSL 'https://raw.githubusercontent.com/AstroLabVN/setup-ssh-tmux-student-vm/main/setup.sh' | sudo bash"
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

ensure_user_exists() {
  if ! id "${STUDENT_USER}" >/dev/null 2>&1; then
    die "User ${STUDENT_USER} does not exist on this VM."
  fi
}

configure_fast_apt_mirror() {
  local sources_file='/etc/apt/sources.list.d/ubuntu.sources'
  local backup_file='/etc/apt/sources.list.d/ubuntu.sources.bak'
  local chosen_mirror=''
  local mirror=''

  local -a mirrors=(
    'https://mirror.clearsky.vn/ubuntu/'
    'http://mirror.viettelcloud.vn/ubuntu/'
    'https://mirror.azvps.vn/ubuntu/'
    'https://ftp.udx.icscoe.jp/Linux/ubuntu/'
    'http://tw.archive.ubuntu.com/ubuntu/'
  )

  log 'Forcing IPv4 for apt'
  cat > /etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF

  log 'Setting apt retries and timeouts'
  cat > /etc/apt/apt.conf.d/99lab-speed <<'EOF'
Acquire::Retries "2";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
EOF

  if [[ ! -f "${sources_file}" ]]; then
    warn "Could not find ${sources_file}; skipping mirror rewrite"
    return 0
  fi

  log "Backing up ${sources_file} to ${backup_file}"
  cp "${sources_file}" "${backup_file}"

  log 'Testing mirrors'
  for mirror in "${mirrors[@]}"; do
    printf '[INFO] Testing mirror: %s\n' "${mirror}"
    if curl -4 -L --silent --show-error --output /dev/null --max-time 8 "${mirror}dists/"; then
      chosen_mirror="${mirror}"
      printf '[INFO] Selected mirror: %s\n' "${chosen_mirror}"
      break
    fi
  done

  if [[ -z "${chosen_mirror}" ]]; then
    warn 'No custom mirror responded in time; keeping existing Ubuntu sources'
    return 0
  fi

  log 'Rewriting ubuntu.sources'
  sed -Ei \
    -e "s|https?://([a-z]{2}\.)?archive\.ubuntu\.com/ubuntu/|${chosen_mirror}|g" \
    -e "s|https?://security\.ubuntu\.com/ubuntu/|${chosen_mirror}|g" \
    "${sources_file}"

  log 'Updated apt sources file'
  cat "${sources_file}"
}

install_packages() {
  log 'Updating apt package lists'
  apt update

  log 'Installing curl, openssh-server and tmux'
  DEBIAN_FRONTEND=noninteractive apt install -y curl openssh-server tmux
}

configure_ssh_dir() {
  local user_home
  local auth_keys_file

  user_home="$(getent passwd "${STUDENT_USER}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "Could not determine home directory for ${STUDENT_USER}"

  auth_keys_file="${user_home}/.ssh/authorized_keys"

  log "Creating SSH directory for ${STUDENT_USER}"
  install -d -m 700 -o "${STUDENT_USER}" -g "${STUDENT_USER}" "${user_home}/.ssh"

  log "Writing authorized_keys for ${STUDENT_USER}"
  cat > "${auth_keys_file}" <<EOF
${TEACHER_PUBLIC_KEY}
EOF

  chown "${STUDENT_USER}:${STUDENT_USER}" "${auth_keys_file}"
  chmod 600 "${auth_keys_file}"
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

  log 'Ensuring /run/sshd exists'
  install -d -m 755 /run/sshd

  log 'Validating sshd configuration'
  /usr/sbin/sshd -t

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
  printf '\n'
  printf 'Connect from your machine with:\n'
  printf 'ssh -i ~/.ssh/astrolab/ssh_tmux_student_vm %s@%s\n' "${STUDENT_USER}" "${primary_ip}"
  printf '\n'
  printf 'Because tmux auto-attach is enabled, both of you should land in the same shared session.\n'
  printf 'If needed, the manual tmux command is:\n'
  printf 'tmux new-session -A -s %s\n' "${TMUX_SESSION}"
}

main() {
  require_root
  require_debian_like
  ensure_user_exists
  configure_fast_apt_mirror
  install_packages
  configure_ssh_dir
  configure_sshd
  install_tmux_auto_attach
  ensure_tmux_session_exists
  print_summary
}

main "$@"
