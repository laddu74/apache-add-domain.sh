#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Default values
site_type="php"
domain_name=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --type=*) site_type="${1#*=}"; shift ;;
        -t|--type) site_type="$2"; shift 2 ;;
        *) domain_name="$1"; shift ;;
    esac
done

# Check if domain name argument is provided
if [ -z "$domain_name" ]; then
    echo "Usage: sudo $0 <domain_name> [--type=php|perl|python|ror]"
    exit 1
fi

# Load environment variables from .env file if it exists
ENV_FILE="$(dirname "$0")/.env"
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
# Function to check required Apache modules
check_required_modules() {
    local modules=()
    case ${site_type,,} in
        perl) modules=("cgid" "rewrite" "headers") ;;
        python) modules=("wsgi" "rewrite" "headers") ;;
        ror) modules=("passenger" "rewrite" "headers") ;;
        php|*) modules=("rewrite" "headers") ;;
    esac

    local missing_modules=()
    for mod in "${modules[@]}"; do
        if ! apache2ctl -M 2>/dev/null | grep -q "${mod}_module"; then
            # Check if it's available to enable
            if [ -f "/etc/apache2/mods-available/${mod}.load" ]; then
                echo "Enabling required module: ${mod}"
                sudo a2enmod "$mod" > /dev/null 2>&1
            else
                missing_modules+=("$mod")
            fi
        fi
    done

    if [ ${#missing_modules[@]} -ne 0 ]; then
        echo "=========================================="
        echo " ERROR: Missing Required Apache Modules"
        echo "=========================================="
        echo "The following modules are NOT installed on your system:"
        for mod in "${missing_modules[@]}"; do
            echo " - $mod"
        done
        echo ""
        echo "Please install them using: sudo apt update && sudo apt install <module-package>"
        echo "For example:"
        echo " - WSGI (Python): libapache2-mod-wsgi-py3"
        echo " - Passenger (RoR): libapache2-mod-passenger"
        echo " - Perl: libapache2-mod-perl2 (or just use cgid which is usually built-in)"
        echo "=========================================="
        exit 1
    fi
}

# Run module check
check_required_modules

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
    echo " Sending Setup Details via Email"
    echo "=========================================="
    
    # Prepare JSON payload
    email_json=$(cat <<EOF
{
  "personalizations": [{
    "to": [{"email": "$ADMIN_EMAIL"}]
  }],
  "from": {"email": "$SENDER_EMAIL", "name": "Server Setup"},
  "subject": "New Domain Setup: $domain_name",
  "content": [{
    "type": "text/plain",
    "value": "Domain Setup Details:\n\nDomain: $domain_name\nSystem User: $username\nSystem Pass: $sys_pass\nDocument Root: $domain_directory\n\nDatabase Info:\nDB Name: $db_name\nDB User: $db_user\nDB Password: $db_pass"
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

# Generate username from domain name (alphanumeric, max 16 chars for legacy DB compatibility)
username=$(echo "${domain_name}" | sed 's/[^a-zA-Z0-9]//g' | cut -c 1-16)
sys_pass=$(openssl rand -base64 16)

# Database credentials
db_name="${username}_db"
db_user="${username}_usr"
db_pass=$(openssl rand -base64 16)

# Directories
user_home="/home/${username}"
domain_directory="${user_home}/public_html"
apache_conf_dir="/etc/apache2/sites-available/"
apache_conf="${apache_conf_dir}${domain_name}.conf"

echo "Site Type: ${site_type^^}"

echo "=========================================="
echo "1. Creating System User: ${username}"
echo "=========================================="
if id "$username" &>/dev/null; then
    echo "User $username already exists."
else
    # Create user with a generated password
    sudo useradd -m -d "${user_home}" -s /bin/bash "$username"
    echo "${username}:${sys_pass}" | sudo chpasswd
    echo "User ${username} created successfully with a secure password."
fi

# Create document root
sudo mkdir -p "${domain_directory}"

# Secure permissions
# Set owner to new user, group to www-data (Apache)
sudo chown -R ${username}:www-data "${user_home}"
# 750: User can read/write/execute, www-data can read/execute, others have no access
sudo chmod 750 "${user_home}"
sudo chmod 750 "${domain_directory}"
echo "Permissions secured for ${domain_directory}"

echo "=========================================="
echo "2. Configuring Database: ${db_name}"
echo "=========================================="
if command -v mysql &> /dev/null; then
    $MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;"
    $MYSQL_CMD -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    $MYSQL_CMD -e "FLUSH PRIVILEGES;"
    echo "Database and user created successfully."
else
    echo "WARNING: MySQL/MariaDB not found. Skipping database setup."
fi

echo "=========================================="
echo "3. Configuring Apache VirtualHost"
echo "=========================================="

# Remove existing Apache virtual host configuration file if it exists
if [ -f "$apache_conf" ]; then
    sudo rm "$apache_conf"
    echo "Existing configuration file ${domain_name}.conf removed."
fi

# Create Apache virtual host configuration file
case ${site_type,,} in
    perl)
        VHOST_CONFIG=$(cat <<EOF
<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    DocumentRoot ${domain_directory}

    <Directory ${domain_directory}>
        Options +ExecCGI -Indexes +FollowSymLinks
        AddHandler cgi-script .cgi .pl
        AllowOverride All
        Require all granted
    </Directory>

    # ScriptAlias for CGI
    ScriptAlias /cgi-bin/ "${domain_directory}/cgi-bin/"

    <Directory "${domain_directory}/cgi-bin">
        AllowOverride None
        Options +ExecCGI
        Require all granted
    </Directory>

    <DirectoryMatch "/\.(?!well-known)">
        Require all denied
    </DirectoryMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${domain_name}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain_name}_access.log combined
</VirtualHost>
EOF
)
        ;;
    python)
        VHOST_CONFIG=$(cat <<EOF
<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    DocumentRoot ${domain_directory}

    # WSGI Configuration
    WSGIDaemonProcess ${username} user=${username} group=www-data threads=5
    WSGIProcessGroup ${username}
    WSGIScriptAlias / ${domain_directory}/adapter.wsgi

    <Directory ${domain_directory}>
        WSGIProcessGroup ${username}
        WSGIApplicationGroup %{GLOBAL}
        Require all granted
    </Directory>

    <DirectoryMatch "/\.(?!well-known)">
        Require all denied
    </DirectoryMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${domain_name}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain_name}_access.log combined
</VirtualHost>
EOF
)
        ;;
    ror)
        VHOST_CONFIG=$(cat <<EOF
<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    DocumentRoot ${domain_directory}/public

    # Passenger Configuration
    PassengerEnabled on
    PassengerAppType rack
    PassengerAppRoot ${domain_directory}

    <Directory ${domain_directory}/public>
        AllowOverride all
        Options -MultiViews
        Require all granted
    </Directory>

    <DirectoryMatch "/\.(?!well-known)">
        Require all denied
    </DirectoryMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${domain_name}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain_name}_access.log combined
