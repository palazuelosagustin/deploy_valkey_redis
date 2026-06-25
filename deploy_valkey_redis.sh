#!/bin/bash
set -euo pipefail

# check if docker is installed
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH. It is required for this script."
    exit 1
fi

# --- Script Configuration & Defaults ---
BASE_DIR_PREFIX="$HOME" # Renamed to avoid conflict
REPO=""
FLAVOR=""
TYPE=""
VERSION="latest"
REPLICAS=2
SENTINELS=3
SHARDS=3
CLUSTER_REPLICAS=0
CLEAN_PREVIOUS=false
PASSWORD="${DEPLOY_VALKEY_REDIS_PASSWORD:-}"
NAME_SUFFIX=""
AUTO_CLEANUP_ON_ERROR=false
TLS_ENABLED=false

# --- Variables set dynamically in main() ---
DEPLOYMENT_ID=""
BASE_DIR=""
NETWORK_NAME=""
BASE_CONTAINER_NAME=""
TLS_DIR=""

# --- Global Variables (set by functions) ---
NETWORK_SUBNET=""
IMAGE_NAME=""
BINARY=""
CLI_COMMAND=""
SENTINEL_COMMAND=""
JSON_MODULE=""
BLOOM_MODULE=""
SEARCH_MODULE=""
CLI_TLS_ARGS=()

# --- Color Codes ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Deploys Redis or Valkey with various topologies using Docker.

Usage:
  $0 -r <repo> -t <type> [OPTIONS]

Required Arguments:
  -r <repo>           Specify the repository: 'redis' or 'valkey'.
  -t <type>           Specify the deployment type: 'standalone', 'replica', or 'cluster'.

Options:
  -N <name>           Specify a unique name for the deployment (e.g., 'test1').
  -f <flavor>         Image flavor. For redis: 'stack'. For valkey: 'extensions'.
  -v <version>        Image version/tag (default: latest).
  -n <num>            Number of replicas for a replica set (default: 2).
  -s <num>            Number of sentinels for a replica set (default: 3).
  -S <num>            Number of master shards for a cluster (default: 3).
  -R <num>            Number of replicas per shard for a cluster (default: 0).
  -p <password>       Password for Redis/Valkey auth. If omitted, one is generated.
  -T                  Enable TLS. Certificates are generated automatically with OpenSSL.
  -c                  Clean up a specific deployment before starting a new one.
  -h                  Show this help message.

Example:
  $0 -c -r redis -f stack -t replica -n 2 -s 3 -v 7.2
  $0 -c -r valkey -t cluster -S 3 -R 1 -N my-cluster
  DEPLOY_VALKEY_REDIS_PASSWORD=secret123 $0 -c -r valkey -t standalone -N my-dev
  $0 -T -r redis -t standalone -N tls-demo

Available tags:
valkey:             8.1.1, 8.1, 8
valkey-extensions:  8.1.0-rc1, 8.1, 8
redis:              8, 8.0, 8.0.0, 8.0.1, 7, 7.0.1, 6
redis-stack-server: 8.0.0, 8, 7.0.0, 7

EOF
    exit 0
}

