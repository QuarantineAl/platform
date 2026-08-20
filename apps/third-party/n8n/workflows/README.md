# n8n workflows — git as source of truth

n8n's own Postgres database (`needs_db: true`, see
`apps/third-party/n8n/compose.yaml`) is runtime state, not source of truth
— it can be rebuilt from this directory, but this directory cannot be
rebuilt from it after the fact if it's ever lost or corrupted.

**The rule: every production workflow is exported as JSON and committed
here**, one file per workflow, before or immediately after activating it in
the editor. A workflow that only exists in n8n's database does not count as
shipped.

## Exporting

Editor → open the workflow → menu (⋯) → Download, or the n8n CLI:

```bash
docker exec quarantine-n8n n8n export:workflow --id=<id> --output=/tmp/<name>.json
docker cp quarantine-n8n:/tmp/<name>.json apps/third-party/n8n/workflows/<name>.json
```

Commit the result like any other change to this repo (see the root
`CLAUDE.md`/session rules for branch/commit conventions if you're an agent
doing this).

## Importing

No sync automation exists yet — this is a manual step, either through the
editor's own Import from File, or:

```bash
docker cp apps/third-party/n8n/workflows/<name>.json quarantine-n8n:/tmp/<name>.json
docker exec quarantine-n8n n8n import:workflow --input=/tmp/<name>.json
```

Credentials are never exported alongside a workflow (n8n's own export
deliberately omits credential values) — re-attach the workflow's
credential references by hand after import, same as any fresh environment.

## What does NOT belong here

No credentials, no `.n8n` binary-data exports, no sample/demo workflows —
this directory is exclusively the JSON export of workflows actually running
in an environment that matters.
