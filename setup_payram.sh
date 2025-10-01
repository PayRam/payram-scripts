#!/bin/bash
set -euo pipefail

# =============================================================================
# PayRam Universal Setup Script v3
# =============================================================================
# A universal, cross-platform setup script for PayRam crypto payment gateway
# Supports: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch, Alpine, macOS
# =============================================================================

# --- GLOBAL SYSTEM INFORMATION ---
declare -g OS_FAMILY=""
declare -g OS_DISTRO=""
declare -g OS_VERSION=""
declare -g PACKAGE_MANAGER=""

# Initialize original user information early
if [[ -n "${SUDO_USER:-}" ]]; then
  ORIGINAL_USER="$SUDO_USER"
  ORIGINAL_HOME=$(eval echo "~$SUDO_USER")
else
  ORIGINAL_USER="$(whoami)"
  ORIGINAL_HOME="$HOME"
fi
declare -g SERVICE_MANAGER=""
declare -g INSTALL_METHOD=""
declare -g SCRIPT_DIR="${PWD}"
declare -g LOG_FILE="/tmp/payram-setup.log"
# Initialize directory variables with defaults
declare -g PAYRAM_INFO_DIR="${HOME}/.payraminfo"
declare -g PAYRAM_CORE_DIR="${HOME}/.payram-core"

# --- CORE UTILITY FUNCTIONS ---

# Enhanced logging with timestamps
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
  
  case "$level" in
    ERROR) print_color "red" "❌ $message" ;;
    WARN) print_color "yellow" "⚠️  $message" ;;
    INFO) print_color "blue" "ℹ️  $message" ;;
    SUCCESS) print_color "green" "✅ $message" ;;
    DEBUG) [[ "${DEBUG:-0}" == "1" ]] && print_color "gray" "🔍 $message" ;;
    *) echo "$message" ;;
  esac
}

# Progress indicator with improved spacing
show_progress() {
  local current=$1
  local total=$2
  local description="$3"
  local percent=$((current * 100 / total))
  local completed=$((current * 50 / total))
  local remaining=$((50 - completed))
  
  # Add space above progress bar
  echo
  
  printf "🚀 [%s%s] %d%% - %s" \
    "$(printf "%${completed}s" | tr ' ' '=')" \
    "$(printf "%${remaining}s" | tr ' ' '-')" \
    "$percent" \
    "$description"
    
  if [[ $current -eq $total ]]; then
    echo
    # Add space below when progress is complete
    echo
  else
    echo
    # Add space below for ongoing progress
    echo
  fi
}

# Check if script is run as root (with better UX)
check_privileges() {
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "This script requires root privileges for system modifications"
    echo
    print_color "yellow" "Please run one of the following:"
    print_color "blue" "  sudo $0 $*"
    print_color "blue" "  su -c '$0 $*'"
    echo
    exit 1
  fi
  
  # Update user info if running as root via sudo
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    ORIGINAL_USER="$SUDO_USER"
    ORIGINAL_HOME=$(eval echo "~$SUDO_USER")
  elif [[ "$(id -u)" -eq 0 ]]; then
    ORIGINAL_USER="root"
    ORIGINAL_HOME="/root"
  fi
  
  log "INFO" "Running as root, original user: $ORIGINAL_USER"
}

# --- SYSTEM DETECTION MODULE ---

# Comprehensive OS detection
detect_system_info() {
  log "INFO" "Detecting system information..."
  show_progress 1 10 "Analyzing operating system..."
  
  # Initialize variables
  OS_FAMILY=""
  OS_DISTRO=""
  OS_VERSION=""
  PACKAGE_MANAGER=""
  SERVICE_MANAGER=""
  INSTALL_METHOD=""
  
  # Detect OS type
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_FAMILY="macos"
    OS_DISTRO="macos"
    OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    PACKAGE_MANAGER="brew"
    SERVICE_MANAGER="launchctl"
    INSTALL_METHOD="homebrew"
    
  elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    OS_FAMILY="windows"
    OS_DISTRO="windows"
    PACKAGE_MANAGER="none"
    SERVICE_MANAGER="none"
    INSTALL_METHOD="manual"
    
  elif [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_DISTRO="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    
    # Determine OS family and capabilities
    case "$OS_DISTRO" in
      ubuntu|debian|mint|pop|elementary|kali)
        OS_FAMILY="debian"
        PACKAGE_MANAGER="apt"
        INSTALL_METHOD="official"
        ;;
      centos|rhel|rocky|almalinux|ol|amzn)
        OS_FAMILY="rhel"
        PACKAGE_MANAGER="yum"
        [[ -x "$(command -v dnf)" ]] && PACKAGE_MANAGER="dnf"
        INSTALL_METHOD="official"
        ;;
      fedora)
        OS_FAMILY="fedora"
        PACKAGE_MANAGER="dnf"
        INSTALL_METHOD="official"
        ;;
      opensuse*|sles)
        OS_FAMILY="opensuse"
        PACKAGE_MANAGER="zypper"
        INSTALL_METHOD="official"
        ;;
      arch|manjaro|endeavouros|artix)
        OS_FAMILY="arch"
        PACKAGE_MANAGER="pacman"
        INSTALL_METHOD="official"
        ;;
      alpine)
        OS_FAMILY="alpine"
        PACKAGE_MANAGER="apk"
        INSTALL_METHOD="official"
        ;;
      void)
        OS_FAMILY="void"
        PACKAGE_MANAGER="xbps"
        INSTALL_METHOD="fallback"
        ;;
      *)
        OS_FAMILY="linux"
        PACKAGE_MANAGER="unknown"
        INSTALL_METHOD="fallback"
        ;;
    esac
    
    # Detect service manager
    if [[ -x "$(command -v systemctl)" ]] && systemctl --version &>/dev/null; then
      SERVICE_MANAGER="systemd"
    elif [[ -x "$(command -v service)" ]]; then
      SERVICE_MANAGER="sysvinit"
    elif [[ -x "$(command -v rc-service)" ]]; then
      SERVICE_MANAGER="openrc"
    else
      SERVICE_MANAGER="unknown"
    fi
    
  else
    # Fallback detection
    if command -v uname &>/dev/null; then
      local uname_s=$(uname -s)
      case "$uname_s" in
        Linux) OS_FAMILY="linux"; INSTALL_METHOD="fallback" ;;
        Darwin) OS_FAMILY="macos"; INSTALL_METHOD="homebrew" ;;
        *) OS_FAMILY="unknown"; INSTALL_METHOD="manual" ;;
      esac
    else
      OS_FAMILY="unknown"
      INSTALL_METHOD="manual"
    fi
  fi
  
  show_progress 3 10 "System detection complete"
  
  # Display results
  log "SUCCESS" "System Detection Results:"
  log "INFO" "  OS Family: $OS_FAMILY"
  log "INFO" "  Distribution: $OS_DISTRO"
  log "INFO" "  Version: $OS_VERSION"
  log "INFO" "  Package Manager: $PACKAGE_MANAGER"
  log "INFO" "  Service Manager: $SERVICE_MANAGER"
  log "INFO" "  Install Method: $INSTALL_METHOD"
  
  # Validate compatibility
  validate_system_compatibility
}

validate_system_compatibility() {
  show_progress 4 10 "Validating system compatibility..."
  
  case "$OS_FAMILY" in
    macos|debian|rhel|fedora|arch|alpine)
      log "SUCCESS" "System is fully supported"
      ;;
    linux)
      log "WARN" "Limited support - will attempt fallback installation"
      ;;
    windows)
      log "ERROR" "Windows is not directly supported. Please use WSL2 or Docker Desktop"
      print_color "yellow" "Setup instructions:"
      print_color "blue" "  1. Install WSL2: https://docs.microsoft.com/en-us/windows/wsl/install"
      print_color "blue" "  2. Install Ubuntu in WSL2"
      print_color "blue" "  3. Run this script inside WSL2"
      exit 1
      ;;
    unknown)
      log "ERROR" "Unsupported operating system detected"
      print_color "yellow" "Please install Docker and PostgreSQL manually, then run:"
      print_color "blue" "  curl -fsSL https://get.docker.com | sh"
      exit 1
      ;;
  esac
}

# --- UNIVERSAL PACKAGE MANAGEMENT MODULE ---

# Universal package manager wrapper
pkg_update() {
  log "INFO" "Updating package lists for $PACKAGE_MANAGER..."
  
  case "$PACKAGE_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt update -qq
      ;;
    yum)
      yum check-update || true
      ;;
    dnf)
      dnf check-update || true
      ;;
    zypper)
      zypper refresh -q
      ;;
    pacman)
      pacman -Sy --noconfirm
      ;;
    apk)
      apk update -q
      ;;
    xbps)
      xbps-install -S
      ;;
    brew)
      su - "$ORIGINAL_USER" -c "brew update" || true
      ;;
    *)
      log "ERROR" "Unknown package manager: $PACKAGE_MANAGER"
      return 1
      ;;
  esac
}

pkg_install() {
  local packages=("$@")
  log "INFO" "Installing packages: ${packages[*]}"
  
  case "$PACKAGE_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    zypper)
      zypper install -y "${packages[@]}"
      ;;
    pacman)
      pacman -S --noconfirm "${packages[@]}"
      ;;
    apk)
      apk add "${packages[@]}"
      ;;
    xbps)
      xbps-install -y "${packages[@]}"
      ;;
    brew)
      for package in "${packages[@]}"; do
        su - "$ORIGINAL_USER" -c "brew install $package" || true
      done
      ;;
    *)
      log "ERROR" "Cannot install packages with $PACKAGE_MANAGER"
      return 1
      ;;
  esac
}

# Universal service management
service_start() {
  local service="$1"
  log "INFO" "Starting service: $service"
  
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl start "$service"
      ;;
    sysvinit)
      service "$service" start
      ;;
    openrc)
      rc-service "$service" start
      ;;
    launchctl)
      log "INFO" "Service management on macOS is automatic"
      ;;
    *)
      log "WARN" "Cannot start service $service with $SERVICE_MANAGER"
      ;;
  esac
}

service_enable() {
  local service="$1"
  log "INFO" "Enabling service: $service"
  
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl enable "$service"
      ;;
    openrc)
      rc-update add "$service" boot
      ;;
    sysvinit|launchctl)
      log "INFO" "Service auto-enable not required for $SERVICE_MANAGER"
      ;;
    *)
      log "WARN" "Cannot enable service $service with $SERVICE_MANAGER"
      ;;
  esac
}

# Get appropriate package names for different systems
get_docker_prerequisites() {
  case "$OS_FAMILY" in
    debian)
      echo "ca-certificates curl gnupg lsb-release apt-transport-https"
      ;;
    rhel|fedora)
      echo "yum-utils device-mapper-persistent-data lvm2"
      ;;
    arch)
      echo ""  # No prerequisites needed
      ;;
    alpine)
      echo ""  # No prerequisites needed
      ;;
    macos)
      echo ""  # Homebrew handles dependencies
      ;;
    *)
      echo ""
      ;;
  esac
}

get_postgresql_client_package() {
  case "$OS_FAMILY" in
    debian) echo "postgresql-client" ;;
    rhel|fedora) echo "postgresql" ;;
    arch) echo "postgresql" ;;
    alpine) echo "postgresql-client" ;;
    macos) echo "postgresql" ;;
    *) echo "postgresql-client" ;;
  esac
}

# --- DEPENDENCY MANAGEMENT MODULE ---

# Universal Docker installation
install_docker() {
  log "INFO" "Installing Docker using $INSTALL_METHOD method..."
  show_progress 5 10 "Installing Docker..."
  
  # Check if Docker is already installed and working
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    log "SUCCESS" "Docker is already installed and running"
    docker --version
    return 0
  fi
  
  case "$INSTALL_METHOD" in
    official)
      install_docker_official_repo
      ;;
    homebrew)
      install_docker_homebrew
      ;;
    fallback)
      install_docker_distribution_packages
      ;;
    manual)
      log "ERROR" "Manual Docker installation required for $OS_FAMILY"
      print_color "yellow" "Please visit: https://docs.docker.com/get-docker/"
      return 1
      ;;
  esac
  
  configure_docker_post_install
  verify_docker_installation
}

install_docker_official_repo() {
  local prereq_packages
  prereq_packages=$(get_docker_prerequisites)
  
  # Install prerequisites
  if [[ -n "$prereq_packages" ]]; then
    pkg_install $prereq_packages
  fi
  
  case "$OS_FAMILY" in
    debian)
      # Add Docker's official GPG key
      curl -fsSL "https://download.docker.com/linux/$OS_DISTRO/gpg" | \
        gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      
      # Add repository
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS_DISTRO $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
      
      pkg_update
      pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;
      
    rhel|fedora)
      # Add Docker repository
      local repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
      [[ "$OS_FAMILY" == "fedora" ]] && repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"

      if [[ "$PACKAGE_MANAGER" == "dnf" ]]; then
        pkg_install dnf-plugins-core
        dnf config-manager --add-repo "$repo_url"
      else
        # yum has config-manager via yum-utils
        $PACKAGE_MANAGER config-manager --add-repo "$repo_url"
      fi
      pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;
      
    arch)
      pkg_install docker docker-compose
      ;;
      
    alpine)
      pkg_install docker docker-compose
      ;;
  esac
}

install_docker_homebrew() {
  # Check if Homebrew is installed
  if ! su - "$ORIGINAL_USER" -c "command -v brew" &>/dev/null; then
    log "INFO" "Installing Homebrew first..."
    su - "$ORIGINAL_USER" -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  fi
  
  su - "$ORIGINAL_USER" -c "brew install --cask docker"
  
  log "INFO" "Please start Docker Desktop and wait for it to be ready..."
  wait_for_docker_macos
}

install_docker_distribution_packages() {
  log "WARN" "Falling back to distribution packages..."
  
  case "$OS_FAMILY" in
    debian) 
      pkg_install docker.io docker-compose
      ;;
    rhel|fedora) 
      pkg_install docker docker-compose
      ;;
    *) 
      log "ERROR" "No fallback package available for $OS_FAMILY"
      return 1
      ;;
  esac
}

