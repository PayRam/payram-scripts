# PayRam Self-Hosted Crypto Payment Gateway

Choose one of two paths:

- **Standard setup** (full install + UI)
- **Agent setup** (single CLI flow for AI agents automation)

**Agent One-Line Setup** - Copy, paste, and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram_agents.sh)"
```

🚀 **Standard One-Line Setup** - Copy, paste, and run:

```bash
bash <(curl -fsSL https://payram.com/setup_payram.sh)
```

If you see a permissions error, rerun with:

```bash
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh)'
```

💡 **One-Line with Arguments** - Use the same pattern with flags:

```bash
# Fresh installation (default)
bash <(curl -fsSL https://payram.com/setup_payram.sh)

# Update existing installation
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --update'

# Complete reset (removes all data)
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --reset'

# Testnet deployment
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --testnet'

# Specific Docker image tag
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --tag=latest'

# Help and usage
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --help'
```

## 💎 What is PayRam?

PayRam is a **self-hosted cryptocurrency payment gateway** that enables businesses to accept crypto payments directly - **no middleman, no charge back, complete control**. Perfect for e-commerce, APIs, subscriptions, and any business wanting to embrace the future of payments.

## ✨ Key Features

- 🏛️ **Universal OS Support**: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux, Alpine, macOS
- 🐳 **Docker-Based**: Containerized deployment with automatic dependency management
- 🔐 **Security First**: Keys not stored on server for fund collection, AES-256 encryption, secure credential storage, SSL/TLS support
- 🌐 **Let's Encrypt Integration**: Automatic SSL certificate management
- 📊 **PostgreSQL Support**: External database integration with connection validation
- 🎨 **Enhanced UX**: Beautiful ASCII art banners and guided setup experience
- ⚡ **Quick Setup**: Complete gateway deployment in minutes

## 🚀 Quick Start

### Option 1: Direct Install (Recommended)
```bash
bash <(curl -fsSL https://payram.com/setup_payram.sh)
```

### Option 2: One-Line with Arguments
```bash
# If the script asks for root privileges, rerun with sudo at the beginning
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --update'
```

### Option 3: Download and Run
```bash
curl -O https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh
chmod +x setup_payram.sh
sudo ./setup_payram.sh
```

### Option 4: Clone Repository
```bash
git clone https://github.com/PayRam/payram-scripts.git
cd payram-scripts
sudo ./setup_payram.sh
```

## 🛠️ Advanced Usage

### Command Line Options

#### Local Script Execution:
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

#### One-Line Remote Execution:
```bash
# Fresh installation (default)
bash <(curl -fsSL https://payram.com/setup_payram.sh)

# Update existing installation
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --update'

# Testnet deployment  
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --testnet'

# Specific Docker image tag
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --tag=latest'

# Complete reset (removes all data)
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --reset'
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
- **Storage**: 5GB minimum, 10GB recommended
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

**One-Line Command Arguments**: Use process substitution so the interactive menu still works:
```bash
# Correct syntax for one-liner with arguments
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh) --reset'

# Incorrect (won't work)
curl -fsSL https://payram.com/setup_payram.sh | bash
```

**Permission Denied**: Rerun with `sudo` at the beginning
```bash
sudo bash -c 'bash <(curl -fsSL https://payram.com/setup_payram.sh)'
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


## 🤖 Agent / Headless CLI

> **For AI agents and automated workflows only.** These scripts are currently in testing and are not intended for regular client use.

If you are an AI agent (or building agent-based integrations), the following scripts provide a headless CLI for PayRam operations:

| Script | Purpose |
|--------|---------|
| `setup_payram_agents.sh` | Single agent entrypoint for install and headless operations |

### Quick Start (Agents)

```bash
# 1. Start PayRam locally (one-step flow)
./setup_payram_agents.sh

# 2. Sign in or set up
./setup_payram_agents.sh setup      # first time
./setup_payram_agents.sh signin     # subsequent times

# 3. Create a payment link
./setup_payram_agents.sh create-payment-link
```

For full agent documentation, see [`docs/PAYRAM_HEADLESS_AGENT.md`](docs/PAYRAM_HEADLESS_AGENT.md).

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
- **Documentation**: [Full setup guide](https://docs.payram.com)
- **Community**: [Discord server](https://discord.gg/payram)

---

**PayRam** - Empowering businesses with decentralized payment infrastructure. No middleman, no fees, complete control. 🚀💎
