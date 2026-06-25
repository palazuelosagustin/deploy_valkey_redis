# deploy_valkey_redis
Bash script to deploy different Redis and Valkey topologies with Docker containers.

# Installation

1. Clone the repo `git clone https://github.com/palazuelosagustin/deploy_valkey_redis.git`
2. Navigate to the project directory `cd deploy_valkey_redis`
3. Make the main script executable: `chmod +x deploy_valkey_redis.sh`
4. Run the script `./deploy_valkey_redis.sh -h`

# Usage

Deploys Redis or Valkey with various topologies using Docker.

Usage:

    deploy_valkey_redis.sh -r <repo> -t <type> [OPTIONS]

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

Behavior notes:

    - Inputs are validated before Docker resources are created.
    - If deployment fails after resources are created, the script cleans them up automatically.
    - The generated or provided password is printed in the final summary.
    - You can also provide the password through the DEPLOY_VALKEY_REDIS_PASSWORD environment variable.
    - TLS mode creates a local CA plus server/client certificates under the deployment directory.
    - TLS mode configures Redis or Valkey to use TLS-only listeners and TLS for replica, sentinel, and cluster traffic.

Example:

    deploy_valkey_redis.sh -c -r redis -f stack -t replica -n 2 -s 3 -v 7.2
    deploy_valkey_redis.sh -c -r valkey -t cluster -S 3 -R 1 -N my-cluster
    DEPLOY_VALKEY_REDIS_PASSWORD=secret123 ./deploy_valkey_redis.sh -c -r valkey -t standalone -N my-dev
    ./deploy_valkey_redis.sh -T -r redis -t standalone -N tls-demo

TLS notes:

    - TLS requires OpenSSL on the host running the script.
    - The script stores TLS assets under <deployment-dir>/tls.
    - The final summary prints the CA certificate path and TLS-aware client commands.
    - TLS client authentication is disabled, but the generated CA and client certificate are still created for local testing.
