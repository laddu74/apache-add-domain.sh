#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

domain_name="$1"

# Check if domain name argument is provided
if [ -z "$domain_name" ]; then
    echo "Usage: sudo $0 <domain_name>"
    exit 1
fi

# Load environment variables from .env file if it exists
script_dir="$(dirname "$(realpath "$0")")"
ENV_FILE="${script_dir}/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
    echo "Loaded MySQL credentials from .env"
else
    echo "WARNING: .env file not found. Falling back to passwordless sudo."
fi

# Set default MySQL root user and pass if not provided in .env
MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-"root"}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-""}

# Construct MySQL command prefix
if [ "${USE_MYSQL_AUTH,,}" = "true" ]; then
    if [ -n "$MYSQL_ROOT_PASS" ]; then
        MYSQL_CMD="mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASS"
    else
        MYSQL_CMD="mysql -u$MYSQL_ROOT_USER"
    fi
else
    MYSQL_CMD="sudo mysql"
fi

# Generate username from domain name (alphanumeric, max 16 chars for legacy DB compatibility)
username=$(echo "${domain_name}" | sed 's/[^a-zA-Z0-9]//g' | cut -c 1-16)

# Database credentials
db_name="${username}_db"
db_user="${username}_usr"

echo "=========================================="
echo " Starting Password Rotation for ${domain_name}"
echo "=========================================="

rotation_happened=false
new_sys_pass=""
new_db_pass=""

echo "1. Rotating System User Password for: ${username}"
if id "$username" &>/dev/null; then
    new_sys_pass=$(openssl rand -base64 16)
    echo "${username}:${new_sys_pass}" | sudo chpasswd
    echo "System password updated successfully."
    rotation_happened=true
else
    echo "WARNING: User $username does not exist. Skipping."
fi

echo ""
echo "2. Rotating Database User Password for: ${db_user}"
if command -v mysql &> /dev/null; then
    # Check if user exists
    user_exists=$($MYSQL_CMD -se "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '${db_user}');" 2>/dev/null)
    
    if [ "$user_exists" = "1" ]; then
        new_db_pass=$(openssl rand -base64 16)
        $MYSQL_CMD -e "ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${new_db_pass}';"
        $MYSQL_CMD -e "FLUSH PRIVILEGES;"
        echo "Database password updated successfully."
        rotation_happened=true
    else
        echo "WARNING: Database user ${db_user} does not exist. Skipping."
    fi
else
    echo "WARNING: MySQL/MariaDB not found. Skipping database password rotation."
fi

echo ""
echo "=========================================="
if [ "$rotation_happened" = true ]; then
    echo " ROTATION COMPLETE "
    echo "=========================================="
    echo "Domain:        ${domain_name}"
    [ -n "$new_sys_pass" ] && echo "System User:   ${username}"
    [ -n "$new_sys_pass" ] && echo "System Pass:   ${new_sys_pass}"
    echo ""
    if [ -n "$new_db_pass" ]; then
        echo "Database Info (Save this!):"
        echo "DB Name:       ${db_name}"
        echo "DB User:       ${db_user}"
        echo "DB Password:   ${new_db_pass}"
    fi
    echo "=========================================="

    # Log credentials to the secure file
    log_file="/var/log/apache_${domain_name}_setup.log"
    if [ -f "$log_file" ]; then
        cat <<EOF | sudo tee -a "$log_file" > /dev/null
==========================================
Rotation Date: $(date)
System Pass:   ${new_sys_pass:-"N/A (Not Rotated)"}
DB Password:   ${new_db_pass:-"N/A (Not Rotated)"}
==========================================
EOF
        echo "New credentials have been securely logged to: $log_file"
    else
        echo "INFO: Original setup log not found at $log_file."
    fi
else
    echo " NO ROTATION PERFORMED"
    echo "=========================================="
fi
