# External Datastore

> Module 06 · Lesson 03 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents

- [Overview](#overview)
- [When to Use an External Datastore](#when-to-use-an-external-datastore)
- [Supported Datastores](#supported-datastores)
- [What k3s Stores in the Database](#what-k3s-stores-in-the-database)
- [Setting Up MySQL / MariaDB](#setting-up-mysql--mariadb)
- [Setting Up PostgreSQL](#setting-up-postgresql)
- [Bootstrapping k3s with an External Datastore](#bootstrapping-k3s-with-an-external-datastore)
- [Adding More Server Nodes](#adding-more-server-nodes)
- [Connection Pooling Considerations](#connection-pooling-considerations)
- [HA Database Setups](#ha-database-setups)
- [Connecting Agents](#connecting-agents)
- [Migrating from SQLite to External Datastore](#migrating-from-sqlite-to-external-datastore)
- [Datastore vs Embedded etcd: Decision Guide](#datastore-vs-embedded-etcd-decision-guide)
- [Lab](#lab)

---

## Overview

While embedded etcd is the recommended HA path for most users (Module 06 Lesson 02), k3s also supports **external datastores** via the `--datastore-endpoint` flag. This lets you use an existing managed database — MySQL, MariaDB, PostgreSQL, or etcd — that your organisation already operates.

The design philosophy: k3s translates all Kubernetes API objects (Pods, Services, Secrets, etc.) into rows in a relational table. The kine library (Kubernetes IS Not Etcd) provides an etcd-compatible interface over SQL, so the rest of k3s doesn't need to know it's talking to MySQL.

```mermaid
flowchart TD
    API["k3s API Server"] --> KINE["kine library<br/>(etcd translation layer)"]
    KINE --> MYSQL["MySQL / MariaDB<br/>mysql://k3s@host/k3s"]
    KINE --> PG["PostgreSQL<br/>postgres://k3s@host/k3s"]
    KINE --> ETCD["External etcd<br/>https://etcd-host:2379"]
    KINE --> SQLITE["SQLite (default)<br/>/var/lib/rancher/k3s/server/db/state.db"]
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## When to Use an External Datastore

```mermaid
flowchart TD
    A{"Do you have an existing managed DB<br/>with SLAs and DBA support?"} -->|Yes| B["External Datastore<br/>(MySQL / MariaDB / PostgreSQL)"]
    A -->|No| C{"Need HA?"}
    C -->|Yes| D["Embedded etcd HA<br/>(recommended — self-contained)"]
    C -->|No| E["SQLite single-node<br/>(development / edge)"]
    B --> F{"Existing DB is HA?<br/>(Galera, Patroni, RDS Multi-AZ)"}
    F -->|Yes| G["Full HA k3s cluster<br/>(no single point of failure)"]
    F -->|No| H["Single-point DB failure<br/>→ k3s control plane unavailable"]
```

**Use an external datastore when:**
- You already have a managed MySQL/PostgreSQL cluster (AWS RDS, Azure Database for MySQL, Google Cloud SQL)
- Your DBA team manages the database lifecycle (backups, patching, failover)
- You want to share one database cluster across multiple k3s environments
- You need point-in-time recovery through existing database backup infrastructure
- Your organisation has compliance requirements that mandate specific database platforms

**Use embedded etcd when:**
- You want a fully self-contained cluster with no external dependencies
- You don't have existing database infrastructure
- You want simpler operations (fewer moving parts to monitor)
- You're building greenfield infrastructure and can choose freely

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Supported Datastores

| Datastore | Connection String Prefix | Notes |
|-----------|--------------------------|-------|
| MySQL / MariaDB | `mysql://` | Most common external option; MariaDB 10.3+ |
| PostgreSQL | `postgres://` | Fully supported; versions 11+ |
| External etcd | `https://` | Use existing etcd cluster with client certs |
| SQLite | *(default, no flag)* | Single node only; not HA |
| Embedded etcd | *(via `--cluster-init`)* | HA, no external DB; recommended for new clusters |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## What k3s Stores in the Database

Understanding the database schema helps you estimate database size and design backup strategies. The kine library creates a single table:

```sql
-- kine creates this table
CREATE TABLE IF NOT EXISTS kine (
    id          INTEGER     PRIMARY KEY AUTOINCREMENT,
    name        TEXT,           -- key path, e.g. "/registry/pods/default/my-pod"
    created     INTEGER,        -- revision when created
    deleted     INTEGER,        -- revision when deleted (0 = not deleted)
    create_revision INTEGER,
    prev_revision INTEGER,
    lease       INTEGER,
    value       BLOB,           -- the serialised API object (JSON)
    old_value   BLOB            -- previous value for watch events
);
CREATE INDEX IF NOT EXISTS kine_name_index ON kine (name);
CREATE INDEX IF NOT EXISTS kine_name_id_index ON kine (name, id);
```

Each Kubernetes object (Pod, Service, Deployment, Secret, etc.) becomes one or more rows. Size estimates:

| Cluster size | Approx DB size |
|-------------|---------------|
| 10 pods, 5 services | ~10 MB |
| 100 pods, 50 services | ~50 MB |
| 1000 pods, 200 services | ~200 MB |
| 10,000 objects | ~500 MB–1 GB |

> **Compaction:** The database grows over time as old revisions accumulate. k3s runs a periodic compaction that deletes old revisions. This is automatic — but on very busy clusters, monitor database size and run manual compaction if needed (`k3s etcd-snapshot` triggers compaction as a side effect).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Setting Up MySQL / MariaDB

```sql
-- Run on your MySQL/MariaDB server as root
CREATE DATABASE k3s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'k3s'@'%' IDENTIFIED BY 'StrongPassword123!';
GRANT ALL PRIVILEGES ON k3s.* TO 'k3s'@'%';
FLUSH PRIVILEGES;

-- Verify the user can connect and create tables
-- (k3s will auto-create the kine table on first start)
```

> **MariaDB note:** k3s works with MariaDB 10.3+. Use the `mysql://` prefix — the MariaDB connector is compatible. For MariaDB Galera Cluster, point k3s at the cluster's VIP or ProxySQL endpoint.

Verify connectivity from your k3s server nodes before installing:

```bash
# Install mysql client
sudo apt-get install -y mysql-client   # Ubuntu/Debian
sudo dnf install -y mysql              # RHEL/Fedora

# Test connection
mysql -h <DB_HOST> -u k3s -pStrongPassword123! k3s -e "SELECT 1"
# Expected: 1

# Test that k3s user can create tables
mysql -h <DB_HOST> -u k3s -pStrongPassword123! k3s \
  -e "CREATE TABLE test (id INT); DROP TABLE test;"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Setting Up PostgreSQL

```sql
-- Run as PostgreSQL superuser (postgres user)
CREATE USER k3s WITH PASSWORD 'StrongPassword123!';
CREATE DATABASE k3s OWNER k3s;
GRANT ALL PRIVILEGES ON DATABASE k3s TO k3s;

-- For PostgreSQL 15+ you also need:
GRANT USAGE ON SCHEMA public TO k3s;
GRANT ALL ON SCHEMA public TO k3s;
```

Verify connectivity:

```bash
# Test connection
psql "postgres://k3s:StrongPassword123!@<DB_HOST>:5432/k3s" -c "SELECT 1"
# Expected: 1

# Test from the k3s server node (ensure pg client is installed)
psql "postgres://k3s:StrongPassword123!@<DB_HOST>:5432/k3s" \
  -c "CREATE TABLE test (id INT); DROP TABLE test;"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Bootstrapping k3s with an External Datastore

**Never put the connection string in process flags** — it will appear in `ps aux` output. Always use the config file:

```yaml
# /etc/rancher/k3s/config.yaml (create before installing)
# (mode 600 — contains database password)

# MySQL / MariaDB
datastore-endpoint: "mysql://k3s:StrongPassword123!@tcp(192.168.1.50:3306)/k3s"
tls-san:
  - "192.168.1.100"           # load balancer VIP
  - "k3s-api.example.com"     # DNS name for the API

# Disable components you don't need (reduces memory usage)
disable:
  - traefik      # if using NGINX or external ingress
```

```bash
sudo chmod 600 /etc/rancher/k3s/config.yaml

# Install k3s (reads config.yaml automatically)
curl -sfL https://get.k3s.io | sh -

# Verify the kine table was created
mysql -h 192.168.1.50 -u k3s -pStrongPassword123! k3s -e "SHOW TABLES;"
# +-------------------+
# | Tables_in_k3s     |
# +-------------------+
# | kine              |
# +-------------------+

kubectl get nodes
```

For PostgreSQL, the connection string format is:

```yaml
# TLS disabled (dev/internal)
datastore-endpoint: "postgres://k3s:StrongPassword123!@192.168.1.50:5432/k3s?sslmode=disable"

# TLS enabled (verify CA)
datastore-endpoint: "postgres://k3s:StrongPassword123!@192.168.1.50:5432/k3s?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca.crt"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Adding More Server Nodes

With an external datastore there is no `--cluster-init` flag and no peer-to-peer raft consensus — the database is the shared coordination mechanism. Simply point each server at the same database:

```mermaid
graph LR
    subgraph "Database HA Layer"
        DB["MySQL Primary<br/>192.168.1.50"] <-->|"replication"| DBR["MySQL Replica<br/>192.168.1.51"]
    end
    S1["k3s server-01"] --> DB
    S2["k3s server-02"] --> DB
    S3["k3s server-03"] --> DB
    LB["Load Balancer<br/>192.168.1.100:6443"] --> S1 & S2 & S3
    W1["Agent nodes"] --> LB
```

```yaml
# /etc/rancher/k3s/config.yaml on server-02 and server-03
datastore-endpoint: "mysql://k3s:StrongPassword123!@tcp(192.168.1.50:3306)/k3s"
token: "K10abc123::server:def456..."     # must match server-01
tls-san:
  - "192.168.1.100"
  - "k3s-api.example.com"
```

```bash
# On server-02 and server-03
sudo chmod 600 /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | sh -

# Verify all servers appear
kubectl get nodes
```

> **No leader election needed:** Unlike embedded etcd (which uses raft), external-datastore k3s uses optimistic locking on the SQL database for coordination. All server nodes can serve API requests simultaneously. There is no "leader" election — the database itself provides consistency via transactions.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Connection Pooling Considerations

Each k3s server node opens multiple connections to the database. With 3 server nodes and default settings, expect 30–60 total connections. For large clusters or busy databases, this can be a concern.

```mermaid
graph LR
    S1["k3s server-01<br/>~20 connections"] --> DB["MySQL<br/>max_connections: 151"]
    S2["k3s server-02<br/>~20 connections"] --> DB
    S3["k3s server-03<br/>~20 connections"] --> DB
    TOTAL["Total: ~60 connections<br/>(well within default limits)"]
```

For larger deployments, insert **ProxySQL** or **PgBouncer** between k3s and the database:

```
k3s servers → ProxySQL (connection pooling) → MySQL Primary
                                             → MySQL Replica (read queries)
```

Set connection limits on the k3s user as a safeguard:

```sql
-- MySQL: limit connections per user
ALTER USER 'k3s'@'%' WITH MAX_USER_CONNECTIONS 50;

-- Check current connections
SELECT user, host, db, command, time 
FROM information_schema.processlist 
WHERE user = 'k3s';
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## HA Database Setups

The database is a single point of failure unless it is itself highly available.

### MariaDB Galera Cluster

Galera provides synchronous multi-master replication. All nodes are writable. For k3s, point the connection string at a VIP managed by Keepalived, or use ProxySQL to route writes to the primary:

```mermaid
flowchart LR
    K3S["k3s servers"] --> VIP["Keepalived VIP<br/>192.168.1.50"]
    VIP --> G1["Galera node-1<br/>(active)"]
    VIP -.->|"failover"| G2["Galera node-2"]
    VIP -.->|"failover"| G3["Galera node-3"]
    G1 <-->|"wsrep sync"| G2 <-->|"wsrep sync"| G3
```

### PostgreSQL + Patroni

Patroni manages automatic failover for PostgreSQL. Use HAProxy or a virtual IP to route k3s connections to the current primary:

```bash
# Connection string for Patroni-managed PostgreSQL
datastore-endpoint: "postgres://k3s:pass@patroni-vip:5432/k3s?sslmode=disable"
```

### Managed cloud databases

Cloud-managed databases (AWS RDS Multi-AZ, Google Cloud SQL HA, Azure Database for MySQL Flexible Server) handle failover automatically. Use the provided endpoint — they handle DNS failover for you:

```yaml
# AWS RDS Multi-AZ example
datastore-endpoint: "mysql://k3s:pass@tcp(my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com:3306)/k3s"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Connecting Agents

Agents don't need the datastore endpoint — they only talk to the server's API via the WebSocket tunnel:

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<LB_IP>:6443 \
  K3S_TOKEN=<NODE_TOKEN> \
  sh -
```

The `NODE_TOKEN` must be copied from one of the server nodes:

```bash
# On any server node
sudo cat /var/lib/rancher/k3s/server/node-token
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Migrating from SQLite to External Datastore

> ⚠️ This is a **destructive** operation — the SQLite data does NOT migrate automatically. You must back up and restore all workloads manually.

```mermaid
flowchart TD
    BACKUP["Step 1: Backup all resources<br/>kubectl get all --all-namespaces -o yaml"] --> STOP["Step 2: Stop k3s<br/>systemctl stop k3s"]
    STOP --> EXPORT["Step 3: Export SQLite (optional reference)<br/>sqlite3 state.db .dump > backup.sql"]
    EXPORT --> CONFIG["Step 4: Add datastore-endpoint<br/>to /etc/rancher/k3s/config.yaml"]
    CONFIG --> REMOVE["Step 5: Remove old SQLite state<br/>rm -rf /var/lib/rancher/k3s/server/db"]
    REMOVE --> START["Step 6: Start k3s<br/>(creates fresh DB via kine)"]
    START --> RESTORE["Step 7: Re-apply all workloads<br/>kubectl apply -f cluster-backup.yaml"]
```

```bash
# Step 1: Backup all cluster resources
kubectl get all --all-namespaces -o yaml > cluster-backup.yaml
kubectl get configmaps --all-namespaces -o yaml >> cluster-backup.yaml
kubectl get secrets --all-namespaces -o yaml >> cluster-backup.yaml
kubectl get pvc --all-namespaces -o yaml >> cluster-backup.yaml

# Step 2: Stop k3s
sudo systemctl stop k3s

# Step 3: Export SQLite data (optional — for reference only)
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db .dump > sqlite-dump.sql

# Step 4: Update config.yaml with datastore-endpoint
sudo vim /etc/rancher/k3s/config.yaml
# Add: datastore-endpoint: "mysql://k3s:pass@tcp(192.168.1.50:3306)/k3s"

# Step 5: Remove old SQLite state (k3s will error if both exist)
sudo rm -rf /var/lib/rancher/k3s/server/db

# Step 6: Start k3s (creates fresh kine table)
sudo systemctl start k3s
sudo systemctl status k3s

# Step 7: Re-apply critical resources
kubectl apply -f cluster-backup.yaml
```

> **Note:** User workloads stored in SQLite are **not** automatically migrated. They must be re-applied from backup. Internal k3s state (node certificates, etc.) is regenerated on first boot.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Datastore vs Embedded etcd: Decision Guide

| Factor | External Datastore | Embedded etcd |
|--------|-------------------|---------------|
| Operational complexity | Higher (manage DB + k3s) | Lower (fully self-contained) |
| Existing DB team / SLAs | ✅ Leverage existing ops | ❌ New system to manage |
| Network dependency | Yes (DB must be reachable) | No (etcd is colocated) |
| Point-in-time recovery | Via DB backup tools (mysqldump, pg_dump, cloud snapshots) | Via etcd snapshots (`k3s etcd-snapshot`) |
| Storage efficiency | Depends on DB overhead | ~100 MB etcd WAL |
| Write latency | Slightly higher (network round-trip to DB) | Lower (local writes) |
| Number of server nodes | Unlimited (all connect to DB) | Odd numbers: 3, 5, 7 (raft quorum) |
| Failure domain | DB failure = control plane down | etcd majority failure = control plane down |
| Backup tooling | Standard DB tools | k3s built-in snapshot commands |
| Recommendation | When existing DB infra exists | **Default choice** for new clusters |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

### Prerequisites

- A MariaDB or MySQL server reachable from your k3s host (or run one locally)
- k3s not yet installed (fresh install) OR use the migration procedure above

### Option A: Quick lab with local MariaDB container

```bash
# 1. Run MariaDB locally (for testing only — use a real DB for production)
podman run -d --name mariadb-k3s \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=k3s \
  -e MYSQL_USER=k3s \
  -e MYSQL_PASSWORD=k3spass \
  -p 3306:3306 \
  docker.io/mariadb:11

# 2. Wait for MariaDB to be ready
sleep 10

# 3. Verify connectivity
mysql -h 127.0.0.1 -u k3s -pk3spass k3s -e "SELECT 1"

# 4. Configure k3s to use it
sudo tee /etc/rancher/k3s/config.yaml <<'EOF'
datastore-endpoint: "mysql://k3s:k3spass@tcp(127.0.0.1:3306)/k3s"
EOF
sudo chmod 600 /etc/rancher/k3s/config.yaml

# 5. Install k3s (or restart if already installed — it will use new config)
curl -sfL https://get.k3s.io | sh -

# 6. Verify cluster is using the database
kubectl get nodes
mysql -h 127.0.0.1 -u k3s -pk3spass k3s -e "SELECT COUNT(*) as rows FROM kine;"
# rows should be > 100 (all the default k3s API objects)
```

### Option B: Inspect the kine table

```bash
# See what Kubernetes objects look like in the database
mysql -h 127.0.0.1 -u k3s -pk3spass k3s -e "
SELECT name, LENGTH(value) as size_bytes
FROM kine
WHERE name LIKE '/registry/pods/%'
LIMIT 10;
"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
