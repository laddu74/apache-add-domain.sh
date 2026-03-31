#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Default values
site_type="php"
domain_name=""
docker_port="8080" # Default port if not specified
git_url=""
git_branch="main"
git_secret=$(openssl rand -hex 16)
php_version="" # Default to empty, will prompt or use default later

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --type=*) site_type="${1#*=}"; shift ;;
        -t|--type) site_type="$2"; shift 2 ;;
        --port=*) docker_port="${1#*=}"; shift ;;
        -p|--port) docker_port="$2"; shift 2 ;;
        --git-url=*) git_url="${1#*=}"; shift ;;
        --git-branch=*) git_branch="${1#*=}"; shift ;;
        --git-secret=*) git_secret="${1#*=}"; shift ;;
        --php=*) php_version="${1#*=}"; shift ;;
        *) domain_name="$1"; shift ;;
    esac
done

# Check if domain name argument is provided
if [ -z "$domain_name" ]; then
    echo "Usage: sudo $0 <domain_name> [--type=php|wordpress|perl|python|ror|docker] [--port=8080] [--php=8.2]"
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
        docker) modules=("proxy" "proxy_http" "rewrite" "headers") ;;
        wordpress) modules=("rewrite" "headers" "security2" "proxy_fcgi" "setenvif") ;;
        php|*) modules=("rewrite" "headers" "proxy_fcgi" "setenvif") ;;
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
        echo " - Docker (Proxy): Usually pre-installed, just needs a2enmod proxy proxy_http"
        echo "=========================================="
        exit 1
    fi
}

# Run module check
check_required_modules

# Function to check runtime tools and scaffold the environment for the site type
# (called AFTER user + directory creation so chown/mkdir works correctly)
setup_runtime_environment() {
    echo "=========================================="
    echo "  Runtime Environment Setup (${site_type^^})"
    echo "=========================================="

    case ${site_type,,} in
        perl)
            # Check Perl interpreter
            if ! command -v perl &> /dev/null; then
                echo "WARNING: Perl is not installed."
                echo "  Install with: sudo apt install perl"
            else
                PERL_VER=$(perl -e 'print $^V')
                echo "OK Perl found: ${PERL_VER}"
            fi

            # Create cgi-bin directory with +x permissions for CGI execution
            sudo mkdir -p "${domain_directory}/cgi-bin"
            sudo chown ${username}:www-data "${domain_directory}/cgi-bin"
            sudo chmod 755 "${domain_directory}/cgi-bin"
            echo "OK cgi-bin/ created at ${domain_directory}/cgi-bin"

            # Create a sample hello.pl CGI script
            if [ ! -f "${domain_directory}/cgi-bin/hello.pl" ]; then
                cat > /tmp/_hello_pl.$$ <<'ENDSCRIPT'
#!/usr/bin/perl
use strict;
use warnings;
print "Content-type: text/html\n\n";
print "<html><body><h1>Hello from Perl CGI!</h1></body></html>\n";
ENDSCRIPT
                sudo mv /tmp/_hello_pl.$$ "${domain_directory}/cgi-bin/hello.pl"
                sudo chmod 755 "${domain_directory}/cgi-bin/hello.pl"
                sudo chown ${username}:www-data "${domain_directory}/cgi-bin/hello.pl"
                echo "OK Sample CGI script: cgi-bin/hello.pl"
            fi
            ;;

        python)
            # Check Python 3 interpreter
            if ! command -v python3 &> /dev/null; then
                echo "WARNING: Python 3 is not installed."
                echo "  Install with: sudo apt install python3 python3-pip python3-venv"
            else
                PYTHON_VER=$(python3 --version)
                echo "OK ${PYTHON_VER} found"
            fi

            # Check pip3
            if ! command -v pip3 &> /dev/null; then
                echo "WARNING: pip3 is not installed."
                echo "  Install with: sudo apt install python3-pip"
            else
                echo "OK pip3 found"
            fi

            # Create a Python virtualenv for the site
            if command -v python3 &> /dev/null; then
                if [ ! -d "${domain_directory}/venv" ]; then
                    sudo -u "${username}" python3 -m venv "${domain_directory}/venv"
                    echo "OK virtualenv created at ${domain_directory}/venv"
                fi
            fi

            # Create a starter adapter.wsgi (VirtualHost points to this file)
            if [ ! -f "${domain_directory}/adapter.wsgi" ]; then
                cat > /tmp/_adapter_wsgi.$$ <<ENDSCRIPT
import sys
import os

