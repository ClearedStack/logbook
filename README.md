<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/logo-dark.svg">
    <img src="brand/logo-light.svg" alt="Logbook" height="56">
  </picture>
</p>

<p align="center">
  <strong>Keeps the record of every item, decision and proposal, and the public views of that record.</strong><br>
  Part of <a href="https://clearedstack.com">ClearedStack</a>
</p>

---

> **Status: design.** The first milestone is built and tested, and waiting for review: the schema, the two roles, the public views, the ledger and the integrity checks. The manifests that run it in a cluster are in [`deploy/`](deploy). Backups and the restore drill are not built.

Logbook is a control-plane service of the ClearedStack platform. ClearedStack is an open pipeline that finds ideas for government-contracting tools, screens and scores them, and builds each one from the public rule. Logbook is meant to be understood and used without the rest.

Logbook is a schema for PostgreSQL 17, not a program. It has no code that runs by itself and makes no call to anything.

## What works today

- **The working records.** Nine tables in the `core` schema hold the items, their evaluations and decisions, the edit proposals, the queue and its leases, the pauses for a missing rule, the restore drills and the ledger.
- **The public views.** Ten views in the `pub` schema show what is meant to be public and nothing else. An item’s address, a lease token and the text of an unapproved proposal are in no view.
- **Two roles.** `pub_ro` can read the public views and nothing else. `muster` can read the working tables and write each one only as its job needs. Nobody else is granted anything.
- **An append-only ledger.** Nobody can change, remove or truncate a ledger entry, including the owner of the database.
- **Refusals with a public error code.** A row that is broken is refused with `E_PARSE`. A value that is well-formed and unknown is refused with `E_NEEDS_SUBTOOL`. A refusal never repeats the value it refused.
- **Integrity checks.** `core.integrity_check()` runs fifteen checks, always in the same order, for a restore drill to run on a restored copy.
- **A migration runner.** `migrate.sh` applies each migration once, in order, each in one transaction, and refuses to go on if an applied migration has changed.