cleanup() {
    log_info "Cleaning up deployment '$DEPLOYMENT_ID'..."
    local container_ids=()
    if [[ -n "$DEPLOYMENT_ID" ]]; then
        while IFS= read -r container_id; do
            [[ -n "$container_id" ]] && container_ids+=("$container_id")
        done < <(docker ps -aq --filter "label=db-deploy-script=true" --filter "label=deployment_id=${DEPLOYMENT_ID}")
    fi

    if (( ${#container_ids[@]} > 0 )); then
        docker rm -f "${container_ids[@]}" > /dev/null 2>&1 || true
    fi

    if [[ -n "$NETWORK_NAME" ]]; then
        docker network rm "$NETWORK_NAME" > /dev/null 2>&1 || true
    fi

    if [[ -n "${BASE_DIR:-}" && "$BASE_DIR" != "/" && "$BASE_DIR" != "$HOME" ]]; then
        rm -rf "${BASE_DIR}" > /dev/null 2>&1 || true
    fi
    log_info "Cleanup complete."
}

handle_error() {
    local exit_code=$?
    trap - ERR
    echo -e "${RED}[ERROR]${NC} Deployment failed." >&2
    if [[ "$AUTO_CLEANUP_ON_ERROR" == true ]]; then
        cleanup
    fi
    exit "$exit_code"
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '\n'
    else
        local generated_password
        set +o pipefail
        generated_password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
        set -o pipefail
        printf '%s' "$generated_password"
    fi
}

require_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "$name must be a non-negative integer. Got '$value'."
    fi
}

validate_name_suffix() {
    if [[ -n "$NAME_SUFFIX" && ! "$NAME_SUFFIX" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        log_error "Deployment name may contain only letters, numbers, dot, underscore, and dash."
    fi
}

validate_inputs() {
    if [[ -z "$REPO" || -z "$TYPE" ]]; then
        log_warn "Missing required arguments."
        usage
    fi

    if [[ "$REPO" != "redis" && "$REPO" != "valkey" ]]; then
        log_error "Invalid repo: '$REPO'. Must be 'redis' or 'valkey'."
    fi

    if [[ "$TYPE" != "standalone" && "$TYPE" != "replica" && "$TYPE" != "cluster" ]]; then
        log_error "Invalid deployment type '$TYPE'. Use 'standalone', 'replica', or 'cluster'."
    fi

    require_integer "Replicas" "$REPLICAS"
    require_integer "Sentinels" "$SENTINELS"
    require_integer "Shards" "$SHARDS"
    require_integer "Cluster replicas" "$CLUSTER_REPLICAS"
    validate_name_suffix

    if [[ -n "$FLAVOR" ]]; then
        case "$REPO:$FLAVOR" in
            redis:stack|valkey:extensions) ;;
            *)
                log_error "Invalid flavor '$FLAVOR' for repo '$REPO'."
                ;;
        esac
    fi

    if [[ "$TYPE" == "replica" && "$REPLICAS" -lt 1 ]]; then
        log_error "Replica deployments require at least 1 replica."
    fi

    if [[ "$TYPE" == "replica" ]]; then
        if (( 10 + REPLICAS > 254 )); then
            log_error "Replica count is too large for the current IP allocation."
        fi

        if (( 100 + SENTINELS > 254 )); then
            log_error "Sentinel count is too large for the current IP allocation."
        fi
    fi

    if [[ "$TYPE" == "cluster" ]]; then
        if (( SHARDS < 3 )); then
            log_warn "Cluster requires at least 3 master shards. Setting shards to 3."
            SHARDS=3
        fi

        if (( 20 * SHARDS + CLUSTER_REPLICAS > 254 )); then
            log_error "Cluster size is too large for the current IP allocation."
        fi
    fi

    if [[ -z "$PASSWORD" ]]; then
        PASSWORD="$(generate_password)"
    fi

    if [[ "$TLS_ENABLED" == true ]] && ! command -v openssl >/dev/null 2>&1; then
        log_error "OpenSSL is required when TLS is enabled."
    fi
}

prepare_node_dirs() {
    local dir="$1"
    mkdir -p "${dir}/config" "${dir}/data" "${dir}/logs"
    chmod 755 "${dir}" "${dir}/config"
    chmod 777 "${dir}/data" "${dir}/logs"
}

set_cli_tls_args() {
    CLI_TLS_ARGS=()
    if [[ "$TLS_ENABLED" == true ]]; then
        CLI_TLS_ARGS=(--tls --cacert /tls/ca.crt)
    fi
}

append_tls_config() {
    local config_path="$1"
    local tls_port="$2"

    if [[ "$TLS_ENABLED" != true ]]; then
        return 0
    fi

    cat >> "$config_path" <<EOF
port 0
tls-port $tls_port
tls-cert-file /tls/server.crt
tls-key-file /tls/server.key
tls-ca-cert-file /tls/ca.crt
tls-auth-clients no
EOF
}

generate_tls_openssl_config() {
    local config_path="$1"
    local ip_base="$2"
    local alt_names=()
    local alt_index=1

    alt_names+=("IP.${alt_index} = 127.0.0.1")
    alt_index=$((alt_index + 1))
    alt_names+=("DNS.${alt_index} = localhost")
    alt_index=$((alt_index + 1))

    case "$TYPE" in
        standalone)
            alt_names+=("IP.${alt_index} = ${ip_base}.10")
            ;;
        replica)
            alt_names+=("IP.${alt_index} = ${ip_base}.10")
            alt_index=$((alt_index + 1))
            for i in $(seq 1 "$REPLICAS"); do
                alt_names+=("IP.${alt_index} = ${ip_base}.$((10 + i))")
                alt_index=$((alt_index + 1))
            done
            for i in $(seq 1 "$SENTINELS"); do
                alt_names+=("IP.${alt_index} = ${ip_base}.$((100 + i))")
                alt_index=$((alt_index + 1))
            done
            ;;
        cluster)
            for i in $(seq 0 $((SHARDS - 1))); do
                alt_names+=("IP.${alt_index} = ${ip_base}.$((10 + i))")
                alt_index=$((alt_index + 1))
                for j in $(seq 1 "$CLUSTER_REPLICAS"); do
                    alt_names+=("IP.${alt_index} = ${ip_base}.$(((i + 1) * 20 + j))")
                    alt_index=$((alt_index + 1))
                done
            done
            ;;
    esac

    cat > "$config_path" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = ${DEPLOYMENT_ID}

