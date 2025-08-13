#!/bin/bash
set -euo pipefail

# Check if script is run as root
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31mError: This script must be run as root (or with sudo).\033[0m"
    echo -e "\033[0;33mPlease run: sudo su\033[0m"
    echo -e "\033[0;33mThen try again.\033[0m"
    exit 1
  fi
}

# Execute root check immediately
check_root

# --- Default Configuration ---
DEFAULT_IMAGE_TAG="develop"
NETWORK_TYPE="mainnet"
SERVER="PRODUCTION"
IMAGE_TAG=""
POSTGRES_SSLMODE="prefer"
SSL_CERT_PATH=""
AES_KEY=""

# --- Helper Functions ---

# Function to display usage information
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "A script to manage the PayRam Docker container setup."
  echo ""
  echo "Options:"
  echo "  --update                 Update the container to the latest image version using existing settings."
  echo "  --reset                  Permanently delete the container, images, data, and configuration."
  echo "  --testnet                Set up a testnet environment (SERVER=DEVELOPMENT)."
  echo "  --tag=<tag>, -T=<tag>    Specify the Docker image tag to use. Defaults to release version."
  echo "  -h, --help               Show this help message."
}

# Function to print colored text
print_color() {
  case "$1" in
    "green") echo -e "\033[0;32m$2\033[0m" ;;
    "red") echo -e "\033[0;31m$2\033[0m" ;;
    "yellow") echo -e "\033[0;33m$2\033[0m" ;;
    "blue") echo -e "\033[0;34m$2\033[0m" ;;
    *)
      echo "$2"
      ;;
  esac
}

# Function to check and install dependencies for Ubuntu
check_and_install_dependencies() {
  print_color "blue" "Checking for required dependencies..."
  local dependencies=("docker" "psql")
  local missing_deps=()

  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      print_color "yellow" "Dependency '$dep' not found."
      missing_deps+=("$dep")
    else
      print_color "green" "✅ Dependency '$dep' is already installed."
    fi
  done

  if [ ${#missing_deps[@]} -gt 0 ]; then
    print_color "yellow" "Installing missing dependencies for Ubuntu..."
    
    if ! command -v sudo &> /dev/null; then
        print_color "red" "Error: 'sudo' command not found. Please install it or run this script as root."
        exit 1
    fi
    
    print_color "yellow" "Sudo privileges are required to install packages."
    sudo -v
    
    print_color "yellow" "Updating package lists..."
    sudo apt-get update -y > /dev/null 2>&1

    for dep in "${missing_deps[@]}"; do
      print_color "yellow" "Installing '$dep'..."
      case "$dep" in
        "docker")
          sudo apt-get install -y docker.io > /dev/null 2>&1
          sudo systemctl enable --now docker > /dev/null 2>&1
          sudo usermod -aG docker "$USER" > /dev/null 2>&1
          print_color "green" "✅ Docker installed successfully."
          print_color "yellow" "Note: You may need to log out and log back in for Docker group changes to take effect."
          ;;
        "psql")
          sudo apt-get install -y postgresql-client > /dev/null 2>&1
          print_color "green" "✅ PostgreSQL client installed successfully."
          ;;
      esac
    done
    print_color "green" "✅ All missing dependencies have been installed."
  else
    print_color "green" "All required dependencies are already installed."
  fi
  echo
}

# Function to test PostgreSQL connection
test_postgres_connection() {
  print_color "yellow" "\nAttempting to connect to the database..."
  
  # Use .pgpass file for secure password handling
  local pgpass_file=$(mktemp)
  echo "$DB_HOST:$DB_PORT:$DB_NAME:$DB_USER:$DB_PASSWORD" > "$pgpass_file"
  chmod 600 "$pgpass_file"
  
  # Use PGPASSFILE instead of PGPASSWORD
  if PGPASSFILE="$pgpass_file" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "\q" &>/dev/null; then
    rm -f "$pgpass_file"
    return 0 # Success
  else
    rm -f "$pgpass_file"
    return 1 # Failure
  fi
}

