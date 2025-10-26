#!/usr/bin/env bash
# Install and configure nginx on Amazon Linux 2023 (EC2)
# Creates a minimal custom configuration under /opt/custom/nginx
# Idempotent-ish: safe to re-run
#
# Notes:
# - Designed for Amazon Linux 2023 (ID contains "amzn" / VERSION_ID starts with "2023").
# - Uses dnf for package installs (AL2023 uses dnf).
# - Attempts several common SELinux helper package names as some repos differ.
# - If SELinux tools are not available, it will run restorecon and warn.

set -euo pipefail

CUSTOM_DIR="/opt/custom/nginx"
CUSTOM_CONFDIR="${CUSTOM_DIR}/conf.d"
CUSTOM_HTML="${CUSTOM_DIR}/html"
INCLUDE_DROPIN="/etc/nginx/conf.d/99-custom-include.conf"

echo "==> Running nginx install + custom config script for Amazon Linux 2023"

# Basic distro detection (just to warn if not Amazon Linux)
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME="${NAME:-}${ID:-}"
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
else
  OS_NAME="unknown"
  OS_ID="unknown"
  OS_VERSION="unknown"
fi

if ! echo "${OS_NAME} ${OS_ID} ${OS_VERSION}" | grep -qi "amzn\|amazon"; then
  echo "Warning: This script is tuned for Amazon Linux 2023 but this host reports: ${OS_NAME} ${OS_VERSION}"
  echo "Continuing anyway..."
fi

# 1) Install nginx and utilities
echo "==> Installing nginx and utilities..."
if ! command -v nginx >/dev/null 2>&1; then
  # Attempt a normal dnf install
  if dnf -y install nginx; then
    echo "nginx installed."
  else
    echo "dnf install nginx failed. Trying to enable repositories and retry..."
    # try to enable common repos if present, then retry once
    dnf -y makecache || true
    if ! dnf -y install nginx; then
      echo "Error: Could not install nginx via dnf. Please check your repositories."
      exit 1
    fi
  fi
else
  echo "nginx already installed; skipping install."
fi

# 1b) Ensure /usr/sbin is in PATH for systemd services if script run with minimal PATH
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin"

# 2) SELinux helper tooling detection & install (try several package names)
# Amazon Linux 2023 may use different package names for semanage; try common ones.
try_install_semanage_pkg() {
  local pkgs=(policycoreutils-python-utils policycoreutils-python policycoreutils-python-utils-2 policycoreutils)
  for pkg in "${pkgs[@]}"; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
      # already present
      return 0
    fi
  done

  for pkg in "${pkgs[@]}"; do
    echo "==> Attempting to install SELinux helper package: ${pkg} (may fail if not available)..."
    if dnf -y install "${pkg}" >/dev/null 2>&1; then
      echo "Installed ${pkg}"
      return 0
    fi
  done

  return 1
}

if getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  if ! command -v semanage >/dev/null 2>&1; then
    echo "==> semanage not present. Trying to install SELinux helper packages..."
    if try_install_semanage_pkg; then
      echo "semanage (or equivalent) provisioned."
    else
      echo "Warning: could not install semanage helper packages. SELinux file context changes may be incomplete."
    fi
  else
    echo "semanage present; skipping install."
  fi
else
  echo "SELinux disabled or not present; skipping semanage install attempts."
fi

# 3) Create custom directories and minimal files
echo "==> Creating custom config directory: ${CUSTOM_DIR}"
mkdir -p "${CUSTOM_CONFDIR}"
mkdir -p "${CUSTOM_HTML}"
chown -R root:root "${CUSTOM_DIR}" || true
chmod -R 0755 "${CUSTOM_DIR}" || true

