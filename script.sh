#!/bin/bash
set -euo pipefail

####################################
# OS Detection and Dependency Installation
####################################

reset_dependencies() {
  local CONTAINER_NAME="payram"
  local IMAGE_NAME="buddhasource/payram-core:develop"

  # Stop the container if it's running.
  if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Stopping running container: ${CONTAINER_NAME}..."
    docker stop "${CONTAINER_NAME}"
  else
    echo "Container ${CONTAINER_NAME} is not running."
  fi

  # Remove the container along with its volumes.
  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Removing container and its volumes: ${CONTAINER_NAME}..."
    docker rm -v "${CONTAINER_NAME}"
  else
    echo "Container ${CONTAINER_NAME} does not exist."
  fi

  # Remove the Docker image.
  if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
    echo "Removing Docker image: ${IMAGE_NAME}..."
    docker rmi "${IMAGE_NAME}"
  else
    echo "Docker image ${IMAGE_NAME} not found."
  fi

  # Remove associated files/directories (.payram-core and .payram)
  echo "Searching and deleting .payram-core and .payram files/directories..."
  sudo find / -type d \( -name ".payram-core" -o -name ".payram" \) -prune -exec rm -rf {} \; 2>/dev/null || true
  sudo find / -type f \( -name ".payram-core" -o -name ".payram" \) -prune -exec rm -f {} \; 2>/dev/null || true

  echo "Container, image, volumes, and associated files have been permanently removed."
}

update_container() {
  local CONTAINER_NAME="payram"
  local IMAGE_NAME="buddhasource/payram-core:develop"

  echo "🚀 Stopping and removing existing container..."
  docker stop "${CONTAINER_NAME}" 2>/dev/null || true
  docker rm "${CONTAINER_NAME}" 2>/dev/null || true

  echo "🗑️ Removing existing image..."
  docker rmi -f "${IMAGE_NAME}" 2>/dev/null || true

  echo "📥 Pulling the latest image..."
  docker pull "${IMAGE_NAME}"

  # Generate an AES key (32 bytes for AES-256)
  aes_key=$(openssl rand -hex 32)
  echo "Generated AES key: $aes_key"

  sudo bash -c "echo \"AES_KEY=$aes_key\" > /.payram/aes/$aes_key"
  echo "AES key saved to /.payram/aes/$aes_key"

  echo "🔄 Running a new container..."
   docker run -d \
    --name ${CONTAINER_NAME} \
    --publish 8080:8080 \
    --publish 8443:8443 \
    --publish 80:80 \
    --publish 443:443 \
    -e AES_KEY="$aes_key" \
    -e BLOCKCHAIN_NETWORK_TYPE=testnet \
    -e SERVER=DEVELOPMENT \
    -v /home/ubuntu/.payram-core:/root/payram \
    -v /home/ubuntu/.payram-core/log/supervisord:/var/log \
    -v /etc/letsencrypt:/etc/letsencrypt \
    ${IMAGE_NAME}

  echo "✅ Update complete! Payram is now running with the latest version."
}

# Execute the appropriate function based on command-line arguments.
if [[ "${1:-}" == "--reset" ]]; then
  reset_dependencies
  exit 0
fi

if [[ "${1:-}" == "--update" ]]; then
  update_container
  exit 0
fi


if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS=$ID
  VERSION=$VERSION_ID
elif [[ -f /etc/centos-release ]]; then
  OS="centos"
  VERSION=$(awk '{print $4}' /etc/centos-release)
elif [[ -f /etc/redhat-release ]]; then
  OS="rhel"
  VERSION=$(awk '{print $7}' /etc/redhat-release)
elif [[ "$(uname)" == "Darwin" ]]; then
  OS="macos"
  VERSION=$(sw_vers -productVersion)
else
  OS="unknown"
  VERSION="unknown"
fi

echo "Detected OS: $OS"
echo "Version: $VERSION"
echo ""

############################
# Utility Function: Check if a command is installed
############################
is_installed() {
  command -v "$1" &>/dev/null
}

############################
# Dependency Installation Functions
############################
install_docker() {
  if is_installed docker; then
    echo "✅ Docker is already installed."
  else
    echo "🚀 Installing Docker..."
    case "$OS" in
      ubuntu|debian)
        sudo apt update && sudo apt install -y docker.io
        ;;
      amzn|centos|rhel)
        sudo yum update -y && sudo yum install -y docker
        ;;
      macos)
        brew install --cask docker
        ;;
      *)
        echo "❌ OS not supported for Docker installation."
        exit 1
        ;;
    esac
    sudo systemctl enable docker
    sudo systemctl start docker
    echo "✅ Docker installed successfully."
  fi
}

install_sqlite() {
  if is_installed sqlite3; then
    echo "✅ SQLite is already installed."
  else
    echo "🚀 Installing SQLite..."
    case "$OS" in
      ubuntu|debian)
        sudo apt update && sudo apt install -y sqlite3
        ;;
      amzn|centos|rhel)
        sudo yum update -y && sudo yum install -y sqlite
        ;;
      macos)
        brew install sqlite
        ;;
      *)
        echo "❌ OS not supported for SQLite installation."
        exit 1
        ;;
    esac
    echo "✅ SQLite installed successfully."
  fi
}

install_jq() {
  if is_installed jq; then
    echo "✅ jq is already installed."
  else
    echo "🚀 Installing jq..."
    case "$OS" in
      ubuntu|debian)
        sudo apt update && sudo apt install -y jq
        ;;
      amzn|centos|rhel)
        sudo yum update -y && sudo yum install -y jq
        ;;
      macos)
        brew install jq
        ;;
      *)
        echo "❌ OS not supported for jq installation."
        exit 1
        ;;
    esac
    echo "✅ jq installed successfully."
  fi
}

install_yq() {
  if is_installed yq; then
    echo "✅ yq is already installed."
  else
    echo "🚀 Installing yq..."
    case "$OS" in
      ubuntu|debian)
        # Installing yq manually if snap is not available
        if ! is_installed snap; then
          curl -Lo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.15.1/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq
        else
          sudo snap install yq
        fi
        ;;
      amzn|centos|rhel)
        # Use the manual method for RHEL/CentOS if yq is not in the repos
        curl -Lo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.15.1/yq_linux_amd64
        sudo chmod +x /usr/local/bin/yq
        ;;
      macos)
        brew install yq
        ;;
      *)
        echo "❌ OS not supported for yq installation."
        exit 1
        ;;
    esac
    echo "✅ yq installed sucrestart_dependencies() {
  local CONTAINER_NAME="payram"
  local IMAGE_NAME="buddhasource/payram-core:develop"

  # Stop the container if it's running.
  if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Stopping running container: ${CONTAINER_NAME}..."
    docker stop "${CONTAINER_NAME}"
  else
    echo "Container ${CONTAINER_NAME} is not running."
  fi

  # Remove the container along with its volumes.
  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Removing container and its volumes: ${CONTAINER_NAME}..."
    docker rm -v "${CONTAINER_NAME}"
  else
    echo "Container ${CONTAINER_NAME} does not exist."
  fi

  # Remove the Docker image.
  if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
    echo "Removing Docker image: ${IMAGE_NAME}..."
    docker rmi "${IMAGE_NAME}"
  else
    echo "Docker image ${IMAGE_NAME} not found."
  fi

  # Remove associated files/directories (.payram-core and .payram)
  echo "Searching and deleting .payram-core and .payram files/directories..."
  sudo find / -type d \( -name ".payram-core" -o -name ".payram" \) -prune -exec rm -rf {} \; 2>/dev/null || true
  sudo find / -type f \( -name ".payram-core" -o -name ".payram" \) -prune -exec rm -f {} \; 2>/dev/null || true

  echo "Container, image, volumes, and associated files have been permanently removed."
}