[req_ext]
subjectAltName = @alt_names

[alt_names]
$(printf '%s\n' "${alt_names[@]}")
EOF
}

generate_tls_materials() {
    if [[ "$TLS_ENABLED" != true ]]; then
        return 0
    fi

    local ip_base
    local openssl_config

    ip_base=$(echo "$NETWORK_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
    TLS_DIR="${BASE_DIR}/tls"
    mkdir -p "$TLS_DIR"
    chmod 755 "$TLS_DIR"

    openssl_config="${TLS_DIR}/openssl.cnf"
    generate_tls_openssl_config "$openssl_config" "$ip_base"

    log_info "Generating TLS certificates in '$TLS_DIR'..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${TLS_DIR}/ca.key" \
        -out "${TLS_DIR}/ca.crt" \
        -days 3650 \
        -subj "/CN=${DEPLOYMENT_ID}-ca" >/dev/null 2>&1

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${TLS_DIR}/server.key" \
        -out "${TLS_DIR}/server.csr" \
        -config "$openssl_config" >/dev/null 2>&1

    openssl x509 -req \
        -in "${TLS_DIR}/server.csr" \
        -CA "${TLS_DIR}/ca.crt" \
        -CAkey "${TLS_DIR}/ca.key" \
        -CAcreateserial \
        -out "${TLS_DIR}/server.crt" \
        -days 825 \
        -sha256 \
        -extensions req_ext \
        -extfile "$openssl_config" >/dev/null 2>&1

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${TLS_DIR}/client.key" \
        -out "${TLS_DIR}/client.csr" \
        -subj "/CN=${DEPLOYMENT_ID}-client" >/dev/null 2>&1

    openssl x509 -req \
        -in "${TLS_DIR}/client.csr" \
        -CA "${TLS_DIR}/ca.crt" \
        -CAkey "${TLS_DIR}/ca.key" \
        -CAcreateserial \
        -out "${TLS_DIR}/client.crt" \
        -days 825 \
        -sha256 >/dev/null 2>&1

    rm -f "${TLS_DIR}/server.csr" "${TLS_DIR}/client.csr" "${TLS_DIR}/ca.srl"
    chmod 644 "${TLS_DIR}/ca.key" "${TLS_DIR}/server.key" "${TLS_DIR}/client.key"
    chmod 644 "${TLS_DIR}/ca.crt" "${TLS_DIR}/server.crt" "${TLS_DIR}/client.crt" "$openssl_config"
}

create_network() {
    # First, check if the network already exists to avoid re-creating it
    if docker network inspect "$NETWORK_NAME" &>/dev/null; then
        log_info "Network '$NETWORK_NAME' already exists. Re-using it."
        NETWORK_SUBNET=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME")
        return 0
    fi

    log_info "Searching for an available Class B IP subnet..."
    local subnet=""
    # Loop through the private Class B range (172.16.x.x to 172.31.x.x)
    for j in {16..31}; do
        for k in {0..254}; do
            local potential_subnet="172.${j}.${k}.0/24"
            # Check if this /24 subnet is already in use by any Docker network
            if ! docker network ls --format '{{.Name}}' | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | grep -qF "$potential_subnet"; then
                subnet="$potential_subnet"
                break 2 # Break out of both loops once an available subnet is found
            fi
        done
    done

    # If no subnet was found after checking the entire range, exit with an error
    if [[ -z "$subnet" ]]; then
        log_error "Could not find an available subnet in the 172.16.0.0/24 - 172.31.255.0/24 range."
        return 1
    fi

    # Create the network with the identified subnet
    NETWORK_SUBNET="$subnet"
    log_info "Creating network '$NETWORK_NAME' with subnet ${subnet}..."
    docker network create --subnet="$subnet" --label "db-deploy-script=true" --label "deployment_id=${DEPLOYMENT_ID}" "$NETWORK_NAME" >/dev/null
}


set_image_config() {
    if [[ "$REPO" == "redis" ]]; then
        CLI_COMMAND="redis-cli"
        SENTINEL_COMMAND="redis-sentinel"
        if [[ "$FLAVOR" == "stack" ]]; then
            IMAGE_NAME="redis/redis-stack"
            BINARY="redis-stack-server"
        else
            IMAGE_NAME="redis"
            BINARY="redis-server"
        fi
    elif [[ "$REPO" == "valkey" ]]; then
        CLI_COMMAND="valkey-cli"
        SENTINEL_COMMAND="valkey-sentinel"
        BINARY="valkey-server"
        if [[ "$FLAVOR" == "extensions" ]]; then
            IMAGE_NAME="valkey/valkey-extensions"
            JSON_MODULE="loadmodule /usr/lib/valkey/libjson.so"
            BLOOM_MODULE="loadmodule /usr/lib/valkey/libvalkey_bloom.so"
            SEARCH_MODULE="loadmodule /usr/lib/valkey/libsearch.so"
        else
            IMAGE_NAME="valkey/valkey"
        fi
    else
        log_error "Invalid repo: '$REPO'. Must be 'redis' or 'valkey'."
    fi
}

create_server_config() {
    local config_path="$1"
    local node_type="$2"
    local replicaof_ip=${3:-""}

    cat > "$config_path" <<EOF
bind 0.0.0.0
logfile /logs/server.log
dir /data
aclfile /config/users.acl
EOF

    if [[ "$TLS_ENABLED" == true ]]; then
        append_tls_config "$config_path" 6379
    fi

    case "$node_type" in
        standalone)
            true
            ;;
        replica_master)
            echo "masteruser replica-user" >> "$config_path"
            echo "masterauth $PASSWORD" >> "$config_path"
            [[ "$TLS_ENABLED" == true ]] && echo "tls-replication yes" >> "$config_path"
            ;;
        replica_slave)
            echo "masteruser replica-user" >> "$config_path"
            echo "masterauth $PASSWORD" >> "$config_path"
            echo "replicaof $replicaof_ip 6379" >> "$config_path"
            [[ "$TLS_ENABLED" == true ]] && echo "tls-replication yes" >> "$config_path"
            ;;
        cluster)
            cat >> "$config_path" <<EOF
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
requirepass $PASSWORD
masterauth $PASSWORD
EOF
            if [[ "$TLS_ENABLED" == true ]]; then
                cat >> "$config_path" <<EOF
