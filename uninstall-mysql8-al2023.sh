#!/usr/bin/env bash
# uninstall-mysql8-al2023.sh
# Cleanly uninstall MySQL 8 on Amazon Linux 2023.
# Usage:
#   sudo ./uninstall-mysql8-al2023.sh [--purge-data] [--remove-keys] [--yes]
#
# Options:
#   --purge-data     Remove /var/lib/mysql and /etc/my.cnf* after backing up (destructive)
#   --remove-keys    Remove imported MySQL GPG keys (attempts safe best-effort)
#   --yes            Skip confirmations (use with care)

set -euo pipefail

PURGE_DATA=0
REMOVE_KEYS=0
ASSUME_YES=0

for arg in "$@"; do
  case "${arg}" in
    --purge-data) PURGE_DATA=1 ;;
    --remove-keys) REMOVE_KEYS=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [--purge-data] [--remove-keys] [--yes]

--purge-data   : Remove MySQL data directory (/var/lib/mysql) and config (/etc/my.cnf*) AFTER backing up.
--remove-keys  : Attempt to remove imported MySQL GPG keys (best-effort).
--yes          : Skip interactive confirmation prompts.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}"
      exit 1
      ;;
  esac
done

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# Ensure running on Amazon Linux 2023
if [ -r /etc/os-release ]; then
  . /etc/os-release
  if ! echo "${ID:-}" | grep -qi '^amzn'; then
    echo "This script targets Amazon Linux (amzn). Detected ID='${ID:-}'. Aborting."
    exit 1
  fi
  if ! echo "${VERSION_ID:-}" | grep -q '^2023'; then
    echo "This script is intended for Amazon Linux 2023. Detected VERSION_ID='${VERSION_ID:-}'. Aborting."
    exit 1
  fi
else
  echo "/etc/os-release missing. Can't detect OS. Aborting."
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP="/root/mysql-backup-${TIMESTAMP}.tar.gz"
DATA_DIR="/var/lib/mysql"
CNF_FILES="/etc/my.cnf /etc/my.cnf.d /etc/my.cnf*"
REPO_PKG="mysql80-community-release"

echo "MySQL 8 uninstall helper for Amazon Linux 2023"
echo "Backup path will be: ${BACKUP}"
echo "Options: purge-data=${PURGE_DATA}, remove-keys=${REMOVE_KEYS}, assume-yes=${ASSUME_YES}"
echo

if [ "${ASSUME_YES}" -ne 1 ]; then
  read -r -p "Proceed with uninstall of MySQL packages? (y/N) " RESP
  if ! echo "${RESP}" | grep -iq '^y'; then
    echo "Aborted by user."
    exit 0
  fi
fi

# --- Step 1: stop & disable mysqld ---
echo "Stopping and disabling mysqld service..."
systemctl stop mysqld 2>/dev/null || true
systemctl disable mysqld 2>/dev/null || true

# --- Step 2: Back up data & config if present ---
echo "Creating backup of MySQL data and config (if present) -> ${BACKUP}"
TO_BACKUP=()
if [ -d "${DATA_DIR}" ]; then
  TO_BACKUP+=("${DATA_DIR}")
fi

# include /etc/my.cnf and related if they exist
for p in /etc/my.cnf /etc/my.cnf.d; do
  if [ -e "${p}" ]; then
    TO_BACKUP+=("${p}")
  fi
done

