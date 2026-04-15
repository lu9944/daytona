#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/install.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [[ ! -f "$CONF_FILE" ]]; then
    error "install.conf not found at $CONF_FILE"
fi

set -a
source "$CONF_FILE"
set +a

DAYTONA_HOME="${DAYTONA_BASE}/daytona"
COMPOSE_FILES="-f docker-compose.yml"

if [[ "${DAYTONA_EXTERNAL_DB}" != "true" ]]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose-db.yml"
fi

if [[ "${DAYTONA_EXTERNAL_REDIS}" != "true" ]]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose-redis.yml"
fi

info "=========================================="
info " Daytona ${DAYTONA_VERSION} Offline Installer"
info "=========================================="
info "Install directory : ${DAYTONA_HOME}"
info "Service port      : ${DAYTONA_PORT}"
info "Hostname          : ${DAYTONA_HOSTNAME}"
info "External DB       : ${DAYTONA_EXTERNAL_DB}"
info "External Redis    : ${DAYTONA_EXTERNAL_REDIS}"
info "=========================================="

if command -v daytonactl &>/dev/null; then
    warn "Detected existing Daytona installation. Upgrading..."
    EXISTING_BASE=$(daytonactl _get_base 2>/dev/null || echo "${DAYTONA_BASE}")
    if [[ -f "${EXISTING_BASE}/daytona/conf/daytona.env" ]]; then
        info "Preserving existing configuration..."
        cp -f "${EXISTING_BASE}/daytona/conf/daytona.env" /tmp/daytona-env-backup
        UPGRADE_MODE=true
    fi
    daytonactl uninstall 2>/dev/null || true
fi

install_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        info "Docker is already installed and running."
        return 0
    fi

    info "Installing Docker from offline binaries..."
    if [[ ! -d "${SCRIPT_DIR}/docker/bin" ]]; then
        error "Docker binaries not found in ${SCRIPT_DIR}/docker/bin/"
    fi

    cp -f "${SCRIPT_DIR}/docker/bin/containerd" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/containerd-shim-runc-v2" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/ctr" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/docker" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/dockerd" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/docker-init" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/docker-proxy" /usr/bin/
    cp -f "${SCRIPT_DIR}/docker/bin/runc" /usr/bin/
    chmod +x /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 /usr/bin/ctr \
              /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init \
              /usr/bin/docker-proxy /usr/bin/runc

    if [[ -f "${SCRIPT_DIR}/docker/service/docker.service" ]]; then
        cp -f "${SCRIPT_DIR}/docker/service/docker.service" /etc/systemd/system/docker.service
        systemctl daemon-reload
        systemctl enable docker
        systemctl start docker
    fi

    info "Docker installed successfully."
}

install_docker_compose() {
    if command -v "docker-compose" &>/dev/null || docker compose version &>/dev/null; then
        info "Docker Compose is already installed."
        return 0
    fi

    info "Installing docker-compose from offline binaries..."
    if [[ -f "${SCRIPT_DIR}/docker/bin/docker-compose" ]]; then
        cp -f "${SCRIPT_DIR}/docker/bin/docker-compose" /usr/bin/docker-compose
        chmod +x /usr/bin/docker-compose
        info "Docker Compose installed successfully."
    else
        error "docker-compose binary not found in ${SCRIPT_DIR}/docker/bin/"
    fi
}

disable_selinux() {
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
        warn "Disabling SELinux..."
        setenforce 0 2>/dev/null || true
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config 2>/dev/null || true
        sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config 2>/dev/null || true
    fi
}

open_firewall_ports() {
    if systemctl is-active firewalld &>/dev/null; then
        info "Opening firewall ports..."
        firewall-cmd --permanent --add-port="${DAYTONA_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="4000/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="2222/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="5556/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="9001/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="1080/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="5050/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="5100/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="6000/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="16686/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "Firewall ports opened."
    fi
}

