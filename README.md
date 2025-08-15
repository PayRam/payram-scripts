# Payram Self-Hosted Crypto Payment Gateway Setup Script (Version 2)

## Overview

Payram is a self-hosted cryptocurrency payment gateway that enables businesses to accept crypto payments. This streamlined setup script provides a simplified deployment process focused on Docker container management with interactive configuration.

## What This Script Does

This simplified bash script automates the Docker container deployment and basic configuration of a Payram crypto payment gateway instance. It focuses on container management rather than complex API configurations, providing a more user-friendly setup experience.

## Script Audit & Flow Analysis (Version 2)

### 1. **Security & Privilege Management**
- **Root Check**: Script requires root privileges for Docker and system operations
- **Secure Configuration Storage**: Uses restrictive permissions (600) for config files
- **Password Security**: Uses .pgpass file for secure PostgreSQL connection testing

### 2. **Command-line Arguments Handling**
The script supports multiple operational modes:
- `--update`: Updates existing Payram installation with version selection
- `--reset`: Completely removes Payram containers, images, and data
- `--testnet`: Sets up testnet environment (DEVELOPMENT mode)
- `--tag=<tag>` or `-T=<tag>`: Specifies Docker image tag
- `--help` or `-h`: Shows usage information
- Default: Interactive fresh installation

### 3. **Dependency Management**
Simplified dependency installation for Ubuntu:
```
├── Docker (docker.io package)
├── PostgreSQL Client (postgresql-client)
└── Automatic user group management
```

### 4. **Configuration Storage System**
- **Config Directory**: `/home/ubuntu/.payraminfo/`
- **Config File**: `/home/ubuntu/.payraminfo/config.env`
- **AES Key Storage**: `/home/ubuntu/.payraminfo/aes/`
- **Data Directory**: `/home/ubuntu/.payram-core/`
- **Secure Permissions**: 600 on configuration files

### 5. **Docker Container Management**
- **Image**: `buddhasource/payram-core:develop` (default)
- **Tag Validation**: Verifies Docker image exists before deployment
- **Clean Deployment**: Removes existing containers/images before update
- **Port Mapping**: 8080, 8443, 80, 443, 5432
- **Volume Mounts**: Persistent data storage

### 6. **Interactive Configuration**
The script provides guided setup for:

#### Database Configuration:
- **Option 1**: External PostgreSQL database (recommended)
  - Interactive connection testing
  - Credential validation
- **Option 2**: Default internal database

