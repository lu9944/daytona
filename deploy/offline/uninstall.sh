#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/install.conf"

if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
else
    DAYTONA_BASE="${DAYTONA_BASE:-/opt}"
fi

DAYTONA_HOME="${DAYTONA_BASE}/daytona"

echo -e "${YELLOW}This will completely remove Daytona and all its data.${NC}"
read -rp "Are you sure you want to uninstall? [y/N]: " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    info "Uninstall cancelled."
    exit 0
fi

if command -v daytonactl &>/dev/null; then
    info "Stopping services and removing containers..."
    daytonactl uninstall 2>/dev/null || true
fi

info "Removing Daytona images..."
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^daytona/' | while read -r img; do
    docker rmi "$img" 2>/dev/null || true
done
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^daytonaio/' | while read -r img; do
    docker rmi "$img" 2>/dev/null || true
done

info "Removing Daytona runtime directory: ${DAYTONA_HOME}..."
rm -rf "${DAYTONA_HOME}"

info "Removing daytonactl..."
rm -f /usr/local/bin/daytonactl

info "Daytona has been uninstalled successfully."
