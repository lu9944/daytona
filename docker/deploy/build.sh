#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Daytona + Keycloak Docker Build & Deploy Script

Usage: $(basename "$0") <command> [options]

Commands:
  init            First-time setup (pull images + generate certs + start)
  pull            Pull all Docker images
  up              Start all services
  down            Stop all services
  restart         Restart all services
  status          Show service status
  logs [svc]      Tail logs (optional: service name)
  clean           Remove all containers, volumes, and images
  build-source    Build images from source (requires full source tree)
  help            Show this help message

Environment Variables (set in .env or export before running):
  DAYTONA_DOMAIN        Daytona domain (default: daytona.example.com)
  KEYCLOAK_DOMAIN       Keycloak domain (default: auth.example.com)
  DAYTONA_VERSION       Version tag for source builds (default: 0.0.1)
  DAYTONA_SRC           Source code path for source builds (default: ../../)

Examples:
  ./build.sh init                          # First time: pull images + start
  ./build.sh up                            # Start services
  ./build.sh logs api                      # Tail API logs
  ./build.sh logs keycloak                 # Tail Keycloak logs

EOF
}

check_prerequisites() {
    info "Checking prerequisites..."
    command -v docker >/dev/null 2>&1 || error "docker not found. Please install Docker."
    command -v openssl >/dev/null 2>&1 || error "openssl not found. Please install openssl."

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        error "docker compose not found. Please install Docker Compose."
    fi
    info "Using compose command: ${COMPOSE_CMD}"

    if [ ! -f "${DEPLOY_DIR}/.env" ]; then
        warn ".env file not found. Copying from .env.example..."
        if [ -f "${DEPLOY_DIR}/.env.example" ]; then
            cp "${DEPLOY_DIR}/.env.example" "${DEPLOY_DIR}/.env"
        else
            warn "No .env.example found. Using defaults."
        fi
    fi

    ok "Prerequisites satisfied"
}

generate_certs() {
    if [ ! -f "${DEPLOY_DIR}/ssl/certs/daytona.example.com.crt" ]; then
        info "Generating SSL certificates..."
        bash "${DEPLOY_DIR}/ssl/generate-certs.sh"
        ok "SSL certificates generated"
    else
        ok "SSL certificates already exist"
    fi
}

generate_ssh_keys() {
    local env_file="${DEPLOY_DIR}/.env"
    if grep -q "^SSH_PRIVATE_KEY=" "${env_file}" 2>/dev/null && ! grep -q "^SSH_PRIVATE_KEY=$" "${env_file}" 2>/dev/null; then
        ok "SSH keys already configured in .env"
        return 0
    fi

    info "Generating SSH keys for SSH Gateway..."

    local tmpdir
    tmpdir=$(mktemp -d)

    ssh-keygen -t rsa -b 4096 -f "${tmpdir}/ssh_host_rsa_key" -N "" -q -C "daytona-ssh-gateway"
    ssh-keygen -t ed25519 -f "${tmpdir}/ssh_host_ed25519_key" -N "" -q -C "daytona-ssh-gateway"

    local private_key
    private_key=$(cat "${tmpdir}/ssh_host_ed25519_key" | base64 -w0)

    local host_key
    host_key=$(cat "${tmpdir}/ssh_host_rsa_key" | base64 -w0)

    local public_key
    public_key=$(cat "${tmpdir}/ssh_host_ed25519_key.pub" | base64 -w0)

    if ! grep -q "^SSH_PRIVATE_KEY=" "${env_file}" 2>/dev/null; then
        echo "" >> "${env_file}"
        echo "### SSH Gateway Keys (auto-generated) ###" >> "${env_file}"
    fi

    sed -i "s|^SSH_PRIVATE_KEY=.*|SSH_PRIVATE_KEY=${private_key}|" "${env_file}" 2>/dev/null || \
        echo "SSH_PRIVATE_KEY=${private_key}" >> "${env_file}"
    sed -i "s|^SSH_HOST_KEY=.*|SSH_HOST_KEY=${host_key}|" "${env_file}" 2>/dev/null || \
        echo "SSH_HOST_KEY=${host_key}" >> "${env_file}"
    sed -i "s|^SSH_GATEWAY_PUBLIC_KEY=.*|SSH_GATEWAY_PUBLIC_KEY=${public_key}|" "${env_file}" 2>/dev/null || \
        echo "SSH_GATEWAY_PUBLIC_KEY=${public_key}" >> "${env_file}"

    rm -rf "${tmpdir}"
    ok "SSH keys generated and saved to .env"
}