# Execute the function only if "restart" is passed as the first argument.
if [[ "${1:-}" == "restart" ]]; then
  restart_dependencies
  exit 0
else
  echo "Usage: $0 restart"
  exit 1
fi
cessfully."
  fi
}

############################
# Setup Hidden State File (/.payram/state.txt)
############################
check_STATE_FILE() {
  local dir="/.payram"
  local file="$dir/state.txt"

  if [[ ! -d "$dir" ]]; then
    echo "Hidden directory $dir does not exist. Creating now..."
    sudo mkdir -p "$dir"
  else
    echo "Hidden directory $dir already exists."
  fi

  if [[ ! -f "$file" ]]; then
    echo "File $file does not exist. Creating now..."
    sudo touch "$file"
  else
    echo "File $file already exists."
  fi
}

############################
# Install Dependencies if Not Already Done
############################
install_dependencies() {
  local STATE_FILE="/.payram/state.txt"

  if grep -q "dependencies_installed" "$STATE_FILE"; then
    echo "Dependencies have already been installed (flag found in $STATE_FILE)."
    return
  fi

  install_docker
  install_sqlite
  install_jq
  install_yq

  echo "dependencies_installed" | sudo tee -a "$STATE_FILE" >/dev/null
  echo "State updated: dependencies have been installed."
}

############################
# Pull and Run Docker Container if Not Already Runningconfig
############################
run_docker_container() {
  if docker ps --format '{{.Names}}' | grep -wq '^payram$'; then
    echo "Docker container 'payram' is already running."
    return
  fi

  echo "Container 'payram' is not running. Proceeding to pull and run the container..."

  # Generate an AES key (32 bytes for AES-256)
  aes_key=$(openssl rand -hex 32)
  echo "Generated AES key: $aes_key"

  # Create the directory for storing the AES key if it doesn't exist
  if [[ ! -d "/.payram/aes" ]]; then
    sudo mkdir -p "/.payram/aes"
  fi

  # Save the AES key to a file with the key name and content "AES_KEY=<generated_key>"
  sudo bash -c "echo \"AES_KEY=$aes_key\" > /.payram/aes/$aes_key"
  echo "AES key saved to /.payram/aes/$aes_key"

  # Run the Docker container
  docker run -d \
    --name payram \
    --publish 8080:8080 \
    --publish 8443:8443 \
    --publish 80:80 \
    --publish 443:443 \
    -e AES_KEY="$aes_key" \
    -e BLOCKCHAIN_NETWORK_TYPE=testnet \
    -e SERVER=DEVELOPMENT \
    -v /home/ubuntu/.payram-core:/root/payram \
    -v /home/ubuntu/.payram-core/log/supervisord:/var/log \
    -v /etc/letsencrypt:/etc/letsencrypt \
    buddhasource/payram-core:develop

  if docker ps --filter name=payram --filter status=running --format '{{.Names}}' | grep -wq '^payram$'; then
    echo "Docker container 'payram' is now running."
    sudo bash -c "echo 'docker_container_running' >> /.payram/state.txt"
  else
    echo "Failed to start docker container 'payram'."
  fi
}

############################
# Main Execution for OS/Dependency/Docker Setup
############################
check_STATE_FILE
install_dependencies
run_docker_container

echo ""
echo "🔍 Verifying installations..."
docker --version && sqlite3 --version && jq --version && yq --version
echo "🎉 Setup complete!"




process_projects() {
    CONFIG_FILE="config.yaml"
    STATE_FILE="/.payram/state.txt"  
    API_URL="http://localhost:8080/api/v1/external-platform"
    
    perform_request() {
        description="$1"
        shift
        response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$@")
        body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
        http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        >&2 echo "$description Response:"
        # >&2 echo "$body"
        >&2 echo "HTTP Status: $http_code  in th perform_request function"
        echo "$body"  # Return the body so it can be processed
    }

    perform_request_http() {  
        description="$1"
        shift
        response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$@")
        body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
        http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        >&2 echo "$description Response:"
        # >&2 echo "$body"
        >&2 echo "HTTP Status: $http_code  in th perform_request function"
        echo "$http_code"  # Return the http_code so it can be processed
    }

    # Function to update the state file
    update_state() {
        flag="$1"
        echo "Updating state with flag: $flag"  # Debug output
        sudo bash -c "echo '$flag' >> $STATE_FILE"
    }

    project_keys=$(yq eval '.projects | keys' "$CONFIG_FILE" | sed 's/- //g')
    
    # Iterate over each project key (like project1, project2)
    for project_key in $project_keys; do
        # Check if this project has already been processed by looking for the flag (e.g., project1_done)
        flag="${project_key}_done"
        echo "Checking if $project_key has already been processed"
        if grep -q "$flag" "$STATE_FILE"; then
            echo "Skipping $project_key (already processed)"
            continue
        fi

        echo "Preparing data for $project_key"

        # Fetch project details under each project (e.g., name, website, etc.)
        project_name=$(yq eval ".projects.${project_key}.name" "$CONFIG_FILE")
        project_website=$(yq eval ".projects.${project_key}.website" "$CONFIG_FILE")
        success_endpoint=$(yq eval ".projects.${project_key}.successEndpoint" "$CONFIG_FILE")
        webhook_endpoint=$(yq eval ".projects.${project_key}.webhookEndpoint" "$CONFIG_FILE")

        # Build the JSON body
        json_data=$(cat <<EOF
{
    "name": "$project_name",
    "website": "$project_website",
    "successEndpoint": "$success_endpoint",
    "webhookEndpoint": "$webhook_endpoint"
}
EOF
)

        # Send the first request using perform_request with --data-raw
        echo "Sending request for $project_key"
        response=$(perform_request "Sending data for $project_key" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --data-raw "$json_data" \
            "$API_URL")

        # Check if the response is valid JSON and contains the "id" field
        if echo "$response" | jq empty >/dev/null 2>&1; then
            platform_id=$(echo "$response" | jq -r '.id')

            # Check if platform_id is a valid integer
            if [[ "$platform_id" =~ ^[0-9]+$ ]]; then
                echo "Request successful for $project_key"
                echo "Extracted platform ID: $platform_id"

                # Send the second request with the extracted ID
                second_request_data=$(cat <<EOF
{
    "externalPlatformID": $platform_id,
    "roleName": "platform_admin"
}
EOF
)
                echo "Sending second request for $project_key with externalPlatformID $platform_id"
                second_response=$(perform_request_http "Sending API key data for $project_key" \
                    --header "API-Key: $API_KEY" \
                    --header "Content-Type: application/json" \
                    --data-raw "$second_request_data" \
                    "http://localhost:8080/api/v1/api-key")

                # Extract the HTTP status from the second request's response
                second_http_code=$(echo "$second_response" | tail -n 1)
                echo "Second request HTTP Status: $second_http_code"
                # Check if the second request was successful
                if [[ "$second_http_code" -eq 200 || "$second_http_code" -eq 201 ]]; then
                    echo "Second request successful for $project_key. Updating state."
                    update_state "$flag"  # This should update the state file
                else
                    echo "Second request failed for $project_key. HTTP Status: $second_http_code"
                fi
            else
                echo "Error: platform_id is not a valid integer. Response: $response"
            fi
        else
            echo "Error: Response is not valid JSON. Response: $response"
        fi

        echo -e "\nFinished processing $project_key\n"
    done
}