setup_directories() {
    info "Creating Daytona directory structure at ${DAYTONA_HOME}..."
    mkdir -p "${DAYTONA_HOME}"/{conf/dex,conf/otel,conf/pgadmin4,data,logs}

    cp -f "${SCRIPT_DIR}/daytona/docker-compose.yml" "${DAYTONA_HOME}/"
    cp -f "${SCRIPT_DIR}/daytona/docker-compose-db.yml" "${DAYTONA_HOME}/"
    cp -f "${SCRIPT_DIR}/daytona/docker-compose-redis.yml" "${DAYTONA_HOME}/"

    cp -f "${SCRIPT_DIR}/daytona/conf/otel/otel-collector-config.yaml" "${DAYTONA_HOME}/conf/otel/"
}

render_templates() {
    info "Rendering configuration templates..."
    if ! command -v envsubst &>/dev/null; then
        apt-get install -y gettext >/dev/null 2>&1 || yum install -y gettext >/dev/null 2>&1 || error "envsubst not found. Please install gettext."
    fi

    envsubst < "${SCRIPT_DIR}/daytona/templates/daytona.env" > "${DAYTONA_HOME}/conf/daytona.env"

    echo "DAYTONA_VERSION=${DAYTONA_VERSION}" >> "${DAYTONA_HOME}/conf/daytona.env"
    echo "DAYTONA_PORT=${DAYTONA_PORT}" >> "${DAYTONA_HOME}/conf/daytona.env"

    cat > "${DAYTONA_HOME}/.env" <<COMPOSEEOF
DAYTONA_VERSION=${DAYTONA_VERSION}
DAYTONA_PORT=${DAYTONA_PORT}
DAYTONA_HOSTNAME=${DAYTONA_HOSTNAME}
DAYTONA_DOCKER_SUBNET=${DAYTONA_DOCKER_SUBNET}
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
MINIO_PORT=${MINIO_PORT}
REGISTRY_ADMIN=${REGISTRY_ADMIN}
REGISTRY_PASSWORD=${REGISTRY_PASSWORD}
DB_PASSWORD=${DB_PASSWORD}
DB_USERNAME=${DB_USERNAME}
DB_DATABASE=${DB_DATABASE}
COMPOSEEOF

    envsubst > "${DAYTONA_HOME}/conf/dex/config.yaml" <<'DEXEOF'
issuer: http://${DAYTONA_HOSTNAME}:5556/dex
storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db

web:
  http: 0.0.0.0:5556
  allowedOrigins: ['*']
  allowedHeaders: ['x-requested-with']
staticClients:
  - id: daytona
    redirectURIs:
      - 'http://${DAYTONA_HOSTNAME}:3000'
      - 'http://${DAYTONA_HOSTNAME}:3000/api/oauth2-redirect.html'
      - 'http://${DAYTONA_HOSTNAME}:3009/callback'
      - 'http://proxy.${DAYTONA_HOSTNAME}:4000/callback'
    name: 'Daytona'
    public: true
enablePasswordDB: true
staticPasswords:
  - email: 'dev@daytona.io'
    hash: '$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W'
    username: 'admin'
    userID: '1234'
DEXEOF

    envsubst > "${DAYTONA_HOME}/conf/pgadmin4/servers.json" <<'PGEOF'
{
  "Servers": {
    "1": {
      "Name": "Daytona",
      "Group": "Servers",
      "Host": "${DB_HOST}",
      "Port": ${DB_PORT},
      "MaintenanceDB": "postgres",
      "Username": "${DB_USERNAME}",
      "PassFile": "/pgpass"
    }
  }
}
PGEOF

    echo "${DB_HOST}:${DB_PORT}:*:${DB_USERNAME}:${DB_PASSWORD}" > "${DAYTONA_HOME}/conf/pgadmin4/pgpass"
    chmod 600 "${DAYTONA_HOME}/conf/pgadmin4/pgpass"

    if [[ "${UPGRADE_MODE}" == "true" && -f /tmp/daytona-env-backup ]]; then
        warn "Upgrade mode: merging preserved configuration..."
        mv /tmp/daytona-env-backup "${DAYTONA_HOME}/conf/daytona.env.preserved"
    fi
}