pull_images() {
    info "Pulling Docker images..."
    ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" pull
    ok "All images pulled successfully"
}

build_from_source() {
    local src_dir="${DAYTONA_SRC:-../../}"
    if [ ! -f "${src_dir}/go.work" ]; then
        error "Source directory not found at ${src_dir}. Set DAYTONA_SRC to the repo root."
    fi
    info "Building from source at ${src_dir}..."
    ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" -f "${DEPLOY_DIR}/docker-compose.source.yaml" build --parallel
    ok "All images built from source"
}

start_services() {
    info "Starting services..."
    ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" up -d
    ok "Services started"
    echo ""
    print_access_info
}

stop_services() {
    info "Stopping services..."
    ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" down
    ok "Services stopped"
}

show_status() {
    ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" ps
}

show_logs() {
    local svc="${1:-}"
    if [ -n "${svc}" ]; then
        ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" logs -f "${svc}"
    else
        ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" logs -f
    fi
}

clean_all() {
    warn "This will remove ALL containers, volumes, and built images."
    read -p "Are you sure? [y/N] " confirm
    if [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ]; then
        ${COMPOSE_CMD} -f "${DEPLOY_DIR}/docker-compose.yaml" down -v --rmi local
        ok "Cleaned up"
    else
        info "Cancelled"
    fi
}

print_access_info() {
    source_env
    local daytona_domain="${DAYTONA_DOMAIN:-daytona.example.com}"
    local keycloak_domain="${KEYCLOAK_DOMAIN:-auth.example.com}"
    local keycloak_admin_user="${KEYCLOAK_ADMIN_USER:-admin}"
    local keycloak_admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

    echo "======================================"
    echo "  Daytona + Keycloak Deployment"
    echo "======================================"
    echo ""
    echo "  Daytona Dashboard:"
    echo "    https://${daytona_domain}"
    echo ""
    echo "  Keycloak Admin Console:"
    echo "    https://${keycloak_domain}"
    echo "    Admin: ${keycloak_admin_user} / ${keycloak_admin_pass}"
    echo ""
    echo "  Keycloak User Account (self-service password change):"
    echo "    https://${keycloak_domain}/realms/daytona/account/"
    echo ""
    echo "  Default user:"
    echo "    admin@example.com / admin"
    echo ""
    echo "  CLI login:"
    echo "    DAYTONA_AUTH0_DOMAIN=https://${keycloak_domain}/realms/daytona \\"
    echo "    DAYTONA_AUTH0_CLIENT_ID=daytona \\"
    echo "    DAYTONA_AUTH0_AUDIENCE=daytona \\"
    echo "    daytona login"
    echo ""
    echo "======================================"
}

source_env() {
    if [ -f "${DEPLOY_DIR}/.env" ]; then
        set -a
        source "${DEPLOY_DIR}/.env"
        set +a
    fi
}

cmd_init() {
    check_prerequisites
    generate_certs
    generate_ssh_keys
    pull_images
    start_services
}

cmd_pull() {
    check_prerequisites
    pull_images
}

cmd_build_source() {
    check_prerequisites
    build_from_source
}

cmd_up() {
    check_prerequisites
    generate_certs
    start_services
}

cmd_down() {
    stop_services
}

cmd_restart() {
    stop_services
    start_services
}

cmd_status() {
    show_status
}

cmd_logs() {
    show_logs "$@"
}

cmd_clean() {
    clean_all
}

case "${1:-help}" in
    init)
        cmd_init
        ;;
    pull)
        cmd_pull
        ;;
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs "${2:-}"
        ;;
    clean)
        cmd_clean
        ;;
    build-source)
        cmd_build_source
        ;;
    help|*)
        usage
        ;;
esac
