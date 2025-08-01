#!/bin/bash
# set -euo pipefail

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
PASSWORD="password"
NAME_SUFFIX=""

# --- Variables set dynamically in main() ---
DEPLOYMENT_ID=""
BASE_DIR=""
NETWORK_NAME=""
BASE_CONTAINER_NAME=""

# --- Global Variables (set by functions) ---
NETWORK_SUBNET=""
IMAGE_NAME=""
BINARY=""
CLI_COMMAND=""
SENTINEL_COMMAND=""
JSON_MODULE=""
BLOOM_MODULE=""
SEARCH_MODULE=""

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
  -c                  Clean up a specific deployment before starting a new one.
  -h                  Show this help message.

Example:
  $0 -c -r redis -f stack -t replica -n 2 -s 3 -v 7.2
  $0 -c -r valkey -t cluster -S 3 -R 1 -N my-cluster
  $0 -c -r valkey -t cluster -S 3 -R 1 -N my-cluster

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
    docker rm -f $(docker ps -aq --filter "label=db-deploy-script=true" --filter "label=deployment_id=${DEPLOYMENT_ID}") > /dev/null 2>&1
    docker network rm "$NETWORK_NAME" > /dev/null 2>&1
    rm -rf "${BASE_DIR}" > /dev/null 2>&1
    log_info "Cleanup complete."
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

    case "$node_type" in
        standalone)
            true
            ;;
        replica_master)
            echo "masteruser replica-user" >> "$config_path"
            echo "masterauth $PASSWORD" >> "$config_path"
            ;;
        replica_slave)
            echo "masteruser replica-user" >> "$config_path"
            echo "masterauth $PASSWORD" >> "$config_path"
            echo "replicaof $replicaof_ip 6379" >> "$config_path"
            ;;
        cluster)
            cat >> "$config_path" <<EOF
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
requirepass $PASSWORD
masterauth $PASSWORD
EOF
            ;;
    esac

    [[ -n "$JSON_MODULE" ]] && echo "$JSON_MODULE" >> "$config_path"
    [[ -n "$BLOOM_MODULE" ]] && echo "$BLOOM_MODULE" >> "$config_path"
    [[ -n "$SEARCH_MODULE" ]] && echo "$SEARCH_MODULE" >> "$config_path"
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
}

# Usage: run_node <name> <dir_path> <node_type> <ip_address>
run_node() {
    local name="$1"
    local dir_path="$2"
    local node_type="$3"
    local ip_address="$4"

    local cmd="$BINARY"
    local conf_file_name="server.conf"

    if [[ "$node_type" == "sentinel" ]]; then
        cmd="$SENTINEL_COMMAND"
        conf_file_name="sentinel.conf"
    fi

    log_info "Starting container '$name' with IP ${ip_address}..."
    docker run -d --restart always \
        --name "$name" \
        --network "$NETWORK_NAME" \
        --ip "$ip_address" \
        --label "db-deploy-script=true" \
        --label "deployment_id=${DEPLOYMENT_ID}" \
        -v "${dir_path}/data:/data" \
        -v "${dir_path}/config:/config" \
        -v "${dir_path}/logs:/logs" \
        "${IMAGE_NAME}:${VERSION}" "$cmd" "/config/${conf_file_name}" >/dev/null
}