if [ ${#TO_BACKUP[@]} -gt 0 ]; then
  tar -czf "${BACKUP}" "${TO_BACKUP[@]}" || {
    echo "Backup failed. Continuing anyway but you may want to check ${BACKUP}."
  }
  echo "Backup completed: ${BACKUP}"
else
  echo "No MySQL data/config found to backup."
fi

# --- Step 3: remove MySQL packages ---
echo "Removing MySQL packages via dnf..."
# remove specific packages (best-effort); ignore failures
dnf -y remove mysql-community-server mysql-community-client mysql-community-libs mysql-community-common mysql-community-client-plugins mysql-community-icu-data-files || true

# Also try to remove any remaining mysql-community-* packages
PKGS=$(dnf list installed 2>/dev/null | awk '/mysql-community/ {print $1}' || true)
if [ -n "${PKGS}" ]; then
  echo "Removing remaining mysql-community packages: ${PKGS}"
  dnf -y remove ${PKGS} || true
fi

# Remove the MySQL repo package (that created repo files)
echo "Removing MySQL repo package (${REPO_PKG})..."
dnf -y remove "${REPO_PKG}" || rpm -e "${REPO_PKG}" 2>/dev/null || true

# Remove repo files just in case
rm -f /etc/yum.repos.d/mysql-community.repo /etc/yum.repos.d/mysql-community-source.repo || true

# --- Step 4: purge data/config optionally ---
if [ "${PURGE_DATA}" -eq 1 ]; then
  if [ "${ASSUME_YES}" -ne 1 ]; then
    read -r -p "Purge MySQL data (${DATA_DIR}) and configs (${CNF_FILES})? This is destructive. (y/N) " PURGE_CONF
    if ! echo "${PURGE_CONF}" | grep -iq '^y'; then
      echo "Skipping purge of data/config."
      PURGE_DATA=0
    fi
  fi

  if [ "${PURGE_DATA}" -eq 1 ]; then
    echo "Purging data and configs..."
    rm -rf "${DATA_DIR}" || true
    rm -rf /etc/my.cnf /etc/my.cnf.d /etc/my.cnf* || true
    echo "Data/config purge complete."
  fi
else
  echo "Data/config left in place. Remove with --purge-data if you want to delete them."
fi

# --- Step 5: remove mysql user & group if they exist (best-effort) ---
if getent passwd mysql >/dev/null 2>&1; then
  echo "Removing mysql system user and home (if any)..."
  userdel -r mysql 2>/dev/null || userdel mysql 2>/dev/null || true
fi
if getent group mysql >/dev/null 2>&1; then
  groupdel mysql 2>/dev/null || true
fi

# --- Step 6: remove imported GPG keys (optional) ---
if [ "${REMOVE_KEYS}" -eq 1 ]; then
  echo "Attempting to remove imported MySQL GPG keys (best-effort)."
  # list gpg-pubkey entries and attempt to find those which mention 'mysql' in their pkg info
  for key in $(rpm -qa 'gpg-pubkey*' 2>/dev/null || true); do
    # show info and search for mysql (not always present)
    if rpm -q --qf '%{NAME} %{SUMMARY}\n' "${key}" 2>/dev/null | grep -iq mysql; then
      echo "Removing RPM GPG key: ${key}"
      rpm -e "${key}" || true
    else
      # try a fingerprint match by fetching the key details and checking if it was imported from repo.mysql.com
      if rpm -qi "${key}" 2>/dev/null | grep -qi 'repo.mysql.com'; then
        echo "Removing RPM GPG key (repo.mysql.com): ${key}"
        rpm -e "${key}" || true
      fi
    fi
  done
  echo "GPG key removal attempted (verify with: rpm -qa | grep -i gpg-pubkey)."
else
  echo "Skipping removal of GPG keys. Use --remove-keys to attempt removal."
fi

# --- Step 7: cleanup package caches and orphan deps ---
echo "Cleaning package metadata and removing orphan dependencies..."
dnf -y autoremove || true
dnf -y clean all || true

# --- Step 8: final verification ---
echo
echo "Verification:"
if systemctl list-unit-files | grep -qi mysqld; then
  echo "  - mysqld systemd unit still present (may be residual)."
else
  echo "  - mysqld systemd unit not present."
fi

if command -v mysql >/dev/null 2>&1; then
  echo "  - mysql binary still in PATH: $(command -v mysql)"
else
  echo "  - mysql client binary removed."
fi

if [ -d "${DATA_DIR}" ]; then
  echo "  - Data dir still present: ${DATA_DIR}"
else
  echo "  - Data dir removed or not present."
fi

echo
echo "Uninstall process finished."
echo "Backup (if created): ${BACKUP}"
if [ "${PURGE_DATA}" -eq 0 ]; then
  echo "Data and config were left in place. Rerun with --purge-data to delete them."
fi
if [ "${REMOVE_KEYS}" -eq 0 ]; then
  echo "GPG keys not removed. Rerun with --remove-keys to attempt removal."
fi

exit 0
==========
logs:

[ec2-user@ip-172-31-88-106 ~]$ vi uninstall-mysql8-al2023.sh
[ec2-user@ip-172-31-88-106 ~]$ chmod +x uninstall-mysql8-al2023.sh
[ec2-user@ip-172-31-88-106 ~]$ sudo ./uninstall-mysql8-al2023.sh --purge-data --remove-keys --yes
MySQL 8 uninstall helper for Amazon Linux 2023
Backup path will be: /root/mysql-backup-20251026111847.tar.gz
Options: purge-data=1, remove-keys=1, assume-yes=1

Stopping and disabling mysqld service...
Creating backup of MySQL data and config (if present) -> /root/mysql-backup-20251026111847.tar.gz
tar: Removing leading `/' from member names
tar: Removing leading `/' from hard link targets
Backup completed: /root/mysql-backup-20251026111847.tar.gz
Removing MySQL packages via dnf...
Dependencies resolved.
=========================================================================================================================================================================================
 Package                                                   Architecture                      Version                                 Repository                                     Size
=========================================================================================================================================================================================
Removing:
 mysql-community-client                                    x86_64                            8.0.44-1.el9                            @mysql80-community                             71 M
 mysql-community-client-plugins                            x86_64                            8.0.44-1.el9                            @mysql80-community                            7.4 M
 mysql-community-common                                    x86_64                            8.0.44-1.el9                            @mysql80-community                             10 M
 mysql-community-icu-data-files                            x86_64                            8.0.44-1.el9                            @mysql80-community                            4.3 M
 mysql-community-libs                                      x86_64                            8.0.44-1.el9                            @mysql80-community                            7.3 M
 mysql-community-server                                    x86_64                            8.0.44-1.el9                            @mysql80-community                            237 M

Transaction Summary
=========================================================================================================================================================================================
Remove  6 Packages

Freed space: 337 M
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                 1/1
  Running scriptlet: mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      1/6
  Erasing          : mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      1/6
  Running scriptlet: mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      1/6
  Erasing          : mysql-community-icu-data-files-8.0.44-1.el9.x86_64                                                                                                              2/6
  Erasing          : mysql-community-client-8.0.44-1.el9.x86_64                                                                                                                      3/6
  Erasing          : mysql-community-libs-8.0.44-1.el9.x86_64                                                                                                                        4/6
  Running scriptlet: mysql-community-libs-8.0.44-1.el9.x86_64                                                                                                                        4/6
  Erasing          : mysql-community-common-8.0.44-1.el9.x86_64                                                                                                                      5/6
  Erasing          : mysql-community-client-plugins-8.0.44-1.el9.x86_64                                                                                                              6/6
  Running scriptlet: mysql-community-client-plugins-8.0.44-1.el9.x86_64                                                                                                              6/6
  Verifying        : mysql-community-client-8.0.44-1.el9.x86_64                                                                                                                      1/6
  Verifying        : mysql-community-client-plugins-8.0.44-1.el9.x86_64                                                                                                              2/6
  Verifying        : mysql-community-common-8.0.44-1.el9.x86_64                                                                                                                      3/6
  Verifying        : mysql-community-icu-data-files-8.0.44-1.el9.x86_64                                                                                                              4/6
  Verifying        : mysql-community-libs-8.0.44-1.el9.x86_64                                                                                                                        5/6
  Verifying        : mysql-community-server-8.0.44-1.el9.x86_64                                                                                                                      6/6

Removed:
  mysql-community-client-8.0.44-1.el9.x86_64                      mysql-community-client-plugins-8.0.44-1.el9.x86_64              mysql-community-common-8.0.44-1.el9.x86_64
  mysql-community-icu-data-files-8.0.44-1.el9.x86_64              mysql-community-libs-8.0.44-1.el9.x86_64                        mysql-community-server-8.0.44-1.el9.x86_64

Complete!
Removing MySQL repo package (mysql80-community-release)...
Dependencies resolved.
=========================================================================================================================================================================================
 Package                                                  Architecture                          Version                               Repository                                    Size
=========================================================================================================================================================================================
Removing:
 mysql80-community-release                                noarch                                el9-3                                 @@commandline                                7.8 k

Transaction Summary
=========================================================================================================================================================================================
Remove  1 Package

Freed space: 7.8 k
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                 1/1
  Erasing          : mysql80-community-release-el9-3.noarch                                                                                                                          1/1
  Verifying        : mysql80-community-release-el9-3.noarch                                                                                                                          1/1

Removed:
  mysql80-community-release-el9-3.noarch

Complete!
Purging data and configs...
Data/config purge complete.
Removing mysql system user and home (if any)...
Attempting to remove imported MySQL GPG keys (best-effort).
Removing RPM GPG key: gpg-pubkey-3a79bd29-61b8bab7
Removing RPM GPG key: gpg-pubkey-a8d3785c-6536acda
Removing RPM GPG key: gpg-pubkey-5072e1f5-5c4058fb
GPG key removal attempted (verify with: rpm -qa | grep -i gpg-pubkey).
Cleaning package metadata and removing orphan dependencies...
Last metadata expiration check: 0:10:57 ago on Sun Oct 26 11:07:53 2025.
Dependencies resolved.
Nothing to do.
Complete!
32 files removed

Verification:
  - mysqld systemd unit not present.
  - mysql client binary removed.
  - Data dir removed or not present.

Uninstall process finished.
Backup (if created): /root/mysql-backup-20251026111847.tar.gz
[ec2-user@ip-172-31-88-106 ~]$
