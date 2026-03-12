#!/bin/bash

# Check if the script is executed with sudo
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Check if file argument is provided
if [ $# -ne 1 ]; then
    echo "Usage: sudo $0 domains_file.txt"
    exit 1
fi

domains_file=$1

if [ ! -f "$domains_file" ]; then
    echo "Error: File $domains_file not found."
    exit 1
fi

echo "=========================================="
echo " BULK DOMAIN CREATION"
echo "=========================================="

while IFS= read -r domain || [ -n "$domain" ]; do
    # Skip empty lines and comments
    [[ -z "$domain" || "$domain" =~ ^# ]] && continue
    
    # Trim whitespace
    domain=$(echo "$domain" | xargs)
    
    echo ">>> Provisioning: $domain"
    # Call the existing add_domain.sh script
    ./add_domain.sh "$domain"
    echo "------------------------------------------"
done < "$domains_file"

echo "Bulk creation setup complete."