####################################
# API Requests Section (wrapped in a function)
####################################

validate_config() {
  local CONFIG_FILE="${1:-config.yaml}"

  check_top_level_key() {
    local key="$1"
    local line
    line=$(grep -E "^[[:space:]]*$key:[[:space:]]*" "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$line" ]; then
      echo "Error: '$key' not found or missing in $CONFIG_FILE"
      exit 1
    fi
    local value="${line#*:}"
    value=$(echo "$value" | xargs)
    if [ -z "$value" ] || [ "$value" = "\"\"" ]; then
      echo "Error: '$key' is empty in $CONFIG_FILE"
      exit 1
    fi
  }

  check_top_level_key "payram.backend"
  check_top_level_key "payram.frontend"
  check_top_level_key "postal.endpoint"
  check_top_level_key "postal.apikey"
  check_top_level_key "ssl"

  local projects_block
  projects_block=$(
    awk '
      /^projects:/ { flag=1; next }
      /^[^[:space:]]/ { flag=0 }
      flag { print }
    ' "$CONFIG_FILE"
  )

  if [ -z "$projects_block" ]; then
    echo "Error: No 'projects:' block found or it is empty in $CONFIG_FILE"
    exit 1
  fi

  check_project_block() {
    local pblock="$1"
    for required_key in name website successEndpoint webhookEndpoint; do
      local line
      line=$(echo "$pblock" | grep -E "^[[:space:]]*$required_key:[[:space:]]*")
      if [ -z "$line" ]; then
        echo "Error: '$required_key' is missing in this project block:"
        echo "$pblock"
        exit 1
      fi
      local value="${line#*:}"
      value=$(echo "$value" | xargs)
      if [ -z "$value" ] || [ "$value" = "\"\"" ]; then
        echo "Error: '$required_key' is empty in this project block:"
        echo "$pblock"
        exit 1
      fi
    done
  }

  local current_project=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*project[0-9]+: ]]; then
      if [ -n "$current_project" ]; then
        check_project_block "$current_project"
      fi
      current_project="$line"
    else
      if [ -n "$current_project" ]; then
        current_project="$current_project
$line"
      fi
    fi
  done <<< "$projects_block"

  if [ -n "$current_project" ]; then
    check_project_block "$current_project"
  fi

  
}