configure_docker_post_install() {
  log "INFO" "Configuring Docker post-installation..."
  
  # Skip service management for macOS
  if [[ "$OS_FAMILY" != "macos" ]]; then
    service_start docker
    service_enable docker
    
    # Add original user to docker group
    if [[ "$ORIGINAL_USER" != "root" ]]; then
      usermod -aG docker "$ORIGINAL_USER"
      log "SUCCESS" "User $ORIGINAL_USER added to docker group"
      log "WARN" "Please log out and back in for group changes to take effect"
    fi
  fi
}

wait_for_docker_macos() {
  local max_attempts=30
  local attempt=0
  
  log "INFO" "Waiting for Docker Desktop to start..."
  while ! docker info &>/dev/null; do
    if [ $attempt -ge $max_attempts ]; then
      log "ERROR" "Docker Desktop did not start within 5 minutes"
      return 1
    fi
    sleep 10
    ((attempt++))
    echo -n "."
  done
  echo
  log "SUCCESS" "Docker Desktop is ready"
}

verify_docker_installation() {
  log "INFO" "Verifying Docker installation..."
  
  # Test Docker daemon
  if ! docker info &>/dev/null; then
    log "ERROR" "Docker is not running or not accessible"
    return 1
  fi
  
  # Test with hello-world
  if docker run --rm hello-world &>/dev/null; then
    log "SUCCESS" "Docker is working correctly"
    docker --version
    return 0
  else
    log "ERROR" "Docker test failed"
    return 1
  fi
}

# PostgreSQL client installation
install_postgresql_client() {
  show_progress 6 10 "Installing PostgreSQL client..."
  
  local pg_package
  pg_package=$(get_postgresql_client_package)
  
  if command -v psql &>/dev/null; then
    log "SUCCESS" "PostgreSQL client is already installed"
    psql --version
  else
    log "INFO" "Installing PostgreSQL client..."
    pkg_install "$pg_package"
    
    if command -v psql &>/dev/null; then
      log "SUCCESS" "PostgreSQL client installed successfully"
      psql --version
    else
      log "ERROR" "PostgreSQL client installation failed"
      return 1
    fi
  fi
}

# Main dependency installation orchestrator
install_all_dependencies() {
  log "INFO" "Installing system dependencies..."
  show_progress 4 10 "Preparing dependency installation..."
  
  # Update package lists
  pkg_update
  
  # Install Docker
  install_docker
  
  # Install PostgreSQL client
  install_postgresql_client
  
  show_progress 7 10 "All dependencies installed successfully"
  log "SUCCESS" "All system dependencies are ready"
}

# --- CONFIGURATION MANAGEMENT MODULE ---

# Configuration defaults
set_configuration_defaults() {
  DEFAULT_IMAGE_TAG="1.6.3"
  NETWORK_TYPE="mainnet"
  SERVER="PRODUCTION"
  IMAGE_TAG=""
  POSTGRES_SSLMODE="prefer"
  SSL_CERT_PATH=""
  SSL_MODE=""
  DOMAIN_NAME=""
  AES_KEY=""
  : "${NETWORK_CHOICE:=}"
}

# Initialize defaults early
set_configuration_defaults

# Dynamic directory paths based on original user
get_payram_directories() {
  if [[ "$ORIGINAL_USER" == "root" ]]; then
    PAYRAM_HOME="/root"
  else
    PAYRAM_HOME="$ORIGINAL_HOME"
  fi
  
  PAYRAM_INFO_DIR="$PAYRAM_HOME/.payraminfo"
  PAYRAM_CORE_DIR="$PAYRAM_HOME/.payram-core"
  
  log "INFO" "PayRam directories:"
  log "INFO" "  Home: $PAYRAM_HOME"
  log "INFO" "  Config: $PAYRAM_INFO_DIR"  
  log "INFO" "  Data: $PAYRAM_CORE_DIR"
  
  # Check disk space availability
  check_disk_space_requirements
}

# Check disk space requirements with user choice
check_disk_space_requirements() {
  local minimum_space_gb=5
  local recommended_space_gb=10
  local minimum_space_kb=$((minimum_space_gb * 1024 * 1024))
  local recommended_space_kb=$((recommended_space_gb * 1024 * 1024))
  
  log "INFO" "Checking disk space requirements..."
  
  # Get available space in KB for the target directory
  local available_space_kb
  if command -v df >/dev/null 2>&1; then
    # Try different approaches to get disk space
    available_space_kb=$(df "$PAYRAM_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$available_space_kb" || "$available_space_kb" == "0" ]]; then
      # Fallback to root filesystem if PAYRAM_HOME fails
      available_space_kb=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
    fi
    if [[ -z "$available_space_kb" ]]; then
      available_space_kb=0
    fi
    local available_space_gb=$((available_space_kb / 1024 / 1024))
    
    echo
    print_color "blue" "💾 Disk Space Requirements:"
    print_color "gray" "  • Minimum: ${minimum_space_gb}GB required"
    print_color "gray" "  • Recommended: ${recommended_space_gb}GB for optimal performance"
    print_color "gray" "  • Available: ${available_space_gb}GB"
    
    if [[ $available_space_kb -lt $minimum_space_kb ]]; then
      print_color "red" "  ❌ Insufficient disk space!"
      echo
      print_color "red" "❌ CRITICAL: You have ${available_space_gb}GB available, but ${minimum_space_gb}GB minimum is required."
      print_color "yellow" "   PayRam requires space for:"
      print_color "gray" "   • Docker images and containers (~3GB)"
      print_color "gray" "   • Database storage (~1GB)"
      print_color "gray" "   • Logs and temporary files (~1GB)"
      echo
      print_color "blue" "💡 Note: You can increase disk space after installation if needed."
      echo
      
      while true; do
        print_color "yellow" "Do you want to continue anyway? (y/N): "
        read -r response
        case $response in
          [Yy]|[Yy][Ee][Ss])
            print_color "yellow" "⚠️  Proceeding with insufficient disk space - installation may fail..."
            echo
            return 0
            ;;
          [Nn]|[Nn][Oo]|"")
            print_color "red" "Installation cancelled. Please free up disk space and try again."
            echo
            print_color "blue" "💡 Tips to free up space:"
            print_color "gray" "   • Remove unused Docker images: docker system prune -a"
            print_color "gray" "   • Clean package cache: sudo apt clean (Ubuntu/Debian)"
            print_color "gray" "   • Remove old log files: sudo journalctl --vacuum-time=7d"
            print_color "gray" "   • Use a different installation directory with more space"
            echo
            return 1
            ;;
          *)
            print_color "red" "Please answer 'y' for yes or 'n' for no."
            ;;
        esac
      done
    elif [[ $available_space_kb -lt $recommended_space_kb ]]; then
      print_color "yellow" "  ⚠️  Limited disk space available"
      echo
      print_color "yellow" "⚠️  WARNING: You have ${available_space_gb}GB available. ${recommended_space_gb}GB is recommended for optimal performance."
      print_color "yellow" "   With ${available_space_gb}GB you may experience:"
      print_color "gray" "   • Slower performance during heavy usage"
      print_color "gray" "   • Limited log retention"
      print_color "gray" "   • Potential space issues with large transactions"
      echo
      print_color "blue" "💡 Note: Installation will proceed but monitor disk usage closely."
      print_color "yellow" "⚠️  Continuing with limited disk space..."
      echo
      return 0
    else
      print_color "green" "  ✅ Sufficient disk space available"
    fi
    echo
  else
    print_color "yellow" "⚠️  Could not check disk space. Ensure ${minimum_space_gb}GB minimum (${recommended_space_gb}GB recommended) available"
    echo
  fi
  
  return 0
}

# Non-interactive disk space check for validation purposes
check_disk_space_requirements_silent() {
  local minimum_space_gb=5
  local minimum_space_kb=$((minimum_space_gb * 1024 * 1024))
  
  # Get available space in KB for the target directory
  local available_space_kb
  if command -v df >/dev/null 2>&1; then
    # Try different approaches to get disk space
    available_space_kb=$(df "$PAYRAM_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$available_space_kb" || "$available_space_kb" == "0" ]]; then
      # Fallback to root filesystem if PAYRAM_HOME fails
      available_space_kb=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
    fi
    if [[ -z "$available_space_kb" ]]; then
      available_space_kb=0
    fi
    
    if [[ $available_space_kb -lt $minimum_space_kb ]]; then
      return 1  # Insufficient space
    else
      return 0  # Sufficient space
    fi
  else
    return 0  # Can't check, assume OK
  fi
}

# Enhanced database configuration with better UX
configure_database() {
  show_progress 8 10 "Configuring database connection..."
  
  echo
  print_color "bold" "📊 Database Configuration"
  echo
  print_color "yellow" "PayRam stores business data in PostgreSQL:"
  print_color "gray" "  • 📈 Transaction history and status"
  print_color "gray" "  • ⚙️  System configurations and settings"
  print_color "gray" "  • 👥 Merchant accounts and API credentials"
  print_color "gray" "  • 📊 Analytics and reporting data"
  echo
  print_color "green" "� Security: Private keys are NOT stored in database"
  print_color "gray" "  • Cold wallet keys: Never on server"
  print_color "gray" "  • Deposit keys: Not stored, smart sweep used"
  print_color "gray" "  • Hot wallet keys: Encrypted separately with AES-256"
  echo
  
  print_color "blue" "1) External PostgreSQL Database (Recommended for Production)"
  print_color "gray" "   • Your database runs on a separate server or cloud service"
  print_color "gray" "   • Better uptime, professional backups, and easy scaling"
  print_color "gray" "   • Ideal for live businesses and production environments"
  print_color "gray" "   • Requires: Existing PostgreSQL server with credentials"
  echo
  
  print_color "blue" "2) Containerized PostgreSQL (Quick Setup for Development)"
  print_color "gray" "   • Database runs inside a Docker container on this server"
  print_color "gray" "   • Fast setup with automatic configuration"
  print_color "gray" "   • ⚠️  Risk: Container loss = data loss (backup regularly!)"
  print_color "gray" "   • Best for: Testing, development, and small-scale usage"
  echo
  
  while true; do
    read -p "Select option (1-2): " choice
    case $choice in
      1)
        configure_external_database
        break
        ;;
      2)
        configure_internal_database
        break
        ;;
      *)
        print_color "red" "Invalid option. Please select 1 or 2."
        ;;
    esac
  done
}

configure_external_database() {
  echo
  print_color "bold" "🔗 External PostgreSQL Configuration"
  print_color "yellow" "You'll need an existing PostgreSQL database with:"
  print_color "gray" "  • Database server accessible from this machine"
  print_color "gray" "  • Database user with CREATE, INSERT, UPDATE, DELETE permissions"
  print_color "gray" "  • Network connectivity (check firewalls if connection fails)"
  echo
  
  while true; do
    read -p "Database Host [localhost]: " DB_HOST
    DB_HOST=${DB_HOST:-localhost}
    
    read -p "Database Port [5432]: " DB_PORT
    DB_PORT=${DB_PORT:-5432}
    
    read -p "Database Name: " DB_NAME
    while [[ -z "$DB_NAME" ]]; do
      print_color "red" "Database name cannot be empty"
      read -p "Database Name: " DB_NAME
    done
    
    read -p "Database Username: " DB_USER
    while [[ -z "$DB_USER" ]]; do
      print_color "red" "Database username cannot be empty"
      read -p "Database Username: " DB_USER
    done
    
    read -s -p "Database Password: " DB_PASSWORD
    echo
    while [[ -z "$DB_PASSWORD" ]]; do
      print_color "red" "Database password cannot be empty"
      read -s -p "Database Password: " DB_PASSWORD
      echo
    done
    
    print_color "blue" "🔍 Testing database connection..."
    if test_postgres_connection; then
      print_color "green" "✅ Database connection successful!"
      print_color "gray" "PayRam will be able to connect to your database"
      break
    else
      print_color "red" "❌ Database connection failed"
      print_color "yellow" "Common issues:"
      print_color "gray" "  • Check if PostgreSQL is running on the host"
      print_color "gray" "  • Verify database name exists"
      print_color "gray" "  • Confirm username/password are correct"
      print_color "gray" "  • Check firewall settings (port $DB_PORT)"
      echo
      read -p "Would you like to try again? (y/N): " retry
      [[ ! "$retry" =~ ^[Yy]$ ]] && exit 1
    fi
  done
}

configure_internal_database() {
  echo
  print_color "bold" "🐳 Containerized PostgreSQL Setup"
  print_color "green" "✅ Quick automatic configuration selected"
  echo
  print_color "blue" "📊 Storage Configuration:"
  print_color "gray" "  • PostgreSQL runs in Docker container"
  print_color "gray" "  • Data stored in: $PAYRAM_HOME/.payram-core/db/postgres/"
  print_color "gray" "  • Initial size: ~500MB, grows with transaction volume"
  print_color "gray" "  • Logs stored in: $PAYRAM_HOME/.payram-core/log/"
  print_color "gray" "  • Default credentials: payram/payram123"
  print_color "gray" "  • Container name: payram (includes database)"
  echo
  
  print_color "yellow" "🔐 Hot Wallet Key Storage:"
  print_color "gray" "  • Hot wallet private keys stored in database (encrypted)"
  print_color "gray" "  • Encryption: AES-256 with key stored separately"
  print_color "gray" "  • Database backup + AES key backup both required"
  echo
  
  print_color "yellow" "⚠️  Important for Production:"
  print_color "red" "  • Regular backups are YOUR responsibility"
  print_color "red" "  • Container removal = complete data loss"
  print_color "red" "  • Backup BOTH database AND AES encryption key"
  print_color "red" "  • Consider external database for critical operations"
  echo
  
  print_color "blue" "💾 Complete Backup Strategy:"
  print_color "gray" "  # 1. Database backup"
  print_color "gray" "  docker exec payram pg_dump -U payram payram > backup.sql"
  print_color "gray" "  # 2. AES key backup (CRITICAL)"
  print_color "gray" "  tar -czf payram-keys-backup.tar.gz ~/.payraminfo/aes"
  print_color "gray" "  # 3. Configuration backup"
  print_color "gray" "  cp ~/.payraminfo/config.env config-backup.env"
  echo
  
  DB_HOST="localhost"
  DB_PORT="5432"
  DB_NAME="payram"
  DB_USER="payram"
  DB_PASSWORD="payram123"
  
  print_color "green" "✅ Internal database configured successfully"
}