wait_for_ready() {
    local container_name="$1"
    local pass_arg=${2:-""}

    log_info "Waiting for '$container_name' to be ready..."
    for _ in {1..20}; do
        if docker exec "$container_name" "$CLI_COMMAND" $pass_arg --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
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
    mkdir -p "${dir}"/{config,data,logs} && chmod -R 777 "${dir}"/{config,data,logs}
    create_server_config "${dir}/config/server.conf" "standalone"
    create_acl_file "${dir}/config/users.acl" "standalone"
    run_node "$container_name" "$dir" "server" "$ip"
    wait_for_ready "$container_name" "-a $PASSWORD"
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
    mkdir -p "${master_dir}"/{config,data,logs} && chmod -R 777 "${master_dir}"/{config,data,logs}
    create_server_config "${master_dir}/config/server.conf" "replica_master"
    create_acl_file "${master_dir}/config/users.acl" "replica"
    run_node "$container_name" "$master_dir" "server" "$master_ip"
    wait_for_ready "$container_name" "-a $PASSWORD"

    # Deploy Replicas
    for i in $(seq 1 "$REPLICAS"); do
        local replica_name="node-${i}"
        local container_name="${BASE_CONTAINER_NAME}-${replica_name}"
        local replica_dir="${BASE_DIR}/${replica_name}"
        local replica_ip="${ip_base}.$((10 + i))"
        mkdir -p "${replica_dir}"/{config,data,logs} && chmod -R 777 "${replica_dir}"/{config,data,logs}
        create_server_config "${replica_dir}/config/server.conf" "replica_slave" "$master_ip"
        cp "${master_dir}/config/users.acl" "${replica_dir}/config/users.acl"
        run_node "$container_name" "$replica_dir" "server" "$replica_ip"
        wait_for_ready "$container_name" "-a $PASSWORD"
    done

    # Deploy Sentinels
    if (( SENTINELS > 0 )); then
        local quorum=$(((SENTINELS / 2) + 1))
        for i in $(seq 1 "$SENTINELS"); do
            local sentinel_name="sentinel-${i}"
            local container_name="${BASE_CONTAINER_NAME}-${sentinel_name}"
            local sentinel_dir="${BASE_DIR}/${sentinel_name}"
            local sentinel_ip="${ip_base}.$((100 + i))"
            mkdir -p "${sentinel_dir}"/{config,data,logs} && chmod -R 777 "${sentinel_dir}"/{config,data,logs}
            create_sentinel_config "${sentinel_dir}/config/sentinel.conf" "$master_ip" "$quorum"
            run_node "$container_name" "$sentinel_dir" "sentinel" "$sentinel_ip"
            wait_for_ready "$container_name" "-a $PASSWORD -p 26379"
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

        mkdir -p "${master_dir}"/{config,data,logs} && chmod -R 777 "${master_dir}"/{config,data,logs}
        create_server_config "${master_dir}/config/server.conf" "cluster"
        create_acl_file "${master_dir}/config/users.acl" "cluster"
        run_node "$container_name" "$master_dir" "server" "$master_ip"
        wait_for_ready "$container_name" "-a $PASSWORD"
    done

    # Wait for all masters and build seeds list
    for i in $(seq 0 $((SHARDS - 1))); do
        wait_for_ready "$container_name" "-a $PASSWORD"
        seeds+="${master_ips[i]}:6379 "
    done

    # Create Cluster
    log_info "Creating cluster with seeds: $seeds"
    docker exec "${BASE_CONTAINER_NAME}-sh0-node0" "$CLI_COMMAND" --no-auth-warning -a "$PASSWORD" --cluster create $seeds --cluster-yes

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

                mkdir -p "${replica_dir}"/{config,data,logs} && chmod -R 777 "${replica_dir}"/{config,data,logs}
                create_server_config "${replica_dir}/config/server.conf" "cluster"
                cp "${BASE_DIR}/shard${i}/node0/config/users.acl" "${replica_dir}/config/users.acl"
                run_node "$container_name" "$replica_dir" "server" "$replica_ip"
                wait_for_ready "$container_name" "-a $PASSWORD"

                log_info "Adding node $container_name as replica for $master_name"
                local master_id=$(docker exec "$master_name" "$CLI_COMMAND" --no-auth-warning -a "$PASSWORD" CLUSTER MYID | tr -d '\r')
                docker exec "$container_name" "$CLI_COMMAND" --no-auth-warning -a "$PASSWORD" --cluster add-node "${replica_ip}:6379" "${master_ip}:6379" --cluster-slave --cluster-master-id "$master_id"
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
        docker exec ${BASE_CONTAINER_NAME}-sh0-node0 "$CLI_COMMAND" --no-auth-warning -a "$PASSWORD" CLUSTER NODES
    fi

    echo -e "${YELLOW}------------------------------------------------------------------${NC}"
    log_info "Connect using ${CLI_COMMAND}:"
    case "$TYPE" in
        standalone)
            echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -h $(get_container_data "${BASE_CONTAINER_NAME}-standalone" 'ip') -a $PASSWORD"
            ;;
        replica)
            echo "  # Connect to Master:"
            echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -h $(get_container_data "${BASE_CONTAINER_NAME}-node-0" 'ip') -a $PASSWORD"
            echo "  # Connect via Sentinel (for failover):"
            echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -h $(get_container_data "${BASE_CONTAINER_NAME}-sentinel-1" 'ip') -p 26379 -a $PASSWORD"
            ;;
        cluster)
            echo "  # Connect to any node in the cluster with -c for cluster mode:"
            echo "  docker run --rm -it --network ${NETWORK_NAME} ${IMAGE_NAME}:${VERSION} ${CLI_COMMAND} -c -h $(get_container_data "${BASE_CONTAINER_NAME}-sh0-node0" 'ip') -a $PASSWORD"
            ;;
    esac

    echo " "
    echo "  # All files were created on: $BASE_DIR"

    echo -e "${YELLOW}------------------------------------------------------------------${NC}"
}


# --- Main Execution Logic ---

main() {
    while getopts ":r:t:f:v:n:s:S:R:N:ch" opt; do
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

    if [[ -z "$REPO" ]] || [[ -z "$TYPE" ]]; then
        log_warn "Missing required arguments."
        usage
    else
        create_network
        set_image_config

        case "$TYPE" in
            standalone) deploy_standalone ;;
            replica) deploy_replica_set ;;
            cluster)
                if (( SHARDS < 3 )); then
                    log_warn "Cluster requires at least 3 master shards. Setting shards to 3."
                    SHARDS=3
                fi
                deploy_cluster
                ;;
            *) log_error "Invalid deployment type '$TYPE'. Use 'standalone', 'replica', or 'cluster'." ;;
        esac

        print_final_status
    fi
}

main "$@"