tls-replication yes
tls-cluster yes
EOF
            fi
            ;;
    esac

    [[ -n "$JSON_MODULE" ]] && echo "$JSON_MODULE" >> "$config_path"
    [[ -n "$BLOOM_MODULE" ]] && echo "$BLOOM_MODULE" >> "$config_path"
    [[ -n "$SEARCH_MODULE" ]] && echo "$SEARCH_MODULE" >> "$config_path"
    chmod 644 "$config_path"
}

create_acl_file() {
    local acl_path="$1"
    local acl_type="$2"

    case "$acl_type" in
        standalone|cluster)
            cat > "$acl_path" <<EOF
user default on >$PASSWORD ~* &* +@all
EOF
            ;;
        replica)
            cat > "$acl_path" <<EOF
user default on >$PASSWORD ~* &* +@all
user replica-user on >$PASSWORD -@all +psync +replconf +ping
user sentinel-user on >$PASSWORD allchannels -@all +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill
EOF
            ;;
    esac
    chmod 644 "$acl_path"
}

create_sentinel_config() {
    local config_path="$1"
    local master_ip="$2"
    local quorum="$3"

    cat > "$config_path" <<EOF
logfile /logs/sentinel.log
dir /tmp
sentinel monitor mymaster $master_ip 6379 $quorum
sentinel auth-user mymaster sentinel-user
sentinel auth-pass mymaster $PASSWORD
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
user default on >$PASSWORD ~* &* +@all
EOF
    if [[ "$TLS_ENABLED" == true ]]; then
        append_tls_config "$config_path" 26379
        echo "tls-replication yes" >> "$config_path"
    fi
    chmod 644 "$config_path"
}

