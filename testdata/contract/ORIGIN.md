# Origin of the saved Contract v1 examples

The `.json` files and `README.md` in this directory are copied unchanged from `ClearedStack/muster`:

- Repository: `https://github.com/ClearedStack/muster`
- Directory: `contract/v1/examples`
- Branch: `claude/repo-build-prompt-1csgx6` (PR #2)
- Commit: `470dddfe8410738052655313bd32fbeefc715f9f`

`contract_test.go` replays every file here against a PostgreSQL 17 database migrated with `migrate.sh`, exercising the `muster` and `pub_ro` roles, all working tables, public views, refusal rules and `core.integrity_check()`.