# Add the application directory to sys.path
sys.path.insert(0, '${domain_directory}')

# Activate virtual environment if present
activate_this = os.path.join('${domain_directory}', 'venv', 'bin', 'activate_this.py')
if os.path.exists(activate_this):
    exec(open(activate_this).read(), dict(__file__=activate_this))

def application(environ, start_response):
    status = '200 OK'
    output = b'<html><body><h1>Hello from Python WSGI!</h1></body></html>'
    response_headers = [('Content-type', 'text/html'), ('Content-Length', str(len(output)))]
    start_response(status, response_headers)
    return [output]
ENDSCRIPT
                sudo mv /tmp/_adapter_wsgi.$$ "${domain_directory}/adapter.wsgi"
                sudo chown ${username}:www-data "${domain_directory}/adapter.wsgi"
                sudo chmod 644 "${domain_directory}/adapter.wsgi"
                echo "OK Starter adapter.wsgi created"
            fi
            ;;

        ror)
            # Check Ruby
            if ! command -v ruby &> /dev/null; then
                echo "WARNING: Ruby is not installed."
                echo "  Install with: sudo apt install ruby ruby-dev"
            else
                RUBY_VER=$(ruby --version)
                echo "OK ${RUBY_VER} found"
            fi

            # Check Bundler
            if ! command -v bundle &> /dev/null; then
                echo "WARNING: Bundler gem is not installed."
                echo "  Install with: sudo gem install bundler"
            else
                echo "OK $(bundle --version) found"
            fi

            # Check Passenger gem
            if ! gem list passenger --installed > /dev/null 2>&1; then
                echo "WARNING: Passenger gem is not installed."
                echo "  Install with: sudo gem install passenger"
            else
                echo "OK Passenger gem found"
            fi

            # Create public/ directory (RoR DocumentRoot)
            sudo mkdir -p "${domain_directory}/public"
            sudo chown ${username}:www-data "${domain_directory}/public"
            sudo chmod 755 "${domain_directory}/public"
            echo "OK public/ directory created"

            # Create a minimal config.ru (Rack entry point for Passenger)
            if [ ! -f "${domain_directory}/config.ru" ]; then
                cat > /tmp/_config_ru.$$ <<'ENDSCRIPT'
# Replace with your actual Rails app loader:
# require_relative 'config/environment'
# run Rails.application
run proc { |env|
  [200, { 'Content-Type' => 'text/html' }, ['<html><body><h1>Hello from Rails!</h1></body></html>']]
}
ENDSCRIPT
                sudo mv /tmp/_config_ru.$$ "${domain_directory}/config.ru"
                sudo chown ${username}:www-data "${domain_directory}/config.ru"
                sudo chmod 644 "${domain_directory}/config.ru"
                echo "OK Starter config.ru created (replace with your Rails app)"
            fi

            # Placeholder index.html in public/
            if [ ! -f "${domain_directory}/public/index.html" ]; then
                cat > /tmp/_index_html.$$ <<'ENDSCRIPT'
<!DOCTYPE html>
<html><body><h1>Ruby on Rails - Site Ready</h1>
<p>Deploy your Rails app to this directory.</p></body></html>
ENDSCRIPT
                sudo mv /tmp/_index_html.$$ "${domain_directory}/public/index.html"
                sudo chown ${username}:www-data "${domain_directory}/public/index.html"
                echo "OK Placeholder public/index.html created"
            fi
            ;;

        docker)
            echo "OK Docker proxy selected. Traffic will be forwarded to localhost:${docker_port}"
            # Create a sample docker-compose.yml as a hint
            if [ ! -f "${domain_directory}/docker-compose.yml" ]; then
                cat > /tmp/_docker_compose_yml.$$ <<ENDSCRIPT
version: '3.8'
services:
  web:
    image: nginx:alpine
    ports:
      - "127.0.0.1:${docker_port}:80"
    volumes:
      - ./public_html:/usr/share/nginx/html