# Function to generate a secure AES key
generate_aes_key() {
  print_color "yellow" "Generating a new secure AES key..."
  AES_KEY=$(openssl rand -hex 32)
  
  # Also save the key to /home/ubuntu/.payraminfo/aes/ for legacy compatibility
  local aes_dir="/home/ubuntu/.payraminfo/aes"
  print_color "yellow" "Saving AES key to $aes_dir for legacy compatibility..."
  
  mkdir -p "$aes_dir"
  echo "AES_KEY=$AES_KEY" > "$aes_dir/$AES_KEY"
  print_color "green" "✅ AES key generated and saved."
}

# Function to save the configuration to a file
save_configuration() {
  local config_dir="/home/ubuntu/.payraminfo"
  local config_file="$config_dir/config.env"

  print_color "yellow" "\nSaving configuration to $config_file..."
  
  mkdir -p "$config_dir"

  # Set restrictive umask before creating the file
  umask 077

  # Write all relevant variables to the config file
  cat > "$config_file" << EOL
# PayRam Configuration - Do not edit manually unless you know what you are doing.
IMAGE_TAG="${IMAGE_TAG:-}"
NETWORK_TYPE="${NETWORK_TYPE:-}"
SERVER="${SERVER:-}"
AES_KEY="${AES_KEY:-}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
POSTGRES_SSLMODE="${POSTGRES_SSLMODE:-}"
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
EOL

  # Double-check permissions are set correctly
  chmod 600 "$config_file" || true
  print_color "green" "✅ Configuration saved (permissions 600)."
}

# Function to perform a full reset
reset_environment() {
  print_color "red" "WARNING: This will permanently delete the PayRam container, all associated Docker images, data volumes, and configuration."
  read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_color "yellow" "Reset cancelled."
    exit 1
  fi

  print_color "yellow" "\nStopping and removing 'payram' container..."
  docker stop payram &>/dev/null || true
  docker rm -v payram &>/dev/null || true

  print_color "yellow" "Removing all 'buddhasource/payram-core' Docker images..."
  docker images --filter=reference='buddhasource/payram-core' -q | xargs -r docker rmi -f

  print_color "yellow" "Deleting PayRam data and configuration directories..."
  # Use specific rm commands for safety and precision
  sudo rm -rf /home/ubuntu/.payram-core
  rm -rf /home/ubuntu/.payraminfo

  print_color "green" "\n✅ Reset complete. All PayRam data and configurations have been removed."
}

