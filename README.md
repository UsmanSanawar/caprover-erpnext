# ERPNext v15 in Caprover as App Installation Reference

## Overview
This document details the manual installation of ERPNext v15 on CapRover using Docker Swarm. The setup uses a microservices architecture with a custom stack to ensure proper static asset handling and database isolation.

## Installation Architecture

### Services
The installation consists of 4 main Docker Services running on the `captain-overlay-network`:

| Service Name | Docker Image | Role | Internal Port |
| :--- | :--- | :--- | :--- |
| **`srv-captain--erp`** | `frappe/erpnext:v15` | **Frontend** (Nginx/Web Server). Exposed as CapRover App. | 8080 (mapped to 80) |
| **`erp-backend`** | `frappe/erpnext:v15` | **Backend** (Gunicorn/Python). Executes logic. | 8000 |
| **`erp-mariadb`** | `mariadb:10.6` | **Database**. Dedicated instance for ERPNext. | 3306 |
| **`erp-redis`** | `redis:6.2-alpine` | **Cache/Queue**. Shared Redis instance. | 6379 |

### Data Persistence (Volumes)
All data is stored in named Docker Volumes. These persist independently of containers.

| Volume Name | Mount Path (Container) | Description |
| :--- | :--- | :--- |
| **`erp_sites`** | `/home/frappe/frappe-bench/sites` | Site configurations, uploads, and logs. |
| **`erp_assets`** | `/home/frappe/frappe-bench/sites/assets` | Static files (CSS, JS). Shared between Backend & Frontend. |
| **`erp_db_data`** | `/var/lib/mysql` | MariaDB database files. |
| **`erp_redis_data`** | `/data` | Redis persistence data. |

**Host Location**: Physical data is stored at `/var/lib/docker/volumes/<volume_name>/_data` on the host server.

## Configuration Details

### Database Connection
The site is configured to connect to the dedicated MariaDB service, not localhost.
- **DB Host**: `erp-mariadb`
- **Socket**: Disabled (using TCP)
- **Root Password**: `YourDbPassword`
- **User Password**: `YourDbPassword`

### Redis Connection
- **Cache**: `redis://erp-redis:6379/1`
- **Queue**: `redis://erp-redis:6379/0`
- **SocketIO**: `redis://erp-redis:6379/2`

## Administration & Maintenance

