#!/usr/bin/env bash
# ============================================================
# Deploy the Ansible configuration through an IAP tunnel.
#
# The instance has no public IP. This script opens the free IAP tunnel on
# localhost:2222, runs site.yml against it, and always closes the tunnel and
# removes the temporary inventory, even if Ansible fails.
#
# Usage:
#   ./scripts/deploy.sh                 # full playbook
#   ./scripts/deploy.sh --tags verify   # one block
#   ./scripts/deploy.sh --check         # dry run
#
# Environment overrides:
#   GCP_PROJECT, GCP_ZONE, GCP_INSTANCE, IAP_PORT, SSH_PRIVATE_KEY
#   ANSIBLE_EXTRA_VARS  (default: -e @secrets.yml when that file exists)
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

for cmd in gcloud ansible-playbook terraform ssh-keyscan; do
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is not installed or not in PATH."
done

# Terraform owns the real values; the environment variables only exist so this
# script can be pointed at another instance without editing the repository.
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${GCP_ZONE:-$(terraform output -raw zone 2>/dev/null || true)}"
INSTANCE="${GCP_INSTANCE:-$(terraform output -raw instance_name 2>/dev/null || true)}"
SSH_USER="${GCP_USER:-$(terraform output -raw ssh_user 2>/dev/null || true)}"
PORT="${IAP_PORT:-2222}"

[[ -n "${PROJECT}" && "${PROJECT}" != "(unset)" ]] || die "No GCP project. Run 'gcloud config set project <id>' or set GCP_PROJECT."
[[ -n "${ZONE}" ]] || die "No zone. Run 'terraform apply' first, or set GCP_ZONE."
[[ -n "${INSTANCE}" ]] || die "No instance. Run 'terraform apply' first, or set GCP_INSTANCE."
SSH_USER="${SSH_USER:-ubuntu}"

# A VM without an external address and without Cloud NAT cannot reach apt or
# the Docker registry. Fail before spending a tunnel and a half-finished
# deployment on it. A run that only verifies or hardens the host does not need
# egress, so `make verify` keeps working after `make egress-off`.
REQUIRE_EGRESS=1
prev=""
for arg in "$@"; do
  case "${arg}" in
    --check|--syntax-check|--list-tags) REQUIRE_EGRESS=0 ;;
    --tags=*|-t=*)
      tags="${arg#*=}"
      case ",${tags}," in
        *,docker,*|*,stacks,*|*,backups,*|*,all,*) ;;
        *) REQUIRE_EGRESS=0 ;;
      esac
      ;;
  esac
  if [[ "${prev}" == "--tags" || "${prev}" == "-t" ]]; then
    case ",${arg}," in
      *,docker,*|*,stacks,*|*,backups,*|*,all,*) ;;
      *) REQUIRE_EGRESS=0 ;;
    esac
  fi
  prev="${arg}"
done

if [[ "${REQUIRE_EGRESS}" -eq 1 ]]; then
  PROFILE="$(terraform output -raw deployment_profile 2>/dev/null || true)"
  case "${PROFILE}" in
    egress-window*) log "Egress window is open (${PROFILE})." ;;
    *)
      die "The instance has no egress. Run 'make egress-on' first, deploy, then 'make egress-off'."
      ;;
  esac
else
  log "This run does not need egress (verify/hardening or --check)."
fi

INVENTORY="$(mktemp "${TMPDIR:-/tmp}/gcp-inventory.XXXXXX.ini")"
TUNNEL_LOG="$(mktemp "${TMPDIR:-/tmp}/iap-tunnel.XXXXXX.log")"
TUNNEL_PID=""

cleanup() {
  local rc=$?
  if [[ -n "${TUNNEL_PID}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    log "Closing the IAP tunnel."
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi
  rm -f "${INVENTORY}"
  if [[ ${rc} -ne 0 ]]; then
    log "Tunnel log kept at ${TUNNEL_LOG}"
  else
    rm -f "${TUNNEL_LOG}"
  fi
  exit "${rc}"
}
trap cleanup EXIT INT TERM

log "Opening IAP tunnel to ${INSTANCE} (${PROJECT}/${ZONE}) on 127.0.0.1:${PORT}."
gcloud compute start-iap-tunnel "${INSTANCE}" 22 \
  --local-host-port="127.0.0.1:${PORT}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" >"${TUNNEL_LOG}" 2>&1 &
TUNNEL_PID=$!

# Wait until the local end accepts connections. Probing with bash's /dev/tcp
# avoids depending on netcat being installed.
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3<&- 3>&- 2>/dev/null || true
    break
  fi
  kill -0 "${TUNNEL_PID}" 2>/dev/null || die "The IAP tunnel exited. See ${TUNNEL_LOG}"
  sleep 2
done
(exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null || die "The IAP tunnel did not become ready. See ${TUNNEL_LOG}"
exec 3<&- 3>&- 2>/dev/null || true

printf '[gcp_servers]\ngcp-server ansible_host=127.0.0.1 ansible_port=%s ansible_user=%s\n' \
  "${PORT}" "${SSH_USER}" >"${INVENTORY}"

# The tunnel presents the instance's host key over 127.0.0.1. Ansible keeps host
# key checking on (ansible.cfg), so the key has to be trusted first.
ssh-keyscan -H -p "${PORT}" 127.0.0.1 >>"${HOME}/.ssh/known_hosts" 2>/dev/null || true

ANSIBLE_ARGS=(-i "${INVENTORY}")
if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
  ANSIBLE_ARGS+=(--private-key "${SSH_PRIVATE_KEY}")
fi
if [[ -f secrets.yml ]]; then
  ANSIBLE_ARGS+=(-e @secrets.yml)
fi
# Allow the caller to override the webhook without editing a tracked file.
# shellcheck disable=SC2206
if [[ -n "${ANSIBLE_EXTRA_VARS:-}" ]]; then
  ANSIBLE_ARGS+=(${ANSIBLE_EXTRA_VARS})
fi

log "Running site.yml."
ansible-playbook site.yml "${ANSIBLE_ARGS[@]}" "$@"
