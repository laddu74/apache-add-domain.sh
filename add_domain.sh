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
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;"
    sudo mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
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
cat <<EOF | sudo tee "$apache_conf" > /dev/null
<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    DocumentRoot ${domain_directory}

    <Directory ${domain_directory}>
        # Hardening: Disallow directory listing, allow symlinks
        Options -Indexes +FollowSymLinks
        # Allow .htaccess to override configurations (Required for WordPress/PHP CMS)
        AllowOverride All
        Require all granted
    </Directory>

    # Hardening: Block access to hidden files and directories (like .git, .env)
    <DirectoryMatch "/\.(?!well-known)">
        Require all denied
    </DirectoryMatch>

    # Hardening: Security Headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${domain_name}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain_name}_access.log combined
</VirtualHost>
EOF

echo "VirtualHost configuration created."

echo "=========================================="
echo "4. Enabling Site and Applying Changes"
echo "=========================================="
# Enable the required modules for WordPress and security headers
sudo a2enmod rewrite headers > /dev/null 2>&1

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
log_file="/var/log/apache_domain_setup.log"
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