### Accessing the Server
**URL**: [http://erp.domain.com](http://erp.domain.com) (Enable HTTPS in CapRover)
**Credentials**:
- **User**: `Administrator`
- **Password**: `admin`

### Accessing Files & Logs (Command Line)
To run `bench` commands or check logs, you must enter the **backend** container.

1.  **Find the Container ID**:
    ```bash
    docker ps -f name=erp-backend -q
    ```
2.  **Enter the Container**:
    ```bash
    docker exec -it <container_id> bash
    
    # Or as a one-liner:
    docker exec -it $(docker ps -f name=erp-backend -q) bash
    ```
3.  **Common Commands**:
    -   `cd sites`: Go to site directory.
    -   `bench --site erp.domain.com console`: Open Python console.
    -   `tail -f logs/web.log`: View application logs.

### Restoring/Backing Up
Since data is in volumes, standard Docker backup strategies apply.
- **Backup**: Run `bench backup` inside the backend container. Files are saved to `sites/erp.domain.com/private/backups`.
- **Download**: You can download backups via the ERPNext UI ("Download Backups") or copy them from the volume path.

## Installation Steps Followed
1.  **Image Pull**: Pulled `frappe/erpnext:v15` and `mariadb:10.6`.
2.  **Volume Creation**: Created the 4 named volumes manually.
3.  **Service Deployment**:
    -   Deployed `erp-mariadb` and `erp-redis`.
    -   Deployed `erp-backend` linked to these services.
    -   Updated the existing CapRover app `erp` (Frontend) to use the correct image and mount the shared `erp_assets` volume.
4.  **Site Initialization**:
    -   Configured global `db_host` and `redis` settings in `common_site_config.json`.
    -   Ran `bench new-site erp.domain.com` manually to install the database tables.

This setup bypasses the standard CapRover One-Click limitations to provide a production-ready, persistent environment.

## Exact Installation Log (Step-by-Step)
For future reference, these are the exact commands used to install the system manually via SSH.

### 1. Create Docker Volumes
```bash
docker volume create erp_db_data
docker volume create erp_redis_data
docker volume create erp_sites
docker volume create erp_assets
```

### 2. Deploy Background Services
**MariaDB**
```bash
docker service create \
  --name erp-mariadb \
  --network captain-overlay-network \
  --replicas 1 \
  --mount type=volume,source=erp_db_data,target=/var/lib/mysql \
  --env MYSQL_ROOT_PASSWORD=YourDbPassword \
  --env MYSQL_DATABASE=erpnext \
  --env MYSQL_USER=erpnext \
  --env MYSQL_PASSWORD=YourDbPassword \
  mariadb:10.6 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci \
  --skip-character-set-client-handshake \
  --innodb-file-format=Barracuda \
  --innodb-large-prefix=1 \
  --innodb-file-per-table=1
```

**Redis**
```bash
docker service create \
  --name erp-redis \
  --network captain-overlay-network \
  --replicas 1 \
  --mount type=volume,source=erp_redis_data,target=/data \
  redis:6.2-alpine
```

**ERPNext Backend**
```bash
docker service create \
  --name erp-backend \
  --network captain-overlay-network \
  --replicas 1 \
  --mount type=volume,source=erp_sites,target=/home/frappe/frappe-bench/sites \
  --mount type=volume,source=erp_assets,target=/home/frappe/frappe-bench/sites/assets \
  --env DB_HOST=erp-mariadb \
  --env DB_PORT=3306 \
  --env REDIS_CACHE=erp-redis:6379/1 \
  --env REDIS_QUEUE=erp-redis:6379/0 \
  --env REDIS_SOCKETIO=erp-redis:6379/2 \
  --env SOCKETIO_PORT=9000 \
  frappe/erpnext:v15
```

### 3. Update Frontend (CapRover Service)
*Assumes CapRover app `erp` was already created manually.*
```bash
docker service update \
  --image frappe/erpnext:v15 \
  --args "nginx-entrypoint.sh" \
  --mount-add type=volume,source=erp_sites,target=/home/frappe/frappe-bench/sites \
  --mount-add type=volume,source=erp_assets,target=/home/frappe/frappe-bench/sites/assets \
  --env-add BACKEND=erp-backend:8000 \
  --env-add SOCKETIO=erp-backend:9000 \
  --env-add FRAPPE_SITE_NAME_HEADER=erp.domain.com \
  --env-add UPSTREAM_REAL_IP_ADDRESS=127.0.0.1 \
  --env-add UPSTREAM_REAL_IP_HEADER=X-Forwarded-For \
  --env-add UPSTREAM_REAL_IP_RECURSIVE=off \
  --env-add PROXY_READ_TIMEOUT=120 \
  --env-add CLIENT_MAX_BODY_SIZE=50m \
  srv-captain--erp
```

### 4. Configure Site Settings
Run inside the backend container to point it to the correct DB/Redis hosts (since automatic config failed).
```bash
# Get Container ID
CID=$(docker ps -f name=erp-backend -q)

docker exec $CID bench set-config -g db_host erp-mariadb
docker exec $CID bench set-config -g redis_cache redis://erp-redis:6379/1
docker exec $CID bench set-config -g redis_queue redis://erp-redis:6379/0
docker exec $CID bench set-config -g redis_socketio redis://erp-redis:6379/2
```

### 5. Install Site
The final step to create the database tables.
```bash
docker exec $CID bench new-site erp.domain.com \
  --mariadb-root-password YourDbPassword \
  --admin-password admin \
  --db-password YourDbPassword \
  --install-app erpnext \
  --force
```