# Function to update the container using saved settings
update_container() {
  local config_file="/home/ubuntu/.payraminfo/config.env"
  print_color "blue" "Starting PayRam update process..."

  if ! test -f "$config_file"; then
    print_color "red" "Error: Configuration file not found at '$config_file'."
    print_color "yellow" "Please run the initial setup first (without the --update flag)."
    exit 1
  fi

  print_color "yellow" "Loading existing configuration from $config_file..."
  # Store the user-provided tag BEFORE loading config
  local user_provided_tag="$IMAGE_TAG"
  
  # Load the config but save IMAGE_TAG separately first
  source "$config_file"
  local current_tag="$IMAGE_TAG"
  
  # Set target tag based on user input or default
  local target_tag
  if [[ -n "$user_provided_tag" ]]; then
    target_tag="$user_provided_tag"
  else
    target_tag="$DEFAULT_IMAGE_TAG"
  fi

  print_color "green" "✅ Configuration loaded."
  echo
  
  # # Check if current and target versions are the same
  # if [[ "$current_tag" == "$target_tag" ]]; then
  #   print_color "blue" "--- Version Check ---"
  #   print_color "yellow" "Current installed version: $current_tag"
  #   print_color "yellow" "Target version: $target_tag"
  #   print_color "green" "\n✅ You are already using the latest version ($current_tag)."
  #   print_color "yellow" "No update needed. Exiting..."
  #   exit 0
  # fi
  
  print_color "blue" "--- Tag Selection ---"
  print_color "yellow" "Current installed version: $current_tag"
  print_color "yellow" "Target version: $target_tag"
  echo
  
  # Always show selection menu
  PS3='Please choose which tag to use for the update: '
  options=("Use target tag: $target_tag (new version)" "Use existing tag: $current_tag (current version)" "Don't update (cancel)")
  select opt in "${options[@]}"
  do
    case $opt in
      "${options[0]}")
        IMAGE_TAG="$target_tag"
        break
        ;;
      "${options[1]}")
        IMAGE_TAG="$current_tag"
        break
        ;;
      "${options[2]}")
        print_color "yellow" "\nUpdate cancelled by user."
        exit 0
        ;;
      *)
        print_color "red" "Invalid option $REPLY"
        ;;
    esac
  done

  # Show configuration summary
  echo
  print_color "blue" "--- Update Configuration Summary ---"
  print_color "yellow" "Docker Image Tag: $IMAGE_TAG"
  print_color "yellow" "Network Type: $NETWORK_TYPE"
  print_color "yellow" "Server Mode: $SERVER"
  print_color "yellow" "Database Host: $DB_HOST"
  print_color "yellow" "Database Port: $DB_PORT"
  print_color "yellow" "Database Name: $DB_NAME"
  if [[ -n "$SSL_CERT_PATH" ]]; then
    print_color "yellow" "SSL Certificate Path: $SSL_CERT_PATH"
  else
    print_color "yellow" "SSL Certificate Path: Not configured"
  fi
  print_color "blue" "--------------------------------"
  echo

  read -p "Press [Enter] to proceed with the update..."

  print_color "yellow" "\nUpdating to image: buddhasource/payram-core:$IMAGE_TAG..."
  
  # Call the run function with the selected settings
  run_docker_container
  exit 0
}

# Function to validate a Docker image tag
validate_docker_tag() {
  local tag_to_check=$1
  print_color "yellow" "\nValidating Docker tag: $tag_to_check..."
  if docker manifest inspect "buddhasource/payram-core:$tag_to_check" >/dev/null 2>&1; then
    print_color "green" "✅ Tag '$tag_to_check' is valid."
    return 0
  else
    print_color "red" "❌ Error: Docker tag '$tag_to_check' not found in the repository. Please provide a valid tag."
    return 1
  fi
}

# Function to run the Docker container
run_docker_container() {
  # Validate the Docker tag before proceeding
  if ! validate_docker_tag "$IMAGE_TAG"; then
    exit 1
  fi

  print_color "yellow" "\nStopping and removing existing 'payram' container..."
  docker stop payram &>/dev/null || true
  docker rm payram &>/dev/null || true

  print_color "yellow" "Removing all 'buddhasource/payram-core' Docker images..."
  docker images --filter=reference='buddhasource/payram-core' -q | xargs -r docker rmi -f

  print_color "yellow" "Pulling the Docker image: buddhasource/payram-core:$IMAGE_TAG..."
  if ! docker pull "buddhasource/payram-core:$IMAGE_TAG"; then
    print_color "red" "\n❌ Failed to pull the Docker image. Please check the image tag and your internet connection."
    exit 1
  fi

  # Generate AES key and save configuration AFTER successful image pull
  if [[ -z "$AES_KEY" ]]; then
    generate_aes_key
  else
    print_color "yellow" "Using existing AES key from configuration."
  fi
  save_configuration

  print_color "yellow" "Starting the PayRam container..."
  docker run -d \
    --name payram \
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
    -v /home/ubuntu/.payram-core:/root/payram \
    -v /home/ubuntu/.payram-core/log/supervisord:/var/log \
    -v /home/ubuntu/.payram-core/db/postgres:/var/lib/payram/db/postgres \
    -v /etc/letsencrypt:/etc/letsencrypt \
    "buddhasource/payram-core:$IMAGE_TAG"

  # --- Confirmation ---
  sleep 5 # Give the container a moment to start
  if docker ps --filter name=payram --filter status=running --format '{{.Names}}' | grep -wq '^payram$'; then
    print_color "green" "\n✅ PayRam container is now running successfully!"
  else
    print_color "red" "\n❌ Failed to start the PayRam container. Please check the Docker logs for more information."
    exit 1
  fi
}