# Usage: run_node <name> <dir_path> <node_type> <ip_address>
run_node() {
    local name="$1"
    local dir_path="$2"
    local node_type="$3"
    local ip_address="$4"
    local volume_args=(
        -v "${dir_path}/data:/data"
        -v "${dir_path}/config:/config"
        -v "${dir_path}/logs:/logs"
    )

    local cmd="$BINARY"
    local conf_file_name="server.conf"

    if [[ "$node_type" == "sentinel" ]]; then
        cmd="$SENTINEL_COMMAND"
        conf_file_name="sentinel.conf"
    fi

    if [[ "$TLS_ENABLED" == true ]]; then
        volume_args+=(-v "${TLS_DIR}:/tls:ro")
    fi

    log_info "Starting container '$name' with IP ${ip_address}..."
    docker run -d --restart always \
        --name "$name" \
        --network "$NETWORK_NAME" \
        --ip "$ip_address" \
        --label "db-deploy-script=true" \
        --label "deployment_id=${DEPLOYMENT_ID}" \
        "${volume_args[@]}" \
        "${IMAGE_NAME}:${VERSION}" "$cmd" "/config/${conf_file_name}" >/dev/null
}

wait_for_ready() {
    local container_name="$1"
    local extra_args=("${@:2}")

    log_info "Waiting for '$container_name' to be ready..."
    for _ in {1..20}; do
        if docker exec "$container_name" "$CLI_COMMAND" "${CLI_TLS_ARGS[@]}" "${extra_args[@]}" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
            log_info "'$container_name' is ready."
            return 0
        fi
        sleep 1
    done
    log_error "'$container_name' did not become ready in time."
}

get_container_data() {
    local container_name="$1"
    local field="$2"
    case "$field" in
        ip) docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1";;
        status) docker inspect -f '{{.State.Status}}' "$1";;
    esac

}

