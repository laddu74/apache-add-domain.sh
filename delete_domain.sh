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

# Reconstruct username from domain name
username=$(echo "${domain_name}" | sed 's/[^a-zA-Z0-9]//g' | cut -c 1-16)

# Database credentials
db_name="${username}_db"
db_user="${username}_usr"

# Directories and files
user_home="/home/${username}"
apache_conf_dir="/etc/apache2/sites-available/"
apache_conf="${apache_conf_dir}${domain_name}.conf"
log_file="/var/log/apache_${domain_name}_setup.log"

echo "=========================================="
echo "           DELETING DOMAIN: ${domain_name} "
echo "=========================================="
echo "WARNING: This will permanently EXTERMINATE:"
echo "- Apache Configuration (${domain_name}.conf)"
echo "- System User and Home Directory (/home/${username})"
echo "- Database (${db_name}) and User (${db_user})"
echo "- Credential Log File (${log_file})"
echo ""
read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation aborted."
    exit 1
fi

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
echo "2. Deleting Database and DB User"
echo "=========================================="
if command -v mysql &> /dev/null; then
    $MYSQL_CMD -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
    $MYSQL_CMD -e "DROP USER IF EXISTS '${db_user}'@'localhost';"
    $MYSQL_CMD -e "FLUSH PRIVILEGES;"
    echo "Database '${db_name}' and user '${db_user}' have been dropped."
else
    echo "WARNING: MySQL/MariaDB not found. Skipping database removal."
fi

echo "=========================================="
echo "3. Removing System User and Home Directory"
echo "=========================================="
if id "$username" &>/dev/null; then
    # Kill any processes running as the user before deleting
    sudo pkill -u "$username"
    
    # Remove user and home directory (-r flag)
    sudo userdel -r "$username" 2>/dev/null
    echo "System user '${username}' and their home directory have been deleted."
else
    echo "System user '${username}' not found. Skipping."
fi

echo "=========================================="
echo "4. Removing Setup Log File"
echo "=========================================="
if [ -f "$log_file" ]; then
    sudo rm "$log_file"
    echo "Setup log file '${log_file}' removed."
else
    echo "Log file not found. Skipping."
fi

echo ""
echo "=========================================="
echo " DOMAIN DELETION COMPLETE"
echo "=========================================="