# Enhanced SSL configuration
configure_ssl() {
  show_progress 9 10 "Configuring SSL certificates..."
  
  echo
  print_color "bold" "🔒 SSL Certificate Setup"
  print_color "yellow" "HTTPS is essential for PayRam's security - it protects:"
  print_color "gray" "  • API communications and payment data"
  print_color "gray" "  • Dashboard access and authentication"
  print_color "gray" "  • Customer payment pages and transactions"
  echo
  
  print_color "blue" "1) Let's Encrypt - Auto-Generate Free SSL (2 minutes)"
  print_color "gray" "   • Automatic certificate generation and installation"
  print_color "gray" "   • Free SSL certificates trusted by all browsers"
  print_color "gray" "   • Auto-renewal every 90 days (with cron job)"
  print_color "gray" "   • ✅ Perfect for production and development"
  print_color "gray" "   • Requires: Domain name pointing to this server"
  echo
  
  print_color "blue" "2) Custom Certificates - Upload Your Own SSL"
  print_color "gray" "   • Upload your own commercial or internal certificates"
  print_color "gray" "   • Supports: Wildcard, EV, custom CA certificates"
  print_color "gray" "   • Files needed: fullchain.pem + privkey.pem"
  print_color "gray" "   • ✅ Ideal for enterprise and scaled production"
  echo
  
  print_color "blue" "3) External SSL - Use Cloud/Proxy Services (Often Easiest!)"
  print_color "gray" "   • Cloudflare SSL (5-min setup, free tier available)"
  print_color "gray" "   • AWS ALB, Google LB, Azure Gateway, Nginx, Apache"
  print_color "gray" "   • PayRam runs HTTP behind your SSL termination"
  print_color "gray" "   • ✅ Great for cloud deployments and existing infrastructure"
  echo
  
  while true; do
    read -p "Select option (1-3): " choice
    case $choice in
      1)
        configure_ssl_letsencrypt
        break
        ;;
      2)
        configure_ssl_custom
        break
        ;;
      3)
        configure_ssl_external
        break
        ;;
      *)
        print_color "red" "Invalid option. Please select 1, 2, or 3."
        ;;
    esac
  done
}

configure_ssl_letsencrypt() {
  echo
  print_color "bold" "🆓 Let's Encrypt SSL Setup"
  print_color "yellow" "This will install Certbot and generate free SSL certificates."
  echo
  print_color "blue" "Requirements:"
  print_color "gray" "  • Domain name must point to this server's public IP"
  print_color "gray" "  • Ports 80 and 443 must be accessible from internet"
  print_color "gray" "  • No other web server using these ports"
  echo
  
  # Domain input with validation
  while true; do
    read -p "Enter your domain name (e.g., payram.example.com): " DOMAIN_NAME
    
    if [[ -z "$DOMAIN_NAME" ]]; then
      print_color "red" "Domain name cannot be empty"
      continue
    fi
    
    # Basic domain validation
    if [[ ! "$DOMAIN_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
      print_color "red" "Invalid domain format. Please use format: payram.example.com"
      continue
    fi
    
    break
  done
  
  # Email for Let's Encrypt notifications
  while true; do
    read -p "Enter email for SSL notifications (certificate expiry alerts): " LE_EMAIL
    
    if [[ -z "$LE_EMAIL" ]]; then
      print_color "red" "Email cannot be empty"
      continue
    fi
    
    # Basic email validation
    if [[ ! "$LE_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      print_color "red" "Invalid email format"
      continue
    fi
    
    break
  done
  
  echo
  print_color "yellow" "⚠️  Before proceeding:"
  print_color "gray" "  • Ensure $DOMAIN_NAME points to this server"
  print_color "gray" "  • Stop any web servers on ports 80/443"
  print_color "gray" "  • This process takes 1-3 minutes"
  echo
  
  read -p "Ready to generate SSL certificate? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_color "yellow" "SSL setup cancelled. Continuing without SSL..."
    SSL_CERT_PATH=""
    return 0
  fi
  
  # Install Certbot
  print_color "blue" "📦 Installing Certbot (Let's Encrypt client)..."
  if ! install_certbot; then
    print_color "red" "Failed to install Certbot. Continuing without SSL..."
    SSL_CERT_PATH=""
    return 1
  fi
  
  # Generate certificate
  print_color "blue" "🔐 Generating SSL certificate for $DOMAIN_NAME..."
  if generate_letsencrypt_cert "$DOMAIN_NAME" "$LE_EMAIL"; then
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN_NAME"
    SSL_MODE="letsencrypt"
    
    print_color "green" "✅ SSL certificate generated successfully!"
    print_color "gray" "  Certificate: $SSL_CERT_PATH/fullchain.pem"
    print_color "gray" "  Private Key: $SSL_CERT_PATH/privkey.pem"
    print_color "gray" "  Expires: 90 days (auto-renewal recommended)"
    echo
    
    # Setup auto-renewal
    setup_certbot_renewal "$DOMAIN_NAME"
    
  else
    print_color "red" "❌ Failed to generate SSL certificate"
    print_color "yellow" "Common issues:"
    print_color "gray" "  • Domain doesn't point to this server"
    print_color "gray" "  • Firewall blocking ports 80/443"
    print_color "gray" "  • Another web server is running"
    echo
    
    read -p "Continue without SSL? (y/N): " continue_without_ssl
    if [[ "$continue_without_ssl" =~ ^[Yy]$ ]]; then
      SSL_CERT_PATH=""
    else
      print_color "yellow" "Please fix the issues and run the script again"
      exit 1
    fi
  fi
}

configure_ssl_custom() {
  echo
  print_color "bold" "📁 Custom SSL Certificate Setup"
  print_color "yellow" "Upload your own SSL certificates (commercial, wildcard, or internal CA)."
  echo
  print_color "blue" "Required files in certificate directory:"
  print_color "gray" "  • fullchain.pem - Complete certificate chain"
  print_color "gray" "  • privkey.pem - Private key file"
  echo
  print_color "blue" "Common certificate locations:"
  print_color "gray" "  • Let's Encrypt: /etc/letsencrypt/live/yourdomain.com/"
  print_color "gray" "  • Custom location: /etc/ssl/certs/payram/"
  print_color "gray" "  • Uploaded files: /opt/ssl-certificates/"
  echo
  
  while true; do
    read -p "SSL certificate directory path: " SSL_CERT_PATH
    
    if [[ -z "$SSL_CERT_PATH" ]]; then
      print_color "red" "SSL certificate path cannot be empty"
      continue
    fi
    
    # Expand tilde to home directory
    SSL_CERT_PATH="${SSL_CERT_PATH/#\~/$HOME}"
    
    if [[ ! -d "$SSL_CERT_PATH" ]]; then
      print_color "red" "Directory '$SSL_CERT_PATH' does not exist"
      print_color "yellow" "Create the directory first and copy your certificate files there"
      continue
    fi
    
    if [[ ! -r "$SSL_CERT_PATH" ]]; then
      print_color "red" "Directory '$SSL_CERT_PATH' is not readable"
      continue
    fi
    
    # Check for required certificate files
    local required_files=("fullchain.pem" "privkey.pem")
    local missing_files=()
    
    for file in "${required_files[@]}"; do
      if [[ ! -f "$SSL_CERT_PATH/$file" ]]; then
        missing_files+=("$file")
      elif [[ ! -r "$SSL_CERT_PATH/$file" ]]; then
        missing_files+=("$file (not readable)")
      fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
      print_color "red" "Missing or unreadable certificate files: ${missing_files[*]}"
      echo
      print_color "yellow" "How to fix:"
      print_color "gray" "  1. Copy your certificate files to: $SSL_CERT_PATH"
      print_color "gray" "  2. Rename certificate to: fullchain.pem"
      print_color "gray" "  3. Rename private key to: privkey.pem"
      print_color "gray" "  4. Set proper permissions: chmod 644 fullchain.pem && chmod 600 privkey.pem"
      echo
      
      read -p "Would you like to try a different path? (y/N): " retry
      if [[ ! "$retry" =~ ^[Yy]$ ]]; then
        SSL_CERT_PATH=""
        print_color "yellow" "Continuing without SSL certificates..."
        return 0
      fi
      continue
    fi
    
    # Validate certificate
    if validate_ssl_certificate "$SSL_CERT_PATH"; then
      SSL_MODE="custom"
      print_color "green" "✅ SSL certificates validated successfully!"
      print_color "gray" "  Certificate: $SSL_CERT_PATH/fullchain.pem"
      print_color "gray" "  Private Key: $SSL_CERT_PATH/privkey.pem"
      break
    else
      print_color "red" "❌ Certificate validation failed"
      read -p "Continue anyway? (y/N): " force_continue
      if [[ "$force_continue" =~ ^[Yy]$ ]]; then
        print_color "yellow" "⚠️  Using certificates without validation"
        break
      fi
    fi
  done
}

configure_ssl_external() {
  echo
  print_color "bold" "🌐 External SSL Management"
  print_color "yellow" "Configure SSL outside PayRam - often the easiest option for cloud deployments!"
  echo
  print_color "green" "🚀 EASIEST OPTION - Cloudflare (5-minute setup):"
  print_color "gray" "  1. Sign up at cloudflare.com (free tier available)"
  print_color "gray" "  2. Add your domain and change nameservers"
  print_color "gray" "  3. Enable 'Flexible' or 'Full' SSL mode"
  print_color "gray" "  4. Create A record: yourdomain.com → your-server-ip"
  print_color "gray" "  5. Done! Cloudflare handles SSL automatically"
  echo
  
  print_color "blue" "☁️  Other Cloud SSL Services:"
  print_color "gray" "  • AWS Application Load Balancer + Certificate Manager"
  print_color "gray" "  • Google Cloud Load Balancer + SSL certificates"
  print_color "gray" "  • Azure Application Gateway + Key Vault"
  echo
  
  print_color "yellow" "🔄 Self-Hosted Reverse Proxy Solutions:"
  print_color "gray" "  • Nginx with SSL termination"
  print_color "gray" "  • Apache HTTP Server with mod_ssl"
  print_color "gray" "  • Traefik with automatic Let's Encrypt"
  print_color "gray" "  • HAProxy with SSL offloading"
  echo
  
  print_color "yellow" "🛡️  Premium Security Services:"
  print_color "gray" "  • Sucuri Website Firewall"
  print_color "gray" "  • Incapsula DDoS Protection"
  print_color "gray" "  • AWS WAF with CloudFront"
  echo
  
  print_color "blue" "Setup Configuration:"
  print_color "gray" "  • PayRam will run HTTP-only (no SSL certificates needed)"
  print_color "gray" "  • Your external service handles HTTPS and forwards to PayRam"
  print_color "gray" "  • PayRam API accessible at: http://localhost:8080"
  print_color "gray" "  • PayRam Dashboard at: http://localhost"
  echo
  
  print_color "yellow" "⚠️  Important Notes:"
  print_color "red" "  • Ensure your proxy forwards real client IPs"
  print_color "red" "  • Configure proper headers: X-Forwarded-For, X-Real-IP"
  print_color "red" "  • Set X-Forwarded-Proto: https for HTTPS detection"
  print_color "red" "  • Restrict direct access to PayRam ports (firewall rules)"
  echo
  
  read -p "Do you want to continue with external SSL management? (y/N): " confirm_external
  if [[ "$confirm_external" =~ ^[Yy]$ ]]; then
    SSL_CERT_PATH=""
    SSL_MODE="external"
    print_color "green" "✅ External SSL management selected"
    print_color "blue" "Next steps after PayRam installation:"
    print_color "gray" "  1. Configure your reverse proxy to forward to:"
    print_color "gray" "     - API: http://this-server:8080"
    print_color "gray" "     - Dashboard: http://this-server:80"
    print_color "gray" "  2. Test HTTPS connectivity through your proxy"
    print_color "gray" "  3. Configure firewall to block direct access"
    echo
  else
    print_color "yellow" "Returning to SSL configuration menu..."
    configure_ssl
  fi
}

# Supporting functions for SSL configuration

# Install Certbot based on OS
install_certbot() {
  log "INFO" "Installing Certbot for Let's Encrypt..."
  
  case "$OS_FAMILY" in
    debian)
      pkg_install snapd
      snap install --classic certbot
      ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
      ;;
    rhel|fedora)
      pkg_install certbot
      ;;
    arch)
      pkg_install certbot
      ;;
    alpine)
      pkg_install certbot
      ;;
    macos)
      su - "$ORIGINAL_USER" -c "brew install certbot"
      ;;
    *)
      print_color "red" "Certbot installation not supported on $OS_FAMILY"
      return 1
      ;;
  esac
  
  # Verify installation
  if command -v certbot &>/dev/null; then
    log "SUCCESS" "Certbot installed successfully"
    certbot --version
    return 0
  else
    log "ERROR" "Certbot installation failed"
    return 1
  fi
}

# Generate Let's Encrypt certificate
generate_letsencrypt_cert() {
  local domain="$1"
  local email="$2"
  
  log "INFO" "Generating Let's Encrypt certificate for $domain..."
  
  # Stop any services that might be using port 80
  if command -v systemctl &>/dev/null; then
    systemctl stop apache2 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop httpd 2>/dev/null || true
  fi
  
  # Generate certificate using standalone mode
  if certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "$email" \
    --domains "$domain" \
    --expand \
    --keep-until-expiring; then
    
    log "SUCCESS" "Certificate generated for $domain"
    return 0
  else
    log "ERROR" "Failed to generate certificate for $domain"
    return 1
  fi
}