ENDSCRIPT
                sudo mv /tmp/_docker_compose_yml.$$ "${domain_directory}/docker-compose.yml"
                sudo chown ${username}:www-data "${domain_directory}/docker-compose.yml"
                echo "OK Starter docker-compose.yml created in ${domain_directory}"
            fi
            ;;

        php|wordpress|*)
            # PHP Version Selection
            if [ -z "$php_version" ]; then
                echo "Available PHP versions:"
                installed_versions=$(ls /etc/php/ | grep -E '^[0-9]+\.[0-9]+$' | sort -r)
                if [ -z "$installed_versions" ]; then
                    echo "WARNING: No PHP versions found in /etc/php/"
                    php_version="8.2" # Fallback
                else
                    PS3="Please select PHP version (default: $(echo "$installed_versions" | head -n 1)): "
                    options=($installed_versions)
                    select opt in "${options[@]}"; do
                        if [ -n "$opt" ]; then
                            php_version=$opt
                            break
                        fi
                    done
                    # If user just presses enter, use the first one
                    if [ -z "$php_version" ]; then
                        php_version=$(echo "$installed_versions" | head -n 1)
                    fi
                fi
            fi
            echo "Selected PHP version: ${php_version}"

            # Check PHP-FPM service
            if ! systemctl is-active --quiet "php${php_version}-fpm"; then
                echo "WARNING: php${php_version}-fpm is not running. Attempting to start..."
                sudo systemctl start "php${php_version}-fpm"
            fi

            # Starter index.php (only if not wordpress, as wordpress will have its own setup)
            if [ "${site_type,,}" != "wordpress" ]; then
                if [ ! -f "${domain_directory}/index.php" ]; then
                    cat > /tmp/_index_php.$$ <<'ENDSCRIPT'
