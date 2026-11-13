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

> **Status: in progress.** The first milestone is built and tested: the schema, the three roles and the public views. Backups, the restore drill and deployment are not built. See [What works today](#what-works-today) and [Not yet done](#not-yet-done).

Logbook is a control-plane service of the ClearedStack platform. ClearedStack is an open pipeline that finds ideas for government-contracting tools, screens and scores them, and builds each one from the public rule. Logbook is meant to be understood and used without the rest.

## In this repository

| File | What it is |
| --- | --- |
| [`SPEC.md`](SPEC.md) | The specification: what Logbook does, its data model, its interfaces, how it fails and how it is kept safe. |
| [`migrations/`](migrations) | The schema, as SQL for PostgreSQL 17. Three files, applied once each, in order. |
| [`tests/`](tests) | The saved examples and the script that runs them. |
| [`PROMPT.md`](PROMPT.md) | The prompt to start a build session with. It says what to build and the rules to build it under. |
| [`component.json`](component.json) | This component’s entry in the ClearedStack naming registry. |
| [`brand/`](brand) | The Logbook logo and mark, for light and dark backgrounds. |

## What works today

- **The working records.** The `core` schema holds items, evaluation outcomes, the decision trail, edit proposals, the work queue with its leases, the append-only ledger and the result of each restore drill.
- **The public views.** The `pub` schema holds seven views of those records. They leave out the source address of an item, every lease token, and the text of any edit proposal the owner has not approved.
- **Three roles.** `core_rw` for Muster, `pub_ro` for Conn and `backup_ro` for the backup job. `pub_ro` reads the views and cannot read a working table. None of the three can log in or has a password: the login users are made at deployment.
- **Rules on every row.** A row that is broken is refused as `E_PARSE`. A row that is well formed and names a state, worker, lane or kind Logbook does not know is refused as `E_NEEDS_SUBTOOL`. The message is a fixed sentence and never repeats a value from the row.
- **An append-only ledger.** An entry can be added. It cannot be changed or removed by any role.
- **One transaction.** A change of state, the next queue step and the ledger entry are kept together or not at all.

[`SPEC.md`](SPEC.md) lists every table, column, rule and view.

## Running the tests

The tests need the PostgreSQL 17 programs and an ordinary user. They refuse to run as root.

```sh
sh tests/run.sh
# or, if PostgreSQL 17 is not on PATH:
PG_BINDIR=/usr/lib/postgresql/17/bin sh tests/run.sh
```

The script starts a private PostgreSQL server in a temporary directory, reachable only through a socket in that directory, and removes it when it finishes. For each directory under [`tests/cases`](tests/cases) it makes a new database, applies the migrations, runs `input.sql` and compares the output with `expected.out`, byte for byte. It then checks that:

- every rule in the migrations has a saved example,
- a migration cannot be applied twice,
- the first migration stops if one of the three roles already exists and can log in,
- a member of `backup_ro` can dump the database and a member of `pub_ro` cannot.

It exits with 0 when everything passed, 1 when a test failed and 2 when it could not run.

To change a behaviour, change the migration and the `expected.out` that shows it. A change to one without the other fails.

## Applying the migrations

As a superuser, or as the owner of an empty database who may create roles, apply each file once, in order:

```sh
for file in migrations/*.sql; do
  psql -X -v ON_ERROR_STOP=1 -f "$file" || break
done
```

Each file runs in one transaction and records itself in `core.migration`. A second run of a file is refused and changes nothing. Then make one login user for each service and add it to its role, for example `CREATE ROLE <name> LOGIN IN ROLE pub_ro`. The passwords belong in the cluster’s secrets and never in this repository.

## Not yet done

From [`SPEC.md`](SPEC.md):

- **The nightly backup.** The consistent dump, the `age` encryption, the transfer off the node and the removal of old copies. The role the job connects with exists and is tested to be able to take a dump.
- **The monthly restore drill.** The job, and the integrity checks it runs on `core` and `pub`. The table and the view for its result exist. A dump does not carry roles, so the drill will have to create the three roles before it restores.
- **Deployment.** The workload, its volume, its priority class, the network policy, and running as a non-root user with no added privileges within 256 MiB. None of these are SQL, and none are in this repository yet.
- **A run inside the `postgres:17-alpine` image.** The tests have been run with PostgreSQL 17.12 on Ubuntu, as an ordinary user. They have not been run inside the image, with a read-only filesystem or under a 256 MiB limit.
- **The six questions under “Still open”** in the Data model section of the specification.

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

## Names

`logbook` is this component’s identifier everywhere: the repository, the workload, the container image. The one place names are written down is the [naming registry](https://clearedstack.com/platform/registry.json), kept in [`clearedstack.com`](https://github.com/ClearedStack/clearedstack.com/blob/main/src/data/registry.json). `component.json` here is a copy of this component’s entry. If the two disagree, the registry is right.

## Ground rules

- **No AI when it runs.** The same input gives the same output on any machine.
- **Stop instead of guessing.** A case with no rule is paused and reported, never improvised.
- **Clean room.** Written from scratch. No code, text or design is copied from another project.
- **Public sources and made-up data only.** Nothing classified, controlled or taken from a real contract, in code, tests, issues or commit messages.

## License

[MIT](LICENSE). ClearedStack is an independent personal project. It is not affiliated with, endorsed by, or sponsored by the U.S. Department of Defense or any other government agency.