# Setup automatic renewal
setup_certbot_renewal() {
  local domain="$1"
  
  log "INFO" "Setting up automatic certificate renewal..."
  
  # Create renewal script
  cat > /etc/cron.d/payram-certbot-renewal << EOF
# PayRam Let's Encrypt Certificate Renewal
# Runs twice daily at random minutes to avoid load spikes
$(shuf -i 0-59 -n 1) $(shuf -i 0-23 -n 1) * * * root certbot renew --quiet --deploy-hook "docker restart payram 2>/dev/null || true"
EOF
  
  chmod 644 /etc/cron.d/payram-certbot-renewal
  
  # Test renewal (dry run)
  if certbot renew --dry-run --quiet; then
    print_color "green" "✅ Auto-renewal configured and tested successfully"
    print_color "gray" "  • Renewal runs twice daily automatically"
    print_color "gray" "  • PayRam will restart after certificate updates"
    print_color "gray" "  • Check renewal status: certbot certificates"
  else
    print_color "yellow" "⚠️  Auto-renewal configured but test failed"
    print_color "gray" "  • Manual renewal: certbot renew"
  fi
}

# Validate SSL certificate
validate_ssl_certificate() {
  local cert_path="$1"
  local cert_file="$cert_path/fullchain.pem"
  local key_file="$cert_path/privkey.pem"
  
  log "INFO" "Validating SSL certificate..."
  
  # Check if openssl is available
  if ! command -v openssl &>/dev/null; then
    log "WARN" "OpenSSL not available for certificate validation"
    return 1
  fi

  # Validate certificate format
  if ! openssl x509 -in "$cert_file" -noout -text &>/dev/null; then
    log "ERROR" "Invalid certificate format"
    return 1
  fi

  # Validate private key format (supports RSA and EC)
  if ! openssl pkey -in "$key_file" -noout -text &>/dev/null 2>&1; then
    log "ERROR" "Invalid private key format"
    return 1
  fi

  # Check if certificate and private key match (by public key digest)
  local cert_pubkey_digest
  local key_pubkey_digest
  cert_pubkey_digest="$(openssl x509 -in "$cert_file" -noout -pubkey 2>/dev/null \
                        | openssl pkey -pubin -outform pem 2>/dev/null \
                        | openssl dgst -sha256 2>/dev/null)"
  key_pubkey_digest="$(openssl pkey -in "$key_file" -pubout -outform pem 2>/dev/null \
                      | openssl dgst -sha256 2>/dev/null)"
  if [[ -z "$cert_pubkey_digest" || -z "$key_pubkey_digest" || \
        "$cert_pubkey_digest" != "$key_pubkey_digest" ]]; then
    log "ERROR" "Certificate and private key do not match"
    return 1
  fi

  # Check certificate expiration using openssl (portable)
  if ! openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
    log "ERROR" "Certificate has expired"
    return 1
  fi
  # Warn if expiring within 30 days
  if ! openssl x509 -in "$cert_file" -noout -checkend $((30*24*3600)) >/dev/null 2>&1; then
    print_color "yellow" "⚠️  Certificate expires within 30 days"
  else
    print_color "green" "✅ Certificate validity is more than 30 days"
  fi

  log "SUCCESS" "SSL certificate validation passed"
  return 0
}

test_postgres_connection() {
  log "INFO" "Testing database connection..."
  
  # Create temporary .pgpass file for secure authentication
  local pgpass_file=$(mktemp)
  echo "$DB_HOST:$DB_PORT:$DB_NAME:$DB_USER:$DB_PASSWORD" > "$pgpass_file"
  chmod 600 "$pgpass_file"
  
  # Test connection
  if PGPASSFILE="$pgpass_file" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "\q" &>/dev/null; then
    rm -f "$pgpass_file"
    return 0
  else
    rm -f "$pgpass_file"
    return 1
  fi
}

# AES key generation for hot wallet encryption
generate_aes_key() {
  echo
  print_color "bold" "🔐 Hot Wallet Encryption Setup"
  print_color "yellow" "PayRam follows a 'minimal key storage' security philosophy:"
  print_color "gray" "  • 🔒 Cold wallets: Keys NEVER stored on server (maximum security)"
  print_color "gray" "  • 💰 Deposit wallets: Keys NOT stored, uses smart sweep technology"
  print_color "gray" "  • 🔥 Hot wallet: ONLY wallet with keys on server (for withdrawals)"
  echo
  
  print_color "blue" "Hot Wallet Purpose & Security:"
  print_color "gray" "  • Enables automatic withdrawals and operations"
  print_color "gray" "  • Private keys encrypted with AES-256 (military-grade)"
  print_color "gray" "  • Keys stored locally, never transmitted"
  echo
  
  print_color "yellow" "⚠️  Hot Wallet Security Guidelines:"
  print_color "red" "  • Store MINIMAL funds only (recommended: <\$1,000 equivalent)"
  print_color "red" "  • Hot wallet = convenient but higher risk"
  print_color "red" "  • Most funds should stay in cold storage"
  print_color "red" "  • Regular withdrawal of excess funds to cold wallet"
  echo
  
  read -p "Press [Enter] to generate AES-256 encryption key for hot wallet..."
  
  print_color "cyan" "🔮 Summoning cryptographic magic..."
  print_color "yellow" "⚡ Generating quantum-secure randomness..."
  print_color "blue" "🔐 Forging your AES-256 encryption key..."
  
  log "INFO" "Generating secure AES-256 encryption key for hot wallet protection..."
  AES_KEY=$(openssl rand -hex 32)
  
  # Save key for legacy compatibility
  local aes_dir="$PAYRAM_INFO_DIR/aes"
  mkdir -p "$aes_dir"
  local key_file="$aes_dir/$AES_KEY"
  echo "AES_KEY=$AES_KEY" > "$key_file"
  chmod 600 "$key_file"
  
  # Change ownership to original user
  if [[ "$ORIGINAL_USER" != "root" ]]; then
    chown -R "$ORIGINAL_USER:$(id -gn "$ORIGINAL_USER")" "$PAYRAM_INFO_DIR"
  fi
  
  print_color "green" "✅ Hot wallet encryption key generated successfully!"
  print_color "blue" "   📁 Key location: $PAYRAM_INFO_DIR/aes/ (permissions: 600)"
  print_color "blue" "   🔐 Key strength: 256-bit AES encryption"
  echo
  
  print_color "yellow" "� Critical Information:"
  print_color "gray" "  • Hot wallet private keys are stored in database (encrypted)"
  print_color "gray" "  • This AES key decrypts those hot wallet keys"
  print_color "gray" "  • Without this key: hot wallet becomes permanently inaccessible"
  print_color "gray" "  • Database backup alone is insufficient - AES key required"
  echo
  
  print_color "red" "🚨 CRITICAL BACKUP REQUIREMENT:"
  print_color "red" "  • IMMEDIATELY backup this AES key to secure offline storage"
  print_color "red" "  • Store in multiple secure locations (encrypted USB, safe, etc.)"
  print_color "red" "  • Never store only on this server - hardware failure = key loss"
  print_color "red" "  • Test backup restoration before processing real transactions"
  echo
  
  print_color "blue" "💾 Backup Commands:"
  print_color "gray" "  # Copy AES key directory to secure location"
  print_color "gray" "  cp -r $PAYRAM_INFO_DIR/aes /path/to/secure/backup/"
  print_color "gray" "  # Or backup entire config directory"
  print_color "gray" "  tar -czf payram-config-backup.tar.gz $PAYRAM_INFO_DIR"
  echo
  
  print_color "green" "📈 Best Practices:"
  print_color "gray" "  • Keep hot wallet balance under \$1,000"
  print_color "gray" "  • Monitor hot wallet activity regularly"
  print_color "gray" "  • Set up automatic cold storage transfers"
  print_color "gray" "  • Test key backup/restore procedures quarterly"
}

# Configuration file management
save_configuration() {
  local config_file="$PAYRAM_INFO_DIR/config.env"
  
  log "INFO" "Saving configuration to $config_file..."
  
  # Create directory with proper permissions
  mkdir -p "$PAYRAM_INFO_DIR"
  
  # Write configuration with restrictive permissions
  umask 077
  cat > "$config_file" << EOL
# PayRam Configuration - Generated $(date)
# Do not edit manually unless you know what you are doing

# Container Configuration
IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
NETWORK_TYPE="${NETWORK_TYPE:-mainnet}"
SERVER="${SERVER:-PRODUCTION}"
AES_KEY="${AES_KEY:-}"

# Database Configuration
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-payram}"
DB_USER="${DB_USER:-payram}"
DB_PASSWORD="${DB_PASSWORD:-}"
POSTGRES_SSLMODE="${POSTGRES_SSLMODE:-prefer}"

# SSL Configuration
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_MODE="${SSL_MODE:-}"

# System Information
OS_FAMILY="$OS_FAMILY"
OS_DISTRO="$OS_DISTRO"
ORIGINAL_USER="$ORIGINAL_USER"
PAYRAM_HOME="$PAYRAM_HOME"
EOL
  
  # Set proper ownership and permissions
  chmod 600 "$config_file"
  if [[ "$ORIGINAL_USER" != "root" ]]; then
    chown "$ORIGINAL_USER:$(id -gn "$ORIGINAL_USER")" "$config_file"
  fi
  
  log "SUCCESS" "Configuration saved with secure permissions (600)"
}

load_configuration() {
  local config_file="$PAYRAM_INFO_DIR/config.env"
  
  if [[ ! -f "$config_file" ]]; then
    log "ERROR" "Configuration file not found: $config_file"
    return 1
  fi
  
  log "INFO" "Loading configuration from $config_file..."
  source "$config_file"
  
  # Validate required variables
  local required_vars=("IMAGE_TAG" "DB_HOST" "DB_PORT" "DB_NAME" "DB_USER" "DB_PASSWORD")
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      log "ERROR" "Required configuration variable $var is missing or empty"
      return 1
    fi
  done
  
  log "SUCCESS" "Configuration loaded successfully"
  return 0
}

# --- CONTAINER LIFECYCLE MANAGEMENT ---

# Docker image validation
validate_docker_tag() {
  local tag_to_check="$1"
  log "INFO" "Validating Docker tag: $tag_to_check..."
  
  # Use Docker Hub API to check if tag exists
  if curl -s "https://registry.hub.docker.com/v2/repositories/payramapp/payram/tags/$tag_to_check/" | grep -q '"name"' 2>/dev/null; then
    log "SUCCESS" "Docker tag '$tag_to_check' is valid"
    return 0
  else
    log "ERROR" "Docker tag '$tag_to_check' not found in repository"
    return 1
  fi
}

