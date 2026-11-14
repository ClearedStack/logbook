# Logbook specification

> The platform’s one record of state: the working records, the public views of them and the append-only ledger, kept today in a single PostgreSQL 17 database.

**Status: design.** This is a specification. It describes how Logbook is meant to work, not something that exists yet.

The same text is published at [clearedstack.com/platform/logbook/](https://clearedstack.com/platform/logbook/). To change the specification, change it here and say why.

Logbook is the name for the platform’s record of state, not for the database engine. If PostgreSQL were ever replaced, Logbook would still be Logbook. Today it is a single shared PostgreSQL 17 database (image `postgres:17`, with its schema kept in the `logbook` repository). Running one consolidated database on a Persistent Volume Claim (PVC) eliminates multi-database sync bugs and keeps control-plane memory compact enough for a single 4 GiB `k3s` node.

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
| **Version** | `17` |
| **Owning Repo** | `logbook` |
| **RAM Request** | `256 MiB` |
| **Priority Class** | High (Control Plane, protected from eviction) |
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

## Schema

> **Proposed with the first build milestone, and waiting for review.** The sections above do not say what the tables, views and rules are. This section says what was built, and where each choice came from. The code is in [`migrations/`](migrations) and every rule here has a saved example in [`tests/`](tests). Nothing above this line was changed.

### Roles

| Role | For | May do |
| --- | --- | --- |
| `muster` | Muster | Read every `core` table. Write each one only as its job needs: see the table below. Nothing in `pub`. |
| `pub_ro` | Conn | Read every `pub` view. Nothing else. |

Both roles are created without a password and unable to log in. Whoever deploys Logbook turns login on and sets the password, so no credential is ever in this repository. Nobody else is granted anything, on the database, a schema, a table or a function.

`muster` is the name the naming registry gives the service. The specification named only `pub_ro`.

### Working tables (`core`)

| Table | Holds | Muster may |
| --- | --- | --- |
| `core.item` | One row for each item: an identifier such as `PA-0001` or `PA-10000`, state, title, the cleaned address it was found at, the SHA-256 of that address, and the intake source | Add, giving the state, title, address and source. Logbook gives out the identifier and sets the time it was recorded. Change the state, title, address and source. Never remove, never choose or change the identifier |
| `core.evaluation` | One row each time an item is screened and scored: the result of each gate, the rating and weight of each factor, the score, the recommendation | Add only |
| `core.decision` | The decision trail: what the owner chose for an evaluation, and why | Add only |
| `core.edit_proposal` | One row for each proposal that passed the automatic checks (numbered `1` to `999999999` for `EP-0001` to `EP-999999999`): the element, the owning repository, the file path, the kind, the text, the reason, the status | Add. Change the status and decision time. Never change the text, reason or file path, never remove |
| `core.queue` | Work waiting, claimed or stopped (`held`): the worker, the lane, what it is about, and the lease | Add, remove. Change the lease, the attempt count and `held` |
| `core.pause` | Items stopped for a missing rule: the worker, the pattern, the state to return to | Add. Mark as replayed |
| `core.result` | The latest JSON object (up to 256 KiB) each worker returned for an item or an edit proposal | Add. Replace the JSON object and time for the same subject and worker. Never remove |
| `core.lease_outcome` | How the last lease on an item, incident or proposal ended, so a repeated worker call receives the same answer | Add, change, remove |
| `core.component_health` | The latest health state, public error code and `sha256` image digest Shipkeeper reported for each component | Add. Change the state, error code, digest and time. Never remove |
| `core.submission_count` | How many intake submissions a salted 64-hex visitor HMAC key has made on a UTC day | Add, change the count, remove |
| `core.ledger` | The append-only ledger: one entry each time an item changes state or a proposal changes status | Add only |
| `core.restore_drill` | When each restore drill ran, and the outcome of its four checks | Add only |
| `core.migration` | Which migrations have been applied, and the SHA-256 of each file | Read only |

The ledger refuses a change, a removal or a truncation from anyone, including the owner of the database.

### Public views (`pub`)

| View | Shows |
| --- | --- |
| `pub.item` | Identifier, state, title, when it was recorded and when it last changed |
| `pub.item_history` | Every change of state of every item, from the ledger |
| `pub.evaluation`, `pub.evaluation_gate`, `pub.evaluation_factor` | Each evaluation, the result of each gate, and the points for each factor |
| `pub.decision` | What was recommended, what the owner chose, whether that was an override, and the reason |
| `pub.queue_depth` | How much active work is waiting and claimed right now, for each worker and lane (excluding stopped steps and future-scheduled checks) |
| `pub.pause` | Every pause for a missing rule, and whether it has been replayed |
| `pub.edit_proposal` | Every proposal and its status. The text appears only once the owner has approved it |
| `pub.restore_drill` | When each drill ran, whether it passed, and the outcome of each of the four checks |
| `pub.component_health` | The latest health state and public error code of each component that has reported, without image digests |

Never shown in any view: an item's address, address hash or intake source, a lease token or lease identifier, a proposal's reason, file path or unapproved text, a worker's `core.result` JSON object, an image digest, or a visitor submission key.

### Fixed lists

Logbook refuses a value outside these lists.

| List | Values | Taken from |
| --- | --- | --- |
| Item states | `discovered`, `recorded`, `observed`, `needs_subtool`, `screened_out`, `scored`, `parked`, `approved`, `building`, `live`, `rejected`, `linked`, `merged`, `retired` | [An item’s life](https://clearedstack.com/platform/item-lifecycle/) |
| Item sources | `sam-gov`, `github-issues`, `web-sweep`, `site-form` | Contract v1 (`ClearedStack/muster`) |
| Lanes, in the order they are emptied | `urgent`, `normal`, `backfill` | [An item’s life](https://clearedstack.com/platform/item-lifecycle/) |
| Error codes | `E_TIMEOUT`, `E_PARSE`, `E_NEEDS_SUBTOOL` | [Operating it](https://clearedstack.com/platform/operations/) |
| Component health states | `healthy`, `idle`, `degraded`, `paused` | Contract v1 (`ClearedStack/muster`) |
| Lease-ending calls | `complete`, `fail`, `needs_subtool` | Contract v1 (`ClearedStack/muster`) |
| Recommendations | `build`, `link`, `park`, `reject` | [How we decide what to build](https://clearedstack.com/platform/how-we-decide/) |
| Decisions | `build`, `link`, `merge`, `park`, `reject`, `reopen` | [How we decide what to build](https://clearedstack.com/platform/how-we-decide/) |
| Kinds of edit | `DATA`, `CONFIG`, `ISSUE` | [Public edits](https://clearedstack.com/platform/public-edits/) |
| Proposal statuses | `pending_approval`, `approved`, `building`, `live`, `declined` | [Public edits](https://clearedstack.com/platform/public-edits/) |
| Restore drill checks | `decrypt`, `logbook`, `plainforge`, `lazarette` | [Operating it](https://clearedstack.com/platform/operations/) |

Names that are listed somewhere else are checked for their form only: a worker or repository in the naming registry, an element in the ownership map, a relative file path inside a repository, and the gates, factors and profiles that belong to Assay. Logbook does not keep a second copy of those lists. In particular it does not fix the weights of the rubric: an evaluation records the weight that was used, and Logbook checks that the score is the sum of each rating times its weight.

### What Logbook refuses

| Rule | Refusal |
| --- | --- |
| A required value is missing, or is not in the form it must have | `E_PARSE` |
| A value is well-formed and not in a fixed list | `E_NEEDS_SUBTOOL` |
| An item identifier is not `PA-` followed by four digits, or by five to nine digits that do not start with 0 | `E_PARSE` |
| An evaluation’s score is not the sum of each rating times its weight, a rating is not a whole number from 1 to 5, or a failed gate has no reason | `E_PARSE` |
| An evaluation that failed a gate also carries factors, a score or a recommendation | `E_PARSE` |
| A decision differs from the recommendation and has no written reason | `E_PARSE` |
| A proposal’s text or reason is longer than 4096 bytes, is empty or holds control characters, or `file_path` is not a clean relative path | `E_PARSE` |
| A lease has a token and no end time, or the other way round, or a `held` queue row still carries a live lease | `E_PARSE` |
| A worker result is not a JSON object, is larger than 262,144 bytes, or is not about one item or one proposal | `E_PARSE` |
| A component digest is not `sha256:` followed by 64 lower-case hexadecimal digits, or a visitor key is not 64 lower-case hexadecimal digits | `E_PARSE` |
| A ledger entry is not about exactly one item or one proposal | `E_PARSE` |

A refusal names the field and the rule. It never repeats the value it refused. Logbook never raises `E_TIMEOUT` itself; it stores that code when a worker reports it, and `migrate.sh` reports it when the database does not answer.

Logbook does not decide which move between states is allowed. Muster is the gatekeeper for that. Logbook checks that both ends of a move are states it knows.

### Integrity checks

`core.integrity_check()` returns the same nineteen checks in the same order every time, each with the number of things that failed it. A restore drill runs it on the restored copy, and all zeros is a pass. It checks that every row in all twelve working tables would still be accepted, that each item and each proposal is where its last ledger entry put it, that each ledger trail has no gap, that an item is in `needs_subtool` exactly when it has an open pause, and that the public views show every row and no unapproved text.

### Questions this leaves open

| Question | What was built in the meantime |
| --- | --- |
| The platform pages write one state two ways, `screened_out` and `screened-out` | `screened_out`. The hyphenated form is refused |
| The shared contract allows 4 to 9 digits and does not say whether leading zeros matter | Each number has one form: four digits up to `PA-9999`, then no leading zero, up to `PA-999999999`. `PA-00001` is refused. Logbook gives out every identifier, and Muster cannot supply one |
| An item is said to have an identifier in every state, and also to be given one only when it moves from `discovered` to `recorded` | Every row has an identifier, and every one of the fourteen states is accepted |
| Only Muster and Conn may connect, but a backup needs a dump and a drill needs its result written | No third role. A drill’s result is written by Muster. `dump.sh` (mounted read-only at `/logbook/bin/dump.sh` inside Logbook’s pod) takes a consistent `pg_dump --serializable-deferrable` snapshot as the database owner and optionally streams it through `age`; `restore-drill.sh` restores into an isolated scratch PostgreSQL 17 cluster (or an empty database), locks down database-level `CONNECT`, and verifies `core.integrity_check()` and both role fences |
| The memory figure is called a request here and a limit in the build prompt | Both request and limit are `256Mi`, and PostgreSQL’s buffers, connections and WAL are sized in `deploy/logbook.yaml` to stay inside that budget |
| What Sextant and other workers pass along about an item or proposal | Stored as one JSON object per subject and worker in `core.result` (up to 256 KiB), matching Contract v1, and never published directly |
| How component health reaches `pub` without leaking image digests | Stored in `core.component_health` and published through `pub.component_health` without `digest` |
| How long a lease lasts, and how a worker claims one | Contract v1 sets the lease rules in Muster; Logbook stores the active lease in `core.queue` and the last completed lease answer in `core.lease_outcome` |
| Whether an item’s address is public | Not published |

## Related pages

- [Cluster architecture](https://clearedstack.com/platform/cluster-architecture/)
- [Operating it: status views, failures and backups](https://clearedstack.com/platform/operations/)
