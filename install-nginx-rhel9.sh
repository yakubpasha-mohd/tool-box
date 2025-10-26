#!/usr/bin/env bash
# Install and configure nginx on RHEL9 (EC2)
# Creates a minimal custom configuration under /opt/custom/nginx
# Idempotent-ish: safe to re-run

set -euo pipefail

CUSTOM_DIR="/opt/custom/nginx"
CUSTOM_CONFDIR="${CUSTOM_DIR}/conf.d"
CUSTOM_HTML="${CUSTOM_DIR}/html"
INCLUDE_DROPIN="/etc/nginx/conf.d/99-custom-include.conf"

echo "==> Running nginx install + custom config script for RHEL9"

# 1) Install nginx
echo "==> Installing nginx and utilities..."
if ! command -v nginx >/dev/null 2>&1; then
  dnf -y install nginx
else
  echo "nginx already installed; skipping install."
fi

# Install semanage utility if SELinux tools are required (for file contexts)
if getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  if ! command -v semanage >/dev/null 2>&1; then
    echo "==> Installing semanage (policycoreutils-python-utils) for SELinux file contexts..."
    dnf -y install policycoreutils-python-utils || {
      echo "Warning: could not install policycoreutils-python-utils. You may need to manually set SELinux contexts."
    }
  fi
fi

# 2) Create custom directories and minimal files
echo "==> Creating custom config directory: ${CUSTOM_DIR}"
mkdir -p "${CUSTOM_CONFDIR}"
mkdir -p "${CUSTOM_HTML}"

# 3) Write a minimal nginx main file in /opt/custom/nginx (optional)
# We'll create an include drop-in in /etc/nginx/conf.d that includes files inside /opt/custom/nginx/conf.d/*.conf
echo "==> Creating include drop-in at ${INCLUDE_DROPIN} to load ${CUSTOM_DIR}/conf.d/*.conf"
cat > "${INCLUDE_DROPIN}" <<'EOF'
# This file loads any custom server blocks placed in /opt/custom/nginx/conf.d/
# Keep this file for idempotent custom include.
# Do not modify unless you know what you're doing.
include /opt/custom/nginx/conf.d/*.conf;
EOF

# 4) Create a minimal server block in custom conf.d
CUSTOM_SERVER_CONF="${CUSTOM_CONFDIR}/00-default.conf"
echo "==> Creating minimal server block: ${CUSTOM_SERVER_CONF}"
cat > "${CUSTOM_SERVER_CONF}" <<EOF
server {
    listen       80 default_server;
    listen       [::]:80 default_server;
    server_name  _;
    root         ${CUSTOM_HTML};
    index        index.html index.htm;

    access_log  /var/log/nginx/custom_access.log;
    error_log   /var/log/nginx/custom_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Simple health endpoint
    location = /health {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
EOF

# 5) Create a minimal index.html
INDEX_FILE="${CUSTOM_HTML}/index.html"
if [ ! -f "${INDEX_FILE}" ]; then
  echo "==> Creating sample index at ${INDEX_FILE}"
  cat > "${INDEX_FILE}" <<EOF
<html>
<head><title>nginx on RHEL9 (custom)</title></head>
<body>
<h1>nginx on RHEL9</h1>
<p>Served from: ${CUSTOM_HTML}</p>
</body>
</html>
EOF
else
  echo "Index already exists at ${INDEX_FILE}; leaving it."
fi

# 6) SELinux: set correct context for nginx to read files
if getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  echo "==> Applying SELinux contexts to ${CUSTOM_DIR} so nginx can serve files..."
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "${CUSTOM_DIR}(/.*)?" || true
    restorecon -Rv "${CUSTOM_DIR}" || true
  else
    echo "Note: semanage not available. Running restorecon only (may not be sufficient):"
    restorecon -Rv "${CUSTOM_DIR}" || true
    echo "If SELinux denies access, install policycoreutils-python-utils and run semanage fcontext as root."
  fi
else
  echo "SELinux disabled or not present; skipping SELinux context steps."
fi

# 7) Ensure nginx service enabled and started
echo "==> Enabling and starting nginx service..."
systemctl enable --now nginx

# 8) Configure firewall (firewalld) — optional, only if firewalld running
if systemctl is-active --quiet firewalld; then
  echo "==> Adding firewall rules for http and https (firewalld)..."
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
else
  echo "firewalld not active; skipping firewall-cmd steps. (On EC2, also ensure the Security Group allows inbound 80/443.)"
fi

# 9) Test nginx configuration and reload
echo "==> Testing nginx configuration..."
nginx -t

echo "==> Reloading nginx to apply configuration..."
systemctl reload nginx

echo "==> Done. Custom nginx files installed to ${CUSTOM_DIR}"
echo "Access the server on port 80 (ensure EC2 Security Group allows inbound TCP:80)."