# Container deployment
deploy_payram_container() {
  show_progress 10 10 "Deploying PayRam container..."
  
  # Generate AES key if not exists
  if [[ -z "$AES_KEY" ]]; then
    generate_aes_key
  fi
  
  # Validate Docker tag
  if ! validate_docker_tag "${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"; then
    log "ERROR" "Cannot proceed with invalid Docker tag"
    return 1
  fi
  
  # Check for existing container
  if docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" | grep -q "payram"; then
    log "WARN" "PayRam container is already running"
    docker ps --filter "name=payram"
    return 0
  fi
  
  # Remove stopped container if exists
  if docker ps -a --filter "name=^payram$" --format "{{.Names}}" | grep -q "payram"; then
    log "INFO" "Removing existing stopped PayRam container..."
    docker rm -v payram &>/dev/null || true
  fi
  
  # Clean up old images
  log "INFO" "Cleaning up old PayRam images..."
  docker images --filter=reference='payramapp/payram' -q | xargs -r docker rmi -f &>/dev/null || true
  
  # Pull latest image with progress
  log "INFO" "Pulling PayRam image: payramapp/payram:${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}..."
  echo
  print_color "blue" "📥 Downloading Docker image..."
  print_color "gray" "   This may take several minutes depending on your connection"
  echo
  
  # Pull with progress monitoring
  if ! docker pull "payramapp/payram:${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}" 2>&1 | while IFS= read -r line; do
    if [[ "$line" =~ Pulling|Downloading|Extracting|Pull\ complete ]]; then
      echo "   $line"
    elif [[ "$line" =~ Status:.*Downloaded ]]; then
      print_color "green" "   ✅ Download completed successfully"
    fi
  done; then
    log "ERROR" "Failed to pull Docker image"
    return 1
  fi
  echo
  
  # Create data directories
  mkdir -p "$PAYRAM_CORE_DIR"/{log/supervisord,db/postgres}
  if [[ "$ORIGINAL_USER" != "root" ]]; then
    chown -R "$ORIGINAL_USER:$(id -gn "$ORIGINAL_USER")" "$PAYRAM_CORE_DIR"
  fi

  # Deploy container
  log "INFO" "Starting PayRam container..."
  docker run -d \
    --name payram \
    --restart unless-stopped \
    --publish 8080:8080 \
    --publish 8443:8443 \
    --publish 80:80 \
    --publish 443:443 \
    --publish 5432:5432 \
    -e AES_KEY="$AES_KEY" \
    -e BLOCKCHAIN_NETWORK_TYPE="$NETWORK_TYPE" \
    -e SERVER="$SERVER" \
    -e POSTGRES_SSLMODE="$POSTGRES_SSLMODE" \
    -e POSTGRES_HOST="$DB_HOST" \
    -e POSTGRES_PORT="$DB_PORT" \
    -e POSTGRES_DATABASE="$DB_NAME" \
    -e POSTGRES_USERNAME="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e SSL_CERT_PATH="$SSL_CERT_PATH" \
    -v "$PAYRAM_CORE_DIR":/root/payram \
    -v "$PAYRAM_CORE_DIR/log/supervisord":/var/log \
    -v "$PAYRAM_CORE_DIR/db/postgres":/var/lib/payram/db/postgres \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    "payramapp/payram:${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  
  # Verify deployment
  sleep 5
  if docker ps --filter name=payram --filter status=running --format '{{.Names}}' | grep -wq '^payram$'; then
    log "SUCCESS" "PayRam container deployed successfully!"
    
    # Save configuration after successful deployment
    save_configuration
    
    # Perform health check
    if perform_health_check; then
      log "SUCCESS" "PayRam application is healthy and ready!"
    else
      log "WARN" "Container started but health check failed - may need time to initialize"
    fi
    
    # Show container info
    docker ps --filter name=payram
    log "INFO" "Container logs: docker logs payram"
    log "INFO" "Container shell: docker exec -it payram bash"
    
    return 0
  else
    log "ERROR" "PayRam container failed to start"
    log "INFO" "Check logs with: docker logs payram"
    return 1
  fi
}

# Health check function
perform_health_check() {
  echo
  print_color "blue" "🏥 Performing application health check..."
  
  local max_attempts=6
  local attempt=1
  local wait_time=10
  
  while [[ $attempt -le $max_attempts ]]; do
    print_color "yellow" "   Attempt $attempt/$max_attempts: Checking application status..."
    
    # Check if container is still running
    if ! docker ps --filter name=payram --filter status=running --format '{{.Names}}' | grep -wq '^payram$'; then
      print_color "red" "   ❌ Container stopped unexpectedly"
      return 1
    fi
    
    # Check container logs for successful startup indicators
    local logs=$(docker logs payram 2>&1 | tail -20)
    
    # Look for positive indicators in logs
    if echo "$logs" | grep -qi "server.*start\|ready\|listening\|started\|running"; then
      print_color "green" "   ✅ Application startup detected in logs"
      
      # Additional check: Try to connect to port 8080
      if timeout 5 bash -c "</dev/tcp/127.0.0.1/8080" >/dev/null 2>&1; then
        print_color "green" "   ✅ Port 8080 is accepting connections"
        print_color "green" "   🎉 Health check passed - PayRam is healthy!"
        echo
        return 0
      else
        print_color "yellow" "   ⚠️  Application starting but port not ready yet..."
      fi
    elif echo "$logs" | grep -qi "error\|failed\|exception\|fatal"; then
      print_color "red" "   ❌ Error detected in application logs"
      print_color "gray" "   Last few log lines:"
      echo "$logs" | tail -5 | sed 's/^/      /'
      echo
      return 1
    else
      print_color "yellow" "   ⏳ Application still initializing..."
    fi
    
    if [[ $attempt -lt $max_attempts ]]; then
      print_color "gray" "   Waiting ${wait_time}s before next check..."
      sleep $wait_time
    fi
    
    ((attempt++))
  done
  
  print_color "yellow" "   ⚠️  Health check timeout - application may still be starting"
  print_color "gray" "   You can check status later with: docker logs payram"
  echo
  return 1
}

# Pre-upgrade validation checklist
validate_upgrade_readiness() {
  log "INFO" "🔍 Performing pre-upgrade validation..."
  echo
  print_color "blue" "╔════════════════════════════════════════════════════════════╗"
  print_color "blue" "║                    🔍 UPGRADE READINESS CHECK              ║"
  print_color "blue" "╚════════════════════════════════════════════════════════════╝"
  echo
  
  local checks_passed=0
  local total_checks=7
  
  # Check 1: Configuration exists
  print_color "yellow" "📋 1/7 Checking existing configuration..."
  if [[ -f "$PAYRAM_INFO_DIR/config.env" ]]; then
    print_color "green" "   ✅ Configuration file found"
    ((checks_passed++))
  else
    print_color "red" "   ❌ Configuration file missing"
  fi
  
  # Check 2: Docker service
  print_color "yellow" "🐳 2/7 Checking Docker service..."
  if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    print_color "green" "   ✅ Docker service is running"
    ((checks_passed++))
  else
    print_color "red" "   ❌ Docker service not available"
  fi
  
  # Check 3: Current container status
  print_color "yellow" "📦 3/7 Checking current PayRam container..."
  if docker ps --filter "name=^payram$" --format "{{.Names}}" | grep -q "payram"; then
    print_color "green" "   ✅ PayRam container is running"
    ((checks_passed++))
  else
    if docker ps -a --filter "name=^payram$" --format "{{.Names}}" | grep -q "payram"; then
      print_color "yellow" "   ⚠️  PayRam container exists but stopped"
      ((checks_passed++))
    else
      print_color "red" "   ❌ No PayRam container found"
    fi
  fi
  
  # Check 4: Disk space
  print_color "yellow" "💾 4/7 Checking disk space..."
  if check_disk_space_requirements_silent; then
    print_color "green" "   ✅ Sufficient disk space available"
    ((checks_passed++))
  else
    print_color "red" "   ❌ Insufficient disk space"
  fi
  
  # Check 5: Network connectivity
  print_color "yellow" "🌐 5/7 Checking network connectivity..."
  if timeout 10 curl -s https://registry-1.docker.io >/dev/null 2>&1; then
    print_color "green" "   ✅ Docker registry accessible"
    ((checks_passed++))
  else
    print_color "red" "   ❌ Cannot reach Docker registry"
  fi
  
  # Check 6: Target image availability
  print_color "yellow" "🏷️  6/7 Checking target image availability..."
  local target_tag="${NEW_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  if validate_docker_tag "$target_tag" >/dev/null 2>&1; then
    print_color "green" "   ✅ Target image 'payramapp/payram:$target_tag' is available"
    ((checks_passed++))
  else
    print_color "red" "   ❌ Target image 'payramapp/payram:$target_tag' not found"
  fi
  
  # Check 7: Database connectivity (if external)
  print_color "yellow" "🗄️  7/7 Checking database connectivity..."
  if [[ "$DB_HOST" != "localhost" && "$DB_HOST" != "127.0.0.1" ]]; then
    if timeout 5 bash -c "</dev/tcp/$DB_HOST/$DB_PORT" >/dev/null 2>&1; then
      print_color "green" "   ✅ External database is reachable"
      ((checks_passed++))
    else
      print_color "red" "   ❌ Cannot reach external database"
    fi
  else
    print_color "green" "   ✅ Using internal database (no check needed)"
    ((checks_passed++))
  fi
  
  echo
  print_color "blue" "╔════════════════════════════════════════════════════════════╗"
  if [[ $checks_passed -eq $total_checks ]]; then
    print_color "green" "║  🎉 UPGRADE POSSIBLE: All checks passed ($checks_passed/$total_checks)          ║"
    print_color "blue" "║                                                            ║"
    print_color "green" "║  ✅ System is ready for upgrade                            ║"
    print_color "blue" "╚════════════════════════════════════════════════════════════╝"
    echo
    return 0
  elif [[ $checks_passed -ge 5 ]]; then
    print_color "yellow" "║  ⚠️  UPGRADE POSSIBLE: Some issues detected ($checks_passed/$total_checks)      ║"
    print_color "blue" "║                                                            ║"
    print_color "yellow" "║  🔧 Upgrade can proceed but with warnings                 ║"
    print_color "blue" "╚════════════════════════════════════════════════════════════╝"
    echo
    print_color "yellow" "⚠️  Some non-critical issues were found. Continue? (y/N): "
    read -r continue_choice
    if [[ "$continue_choice" =~ ^[Yy]$ ]]; then
      return 0
    else
      log "INFO" "Upgrade cancelled by user"
      return 1
    fi
  else
    print_color "red" "║  ❌ UPGRADE NOT POSSIBLE: Critical issues found ($checks_passed/$total_checks)  ║"
    print_color "blue" "║                                                            ║"
    print_color "red" "║  🚫 Please resolve issues before upgrading                ║"
    print_color "blue" "╚════════════════════════════════════════════════════════════╝"
    echo
    print_color "red" "Please resolve the above issues before attempting upgrade."
    return 1
  fi
}

# Container update workflow
update_payram_container() {
  log "INFO" "Starting PayRam update process..."
  
  # Load existing configuration
  get_payram_directories
  if ! load_configuration; then
    log "ERROR" "Cannot update - no existing configuration found"
    log "INFO" "Please run initial setup first (without --update flag)"
    return 1
  fi
  
  # Validate upgrade readiness
  if ! validate_upgrade_readiness; then
    log "ERROR" "Upgrade validation failed"
    return 1
  fi
  
  local current_tag="$IMAGE_TAG"
  local target_tag="${NEW_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  
  log "INFO" "Update Configuration:"
  log "INFO" "  Current version: $current_tag"
  log "INFO" "  Target version: $target_tag"
  
  # Version selection menu
  print_color "blue" "Update Options:"
  print_color "yellow" "1) Update to target version: $target_tag"
  print_color "yellow" "2) Keep current version: $current_tag"
  print_color "yellow" "3) Cancel update"
  
  while true; do
    read -p "Select option (1-3): " choice
    case $choice in
      1)
        IMAGE_TAG="$target_tag"
        break
        ;;
      2)
        IMAGE_TAG="$current_tag"
        log "INFO" "Keeping current version"
        break
        ;;
      3)
        log "INFO" "Update cancelled by user"
        return 0
        ;;
      *)
        print_color "red" "Invalid option. Please select 1-3."
        ;;
    esac
  done
  
  # Show final configuration
  log "INFO" "Final Update Configuration:"
  log "INFO" "  Image: payramapp/payram:$IMAGE_TAG"
  log "INFO" "  Network: $NETWORK_TYPE"
  log "INFO" "  Server: $SERVER"
  log "INFO" "  Database: $DB_HOST:$DB_PORT/$DB_NAME"
  
  read -p "Press [Enter] to proceed with update..."
  
  # Validate Docker tag BEFORE stopping container
  if ! validate_docker_tag "${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"; then
    log "ERROR" "Cannot proceed with invalid Docker tag: ${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    log "ERROR" "Update cancelled - existing container remains running"
    return 1
  fi
  
  # Stop existing container
  if docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" | grep -q "payram"; then
    log "INFO" "Stopping existing PayRam container..."
    docker stop payram || true
  fi

  # Deploy updated container with update-specific fixes
  deploy_payram_container_update
}