deploy_standalone() {
    log_info "Deploying Standalone Node..."
    local ip_base
    ip_base=$(echo "$NETWORK_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
    local ip="${ip_base}.10"
    local container_name="${BASE_CONTAINER_NAME}-standalone"


    local dir="${BASE_DIR}/standalone"
    prepare_node_dirs "${dir}"
    create_server_config "${dir}/config/server.conf" "standalone"
    create_acl_file "${dir}/config/users.acl" "standalone"
    run_node "$container_name" "$dir" "server" "$ip"
    wait_for_ready "$container_name" -a "$PASSWORD"
}

deploy_replica_set() {
    log_info "Deploying Replica Set ($REPLICAS replicas, $SENTINELS sentinels)..."
    local ip_base
    ip_base=$(echo "$NETWORK_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
    local master_ip="${ip_base}.10"

    # Deploy Master
    local master_name="node-0"
    local container_name="${BASE_CONTAINER_NAME}-$master_name"
    local master_dir="${BASE_DIR}/${master_name}"
    prepare_node_dirs "${master_dir}"
    create_server_config "${master_dir}/config/server.conf" "replica_master"
    create_acl_file "${master_dir}/config/users.acl" "replica"
    run_node "$container_name" "$master_dir" "server" "$master_ip"
    wait_for_ready "$container_name" -a "$PASSWORD"

    # Deploy Replicas
    for i in $(seq 1 "$REPLICAS"); do
        local replica_name="node-${i}"
        local container_name="${BASE_CONTAINER_NAME}-${replica_name}"
        local replica_dir="${BASE_DIR}/${replica_name}"
        local replica_ip="${ip_base}.$((10 + i))"
        prepare_node_dirs "${replica_dir}"
        create_server_config "${replica_dir}/config/server.conf" "replica_slave" "$master_ip"
        cp "${master_dir}/config/users.acl" "${replica_dir}/config/users.acl"
        run_node "$container_name" "$replica_dir" "server" "$replica_ip"
        wait_for_ready "$container_name" -a "$PASSWORD"
    done

    # Deploy Sentinels
    if (( SENTINELS > 0 )); then
        local quorum=$(((SENTINELS / 2) + 1))
        for i in $(seq 1 "$SENTINELS"); do
            local sentinel_name="sentinel-${i}"
            local container_name="${BASE_CONTAINER_NAME}-${sentinel_name}"
            local sentinel_dir="${BASE_DIR}/${sentinel_name}"
            local sentinel_ip="${ip_base}.$((100 + i))"
            prepare_node_dirs "${sentinel_dir}"
            create_sentinel_config "${sentinel_dir}/config/sentinel.conf" "$master_ip" "$quorum"
            run_node "$container_name" "$sentinel_dir" "sentinel" "$sentinel_ip"
            wait_for_ready "$container_name" -a "$PASSWORD" -p 26379
        done
    fi
}

deploy_cluster() {
    log_info "Deploying Cluster ($SHARDS shards, $CLUSTER_REPLICAS replicas per shard)..."
    local ip_base
    ip_base=$(echo "$NETWORK_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
    local master_ips=()
    local seeds=""

    # Deploy Master Nodes
    for i in $(seq 0 $((SHARDS - 1))); do
        local master_name="sh${i}-node0"
        local container_name="${BASE_CONTAINER_NAME}-${master_name}"
        local master_dir="${BASE_DIR}/shard${i}/node0"
        local master_ip="${ip_base}.$((10 + i))"
        master_ips+=("$master_ip")

        prepare_node_dirs "${master_dir}"
        create_server_config "${master_dir}/config/server.conf" "cluster"
        create_acl_file "${master_dir}/config/users.acl" "cluster"
        run_node "$container_name" "$master_dir" "server" "$master_ip"
        wait_for_ready "$container_name" -a "$PASSWORD"
    done

    # Wait for all masters and build seeds list
    for i in $(seq 0 $((SHARDS - 1))); do
        local container_name="${BASE_CONTAINER_NAME}-sh${i}-node0"
        wait_for_ready "$container_name" -a "$PASSWORD"
        seeds+="${master_ips[i]}:6379 "
    done

    # Create Cluster
    log_info "Creating cluster with seeds: $seeds"
    docker exec "${BASE_CONTAINER_NAME}-sh0-node0" "$CLI_COMMAND" "${CLI_TLS_ARGS[@]}" --no-auth-warning -a "$PASSWORD" --cluster create $seeds --cluster-yes

    # Deploy and add Replica Nodes
    if (( CLUSTER_REPLICAS > 0 )); then
        sleep 2 # Give cluster time to settle before adding replicas
        for i in $(seq 0 $((SHARDS - 1))); do
            local master_name="${BASE_CONTAINER_NAME}-sh${i}-node0"
            local master_ip=${master_ips[i]}
            for j in $(seq 1 "$CLUSTER_REPLICAS"); do
                local replica_name="sh${i}-node${j}"
                local container_name="${BASE_CONTAINER_NAME}-${replica_name}"
                local replica_dir="${BASE_DIR}/shard${i}/node${j}"
                local replica_ip="${ip_base}.$(( (i+1)*20 + j ))"

                prepare_node_dirs "${replica_dir}"
                create_server_config "${replica_dir}/config/server.conf" "cluster"
                cp "${BASE_DIR}/shard${i}/node0/config/users.acl" "${replica_dir}/config/users.acl"
                run_node "$container_name" "$replica_dir" "server" "$replica_ip"
                wait_for_ready "$container_name" -a "$PASSWORD"

                log_info "Adding node $container_name as replica for $master_name"
                local master_id
                master_id=$(docker exec "$master_name" "$CLI_COMMAND" "${CLI_TLS_ARGS[@]}" --no-auth-warning -a "$PASSWORD" CLUSTER MYID | tr -d '\r')
                docker exec "$container_name" "$CLI_COMMAND" "${CLI_TLS_ARGS[@]}" --no-auth-warning -a "$PASSWORD" --cluster add-node "${replica_ip}:6379" "${master_ip}:6379" --cluster-slave --cluster-master-id "$master_id"
            done
        done
    fi
}

print_final_status() {
    log_info "Deployment Summary for '$DEPLOYMENT_ID':"
    echo -e "${YELLOW}------------------------------------------------------------------${NC}"
    (
        echo "CONTAINER_NAME IP_ADDRESS STATUS"
        docker ps --format '{{.Names}}' --filter "label=db-deploy-script=true" --filter "label=deployment_id=${DEPLOYMENT_ID}" | while read -r name; do
            echo "$name $(get_container_data $name 'ip') $(get_container_data $name 'status')"
        done | sed 's/^\///'
    ) | column -t

    if [[ "$TYPE" == "cluster" ]]; then
        log_info "Cluster Nodes Status:"
        sleep 2 # Allow cluster state to propagate
        docker exec "${BASE_CONTAINER_NAME}-sh0-node0" "$CLI_COMMAND" "${CLI_TLS_ARGS[@]}" --no-auth-warning -a "$PASSWORD" CLUSTER NODES
    fi

    echo -e "${YELLOW}------------------------------------------------------------------${NC}"
    log_info "Connect using ${CLI_COMMAND}:"
    echo "  Password: $PASSWORD"
    if [[ "$TLS_ENABLED" == true ]]; then
        echo "  TLS CA certificate: ${TLS_DIR}/ca.crt"
    fi
    case "$TYPE" in
        standalone)
            if [[ "$TLS_ENABLED" == true ]]; then
                echo "  docker exec -it ${BASE_CONTAINER_NAME}-standalone ${CLI_COMMAND} --tls --cacert /tls/ca.crt -h $(get_container_data "${BASE_CONTAINER_NAME}-standalone" 'ip') -a $PASSWORD"
            else
                echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -h $(get_container_data "${BASE_CONTAINER_NAME}-standalone" 'ip') -a $PASSWORD"
            fi
            ;;
        replica)
            echo "  # Connect to Master:"
            if [[ "$TLS_ENABLED" == true ]]; then
                echo "  docker exec -it ${BASE_CONTAINER_NAME}-node-0 ${CLI_COMMAND} --tls --cacert /tls/ca.crt -h $(get_container_data "${BASE_CONTAINER_NAME}-node-0" 'ip') -a $PASSWORD"
            else
                echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -h $(get_container_data "${BASE_CONTAINER_NAME}-node-0" 'ip') -a $PASSWORD"
            fi
            echo "  # Connect via Sentinel (for failover):"
            if [[ "$TLS_ENABLED" == true ]]; then
                echo "  docker exec -it ${BASE_CONTAINER_NAME}-sentinel-1 ${CLI_COMMAND} --tls --cacert /tls/ca.crt -h $(get_container_data "${BASE_CONTAINER_NAME}-sentinel-1" 'ip') -p 26379 -a $PASSWORD"
            else
                echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -h $(get_container_data "${BASE_CONTAINER_NAME}-sentinel-1" 'ip') -p 26379 -a $PASSWORD"
            fi
            ;;
        cluster)
            echo "  # Connect to any node in the cluster with -c for cluster mode:"
            if [[ "$TLS_ENABLED" == true ]]; then
                echo "  docker exec -it ${BASE_CONTAINER_NAME}-sh0-node0 ${CLI_COMMAND} --tls --cacert /tls/ca.crt -c -h $(get_container_data "${BASE_CONTAINER_NAME}-sh0-node0" 'ip') -a $PASSWORD"
            else
                echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -c -h $(get_container_data "${BASE_CONTAINER_NAME}-sh0-node0" 'ip') -a $PASSWORD"
            fi
            ;;
    esac

    echo " "
    echo "  # All files were created on: $BASE_DIR"

    echo -e "${YELLOW}------------------------------------------------------------------${NC}"
}