# 4) Write an include drop-in in /etc/nginx/conf.d to load /opt/custom/nginx/conf.d/*.conf
echo "==> Creating include drop-in at ${INCLUDE_DROPIN} to load ${CUSTOM_DIR}/conf.d/*.conf"
cat > "${INCLUDE_DROPIN}" <<'EOF'
# This file loads any custom server blocks placed in /opt/custom/nginx/conf.d/
# Keep this file for idempotent custom include.
# Do not modify unless you know what you're doing.
include /opt/custom/nginx/conf.d/*.conf;
EOF

# 5) Create a minimal server block in custom conf.d
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
        default_type text/plain;
        return 200 'ok';
    }
}
EOF

# 6) Create a minimal index.html (only if it doesn't already exist)
INDEX_FILE="${CUSTOM_HTML}/index.html"
if [ ! -f "${INDEX_FILE}" ]; then
  echo "==> Creating sample index at ${INDEX_FILE}"
  cat > "${INDEX_FILE}" <<EOF
<html>
<head><title>nginx on Amazon Linux 2023 (custom)</title></head>
<body>
<h1>nginx on Amazon Linux 2023</h1>
<p>Served from: ${CUSTOM_HTML}</p>
</body>
</html>
EOF
else
  echo "Index already exists at ${INDEX_FILE}; leaving it."
fi

# 7) SELinux: set correct context for nginx to read files (best-effort)
if getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  echo "==> Applying SELinux contexts to ${CUSTOM_DIR} so nginx can serve files (best-effort)..."
  if command -v semanage >/dev/null 2>&1; then
    # Add fcontext rule (idempotent)
    semanage fcontext -a -t httpd_sys_content_t "${CUSTOM_DIR}(/.*)?" || true
    restorecon -Rv "${CUSTOM_DIR}" || true
  else
    echo "Note: semanage not available. Running restorecon only (may not be sufficient):"
    restorecon -Rv "${CUSTOM_DIR}" || true
    echo "If SELinux denies access, install an appropriate package that provides semanage and run:"
    echo "  semanage fcontext -a -t httpd_sys_content_t '${CUSTOM_DIR}(/.*)?' && restorecon -Rv '${CUSTOM_DIR}'"
  fi
else
  echo "SELinux disabled or not present; skipping SELinux context steps."
fi

# 8) Ensure nginx service enabled and started
echo "==> Enabling and starting nginx service..."
if systemctl enable --now nginx; then
  echo "nginx enabled and started."
else
  echo "Warning: systemctl failed to enable/start nginx. Check 'systemctl status nginx' for details."
fi

# 9) Configure firewall (firewalld) — optional, only if firewalld running
if systemctl is-active --quiet firewalld >/dev/null 2>&1; then
  echo "==> Adding firewall rules for http and https (firewalld)..."
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
else
  echo "firewalld not active; skipping firewall-cmd steps. (On EC2, also ensure the Security Group allows inbound 80/443.)"
fi

# 10) Test nginx configuration and reload
echo "==> Testing nginx configuration..."
if nginx -t; then
  echo "nginx configuration OK."
  echo "==> Reloading nginx to apply configuration..."
  systemctl reload nginx || {
    echo "Warning: reload failed; attempting restart..."
    systemctl restart nginx || {
      echo "Error: could not reload or restart nginx. Check journalctl -u nginx.service"
      exit 1
    }
  }
else
  echo "nginx configuration test failed. Aborting reload."
  exit 1
fi

echo "==> Done. Custom nginx files installed to ${CUSTOM_DIR}"
echo "Access the server on port 80 (ensure EC2 Security Group allows inbound TCP:80)."

==========
[ec2-user@ip-172-31-88-106 ~]$ vi install-nginx.sh
[ec2-user@ip-172-31-88-106 ~]$ chmod +x install-nginx.sh
[ec2-user@ip-172-31-88-106 ~]$ sh install-nginx.sh
==> Running nginx install + custom config script for Amazon Linux 2023
==> Installing nginx and utilities...
Error: This command has to be run with superuser privileges (under the root user on most systems).
dnf install nginx failed. Trying to enable repositories and retry...
Node.js Packages for Linux RPM based distros - x86_64                                                                                                     16 MB/s | 1.0 MB     00:00
N|Solid Packages for Linux RPM based distros - x86_64                                                                                                     13 MB/s | 840 kB     00:00
Amazon Linux 2023 repository                                                                                                                              66 MB/s |  47 MB     00:00
Amazon Linux 2023 Kernel Livepatch repository                                                                                                            186 kB/s |  26 kB     00:00
MySQL 8.0 Community Server                                                                                                                                46 MB/s | 2.9 MB     00:00
MySQL Connectors Community                                                                                                                               6.2 MB/s |  98 kB     00:00
MySQL Tools Community                                                                                                                                     44 MB/s | 1.3 MB     00:00
Metadata cache created.
Error: This command has to be run with superuser privileges (under the root user on most systems).
Error: Could not install nginx via dnf. Please check your repositories.
[ec2-user@ip-172-31-88-106 ~]$ sudo sh install-nginx.sh
==> Running nginx install + custom config script for Amazon Linux 2023
==> Installing nginx and utilities...
Node.js Packages for Linux RPM based distros - x86_64                                                                                                     16 MB/s | 1.0 MB     00:00
N|Solid Packages for Linux RPM based distros - x86_64                                                                                                     10 MB/s | 840 kB     00:00
Amazon Linux 2023 repository                                                                                                                              69 MB/s |  47 MB     00:00
Amazon Linux 2023 Kernel Livepatch repository                                                                                                            157 kB/s |  26 kB     00:00
MySQL 8.0 Community Server                                                                                                                                58 MB/s | 2.9 MB     00:00
MySQL Connectors Community                                                                                                                               6.8 MB/s |  98 kB     00:00
MySQL Tools Community                                                                                                                                     31 MB/s | 1.3 MB     00:00
Dependencies resolved.
=========================================================================================================================================================================================
 Package                                         Architecture                       Version                                                Repository                               Size
=========================================================================================================================================================================================
Installing:
 nginx                                           x86_64                             1:1.28.0-1.amzn2023.0.2                                amazonlinux                              33 k
Installing dependencies:
 generic-logos-httpd                             noarch                             18.0.0-12.amzn2023.0.3                                 amazonlinux                              19 k
 gperftools-libs                                 x86_64                             2.9.1-1.amzn2023.0.3                                   amazonlinux                             308 k
 libunwind                                       x86_64                             1.4.0-5.amzn2023.0.3                                   amazonlinux                              66 k
 nginx-core                                      x86_64                             1:1.28.0-1.amzn2023.0.2                                amazonlinux                             686 k
 nginx-filesystem                                noarch                             1:1.28.0-1.amzn2023.0.2                                amazonlinux                             9.6 k
 nginx-mimetypes                                 noarch                             2.1.49-3.amzn2023.0.3                                  amazonlinux                              21 k

Transaction Summary
=========================================================================================================================================================================================
Install  7 Packages

Total download size: 1.1 M
Installed size: 3.7 M
Downloading Packages:
(1/7): generic-logos-httpd-18.0.0-12.amzn2023.0.3.noarch.rpm                                                                                             511 kB/s |  19 kB     00:00
(2/7): gperftools-libs-2.9.1-1.amzn2023.0.3.x86_64.rpm                                                                                                   6.3 MB/s | 308 kB     00:00
(3/7): libunwind-1.4.0-5.amzn2023.0.3.x86_64.rpm                                                                                                         1.1 MB/s |  66 kB     00:00
(4/7): nginx-1.28.0-1.amzn2023.0.2.x86_64.rpm                                                                                                            1.4 MB/s |  33 kB     00:00
(5/7): nginx-core-1.28.0-1.amzn2023.0.2.x86_64.rpm                                                                                                        23 MB/s | 686 kB     00:00
(6/7): nginx-filesystem-1.28.0-1.amzn2023.0.2.noarch.rpm                                                                                                 448 kB/s | 9.6 kB     00:00
(7/7): nginx-mimetypes-2.1.49-3.amzn2023.0.3.noarch.rpm                                                                                                  981 kB/s |  21 kB     00:00
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Total                                                                                                                                                    9.9 MB/s | 1.1 MB     00:00
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                 1/1
  Running scriptlet: nginx-filesystem-1:1.28.0-1.amzn2023.0.2.noarch                                                                                                                 1/7
  Installing       : nginx-filesystem-1:1.28.0-1.amzn2023.0.2.noarch                                                                                                                 1/7
  Installing       : nginx-mimetypes-2.1.49-3.amzn2023.0.3.noarch                                                                                                                    2/7
  Installing       : libunwind-1.4.0-5.amzn2023.0.3.x86_64                                                                                                                           3/7
  Installing       : gperftools-libs-2.9.1-1.amzn2023.0.3.x86_64                                                                                                                     4/7
  Installing       : nginx-core-1:1.28.0-1.amzn2023.0.2.x86_64                                                                                                                       5/7
  Installing       : generic-logos-httpd-18.0.0-12.amzn2023.0.3.noarch                                                                                                               6/7
  Installing       : nginx-1:1.28.0-1.amzn2023.0.2.x86_64                                                                                                                            7/7
  Running scriptlet: nginx-1:1.28.0-1.amzn2023.0.2.x86_64                                                                                                                            7/7
  Verifying        : generic-logos-httpd-18.0.0-12.amzn2023.0.3.noarch                                                                                                               1/7
  Verifying        : gperftools-libs-2.9.1-1.amzn2023.0.3.x86_64                                                                                                                     2/7
  Verifying        : libunwind-1.4.0-5.amzn2023.0.3.x86_64                                                                                                                           3/7
  Verifying        : nginx-1:1.28.0-1.amzn2023.0.2.x86_64                                                                                                                            4/7
  Verifying        : nginx-core-1:1.28.0-1.amzn2023.0.2.x86_64                                                                                                                       5/7
  Verifying        : nginx-filesystem-1:1.28.0-1.amzn2023.0.2.noarch                                                                                                                 6/7
  Verifying        : nginx-mimetypes-2.1.49-3.amzn2023.0.3.noarch                                                                                                                    7/7

Installed:
  generic-logos-httpd-18.0.0-12.amzn2023.0.3.noarch  gperftools-libs-2.9.1-1.amzn2023.0.3.x86_64      libunwind-1.4.0-5.amzn2023.0.3.x86_64         nginx-1:1.28.0-1.amzn2023.0.2.x86_64
  nginx-core-1:1.28.0-1.amzn2023.0.2.x86_64          nginx-filesystem-1:1.28.0-1.amzn2023.0.2.noarch  nginx-mimetypes-2.1.49-3.amzn2023.0.3.noarch

Complete!
nginx installed.
semanage present; skipping install.
==> Creating custom config directory: /opt/custom/nginx
==> Creating include drop-in at /etc/nginx/conf.d/99-custom-include.conf to load /opt/custom/nginx/conf.d/*.conf
==> Creating minimal server block: /opt/custom/nginx/conf.d/00-default.conf
==> Creating sample index at /opt/custom/nginx/html/index.html
==> Applying SELinux contexts to /opt/custom/nginx so nginx can serve files (best-effort)...
Relabeled /opt/custom/nginx from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /opt/custom/nginx/conf.d from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /opt/custom/nginx/conf.d/00-default.conf from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /opt/custom/nginx/html from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /opt/custom/nginx/html/index.html from unconfined_u:object_r:usr_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
==> Enabling and starting nginx service...
Created symlink /etc/systemd/system/multi-user.target.wants/nginx.service → /usr/lib/systemd/system/nginx.service.
nginx enabled and started.
firewalld not active; skipping firewall-cmd steps. (On EC2, also ensure the Security Group allows inbound 80/443.)
==> Testing nginx configuration...
nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
nginx: [warn] conflicting server name "_" on [::]:80, ignored
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
nginx configuration OK.
==> Reloading nginx to apply configuration...
==> Done. Custom nginx files installed to /opt/custom/nginx
Access the server on port 80 (ensure EC2 Security Group allows inbound TCP:80).
[ec2-user@ip-172-31-88-106 ~]$ cd /opt/custom/nginx
[ec2-user@ip-172-31-88-106 nginx]$ ls -ltr
total 0
drwxr-xr-x. 2 root root 24 Oct 26 11:47 html
drwxr-xr-x. 2 root root 29 Oct 26 11:47 conf.d
[ec2-user@ip-172-31-88-106 nginx]$ cd conf.d/
[ec2-user@ip-172-31-88-106 conf.d]$ ls -ltr
total 4
-rw-r--r--. 1 root root 466 Oct 26 11:47 00-default.conf
[ec2-user@ip-172-31-88-106 conf.d]$ cat 00-default.conf
server {
    listen       80 default_server;
    listen       [::]:80 default_server;
    server_name  _;
    root         /opt/custom/nginx/html;
    index        index.html index.htm;

    access_log  /var/log/nginx/custom_access.log;
    error_log   /var/log/nginx/custom_error.log;

    location / {
        try_files $uri $uri/ =404;
    }

    # Simple health endpoint
    location = /health {
        default_type text/plain;
        return 200 'ok';
    }
}
[ec2-user@ip-172-31-88-106 conf.d]$ sudo systemctl status nginx
● nginx.service - The nginx HTTP and reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled; preset: disabled)
     Active: active (running) since Sun 2025-10-26 11:47:44 UTC; 1min 22s ago
    Process: 30989 ExecStartPre=/usr/bin/rm -f /run/nginx.pid (code=exited, status=0/SUCCESS)
    Process: 30990 ExecStartPre=/usr/sbin/nginx -t (code=exited, status=0/SUCCESS)
    Process: 30991 ExecStart=/usr/sbin/nginx (code=exited, status=0/SUCCESS)
    Process: 30998 ExecReload=/usr/sbin/nginx -s reload (code=exited, status=0/SUCCESS)
   Main PID: 30992 (nginx)
      Tasks: 2 (limit: 1106)
     Memory: 3.2M
        CPU: 94ms
     CGroup: /system.slice/nginx.service
             ├─30992 "nginx: master process /usr/sbin/nginx"
             └─30999 "nginx: worker process"

Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30990]: nginx: [warn] conflicting server name "_" on [::]:80, ignored
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30990]: nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30990]: nginx: configuration file /etc/nginx/nginx.conf test is successful
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30991]: nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30991]: nginx: [warn] conflicting server name "_" on [::]:80, ignored
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal systemd[1]: Started nginx.service - The nginx HTTP and reverse proxy server.
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal systemd[1]: Reloading nginx.service - The nginx HTTP and reverse proxy server...
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30998]: nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal nginx[30998]: nginx: [warn] conflicting server name "_" on [::]:80, ignored
Oct 26 11:47:44 ip-172-31-88-106.ec2.internal systemd[1]: Reloaded nginx.service - The nginx HTTP and reverse proxy server.
[ec2-user@ip-172-31-88-106 conf.d]$
=====
testing from browser :

nginx on Amazon Linux 2023
Served from: /opt/custom/nginx/html