# Update-specific container deployment with fixes
deploy_payram_container_update() {
  show_progress 10 10 "Deploying updated PayRam container..."
  
  # Generate AES key if not exists
  if [[ -z "$AES_KEY" ]]; then
    generate_aes_key
  fi
  
  # Check for existing container
  if docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" | grep -q "payram"; then
    log "WARN" "PayRam container is already running"
    docker ps --filter "name=payram"
    return 0
  fi
  
  # Remove stopped container if exists
  if docker ps -a --filter "name=^payram$" --format "{{.Names}}" | grep -q "payram"; then
    log "INFO" "Removing existing stopped PayRam container..."
    docker rm -v payram &>/dev/null || true
  fi
  
  # Clean up old images
  log "INFO" "Cleaning up old PayRam images..."
  {
    imgs="$(docker images --filter=reference='payramapp/payram' -q)"
    if [[ -n "$imgs" ]]; then
      # shellcheck disable=SC2086
      docker rmi -f $imgs
    fi
  } &>/dev/null || true
  
  # Pull latest image with progress
  log "INFO" "Pulling PayRam image: payramapp/payram:${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}..."
  echo
  print_color "blue" "📥 Downloading Docker image..."
  print_color "gray" "   This may take several minutes depending on your connection"
  echo
  
  # Pull with progress monitoring
  if ! docker pull "payramapp/payram:${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}" 2>&1 | while IFS= read -r line; do
    if [[ "$line" =~ Pulling|Downloading|Extracting|Pull\ complete ]]; then
      echo "   $line"
    elif [[ "$line" =~ Status:.*Downloaded ]]; then
      print_color "green" "   ✅ Download completed successfully"
    fi
  done; then
    log "ERROR" "Failed to pull Docker image"
    return 1
  fi
  echo
  
  # Save configuration BEFORE starting container (update-specific fix)
  save_configuration
  
  # Deploy container with update-specific volume mounts
  log "INFO" "Starting updated PayRam container..."
  docker run -d \
    --name payram \
    --restart unless-stopped \
    --publish 8080:8080 \
    --publish 8443:8443 \
    --publish 80:80 \
    --publish 443:443 \
    --publish 5432:5432 \
    -e AES_KEY="$AES_KEY" \
    -e BLOCKCHAIN_NETWORK_TYPE="$NETWORK_TYPE" \
    -e SERVER="$SERVER" \
    -e POSTGRES_SSLMODE="$POSTGRES_SSLMODE" \
    -e POSTGRES_HOST="$DB_HOST" \
    -e POSTGRES_PORT="$DB_PORT" \
    -e POSTGRES_DATABASE="$DB_NAME" \
    -e POSTGRES_USERNAME="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e SSL_CERT_PATH="$SSL_CERT_PATH" \
    -v "$PAYRAM_CORE_DIR":/root/payram \
    -v "$PAYRAM_CORE_DIR/log/supervisord":/var/log \
    -v "$PAYRAM_CORE_DIR/db/postgres":/var/lib/payram/db/postgres \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    "payramapp/payram:${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  
  # Verify deployment
  sleep 5
  if docker ps --filter name=payram --filter status=running --format '{{.Names}}' | grep -wq '^payram$'; then
    log "SUCCESS" "PayRam container updated successfully!"
    
    # Perform health check
    if perform_health_check; then
      log "SUCCESS" "PayRam application is healthy and ready!"
    else
      log "WARN" "Container started but health check failed - may need time to initialize"
    fi
    
    # Show container info
    docker ps --filter name=payram
    log "INFO" "Container logs: docker logs payram"
    log "INFO" "Container shell: docker exec -it payram bash"
    
    return 0
  else
    log "ERROR" "PayRam container failed to start"
    log "INFO" "Check logs with: docker logs payram"
    return 1
  fi
}

# Environment reset
reset_payram_environment() {
  print_color "red" "🚨 CRITICAL WARNING: Complete PayRam Environment Reset"
  echo
  print_color "yellow" "This will permanently delete ALL PayRam data including:"
  print_color "red" "  💀 PayRam container and ALL persistent data"
  print_color "red" "  🔑 AES encryption keys (hot wallet access lost forever)"
  print_color "red" "  🗄️  Database data (transaction history, configurations)"
  print_color "red" "  📄 Configuration files and custom SSL certificates"
  print_color "red" "  🔒 Let's Encrypt certificates and renewal settings"
  print_color "red" "  🐳 All PayRam Docker images"
  print_color "red" "  📋 Cron jobs and renewal tasks"
  echo
  
  print_color "red" "🔥 Hot Wallet Impact:"
  print_color "red" "  • Any funds in hot wallet will become PERMANENTLY INACCESSIBLE"
  print_color "red" "  • AES key deletion = no way to decrypt hot wallet private keys"
  print_color "red" "  • This action CANNOT be undone - backup first!"
  echo
  
  # Get directories to show what will be deleted
  get_payram_directories
  
  print_color "blue" "📋 DETAILED REMOVAL PREVIEW:"
  echo
  print_color "yellow" "🐳 Docker Components:"
  local container_count=$(docker ps -a --filter "name=^payram$" --format "{{.Names}}" 2>/dev/null | wc -l)
  local image_count=$(docker images --filter=reference='payramapp/payram' -q 2>/dev/null | wc -l)
  print_color "gray" "  • PayRam container: $([ $container_count -gt 0 ] && echo "✅ Found (will remove)" || echo "❌ Not found")"
  print_color "gray" "  • PayRam images: $([ $image_count -gt 0 ] && echo "✅ Found $image_count image(s) (will remove)" || echo "❌ Not found")"
  echo
  
  print_color "yellow" "📁 File System Components:"
  print_color "gray" "  • Config directory: $PAYRAM_INFO_DIR"
  [[ -d "$PAYRAM_INFO_DIR" ]] && print_color "gray" "    └─ Status: ✅ Exists ($(du -sh "$PAYRAM_INFO_DIR" 2>/dev/null | cut -f1) - will remove)" || print_color "gray" "    └─ Status: ❌ Not found"
  if [[ -d "$PAYRAM_INFO_DIR" ]]; then
    [[ -d "$PAYRAM_INFO_DIR/aes" ]] && print_color "gray" "    └─ AES keys: ✅ Found (will remove)" || print_color "gray" "    └─ AES keys: ❌ Not found"
    [[ -f "$PAYRAM_INFO_DIR/config.env" ]] && print_color "gray" "    └─ Config file: ✅ Found (will remove)" || print_color "gray" "    └─ Config file: ❌ Not found"
  fi
  echo
  
  print_color "gray" "  • Data directory: $PAYRAM_CORE_DIR"
  [[ -d "$PAYRAM_CORE_DIR" ]] && print_color "gray" "    └─ Status: ✅ Exists ($(du -sh "$PAYRAM_CORE_DIR" 2>/dev/null | cut -f1) - will remove)" || print_color "gray" "    └─ Status: ❌ Not found"
  if [[ -d "$PAYRAM_CORE_DIR" ]]; then
    [[ -d "$PAYRAM_CORE_DIR/db" ]] && print_color "gray" "    └─ Database: ✅ Found (will remove)" || print_color "gray" "    └─ Database: ❌ Not found"
    [[ -d "$PAYRAM_CORE_DIR/logs" ]] && print_color "gray" "    └─ Logs: ✅ Found (will remove)" || print_color "gray" "    └─ Logs: ❌ Not found"
  fi
  echo
  
  print_color "yellow" "🔒 SSL/TLS Components:"
  print_color "gray" "  • Let's Encrypt certificates: /etc/letsencrypt/"
  if [[ -d "/etc/letsencrypt" ]] && [[ "$(find /etc/letsencrypt -name "*.pem" 2>/dev/null | wc -l)" -gt 0 ]]; then
    local cert_count=$(find /etc/letsencrypt -name "*.pem" 2>/dev/null | wc -l)
    print_color "gray" "    └─ Status: ✅ Found $cert_count certificate files (will remove)"
    while IFS= read -r domain_dir; do
      domain="$(basename "$domain_dir")"
      print_color "gray" "    └─ Domain: $domain"
    done < <(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -name "*.*" 2>/dev/null | head -3)
  else
    print_color "gray" "    └─ Status: ❌ No certificates found"
  fi
  echo
  
  print_color "gray" "  • Renewal cron jobs: /etc/cron.d/payram-*"
  local cron_count=$(find /etc/cron.d -name "payram-*" 2>/dev/null | wc -l)
  [[ $cron_count -gt 0 ]] && print_color "gray" "    └─ Status: ✅ Found $cron_count cron job(s) (will remove)" || print_color "gray" "    └─ Status: ❌ Not found"
  echo
  
  print_color "yellow" "🚨💾 CRITICAL: Last Chance Backup Commands:"
  print_color "gray" "  # Complete backup (recommended)"
  print_color "gray" "  tar -czf payram-complete-backup-$(date +%Y%m%d-%H%M%S).tar.gz \\"
  print_color "gray" "      ~/.payraminfo ~/.payram-core /etc/letsencrypt 2>/dev/null"
  print_color "gray" "  "
  print_color "gray" "  # Database only backup"
  print_color "gray" "  docker exec payram pg_dump -U payram payram > payram-db-backup-$(date +%Y%m%d-%H%M%S).sql"
  echo
  
  print_color "red" "⚠️  This is your FINAL WARNING - ALL DATA WILL BE PERMANENTLY LOST!"
  echo
  
  read -p "Are you absolutely sure? Type 'DELETE' to confirm: " confirmation
  if [[ "$confirmation" != "DELETE" ]]; then
    log "INFO" "Reset cancelled by user"
    return 0
  fi
  echo
  
  print_color "red" "🔥 Starting complete PayRam environment removal..."
  echo
  
  # Stop and remove container
  log "INFO" "Step 1/6: Stopping and removing PayRam container..."
  if docker ps --filter "name=^payram$" --format "{{.Names}}" 2>/dev/null | grep -q "payram"; then
    docker stop payram &>/dev/null || true
    print_color "green" "  ✅ Container stopped"
  fi
  if docker ps -a --filter "name=^payram$" --format "{{.Names}}" 2>/dev/null | grep -q "payram"; then
    docker rm -v payram &>/dev/null || true
    print_color "green" "  ✅ Container removed"
  fi
  
  # Remove Docker images
  log "INFO" "Step 2/6: Removing PayRam Docker images..."
  {
    imgs="$(docker images --filter=reference='payramapp/payram' -q)"
    if [[ -n "$imgs" ]]; then
      # shellcheck disable=SC2086
      docker rmi -f $imgs &>/dev/null
      print_color "green" "  ✅ Docker images removed"
    else
      print_color "yellow" "  ⚠️  No PayRam images found"
    fi
  } || print_color "yellow" "  ⚠️  Some images may still be in use"
  
  # Skip removing data directories here; will remove at Step 6 after using config
  log "INFO" "Step 3/6: Skipping data/config directory removal until Step 6..."
  
  # Remove Let's Encrypt certificates (for configured domain only)
  log "INFO" "Step 4/6: Removing Let's Encrypt certificates..."
  local removed_certs=false
  # Try to source existing config to get SSL_MODE and SSL_CERT_PATH if available
  if [[ -f "$PAYRAM_INFO_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$PAYRAM_INFO_DIR/config.env"
  fi
  if [[ "${SSL_MODE:-}" == "letsencrypt" && -n "${SSL_CERT_PATH:-}" ]]; then
    # Normalize and extract domain from SSL_CERT_PATH (expecting /etc/letsencrypt/live/<domain>)
    local cert_path_normalized="${SSL_CERT_PATH%/}"
    local domain_name
    domain_name="$(basename "$cert_path_normalized")"
    if [[ -n "$domain_name" && -d "/etc/letsencrypt/live/$domain_name" ]]; then
      if command -v certbot >/dev/null 2>&1; then
        if certbot delete --cert-name "$domain_name" --non-interactive --quiet; then
          print_color "green" "  ✅ Removed Let's Encrypt certificate for domain: $domain_name"
          removed_certs=true
        else
          print_color "yellow" "  ⚠️  Failed to delete cert via certbot for domain: $domain_name"
          print_color "gray" "     You may remove manually: certbot delete --cert-name $domain_name"
        fi
      else
        print_color "yellow" "  ⚠️  Certbot not found; skipping certificate deletion for $domain_name"
        print_color "gray" "     Install certbot or remove manually under /etc/letsencrypt/{live,archive,renewal}"
      fi
    else
      print_color "yellow" "  ⚠️  SSL_CERT_PATH points to a non-existent domain directory: $SSL_CERT_PATH"
    fi
  else
    print_color "yellow" "  ⚠️  No Let's Encrypt configuration detected for this installation"
  fi

  # Always remove PayRam-related renewal hooks if present
  if [[ -f "/etc/letsencrypt/renewal-hooks/deploy/payram-restart" ]]; then
    rm -f "/etc/letsencrypt/renewal-hooks/deploy/payram-restart" &>/dev/null || true
    removed_certs=true
  fi
  find /etc/letsencrypt/renewal-hooks -name "*payram*" -delete &>/dev/null || true

  if [[ "$removed_certs" == true ]]; then
    print_color "green" "  ✅ Certificate artifacts cleaned (domain and/or hooks)"
  fi
  
  # Remove cron jobs
  log "INFO" "Step 5/6: Removing PayRam cron jobs..."
  local removed_cron=false
  for cron_file in /etc/cron.d/payram-*; do
    if [[ -f "$cron_file" ]]; then
      rm -f "$cron_file" &>/dev/null || true
      print_color "green" "  ✅ Removed cron job: $(basename "$cron_file")"
      removed_cron=true
    fi
  done
  
  if [[ "$removed_cron" == false ]]; then
    print_color "yellow" "  ⚠️  No PayRam cron jobs found"
  fi
  
  # Remove PayRam data directories at the end (after cert cleanup and cron removal)
  log "INFO" "Step 6/6: Removing PayRam data directories..."
  if [[ -d "$PAYRAM_CORE_DIR" ]]; then
    rm -rf "$PAYRAM_CORE_DIR"
    print_color "green" "  ✅ Data directory removed: $PAYRAM_CORE_DIR"
  else
    print_color "yellow" "  ⚠️  Data directory not found: $PAYRAM_CORE_DIR"
  fi
  
  if [[ -d "$PAYRAM_INFO_DIR" ]]; then
    rm -rf "$PAYRAM_INFO_DIR"
    print_color "green" "  ✅ Config directory removed: $PAYRAM_INFO_DIR"
  else
    print_color "yellow" "  ⚠️  Config directory not found: $PAYRAM_INFO_DIR"
  fi
  
  # Final cleanup and summary
  log "INFO" "Final cleanup and verification..."
  
  # Verify removal
  local cleanup_success=true
  
  if docker ps -a --filter "name=^payram$" --format "{{.Names}}" 2>/dev/null | grep -q "payram"; then
    print_color "red" "  ❌ Container still exists"
    cleanup_success=false
  fi
  
  if [[ -d "$PAYRAM_CORE_DIR" ]] || [[ -d "$PAYRAM_INFO_DIR" ]]; then
    print_color "red" "  ❌ Some directories still exist"
    cleanup_success=false
  fi
  
  echo
  if [[ "$cleanup_success" == true ]]; then
    print_color "green" "🎉 PayRam environment reset completed successfully!"
    print_color "green" "✅ All PayRam components have been removed"
    echo
    print_color "blue" "📋 Summary of actions performed:"
    print_color "gray" "  • Docker containers and images removed"
    print_color "gray" "  • Configuration and data directories deleted"
    print_color "gray" "  • AES encryption keys permanently deleted"
    print_color "gray" "  • Certificate renewal hooks removed"
    print_color "gray" "  • Cron jobs cleaned up"
    echo
    print_color "yellow" "💡 To reinstall PayRam, run:"
    print_color "gray" "   sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\""
  else
    print_color "red" "❌ Reset completed with some issues"
    print_color "yellow" "Some components may need manual removal"
    print_color "gray" "Check the messages above for details"
  fi
  
  echo
  log "SUCCESS" "PayRam environment reset process complete"
}

# Function to detect public IP address with robust error handling
get_public_ip() {
  local public_ip=""
  
  # Set strict error handling for this function only
  set +e  # Don't exit on error
  
  # Try multiple services for reliability
  local ip_services=(
    "https://ipinfo.io/ip"
    "https://ip.seeip.org"
    "https://ifconfig.me/ip"
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
  )
  
  # Check if curl or wget is available
  local has_curl=false
  local has_wget=false
  
  if command -v curl >/dev/null 2>&1; then
    has_curl=true
  fi
  
  if command -v wget >/dev/null 2>&1; then
    has_wget=true
  fi
  
  # If neither curl nor wget is available, skip web-based detection
  if [[ "$has_curl" == false && "$has_wget" == false ]]; then
    # Try fallback method only
    if command -v ip >/dev/null 2>&1; then
      public_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}' 2>/dev/null || echo "")
      if [[ -n "$public_ip" ]] && [[ "$public_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$public_ip"
        return 0
      fi
    fi
    echo ""
    return 1
  fi
  
  # Try web services
  for service in "${ip_services[@]}"; do
    if [[ "$has_curl" == true ]]; then
      # Use curl with comprehensive error handling
      public_ip=$(timeout 15 curl -s --connect-timeout 5 --max-time 10 --retry 1 --fail "$service" 2>/dev/null | head -1 | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || echo "")
    elif [[ "$has_wget" == true ]]; then
      # Use wget with comprehensive error handling  
      public_ip=$(timeout 15 wget -qO- --timeout=10 --tries=1 "$service" 2>/dev/null | head -1 | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || echo "")
    fi
    
    # Validate the IP format more strictly
    if [[ -n "$public_ip" ]] && [[ "$public_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      # Additional validation: check IP ranges
      local IFS='.'
      local ip_parts=($public_ip)
      local valid_ip=true
      
      # Check each octet is within valid range (0-255)
      for part in "${ip_parts[@]}"; do
        if [[ $part -gt 255 || $part -lt 0 ]]; then
          valid_ip=false
          break
        fi
      done
      
      # Check for private/reserved ranges
      local first_octet=${ip_parts[0]}
      local second_octet=${ip_parts[1]}
      
      # Skip private/reserved IPs
      if [[ $first_octet -eq 10 ]] || \
         [[ $first_octet -eq 172 && $second_octet -ge 16 && $second_octet -le 31 ]] || \
         [[ $first_octet -eq 192 && $second_octet -eq 168 ]] || \
         [[ $first_octet -eq 127 ]] || \
         [[ $first_octet -eq 0 ]] || \
         [[ $first_octet -ge 224 ]]; then
        valid_ip=false
      fi
      
      if [[ "$valid_ip" == true ]]; then
        echo "$public_ip"
        return 0
      fi
    fi
    
    # Clear the variable for next iteration
    public_ip=""
  done
  
  # Fallback: try to get IP from network interface (but only for local network awareness)
  if command -v ip >/dev/null 2>&1; then
    local local_ip=""
    local_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}' 2>/dev/null || echo "")
    if [[ -n "$local_ip" ]] && [[ "$local_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      # Only return local IP if it's not a private range (unlikely but possible)
      local IFS='.'
      local ip_parts=($local_ip)
      local first_octet=${ip_parts[0]}
      local second_octet=${ip_parts[1]}
      
      # If it's not a private IP, return it
      if [[ $first_octet -ne 10 ]] && \
         [[ ! ($first_octet -eq 172 && $second_octet -ge 16 && $second_octet -le 31) ]] && \
         [[ ! ($first_octet -eq 192 && $second_octet -eq 168) ]] && \
         [[ $first_octet -ne 127 ]] && \
         [[ $first_octet -ne 0 ]] && \
         [[ $first_octet -lt 224 ]]; then
        echo "$local_ip"
        return 0
      fi
    fi
  fi
  
  # If all fails, return empty
  echo ""
  return 1
}

# Function to display access URLs with robust error handling
display_access_urls() {
  local public_ip=""
  
  # Safely attempt to get public IP with error handling
  set +e  # Don't exit on error
  public_ip=$(get_public_ip 2>/dev/null || echo "")
  set -e  # Re-enable exit on error
  
  echo
  print_color "green" "🌐 PayRam Access URLs:"
  echo
  
  # Check if SSL is configured (domain name set or SSL certificates exist)
  local ssl_enabled=false
  if [[ -n "${DOMAIN_NAME:-}" && "${DOMAIN_NAME}" != "" ]] || compgen -G "/etc/letsencrypt/live/*/fullchain.pem" > /dev/null 2>&1; then
    ssl_enabled=true
  fi
  
  # Public access - show only if we have a valid public IP
  if [[ -n "$public_ip" && "$public_ip" != "ERROR" ]]; then
    print_color "blue" "🌍 Public Access (from anywhere):"
    
    if [[ "$ssl_enabled" == "true" ]]; then
      print_color "gray" "  • HTTPS API: https://$public_ip:8443"
      print_color "gray" "  • Web Interface: https://$public_ip/login"
    else
      print_color "gray" "  • HTTP API: http://$public_ip:8080"
      print_color "gray" "  • Web Interface: http://$public_ip/login"
    fi
    
    echo
    print_color "yellow" "⚠️  Security Note:"
    if [[ "$ssl_enabled" == "true" ]]; then
      print_color "gray" "  • Ensure firewall allows ports 443, 8443"
      print_color "gray" "  • SSL is enabled - using secure HTTPS connections"
    else
      print_color "gray" "  • Ensure firewall allows ports 80, 8080"
      print_color "gray" "  • Consider setting up SSL/domain name for production"
    fi
    print_color "gray" "  • Detected public IP: $public_ip"
  else
    print_color "yellow" "🔍 Public IP Detection:"
    print_color "gray" "  • Could not detect public IP automatically"
    print_color "gray" "  • This is normal for private networks or if internet is unavailable"
    print_color "gray" "  • To check manually: curl -s ifconfig.me"
    print_color "gray" "  • Public access (if available): http://YOUR_PUBLIC_IP/login"
    echo
    print_color "blue" "💡 Alternative Access Methods:"
    print_color "gray" "  • Access locally via http://localhost/login"
    print_color "gray" "  • Set up port forwarding if behind NAT/firewall"
    print_color "gray" "  • Configure a domain name for external access"
  fi
  echo
  
  # Domain access (if configured) - safely check for domain variable
  if [[ -n "${DOMAIN_NAME:-}" && "${DOMAIN_NAME}" != "" ]]; then
    print_color "blue" "🏷️  Domain Access (SSL enabled):"
    print_color "gray" "  • HTTPS API: https://$DOMAIN_NAME:8443"
    print_color "gray" "  • Web Interface: https://$DOMAIN_NAME/login"
    echo
  fi
}

# Function to print colored text
print_color() {
  case "$1" in
    "green") echo -e "\033[0;32m$2\033[0m" ;;
    "red") echo -e "\033[0;31m$2\033[0m" ;;
    "yellow") echo -e "\033[0;33m$2\033[0m" ;;
    "blue") echo -e "\033[0;34m$2\033[0m" ;;
    "gray") echo -e "\033[0;90m$2\033[0m" ;;
    "bold") echo -e "\033[1m$2\033[0m" ;;
    "magenta") echo -e "\033[0;35m$2\033[0m" ;;
    "cyan") echo -e "\033[0;36m$2\033[0m" ;;
    *) echo "$2" ;;
  esac
}