# --- Main Execution Logic ---

main() {
    trap handle_error ERR

    while getopts ":r:t:f:v:n:s:S:R:N:p:Tch" opt; do
        case ${opt} in
            r) REPO="$OPTARG" ;;
            t) TYPE="$OPTARG" ;;
            f) FLAVOR="$OPTARG" ;;
            v) VERSION="$OPTARG" ;;
            n) REPLICAS=$OPTARG ;;
            s) SENTINELS=$OPTARG ;;
            S) SHARDS=$OPTARG ;;
            R) CLUSTER_REPLICAS=$OPTARG ;;
            N) NAME_SUFFIX="$OPTARG" ;;
            p) PASSWORD="$OPTARG" ;;
            T) TLS_ENABLED=true ;;
            c) CLEAN_PREVIOUS=true ;;
            h) usage ;;
            \?) log_error "Invalid option: -$OPTARG" ;;
            :) log_error "Option -$OPTARG requires an argument." ;;
        esac
    done

    if [[ -n "$NAME_SUFFIX" ]]; then
        DEPLOYMENT_ID="${USER}-${NAME_SUFFIX}"
    else
        DEPLOYMENT_ID="${USER}"
    fi
    BASE_DIR="${BASE_DIR_PREFIX}/${DEPLOYMENT_ID}"
    NETWORK_NAME="${DEPLOYMENT_ID}-db-net"
    BASE_CONTAINER_NAME="${DEPLOYMENT_ID}"
    # --- End of dynamic names ---

    if [ "$CLEAN_PREVIOUS" = true ]; then
        cleanup
        if [[ -z "$REPO" ]] && [[ -z "$TYPE" ]]; then
            exit 0
        fi
    fi

    validate_inputs
    set_image_config
    set_cli_tls_args
    AUTO_CLEANUP_ON_ERROR=true
    create_network
    generate_tls_materials

    case "$TYPE" in
        standalone) deploy_standalone ;;
        replica) deploy_replica_set ;;
        cluster) deploy_cluster ;;
    esac

    AUTO_CLEANUP_ON_ERROR=false
    print_final_status
}

main "$@"
