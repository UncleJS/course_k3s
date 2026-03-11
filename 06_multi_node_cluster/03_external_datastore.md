# External Datastore
> Module 06 · Lesson 03 | [↑ Course Index](../README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](../README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](../LICENSE.md)

## Table of Contents
- [Overview](#overview)
- [When to Use an External Datastore](#when-to-use-an-external-datastore)
- [Supported Datastores](#supported-datastores)
- [Setting Up MySQL / MariaDB](#setting-up-mysql--mariadb)
- [Setting Up PostgreSQL](#setting-up-postgresql)
- [Bootstrapping k3s with an External Datastore](#bootstrapping-k3s-with-an-external-datastore)
- [Adding More Server Nodes](#adding-more-server-nodes)
- [Connecting Agents](#connecting-agents)
- [Migrating from SQLite to External Datastore](#migrating-from-sqlite-to-external-datastore)
- [Datastore vs Embedded etcd: Decision Guide](#datastore-vs-embedded-etcd-decision-guide)
- [Lab](#lab)

---

## Overview

While embedded etcd is the recommended HA path for most users, k3s also supports **external datastores** via the `--datastore-endpoint` flag. This lets you use an existing managed database (MySQL, MariaDB, PostgreSQL, or etcd) that your organisation already operates — useful when you have DBA teams and SLAs around those databases.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## When to Use an External Datastore

```mermaid
flowchart TD
    A{Do you have an existing managed DB with SLAs?} -->|Yes| B[External Datastore]
    A -->|No| C{Need HA?}
    C -->|Yes| D[Embedded etcd HA]
    C -->|No| E[SQLite single-node]
    B --> F[MySQL / MariaDB / PostgreSQL]
```

Use an external datastore when:
- You already have a managed MySQL/PostgreSQL cluster (e.g., AWS RDS, Azure Database)
- Your DBA team wants to manage the database lifecycle
- You want to share one database cluster across multiple k3s clusters
- You need point-in-time recovery via existing DB backup infrastructure

Use embedded etcd when:
- You want a fully self-contained cluster
- You don't have existing database infrastructure
- You want simpler operations (no external dependency)

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Supported Datastores

| Datastore | Connection String Prefix | Notes |
|-----------|--------------------------|-------|
| MySQL / MariaDB | `mysql://` | Most common external option |
| PostgreSQL | `postgres://` | Fully supported |
| External etcd | `https://` | Use existing etcd cluster |
| SQLite | *(default, no flag needed)* | Single node only |
| Embedded etcd | *(via `--cluster-init`)* | HA, no external DB |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Setting Up MySQL / MariaDB

```sql
-- Run on your MySQL/MariaDB server
CREATE DATABASE k3s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'k3s'@'%' IDENTIFIED BY 'StrongPassword123!';
GRANT ALL PRIVILEGES ON k3s.* TO 'k3s'@'%';
FLUSH PRIVILEGES;
```

> **MariaDB note:** k3s works with MariaDB 10.3+. Use the `mysql://` prefix — the MariaDB driver is compatible.

Verify connectivity from your server nodes:
```bash
mysql -h <DB_HOST> -u k3s -pStrongPassword123! k3s -e "SELECT 1"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Setting Up PostgreSQL

```sql
-- Run on your PostgreSQL server as superuser
CREATE USER k3s WITH PASSWORD 'StrongPassword123!';
CREATE DATABASE k3s OWNER k3s;
GRANT ALL PRIVILEGES ON DATABASE k3s TO k3s;
```

Verify:
```bash
psql "postgres://k3s:StrongPassword123!@<DB_HOST>:5432/k3s" -c "SELECT 1"
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Bootstrapping k3s with an External Datastore

Store the connection string in a file to avoid it appearing in process lists:

```bash
# /etc/rancher/k3s/config.yaml
# (create on every server node before installing)

datastore-endpoint: "mysql://k3s:StrongPassword123!@tcp(192.168.1.50:3306)/k3s"
tls-san:
  - "192.168.1.100"   # LB IP
  - "k3s-api.example.com"
```

Then install k3s (no special flags needed — it reads `config.yaml`):
```bash
curl -sfL https://get.k3s.io | sh -
```

For PostgreSQL, the connection string format is:
```
postgres://k3s:StrongPassword123!@192.168.1.50:5432/k3s?sslmode=disable
```

For TLS-enabled PostgreSQL:
```
postgres://k3s:StrongPassword123!@192.168.1.50:5432/k3s?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca.crt
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Adding More Server Nodes

With an external datastore there is no `--cluster-init` flag and no peer-to-peer etcd — the database is the shared state. Just point each server at the same database:

```bash
# /etc/rancher/k3s/config.yaml on server-02 and server-03
datastore-endpoint: "mysql://k3s:StrongPassword123!@tcp(192.168.1.50:3306)/k3s"
token: "K10abc123::server:def456..."
tls-san:
  - "192.168.1.100"
  - "k3s-api.example.com"
```

```bash
curl -sfL https://get.k3s.io | sh -
```

All servers connect to the same DB and automatically coordinate via it.

```mermaid
graph LR
    subgraph Database HA
        DB[(MySQL Primary)] <-->|replication| DBR[(MySQL Replica)]
    end
    S1[k3s server-01] --> DB
    S2[k3s server-02] --> DB
    S3[k3s server-03] --> DB
    LB[Load Balancer] --> S1
    LB --> S2
    LB --> S3
    W1[Agent nodes] --> LB
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Connecting Agents

Agents don't need the datastore endpoint — they only talk to the server's API:

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<LB_IP>:6443 \
  K3S_TOKEN=<NODE_TOKEN> \
  sh -
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Migrating from SQLite to External Datastore

> ⚠️ This is a **destructive** operation — back up your cluster first!

```bash
# Step 1: Backup all cluster resources
kubectl get all --all-namespaces -o yaml > cluster-backup.yaml

# Step 2: Stop k3s
sudo systemctl stop k3s

# Step 3: Export SQLite data (optional — for reference)
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db .dump > sqlite-dump.sql

# Step 4: Update config.yaml with datastore-endpoint
sudo vim /etc/rancher/k3s/config.yaml

# Step 5: Remove old SQLite state
sudo rm -rf /var/lib/rancher/k3s/server/db

# Step 6: Restart k3s (will use new datastore)
sudo systemctl start k3s

# Step 7: Re-apply critical resources if needed
kubectl apply -f cluster-backup.yaml
```

> **Note:** User workloads (Deployments, ConfigMaps, etc.) stored in SQLite will be **lost** unless you re-apply them. Always restore from backup.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Datastore vs Embedded etcd: Decision Guide

| Factor | External Datastore | Embedded etcd |
|--------|-------------------|---------------|
| Operational complexity | Higher (manage DB) | Lower (self-contained) |
| Existing DB team / SLAs | ✅ Leverage existing ops | ❌ New system to manage |
| Network dependency | Yes (DB must be reachable) | No (etcd is colocated) |
| Point-in-time recovery | Via DB backups | Via etcd snapshots |
| Storage efficiency | Depends on DB | ~100MB etcd WAL |
| Latency | Slightly higher | Lower (local) |
| Recommendation | When DB infra exists | Default HA choice |

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab

There is no separate lab file for this lesson — the external datastore setup is documented inline above. To practice:

1. Spin up a MariaDB container (or use a VM):
   ```bash
   podman run -d --name mariadb \
     -e MYSQL_ROOT_PASSWORD=root \
     -e MYSQL_DATABASE=k3s \
     -e MYSQL_USER=k3s \
     -e MYSQL_PASSWORD=k3spass \
     -p 3306:3306 \
     docker.io/mariadb:11
   ```

2. Install k3s with `datastore-endpoint: "mysql://k3s:k3spass@tcp(127.0.0.1:3306)/k3s"`

3. Verify with `kubectl get nodes` and inspect the database:
   ```bash
   mysql -h 127.0.0.1 -u k3s -pk3spass k3s -e "SHOW TABLES;"
   ```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---
*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
