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

> **Status: design.** The first milestone is built: the schema, the public views and the read-only role, with tests. Most of the specification is not built yet. See [What works today](#what-works-today).

Logbook is a control-plane service of the ClearedStack platform. ClearedStack is an open pipeline that finds ideas for government-contracting tools, screens and scores them, and builds each one from the public rule. Logbook is meant to be understood and used without the rest.

## What works today

The first milestone only: the database schema as migrations, with tests.

- **Working tables** in the `core` schema: `item`, `evaluation`, `decision`, `queue_lease`, `edit_proposal`, `ledger`, `restore_drill`, `restore_drill_check`, and `migration` (the record of which migration files have been applied).
- **Public views** in the `pub` schema: `item`, `evaluation`, `decision`, `edit_proposal`, `restore_drill`. They show only published items, approved edit proposals and finished restore drills, and only the columns each view names.
- **The read-only role** `pub_ro`: it can read the `pub` views and nothing else. It is created without a login or password; how Conn becomes `pub_ro` is left to whoever deploys Logbook.
- **A migration runner**, `bin/migrate`: applies the files in `migrations/` in order, each in one transaction, and stops if an already-applied file has changed or gone missing.
- **Tests** proving, among other things, that `pub_ro` cannot read any working table.

The table and column names, and the rule for what counts as public, are not given by `SPEC.md`. They are a first proposal and are listed as open questions in the pull request that added them.

### Running it

You need `psql` and a PostgreSQL 17 server. Point the usual PostgreSQL environment variables (`PGHOST`, `PGUSER`, `PGDATABASE`, ...) at an empty database and run:

```sh
bin/migrate
```

### Running the tests

With Docker, which starts a throwaway `postgres:17-alpine` limited to 256 MiB and removes it afterwards:

```sh
tests/run-in-docker.sh
```

Or against a server you already have, as a user who may create a database and a role:

```sh
tests/run.sh
```

Each file in `tests/cases/` is run against the made-up records in `tests/fixtures/seed.sql`, and its output must match the saved file of the same name in `tests/expected/` exactly. Note that `pub_ro` is created on the server and is left there after the tests.

### Not yet done

Everything else in `SPEC.md`, including:

- Muster's read/write access to `core` (no role or grants for Muster exist yet).
- Enforcing that the ledger is append-only. The `core.ledger` table exists, but nothing yet stops a row being changed or deleted.
- Queue behaviour: leasing, `needs_subtool` pauses and replay. Only the table exists.
- Nightly encrypted backups, the monthly restore drill and its integrity checks.
- Deployment: the workload, its volume, the network policy, running as non-root with a read-only filesystem.
- The three public error codes (`E_TIMEOUT`, `E_PARSE`, `E_NEEDS_SUBTOOL`). Nothing built so far reports them.

## In this repository

| File | What it is |
| --- | --- |
| [`SPEC.md`](SPEC.md) | The specification: what Logbook does, its interfaces, how it fails and how it is kept safe. |
| [`PROMPT.md`](PROMPT.md) | The prompt to start a build session with. It says what to build and the rules to build it under. |
| [`component.json`](component.json) | This component’s entry in the ClearedStack naming registry. |
| [`migrations/`](migrations) | The schema, as numbered SQL files for PostgreSQL 17. |
| [`bin/migrate`](bin/migrate) | Applies the migrations. |
| [`tests/`](tests) | The test cases, the made-up records they use and the exact output expected. |
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

## Names

`logbook` is this component’s identifier everywhere: the repository, the workload, the container image. The one place names are written down is the [naming registry](https://clearedstack.com/platform/registry.json), kept in [`clearedstack.com`](https://github.com/ClearedStack/clearedstack.com/blob/main/src/data/registry.json). `component.json` here is a copy of this component’s entry. If the two disagree, the registry is right.

## Ground rules

- **No AI when it runs.** The same input gives the same output on any machine.
- **Stop instead of guessing.** A case with no rule is paused and reported, never improvised.
- **Clean room.** Written from scratch. No code, text or design is copied from another project.
- **Public sources and made-up data only.** Nothing classified, controlled or taken from a real contract, in code, tests, issues or commit messages.

## License

[MIT](LICENSE). ClearedStack is an independent personal project. It is not affiliated with, endorsed by, or sponsored by the U.S. Department of Defense or any other government agency.