# Function to configure the database
configure_database() {
  PS3='Please enter your choice: '
  options=("Use my own external PostgreSQL database (recommended)" "Use the default PayRam database")
  select opt in "${options[@]}"
  do
      case $opt in
          "${options[0]}")
              while true; do
                echo
                read -p "Enter Database Host: " DB_HOST
                read -p "Enter Database Port [5432]: " DB_PORT
                DB_PORT=${DB_PORT:-5432}
                read -p "Enter Database Name: " DB_NAME
                read -p "Enter Database Username: " DB_USER
                read -s -p "Enter Database Password: " DB_PASSWORD
                echo

                if test_postgres_connection; then
                  print_color "green" "\n✅ Database connection successful!"
                  break
                else
                  print_color "red" "\n❌ Connection failed. Please check your details and try again."
                fi
              done
              break
              ;;
          "${options[1]}")
              print_color "green" "\nUsing default database configuration."
              DB_HOST="localhost"
              DB_PORT="5432"
              DB_NAME="payram"
              DB_USER="payram"
              DB_PASSWORD="payram123"
              break
              ;;
          *)
            print_color "red" "Invalid option $REPLY"
            ;;
      esac
  done
}

# Function to configure SSL certificate path
configure_ssl_path() {
  echo
  PS3='Please enter your choice: '
  options=("Configure SSL certificates (Let's Encrypt, etc.)" "Skip SSL or use cloud services (Cloudflare, AWS, GoDaddy)")
  select opt in "${options[@]}"
  do
      case $opt in
          "${options[0]}")
              print_color "green" "\nSSL certificate configuration selected."
              print_color "yellow" "Please provide the path where your SSL certificate files are located."
              print_color "yellow" "Expected files: fullchain.pem and privkey.pem"
              while true; do
                echo
                read -p "Enter SSL certificate directory path: " SSL_CERT_PATH
                
                # Check if path exists
                if [[ ! -d "$SSL_CERT_PATH" ]]; then
                  print_color "red" "❌ Directory '$SSL_CERT_PATH' does not exist."
                  read -p "Do you want to try again? (y/N) " -n 1 -r
                  echo
                  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    SSL_CERT_PATH=""
                    break
                  fi
                  continue
                fi
                
                # Check if directory is readable
                if [[ ! -r "$SSL_CERT_PATH" ]]; then
                  print_color "red" "❌ Directory '$SSL_CERT_PATH' is not readable."
                  read -p "Do you want to try again? (y/N) " -n 1 -r
                  echo
                  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    SSL_CERT_PATH=""
                    break
                  fi
                  continue
                fi
                
                # Check for required SSL certificate files
                print_color "yellow" "\nChecking for SSL certificate files in '$SSL_CERT_PATH'..."
                local found_files=()
                local required_files=("fullchain.pem" "privkey.pem")
                local missing_required=()
                
                for file in "${required_files[@]}"; do
                  if [[ -f "$SSL_CERT_PATH/$file" ]]; then
                    if [[ -r "$SSL_CERT_PATH/$file" ]]; then
                      found_files+=("$file")
                      print_color "green" "✅ Found: $file"
                    else
                      print_color "red" "❌ Found but not readable: $file"
                      missing_required+=("$file")
                    fi
                  else
                    print_color "red" "❌ Missing required file: $file"
                    missing_required+=("$file")
                  fi
                done
                
                # Check for additional SSL files (optional)
                local additional_files=("cert.pem" "certificate.pem" "key.pem" "private.key" "chain.pem" "ca.pem")
                for file in "${additional_files[@]}"; do
                  if [[ -f "$SSL_CERT_PATH/$file" ]]; then
                    if [[ -r "$SSL_CERT_PATH/$file" ]]; then
                      found_files+=("$file")
                      print_color "green" "✅ Found additional: $file"
                    else
                      print_color "yellow" "⚠️  Found but not readable: $file"
                    fi
                  fi
                done
                
                if [[ ${#missing_required[@]} -gt 0 ]]; then
                  print_color "red" "\n❌ Missing required SSL files: ${missing_required[*]}"
                  print_color "yellow" "Please ensure fullchain.pem and privkey.pem are present in the directory."
                  read -p "Do you want to try again? (y/N) " -n 1 -r
                  echo
                  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    SSL_CERT_PATH=""
                    break
                  fi
                  continue
                fi
                
                print_color "green" "\n✅ SSL certificate path validated successfully!"
                print_color "yellow" "Found ${#found_files[@]} SSL file(s) in '$SSL_CERT_PATH'"
                print_color "green" "Required files (fullchain.pem, privkey.pem) are present."
                break
              done
              break
              ;;
          "${options[1]}")
              print_color "yellow" "\nSkipping SSL configuration."
              print_color "blue" "Note: You can configure SSL later using cloud services like:"
              print_color "blue" "  • Cloudflare SSL/TLS"
              print_color "blue" "  • AWS Certificate Manager"
              print_color "blue" "  • GoDaddy SSL Certificates"
              print_color "blue" "  • Other SSL providers"
              SSL_CERT_PATH=""
              break
              ;;
          *)
            print_color "red" "Invalid option $REPLY"
            ;;
      esac
  done
}

