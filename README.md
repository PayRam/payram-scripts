# PayRam Self-Hosted Crypto Payment Gateway

🚀 **One-Line Setup** - Copy, paste, and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)"
```

## 💎 What is PayRam?

PayRam is a **self-hosted cryptocurrency payment gateway** that enables businesses to accept crypto payments directly - **no middleman, no fees, complete control**. Perfect for e-commerce, APIs, subscriptions, and any business wanting to embrace the future of payments.

## ✨ Key Features

- 🏛️ **Universal OS Support**: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux, Alpine, macOS
- 🐳 **Docker-Based**: Containerized deployment with automatic dependency management
- 🔐 **Security First**: AES-256 encryption, secure credential storage, SSL/TLS support
- 🌐 **Let's Encrypt Integration**: Automatic SSL certificate management
- 📊 **PostgreSQL Support**: External database integration with connection validation
- 🎨 **Enhanced UX**: Beautiful ASCII art banners and guided setup experience
- ⚡ **Quick Setup**: Complete gateway deployment in minutes

## 🚀 Quick Start

### Option 1: Direct Install (Recommended)
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)"
```

### Option 2: Download and Run
```bash
curl -O https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh
chmod +x setup_payram.sh
sudo ./setup_payram.sh
```

### Option 3: Clone Repository
```bash
git clone https://github.com/PayRam/payram-scripts.git
cd payram-scripts
sudo ./setup_payram.sh
```

## 🛠️ Advanced Usage

### Command Line Options

```bash
# Fresh installation (default)
sudo ./setup_payram.sh

# Update existing installation
sudo ./setup_payram.sh --update

# Testnet deployment
sudo ./setup_payram.sh --testnet

# Specific Docker image tag
sudo ./setup_payram.sh --tag=latest

# Complete reset (removes all data)
sudo ./setup_payram.sh --reset

# Help and usage
sudo ./setup_payram.sh --help
```

### Environment Variables

```bash
# Specify Docker image tag
PAYRAM_TAG=latest sudo ./setup_payram.sh

# Skip interactive prompts (use defaults)
PAYRAM_AUTO=true sudo ./setup_payram.sh
```

## 📋 Requirements

### System Requirements
- **OS**: Ubuntu 18.04+, Debian 9+, CentOS 7+, RHEL 7+, Fedora 30+, Arch Linux, Alpine Linux, macOS 10.14+
- **RAM**: 2GB minimum, 4GB recommended
- **Storage**: 10GB available space
- **Network**: Internet connection for Docker images and dependencies

### Automatic Dependencies
The script automatically installs:
- Docker & Docker Compose
- PostgreSQL client tools
- SSL certificate utilities
- Required system packages

## 🔧 Configuration

### Database Options
1. **External PostgreSQL** (Recommended)
   - Better performance and reliability
   - Automatic connection testing
   - Backup and scaling capabilities

2. **Internal Database**
   - Quick setup for testing
   - Single container deployment

### SSL Certificate Options
1. **Let's Encrypt** (Recommended)
   - Free SSL certificates
   - Automatic renewal
   - Domain validation

2. **Custom Certificates**
   - Bring your own SSL certs
   - Enterprise CA support

3. **Skip SSL**
   - For development/testing
   - Behind load balancer/proxy

## 🔐 Security Features

- **AES-256 Encryption**: Hot wallet and sensitive data protection
- **Secure Storage**: Configuration files with restricted permissions (600)
- **Privilege Separation**: Root access only when necessary
- **Database Security**: Encrypted connection strings and .pgpass files
- **SSL/TLS**: HTTPS encryption with automatic certificate management

## 📁 File Structure

```
/home/$USER/.payraminfo/          # Configuration directory
├── config.env                   # Main configuration file
├── aes/                         # AES encryption keys
└── ssl/                         # SSL certificates

/home/$USER/.payram-core/         # Application data
├── data/                        # Persistent application data
└── logs/                        # Application logs
```

## 🚨 Troubleshooting

### Common Issues

**Permission Denied**: Make sure to run with `sudo`
```bash
sudo ./setup_payram.sh
```

**Docker Not Found**: Script will install Docker automatically
```bash
# Manual Docker installation check
docker --version
```

**Port Conflicts**: Check if ports 80, 443, 8080, 8443 are available
```bash
sudo netstat -tlnp | grep ':80\|:443\|:8080\|:8443'
```

**SSL Certificate Issues**: Verify domain DNS points to your server
```bash
dig +short yourdomain.com
```

### Log Files
- **Setup Log**: `/tmp/payram-setup.log`
- **Application Logs**: `/home/$USER/.payram-core/logs/`
- **Docker Logs**: `docker logs payram-core`

## 📖 Documentation

- **API Documentation**: Available at `https://yourdomain.com/docs` after setup
- **Admin Panel**: Access at `https://yourdomain.com/admin`
- **Configuration Guide**: See `/home/$USER/.payraminfo/README.txt` after installation

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on multiple OS distributions
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **GitHub Issues**: [Report bugs and request features](https://github.com/PayRam/payram-scripts/issues)
- **Documentation**: [Full setup guide](https://docs.payram.org)
- **Community**: [Discord server](https://discord.gg/payram)

---

**PayRam** - Empowering businesses with decentralized payment infrastructure. No middleman, no fees, complete control. 🚀💎
