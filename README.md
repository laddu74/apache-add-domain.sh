# Apache Domain Management Scripts for Ubuntu

A set of automated bash utility scripts to quickly set up, secure, and remove Apache virtual hosts, along with dedicated system users and MySQL databases on Ubuntu/Debian servers. 

These scripts are specifically optimized for PHP-based applications (like WordPress) and enforce security best practices out of the box.

## Features

### 1. `add_domain.sh`
This script fully automates the provisioning of a new domain.
- **System Isolation:** Automatically creates a dedicated system user and a `public_html` directory with restricted permissions (`750` owner/www-data).
- **Secure Credentials:** Generates a highly secure 16-character random password for the system user (`openssl` generated).
- **Database Provisioning:** Creates a dedicated MySQL database and a specific database user, generating another secure random password, and strictly binding privileges.
- **Apache VirtualHost:** 
  - Generates an Apache `.conf` file.
  - Enables `AllowOverride All` (required for WordPress/PHP CMS Permalinks).
  - Hardens security by blocking directory listings (`-Indexes`) and hidden files/directories (like `.git` or `.env`).
  - Implements modern Security Headers (`nosniff`, `SAMEORIGIN`, `XSS-Protection`, `Referrer-Policy`).
- **Secure Logging:** Securely logs the generated credentials (DB User, DB Pass, System Pass, etc.) to a root-only accessible log file: `/var/log/apache_<domain_name>_setup.log`.

**Usage:**
```bash
sudo ./add_domain.sh example.com
```

### 2. `delete_domain.sh`
This script safely reverses the provisioning process, cleaning up the server.
- **Safety First:** Prompts the user for a final `y/N` confirmation before executing any destructive operations.
- **VirtualHost Cleanup:** Safely disables the Apache site, deletes the `.conf` file, and reloads the web server.
- **Database Cleanup:** Drops the specific database and its associated database user.
- **System Cleanup:** Kills any running processes under the system user, then removes the user and their home directory entirely (`/home/<username>`).
- **Log Cleanup:** Flushes the root credential log file created during setup.

**Usage:**
```bash
sudo ./delete_domain.sh example.com
```

### 3. `bulk_add.sh`
This script allows for provisioning multiple domains at once from a file.
- **Batch Processing:** Reads a simple list of domains from a text file and sequentially calls `add_domain.sh`.
- **Formatting:** Ignores empty lines and comments (lines starting with `#`).

**Usage:**
```bash
sudo ./bulk_add.sh domains.txt
```

## Security & Notifications

### Environment Variables (`.env`)
The scripts now support a `.env` file for sensitive configurations. Use `.env.template` as a base.
- **MySQL Root Credentials:** `MYSQL_ROOT_USER` and `MYSQL_ROOT_PASS` prevent "Access Denied" errors when `sudo mysql` requires a password.
- **SendGrid Integration:** If `SENDGRID_API_KEY`, `ADMIN_EMAIL`, and `SENDER_EMAIL` are provided, setup details are automatically emailed to the admin.

### Centralized Audit Log
Every successful domain creation is recorded in a centralized audit log: `/var/log/apache_setup_audit.log`.

## Changelog

### [2026-03-12]
- **Implemented SendGrid Integration**: Automates email notifications for new setups.
- **Added Bulk Creation Script**: `bulk_add.sh` for batch domain provisioning.
- **Introduced Centralized Audit Logging**: Tracking all setup events in one place.
- **Added `.env` Support**: Secure handling of MySQL root credentials and API keys.

## IDE / Development Rules

When contributing to or enhancing these scripts, please follow the project branching rules defined in `.cursorrules`:
1. **Branching Model:** Always branch off `main` for new features (e.g., `feature/awesome-new-script`).
2. **Merging:** Do not commit directly to `main`. Once a feature is verified and working, merge the branch into `main`.

## Requirements
- Ubuntu/Debian based Linux distribution
- Apache2 (`sudo apt install apache2`)
- MySQL or MariaDB (`sudo apt install mysql-server`)
- OpenSSL (pre-installed on most distributions)
- Curl (for SendGrid notifications)