<?php
phpinfo();
ENDSCRIPT
                    sudo mv /tmp/_index_php.$$ "${domain_directory}/index.php"
                    sudo chown ${username}:www-data "${domain_directory}/index.php"
                    sudo chmod 644 "${domain_directory}/index.php"
                    echo "OK Starter index.php created"
                fi
            else
                echo "INFO: WordPress type selected. Please upload WordPress files to ${domain_directory}"
            fi
            ;;
    esac

    # Git Repository Setup
    if [ -n "$git_url" ]; then
        echo "=========================================="
        echo "  Git Repository Setup"
        echo "=========================================="
        
        if ! command -v git &> /dev/null; then
            echo "ERROR: Git is not installed. Installing git..."
            sudo apt update && sudo apt install -y git
        fi

        # Move existing index files if any
        if [ "$(ls -A ${domain_directory})" ]; then
            echo "Moving existing files to backup..."
            sudo mkdir -p "${domain_directory}/_backup_$(date +%s)"
            sudo mv ${domain_directory}/* "${domain_directory}/_backup_$(date +%s)/" 2>/dev/null
        fi

        echo "Cloning repository: $git_url (branch: $git_branch)"
        sudo -u "${username}" git clone -b "$git_branch" "$git_url" "${domain_directory}"
        
        if [ $? -eq 0 ]; then
            echo "OK Repository cloned successfully."
            
            # Setup Git Sync Script
            sync_script="${user_home}/.git-sync.sh"
            sync_log="${user_home}/git-sync.log"
            template_dir="$(dirname "$0")/templates"
            
            if [ -f "${template_dir}/git-sync.sh.template" ]; then
                sudo cp "${template_dir}/git-sync.sh.template" "$sync_script"
                sudo sed -i "s|{{REPO_PATH}}|${domain_directory}|g" "$sync_script"
                sudo sed -i "s|{{BRANCH}}|${git_branch}|g" "$sync_script"
                sudo sed -i "s|{{LOG_FILE}}|${sync_log}|g" "$sync_script"
                sudo chown ${username}:${username} "$sync_script"
                sudo chmod 700 "$sync_script"
                sudo touch "$sync_log"
                sudo chown ${username}:${username} "$sync_log"
                echo "OK Sync script created at $sync_script"
            fi

            # Setup Webhook Receiver
            webhook_file="${domain_directory}/deploy-webhook.php"
            if [ -f "${template_dir}/deploy-webhook.php.template" ]; then
                sudo cp "${template_dir}/deploy-webhook.php.template" "$webhook_file"
                sudo sed -i "s|{{GIT_SECRET}}|${git_secret}|g" "$webhook_file"
                sudo sed -i "s|{{USERNAME}}|${username}|g" "$webhook_file"
                sudo sed -i "s|{{SYNC_SCRIPT}}|${sync_script}|g" "$webhook_file"
                sudo sed -i "s|{{LOG_FILE}}|${sync_log}|g" "$webhook_file"
                sudo chown ${username}:www-data "$webhook_file"
                sudo chmod 644 "$webhook_file"
                echo "OK Webhook receiver created at $webhook_file"
            fi

            # Configure Sudoers for www-data to trigger sync
            sudoers_file="/etc/sudoers.d/git-sync-${username}"
            echo "www-data ALL=(${username}) NOPASSWD: ${sync_script}" | sudo tee "$sudoers_file" > /dev/null
            sudo chmod 440 "$sudoers_file"
            echo "OK Sudoers configuration added for webhook triggers."
        else
            echo "ERROR: Failed to clone repository."
        fi
    fi

    echo "Runtime environment setup complete."
    echo "=========================================="
}

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
    git_info=""
    if [ -n "$git_url" ]; then
        git_info="\nGit Repo: $git_url\nGit Branch: $git_branch\nWebhook Secret: $git_secret\nWebhook URL: http://$domain_name/deploy-webhook.php"
    fi

    email_json=$(cat <<EOF
{
  "personalizations": [{
    "to": [{"email": "$ADMIN_EMAIL"}]
  }],
  "from": {"email": "$SENDER_EMAIL", "name": "Server Setup"},
  "subject": "New Domain Setup: $domain_name",
  "content": [{
    "type": "text/plain",
    "value": "Domain Setup Details:\n\nDomain: $domain_name\nSystem User: $username\nSystem Pass: $sys_pass\nDocument Root: $domain_directory\n\nDatabase Info:\nDB Name: $db_name\nDB User: $db_user\nDB Password: $db_pass$git_info"
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

# Scaffold the runtime environment for the chosen site type
setup_runtime_environment

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
    docker)
        VHOST_CONFIG=$(cat <<EOF
<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    DocumentRoot ${domain_directory}

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${docker_port}/
    ProxyPassReverse / http://127.0.0.1:${docker_port}/

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
    php|wordpress|*)
        MODSEC_CONFIG=""
        if [ "${site_type,,}" = "wordpress" ]; then
            # Ensure the exclusions directory and file exist
            MODSEC_RULES_DIR="/etc/apache2/modsecurity-rules"
            MODSEC_WP_EXCLUSIONS="${MODSEC_RULES_DIR}/wordpress-exclusions.conf"
            sudo mkdir -p "$MODSEC_RULES_DIR"
            
            if [ ! -f "$MODSEC_WP_EXCLUSIONS" ]; then
                cat <<'MODSEC_EOF' | sudo tee "$MODSEC_WP_EXCLUSIONS" > /dev/null
# WordPress ModSecurity Exclusions
# These rules help prevent false positives for common WordPress administrative actions.

# 1. Allow WordPress Admin POST requests (Skip certain checks for known paths)
SecRule REQUEST_URI "@contains /wp-admin/" \
    "id:10001,phase:2,nolog,pass,ctl:ruleRemoveById=941100,ctl:ruleRemoveById=942100,ctl:ruleRemoveById=932150"

# 2. Support WordPress REST API
SecRule REQUEST_URI "@contains /wp-json/" \
    "id:10002,phase:2,nolog,pass,ctl:ruleRemoveById=942100,ctl:ruleRemoveById=300013,ctl:ruleRemoveById=300015,ctl:ruleRemoveById=300016,ctl:ruleRemoveById=300017"

# 3. Handle XML-RPC if used
SecRule REQUEST_URI "@contains xmlrpc.php" \
    "id:10003,phase:2,nolog,pass,ctl:ruleRemoveById=942100"

# 4. Global exclusions for common false positives in WordPress
# (Add more IDs here as identified in logs)
MODSEC_EOF
                echo "OK Created ModSecurity WordPress exclusions: $MODSEC_WP_EXCLUSIONS"
            fi

            MODSEC_CONFIG=$(cat <<MODSEC_BLOCK
    # ModSecurity Configuration for WordPress
    <IfModule security2_module>
        SecRuleEngine On
        SecAuditEngine On
        SecAuditLog \${APACHE_LOG_DIR}/${domain_name}_modsec_audit.log
        Include "$MODSEC_WP_EXCLUSIONS"
    </IfModule>
MODSEC_BLOCK
)
        fi

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

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${php_version}-fpm.sock|fcgi://localhost"
    </FilesMatch>

    <DirectoryMatch "/\.(?!well-known)">
        Require all denied
    </DirectoryMatch>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

${MODSEC_CONFIG}

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
if [ -n "$git_url" ]; then
    echo ""
    echo "Git Info:"
    echo "Repo URL:      ${git_url}"
    echo "Branch:        ${git_branch}"
    echo "Webhook Sec:   ${git_secret}"
    echo "Webhook URL:   http://${domain_name}/deploy-webhook.php"
fi
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
Git Repo:      ${git_url:-"none"}
Git Branch:    ${git_branch:-"none"}
Git Secret:    ${git_secret:-"none"}
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
