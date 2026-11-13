# Logbook specification

> The platform’s one record of state: the working records, the public views of them and the append-only ledger, kept today in a single PostgreSQL 17 database.

**Status: design.** This is a specification. It describes how Logbook is meant to work, not something that exists yet.

The same text is published at [clearedstack.com/platform/logbook/](https://clearedstack.com/platform/logbook/). To change the specification, change it here and say why.

Logbook is the name for the platform’s record of state, not for the database engine. If PostgreSQL were ever replaced, Logbook would still be Logbook. Today it is a single shared PostgreSQL 17 database (image `postgres:17-alpine`, with its schema owned by `clearedstack.com`). Running one consolidated database on a Persistent Volume Claim (PVC) eliminates multi-database sync bugs and keeps control-plane memory compact enough for a single 4 GiB `k3s` node.

## Overview & Role

Logbook is the durable system of record for live operational state, work queues, and sanitized public views:

- **Single Source of Truth:** Stores `PA-XXXX` item records, evaluation outcomes, decision trails, queue leases, anonymous edit proposals, and an append-only ledger.
- **Atomic State + Queue Transitions:** Because live state and work queues live in the same database, Muster commits an item's state change and its next queue step in a single ACID transaction.
- **Strict Schema Separation:** Splits internal operational data (`core.*`) from sanitized, public-safe projections (`pub.*`).

## Runtime & Resource Budget

| Attribute | Value |
| --- | --- |
| **Namespace** | `clearedstack` (Control Plane) |
| **Kind** | `control-plane` |
| **Version** | `17-alpine` |
| **Owning Repo** | `clearedstack.com` |
| **RAM Request** | `256 MiB` |
| **Priority Class** | High (Control Plane — protected from eviction) |
| **Storage** | Persistent Volume Claim (1 of 3 cluster PVCs) |
| **Network Exposure** | Cluster-private (`ClusterIP` only); unreachable from `cs-workers` and public internet |

## Interfaces & Data Contracts

Only two services in the entire cluster are permitted to connect to Logbook:

| Service | Schema Access | Role / Privileges | Responsibility |
| --- | --- | --- | --- |
| **Muster** | `core.*` | Read / Write | Manages worker queue leases, `needs_subtool` pauses, replay, edit proposals, and append-only ledger entries |
| **Conn** | `pub.*` | Read-Only (`pub_ro`) | Reads sanitized public views for the Portal, App Store UI, and monthly restore drill status |
| **`cs-workers` (Trawl through Bellbuoy)** | None | Blocked | Zero network access (`NetworkPolicy`) and zero database credentials |

## Failure Modes & Recovery

Because Logbook holds one of the cluster's three non-recreatable Persistent Volume Claims, durability and recovery are verified continuously rather than assumed:

- **Consistent Nightly Backups:** A scheduled backup job takes a consistent database dump (never a raw file copy while writes are active), encrypts the dump client-side with `age`, transfers it to off-node storage, and prunes old snapshots on a fixed retention schedule.
- **Automated Monthly Restore Drill:** Once a month, the cluster provisions an isolated scratch area, downloads the latest `age`-encrypted backup, decrypts it with the current key, restores Logbook from scratch, and runs deterministic integrity checks on `core.*` tables and `pub.*` views before tearing down the scratch environment.
- **Live Drill Visibility:** The timestamp and pass/fail outcome of the four monthly verification checks are published directly to the live Portal so backup drift surfaces immediately.
- **Pod Restart / Node Reboot:** Because data resides on the PVC and Logbook runs under the High Priority Class, `k3s` reattaches the volume and recovers cleanly via PostgreSQL crash recovery.

## Security & Clean-Room Boundaries

- **Default-Deny Network Isolation:** `NetworkPolicy` blocks all pods in `cs-workers` and all external Ingress traffic from reaching Logbook on the network.
- **Least-Privilege Roles:** Conn is restricted to `pub_ro` on `pub.*` views, ensuring no public query can ever read `core.*` tables, internal tokens, or unapproved edit payloads.
- **Encrypted Off-Node Backups:** Backup archives are encrypted with `age` before leaving the host node, with the decryption key stored separately from the off-node backup target.
- **Unprivileged Execution:** Runs as non-root with dropped capabilities and no privilege escalation.

## Related pages

- [Cluster architecture](https://clearedstack.com/platform/cluster-architecture/)
- [Operating it: status views, failures and backups](https://clearedstack.com/platform/operations/)