# Welcome banner with ASCII art
display_welcome_banner() {
  clear
  echo
  print_color "cyan" "╔═════════════════════════════════════════════════════════════════╗"
  print_color "cyan" "║                                                                 ║"
  print_color "yellow" "║  💰 ████   ███   █   █ ████   ███  █   █  💎  Crypto Gateway  ║"
  print_color "yellow" "║  ₿  █   █ █   █  █   █ █   █ █   █ ██ ██  🚀                   ║"
  print_color "yellow" "║  ⚡ ████  █████  █████ ████  █████ █ █ █  💸  Self-Hosted     ║"
  print_color "yellow" "║  🌟 █     █   █      █ █   █ █   █ █   █  💰                   ║"
  print_color "yellow" "║  🔥 █     █   █      █ █   █ █   █ █   █  ₿   No middleman    ║"
  print_color "cyan" "║                                                                 ║"
  print_color "magenta" "║                    🚀 Welcome to PayRam Setup! 🚀             ║"
  print_color "cyan" "║                                                                 ║"
  print_color "green" "║    💰 Self-hosted crypto payment gateway with encryption 💰    ║"
  print_color "blue" "║    ⚡ Bitcoin, Ethereum, USDT, USDC, TRX & more ⚡            ║"
  print_color "yellow" "║    🔐 Enterprise-grade security with AES-256 encryption 🔒     ║"
  print_color "cyan" "║                                                                 ║"
  print_color "cyan" "╚═════════════════════════════════════════════════════════════════╝"
  echo
  print_color "bold" "🎉 Welcome to PayRam Universal Setup Script v3!"
  echo
  print_color "blue" "🚀 Setting up your crypto payment gateway with:"
  print_color "gray" "   • ❄️  Cold wallet security (keys never stored)"
  print_color "gray" "   • 🔥 Hot wallet for operations (minimal funds)"
  print_color "gray" "   • 💳 Smart sweep deposits (no key storage)"
  print_color "gray" "   • 🔐 AES-256 encryption for hot wallet keys"
  print_color "gray" "   • 🌐 Multi-platform support (Linux, macOS)"
  print_color "gray" "   • 🔒 SSL/TLS with Let's Encrypt automation"
  echo
  print_color "yellow" "💡 PayRam Philosophy: Minimal key storage = Maximum security"
  echo
  sleep 3
}

# Success completion banner
display_success_banner() {
  echo
  print_color "green" "🎉 ═════════════════════════════════════════════════════════════════════════════════════════════════ 🎉"
  echo
  print_color "yellow" "    ____  _____  ______  ___    __  ___                                                                         "
  print_color "yellow" "   / __ \/   \ \/ / __ \/   |  /  |/  /                                                                         "
  print_color "yellow" "  / /_/ / /| |\  / /_/ / /| | / /|_/ /                                                                          "
  print_color "yellow" " / ____/ ___ |/ / _, _/ ___ |/ /  / /                                                                           "
  print_color "yellow" "/_/   /_/  |_/_/_/ |_/_/  |_/_/  /_/                                                                            "
  echo
  print_color "cyan" "__  __                    ____                                   __     ______      __                          "
  print_color "cyan" "\ \/ ____  __  _______   / __ \____ ___  ______ ___  ___  ____  / /_   / ________ _/ /____ _      ______ ___  __"
  print_color "cyan" " \  / __ \/ / / / ___/  / /_/ / __ \`/ / / / __ \`__ \/ _ \/ __ \/ __/  / / __/ __ \`/ __/ _ | | /| / / __ \`/ / / /"
  print_color "cyan" " / / /_/ / /_/ / /     / ____/ /_/ / /_/ / / / / / /  __/ / / / /_   / /_/ / /_/ / /_/  __| |/ |/ / /_/ / /_/ / "
  print_color "cyan" "/_/\____/\__,_/_/     /_/    \__,_/\__, /_/ /_/ /_/\___/_/ /_/\__/   \____/\__,_/\__/\___/|__/|__/\__,_/\__, /  "
  print_color "cyan" "                                  /____/                                                               /____/   "
  echo
  print_color "green" "💰 ═════════════════════════════════════════════════════════════════════════════════════════════════ 💰"
  echo
  print_color "magenta" "                           🎊 Setup Successfully Completed! 🎊"
  print_color "green" "                      🚀 Your crypto payment gateway is ready! 🚀"
  echo
  print_color "green" "₿ 🔥 💎 ⚡ 🌟 💸 🪙 🚀 💰 ₿ 🔥 💎 ⚡ 🌟 💸 🪙 🚀 💰 ₿ 🔥 💎 ⚡ 🌟 💸 🪙 🚀 💰 ₿"
  echo
}

# Interactive menu for no-arguments mode
show_interactive_menu() {
  # Display welcome banner
  display_welcome_banner
  
  echo
  print_color "blue" "╔═══════════════════════════════════════════════════════════╗"
  print_color "blue" "║                    🚀 PayRam Operations Menu              ║"
  print_color "blue" "╚═══════════════════════════════════════════════════════════╝"
  echo
  
  print_color "green" "Please select an operation:"
  echo
  print_color "yellow" "1) 🆕 Install PayRam"
  print_color "gray" "   • Fresh installation with interactive setup"
  print_color "gray" "   • Configure database, SSL, and hot wallet encryption"
  print_color "gray" "   • Deploy new PayRam container"
  echo
  
  print_color "yellow" "2) 🔄 Update PayRam instance to latest version"
  print_color "gray" "   • Update existing PayRam installation"
  print_color "gray" "   • Preserve configuration and data"
  print_color "gray" "   • Pull latest Docker image and restart"
  echo
  
  print_color "yellow" "3) 🔄 Restart PayRam container"
  print_color "gray" "   • Restart existing PayRam container"
  print_color "gray" "   • Quick restart without updates"
  print_color "gray" "   • Useful for configuration changes"
  echo
  
  print_color "yellow" "4) 🗑️  Reset PayRam environment"
  print_color "gray" "   • Completely remove PayRam installation"
  print_color "gray" "   • Delete containers, data, and configuration"
  print_color "gray" "   • ⚠️  WARNING: This will delete ALL PayRam data!"
  echo
  
  print_color "yellow" "5) ❌ Exit"
  echo
  
  while true; do
    read -p "Enter your choice (1-5): " choice
    case $choice in
      1)
        log "INFO" "User selected: Install PayRam"
        MENU_CHOICE=1
        return 0
        ;;
      2)
        log "INFO" "User selected: Update PayRam"
        MENU_CHOICE=2
        return 0
        ;;
      3)
        log "INFO" "User selected: Restart PayRam"
        MENU_CHOICE=3
        return 0
        ;;
      4)
        log "INFO" "User selected: Reset PayRam"
        MENU_CHOICE=4
        return 0
        ;;
      5)
        log "INFO" "User selected: Exit"
        print_color "blue" "👋 Goodbye! Thank you for using PayRam setup script."
        exit 0
        ;;
      *)
        print_color "red" "❌ Invalid option. Please select 1, 2, 3, 4, or 5."
        ;;
    esac
  done
}

# Show network selection submenu for install
show_network_selection() {
  echo
  print_color "blue" "╔═══════════════════════════════════════════════════════════╗"
  print_color "blue" "║                    🌐 Network Selection                   ║"
  print_color "blue" "╚═══════════════════════════════════════════════════════════╝"
  echo
  
  print_color "yellow" "Please select the network for PayRam installation:"
  echo
  
  print_color "green" "1) 🌐 Mainnet (Production)"
  print_color "gray" "   • Live Bitcoin, Ethereum, and other cryptocurrencies"
  print_color "gray" "   • Real transactions and payments"
  print_color "gray" "   • Production environment"
  echo
  
  print_color "cyan" "2) 🧪 Testnet (Development) – Best for first-time users, testing out features"
  print_color "gray" "   • Test networks for development and testing"
  print_color "gray" "   • Uses testnet tokens (no monetary value)"
  print_color "gray" "   • Development environment"
  echo
  
  while true; do
    read -p "Enter your choice (1-2): " choice
    case $choice in
      1)
        log "INFO" "User selected: Mainnet installation"
        NETWORK_TYPE="mainnet"
        SERVER="PRODUCTION"
        NETWORK_CHOICE=1
        return 0
        ;;
      2)
        log "INFO" "User selected: Testnet installation"
        NETWORK_TYPE="testnet"
        SERVER="DEVELOPMENT"
        NETWORK_CHOICE=2
        return 0
        ;;
      *)
        print_color "red" "❌ Invalid option. Please select 1 or 2."
        ;;
    esac
  done
}

# Restart PayRam container
restart_payram_container() {
  log "INFO" "Starting PayRam container restart..."
  
  # Check if PayRam container exists
  if ! docker ps -a --filter "name=^payram$" --format "{{.Names}}" | grep -q "^payram$"; then
    print_color "red" "❌ No PayRam container found."
    print_color "yellow" "Please install PayRam first using option 1."
    return 1
  fi
  
  # Check current container status
  if docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" | grep -q "^payram$"; then
    print_color "blue" "🔄 Restarting PayRam container..."
    docker restart payram
  else
    print_color "blue" "🚀 Starting stopped PayRam container..."
    docker start payram
  fi
  
  # Verify restart was successful
  sleep 3
  if docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" | grep -q "^payram$"; then
    print_color "green" "✅ PayRam container is now running!"
    docker ps --filter name=payram
  else
    print_color "red" "❌ Failed to start PayRam container"
    print_color "yellow" "Check logs: docker logs payram"
    return 1
  fi
}

