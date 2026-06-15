# Neo4j
**Purpose:** Graph database.
**URL:** https://neo4j.pdx.sanctioned.tech (Browser UI, port 7474); Bolt on TCP host port 7687
**Auth:** local login (`neo4j` / password)
**Image:** neo4j:5.26
**GPU:** no
**Networks / data:** proxy, ai; bind mounts `./neo4j/data` -> `/data`, `./neo4j/logs` -> `/logs`

## Setup as deployed
- Auth: `NEO4J_AUTH=neo4j/${NEO4J_PASSWORD}` (sets the initial password for user `neo4j`).
- Memory tuning:
  - `NEO4J_server_memory_pagecache_size=1G`
  - `NEO4J_server_memory_heap_initial__size=1G`
  - `NEO4J_server_memory_heap_max__size=2G`
- Bolt protocol published on host TCP `7687:7687` for drivers; the Browser UI (HTTP 7474) is
  routed through Traefik.
- Data/logs persist under `./neo4j/data` and `./neo4j/logs`.
- Traefik router on `websecure`, TLS, middleware `secure-chain@file`, backend port 7474.

### First login
- Log in to the Browser UI as `neo4j` with `NEO4J_PASSWORD`. Drivers connect via
  `bolt://jarvis:7687`.

## Fixes & gotchas
- The `NEO4J_AUTH` initial password is only applied on a fresh data dir. Changing
  `NEO4J_PASSWORD` later does not reset an existing DB password — rotate it inside Neo4j.

## Secrets
- `NEO4J_PASSWORD` — password for the `neo4j` user.
- `TZ`. All secrets come from `/opt/homelab/.env` (gitignored); nothing sensitive is committed.
