# deploy_valkey_redis
Bash script to deploy different flavors of redis and valkey with dcocker containers

# Installation

1. Clone the repo `git clone https://github.com/palazuelosagustin/deploy_valkey_redis.git`
2. Navigate to the project directry `cd deploy_valkey_redis`
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
  
  -c                  Clean up a specific deployment before starting a new one.

  -h                  Show this help message.

Example:

  deploy_valkey_redis.sh -c -r redis -f stack -t replica -n 2 -s 3 -v 7.2
  
  deploy_valkey_redis.sh -c -r valkey -t cluster -S 3 -R 1 -N my-cluster
  
  deploy_valkey_redis.sh -c -N my-cluster
