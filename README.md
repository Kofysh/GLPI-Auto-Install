<p align="center">
  <img src="https://raw.githubusercontent.com/glpi-project/glpi/main/public/pics/logos/logo-GLPI-250-black.png" alt="GLPI Logo" width="200"/>
</p>

<h1 align="center">🚀 GLPI Auto-Install</h1>

<p align="center">
  <strong>Automated installer for GLPI</strong><br>
  Deploy GLPI in minutes on any supported Linux distribution
</p>

<p align="center">
  <a href="#-features">Features</a> •
  <a href="#-supported-systems">Supported Systems</a> •
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-usage">Usage</a> •
  <a href="#-options">Options</a> •
  <a href="#-license">License</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-3.0.0-blue.svg" alt="Version"/>
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"/>
  <img src="https://img.shields.io/badge/GLPI-10.x-orange.svg" alt="GLPI Version"/>
  <img src="https://img.shields.io/badge/shell-bash-lightgrey.svg" alt="Shell"/>
</p>

---

## 📋 Description

**GLPI Auto-Install** is a professional Bash script that fully automates the installation of [GLPI](https://glpi-project.org/) (IT Asset Management Software) on Linux servers. The script automatically detects your operating system, downloads the latest GLPI version, and configures the entire LAMP stack.

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔍 **Auto-detection** | Detects OS, version and automatically configures parameters |
| 📦 **Latest GLPI version** | Automatically fetches and installs the latest stable release via GitHub API |
| 🛡️ **Enhanced security** | Data separation outside webroot, secure HTTP headers, strict permissions |
| 🔄 **Rollback system** | Automatic rollback of changes on failure |
| 📝 **Full logging** | Detailed logs in `/var/log/glpi-installer/` |
| 🔐 **Secure passwords** | Automatic cryptographic password generation |
| ⚙️ **SELinux support** | Full support for RHEL/CentOS/Rocky/Alma |
| 🎨 **Intuitive interface** | Progress bars, colors and clear messages |
| 💾 **Auto backup** | Backs up existing installation before replacement |

## 💻 Supported Systems

| Distribution | Versions |
|--------------|----------|
| **Debian** | 10, 11, 12 |
| **Ubuntu** | 20.04, 22.04, 24.04 |
| **RHEL** | 8, 9 |
| **CentOS** | 8, 9 |
| **Rocky Linux** | 8, 9 |
| **AlmaLinux** | 8, 9 |
| **Fedora** | 38, 39, 40 |

## 📋 Requirements

- Root or sudo access
- Internet connection
- **Minimum 1 GB RAM**
- **Minimum 5 GB disk space**

## ⚡ Quick Start

### One-Line Install (Recommended)

```bash
curl -sL https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh | sudo bash
```

### One-Line Install (Automatic Mode)

```bash
curl -sL https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh | sudo bash -s -- -y
```

### Download and Run

```bash
# Download
curl -O https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh

# Make executable
chmod +x glpi-installer.sh

# Run
sudo ./glpi-installer.sh
```

### Using wget

```bash
wget https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh
chmod +x glpi-installer.sh
sudo ./glpi-installer.sh
```

### Clone Repository

```bash
git clone https://github.com/Kofysh/GLPI-Auto-Install.git
cd GLPI-Auto-Install
sudo ./glpi-installer.sh
```

## 📖 Usage

### Interactive Installation (Recommended)

```bash
sudo ./glpi-installer.sh
```

The script will guide you through the steps with confirmations.

### Automatic Installation

```bash
sudo ./glpi-installer.sh -y
```

Ideal for automated deployments and scripts.

### Dry-Run Mode

```bash
sudo ./glpi-installer.sh -d
```

Shows what would be done without making any changes.

### Custom Installation

```bash
sudo ./glpi-installer.sh \
  --db-name my_glpi_db \
  --db-user my_user \
  --db-pass MySecurePassword123! \
  --timezone America/New_York \
  --domain glpi.mycompany.com
```

### Piped with Options

```bash
curl -sL https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh | sudo bash -s -- -y --timezone Europe/London
```

## 🎛️ Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Display help message |
| `-v, --verbose` | Verbose mode (more details) |
| `-y, --yes` | Automatic mode (answer yes to all) |
| `-f, --force` | Force installation on unsupported OS |
| `-d, --dry-run` | Simulation without changes |
| `--skip-checks` | Skip requirements verification |
| `--db-name NAME` | Database name (default: glpi_db) |
| `--db-user USER` | Database user (default: glpi_user) |
| `--db-pass PASS` | Database password (auto-generated if omitted) |
| `--timezone TZ` | Timezone (default: Europe/Paris) |
| `--domain DOMAIN` | Server domain name |
| `--version` | Display script version |

## 📂 File Structure

After installation, files are organized following security best practices:

```
/var/www/html/glpi/      # GLPI application (source code)
/var/lib/glpi/           # Data (files, marketplace)
/var/log/glpi/           # GLPI logs
/etc/glpi/               # Configuration
/var/log/glpi-installer/ # Installation logs
/root/.glpi_credentials  # Credentials (chmod 600)
```

## 🔐 Post-Installation

### 1. Access GLPI

Open your browser and navigate to:
```
http://YOUR_SERVER_IP/glpi
```

### 2. Complete Setup Wizard

Follow the web wizard and enter the database information displayed at the end of the script.

### 3. Default Accounts

| Account | Username | Password | Role |
|---------|----------|----------|------|
| Super-Admin | `glpi` | `glpi` | Full administrator |
| Admin | `tech` | `tech` | Technician |
| Normal | `normal` | `normal` | Standard user |
| Post-only | `post-only` | `post-only` | Ticket creation only |

> ⚠️ **IMPORTANT**: Change all default passwords immediately!

### 4. Post-Installation Security

```bash
# Remove installation script
sudo rm /var/www/html/glpi/install/install.php

# Verify permissions
sudo ls -la /var/lib/glpi/
sudo ls -la /etc/glpi/
```

### 5. HTTPS Configuration (Recommended for Production)

```bash
# Debian/Ubuntu with Certbot
sudo apt install certbot python3-certbot-apache
sudo certbot --apache -d glpi.yourdomain.com

# RHEL/CentOS/Rocky/Fedora
sudo dnf install certbot python3-certbot-apache
sudo certbot --apache -d glpi.yourdomain.com
```

## 📊 What Gets Installed

- **Apache** (web server)
- **MariaDB** (database)
- **PHP** + required extensions (mysql, ldap, imap, curl, gd, mbstring, xml, intl, zip, bz2, opcache)
- **GLPI** (latest stable version)
- **Cron job** for automatic actions

## 🐛 Troubleshooting

### View Installation Logs

```bash
ls -la /var/log/glpi-installer/
cat /var/log/glpi-installer/install_*.log
```

### Check Services

```bash
# Debian/Ubuntu
sudo systemctl status apache2 mariadb

# RHEL/CentOS/Rocky/Fedora
sudo systemctl status httpd mariadb
```

### Test Database Connection

```bash
# Credentials are stored in:
sudo cat /root/.glpi_credentials

# Test connection
mysql -u glpi_user -p glpi_db
```

### Check Permissions

```bash
ls -la /var/www/html/glpi/
ls -la /var/lib/glpi/
ls -la /etc/glpi/
```

### Common Issues

| Issue | Solution |
|-------|----------|
| "Permission denied" | Run with `sudo` |
| "No network connectivity" | Check internet connection |
| Database connection failed | Verify credentials in `/root/.glpi_credentials` |
| Apache won't start | Check logs: `journalctl -xeu apache2` or `httpd` |
| SELinux blocking access | Script configures SELinux automatically, check `audit.log` |

## 🤝 Contributing

Contributions are welcome! Feel free to:

1. Fork the project
2. Create a branch (`git checkout -b feature/improvement`)
3. Commit your changes (`git commit -am 'Add new feature'`)
4. Push to the branch (`git push origin feature/improvement`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [GLPI Project](https://glpi-project.org/) for this excellent IT asset management tool
- The open source community

---

<p align="center">
  <sub>⭐ If this project helped you, please consider giving it a star!</sub>
</p>
