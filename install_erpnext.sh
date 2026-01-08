#!/bin/bash
set -e

# Configuration
NET="captain-overlay-network"
DB_PASS="DbPassword"
APP_DOMAIN="erp.codexters.io"
# Service Names
SVC_DB="erp-mariadb"
SVC_REDIS="erp-redis"
SVC_BACKEND="erp-backend"
SVC_FRONTEND="srv-captain--erp" # EXISTING CapRover App created, changes the container port to 8080

echo "--- Creating Volumes ---"
docker volume create erp_db_data
docker volume create erp_redis_data
docker volume create erp_sites
docker volume create erp_assets

echo "--- Deploying MariaDB ---"
# Check if exists, remove if needed or just update? Better to remove for clean install if new.
# Provided user said they deleted apps, so likely clean.
docker service rm $SVC_DB || true
docker service create \
  --name $SVC_DB \
  --network $NET \
  --replicas 1 \
  --mount type=volume,source=erp_db_data,target=/var/lib/mysql \
  --env MYSQL_ROOT_PASSWORD=$DB_PASS \
  --env MYSQL_DATABASE=erpnext \
  --env MYSQL_USER=erpnext \
  --env MYSQL_PASSWORD=$DB_PASS \
  mariadb:10.6 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci \
  --skip-character-set-client-handshake \
  --innodb-file-format=Barracuda \
  --innodb-large-prefix=1 \
  --innodb-file-per-table=1

echo "--- Deploying Redis ---"
docker service rm $SVC_REDIS || true
docker service create \
  --name $SVC_REDIS \
  --network $NET \
  --replicas 1 \
  --mount type=volume,source=erp_redis_data,target=/data \
  redis:6.2-alpine

echo "--- Deploying Backend ---"
docker service rm $SVC_BACKEND || true
docker service create \
  --name $SVC_BACKEND \
  --network $NET \
  --replicas 1 \
  --mount type=volume,source=erp_sites,target=/home/frappe/frappe-bench/sites \
  --mount type=volume,source=erp_assets,target=/home/frappe/frappe-bench/sites/assets \
  --env DB_HOST=$SVC_DB \
  --env DB_PORT=3306 \
  --env REDIS_CACHE=$SVC_REDIS:6379/1 \
  --env REDIS_QUEUE=$SVC_REDIS:6379/0 \
  --env REDIS_SOCKETIO=$SVC_REDIS:6379/2 \
  --env SOCKETIO_PORT=9000 \
  frappe/erpnext:v15

echo "--- Waiting for Backend to Initialize (30s) ---"
sleep 30

echo "--- Updating Frontend (CapRover Service) ---"
# We hijack the existing srv-captain--erp service
docker service update \
  --image frappe/erpnext:v15 \
  --args "nginx-entrypoint.sh" \
  --mount-add type=volume,source=erp_sites,target=/home/frappe/frappe-bench/sites \
  --mount-add type=volume,source=erp_assets,target=/home/frappe/frappe-bench/sites/assets \
  --env-add BACKEND=$SVC_BACKEND:8000 \
  --env-add SOCKETIO=$SVC_BACKEND:9000 \
  --env-add FRAPPE_SITE_NAME_HEADER=$APP_DOMAIN \
  --env-add UPSTREAM_REAL_IP_ADDRESS=127.0.0.1 \
  --env-add UPSTREAM_REAL_IP_HEADER=X-Forwarded-For \
  --env-add UPSTREAM_REAL_IP_RECURSIVE=off \
  --env-add PROXY_READ_TIMEOUT=120 \
  --env-add CLIENT_MAX_BODY_SIZE=50m \
  $SVC_FRONTEND

echo "--- Deployment Commands Sent ---"