[`SPEC.md`](SPEC.md#schema) lists every table, view, fixed list and rule.

## Run it

You need PostgreSQL 17 and a shell. Nothing else is installed or downloaded.

**Apply the schema** to an empty database. Name the database the usual way, with `PGHOST`, `PGPORT`, `PGDATABASE` and `PGUSER`, and connect as the role that is to own Logbook:

```sh
sh migrate.sh
```

It prints one line for each migration it applies, or `nothing to apply`. It refuses any server that is not PostgreSQL 17.

The two roles are created unable to log in and with no password. To let Muster and Conn connect, turn login on and set a password for each, from wherever your deployment keeps its secrets:

```sql
ALTER ROLE muster LOGIN PASSWORD '...';
ALTER ROLE pub_ro LOGIN PASSWORD '...';
```

**Run the tests** as an ordinary user, with PostgreSQL 17’s `initdb`, `pg_ctl`, `psql`, `createdb` and `pg_dump` on the `PATH`:

```sh
sh tests/run.sh
```

The tests start their own server in a temporary directory, reachable only through a socket in that directory, and remove it when they finish. On each pull request they run inside `postgres:17-alpine` as an ordinary user, with a read-only filesystem, no capabilities, no network and 256 MiB of memory. See [`.github/workflows/tests.yml`](.github/workflows/tests.yml).

**Check a restored copy**, connected as the owner of the database. Every row should show 0 failures:

```sql
SELECT * FROM core.integrity_check();
```

## Run it in a cluster

[`deploy/`](deploy) is written for Argo CD and kustomize, pointed at the top of this repository. It expects one Secret that is not in this repository, `logbook-credentials` in the namespace `clearedstack`, with two keys: `postgres-password` and `muster-password`. Make it however your cluster keeps secrets.

After each sync the Job `logbook-migrate` runs `migrate.sh` against the database and then turns login on for `muster` with its password from that Secret.

## How it is tested

Every rule has a saved example. A file in [`tests/cases/`](tests/cases) is the input, and the file of the same name in [`tests/expected/`](tests/expected) is the exact output expected. Any difference fails the test. All the data is made up, and is in [`tests/fixtures/sample_record.sql`](tests/fixtures/sample_record.sql).

| Saved example | What it proves |
| --- | --- |
| `01_pub_ro_cannot_read_working_tables` | `pub_ro` cannot read a working table, call a function in `core`, write anywhere or become another role |
| `02_muster_writes_only_what_its_job_needs` | Every privilege `muster` holds, and each thing it is refused |
| `03_public_views_show_only_what_is_public` | Every column and row the public views show, and that no private value is among them |
| `04` to `11` | The rules of each table, with each refusal and its error code |
| `12_integrity_checks` | Each integrity check passes on a sound record and fails on the damage it is there to find |
| `13_migrate` | `migrate.sh` applies each migration once and refuses each thing it should |
| `14_dump_and_restore` | A dump restored into a new database passes the integrity checks and keeps both roles fenced |
| `15_cluster_lists_every_migration` | Every migration is named in `kustomization.yaml`, so the cluster is handed each one |

After changing a rule on purpose, run `sh tests/run.sh --accept` to save the new output, and read the difference before committing it.

## In this repository

| Path | What it is |
| --- | --- |
| [`SPEC.md`](SPEC.md) | The specification: what Logbook does, its interfaces, how it fails and how it is kept safe. Its Schema section describes what is built. |
| [`migrations/`](migrations) | The schema, as numbered SQL files applied in order. |
| [`migrate.sh`](migrate.sh) | Applies the migrations. Needs only `sh`, `psql` and `sha256sum`, and writes nothing to disk. |
| [`tests/`](tests) | The saved examples and the script that runs them. |
| [`deploy/`](deploy) | The Kubernetes manifests: the namespace and its default-deny network policy, the database and its volume, and the Job that applies the migrations. |
| [`kustomization.yaml`](kustomization.yaml) | What Argo CD applies: `deploy/`, with `migrate.sh` and the migrations as ConfigMaps for the Job. |
| [`PROMPT.md`](PROMPT.md) | The prompt this build was started from. |
| [`component.json`](component.json) | This component’s entry in the ClearedStack naming registry. |
| [`brand/`](brand) | The Logbook logo and mark, for light and dark backgrounds. |

## At a glance

| | |
| --- | --- |
| **Role** | Control-plane service |
| **Formerly** | `postgres` |
| **Namespace** | `clearedstack` |
| **Container image** | `postgres:17-alpine (upstream PostgreSQL; Logbook is the schema and ledger on top)` |
| **Memory budget** | 256 MiB |
| **Depends on** | Nothing else in the platform |
| **Depended on by** | [Conn](https://github.com/ClearedStack/clearedstack.com), [Muster](https://github.com/ClearedStack/muster) |

### Boundaries

- Working records (the core schema): read and written by Muster only
- Public views (the pub schema): read-only, for Conn

## Not yet done

These are in `SPEC.md` and are not built here.

| Requirement | State |
| --- | --- |
| Nightly backup: a consistent dump, encrypted with `age`, sent off the node, old copies pruned | Not built. The saved example `14_dump_and_restore` covers only taking a dump and loading it |
| Monthly restore drill | Not built. The integrity checks it would run on the database are built, and so is the table and view its result goes in |
| Deployment: the priority class | Not set. [`deploy/`](deploy) has the rest: the persistent volume, the `ClusterIP` service, running as non-root with every capability dropped. It runs the official `postgres:17` image, pinned by digest, where the naming registry says `17-alpine`. The ownership map still puts the manifest in `clearedstack.com`, at `deploy/logbook/app.yaml` |
| Network isolation: Muster and Conn | [`deploy/networkpolicy.yaml`](deploy/networkpolicy.yaml) denies everything in the namespace and lets only the migrate Job reach the database. Muster and Conn are not deployed, so no rule lets them in yet |
| Login for `pub_ro` | Not turned on. The migrate Job turns login on for `muster` only |
| Settings that keep the running database within 256 MiB | Not built. The tests run within 256 MiB, which is not the same thing as a database under load |
| A place for what Sextant observes about an item, and for the health of each component | Not built. `SPEC.md` does not list them among what Logbook stores. See its open questions |
| Functions for Muster to claim, renew and release a lease | Not built. The table holds a lease; how long one lasts is not specified |

Three things to know before relying on it:

- **Restoring a dump does not restore who may connect.** A dump of one database does not carry the database’s own privileges. After a restore, anyone with a login on the server can connect until this is applied again: `REVOKE ALL ON DATABASE ... FROM PUBLIC` and `GRANT CONNECT ON DATABASE ... TO muster, pub_ro`. The saved example `14_dump_and_restore` shows it.
- **Identifiers can have gaps.** A refused insert still uses up its number, and numbers stop at `PA-9999`.
- **Logbook does not decide which move between states is allowed.** It checks that both ends of a move are states it knows. Muster is the gatekeeper.

## Names

`logbook` is this component’s identifier everywhere: the repository, the workload, the container image. The one place names are written down is the [naming registry](https://clearedstack.com/platform/registry.json), kept in [`clearedstack.com`](https://github.com/ClearedStack/clearedstack.com/blob/main/src/data/registry.json). `component.json` here is a copy of this component’s entry. If the two disagree, the registry is right.

## Ground rules

- **No AI when it runs.** The same input gives the same output on any machine.
- **Stop instead of guessing.** A case with no rule is paused and reported, never improvised.
- **Clean room.** Written from scratch. No code, text or design is copied from another project.
- **Public sources and made-up data only.** Nothing classified, controlled or taken from a real contract, in code, tests, issues or commit messages.

## License

[MIT](LICENSE). ClearedStack is an independent personal project. It is not affiliated with, endorsed by, or sponsored by the U.S. Department of Defense or any other government agency.
