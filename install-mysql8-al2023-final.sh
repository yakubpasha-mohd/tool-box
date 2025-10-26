#!/usr/bin/env bash
# install-mysql8-al2023-final.sh
# Amazon Linux 2023 — Install MySQL 8.x (mysql80-community repo) with GPG key import
# Usage:
#   sudo ./install-mysql8-al2023-final.sh <DB_NAME> <DB_USER> <DB_PASSWORD> [ROOT_PASSWORD] [ALLOW_REMOTE]
# Example:
#   sudo ./install-mysql8-al2023-final.sh healthcare_db healthuser 'Health@123' 'Root@123' yes

set -euo pipefail

# === INPUT VALIDATION ===
if [ $# -lt 3 ]; then
  echo "Usage: sudo $0 <DB_NAME> <DB_USER> <DB_PASSWORD> [ROOT_PASSWORD] [ALLOW_REMOTE]"
  exit 1
fi

DB_NAME="$1"
DB_USER="$2"
DB_PASS="$3"
ROOT_PASSWORD="${4:-ChangeMeRoot@2025}"
ALLOW_REMOTE="${5:-no}"

BIND_ADDRESS="127.0.0.1"
if [[ "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
  BIND_ADDRESS="0.0.0.0"
fi

EL9_RPM_URL="https://dev.mysql.com/get/mysql80-community-release-el9-3.noarch.rpm"
TMP_RPM="/tmp/mysql80-el9.rpm"
PKG_MGR="dnf"
MY_CNF="/etc/my.cnf"

# === OS CHECK: ensure Amazon Linux 2023 ===
if [ -r /etc/os-release ]; then
  . /etc/os-release
  DETECT_ID="${ID:-}"
  DETECT_VERSION="${VERSION_ID:-}"
else
  echo "Cannot detect OS. /etc/os-release missing."
  exit 1
fi

if ! echo "${DETECT_ID}" | grep -qi '^amzn'; then
  echo "This script targets Amazon Linux (amzn). Detected ID='${DETECT_ID}'. Exiting."
  exit 1
fi

if ! echo "${DETECT_VERSION}" | grep -q '^2023'; then
  echo "This script is intended for Amazon Linux 2023. Detected VERSION_ID='${DETECT_VERSION}'. Exiting."
  exit 1
fi

echo "Installing MySQL 8 on Amazon Linux 2023..."
echo " DB: ${DB_NAME}  USER: ${DB_USER}  REMOTE: ${ALLOW_REMOTE}"

# === Basic prep: upgrade & install prerequisites ===
sudo ${PKG_MGR} -y upgrade || true
sudo ${PKG_MGR} -y install curl xz libaio openssl dnf-plugins-core -y || true

# === Download & install EL9 MySQL repo RPM ===
echo "Downloading MySQL EL9 repo RPM..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${EL9_RPM_URL}" -o "${TMP_RPM}"
else
  wget -qO "${TMP_RPM}" "${EL9_RPM_URL}"
fi

echo "Installing MySQL repo RPM..."
sudo ${PKG_MGR} -y localinstall "${TMP_RPM}" || sudo rpm -Uvh "${TMP_RPM}"

# === Import MySQL GPG keys to avoid 'GPG check FAILED' ===
echo "Importing MySQL GPG keys..."
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 2>/dev/null || true
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022 2>/dev/null || true
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql 2>/dev/null || true

# === Ensure mysql80 repo is enabled (prefer mysql80 packages) ===
echo "Enabling mysql80-community repository..."
if command -v dnf >/dev/null 2>&1; then
  sudo dnf config-manager --set-enabled mysql80-community || true
  # disable older mysql repos if present
  sudo dnf config-manager --set-disabled mysql57-community mysql56-community || true
fi

# Clean metadata then install MySQL server (8.0)
sudo ${PKG_MGR} -y clean all || true
sudo ${PKG_MGR} -y makecache || true

echo "Installing mysql-community-server (MySQL 8.0)..."
if ! sudo ${PKG_MGR} -y install mysql-community-server; then
  echo "ERROR: dnf install mysql-community-server failed. Run 'sudo dnf repolist' and check repo GPG keys or network."
  exit 1
fi

# === Start and enable mysqld ===
sudo systemctl enable --now mysqld
# wait for mysqld to become ready
echo "Waiting for mysqld to become available..."
RETRIES=15
SLEEP=2
for i in $(seq 1 $RETRIES); do
  if sudo mysqladmin ping >/dev/null 2>&1; then
    echo "mysqld is up (attempt $i)."
    break
  fi
  echo "mysqld not ready yet (attempt $i/$RETRIES). Sleeping ${SLEEP}s..."
  sleep ${SLEEP}
done

# === Secure MySQL root account (handle temp password or socket auth) ===
echo "Configuring MySQL root account and basic security..."
TEMP_PASS=""
if [ -f /var/log/mysqld.log ]; then
  TEMP_PASS=$(grep -i "temporary password" /var/log/mysqld.log | awk '{print $NF}' | tail -n1 || true)
fi

read -r -d '' SECURE_SQL <<'EOF' || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '__ROOT_PASS__';
DELETE FROM mysql.user WHERE User='';
DROP USER IF EXISTS 'root'@'%';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\_%';
FLUSH PRIVILEGES;
EOF
SECURE_SQL="${SECURE_SQL//__ROOT_PASS__/${ROOT_PASSWORD}}"

if [ -n "${TEMP_PASS}" ]; then
  echo "Using temporary root password from /var/log/mysqld.log to set provided root password..."
  sudo mysql --connect-expired-password -u root -p"${TEMP_PASS}" <<SQL || true
${SECURE_SQL}
SQL
else
  if sudo mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    echo "Socket/no-password root access works — applying secure SQL..."
    sudo mysql -u root <<SQL || true
${SECURE_SQL}
SQL
  else
    echo "No temp password and socket access failed — attempting best-effort (may show harmless errors)..."
    sudo mysql --connect-expired-password -u root <<SQL || true
${SECURE_SQL}
SQL
  fi
fi

# === Create application DB and user ===
echo "Creating database '${DB_NAME}' and user '${DB_USER}' (host: ${ALLOW_REMOTE})..."
USER_HOST="%"
if [[ ! "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
  USER_HOST="localhost"
fi

sudo mysql -u root -p"${ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${USER_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${USER_HOST}';
FLUSH PRIVILEGES;
SQL

# === Configure remote bind-address if requested ===
if [[ "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
  echo "Enabling remote access (bind-address = ${BIND_ADDRESS})..."
  if [ -f "${MY_CNF}" ]; then
    if grep -q "^[[:space:]]*bind-address" "${MY_CNF}" 2>/dev/null; then
      sudo sed -i "s/^\\([[:space:]]*bind-address\\).*/bind-address = ${BIND_ADDRESS}/" "${MY_CNF}"
    else
      if grep -q "^\[mysqld\]" "${MY_CNF}"; then
        sudo sed -i "/^\[mysqld\]/a bind-address = ${BIND_ADDRESS}" "${MY_CNF}"
      else
        echo -e "[mysqld]\nbind-address = ${BIND_ADDRESS}" | sudo tee -a "${MY_CNF}" >/dev/null
      fi
    fi
  else
    echo -e "[mysqld]\nbind-address = ${BIND_ADDRESS}" | sudo tee "${MY_CNF}" >/dev/null
  fi
  sudo systemctl restart mysqld || true
fi

# === Firewall handling (firewalld) ===
if command -v firewall-cmd >/dev/null 2>&1; then
  if [[ "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
    sudo firewall-cmd --permanent --add-port=3306/tcp || true
    sudo firewall-cmd --reload || true
  else
    sudo firewall-cmd --permanent --remove-port=3306/tcp 2>/dev/null || true
    sudo firewall-cmd --reload || true
  fi
fi

# === Completion message ===
echo "✅ MySQL 8 installation & initial configuration finished!"
echo "----------------------------------------"
echo "Root login : mysql -u root -p"
echo "Root Pass  : ${ROOT_PASSWORD}"
echo "DB Name    : ${DB_NAME}"
echo "DB User    : ${DB_USER}@${USER_HOST}"
echo "DB Pass    : ${DB_PASS}"
echo "----------------------------------------"
if [[ "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
  echo "Remote access enabled. Ensure your EC2 Security Group allows TCP/3306 from trusted IPs only."
else
  echo "Remote access disabled (bind-address left as 127.0.0.1 or user host = ${USER_HOST})."
fi
echo "To test locally: mysql -u ${DB_USER} -p${DB_PASS} ${DB_NAME}"
if [[ "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
  echo "To test remotely (replace <EC2-PUBLIC-IP>): mysql -h <EC2-PUBLIC-IP> -u ${DB_USER} -p${DB_PASS} ${DB_NAME}"
fi

exit 0
==============
logs

[ec2-user@ip-172-31-88-106 ~]$ sudo ./install-mysql8-al2023-final.sh healthcare_db healthuser 'Health@123' 'Root@123' yes
Installing MySQL 8 on Amazon Linux 2023...
 DB: healthcare_db  USER: healthuser  REMOTE: yes
Amazon Linux 2023 repository                                                                                                                              67 MB/s |  47 MB     00:00
Amazon Linux 2023 Kernel Livepatch repository                                                                                                            246 kB/s |  26 kB     00:00
Dependencies resolved.
Nothing to do.
Complete!
Last metadata expiration check: 0:00:02 ago on Sun Oct 26 11:23:27 2025.
Package xz-5.2.5-9.amzn2023.0.2.x86_64 is already installed.
Package libaio-0.3.111-11.amzn2023.0.2.x86_64 is already installed.
Package openssl-1:3.2.2-1.amzn2023.0.2.x86_64 is already installed.
Package dnf-plugins-core-4.3.0-13.amzn2023.0.5.noarch is already installed.
Error:
 Problem: problem with installed package curl-minimal-8.11.1-4.amzn2023.0.1.x86_64
  - package curl-minimal-8.11.1-4.amzn2023.0.1.x86_64 from @System conflicts with curl provided by curl-7.87.0-2.amzn2023.0.2.x86_64 from amazonlinux
  - package curl-minimal-7.87.0-2.amzn2023.0.2.x86_64 from amazonlinux conflicts with curl provided by curl-7.87.0-2.amzn2023.0.2.x86_64 from amazonlinux
  - package curl-minimal-7.88.0-1.amzn2023.0.1.x86_64 from amazonlinux conflicts with curl provided by curl-7.87.0-2.amzn2023.0.2.x86_64 from amazonlinux
  
  - package curl-minimal-8.5.0-1.amzn2023.0.3.x86_64 from amazonlinux conflicts with curl provided by curl-8.11.1-4.amzn2023.0.1.x86_64 from amazonlinux
  - package curl-minimal-8.5.0-1.amzn2023.0.4.x86_64 from amazonlinux conflicts with curl provided by curl-8.11.1-4.amzn2023.0.1.x86_64 from amazonlinux
  - package curl-minimal-8.5.0-1.amzn2023.0.5.x86_64 from amazonlinux conflicts with curl provided by curl-8.11.1-4.amzn2023.0.1.x86_64 from amazonlinux
(try to add '--allowerasing' to command line to replace conflicting packages or '--skip-broken' to skip uninstallable packages)
Downloading MySQL EL9 repo RPM...
Installing MySQL repo RPM...
Last metadata expiration check: 0:00:03 ago on Sun Oct 26 11:23:27 2025.
Dependencies resolved.
=========================================================================================================================================================================================
 Package                                                  Architecture                          Version                                Repository                                   Size
=========================================================================================================================================================================================
Installing:
 mysql80-community-release                                noarch                                el9-3                                  @commandline                                 10 k

Transaction Summary
=========================================================================================================================================================================================
Install  1 Package

Total size: 10 k
Installed size: 7.8 k
Downloading Packages:
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                 1/1
  Installing       : mysql80-community-release-el9-3.noarch                                                                                                                          1/1
  Verifying        : mysql80-community-release-el9-3.noarch                                                                                                                          1/1

Installed:
  mysql80-community-release-el9-3.noarch

Complete!
Importing MySQL GPG keys...
Enabling mysql80-community repository...
Error: No matching repo to modify: mysql56-community, mysql57-community.
17 files removed
Amazon Linux 2023 repository                                                                                                                              66 MB/s |  47 MB     00:00
Amazon Linux 2023 Kernel Livepatch repository                                                                                                            235 kB/s |  26 kB     00:00
MySQL 8.0 Community Server                                                                                                                                44 MB/s | 2.9 MB     00:00
MySQL Connectors Community                                                                                                                               6.5 MB/s |  98 kB     00:00
MySQL Tools Community                                                                                                                                     45 MB/s | 1.3 MB     00:00
Metadata cache created.
Installing mysql-community-server (MySQL 8.0)...
Last metadata expiration check: 0:00:01 ago on Sun Oct 26 11:23:45 2025.
Dependencies resolved.
=========================================================================================================================================================================================
 Package                                                   Architecture                      Version                                  Repository                                    Size
=========================================================================================================================================================================================
Installing:
 mysql-community-server                                    x86_64                            8.0.44-1.el9                             mysql80-community                             50 M
Installing dependencies:
 mysql-community-client                                    x86_64                            8.0.44-1.el9                             mysql80-community                            3.3 M
 mysql-community-client-plugins                            x86_64                            8.0.44-1.el9                             mysql80-community                            1.4 M
 mysql-community-common                                    x86_64                            8.0.44-1.el9                             mysql80-community                            557 k
 mysql-community-icu-data-files                            x86_64                            8.0.44-1.el9                             mysql80-community                            2.3 M
 mysql-community-libs                                      x86_64                            8.0.44-1.el9                             mysql80-community                            1.5 M

Transaction Summary
=========================================================================================================================================================================================
Install  6 Packages

Total download size: 59 M
Installed size: 337 M
Downloading Packages:
(1/6): mysql-community-common-8.0.44-1.el9.x86_64.rpm                                                                                                     23 MB/s | 557 kB     00:00
(2/6): mysql-community-client-plugins-8.0.44-1.el9.x86_64.rpm                                                                                             37 MB/s | 1.4 MB     00:00
(3/6): mysql-community-icu-data-files-8.0.44-1.el9.x86_64.rpm                                                                                             60 MB/s | 2.3 MB     00:00
(4/6): mysql-community-libs-8.0.44-1.el9.x86_64.rpm                                                                                                       35 MB/s | 1.5 MB     00:00
(5/6): mysql-community-client-8.0.44-1.el9.x86_64.rpm                                                                                                     25 MB/s | 3.3 MB     00:00
(6/6): mysql-community-server-8.0.44-1.el9.x86_64.rpm                                                                                                     67 MB/s |  50 MB     00:00
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Total                                                                                                                                                     72 MB/s |  59 MB     00:00
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                 1/1
  Installing       : mysql-community-common-8.0.44-1.el9.x86_64                                                                                                                      1/6
  Installing       : mysql-community-client-plugins-8.0.44-1.el9.x86_64                                                                                                              2/6
  Installing       : mysql-community-libs-8.0.44-1.el9.x86_64                                                                                                                        3/6
  Running scriptlet: mysql-community-libs-8.0.44-1.el9.x86_64                                                                                                                        3/6
  Installing       : mysql-community-client-8.0.44-1.el9.x86_64                                                                                                                      4/6
  Installing       : mysql-community-icu-data-files-8.0.44-1.el9.x86_64                                                                                                              5/6
  Running scriptlet: mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      6/6
  Installing       : mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      6/6
  Running scriptlet: mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      6/6
  Verifying        : mysql-community-client-8.0.44-1.el9.x86_64                                                                                                                      1/6
  Verifying        : mysql-community-client-plugins-8.0.44-1.el9.x86_64                                                                                                              2/6
  Verifying        : mysql-community-common-8.0.44-1.el9.x86_64                                                                                                                      3/6
  Verifying        : mysql-community-icu-data-files-8.0.44-1.el9.x86_64                                                                                                              4/6
  Verifying        : mysql-community-libs-8.0.44-1.el9.x86_64                                                                                                                        5/6
  Verifying        : mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      6/6

Installed:
  mysql-community-client-8.0.44-1.el9.x86_64                      mysql-community-client-plugins-8.0.44-1.el9.x86_64              mysql-community-common-8.0.44-1.el9.x86_64
  mysql-community-icu-data-files-8.0.44-1.el9.x86_64              mysql-community-libs-8.0.44-1.el9.x86_64                        mysql-community-server-8.0.44-1.el9.x86_64

Complete!
Waiting for mysqld to become available...
mysqld is up (attempt 1).
Configuring MySQL root account and basic security...
Using temporary root password from /var/log/mysqld.log to set provided root password...
mysql: [Warning] Using a password on the command line interface can be insecure.
Creating database 'healthcare_db' and user 'healthuser' (host: yes)...
mysql: [Warning] Using a password on the command line interface can be insecure.
Enabling remote access (bind-address = 0.0.0.0)...
✅ MySQL 8 installation & initial configuration finished!
----------------------------------------
Root login : mysql -u root -p
Root Pass  : *****
DB Name    : healthcare_db
DB User    : healthuser@%
DB Pass    : *********
----------------------------------------
Remote access enabled. Ensure your EC2 Security Group allows TCP/3306 from trusted IPs only.
To test locally: mysql -u healthuser -pHealth@123 healthcare_db
To test remotely (replace <EC2-PUBLIC-IP>): mysql -h <EC2-PUBLIC-IP> -u healthuser -p******** healthcare_db
[ec2-user@ip-172-31-88-106 ~]$  mysql -h ********* -u healthuser -pHealth@123 healthcare_db
mysql: [Warning] Using a password on the command line interface can be insecure.
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 8
Server version: 8.0.44 MySQL Community Server - GPL

Copyright (c) 2000, 2025, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> exit
Bye
[ec2-user@ip-172-31-88-106 ~]$
