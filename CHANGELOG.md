# Changelog

All notable changes to the Apache Domain Management Scripts project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [2026-11-15] - Node.js Support & Port Collision Protection

### Added
- **Node.js Application Support**: Added `--type=node` (and `--type=nodejs`) with reverse proxy forwarding and WebSocket upgrade support (`ws://`).
- **Configurable Application Port**: Supported `--port=...` / `-p ...` (default: 3000 for Node.js, 8080 for Docker).
- **Port Collision Protection**: Automatically detects port conflicts against existing Apache VirtualHosts and active listening sockets; auto-increments to the next available port for defaults or alerts and aborts on conflicting explicit ports.
- **Automated Node.js Scaffolding**: Proactively generates starter `package.json`, `server.js` HTTP server, and PM2 `ecosystem.config.js`.
- **Runtime Dependency Checks**: Checks for `node`/`nodejs`, `npm`, and `pm2`, providing actionable installation guidance when missing.
- **PM2 Process Cleanup**: Enhanced `delete_domain.sh` to cleanly stop and delete PM2 processes registered for the domain upon full purge.

---

## [2026-05-20] - Interactive Deletion & Collision Protection

### Added
- **Interactive Deletion Modes**: Added support for selecting between a "Full Purge" and a safe "Deactivate Only" mode in `delete_domain.sh` to preserve code files and MySQL databases by default.
- **Collision Protection**: Automatically appends a random 4-letter alphabetic suffix (with 12-char trimming to fit legacy 16-char boundaries) when system username collisions are detected in `add_domain.sh`.
- **Custom Username Argument**: Added support for explicitly setting system usernames via `--username`/`-u` in `add_domain.sh`.
- **Dynamic Username Resolution**: Both `delete_domain.sh` and `rotate_passwords.sh` now dynamically look up usernames from `/var/log/apache_${domain_name}_setup.log` for secure operations.
- **Synchronized Cloning**: Enhanced `clone_domain.sh` to pass the target username parameter explicitly to `add_domain.sh` when duplicating domains.

---

## [2026-03-31] - Multi-PHP Support & Domain Cloning

### Added
- **Multi-PHP Support**: Integrated PHP-FPM with support for multiple side-by-side PHP versions.
- **Automatic PHP Discovery**: Script now detects installed PHP versions and offers an interactive selection.
- **Domain Cloning**: Added `clone_domain.sh` for full site and database duplication.
- **Recursive Find-Replace**: Cloning process automatically updates domain names and credentials in files and DB.
- **Enhanced `add_domain.sh` CLI**: Added support for passing manual database and system credentials via arguments.

---

## [2026-03-15] - Multi-Type Site Support & Passwords

### Added
- **Multi-Type Site Support:** Added support for Perl, Python (WSGI), Ruby on Rails (Passenger), and Docker (Reverse Proxy) sites.
- **Improved Module Management:** Integrated automated Apache module checking and user alerting for system dependencies.
- **Dynamic VirtualHost Generation:** Configures Apache based on the `--type` flag.
- **Password Rotation:** Added `rotate_passwords.sh` to securely rotate system and database passwords for a domain.

---

## [2026-03-13] - Database Utilities & Auth Hardening

### Added
- **Added `add_database.sh` utility**: Facilitates adding extra databases to existing users.
- **Hardened MySQL Authentication**: Support for explicit credential-based or sudo authentication.
- **Enhanced Feature Toggling**: Consistent use of flags across all scripts.

---

## [2026-03-12] - Initial Feature Suite

### Added
- **Integrated Feature Flags**: Added `ENABLE_SENDGRID` and `USE_MYSQL_AUTH` for more granular control.
- **Implemented SendGrid Integration**: Automates email notifications for new setups.
- **Added Bulk Creation Script**: `bulk_add.sh` for batch domain provisioning.
- **Introduced Centralized Audit Logging**: Tracking all setup events in one place.
- **Added `.env` Support**: Secure handling of MySQL root credentials and API keys.