# --- Main Logic ---

main() {
  check_and_install_dependencies

  # --- Argument Parsing ---
  local UPDATE_FLAG=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update)
        UPDATE_FLAG=true
        shift # past argument
        ;;
      --reset)
        reset_environment
        exit 0
        ;;
      --testnet)
        NETWORK_TYPE="testnet"
        SERVER="DEVELOPMENT"
        shift # past argument
        ;;
      --tag=*|-T=*)
        IMAGE_TAG="${1#*=}"
        shift # past argument
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        print_color "red" "Error: Unknown option '$1'"
        usage
        exit 1
        ;;
    esac
  done
  
  # Process update after all arguments are parsed
  if [[ "$UPDATE_FLAG" = true ]]; then
    update_container
  fi

  # --- Pre-flight Check for Interactive Mode ---
  if docker ps --filter "name=^payram$" --filter "status=running" --format "{{.Names}}" | grep -q "payram"; then
    print_color "red" "Error: A 'payram' container is already running."
    print_color "yellow" "If you want to update it, use the '--update' flag."
    print_color "yellow" "If you want to start over, use the '--reset' flag first."
    exit 1
  fi

  # --- Finalize and Validate Configuration ---
  if [[ -z "$IMAGE_TAG" ]]; then
    IMAGE_TAG=$DEFAULT_IMAGE_TAG # Default to 1.5.1 if no tag is specified
  fi

  # --- Interactive Setup ---
  print_color "blue" "======================================"
  print_color "blue" " Welcome to the PayRam Setup Utility"
  print_color "blue" "======================================"
  echo

  configure_database
  configure_ssl_path

  # --- Pre-run Summary ---
  echo
  print_color "blue" "--- Configuration Summary ---"
  print_color "yellow" "Docker Image: buddhasource/payram-core:$IMAGE_TAG"
  print_color "yellow" "Network Mode: $NETWORK_TYPE"
  print_color "yellow" "Database Host: $DB_HOST"
  print_color "yellow" "Server: $SERVER"
  if [[ -n "$SSL_CERT_PATH" ]]; then
    print_color "yellow" "SSL Certificate Path: $SSL_CERT_PATH"
  else
    print_color "yellow" "SSL Certificate Path: Not configured"
  fi
  print_color "blue" "---------------------------"
  echo

  read -p "Press [Enter] to continue with the setup..."

  # --- Run Docker ---
  run_docker_container
}

# Execute the main function
main "$@"

