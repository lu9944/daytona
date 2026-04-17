#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"
DAYS_VALID=3650

DAYTONA_DOMAIN="${DAYTONA_DOMAIN:-daytona.example.com}"
KEYCLOAK_DOMAIN="${KEYCLOAK_DOMAIN:-auth.example.com}"

echo "=== Generating SSL certificates ==="
echo "    Daytona domain: ${DAYTONA_DOMAIN}"
echo "    Keycloak domain: ${KEYCLOAK_DOMAIN}"

mkdir -p "${CERT_DIR}"

if command -v openssl &>/dev/null; then
    echo "[OK] openssl found"
else
    echo "[ERROR] openssl not found. Please install openssl first."
    exit 1
fi

CA_KEY="${CERT_DIR}/ca.key"
CA_CERT="${CERT_DIR}/ca.crt"

if [ ! -f "${CA_KEY}" ] || [ ! -f "${CA_CERT}" ]; then
    echo "--- Generating CA certificate ---"
    openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null
    openssl req -new -x509 -days ${DAYS_VALID} \
        -key "${CA_KEY}" \
        -out "${CA_CERT}" \
        -subj "/C=US/ST=California/L=San Francisco/O=Daytona Local CA/CN=Daytona Local CA" \
        2>/dev/null
    echo "[OK] CA certificate generated: ${CA_CERT}"
else
    echo "[SKIP] CA certificate already exists"
fi

generate_cert() {
    local domain="$1"
    local cert_key="${CERT_DIR}/${domain}.key"
    local cert_csr="${CERT_DIR}/${domain}.csr"
    local cert_crt="${CERT_DIR}/${domain}.crt"
    local cert_ext="${CERT_DIR}/${domain}.ext"

    if [ -f "${cert_crt}" ] && [ -f "${cert_key}" ]; then
        echo "[SKIP] Certificate for ${domain} already exists"
        return 0
    fi

    echo "--- Generating certificate for ${domain} ---"

    openssl genrsa -out "${cert_key}" 2048 2>/dev/null

    openssl req -new \
        -key "${cert_key}" \
        -out "${cert_csr}" \
        -subj "/C=US/ST=California/L=San Francisco/O=Daytona/CN=${domain}" \
        2>/dev/null

    cat > "${cert_ext}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF

    openssl x509 -req -days ${DAYS_VALID} \
        -in "${cert_csr}" \
        -CA "${CA_CERT}" \
        -CAkey "${CA_KEY}" \
        -CAcreateserial \
        -out "${cert_crt}" \
        -extfile "${cert_ext}" \
        2>/dev/null

    rm -f "${cert_csr}" "${cert_ext}"

    echo "[OK] Certificate generated: ${cert_crt}"
}

generate_cert "${DAYTONA_DOMAIN}"
generate_cert "${KEYCLOAK_DOMAIN}"

echo ""
echo "=== SSL certificates ready ==="
echo ""
echo "To trust the CA on your machine:"
echo ""
echo "  # Linux (Debian/Ubuntu):"
echo "  sudo cp ${CA_CERT} /usr/local/share/ca-certificates/daytona-local-ca.crt"
echo "  sudo update-ca-certificates"
echo ""
echo "  # macOS:"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_CERT}"
echo ""
echo "  # Windows:"
echo "  certutil -addstore -f \"ROOT\" ${CA_CERT}"
