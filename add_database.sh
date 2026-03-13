#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Check if arguments are provided
if [ $# -ne 2 ]; then
    echo "Usage: sudo $0 system_username database_suffix"
    echo "Example: sudo $0 myuser blog (creates myuser_blog_db)"
    exit 1
fi

# Assign arguments
username=$1
db_suffix=$2

# Load environment variables from .env file if it exists
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
    echo "Loaded configuration from .env"
else
    echo "WARNING: .env file not found. Falling back to defaults."
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

# Database details
db_name="${username}_${db_suffix}_db"
db_user="${username}_usr"

# Function to send setup details via SendGrid
send_setup_email() {
    if [ "${ENABLE_SENDGRID,,}" != "true" ]; then
        echo "INFO: SendGrid integration disabled. Skipping email notification."
        return
    fi

    if [ -z "$SENDGRID_API_KEY" ] || [ -z "$ADMIN_EMAIL" ] || [ -z "$SENDER_EMAIL" ]; then
        echo "WARNING: SendGrid credentials missing. Skipping email notification."
        return
    fi

    echo "=========================================="
    echo " Sending Database Details via Email"
    echo "=========================================="
    
    # Prepare JSON payload
    email_json=$(cat <<EOF
{
  "personalizations": [{
    "to": [{"email": "$ADMIN_EMAIL"}]
  }],
  "from": {"email": "$SENDER_EMAIL", "name": "Database Setup"},
  "subject": "New Database Added: $db_name",
  "content": [{
    "type": "text/plain",
    "value": "New Database Details:\n\nSystem User: $username\nDatabase Name: $db_name\nDatabase User: $db_user\n\nNote: Use existing credentials for $db_user."
  }]
}
EOF
)

    curl --request POST \
      --url https://api.sendgrid.com/v3/mail/send \
      --header "Authorization: Bearer $SENDGRID_API_KEY" \
      --header 'Content-Type: application/json' \
      --data "$email_json" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "Email sent successfully to $ADMIN_EMAIL"
    else
        echo "ERROR: Failed to send email."
    fi
}

echo "=========================================="
echo "1. Validating System User: ${username}"
echo "=========================================="
if ! id "$username" &>/dev/null; then
    echo "ERROR: System user $username does not exist. Please create the user/domain first."
    exit 1
fi

echo "=========================================="
echo "2. Configuring Database: ${db_name}"
echo "=========================================="
if command -v mysql &> /dev/null; then
    # Check if database user exists
    user_exists=$($MYSQL_CMD -N -s -e "SELECT COUNT(*) FROM mysql.user WHERE user = '$db_user';")
    
    if [ "$user_exists" -eq 0 ]; then
        echo "ERROR: Database user $db_user does not exist. Please run add_domain.sh first."
        exit 1
    fi

    # Create Database and Grant Privileges
    $MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    $MYSQL_CMD -e "FLUSH PRIVILEGES;"
    echo "Database created and privileges granted to ${db_user}."
else
    echo "ERROR: MySQL/MariaDB not found. Cannot proceed."
    exit 1
fi

echo ""
echo "=========================================="
echo " DATABASE ADDED SUCCESSFULLY"
echo "=========================================="
echo "System User:   ${username}"
echo "Database Name: ${db_name}"
echo "Database User: ${db_user}"
echo "=========================================="

# Log to centralized audit log
audit_log="/var/log/apache_setup_audit.log"
if [ ! -f "$audit_log" ]; then
    sudo touch "$audit_log"
    sudo chmod 644 "$audit_log"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DB_ADDED: User=$username, DB=$db_name" | sudo tee -a "$audit_log" > /dev/null

# Send email notification
send_setup_email
