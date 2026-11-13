# Logbook specification

> The platform’s one record of state: the working records, the public views of them and the append-only ledger, kept today in a single PostgreSQL 17 database.

**Status: design.** This is a specification. It describes how Logbook is meant to work, not something that exists yet.

The same text is published at [clearedstack.com/platform/logbook/](https://clearedstack.com/platform/logbook/). To change the specification, change it here and say why.

Logbook is the name for the platform’s record of state, not for the database engine. If PostgreSQL were ever replaced, Logbook would still be Logbook. Today it is a single shared PostgreSQL 17 database (image `postgres:17-alpine`, with its schema kept in the `logbook` repository). Running one consolidated database on a Persistent Volume Claim (PVC) eliminates multi-database sync bugs and keeps control-plane memory compact enough for a single 4 GiB `k3s` node.

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
| **Owning Repo** | `logbook` |
| **RAM Request** | `256 MiB` |
| **Priority Class** | High (Control Plane — protected from eviction) |
| **Storage** | Persistent Volume Claim (1 of 3 cluster PVCs) |
| **Network Exposure** | Cluster-private (`ClusterIP` only); unreachable from `cs-workers` and public internet |

## Interfaces & Data Contracts

Only two services in the entire cluster are permitted to connect to Logbook. The one other thing that connects is the nightly backup job, which can read and cannot write:

| Service | Schema Access | Role / Privileges | Responsibility |
| --- | --- | --- | --- |
| **Muster** | `core.*` | Read / Write (`core_rw`) | Manages worker queue leases, `needs_subtool` pauses, replay, edit proposals, append-only ledger entries, and the recorded result of each restore drill |
| **Conn** | `pub.*` | Read-Only (`pub_ro`) | Reads sanitized public views for the Portal, App Store UI, and monthly restore drill status |
| **Nightly backup job** | `core.*` and `pub.*` | Read-Only (`backup_ro`) | Takes the consistent dump described under Failure Modes & Recovery |
| **`cs-workers` (Trawl through Bellbuoy)** | None | Blocked | Zero network access (`NetworkPolicy`) and zero database credentials |

## Data model

This section is what the migrations in `migrations/` build. Each value in a known set is taken from a published page of the platform, named beside it. The names of tables and columns are set here.

### Roles

| Role | For | May |
| --- | --- | --- |
| `core_rw` | Muster | Read and write the working tables, within the limits under Working tables |
| `pub_ro` | Conn | Read the views in `pub`, and nothing else |
| `backup_ro` | The nightly backup job | Read everything in `core` and `pub`, and write nothing |

A role holds privileges only. It cannot log in and has no password, so no credential is kept in this repository. Whoever deploys Logbook creates the login users and makes each a member of one role. No other role is given the right to connect to the database.

### Known sets

A known set changes only by migration. No role can change one.

| Table | Values | Taken from |
| --- | --- | --- |
| `core.item_state` | `discovered`, `recorded`, `observed`, `screened-out`, `scored`, `approved`, `building`, `live`, `parked`, `linked`, `merged`, `rejected`, `retired`, `needs_subtool` | [An item’s life](https://clearedstack.com/platform/item-lifecycle/) |
| `core.lane` | `urgent`, `normal`, `backfill`, emptied in that order | [An item’s life](https://clearedstack.com/platform/item-lifecycle/) |
| `core.worker` | `trawl`, `sextant`, `assay`, `countersign`, `waybill`, `moldloft`, `shakedown`, `chartroom`, `tidegauge`, `bellbuoy`, stages 1 to 10 | [The naming registry](https://clearedstack.com/platform/registry.json) |
| `core.queue_status` | `waiting`, `leased`, `completed`, `failed`, `needs_subtool` | The worker calls in the registry: lease, complete, fail, needs_subtool |
| `core.outcome` | `build`, `link`, `park`, `reject` (which a score can recommend), `merge`, `override` | [How we decide what to build](https://clearedstack.com/platform/how-we-decide/) |
| `core.edit_kind` | `DATA`, `CONFIG`, `ISSUE` | [Public edits](https://clearedstack.com/platform/public-edits/) |
| `core.edit_status` | `pending_approval`, `approved`, `building`, `live`, `declined` | [Public edits](https://clearedstack.com/platform/public-edits/) |

### Working tables

| Table | Holds | Columns | Muster may |
| --- | --- | --- | --- |
| `core.item` | One row for each `PA-XXXX` item | `item_id`, `state`, `title`, `source_url`, `source_hash`, `created_at`, `updated_at` | Read, add, change |
| `core.evaluation` | Evaluation outcomes | `evaluation_id`, `item_id`, `gates_passed`, `reason`, `score`, `recommendation`, `evaluated_at` | Read, add |
| `core.decision` | The decision trail | `decision_id`, `item_id`, `outcome`, `reason`, `decided_at` | Read, add |
| `core.edit_proposal` | Anonymous edit proposals | `proposal_id`, `kind`, `target`, `payload`, `status`, `submitted_at` | Read, add, change |
| `core.queue` | Work queues and their leases | `queue_id`, `item_id`, `proposal_id`, `worker`, `lane`, `status`, `lease_token`, `lease_expires_at`, `heartbeat_at`, `error_code`, `enqueued_at` | Read, add, change, remove |
| `core.ledger` | The append-only ledger: one row for each change of state of an item or of status of a proposal | `ledger_id`, `item_id`, `proposal_id`, `from_state`, `to_state`, `worker`, `recorded_at` | Read, add |
| `core.restore_drill` | The result of each monthly restore drill | `drill_id`, `ran_at`, `decrypt_passed`, `database_passed`, `plainforge_passed`, `lazarette_passed`, `passed` | Read, add |
| `core.migration` | Which migrations have been applied | `version`, `name`, `applied_at` | Read |

- An evaluation, a decision and a drill result are added and never rewritten. A change of mind is a new row.
- An item and a proposal are never removed. Rejected, retired and declined are states, not deletions.
- The ledger refuses every change and removal, from every role, the owner of the table included. An item or a proposal that the ledger mentions cannot be removed either. A database superuser can still switch this protection off. No schema can prevent that, so the superuser’s credential is not given to any service.
- A time that is not supplied is the time of the transaction, so every row written in one transaction carries the same time.
- The four checks of a restore drill are the four in [Operating it](https://clearedstack.com/platform/operations/): decrypt and unpack, the database, Plainforge, Lazarette. `passed` is true only when all four are, and cannot be set.

### Rules

A row that breaks a rule is refused. Nothing of it is kept.

| Table | Refused as `E_PARSE` | Refused as `E_NEEDS_SUBTOOL` |
| --- | --- | --- |
| `core.item` | A required column is empty. `item_id` is not `PA-` and exactly four digits. `title` or `source_url` is blank. `source_hash` is not 64 lowercase hexadecimal characters. | `state` is not a known item state |
| `core.evaluation` | A required column is empty. Gates passed: `score` is missing or outside 20 to 100, or `recommendation` is missing. A gate failed: `reason` is blank, or `score` or `recommendation` is given. | `recommendation` is not one a score can recommend |
| `core.decision` | A required column is empty. `outcome` is `override` and `reason` is blank. | `outcome` is not a known outcome |
| `core.edit_proposal` | A required column is empty. `target` is blank. `payload` is longer than 4096 bytes. | `kind` or `status` is not known |
| `core.queue` | A required column is empty. Both an item and a proposal are named. A leased entry lacks `lease_token` or `lease_expires_at`, or another entry holds one. `error_code` does not go with `status`: `E_NEEDS_SUBTOOL` for `needs_subtool`, `E_TIMEOUT` or `E_PARSE` for `failed`, empty otherwise. | `worker`, `lane` or `status` is not known |
| `core.ledger` | A required column is empty. The entry does not name exactly one item or proposal. | `to_state` or `from_state` is not known for the subject (item states for an item, proposal statuses for a proposal). `worker` is not known. |
| `core.restore_drill` | A required column is empty. | |

Every column is required except: `reason`, `score` and `recommendation` in `core.evaluation`; `item_id`, `proposal_id`, `lease_token`, `lease_expires_at`, `heartbeat_at` and `error_code` in `core.queue`; `item_id`, `proposal_id`, `from_state` and `worker` in `core.ledger`.

Logbook checks the shape of a row. It does not check the order of events: which state may follow which, when a lease has run out, whether an address has been seen before, or whether a recommendation fits a score. Those rules belong to Muster and the workers.

### Errors

- A refusal under a rule is an error whose message starts with the code, then a colon, then a fixed sentence naming the rule: `E_PARSE: item.item_id must be PA- followed by four digits`. Match on the code at the start of the message. The SQLSTATE is `22000` for `E_PARSE` and `0A000` for `E_NEEDS_SUBTOOL`.
- A rule message never repeats a value from the row, so it cannot carry a lease token or an address.
- Logbook never raises `E_TIMEOUT`. It waits on nothing outside itself.
- A write a role has no right to make, and any change to the ledger, is PostgreSQL’s own `permission denied` (SQLSTATE `42501`). None of the three codes fits a refused write.
- PostgreSQL’s own errors can still reach Muster: a reference to an item or proposal that does not exist (`23503`), or a value of the wrong type. Their text can name a table, a key or the value that was refused. Muster maps them to a public code and shows none of their text.

### Public views

| View | Shows | Leaves out |
| --- | --- | --- |
| `pub.item` | `item_id`, `title`, `state`, `created_at`, `updated_at` | `source_url`, `source_hash` |
| `pub.item_history` | Ledger entries about items: `ledger_id`, `item_id`, `from_state`, `to_state`, `worker`, `recorded_at` | Ledger entries about proposals |
| `pub.evaluation` | `evaluation_id`, `item_id`, `gates_passed`, `reason`, `score`, `recommendation`, `evaluated_at` | |
| `pub.decision` | `decision_id`, `item_id`, `outcome`, `reason`, `decided_at` | |
| `pub.queue_length` | The number of queue entries for each `worker`, `lane` and `status` | Every single entry, and so every lease token |
| `pub.edit_proposal` | `proposal_id`, `kind`, `target`, `status`, `submitted_at`, and `payload` once the status is `approved`, `building` or `live` | The payload of a proposal that is pending or declined |
| `pub.restore_drill` | `drill_id`, `ran_at`, `decrypt_passed`, `database_passed`, `plainforge_passed`, `lazarette_passed`, `passed` | |

A view names its columns one by one. A column added to a working table later is private until a migration adds it to a view.

### Still open

1. **Items with no identifier.** [An item’s life](https://clearedstack.com/platform/item-lifecycle/) says an item gets its identifier when it moves from `discovered` to `recorded`. Here every row needs an `item_id`, so a `discovered` item can be stored only if Muster gives it an identifier first.
2. **The size limit on a proposal.** The published pages say both “under 4 KB” and “≤ 4 KB”. Built here: at most 4096 bytes.
3. **Four digits.** `PA-0000` to `PA-9999` is ten thousand items. A wider identifier needs a change here.
4. **Detail of an evaluation.** The result of each of the five gates and the rating on each of the seven factors are not stored, only whether the gates were passed, the reason, the score and the recommendation. Storing them needs names for the gates and the factors, which the registry does not give.
5. **Spam limits for edit intake.** Muster keeps no state of its own, so a count of submissions for each hashed address would have to live here. No table for it is specified.
6. **Which items are public.** Every item is shown in `pub.item`, whatever its state.

## Failure Modes & Recovery

Because Logbook holds one of the cluster's three non-recreatable Persistent Volume Claims, durability and recovery are verified continuously rather than assumed:

- **Consistent Nightly Backups:** A scheduled backup job takes a consistent database dump (never a raw file copy while writes are active), encrypts the dump client-side with `age`, transfers it to off-node storage, and prunes old snapshots on a fixed retention schedule.
- **Automated Monthly Restore Drill:** Once a month, the cluster provisions an isolated scratch area, downloads the latest `age`-encrypted backup, decrypts it with the current key, restores Logbook from scratch, and runs deterministic integrity checks on `core.*` tables and `pub.*` views before tearing down the scratch environment.
- **Live Drill Visibility:** The timestamp and pass/fail outcome of the four monthly verification checks are published directly to the live Portal so backup drift surfaces immediately. Muster records the result in `core.restore_drill`, and Conn reads it from `pub.restore_drill`.
- **Pod Restart / Node Reboot:** Because data resides on the PVC and Logbook runs under the High Priority Class, `k3s` reattaches the volume and recovers cleanly via PostgreSQL crash recovery.

## Security & Clean-Room Boundaries

- **Default-Deny Network Isolation:** `NetworkPolicy` blocks all pods in `cs-workers` and all external Ingress traffic from reaching Logbook on the network.
- **Least-Privilege Roles:** Conn is restricted to `pub_ro` on `pub.*` views, ensuring no public query can ever read `core.*` tables, internal tokens, or unapproved edit payloads.
- **Encrypted Off-Node Backups:** Backup archives are encrypted with `age` before leaving the host node, with the decryption key stored separately from the off-node backup target.
- **Unprivileged Execution:** Runs as non-root with dropped capabilities and no privilege escalation.

## Changes to this specification

| Change | Reason |
| --- | --- |
| Added the Data model section | The specification named what Logbook stores and gave no tables, columns, states or views, so nothing could be built from it without inventing names. |
| Named Muster’s role `core_rw` | Only `pub_ro` had a name. |
| Added the backup job and its role `backup_ro` to the interface table | The specification said only two services may connect, and also described a backup job that has to connect to take a dump. |
| Fixed the identifier as `PA-` and exactly four digits | `PA-XXXX` did not say what an X is. Every published example has four digits. |
| Said that Muster records the result of a restore drill | Only Muster may write, and the drill is a separate job with no role of its own. |
| Added the Errors section | The three public codes describe a worker’s failures. The specification did not say which of them a database refusal carries. |

## Related pages

- [Cluster architecture](https://clearedstack.com/platform/cluster-architecture/)
- [Operating it: status views, failures and backups](https://clearedstack.com/platform/operations/)
