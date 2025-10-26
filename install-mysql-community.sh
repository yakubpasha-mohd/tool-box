install-mysql-community.sh
#!/usr/bin/env bash
# install-mysql-community.sh
# For EC2 RHEL9 — MySQL 8 installation with DB/user arguments
# Usage:
#   sudo ./install-mysql-community.sh <DB_NAME> <DB_USER> <DB_PASSWORD> [ROOT_PASSWORD] [ALLOW_REMOTE]
#
# Example:
#   sudo ./install-mysql-community.sh appdb appuser App@123 Root@123 yes

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

MYSQL_REPO_RPM_URL="https://dev.mysql.com/get/mysql80-community-release-el9-3.noarch.rpm"

echo "=============================="
echo "MySQL Installation Parameters:"
echo " DB Name      : ${DB_NAME}"
echo " DB User      : ${DB_USER}"
echo " DB Password  : ${DB_PASS}"
echo " Root Password: ${ROOT_PASSWORD}"
echo " Allow Remote : ${ALLOW_REMOTE}"
echo "=============================="

# === STEP 1: Update System ===
dnf -y update

# === STEP 2: Install MySQL Yum Repo ===
if ! dnf -y install "${MYSQL_REPO_RPM_URL}"; then
  echo "Failed to install MySQL repo. Visit https://dev.mysql.com/downloads/repo/yum/ for latest EL9 repo."
  exit 1
fi

# === STEP 3: Install MySQL Server ===
dnf -y module reset mysql || true
dnf -y install mysql-community-server

# === STEP 4: Start and Enable Service ===
systemctl enable --now mysqld
sleep 3

# === STEP 5: Secure Installation ===
echo "Configuring MySQL root and security..."
sudo mysql --connect-expired-password <<SQL || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP USER IF EXISTS 'root'@'%';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

# === STEP 6: Create Application DB and User ===
echo "Creating database '${DB_NAME}' and user '${DB_USER}'..."
sudo mysql -u root -p"${ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# === STEP 7: Allow Remote Access (if enabled) ===
MY_CNF="/etc/my.cnf"
if [[ "${ALLOW_REMOTE}" =~ ^(yes|true|1)$ ]]; then
  echo "Enabling remote connections..."
  if grep -q "bind-address" ${MY_CNF}; then
    sed -i "s/^bind-address.*/bind-address = ${BIND_ADDRESS}/" ${MY_CNF}
  else
    sed -i "/^\[mysqld\]/a bind-address = ${BIND_ADDRESS}" ${MY_CNF}
  fi
fi

# === STEP 8: Restart MySQL ===
systemctl restart mysqld

# === STEP 9: Firewall (firewalld) ===
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=3306/tcp || true
  firewall-cmd --reload || true
fi

# === STEP 10: Completion Message ===
echo "✅ MySQL installation and setup complete!"
echo "----------------------------------------"
echo "Root login : mysql -u root -p"
echo "Root Pass  : ${ROOT_PASSWORD}"
echo "DB Name    : ${DB_NAME}"
echo "DB User    : ${DB_USER}"
echo "DB Pass    : ${DB_PASS}"
echo "----------------------------------------"
echo "If remote access was enabled, ensure your EC2 Security Group allows TCP/3306."
echo "To test connection:"
echo "  mysql -h <EC2-Public-IP> -u ${DB_USER} -p${DB_PASS} ${DB_NAME}"

✅ Example Run
chmod +x install-mysql-community.sh
sudo ./install-mysql-community.sh healthcare_db healthuser Health@123 Root@123 yes


It will:

Install MySQL Community 8

Set root password: Root@123

Create database: healthcare_db

Create user: healthuser

Grant privileges

Open port 3306 (firewalld)

Bind to 0.0.0.0 (allow remote)

Start MySQL and enable on boot

✅ Verify Installation
sudo systemctl status mysqld
sudo mysql -u root -p
SHOW DATABASES;


Remote connection test (if allowed):

mysql -h <EC2-Public-IP> -u healthuser -p healthcare_db
