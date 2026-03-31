#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

if [ "$#" -lt 2 ]; then
    echo "Usage: sudo $0 <source_domain> <target_domain>"
    exit 1
fi

SOURCE_DOMAIN=$1
TARGET_DOMAIN=$2

# Load environment variables from .env file if it exists for root MySQL access
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Set default MySQL root user and pass if not provided in .env
MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-"root"}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-""}

if [ "${USE_MYSQL_AUTH,,}" = "true" ] && [ -n "$MYSQL_ROOT_PASS" ]; then
    MYSQL_CMD="mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASS"
    MYSQL_DUMP_CMD="mysqldump -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASS"
else
    MYSQL_CMD="sudo mysql"
    MYSQL_DUMP_CMD="sudo mysqldump"
fi

echo "=========================================="
echo " Cloning: $SOURCE_DOMAIN -> $TARGET_DOMAIN"
echo "=========================================="

# 1. Try to find source domain info
SOURCE_LOG="/var/log/apache_${SOURCE_DOMAIN}_setup.log"
OLD_DB_NAME=""
OLD_DB_USER=""
OLD_DB_PASS=""
OLD_DOCROOT=""

if [ -f "$SOURCE_LOG" ]; then
    echo "Found source domain setup log: $SOURCE_LOG"
    OLD_DB_NAME=$(grep "DB Name:" "$SOURCE_LOG" | awk '{print $NF}')
    OLD_DB_USER=$(grep "DB User:" "$SOURCE_LOG" | awk '{print $NF}')
    OLD_DB_PASS=$(grep "DB Password:" "$SOURCE_LOG" | awk '{print $NF}')
    OLD_DOCROOT=$(grep "Document Root:" "$SOURCE_LOG" | awk '{print $NF}')
fi

# If not found in log, prompt or try to find in common files
if [ -z "$OLD_DB_NAME" ] || [ -z "$OLD_DB_USER" ] || [ -z "$OLD_DB_PASS" ]; then
    echo "Could not find all source credentials in logs."
    read -p "Enter source DB Name (optional if root can find it): " OLD_DB_NAME
    read -p "Enter source DB User (required for find-replace): " OLD_DB_USER
    read -p "Enter source DB Pass (required for find-replace): " -s OLD_DB_PASS
    echo ""
fi

if [ -z "$OLD_DOCROOT" ]; then
    # Try default path
    CLEAN_SRC=$(echo "${SOURCE_DOMAIN}" | sed 's/[^a-zA-Z0-9]//g' | cut -c 1-16)
    OLD_DOCROOT="/home/${CLEAN_SRC}/public_html"
    if [ ! -d "$OLD_DOCROOT" ]; then
        read -p "Enter source Document Root [$OLD_DOCROOT]: " input_docroot
        OLD_DOCROOT=${input_docroot:-$OLD_DOCROOT}
    fi
fi

if [ ! -d "$OLD_DOCROOT" ]; then
    echo "ERROR: Source document root $OLD_DOCROOT does not exist."
    exit 1
fi

echo "Source Info:"
echo " - DB Name:  $OLD_DB_NAME"
echo " - DB User:  $OLD_DB_USER"
echo " - DocRoot:  $OLD_DOCROOT"

# 2. Setup Target Domain
echo "------------------------------------------"
echo "Initializing target domain: $TARGET_DOMAIN"
echo "------------------------------------------"

# Predict target credentials to use in find-replace
TARGET_USER=$(echo "${TARGET_DOMAIN}" | sed 's/[^a-zA-Z0-9]//g' | cut -c 1-16)
NEW_DB_NAME="${TARGET_USER}_db"
NEW_DB_USER="${TARGET_USER}_usr"
NEW_DB_PASS=$(openssl rand -base64 16)
NEW_SYS_PASS=$(openssl rand -base64 16)
NEW_DOCROOT="/home/${TARGET_USER}/public_html"

# Run add_domain.sh with pre-defined credentials
# Assumptions: add_domain.sh is in the same directory
./add_domain.sh "$TARGET_DOMAIN" \
    --db-name="$NEW_DB_NAME" \
    --db-user="$NEW_DB_USER" \
    --db-pass="$NEW_DB_PASS" \
    --sys-pass="$NEW_SYS_PASS"

if [ $? -ne 0 ]; then
    echo "ERROR: add_domain.sh failed."
    exit 1
fi

# 3. Sync Files
echo "------------------------------------------"
echo "Syncing files..."
echo "------------------------------------------"
sudo rsync -av --exclude='.git' "${OLD_DOCROOT}/" "${NEW_DOCROOT}/"
sudo chown -R ${TARGET_USER}:www-data "${NEW_DOCROOT}"

# 4. Clone Database
if [ -n "$OLD_DB_NAME" ]; then
    echo "------------------------------------------"
    echo "Cloning database: $OLD_DB_NAME -> $NEW_DB_NAME"
    echo "------------------------------------------"
    
    TMP_SQL="/tmp/${TARGET_DOMAIN}_$(date +%s).sql"
    $MYSQL_DUMP_CMD "$OLD_DB_NAME" > "$TMP_SQL"
    
    if [ $? -eq 0 ]; then
        # Replace domain and credentials in SQL dump
        echo "Updating SQL dump..."
        sed -i "s|${SOURCE_DOMAIN}|${TARGET_DOMAIN}|g" "$TMP_SQL"
        sed -i "s|${OLD_DB_USER}|${NEW_DB_USER}|g" "$TMP_SQL"
        sed -i "s|${OLD_DB_NAME}|${NEW_DB_NAME}|g" "$TMP_SQL"
        
        $MYSQL_CMD "$NEW_DB_NAME" < "$TMP_SQL"
        rm "$TMP_SQL"
        echo "Database imported successfully."
    else
        echo "WARNING: Database dump failed. Check credentials or database name."
    fi
fi

# 5. Recursive Find-Replace in Files
echo "------------------------------------------"
echo "Performing recursive find-replace in files..."
echo "------------------------------------------"

# Avoid infinite loops or replacing binary files if possible
# We'll use a simple approach for now
find "${NEW_DOCROOT}" -type f -not -path '*/.*' -exec sed -i "s|${SOURCE_DOMAIN}|${TARGET_DOMAIN}|g" {} +
if [ -n "$OLD_DB_USER" ]; then
    find "${NEW_DOCROOT}" -type f -not -path '*/.*' -exec sed -i "s|${OLD_DB_USER}|${NEW_DB_USER}|g" {} +
fi
if [ -n "$OLD_DB_PASS" ]; then
    find "${NEW_DOCROOT}" -type f -not -path '*/.*' -exec sed -i "s|${OLD_DB_PASS}|${NEW_DB_PASS}|g" {} +
fi
if [ -n "$OLD_DB_NAME" ]; then
    find "${NEW_DOCROOT}" -type f -not -path '*/.*' -exec sed -i "s|${OLD_DB_NAME}|${NEW_DB_NAME}|g" {} +
fi

echo "=========================================="
echo " CLONE COMPLETE"
echo "=========================================="
echo "Source: $SOURCE_DOMAIN"
echo "Target: $TARGET_DOMAIN"
echo "New DB Info:"
echo " - DB Name: $NEW_DB_NAME"
echo " - DB User: $NEW_DB_USER"
echo " - DB Pass: $NEW_DB_PASS"
echo "=========================================="