# --- MAIN ORCHESTRATION ---

# Usage information
usage() {
  cat << EOF
PayRam Universal Setup Script v3

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    Universal setup script for PayRam crypto payment gateway.
    Supports multiple operating systems and provides interactive configuration.

OPTIONS:
    --update --tag=<version> Update existing PayRam installation to specific version
    --restart                Restart PayRam container
    --reset                  Completely remove PayRam (requires confirmation)
    --testnet               Set up testnet environment (DEVELOPMENT mode)
    --tag=<tag>             Specify Docker image tag (required with --update)
    --debug                 Enable debug logging
    -h, --help              Show this help message

EXAMPLES:
    $0                      # Interactive fresh installation
    $0 --testnet           # Setup testnet environment
    $0 --update --tag=v1.5.0  # Update to specific version
    $0 --restart           # Restart PayRam container
    $0 --reset             # Complete environment reset

CURL INSTALLATION:
    # Recommended syntax (most reliable):
    curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh | bash -s -- --help
    curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh | bash -s -- --testnet
    curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh | bash -s -- --update
    curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh | bash -s -- --update --tag=v1.5.0
    
    # Alternative syntax (arguments inside quotes):
    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh) --help"
    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh) --update"
    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh) --update --tag=v1.5.0"
    
    # Incorrect syntax (will fail):
    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)" --help
    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)" --update

SUPPORTED SYSTEMS:
    • Ubuntu, Debian, Linux Mint
    • CentOS, RHEL, Rocky Linux, AlmaLinux
    • Fedora
    • Arch Linux, Manjaro
    • Alpine Linux
    • macOS (with Homebrew)

For more information, visit: https://github.com/PayRam/payram-scripts
EOF
}

# Initialize logging with proper error handling
init_logging() {
  # Try to create log file, fallback if permission denied
  if ! echo "PayRam Setup Script v3 - $(date)" > "$LOG_FILE" 2>/dev/null; then
    # Fallback to user's home directory if /tmp is not writable
    LOG_FILE="$HOME/payram-setup.log"
    if ! echo "PayRam Setup Script v3 - $(date)" > "$LOG_FILE" 2>/dev/null; then
      # Final fallback: disable file logging
      LOG_FILE="/dev/null"
      echo "Warning: Could not create log file, logging to console only" >&2
    fi
  fi
}

# Check for existing PayRam installation
check_existing_installation() {
  log "INFO" "Checking for existing PayRam installation..."
  
  local container_running=false
  local container_exists=false
  local config_exists=false
  local data_exists=false
  local installation_found=false
  
  # Initialize directories for checking
  get_payram_directories
  
  # Check for running container (only if docker is available)
  if command -v docker >/dev/null 2>&1 && \
     docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "^payram$"; then
    container_running=true
    installation_found=true
  fi
  
  # Check for existing container (stopped)
  if docker ps -a --filter "name=^payram$" --format "{{.Names}}" 2>/dev/null | grep -q "^payram$"; then
    container_exists=true
    installation_found=true
  fi
  
  # Check for configuration files
  if [[ -f "$PAYRAM_INFO_DIR/config.env" ]] || [[ -d "$PAYRAM_INFO_DIR" ]]; then
    config_exists=true
    installation_found=true
  fi
  
  # Check for data directories
  if [[ -d "$PAYRAM_CORE_DIR" ]]; then
    data_exists=true
    installation_found=true
  fi
  
  # If no installation found, proceed normally
  if [[ "$installation_found" == false ]]; then
    log "INFO" "No existing PayRam installation detected. Proceeding with fresh setup..."
    return 0
  fi
  
  # Show detailed warning about existing installation
  echo
  print_color "red" "⚠️  EXISTING PAYRAM INSTALLATION DETECTED!"
  echo
  print_color "yellow" "🔍 Installation Status:"
  
  if [[ "$container_running" == true ]]; then
    print_color "green" "  • PayRam Container: ✅ RUNNING"
    local container_uptime=$(docker ps --filter "name=^payram$" --format "{{.Status}}" 2>/dev/null)
    print_color "gray" "    └─ Status: $container_uptime"
  elif [[ "$container_exists" == true ]]; then
    print_color "yellow" "  • PayRam Container: ⚠️  EXISTS (stopped)"
    local container_status=$(docker ps -a --filter "name=^payram$" --format "{{.Status}}" 2>/dev/null)
    print_color "gray" "    └─ Status: $container_status"
  else
    print_color "gray" "  • PayRam Container: ❌ Not found"
  fi
  
  if [[ "$config_exists" == true ]]; then
    print_color "green" "  • Configuration: ✅ EXISTS"
    print_color "gray" "    └─ Location: $PAYRAM_INFO_DIR"
    if [[ -f "$PAYRAM_INFO_DIR/config.env" ]]; then
      local config_size=$(du -sh "$PAYRAM_INFO_DIR" 2>/dev/null | cut -f1)
      print_color "gray" "    └─ Size: $config_size"
    fi
  else
    print_color "gray" "  • Configuration: ❌ Not found"
  fi
  
  if [[ "$data_exists" == true ]]; then
    print_color "green" "  • Data Directory: ✅ EXISTS"
    print_color "gray" "    └─ Location: $PAYRAM_CORE_DIR"
    local data_size=$(du -sh "$PAYRAM_CORE_DIR" 2>/dev/null | cut -f1)
    print_color "gray" "    └─ Size: $data_size"
  else
    print_color "gray" "  • Data Directory: ❌ Not found"
  fi
  
  echo
  print_color "red" "🚨 CRITICAL WARNING:"
  print_color "yellow" "  • Running setup again may cause data loss or conflicts"
  print_color "yellow" "  • Existing configuration may be overwritten"
  print_color "yellow" "  • Hot wallet keys could become inaccessible"
  print_color "yellow" "  • Database data might be lost or corrupted"
  echo
  
  if [[ "$container_running" == true ]]; then
    print_color "red" "🔥 PayRam is currently RUNNING!"
    print_color "yellow" "   • To deploy a new instance, first reset the environment:"
    print_color "gray" "     sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --reset"
    print_color "yellow" "   • To keep data and upgrade, use update:"
    print_color "gray" "     sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --update"
    echo
    exit 0
  else
    print_color "blue" "💡 Recommended Actions:"
    print_color "gray" "   • Use --update flag to restart/update installation:"
    print_color "gray" "     sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --update"
    print_color "gray" "   • Use --reset flag to completely remove existing installation:"
    print_color "gray" "     sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --reset"
    print_color "gray" "   • Manual container restart: docker start payram"
    echo
  fi
  
  print_color "yellow" "💾 Before Continuing - Backup Commands:"
  print_color "gray" "  # Complete backup (RECOMMENDED)"
  print_color "gray" "  tar -czf payram-backup-$(date +%Y%m%d-%H%M%S).tar.gz \\"
  print_color "gray" "      ~/.payraminfo ~/.payram-core 2>/dev/null"
  print_color "gray" "  "
  if [[ "$container_running" == true ]]; then
    print_color "gray" "  # Database backup (while running)"
    print_color "gray" "  docker exec payram pg_dump -U payram payram > payram-db-backup-$(date +%Y%m%d-%H%M%S).sql"
  elif [[ "$container_exists" == true ]]; then
    print_color "gray" "  # Start container temporarily for backup"
    print_color "gray" "  docker start payram && docker exec payram pg_dump -U payram payram > backup.sql && docker stop payram"
  fi
  echo
  
  print_color "blue" "📋 What you can do instead:"
  print_color "gray" "  • Update existing installation: sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --update"
  print_color "gray" "  • Reset environment to start fresh: sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --reset"
  print_color "gray" "  • Check current status: docker ps | grep payram"
  print_color "gray" "  • View logs: docker logs payram"
  if [[ "$container_exists" == true && "$container_running" == false ]]; then
    print_color "gray" "  • Start existing container: docker start payram"
  fi
  echo
  exit 0
}

# Main execution flow
main() {
  # Initialize logging safely
  init_logging
  
  # Check privileges early - all operations except help require root
  if [[ $# -eq 0 || ($# -eq 1 && "$1" != "-h" && "$1" != "--help") || ($# -gt 1) ]]; then
    check_privileges
  fi
  
  # Parse command line arguments
  local update_mode=false
  local reset_mode=false
  local testnet_mode=false
  local install_mode=false
  local restart_mode=false
  local args_processed=$#
  NEW_IMAGE_TAG=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --update)
        update_mode=true
        shift
        ;;
      --reset)
        reset_mode=true
        shift
        ;;
      --restart)
        restart_mode=true
        shift
        ;;
      --testnet)
        testnet_mode=true
        NETWORK_TYPE="testnet"
        SERVER="DEVELOPMENT"
        install_mode=true
        shift
        ;;
      --tag=*)
        NEW_IMAGE_TAG="${1#*=}"
        shift
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      *)
        log "ERROR" "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
  
  # Validate --update requires --tag
  if [[ "$update_mode" == true && -z "$NEW_IMAGE_TAG" ]]; then
    log "ERROR" "--update requires --tag parameter to specify version"
    print_color "red" "❌ Error: --update must be used with --tag=version"
    print_color "yellow" "Example: $0 --update --tag=v1.2.0"
    exit 1
  fi
  
  # If no arguments were provided, show interactive menu
  if [[ $args_processed -eq 0 ]]; then
    show_interactive_menu
    
    case $MENU_CHOICE in
      1) 
        install_mode=true
        show_network_selection
        ;;
      2) update_mode=true ;;
      3) restart_mode=true ;;
      4) reset_mode=true ;;
    esac
  fi
  
  
  # Handle special modes
  if [[ "$reset_mode" == true ]]; then
    reset_payram_environment
    exit 0
  fi
  
  if [[ "$update_mode" == true ]]; then
    update_payram_container
    exit 0
  fi
  
  if [[ "$restart_mode" == true ]]; then
    restart_payram_container
    exit 0
  fi
  
  # Fresh installation workflow
  log "SUCCESS" "Starting PayRam setup..."
  
  # Check for existing installation before proceeding
  check_existing_installation
  
  # Step 1: System detection
  detect_system_info
  
  # Step 2: Install dependencies
  install_all_dependencies
  
  # Step 3: Setup directories and defaults
  get_payram_directories
  set_configuration_defaults
  
  # Apply testnet mode if selected
  if [[ "$testnet_mode" == true ]]; then
    log "INFO" "Testnet mode enabled"
    NETWORK_TYPE="testnet"
    SERVER="DEVELOPMENT"
  fi
  
  # Apply network selection from interactive menu
  if [[ "$NETWORK_CHOICE" == "2" ]]; then
    log "INFO" "Applying testnet configuration from menu selection"
    NETWORK_TYPE="testnet"
    SERVER="DEVELOPMENT"
  elif [[ "$NETWORK_CHOICE" == "1" ]]; then
    log "INFO" "Applying mainnet configuration from menu selection"
    NETWORK_TYPE="mainnet"
    SERVER="PRODUCTION"
  fi
  
  # Set image tag
  IMAGE_TAG="${NEW_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  
  # Step 4: Interactive configuration
  log "INFO" "Starting interactive configuration..."
  echo
  print_color "blue" "=== PayRam Configuration ==="
  echo
  
  configure_database
  configure_ssl
  
  # Step 5: Generate hot wallet encryption key
  show_progress 9 10 "Setting up hot wallet encryption (AES-256)"
  generate_aes_key
  
  # Step 6: Configuration summary
  echo
  print_color "blue" "=== Configuration Summary ==="
  log "INFO" "Docker Image: payramapp/payram:$IMAGE_TAG"
  log "INFO" "Network Mode: $NETWORK_TYPE"
  log "INFO" "Server Mode: $SERVER"
  log "INFO" "Database: $DB_HOST:$DB_PORT/$DB_NAME"
  log "INFO" "SSL Path: ${SSL_CERT_PATH:-Not configured}"
  echo
  
  print_color "yellow" "🔐 Security Architecture:"
  print_color "gray" "  • Hot wallet encryption: AES-256 (for withdrawal operations only)"
  print_color "gray" "  • Cold wallets: Keys never stored on server"
  print_color "gray" "  • Deposit wallets: Smart sweep technology, no keys stored"
  print_color "gray" "  • Database: Transaction history + encrypted hot wallet keys"
  echo
  
  print_color "blue" "💾 Persistent Storage:"
  print_color "gray" "  • Config & AES keys: $PAYRAM_INFO_DIR"
  print_color "gray" "  • Application data: $PAYRAM_CORE_DIR"
  print_color "gray" "  • Required space: 5GB minimum, 10GB recommended"
  print_color "gray" "  • Backup critical: AES key + database data"
  echo
  
  read -p "Press [Enter] to deploy PayRam container..."
  
  # Step 7: Deploy container
  if deploy_payram_container; then
    display_success_banner
    
    log "SUCCESS" "PayRam installation completed successfully! 🎉"
    
    # Display access URLs with both local and public options
    display_access_urls
    
    print_color "green" "📋 Next Steps:"
    print_color "gray" "  1. Complete setup via web interface"
    print_color "gray" "  2. Configure payment methods"
    print_color "gray" "  3. Set up merchant accounts"
    echo
    print_color "blue" "🛠️  Useful Commands:"
    print_color "gray" "  • View logs: docker logs payram"
    print_color "gray" "  • Update: sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --update"
    print_color "gray" "  • Restart: sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --restart"
    print_color "gray" "  • Reset: sudo /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/PayRam/payram-scripts/main/setup_payram.sh)\" bash --reset"
    echo
  else
    log "ERROR" "PayRam setup failed"
    log "INFO" "Check logs at: $LOG_FILE"
    log "INFO" "For support, visit: https://github.com/PayRam/payram-scripts/issues"
    exit 1
  fi
}

# Execute main function with all arguments
main "$@"