#### SSL Certificate Configuration:
- **Option 1**: Custom SSL certificates (Let's Encrypt, etc.)
  - Path validation
  - Certificate file verification (fullchain.pem, privkey.pem)
- **Option 2**: Skip SSL (use cloud services)

### 7. **Update Management**
- **Version Selection Menu**: Choose between new/current/cancel
- **Configuration Preservation**: Loads existing settings
- **Safe Updates**: Validates before proceeding

## Critical Issues & Security Concerns Identified

### 🔴 **CRITICAL SECURITY ISSUES**

#### 1. **Root Privilege Requirement**
- **Issue**: Script requires root privileges for all operations
- **Risk**: Unnecessary elevated privileges for file operations
- **Impact**: Increases attack surface and potential for privilege escalation
- **Recommendation**: Implement privilege dropping and use sudo only when necessary

#### 2. **Insecure Configuration Storage**
- **Issue**: Database passwords stored in plaintext in `/home/ubuntu/.payraminfo/config.env`
- **Risk**: Sensitive credentials accessible to anyone with file system access
- **Impact**: Database compromise if config file is exposed
- **Recommendation**: Implement environment variable encryption or use Docker secrets

#### 3. **Hard-coded Directory Paths**
- **Issue**: Fixed paths to `/home/ubuntu/` regardless of actual user
- **Risk**: Permission issues, path traversal vulnerabilities
- **Impact**: Script failure on different user configurations
- **Recommendation**: Use `$HOME` or detect actual user dynamically

#### 4. **Docker Image Tag Validation Bypass**
- **Issue**: Network-dependent validation that can be bypassed
- **Risk**: Potentially malicious or non-existent images could be pulled
- **Impact**: Container failure or security compromise
- **Recommendation**: Implement offline tag format validation and checksum verification

### 🟡 **HIGH PRIORITY ISSUES**

#### 5. **Unsafe File Operations**
- **Issue**: Uses `rm -rf` without proper validation
- **Risk**: Accidental deletion of critical system files
- **Impact**: Data loss or system corruption
- **Recommendation**: Add path validation and confirmation prompts

#### 6. **Missing Input Sanitization**
- **Issue**: User inputs not validated or sanitized
- **Risk**: Command injection, path traversal attacks
- **Impact**: System compromise through malicious input
- **Recommendation**: Implement comprehensive input validation

#### 7. **PostgreSQL Connection Security**
- **Issue**: Database credentials passed through command line and temporary files
- **Risk**: Credential exposure in process lists and temporary files
- **Impact**: Database access compromise
- **Recommendation**: Use environment variables and secure connection methods

#### 8. **Docker Socket Exposure**
- **Issue**: Container runs with Docker socket access (potential)
- **Risk**: Container escape and host system access
- **Impact**: Full host compromise
- **Recommendation**: Verify container security boundaries

### 🟠 **MEDIUM PRIORITY ISSUES**

#### 9. **Port Exposure**
- **Issue**: Multiple ports exposed without firewall configuration
- **Risk**: Unauthorized access to internal services
- **Impact**: Service disruption or data access
- **Recommendation**: Implement firewall rules and port access controls

#### 10. **Logging and Monitoring Gaps**
- **Issue**: Limited error logging and security monitoring
- **Risk**: Undetected security incidents
- **Impact**: Delayed incident response
- **Recommendation**: Implement comprehensive logging and monitoring

#### 11. **Version Management Issues**
- **Issue**: No version pinning or integrity verification
- **Risk**: Supply chain attacks or version conflicts
- **Impact**: Service instability or compromise
- **Recommendation**: Implement image signing and version pinning

### 🔵 **LOW PRIORITY ISSUES**

#### 12. **User Experience Issues**
- **Issue**: No graceful error handling or recovery options
- **Risk**: User confusion and potential data loss
- **Impact**: Poor user experience and support burden
- **Recommendation**: Improve error messages and recovery procedures

## Prerequisites (Updated)

### System Requirements
- **Operating System**: Ubuntu (primarily tested) or compatible Linux distribution
- **User Account**: Root access required (security concern - see issues above)
- **RAM**: Minimum 2GB, Recommended 4GB+
- **Storage**: Minimum 10GB free space
- **Network**: Internet connection for Docker image pulls

### Required Preparation
Unlike the previous version, this script does NOT require a config.yaml file. All configuration is done interactively.

## Installation Steps (Updated for Version 2)

### 1. Download and Setup
```bash
# Clone the repository
git clone https://github.com/PayRam/payram-scripts.git
cd payram-scripts

# Make script executable
chmod +x script.sh
```

### 2. Run the Setup
```bash
# Fresh installation (interactive setup)
sudo ./script.sh

# Update existing installation
sudo ./script.sh --update

# Set up testnet environment
sudo ./script.sh --testnet

# Use specific Docker image tag
sudo ./script.sh --tag=v1.5.0

# Complete reset (removes all data)
sudo ./script.sh --reset

# View help
./script.sh --help
```

### 3. Interactive Setup Process
The script will guide you through:

#### Database Configuration
1. **External PostgreSQL** (recommended):
   - Enter database host, port, name
   - Provide username and password
   - Automatic connection testing

2. **Default Internal Database**:
   - Uses built-in PostgreSQL instance
   - Default credentials: payram/payram123

#### SSL Certificate Setup
1. **Custom SSL Certificates**:
   - Provide certificate directory path
   - Validates presence of fullchain.pem and privkey.pem
   - Checks file permissions and readability

2. **Skip SSL Configuration**:
   - Use with cloud services (Cloudflare, AWS, etc.)
   - Configure SSL externally

### 4. Container Deployment
The script will:
1. Install required dependencies (Docker, PostgreSQL client)
2. Validate Docker image tag
3. Generate AES encryption key
4. Save configuration securely
5. Deploy PayRam container
6. Verify container health

## Configuration Files (Version 2)

### Automatic Configuration Storage
Configuration is automatically saved to:
```
/home/ubuntu/.payraminfo/config.env
```

Example configuration file:
```bash
# PayRam Configuration - Do not edit manually unless you know what you are doing.
IMAGE_TAG="develop"
NETWORK_TYPE="mainnet"
SERVER="PRODUCTION"
AES_KEY="abc123..."
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="payram"
DB_USER="payram"
DB_PASSWORD="payram123"
POSTGRES_SSLMODE="prefer"
SSL_CERT_PATH="/etc/letsencrypt/live/example.com"
```

### Directory Structure
```
/home/ubuntu/
├── .payraminfo/              # Configuration storage
│   ├── config.env           # Main configuration file (600 permissions)
│   └── aes/                 # AES encryption keys
│       └── [generated-key]  # AES key file
└── .payram-core/            # Application data
    ├── log/                 # Application logs
    └── db/postgres/         # Database files (if using internal DB)
```

## Port Configuration (Unchanged)

The Docker container exposes the following ports:
- **8080**: HTTP API endpoint
- **8443**: HTTPS/WebSocket secure endpoint
- **80**: HTTP web interface
- **443**: HTTPS web interface
- **5432**: PostgreSQL database (if using internal DB)

## Volume Mounts (Updated)

Persistent data is stored in:
- `/home/ubuntu/.payram-core/`: Main application data
- `/home/ubuntu/.payram-core/log/supervisord/`: Application logs
- `/home/ubuntu/.payram-core/db/postgres/`: Database files
- `/etc/letsencrypt/`: SSL certificates (mounted read-only)

## Security Features (Updated)

### Encryption
- **AES-256** encryption for sensitive data
- Unique encryption keys generated per installation
- Keys stored in `/home/ubuntu/.payraminfo/aes/`

### Configuration Security
- **File Permissions**: Configuration files use 600 permissions (owner read/write only)
- **Secure Storage**: Sensitive data stored in restricted directories
- **Environment Variables**: Database credentials passed via environment variables

### SSL/TLS
- Support for Let's Encrypt certificates
- Custom certificate path configuration
- Certificate file validation during setup

## Container Features

### Environment Variables
The container is configured with:
```bash
AES_KEY="[generated-256-bit-key]"
BLOCKCHAIN_NETWORK_TYPE="mainnet|testnet"
SERVER="PRODUCTION|DEVELOPMENT"
POSTGRES_SSLMODE="prefer"
POSTGRES_HOST="[database-host]"
POSTGRES_PORT="[database-port]"
POSTGRES_DATABASE="[database-name]"
POSTGRES_USERNAME="[database-user]"
POSTGRES_PASSWORD="[database-password]"
SSL_CERT_PATH="[certificate-path]"
```

### Default Configuration
- **Image Tag**: `develop` (can be overridden)
- **Network Type**: `mainnet` (use `--testnet` for testnet)
- **Server Mode**: `PRODUCTION` (automatically set to `DEVELOPMENT` with `--testnet`)
- **SSL Mode**: `prefer` for PostgreSQL connections

## Troubleshooting (Updated for Version 2)

### Common Issues

#### 1. Permission Errors
```bash
# Ensure script is run as root
sudo ./script.sh

# Check file permissions on config directory
ls -la /home/ubuntu/.payraminfo/
```

#### 2. Docker Issues
```bash
# Check Docker service status
systemctl status docker

# Check if Docker daemon is running
docker version

# View container logs
docker logs payram

# Check container status
docker ps -a
```

#### 3. Database Connection Issues
```bash
# Test PostgreSQL connection manually
psql -h [DB_HOST] -p [DB_PORT] -U [DB_USER] -d [DB_NAME]

# Check if database service is running
systemctl status postgresql  # for local installations
```

#### 4. SSL Certificate Issues
```bash
# Verify certificate files exist
ls -la /path/to/ssl/certificates/

# Check certificate permissions
ls -la /path/to/ssl/certificates/*.pem

# Test certificate validity
openssl x509 -in /path/to/ssl/certificates/fullchain.pem -text -noout
```

#### 5. Port Conflicts
```bash
# Check what's using the ports
sudo netstat -tlnp | grep :8080
sudo netstat -tlnp | grep :80
sudo lsof -i :8080
```

#### 6. Configuration Issues
```bash
# View current configuration
sudo cat /home/ubuntu/.payraminfo/config.env

# Check configuration file permissions
ls -la /home/ubuntu/.payraminfo/config.env

# Validate environment variables
docker exec payram env | grep -E "(AES_KEY|POSTGRES|SERVER)"
```

### Error Messages and Solutions

#### "Error: This script must be run as root"
```bash
# Solution: Run with sudo
sudo ./script.sh
```

#### "Error: A 'payram' container is already running"
```bash
# Solution: Use update flag or reset first
sudo ./script.sh --update
# OR
sudo ./script.sh --reset
```

#### "❌ Connection failed. Please check your details and try again."
- Verify database host is reachable
- Check database credentials
- Ensure database exists and user has proper permissions
- Check firewall settings

#### "❌ Failed to pull the Docker image"
- Check internet connection
- Verify Docker image tag exists
- Check Docker registry accessibility

### Recovery Procedures

#### Reset Configuration Only
```bash
# Remove configuration files (keeps data)
sudo rm -rf /home/ubuntu/.payraminfo/
```

#### Reset Everything
```bash
# Complete reset using script
sudo ./script.sh --reset
```

#### Manual Container Management
```bash
# Stop container
docker stop payram

# Start container
docker start payram

# Restart container
docker restart payram

# Remove container
docker rm -f payram

# Remove images
docker rmi buddhasource/payram-core:develop
```

## Maintenance Commands (Updated)

### Update PayRam
```bash
# Interactive update with version selection
sudo ./script.sh --update

# Update to specific version
sudo ./script.sh --update --tag=v1.5.0
```

### Backup Important Data
```bash
# Backup configuration and data
sudo tar -czf payram-backup-$(date +%Y%m%d).tar.gz \
    /home/ubuntu/.payraminfo/ \
    /home/ubuntu/.payram-core/

# Backup only configuration
sudo cp -r /home/ubuntu/.payraminfo/ ./payram-config-backup/
```

### Restore from Backup
```bash
# Stop container first
docker stop payram

# Restore configuration
sudo tar -xzf payram-backup-20240814.tar.gz -C /

# Restart container
sudo ./script.sh --update
```

### Monitor System Health
```bash
# Check container health
docker ps
docker stats payram

# Check logs
docker logs payram --tail 50 -f

# Check disk usage
df -h /home/ubuntu/.payram-core/

# Check memory usage
free -h
```

## Security Recommendations (Critical)

### Immediate Actions Required

#### 1. **Fix Root Privilege Requirements**
```bash
# Current (insecure): Script requires full root access
sudo ./script.sh

# Recommended: Implement privilege separation
# - Use sudo only for specific operations
# - Drop privileges after system setup
# - Use user's home directory instead of hardcoded paths
```

#### 2. **Secure Configuration Storage**
```bash
# Current (insecure): Plaintext passwords in config files
cat /home/ubuntu/.payraminfo/config.env

# Recommended: Encrypt sensitive data
# - Use Docker secrets for passwords
# - Implement configuration encryption
# - Use environment variables from secure sources
```

#### 3. **Validate User Inputs**
```bash
# Add input validation for all user inputs
# - Database credentials
# - File paths
# - Docker image tags
# - SSL certificate paths
```

#### 4. **Implement Path Security**
```bash
# Replace hardcoded paths
PAYRAM_HOME="/home/ubuntu"  # Insecure

# With dynamic user detection
PAYRAM_HOME="$HOME"  # More secure
```

### Production Deployment Security

#### Network Security
```bash
# Configure firewall rules
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw deny 8080/tcp  # Restrict API access
sudo ufw deny 5432/tcp  # Restrict database access
sudo ufw enable
```

#### Container Security
```bash
# Run container with limited privileges
docker run --user 1000:1000 \
  --read-only \
  --tmpfs /tmp \
  --security-opt no-new-privileges:true \
  # ... other options
```

#### SSL/TLS Configuration
```bash
# Use strong SSL configurations
# - TLS 1.2+ only
# - Strong cipher suites
# - HSTS headers
# - Certificate pinning
```

### Monitoring and Alerts

#### Setup Log Monitoring
```bash
# Monitor container logs
docker logs payram | grep -E "(ERROR|WARN|FAIL)"

# Setup log rotation
# Configure system monitoring
# Implement security alerts
```

#### Regular Security Checks
```bash
# Check for security updates
sudo apt update && sudo apt list --upgradable

# Scan for vulnerabilities
docker scan buddhasource/payram-core:develop

# Review access logs
tail -f /var/log/auth.log
```

## Support & Documentation (Updated)

### Access Your Installation
After successful setup, PayRam should be accessible at:
- **HTTP**: `http://your-server-ip:8080`
- **HTTPS**: `https://your-domain:8443` (if SSL configured)
- **Standard Ports**: `http://your-domain` (port 80) or `https://your-domain` (port 443)

### Getting Help
1. **Check Container Status**: `docker ps` and `docker logs payram`
2. **Verify Configuration**: `sudo cat /home/ubuntu/.payraminfo/config.env`
3. **Test Database Connection**: Use provided connection test during setup
4. **Review SSL Setup**: Verify certificate files and permissions
5. **Check System Resources**: `df -h`, `free -h`, `docker stats payram`

### Important Notes
- **API Configuration**: This version focuses on container deployment only
- **Advanced Configuration**: Additional setup may be required via web interface
- **Blockchain Configuration**: May need to be done post-installation
- **Email Templates**: Not included in this simplified version
- **Project Management**: Handled through the web interface

## Version 2 Differences Summary

### Removed Features (from Version 1)
- ❌ Complex API-based configuration
- ❌ YAML configuration file requirements
- ❌ Blockchain automatic setup
- ❌ Email template configuration
- ❌ Project/merchant API key generation
- ❌ Extended wallet address generation
- ❌ Multi-OS support (now Ubuntu-focused)

### Added Features (Version 2)
- ✅ Interactive setup process
- ✅ Database connection testing
- ✅ SSL certificate validation
- ✅ Version selection during updates
- ✅ Improved error handling
- ✅ Secure configuration storage
- ✅ Container health verification

### Simplified Workflow
```
Version 1: Install Dependencies → Configure YAML → Run Container → API Setup → Blockchain Config → Email Templates → Projects
Version 2: Install Dependencies → Interactive Config → Run Container → Done
```

## Recommendations for Production Use

### Before Deployment
1. **Address all critical security issues** listed above
2. **Test in development environment** first
3. **Setup proper SSL certificates** from trusted CA
4. **Configure external database** (recommended)
5. **Implement proper backup strategy**
6. **Setup monitoring and alerting**

### After Deployment
1. **Complete additional configuration** via web interface
2. **Configure blockchain connections**
3. **Set up payment processing**
4. **Test payment flows**
5. **Monitor system performance**
6. **Regular security updates**

---

**⚠️ WARNING**: This version has significant security vulnerabilities that must be addressed before production use. The simplified approach trades comprehensive automated setup for ease of use, but requires additional manual configuration and security hardening.
