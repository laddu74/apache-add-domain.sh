#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Check if domain name argument is provided
if [ $# -ne 1 ]; then
    echo "Usage: sudo $0 domain_name"
    exit 1
fi

# Assign domain name argument
domain_name=$1

# Load environment variables from .env file if it exists
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
    echo "Loaded MySQL credentials from .env"
fi

# Set default MySQL root user and pass if not provided in .env
MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-"root"}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-""}

# Construct MySQL command prefix
if [ -n "$MYSQL_ROOT_PASS" ]; then
    MYSQL_CMD="mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASS"
else
    MYSQL_CMD="sudo mysql"
fi

# Log file path
log_file="/var/log/apache_${domain_name}_setup.log"

# Reconstruct username from setup log, fallback to domain name formula
username=""
if [ -f "$log_file" ]; then
    username=$(grep "System User:" "$log_file" | awk '{print $NF}')
fi

if [ -z "$username" ]; then
    username=$(echo "${domain_name}" | sed 's/[^a-zA-Z0-9]//g' | cut -c 1-16)
fi

# Database credentials
db_name="${username}_db"
db_user="${username}_usr"

# Directories and files
user_home="/home/${username}"
apache_conf_dir="/etc/apache2/sites-available/"
apache_conf="${apache_conf_dir}${domain_name}.conf"

echo "=========================================="
echo "           DELETING DOMAIN: ${domain_name} "
echo "=========================================="
echo "Please select a deletion mode:"
echo "1) Full Purge (Removes Apache VirtualHost, drops MySQL database/user, and deletes system user & home folder including all website files)"
echo "2) Deactivate Only (Removes Apache VirtualHost and config, but PRESERVES database and all files under /home/${username})"
echo "3) Cancel"
read -p "Select option (1-3): " delete_mode
echo

case "$delete_mode" in
    1)
        echo "WARNING: You selected Full Purge. This will permanently destroy all files, directories, and databases for ${domain_name}!"
        read -p "Are you absolutely sure you want to proceed? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Operation aborted."
            exit 1
        fi
        mode="full"
        ;;
    2)
        echo "Deactivate Only mode selected. Code files and databases will be preserved."
        mode="deactivate"
        ;;
    *)
        echo "Operation aborted."
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "1. Disabling VirtualHost and Removing Config"
echo "=========================================="
if [ -f "$apache_conf" ]; then
    sudo a2dissite "${domain_name}" > /dev/null 2>&1
    sudo rm "$apache_conf"
    sudo systemctl reload apache2
    echo "VirtualHost ${domain_name} disabled and configuration removed."
else
    echo "VirtualHost configuration not found. Skipping."
fi

echo "=========================================="
echo "2. Deleting/Preserving Database and DB User"
echo "=========================================="
if [ "$mode" = "full" ]; then
    if command -v mysql &> /dev/null; then
        $MYSQL_CMD -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
        $MYSQL_CMD -e "DROP USER IF EXISTS '${db_user}'@'localhost';"
        $MYSQL_CMD -e "FLUSH PRIVILEGES;"
        echo "Database '${db_name}' and user '${db_user}' have been dropped."
    else
        echo "WARNING: MySQL/MariaDB not found. Skipping database removal."
    fi
else
    echo "Database '${db_name}' and user '${db_user}' have been PRESERVED."
fi

echo "=========================================="
echo "3. Removing/Preserving System User & Home Directory"
echo "=========================================="
if [ "$mode" = "full" ]; then
    if id "$username" &>/dev/null; then
        # Kill any processes running as the user before deleting
        sudo pkill -u "$username"
        # Remove user and home directory (-r flag)
        sudo userdel -r "$username" 2>/dev/null
        echo "System user '${username}' and their home directory have been deleted."
    else
        echo "System user '${username}' not found. Skipping."
    fi
else
    echo "System user '${username}' and their home directory /home/${username} have been PRESERVED."
fi

echo "=========================================="
echo "4. Removing/Preserving Setup Log File"
echo "=========================================="
if [ "$mode" = "full" ]; then
    if [ -f "$log_file" ]; then
        sudo rm "$log_file"
        echo "Setup log file '${log_file}' removed."
    else
        echo "Log file not found. Skipping."
    fi
else
    echo "Setup log file '${log_file}' has been PRESERVED."
fi

echo ""
echo "=========================================="
echo " DOMAIN DELETION COMPLETE"
echo "=========================================="