</VirtualHost>
EOF
)
        ;;
    php|*)
        VHOST_CONFIG=$(cat <<EOF
<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    DocumentRoot ${domain_directory}

    <Directory ${domain_directory}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <DirectoryMatch "/\.(?!well-known)">
        Require all denied
    </DirectoryMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${domain_name}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain_name}_access.log combined
</VirtualHost>
EOF
)
        ;;
esac

echo "$VHOST_CONFIG" | sudo tee "$apache_conf" > /dev/null

echo "VirtualHost configuration created."

echo "=========================================="
echo "4. Enabling Site and Applying Changes"
echo "=========================================="
# Modules are now handled by check_required_modules

# Enable the site
sudo a2ensite ${domain_name} > /dev/null 2>&1

# Test Apache configuration
if sudo apache2ctl configtest > /dev/null 2>&1; then
    # Reload Apache to apply changes
    sudo systemctl reload apache2
    echo "Apache restarted successfully."
else
    echo "ERROR: Apache configuration test failed. Please test manually: sudo apache2ctl configtest"
fi

echo ""
echo "=========================================="
echo " SETUP COMPLETE"
echo "=========================================="
echo "Domain:        ${domain_name}"
echo "Site Type:     ${site_type^^}"
echo "System User:   ${username}"
echo "System Pass:   ${sys_pass}"
echo "Document Root: ${domain_directory}"
echo ""
echo "Database Info (Save this!):"
echo "DB Name:       ${db_name}"
echo "DB User:       ${db_user}"
echo "DB Password:   ${db_pass}"
echo "=========================================="

# Log credentials to a secure file
log_file="/var/log/apache_${domain_name}_setup.log"
sudo touch "$log_file"
sudo chmod 600 "$log_file" # Ensure only root can read it
cat <<EOF | sudo tee -a "$log_file" > /dev/null
==========================================
Date:          $(date)
Domain:        ${domain_name}
System User:   ${username}
System Pass:   ${sys_pass}
Document Root: ${domain_directory}
DB Name:       ${db_name}
DB User:       ${db_user}
DB Password:   ${db_pass}
==========================================
EOF

echo "These details have been securely logged to: $log_file"

# Append to centralized audit log
audit_log="/var/log/apache_setup_audit.log"
# Ensure the log file exists and has correct permissions
if [ ! -f "$audit_log" ]; then
    sudo touch "$audit_log"
    sudo chmod 644 "$audit_log"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATED: Domain=$domain_name, Type=$site_type, User=$username, DocRoot=$domain_directory" | sudo tee -a "$audit_log" > /dev/null

# Send email notification
send_setup_email