run_api_requests() {

  CONFIG_FILE="config.yaml"
  STATE_FILE="/.payram/state.txt"  # using the same hidden state file

  validate_config $CONFIG_FILE

  update_blockchain_eth_explorer_address=$(yq e '.blockchain.ETH.explorer_address' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_eth_explorer_transaction=$(yq e '.blockchain.ETH.explorer_transaction' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_eth_min_confirmations=$(yq e '.blockchain.ETH.min_confirmations' "$CONFIG_FILE" | tr -d '\n' | xargs)
  
  update_blockchain_btc_client=$(yq e '.blockchain.BTC.client' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_btc_server=$(yq e '.blockchain.BTC.server' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_btc_server_username=$(yq e '.blockchain.BTC.server_username' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_btc_server_password=$(yq e '.blockchain.BTC.server_password' "$CONFIG_FILE" | tr -d '\n' | xargs)
  
  update_blockchain_trx_client=$(yq e '.blockchain.TRX.client' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_trx_server=$(yq e '.blockchain.TRX.server' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_trx_server_api_key=$(yq e '.blockchain.TRX.server_api_key' "$CONFIG_FILE" | tr -d '\n' | xargs)
  update_blockchain_trx_height=$(yq e '.blockchain.TRX.height' "$CONFIG_FILE" | tr -d '\n' | xargs)

  # List of required variables
  required_vars=(
    "$update_blockchain_eth_explorer_address"
    "$update_blockchain_eth_explorer_transaction"
    "$update_blockchain_eth_min_confirmations"
    "$update_blockchain_btc_client"
    "$update_blockchain_btc_server"
    "$update_blockchain_btc_server_username"
    "$update_blockchain_btc_server_password"
    "$update_blockchain_trx_client"
    "$update_blockchain_trx_server"
    "$update_blockchain_trx_server_api_key"
    "$update_blockchain_trx_height"
  )

  # Loop through and exit if any are empty
  for var in "${required_vars[@]}"; do
    if [ -z "$var" ]; then
      
      echo "Error: Missing required configuration. Exiting." >&2

      echo "Please fill all the details in the conig.yaml file"
      exit 1
    fi
  done



  echo "Loading API variables from config.yaml (for non-credential values)"
  
  read -p "Enter your email: " USER_EMAIL

  read -s -p "Enter your password: " USER_PASSWORD
  echo ""
  read -s -p "Confirm your password: " CONFIRM_PASSWORD
  echo ""

# Check if the entered passwords match
if [ "$USER_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
  echo "Passwords do not match. Exiting."
  exit 1
fi

  
  # Override email and password with user input
  EMAIL="$USER_EMAIL"
  PASSWORD="$USER_PASSWORD"
  
  # Load remaining configuration values from config file
  BASE_URL="http://localhost:8080"

  

  
  # update_blockchain_eth_server_api_key=$(yq e '.blockchain.ETH.server_api_key' "$CONFIG_FILE" | tr -d '\n' | xargs)
  # update_blockchain_eth_height=$(yq e '.blockchain.ETH.height' "$CONFIG_FILE" | tr -d '\n' | xargs)
  # update_blockchain_btc_height=$(yq e '.blockchain.BTC.height' "$CONFIG_FILE" | tr -d '\n' | xargs)

  
 
  
  x_pub_Ethereum=$(yq e '.wallets.Ethereum.xpub' "$CONFIG_FILE" | tr -d '\n' | xargs)
  x_pub_Bitcoin=$(yq e '.wallets.Bitcoin.xpub' "$CONFIG_FILE" | tr -d '\n' | xargs)
  x_pub_TRX=$(yq e '.wallets.Trx.xpub' "$CONFIG_FILE" | tr -d '\n' | xargs)

  x_pub_Ethereum_address=$(yq e '.wallets.Ethereum.deposit_addresses_count' "$CONFIG_FILE" | tr -d '\n' | xargs)
  x_pub_Bitcoin_address=$(yq e '.wallets.Bitcoin.deposit_addresses_count' "$CONFIG_FILE" | tr -d '\n' | xargs)
  x_pub_Trx_address=$(yq e '.wallets.Trx.deposit_addresses_count' "$CONFIG_FILE" | tr -d '\n' | xargs)

  
  echo 
  
  echo "All API variables loaded successfully"
  echo ""
  echo "Starting the API requests"
  echo ""
  
  #########################
  # Helper function to update the state
  #########################
  update_state() {
      flag="$1"
      sudo bash -c "echo '$flag' >> $STATE_FILE"
  }
  
  #########################
  # Helper function to perform a request and print response
  # All details are printed to stderr so that command substitution
  # returns only the numeric HTTP status code.
  #########################
  perform_request() {
      description="$1"
      shift
      response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$@")
      body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
      http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
      >&2 echo "$description Response:"
      >&2 echo "$body"
      >&2 echo "HTTP Status: $http_code"
      echo "$http_code"
  }
  
  #########################
  # Helper function to check required parameters.
  # Expects pairs: fieldName value ...
  #########################
  check_params() {
      local missing=0
      while [ "$#" -gt 0 ]; do
          local field="$1"
          local value="$2"
          if [ -z "$value" ]; then
              echo "Error: Required parameter '$field' is missing." >&2
              missing=1
          fi
          shift 2
      done
      return $missing
  }
  
  echo "Email set to: $EMAIL"
  echo "Password set to: [hidden]"
  
  #########################
  # Signup
  #########################
 if ! grep -q "signup_done" "$STATE_FILE"; then
    if check_params "email" "$EMAIL" "password" "$PASSWORD"; then
        echo "Signing up"
        
        # Perform the signup request
        signup_response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" 'http://localhost:8080/api/v1/signup' \
               --header 'Content-Type: application/json' \
               --data-raw "{
                  \"email\": \"$EMAIL\",
                  \"password\": \"$PASSWORD\"
               }")
        
        # Extract response body and HTTP status code
        signup_body=$(echo "$signup_response" | sed -e 's/HTTPSTATUS\:.*//g')
        signup_code=$(echo "$signup_response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        
        # Output the signup response and status code
        echo "Signup Response:"
        echo "$signup_body"
        echo "HTTP Status: $signup_code"
        echo ""
        
        # If status code is 400, forcefully exit the script
        if [ "$signup_code" -eq 400 ]; then
            echo "Bad Request: Invalid data format or missing parameters. Forcefully exiting the script."
            exit 1
        fi
        
        # Update the state if signup is successful
        update_state "signup_done"
    else
        echo "Skipping signup because required parameters are missing."
    fi
else
    echo "Signup already done; skipping."
    echo ""
fi

  
  #########################
  # Signin & Extract API Key (for this session)
  #########################
if check_params "email" "$EMAIL" "password" "$PASSWORD"; then
    echo "Signing in"
    
    # Perform the sign-in request
    signin_response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" 'http://localhost:8080/api/v1/signin' \
               --header 'Content-Type: application/json' \
               --data-raw "{
                  \"email\": \"$EMAIL\",
                  \"password\": \"$PASSWORD\"
               }")
    
    # Extract response body and HTTP status code
    signin_body=$(echo "$signin_response" | sed -e 's/HTTPSTATUS\:.*//g')
    signin_code=$(echo "$signin_response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    
    # Output the sign-in response and status code
    echo "Signin Response:"
    echo "$signin_body"
    echo "HTTP Status: $signin_code"
    echo ""
    
    # If status code is 401, forcefully exit the script
    if [ "$signin_code" -eq 401 ] || [ "$signin_code" -eq 400 ]; then
        echo "Unauthorized or Bad Request: Invalid credentials or request format. Forcefully exiting the script."
        exit 1
    fi
    
    # Extract API key if signin is successful
    API_KEY=$(echo "$signin_body" | jq -r '.key')
    echo "Extracted API key: $API_KEY"
    echo ""
else
    echo "Skipping signin because required parameters are missing."
fi

  
  yq eval '.configuration | to_entries | .[] | "\(.key)=\(.value)"' $CONFIG_FILE | while read -r line; do
      # Parse the key-value pair
      key=$(echo "$line" | cut -d '=' -f 1)
      value=$(echo "$line" | cut -d '=' -f 2-)

      # Clean up any leading/trailing spaces
      key=$(echo "$key" | xargs)
      value=$(echo "$value" | xargs | sed 's/^"\(.*\)"$/\1/')  # Remove quotes from value
      
      # Output for debugging
      echo "Key: $key, Value: $value"

      # Check for the relevant configuration step and proceed
      case "$key" in
        "payram.backend")
          if ! grep -q "configuration_backend_done" "$STATE_FILE"; then
              echo "Configuring backend"
              code=$(perform_request "Configuration Backend" "$BASE_URL/api/v1/configuration" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                  \"key\": \"$key\",
                  \"value\": \"$value\"
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "configuration_backend_done"
              fi
          else
              echo "Configuration backend already done; skipping."
          fi
          ;;
        
        "payram.frontend")
          if ! grep -q "configuration_frontend_done" "$STATE_FILE"; then
              echo "Configuring frontend"
              code=$(perform_request "Configuration Frontend" "$BASE_URL/api/v1/configuration" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                  \"key\": \"$key\",
                  \"value\": \"$value\"
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "configuration_frontend_done"
              fi
          else
              echo "Configuration frontend already done; skipping."
          fi
          ;;
          
        "ssl")
          if ! grep -q "configuration_ssl_done" "$STATE_FILE"; then
              echo "Configuring SSL"
              code=$(perform_request "Configuration SSL" "$BASE_URL/api/v1/configuration" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                  \"key\": \"$key\",
                  \"value\": \"$value\"
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "configuration_ssl_done"
              fi
          else
              echo "Configuration SSL already done or not required; skipping."
          fi
          ;;
          
        "postal.endpoint")
          if ! grep -q "configuration_postal_endpoint_done" "$STATE_FILE"; then
              echo "Configuring postal endpoint"
              code=$(perform_request "Configuration Postal Endpoint" "$BASE_URL/api/v1/configuration" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                  \"key\": \"$key\",
                  \"value\": \"$value\"
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "configuration_postal_endpoint_done"
              fi
          else
              echo "Configuration postal endpoint already done; skipping."
          fi
          ;;
          
        "postal.apikey")
          if ! grep -q "configuration_postal_apikey_done" "$STATE_FILE"; then
              echo "Configuring postal API key"
              code=$(perform_request "Configuration Postal API Key" "$BASE_URL/api/v1/configuration" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                  \"key\": \"$key\",
                  \"value\": \"$value\"
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "configuration_postal_apikey_done"
              fi
          else
              echo "Configuration postal API key already done; skipping."
          fi
          ;;
        *)
          echo "Unknown key: $key, skipping configuration."
          ;;
      esac
  done
  

  
  #########################
  # projects created
  #########################
 

  process_projects

  

  perform_request_http() {
        description="$1"
        shift
        response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$@")
        body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
        http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        >&2 echo "$description Response:"
        # >&2 echo "$body"
        >&2 echo "HTTP Status: $http_code  in th perform_request function"
        echo "$http_code"  # Return the http_code so it can be processed
    }

  
  #########################
  # Blockchain Ethereum
  #########################
  # "server_api_key" "$update_blockchain_eth_server_api_key" \
  # "height" "$update_blockchain_eth_height" \
  if ! grep -q "blockchain_ethereum_done" "$STATE_FILE"; then
      if check_params "explorer_address" "$update_blockchain_eth_explorer_address" \
                      "explorer_transaction" "$update_blockchain_eth_explorer_transaction" \
                      "min_confirmations" "$update_blockchain_eth_min_confirmations"; then
          echo "Updating blockchain Ethereum"
          code=$(perform_request_http "Blockchain Ethereum" "$BASE_URL/api/v1/blockchain/ETH" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --request PUT \
            --data-raw "{
               \"name\": \"Ethereum\",
               \"client\": \"geth\",
               \"server\": \"wss://ethereum-sepolia-rpc.publicnode.com\",
               \"server_api_key\": \"\",
               \"height\": 0,
               \"explorer_address\": \"$update_blockchain_eth_explorer_address\",
               \"explorer_transaction\": \"$update_blockchain_eth_explorer_transaction\",
               \"min_confirmations\": $update_blockchain_eth_min_confirmations
            }")
          if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
              update_state "blockchain_ethereum_done"
          fi
      else
          echo "Skipping blockchain Ethereum update because required parameters are missing."
      fi
  else
      echo "Blockchain Ethereum already updated; skipping."
      echo ""
  fi
  
  #########################
  # Blockchain Bitcoin
  #########################
  # "height" "$update_blockchain_btc_height"
  if ! grep -q "blockchain_bitcoin_done" "$STATE_FILE"; then
      if check_params "blockchain BTC client" "$update_blockchain_btc_client" \
                      "server" "$update_blockchain_btc_server" \
                      "server_username" "$update_blockchain_btc_server_username" \
                      "server_password" "$update_blockchain_btc_server_password"; then
          echo "Updating blockchain Bitcoin"
          code=$(perform_request_http "Blockchain Bitcoin" "$BASE_URL/api/v1/blockchain/BTC" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --request PUT \
            --data-raw "{
               \"client\": \"$update_blockchain_btc_client\",
               \"server\": \"$update_blockchain_btc_server\",
               \"server_username\": \"$update_blockchain_btc_server_username\",
               \"server_password\": \"$update_blockchain_btc_server_password\",
               \"height\": 0
            }")

          echo "the status code is $code"
          if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
              update_state "blockchain_bitcoin_done"
          fi
      else
          echo "Skipping blockchain Bitcoin update because required parameters are missing."
      fi
  else
      echo "Blockchain Bitcoin already updated; skipping."
      echo ""
  fi
  
  #########################
  # Blockchain TRX
  #########################
  # "height" "$update_blockchain_trx_height"
  if ! grep -q "blockchain_trx_done" "$STATE_FILE"; then
      if check_params "blockchain TRX client" "$update_blockchain_trx_client" \
                      "server" "$update_blockchain_trx_server" \
                      "server_api_key" "$update_blockchain_trx_server_api_key"; then
          echo "Updating blockchain TRX"
          code=$(perform_request_http "Blockchain TRX" "$BASE_URL/api/v1/blockchain/TRX" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --request PUT \
            --data-raw "{
               \"client\": \"$update_blockchain_trx_client\",
               \"server\": \"$update_blockchain_trx_server\",
               \"server_api_key\": \"$update_blockchain_trx_server_api_key\",
               \"height\": 0
            }")
          if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
              update_state "blockchain_trx_done"
          fi
      else
          echo "Skipping blockchain TRX update because required parameters are missing."
      fi
  else
      echo "Blockchain TRX already updated; skipping."
      echo ""
  fi

  configure_with_json() {
    local description="$1"
    local state_flag="$2"
    local json_payload="$3"

    # Check if the state flag is already present.
    if [ -f "$STATE_FILE" ] && grep -q "$state_flag" "$STATE_FILE"; then
        echo "$description: already configured (state flag '$state_flag' found), skipping."
        return
    fi

    # Otherwise, proceed to perform the request.
    code=$(perform_request "$description" "$BASE_URL/api/v1/configuration" \
      --header "API-Key: $API_KEY" \
      --header "Content-Type: application/json" \
      --data-raw "$json_payload")

    if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
        update_state "$state_flag"
    else
        >&2 echo "Error in $description. HTTP status: $code"
    fi
  }

  
  #########################
  # Xpub Ethereum and generate addresses
  #########################
  if ! grep -q "xpub_ethereum_done" "$STATE_FILE" && [ -n "$x_pub_Ethereum" ]; then
      if check_params "xpub Ethereum" "$x_pub_Ethereum" "Ethereum address count" "$x_pub_Ethereum_address"; then
          echo "Processing xpub Ethereum"
          code=$(perform_request_http "Xpub Ethereum" "$BASE_URL/api/v1/blockchain-family/ETH_Family/xpub" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --data-raw "{
               \"xpub\": \"$x_pub_Ethereum\"
            }")
          if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
              code=$(perform_request_http "Generate Ethereum Addresses" "$BASE_URL/api/v1/blockchain-family/ETH_Family/generate" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                   \"count\": $x_pub_Ethereum_address
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "xpub_ethereum_done"
              fi
          fi
      else
          echo "Skipping xpub Ethereum processing because required parameters are missing."
      fi
  else
      echo "Xpub Ethereum already processed; skipping."
      echo ""
  fi
  
  #########################
  # Xpub Bitcoin and create pool
  #########################
  if ! grep -q "xpub_bitcoin_done" "$STATE_FILE" && [ -n "$x_pub_Bitcoin" ]; then
      if check_params "xpub Bitcoin" "$x_pub_Bitcoin" "Bitcoin address count" "$x_pub_Bitcoin_address"; then
          echo "Processing xpub Bitcoin"
          echo "this is on the bitcpin"
          echo $x_pub_Bitcoin
          echo $x_pub_Bitcoin_address

          echo "this is on the bitcpin"
          code=$(perform_request_http "Xpub Bitcoin" "$BASE_URL/api/v1/blockchain-family/BTC_Family/xpub" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --data-raw "{
               \"xpub\": \"$x_pub_Bitcoin\"
            }")
            echo "the status code is asdadad $code"
          if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
              code=$(perform_request_http "Create Bitcoin Pool" "$BASE_URL/api/v1/blockchain-family/BTC_Family/generate" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                   \"count\": $x_pub_Bitcoin_address
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "xpub_bitcoin_done"
              fi
          fi
      else
          echo "Skipping xpub Bitcoin processing because required parameters are missing."
      fi
  else
      echo "Xpub Bitcoin already processed; skipping."
      echo ""
  fi
  
  #########################
  # Xpub TRX and generate addresses
  #########################
  if ! grep -q "xpub_trx_done" "$STATE_FILE" && [ -n "$x_pub_TRX" ]; then
      if check_params "xpub TRX" "$x_pub_TRX" "TRX address count" "$x_pub_Trx_address"; then
          echo "Processing xpub TRX"
          echo "this is the trx thing"
          echo $x_pub_TRX
          echo $x_pub_Trx_address

          echo "this the trx thing"
          code=$(perform_request_http "Xpub TRX" "$BASE_URL/api/v1/blockchain-family/TRX_Family/xpub" \
            --header "API-Key: $API_KEY" \
            --header "Content-Type: application/json" \
            --data-raw "{
               \"xpub\": \"$x_pub_TRX\"
            }")
          if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
              code=$(perform_request_http "Generate TRX Addresses" "$BASE_URL/api/v1/blockchain-family/TRX_Family/generate" \
                --header "API-Key: $API_KEY" \
                --header "Content-Type: application/json" \
                --data-raw "{
                   \"count\": $x_pub_Trx_address
                }")
              if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
                  update_state "xpub_trx_done"
              fi
          fi
      else
          echo "Skipping xpub TRX processing because required parameters are missing."
      fi
  else
      echo "Xpub TRX already processed; skipping."
  fi

  if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Consumer Action Config: already configured, skipping."
else
  # JSON payload for consumer.action.config
  json_payload='{
    "key": "consumer.action.config",
    "value": "[{\"QueryBuilder\":{\"EventNames\":[\"payment_request\"],\"CreatedAtRelativeStart\":-10800000000000,\"CreatedAtRelativeEnd\":-180000000000,\"JoinWhereClause\":{\"json_extract(attribute, '\''$.ReferenceID'\'')\":{\"Exclude\":true,\"Clause\":\"json_extract(attribute, '\''$.ReferenceID'\'')\"}},\"SubQueryBuilder\":{\"EventNames\":[\"payment_request-email-sent\",\"payment_request-email-failed\",\"payment_request-cancelled\",\"payment-request-cancelled\",\"deposit-received\"],\"CreatedAtRelativeStart\":-10800000000000,\"CreatedAtRelativeEnd\":0}},\"EmailTemplateName\":\"payram.templates.email.master\",\"EmmitEventsOnSuccess\":[{\"EventName\":\"payment_request-email-sent\",\"CopyProfileID\":true,\"CopyFullAttribute\":false,\"AttributeSpec\":{\"Amount\":true,\"AmountInUsd\":true,\"Currency\":true,\"CustomerID\":true,\"InvoiceID\":true,\"MemberID\":true,\"PaymentRequestID\":true,\"PostalMessageID\":true,\"ReferenceID\":true,\"ToAddresses\":true}}],\"EmmitEventsOnError\":[{\"EventName\":\"payment_request-email-failed\",\"CopyProfileID\":true,\"CopyFullAttribute\":true}],\"SendRequest\":{\"from\":\"Payram App <support@resuefas.vip>\",\"reply_to\":\"support@resuefas.vip\",\"subject\":\"We are waiting for your payment!\"}}]"
  }'

  # Make the curl request
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")

  # Separate body and HTTP status
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

  echo "Configure Consumer Action Config Response:"
  echo "$body"
  echo "HTTP Status: $http_code"

  # Check for success and update state
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Consumer Action Config. HTTP Status: $http_code" >&2
  fi
fi



# 1. Configure consumer.action.config
flag="configuration_consumer_action_config_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Consumer Action Config: already configured, skipping."
else
  json_payload='{
    "key": "consumer.action.config",
    "value": "[{\"QueryBuilder\":{\"EventNames\":[\"payment_request\"],\"CreatedAtRelativeStart\":-10800000000000,\"CreatedAtRelativeEnd\":-180000000000,\"JoinWhereClause\":{\"json_extract(attribute, '\''$.ReferenceID'\'')\":{\"Exclude\":true,\"Clause\":\"json_extract(attribute, '\''$.ReferenceID'\'')\"}},\"SubQueryBuilder\":{\"EventNames\":[\"payment_request-email-sent\",\"payment_request-email-failed\",\"payment_request-cancelled\",\"payment-request-cancelled\",\"deposit-received\"],\"CreatedAtRelativeStart\":-10800000000000,\"CreatedAtRelativeEnd\":0}},\"EmailTemplateName\":\"payram.templates.email.master\",\"EmmitEventsOnSuccess\":[{\"EventName\":\"payment_request-email-sent\",\"CopyProfileID\":true,\"CopyFullAttribute\":false,\"AttributeSpec\":{\"Amount\":true,\"AmountInUsd\":true,\"Currency\":true,\"CustomerID\":true,\"InvoiceID\":true,\"MemberID\":true,\"PaymentRequestID\":true,\"PostalMessageID\":true,\"ReferenceID\":true,\"ToAddresses\":true}}],\"EmmitEventsOnError\":[{\"EventName\":\"payment_request-email-failed\",\"CopyProfileID\":true,\"CopyFullAttribute\":true}],\"SendRequest\":{\"from\":\"Payram App <support@resuefas.vip>\",\"reply_to\":\"support@resuefas.vip\",\"subject\":\"We are waiting for your payment!\"}}]"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Consumer Action Config Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Consumer Action Config. HTTP Status: $http_code" >&2
  fi
fi

# 2. Configure payram.templates.email.deposit.received.master
flag="configuration_email_deposit_received_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Email Deposit Received Master Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.deposit.received.master",
    "value": "{{ template \"payram.templates.email.header\" . }} {{ template \"payram.templates.email.deposit.received.body\" . }} {{ template \"payram.templates.email.footer\" . }}"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Email Deposit Received Master Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Email Deposit Received Master Template. HTTP Status: $http_code" >&2
  fi
fi

# 3. Configure payram.websocket.server.url
flag="configuration_websocket_url_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Websocket Server URL: already configured, skipping."
else
  json_payload='{
    "key": "payram.websocket.server.url",
    "value": "wss://payram.resuefas.vip:8443"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Websocket Server URL Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Websocket Server URL. HTTP Status: $http_code" >&2
  fi
fi

# 4. Configure payram.templates.email.default.otp.master
flag="configuration_otp_master_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Default OTP Master Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.default.otp.master",
    "value": "{{ template \"payram.templates.email.default.header\" . }} {{ template \"payram.templates.email.default.otp.body\" . }} {{ template \"payram.templates.email.default.footer\" . }}"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Default OTP Master Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Default OTP Master Template. HTTP Status: $http_code" >&2
  fi
fi

# 5. Configure payram.templates.email.default.otp.subject
flag="configuration_otp_subject_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Default OTP Subject Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.default.otp.subject",
    "value": "Withdrawal OTP Code - {{.ProjectName}}"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Default OTP Subject Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Default OTP Subject Template. HTTP Status: $http_code" >&2
  fi
fi

# 6. Configure payram.templates.email.default.header
flag="configuration_default_header_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Default Email Header Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.default.header",
    "value": "<!DOCTYPE html> <html> <head> <meta charset=\"UTF-8\"> <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"> <title>Email Template</title> </head><body style=\"font-family: Arial, sans-serif; margin: 0; padding: 0; background-color: #f4f4f4;\"><table role=\"presentation\" width=\"100%\" style=\"background-color: #5A2CD2; padding: 20px; text-align: center;\"><tr><td><img src=\\\"{{.ProjectLogoURL}}\\\" alt=\\\"{{.ProjectName}}\\\" style=\\\"height: 50px;\\\"></td></tr></table>Withdrawal OTP Code - {{.ProjectName}}"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Default Email Header Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Default Email Header Template. HTTP Status: $http_code" >&2
  fi
fi

# 7. Configure payram.templates.email.default.footer
flag="configuration_default_footer_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Default Email Footer Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.default.footer",
    "value": "<table role=\"presentation\" width=\"100%\" style=\"background-color: #ffffff; padding: 20px; text-align: center; border-top: 1px solid #dddddd;\"> <tr> <td> <p style=\"font-size: 14px; color: #666666;\"> Powered By <strong style=\"color: #000;\">PAYRAM</strong> </p> <p style=\"font-size: 12px; color: #999999;\"> If you didn’t initiate this request, please ignore this email or contact our support team immediately. </p> </td> </tr> </table>"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Default Email Footer Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Default Email Footer Template. HTTP Status: $http_code" >&2
  fi
fi

# 8. Configure payram.templates.email.default.otp.body
flag="configuration_otp_body_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Default OTP Body Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.default.otp.body",
    "value": "<table role=\"presentation\" width=\"100%\" style=\"background-color: #ffffff; padding: 30px; max-width: 600px; margin: 0 auto; border-radius: 10px;\"> <tr> <td> <h2 style=\"font-size: 22px; color: #000000; font-weight: bold; text-align: center;\">Verify Your Withdrawal Request</h2> <p style=\"font-size: 16px; color: #333333; text-align: center;\"> We’ve received your <strong>request to withdraw your rewards.</strong> To ensure the security of your account and funds, please verify this transaction using the one-time password (OTP) below: </p> <div style=\"background-color: #f4f4f4; padding: 15px; text-align: center; font-size: 24px; font-weight: bold; letter-spacing: 5px; border-radius: 8px; width: fit-content; margin: 20px auto;\"> {{.OTP}} </div> <p style=\"font-size: 14px; color: #666666; text-align: center;\"> This OTP is valid for the next <strong>{{.ValidityPeriod}}</strong>. Please enter it on the verification page to complete your request. </p> <p style=\"font-size: 14px; color: #333333; text-align: center;\"> Best regards,<br/> <strong>{{.ProjectName}} Team</strong> </p> </td> </tr> </table>"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Default OTP Body Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Default OTP Body Template. HTTP Status: $http_code" >&2
  fi
fi

# 9. Configure payram.templates.email.body
flag="configuration_email_body_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Email Body Template: already configured, skipping."
else
  # Use a here-document to assign the long HTML payload safely.
  json_payload=$(cat <<'EOF'
{
  "key": "payram.templates.email.body",
  "value": "<table border=\"0\" cellpadding=\"10\" cellspacing=\"0\" class=\"heading_block block-2\" role=\"presentation\" style=\"mso-table-lspace: 0pt; mso-table-rspace: 0pt;\" width=\"100%\"> <tr> <td class=\"pad\"> <h1 style=\"margin: 0; color: #1e0e4b; direction: ltr; font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif; font-size: 38px; font-weight: 700; letter-spacing: normal; line-height: 120%; text-align: left; margin-top: 0; margin-bottom: 0; mso-line-height-alt: 45.6px;\"><span class=\"tinyMce-placeholder\">Let me help you with payments</span></h1> </td> </tr> </table> <table border=\"0\" cellpadding=\"10\" cellspacing=\"0\" class=\"paragraph_block block-3\" role=\"presentation\" style=\"mso-table-lspace: 0pt; mso-table-rspace: 0pt; word-break: break-word;\" width=\"100%\"> <tr> <td class=\"pad\"> <div style=\"color:#444a5b; direction:ltr; font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif; font-size: 16px; font-weight: 400; letter-spacing: 0px; line-height: 120%; text-align: left; mso-line-height-alt: 19.2px;\"> <p style=\"margin:0; margin-bottom:16px;\">Payram has helped millions with lead generation and grow their business by 30-40% in just 90 days.</p> <p style=\"margin:0; margin-bottom:16px;\">Let's get you more client.</p> <p style=\"margin:0;\"></p> </div> </td> </tr> </table> <table border=\"0\" cellpadding=\"10\" cellspacing=\"0\" class=\"button_block block-4\" role=\"presentation\" style=\"mso-table-lspace: 0pt; mso-table-rspace: 0pt;\" width=\"100%\"> <tr> <td class=\"pad\"> <div align=\"center\" class=\"alignment\"><a href=\"{{ .PaymentURL }}\" target=\"_blank\" style=\"text-decoration:none; display:inline-block; color:#ffffff; background-color:#4d9aff; border-radius:4px; width:auto; border-top:0px solid transparent; font-weight:400; border-right:0px solid transparent; border-bottom:0px solid transparent; border-left:0px solid transparent; padding-top:5px; padding-bottom:5px; font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif; font-size:16px; text-align:center; mso-border-alt:none; word-break:keep-all;\"><span style=\"padding-left:20px; padding-right:20px; font-size:16px; display:inline-block; letter-spacing:normal;\"><span style=\"word-break:break-word; line-height:32px;\">Pay</span></span></a></div> </td> </tr> </table> <table border=\"0\" cellpadding=\"10\" cellspacing=\"0\" class=\"divider_block block-5\" role=\"presentation\" style=\"mso-table-lspace:0pt; mso-table-rspace:0pt;\" width=\"100%\"> <tr> <td class=\"pad\"> <div align=\"center\" class=\"alignment\"> <table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" role=\"presentation\" style=\"mso-table-lspace:0pt; mso-table-rspace:0pt;\" width=\"100%\"> <tr> <td class=\"divider_inner\" style=\"font-size:1px; line-height:1px; border-top:1px solid #dddddd;\"><span> </span></td> </tr> </table> </div> </td> </tr> </table> <div class=\"spacer_block block-6\" style=\"height:60px; line-height:60px; font-size:1px;\"> </div> <table border=\"0\" cellpadding=\"10\" cellspacing=\"0\" class=\"paragraph_block block-7\" role=\"presentation\" style=\"mso-table-lspace:0pt; mso-table-rspace:0pt; word-break:break-word;\" width=\"100%\"> <tr> <td class=\"pad\"> <div style=\"color:#444a5b; direction:ltr; font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif; font-size:16px; font-weight:400; letter-spacing:0px; line-height:120%; text-align:left; mso-line-height-alt:19.2px;\"> <p style=\"margin:0; margin-bottom:16px;\">\"Since I started using Payram, I've seen a 30-40% increase in my lead generation. The platform's reach is incredible!\" - <em><strong>Tom, NY</strong></em></p> <p style=\"margin:0;\">\"Payram has been a game-changer for my business. It's an investment that pays for itself.\" <em><strong>- Adam, LA</strong></em></p> </div> </td> </tr> </table><!-- End --> </body>"
}
EOF
)
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Email Body Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Email Body Template. HTTP Status: $http_code" >&2
  fi
fi

# 10. Configure payram.templates.email.header
flag="configuration_email_header_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Email Header Template: already configured, skipping."
else
  json_payload='{
    "key": "payram.templates.email.header",
    "value": "<!DOCTYPE html> <html> <head> <meta charset=\"UTF-8\"> <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"> <title>Email Template</title> </head><body style=\"font-family: Arial, sans-serif; margin: 0; padding: 0; background-color: #f4f4f4;\"><table role=\"presentation\" width=\"100%\" style=\"background-color: #5A2CD2; padding: 20px; text-align: center;\"><tr><td><img src=\\\"{{.ProjectLogoURL}}\\\" alt=\\\"{{.ProjectName}}\\\" style=\\\"height: 50px;\\\"></td></tr></table>Withdrawal OTP Code - {{.ProjectName}}"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Email Header Template Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Email Header Template. HTTP Status: $http_code" >&2
  fi
fi

# 11. Configure merchant.webhook.apikey
flag="configuration_merchant_webhook_apikey_done"
if [ -f "$STATE_FILE" ] && grep -q "$flag" "$STATE_FILE"; then
  echo "Configure Merchant Webhook API Key: already configured, skipping."
else
  json_payload='{
    "key": "merchant.webhook.apikey",
    "value": "39b11799f7cf9abadb300e5dc85r6660"
  }'
  response=$(curl --location --silent --write-out "\nHTTPSTATUS:%{http_code}" "$BASE_URL/api/v1/configuration" \
    --header "API-Key: $API_KEY" \
    --header "Content-Type: application/json" \
    --data-raw "$json_payload")
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
  http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  echo "Configure Merchant Webhook API Key Response:"
  echo "$body"
  echo "HTTP Status: $http_code"
  if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    sudo bash -c "echo '$flag' >> $STATE_FILE"
  else
    echo "Error in Configure Merchant Webhook API Key. HTTP Status: $http_code" >&2
  fi
fi

setup_container() {
  
  required_states=(
    "dependencies_installed"
    "docker_container_running"
    "signup_done"
    "configuration_backend_done"
    "configuration_frontend_done"
    "configuration_postal_endpoint_done"
    "configuration_postal_apikey_done"
    "blockchain_bitcoin_done"
    "blockchain_trx_done"
    "xpub_ethereum_done"
    "xpub_bitcoin_done"
    "xpub_trx_done"
    "configuration_consumer_action_config_done"
    "configuration_email_deposit_received_done"
    "configuration_websocket_url_done"
    "configuration_otp_master_done"
    "configuration_otp_subject_done"
    "configuration_default_header_done"
    "configuration_default_footer_done"
    "configuration_otp_body_done"
    "configuration_email_body_done"
    "configuration_email_header_done"
    "configuration_merchant_webhook_apikey_done"
  )

 
  if [ ! -f "$STATE_FILE" ]; then
    echo "State file '$STATE_FILE' not found. Exiting."
    return 1
  fi

 
  missing_state=0
  for state in "${required_states[@]}"; do
    if ! grep -q "^${state}$" "$STATE_FILE"; then
      echo "Required state '$state' is missing."
      missing_state=1
    fi
  done

  if [ $missing_state -ne 0 ]; then
    echo "Not all required states are present. Skipping container restart."
    return 1
  fi

  # At this point, all required states are present.
  # Check if a container named 'payram' is running.
  running_container=$(docker ps --filter "name=payram" --filter "status=running" -q)
  if [ -z "$running_container" ]; then
    echo "No running container named 'payram' found."
    return 1
  fi

  container_restarted_flag="container_restarted"
  # If the container has already been restarted, skip the restart.
  if grep -q "^${container_restarted_flag}$" "$STATE_FILE"; then
    echo "Container restart already performed. Skipping restart."
    return 0
  fi

  # Restart the container since required states are met and restart has not been done.
  echo "Container 'payram' is running. Restarting the container..."
  docker restart payram

  max_attempts=3
  wait_time=20


  # Try to hit the endpoint until a 200 status code is received or max attempts reached.
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
      echo "Attempt ${attempt}: Waiting for ${wait_time} seconds..."
      sleep $wait_time

      # Hit the endpoint and capture the HTTP status code.
      status_code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL")
      echo "Received status code: $status_code"

      if [ "$status_code" -eq 200 ]; then
          echo "Your setup is successful!"
          # Append the container_restarted flag if it is not already present.
          update_state "$container_restarted_flag"
          return 0
      fi
  done

  echo "Something went wrong while setting up the server."
  return 1
}


setup_container

  
  echo "All API requests completed."
}


# Call the API requests function
run_api_requests




