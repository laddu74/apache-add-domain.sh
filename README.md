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

### 4. `add_database.sh`
This script allows for adding an additional MySQL database to an existing system user.
- **Validation:** Checks if the system user and the primary database user (`username_usr`) exist.
- **Naming Pattern:** Databases are named following the pattern `username_suffix_db`.
- **Integration:** Fully respects `USE_MYSQL_AUTH` and `ENABLE_SENDGRID` flags.

**Usage:**
```bash
sudo ./add_database.sh username suffix
```

## Security & Notifications

### Environment Variables (`.env`)
The scripts now support a `.env` file for sensitive configurations. Use `.env.template` as a base.
- **MySQL Root Credentials:** `MYSQL_ROOT_USER` and `MYSQL_ROOT_PASS` prevent "Access Denied" errors when `sudo mysql` requires a password.
- **USE_MYSQL_AUTH flag:** Set to `true` to use credentials, or `false` to use direct `sudo mysql`.
- **SendGrid Integration:** Provide `SENDGRID_API_KEY`, `ADMIN_EMAIL`, and `SENDER_EMAIL` for setup details notifications.
- **ENABLE_SENDGRID flag:** Toggle email notifications on or off (`true`/`false`).

### Centralized Audit Log
Every successful domain creation is recorded in a centralized audit log: `/var/log/apache_setup_audit.log`.

## Changelog

### [2026-03-12]
- **Integrated Feature Flags**: Added `ENABLE_SENDGRID` and `USE_MYSQL_AUTH` for more granular control.
- **Implemented SendGrid Integration**: Automates email notifications for new setups.
- **Added Bulk Creation Script**: `bulk_add.sh` for batch domain provisioning.
- **Introduced Centralized Audit Logging**: Tracking all setup events in one place.
- **Added `.env` Support**: Secure handling of MySQL root credentials and API keys.

### [2026-03-13]
- **Added `add_database.sh` utility**: Facilitates adding extra databases to existing users.
- **Hardened MySQL Authentication**: Support for explicit credential-based or sudo authentication.
- **Enhanced Feature Toggling**: Consistent use of flags across all scripts.

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