load_images() {
    info "Loading Docker images..."
    for tar in "${SCRIPT_DIR}/images/"*.tar.gz; do
        if [[ -f "$tar" ]]; then
            info "Loading $(basename "$tar")..."
            docker load < "$tar"
        fi
    done

    info "Tagging images with version ${DAYTONA_VERSION}..."
    local missing=0
    for svc in api proxy runner ssh-gateway otel-collector; do
        if docker image inspect "daytona/daytona-${svc}:${DAYTONA_VERSION}" >/dev/null 2>&1; then
            continue
        fi
        if docker image inspect "daytonaio/daytona-${svc}:latest" >/dev/null 2>&1; then
            docker tag "daytonaio/daytona-${svc}:latest" "daytona/daytona-${svc}:${DAYTONA_VERSION}"
        else
            warn "Image daytona/daytona-${svc}:${DAYTONA_VERSION} not found after load!"
            missing=$((missing + 1))
        fi
    done

    for tag in "${DAYTONA_VERSION}" "${DAYTONA_VERSION}-slim"; do
        if docker image inspect "daytonaio/sandbox:${tag}" >/dev/null 2>&1; then
            docker tag "daytonaio/sandbox:${tag}" "daytona/sandbox:${tag}" 2>/dev/null || true
        fi
    done

    if [[ $missing -gt 0 ]]; then
        error "$missing required images are missing! Check image tar files."
    fi
}

push_sandbox_to_registry() {
    info "Waiting for registry to be available..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -sf http://127.0.0.1:6000/v2/_catalog >/dev/null 2>&1; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done

    info "Pushing sandbox images to local registry..."
    for tag in "${DAYTONA_VERSION}" "${DAYTONA_VERSION}-slim"; do
        if docker image inspect "daytona/sandbox:${tag}" >/dev/null 2>&1; then
            docker tag "daytona/sandbox:${tag}" "registry:6000/daytona/sandbox:${tag}" 2>/dev/null || true
            docker push "registry:6000/daytona/sandbox:${tag}" 2>/dev/null || warn "Failed to push sandbox:${tag} to local registry"
        fi
    done
}

install_daytonactl() {
    info "Installing daytonactl management script..."
    cp -f "${SCRIPT_DIR}/daytonactl" /usr/local/bin/daytonactl
    chmod +x /usr/local/bin/daytonactl
    sed -i "s|^DAYTONA_BASE=.*|DAYTONA_BASE=${DAYTONA_BASE}|" /usr/local/bin/daytonactl
}

start_services() {
    info "Starting Daytona services..."
    cd "${DAYTONA_HOME}"
    docker compose ${COMPOSE_FILES} up -d
}

health_check() {
    info "Performing health check (up to 30 attempts, 3s interval)..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if curl -sf "http://127.0.0.1:${DAYTONA_PORT}/api/config" >/dev/null 2>&1; then
            info "Daytona is healthy!"
            return 0
        fi
        attempts=$((attempts + 1))
        info "Waiting for Daytona to start... (${attempts}/${max_attempts})"
        sleep 3
    done
    warn "Daytona did not become healthy within the expected time."
    warn "Check logs with: daytonactl status"
    return 1
}

print_info() {
    echo ""
    info "=========================================="
    info " Daytona installed successfully!"
    info "=========================================="
    info "Dashboard    : http://${DAYTONA_HOSTNAME}:${DAYTONA_PORT}/dashboard"
    info "API          : http://${DAYTONA_HOSTNAME}:${DAYTONA_PORT}"
    info "Proxy        : http://${DAYTONA_HOSTNAME}:4000"
    info "SSH Gateway  : ssh -p 2222 <token>@${DAYTONA_HOSTNAME}"
    info "Dex (OIDC)   : http://${DAYTONA_HOSTNAME}:5556/dex"
    info "MinIO        : http://${DAYTONA_HOSTNAME}:${MINIO_PORT}"
    info "pgAdmin      : http://${DAYTONA_HOSTNAME}:5050"
    info "Registry UI  : http://${DAYTONA_HOSTNAME}:5100"
    info "Jaeger       : http://${DAYTONA_HOSTNAME}:16686"
    info "MailDev      : http://${DAYTONA_HOSTNAME}:1080"
    info "------------------------------------------"
    info "Management: daytonactl {start|stop|restart|status|uninstall|version}"
    info "=========================================="
}

main() {
    install_docker
    install_docker_compose
    disable_selinux
    setup_directories
    render_templates
    load_images
    install_daytonactl
    open_firewall_ports
    start_services
    push_sandbox_to_registry
    health_check
    print_info
}

main
