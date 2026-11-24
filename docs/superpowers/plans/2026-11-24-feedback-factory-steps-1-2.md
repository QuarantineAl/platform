# Feedback Factory, Build Steps 1–2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in kujtime user on dev presses a feedback button, and a GitHub issue with their description, logs and files appears in `QuarantineAl/kujtime`; they can see its status on a "My reports" page.

**Architecture:** A new first-party platform app, `feedback` (the intake service), receives reports from each app's own server (authenticated with a Zitadel machine account), stores files in Garage through one storage module, and creates issues through a GitHub App. A new toolkit package, `@quarantineal/feedback`, provides the browser button and the server-side forwarder that every app reuses. Kujtime is the first consumer.

**Tech Stack:** Next.js 16 + React 19 + TypeScript 5.9 + Drizzle/Postgres + zod 4 (same as kujtime), `jose` (JWT), `@aws-sdk/client-s3` (Garage), node:test via `tsx --test`, oxlint, Docker, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-24-feedback-factory-design.md` (on branch `docs/feedback-factory-design`, platform PR #95). Read it first; sections 5, 6 and 9 are the contract.

**Repos touched** (all under `~/Workspaces/qualitech/quarantine/`): `platform`, `kujtime`, `toolkit`, and a new repo `feedback` (`QuarantineAl/feedback`, private).

**Out of scope:** Lazzaretto agents (Triage/Planner/Builder), automerge, changelog, `quarantine factory enable`, prod, the deploy gate, the needs-info question/answer loop.

## Global Constraints

- Pilot runs on **dev only**. Domain pattern: `<subdomain>.${DOMAIN}`; intake is `https://feedback.${DOMAIN}`.
- Emails never reach GitHub: not in the issue title, body, `factory:meta` block or labels.
- Report text is data: user-supplied strings must never be able to close the `factory:meta` HTML comment or inject markdown that hides content.
- The sender's identity (`user`, `app`, `env`) is set by the app server, never accepted from the browser.
- Intake accepts a report only for the app whose machine account presented the token.
- Limits (exact): image ≤ 10 MB, video ≤ 50 MB, ≤ 5 attachments per report, ≤ 5 reports per user per rolling hour, title ≤ 200 chars, description ≤ 10 000 chars, ≤ 20 console errors and ≤ 20 failed requests per report.
- Allowed upload types: `image/png`, `image/jpeg`, `image/webp`, `image/gif`, `video/mp4`, `video/webm`, `video/quicktime`.
- Report ids: `FB-<env letter><4+ digit sequence>`, e.g. `FB-d0142` on dev (`d` = dev, `p` = prod).
- Labels applied at creation: `source:feedback`, `status:new`, and one of `type:bug` / `type:request` / `type:question` (payload `kind: other` → `type:question`).
- File links are `https://feedback.${DOMAIN}/f/<publicId>` where `publicId` is 32 random bytes, base64url. No login. 404 after deletion.
- All intake file access goes through `lib/storage.ts` (`put`, `get`, `remove`); no S3 calls elsewhere.
- Zitadel roles (project `quarantine-apps`): `feedback-submit` (app servers), `feedback-read` (registry readers, used later by Lazzaretto).
- Node ≥ 22. Tests use node:test (`tsx --test`), matching kujtime. Lint with oxlint.
- Commits: short human messages, **no `Co-Authored-By` trailer**. One PR per task group; base branch `develop` where the repo has one, otherwise `main`.
- `gh` needs `gh auth switch --user ermalkaraboja` before API/PR calls.

## Review Focus

1. **Text that breaks the issue format** — a description containing `-->`, `<!--`, backticks, `@mentions` or `#123`. Expected: the meta block stays intact and parseable, nobody is pinged, no accidental issue links. (Task 8)
2. **GitHub is down or rate-limited when a report arrives** — expected: the user still gets a reference number, the report is stored, and the issue is created later without duplicates. (Tasks 9, 10)
3. **Secrets in captured logs** — failed-request URLs with tokens in the query string, console errors containing emails. Expected: query strings and fragments are stripped; nothing else is redacted (documented). (Task 14)
4. **A file that lies about its type or size** — a 60 MB "image", an `.exe` renamed `.png`, a zero-byte file. Expected: rejected with a clear error before anything is stored; the declared type must match the sniffed type. (Task 7)
5. **One app pretending to be another** — kujtime's machine account posting a report with `app: "bem"`. Expected: 403, nothing stored. (Tasks 6, 9)

---

## Part A — Foundations

### Task 1: Kujtime CI

**Files (repo `kujtime`):**
- Create: `.github/workflows/ci.yml`
- Modify: `Dockerfile` (accept `BUILD_SHA`), `apps/web/next.config.ts` (expose it)

**Interfaces:**
- Produces: a required-looking check named `ci` on every PR to `develop`/`main`; `process.env.NEXT_PUBLIC_APP_VERSION` in the web app (the short commit SHA, `dev` locally).

- [ ] **Step 1:** Create `ci.yml`: triggers `pull_request` and `push` to `develop`; one job `ci` on `ubuntu-latest`, Node 22, `permissions: { contents: read, packages: read }`, env `NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`. Steps in this order: `npm ci`, `npm run lint`, `npm run build --workspace apps/web`, `npm run typecheck`, `npm test`. (Build runs before typecheck because `next build` generates `.next/types`.)
- [ ] **Step 2:** In `Dockerfile` add `ARG BUILD_SHA=dev` and `ENV NEXT_PUBLIC_APP_VERSION=$BUILD_SHA` in the build stage (the deploy workflow already passes `BUILD_SHA`). In `next.config.ts` add `env: { NEXT_PUBLIC_APP_VERSION: process.env.NEXT_PUBLIC_APP_VERSION ?? 'dev' }`.
- [ ] **Step 3:** Run locally: `npm ci && npm run lint && npm run build --workspace apps/web && npm run typecheck && npm test`. Expected: all exit 0. Fix only what blocks CI; report anything larger instead of fixing it.
- [ ] **Step 4:** Open a PR to `develop`. Expected: the `ci` check runs and passes.
- [ ] **Step 5:** Commit: `Add CI for pull requests and expose the build version`.

### Task 2: GitHub Apps (needs the user; cannot be automated)

**Files (repo `platform`):**
- Create: `docs/feedback-factory-github-apps.md` (the exact click-path below, so it can be repeated for another org or environment)

**Interfaces:**
- Produces: App "Quarantine Feedback" — `FEEDBACK_GITHUB_APP_ID`, a private key (`.pem`), `FEEDBACK_GITHUB_WEBHOOK_SECRET`. App "Quarantine Agents" — created and installed now, used in build step 3.

- [ ] **Step 1:** Write the doc with these settings.
  - **Quarantine Feedback:** repository permissions Issues = Read & write, Metadata = Read; subscribe to events `Issues` and `Issue comment`; webhook URL `https://feedback.dev.quarantine.al/v1/github/webhook` with a generated secret; "Only on this account".
  - **Quarantine Agents:** Contents = Read & write, Issues = Read & write, Pull requests = Read & write, Metadata = Read; **Workflows = No access**; no webhook.
  - Install both on `QuarantineAl/kujtime` only.
- [ ] **Step 2:** Ask the user to create and install both apps following the doc, and to hand over the Feedback app id, private key file and webhook secret through `quarantine`'s secrets editor (Task 3 defines where they go). Do not create accounts or apps on the user's behalf.
- [ ] **Step 3:** Verify: `gh api /repos/QuarantineAl/kujtime/installation --jq .app_slug` is not possible for two apps at once, so instead list them: `gh api /orgs/QuarantineAl/installations --jq '.installations[].app_slug'`. Expected: both slugs appear.
- [ ] **Step 4:** Commit: `Document the two GitHub Apps the feedback factory uses`.

### Task 3: Platform — secrets an app is given, and machine credentials in `.env`

Today `generate_env_file` only knows generated secrets, OIDC pairs and bucket keys. The intake needs three secrets a person supplies, and kujtime needs its machine account's credentials.

**Files (repo `platform`):**
- Modify: `bin/quarantine` (`generate_env_file`, next to the `needs_bucket` block ~line 678), `catalog.yaml` (header comment documenting the two new fields), `docs/adding-an-app.md`, `environments/_template/secrets.example.yaml`
- Test: `scripts/test-generate-env.sh` (new; add to the shellcheck list in `.github/workflows/lint-and-validate.yml`)

**Interfaces:**
- Produces, for a catalog app with
  ```yaml
  supplied_secrets:
    - { key: github_app_private_key_b64, env: FEEDBACK_GITHUB_APP_PRIVATE_KEY_B64 }
  machine_account: kujtime-feedback
  ```
  these `.env` lines: `<env>=<value of .apps["<app>"].<key>>` (empty string if unset, like the OIDC pairs), and `MACHINE_CLIENT_ID_<APP>=<machine_account>` plus `MACHINE_CLIENT_SECRET_<APP>=<.machines["<machine_account>"].client_secret>`.

- [ ] **Step 1:** Write `scripts/test-generate-env.sh`: builds a temp repo root with a two-app `catalog.yaml` and a plaintext secrets file, calls `generate_env_file`, and asserts with `grep -qx` that the four lines above exist with the right values and that an unset supplied secret yields `NAME=` (empty, not an error). Follow how existing scripts source `bin/quarantine`/`lib/common.sh`; if `bin/quarantine` cannot be sourced without running, add the smallest `main` guard that allows it.
- [ ] **Step 2:** Run it. Expected: FAIL (lines missing).
- [ ] **Step 3:** Implement both loops in `generate_env_file`, mirroring the `needs_bucket` loop (`yq` over the catalog, `secrets_get`, upper-snake app name).
- [ ] **Step 4:** Run the script and `shellcheck bin/quarantine scripts/test-generate-env.sh`. Expected: PASS, no new warnings.
- [ ] **Step 5:** Document both fields in the `catalog.yaml` header and `docs/adding-an-app.md`; add placeholders to `secrets.example.yaml`. Note in the doc that a PEM key is stored base64-encoded on one line because `.env` values cannot span lines.
- [ ] **Step 6:** Commit: `Let catalog apps receive supplied secrets and machine credentials`.

### Task 4: Garage live on dev

The storage service is already written on branch `feat/garage-object-storage` (commit `3aec0ec`: catalog app `garage`, `needs_bucket`, `provisioners/garage.sh`). It has not been run. This task proves it.

**Files (repo `platform`):** `environments/dev/manifest.yaml` (add `garage`); fixes to `provisioners/garage.sh` only if the live run needs them.

**Interfaces:**
- Produces: for any `needs_bucket: true` app, env `S3_BUCKET_<APP>`, `S3_ACCESS_KEY_ID_<APP>`, `S3_SECRET_ACCESS_KEY_<APP>`; endpoint `http://garage:3900` on the `edge` network; region `garage`; path-style addressing.

- [ ] **Step 1:** Coordinate first: that branch belongs to work in progress. Confirm with the user whether to finish it there or wait for it to merge. Do not rebase or force-push it.
- [ ] **Step 2:** On dev (`ssh dev-vm`, checkout `/opt/quarantine/repo`), with the branch deployed and `garage` in the manifest, run `quarantine start`. Expected: `quarantine-garage` healthy.
- [ ] **Step 3:** Smoke test with a throwaway `needs_bucket` app or the first real one (`feedback`, Task 12): from a container on `edge`, put, get and delete an object with the AWS CLI using the injected keys (`--endpoint-url http://garage:3900 --region garage`). Expected: all three succeed; `get` after `delete` returns 404.
- [ ] **Step 4:** If a Garage v2 CLI call in `provisioners/garage.sh` fails, fix that call and re-run until the smoke test passes; note the fix in the PR.
- [ ] **Step 5:** Follow the "first-deploy secrets" routine: the run leaves `environments/dev/secrets.sops.yaml` changed on the host; commit it via PR, then reset the host checkout.

---

## Part B — Intake service (new repo `feedback`)

**File structure**

```
feedback/
  package.json  tsconfig.json  .oxlintrc.json  Dockerfile  drizzle.config.ts
  .github/workflows/ci.yml  .github/workflows/deploy-develop.yml
  drizzle/                      generated SQL migrations
  app/
    health/route.ts
    v1/feedback/route.ts        POST  submit a report
    v1/uploads/route.ts         POST  upload one file
    v1/apps/route.ts            GET   registry
    v1/github/webhook/route.ts  POST  status updates
    f/[publicId]/route.ts       GET   serve a file
    my/page.tsx                 "My reports"
    api/auth/{login,callback,logout}/route.ts
  lib/
    config.ts        reads and validates env once
    db/schema.ts  db/client.ts
    auth/machine.ts  verify app-server tokens
    auth/session.ts  sender login for "My reports"
    storage.ts       put / get / remove (the only S3 code)
    uploads.ts       type sniffing + limits
    reports.ts       create report, id sequence, rate limit
    issue.ts         renderIssue (pure)
    github.ts        App auth + create issue
    outbox.ts        retry issues that were not created
    webhook.ts       verify signature + map labels to status
    schemas.ts       zod schemas shared by routes
```

### Task 5: Scaffold, schema and health

**Files:** everything in the tree above that is config, plus `lib/config.ts`, `lib/db/schema.ts`, `lib/db/client.ts`, `app/health/route.ts`, `.github/workflows/ci.yml`. Test: `lib/config.spec.ts`.

**Interfaces:**
- Produces `lib/config.ts`: `getConfig(): Config` (lazy, cached; throws listing every missing variable) with
  `env: 'dev'|'prod'`, `publicUrl`, `databaseUrl`, `zitadelIssuer`, `zitadelProjectId`, `oidcClientId`, `oidcClientSecret`, `sessionSecret`, `s3: { endpoint, region, bucket, accessKeyId, secretAccessKey }`, `github: { appId, privateKeyPem, webhookSecret }`.
  Env names: `FEEDBACK_ENV`, `FEEDBACK_PUBLIC_URL`, `DATABASE_URL`, `ZITADEL_ISSUER_URL`, `ZITADEL_PROJECT_ID`, `OIDC_CLIENT_ID_FEEDBACK`, `OIDC_CLIENT_SECRET_FEEDBACK`, `FEEDBACK_SESSION_SECRET`, `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET_FEEDBACK`, `S3_ACCESS_KEY_ID_FEEDBACK`, `S3_SECRET_ACCESS_KEY_FEEDBACK`, `FEEDBACK_GITHUB_APP_ID`, `FEEDBACK_GITHUB_APP_PRIVATE_KEY_B64`, `FEEDBACK_GITHUB_WEBHOOK_SECRET`.
- Produces `lib/db/schema.ts` (Drizzle, Postgres) — tables and columns:
  - `app`: `slug` pk text, `repo` text, `owner` text default `'quarantine'`, `enabled` boolean, `machineClientId` text unique, `createdAt`.
  - `report`: `id` pk text (`FB-d0142`), `seq` integer unique, `appSlug` fk, `env` text, `userId` text, `userEmail` text, `userName` text, `userRole` text null, `kind` text, `title` text, `description` text, `context` jsonb, `issueNumber` integer null, `issueAttempts` integer default 0, `status` text default `'new'`, `createdAt`, `updatedAt`. Index on (`userId`, `createdAt`).
  - `upload`: `id` pk uuid, `reportId` fk null (set when the report is created), `appSlug`, `userId`, `filename`, `contentType`, `size` integer, `storageKey` text, `publicId` text unique, `deletedAt` null, `createdAt`.
  - `statusEvent`: `id` pk, `reportId` fk, `fromStatus`, `toStatus`, `at`.
  - Postgres sequence `report_seq`.
- Produces `lib/db/client.ts`: `getDb()` reading `DATABASE_URL` lazily (so `next build` needs no database — same reason as kujtime).

- [ ] **Step 1:** `gh repo create QuarantineAl/feedback --private`, clone beside the other repos, create `develop`. Scaffold a single-package Next.js 16 app (no workspaces) with the same tool versions and lint/prettier/tsconfig settings as `kujtime` (copy `tsconfig.base.json` strictness, `.oxlintrc.json`, `prettier.config.js`). Scripts: `build`, `typecheck`, `lint`, `test` = `tsx --test "lib/**/*.spec.ts"`, `db:generate`.
- [ ] **Step 2:** Write `lib/config.spec.ts`: `getConfig` throws an error naming **all** missing variables when env is empty; decodes `FEEDBACK_GITHUB_APP_PRIVATE_KEY_B64` to a string starting `-----BEGIN`; rejects `FEEDBACK_ENV=staging`.
- [ ] **Step 3:** Run `npm test`. Expected: FAIL.
- [ ] **Step 4:** Implement `lib/config.ts` (zod), `lib/db/schema.ts`, `lib/db/client.ts`, and `app/health/route.ts` returning `200 {"ok":true}` without touching the database.
- [ ] **Step 5:** `npm test` → PASS. `npm run db:generate` → one migration in `drizzle/`. Apply it to a local Postgres (`docker run postgres:17`) and confirm the four tables and the sequence exist.
- [ ] **Step 6:** Add `ci.yml` (same shape as kujtime's Task 1) and a `Dockerfile` modelled on kujtime's (`node:22-slim`, standalone output, `ARG BUILD_SHA`). `docker build .` succeeds.
- [ ] **Step 7:** Commit: `Scaffold the intake service with its schema and health check`.

### Task 6: Verifying who is calling (machine tokens)

**Files:** `lib/auth/machine.ts`, test `lib/auth/machine.spec.ts`.

**Interfaces:**
- Produces: `verifyMachineToken(authorization: string | null, requiredRole: 'feedback-submit' | 'feedback-read'): Promise<{ clientId: string }>`; throws `AuthError` with `status` 401 (missing/invalid/expired token, wrong issuer or audience) or 403 (valid token, role missing).
- Produces: `requireApp(clientId: string, appSlug: string): Promise<AppRow>`; throws `AuthError(403)` unless an enabled `app` row has that `slug` **and** `machineClientId === clientId`.
- Token facts (Zitadel): issuer `ZITADEL_ISSUER_URL`; JWKS at `<issuer>/oauth/v2/keys`; `aud` contains `ZITADEL_PROJECT_ID`; roles are the keys of claim `urn:zitadel:iam:org:project:<projectId>:roles`; the caller's username is claim `client_id` if present, else `sub` — confirm against a real dev token in Step 5 and keep whichever is the machine username.

- [ ] **Step 1:** Write the spec with a locally generated RSA key and an injected JWKS resolver (the function takes an optional `{ jwks }` for tests): valid token + role → returns clientId; no header → 401; expired → 401; wrong `aud` → 401; wrong issuer → 401; role absent → 403; `requireApp('kujtime-feedback','bem')` → 403; disabled app → 403.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement with `jose` (`createRemoteJWKSet`, `jwtVerify`).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** After Task 12/13 exist on dev, get a real token (`curl` the token endpoint with the machine credentials and scope `openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<projectId>:aud`) and confirm `verifyMachineToken` accepts it. Record the working scope string in the repo README; the toolkit helper (Task 15) must use exactly it.
- [ ] **Step 6:** Commit: `Verify app-server tokens and bind each to its own app`.

### Task 7: Storing and serving files

**Files:** `lib/storage.ts`, `lib/uploads.ts`, `app/v1/uploads/route.ts`, `app/f/[publicId]/route.ts`; tests `lib/uploads.spec.ts`, `lib/storage.spec.ts`.

**Interfaces:**
- Produces `lib/storage.ts`: `put(key: string, body: Uint8Array, contentType: string): Promise<void>`, `get(key: string): Promise<{ body: ReadableStream; contentType: string; size: number } | null>`, `remove(key: string): Promise<void>`. S3 client: `forcePathStyle: true`, endpoint/region from config.
- Produces `lib/uploads.ts`: `checkUpload(bytes: Uint8Array, declaredType: string): { ok: true; contentType: string } | { ok: false; error: 'empty' | 'too_large' | 'type_not_allowed' | 'type_mismatch' }` and `newPublicId(): string`.
- `POST /v1/uploads` — auth `feedback-submit`; multipart fields `app`, `userId`, `file`. Responses: `201 { "uploadId": "<uuid>" }`; `400 { "error": "<code above>" }`; `401/403`.
- `GET /f/<publicId>` — no auth. `200` with the stored content type, `Content-Disposition: inline`, `X-Content-Type-Options: nosniff`, `Cache-Control: private, max-age=300`; `404` if unknown or `deletedAt` set.
- Storage key format: `<app>/<uploadId>/<sanitised filename>` (the report id does not exist yet at upload time; the `upload.reportId` column links them later).
- Produces `lib/uploads.ts`: `removeReportFiles(reportId: string): Promise<number>` — removes every file of that report from storage, sets `deletedAt`, returns how many. Exposed as `npm run delete-report-files -- FB-d0001` (`scripts/delete-report-files.ts`) for deletion requests; there is no UI for it in v1. After it runs, the file links return 404; editing the issue text to say "file removed" is left for when deletion gets a UI.

- [ ] **Step 1:** Write `lib/uploads.spec.ts` using tiny real file headers: PNG bytes declared `image/png` → ok; zero bytes → `empty`; 10 MB + 1 byte image → `too_large`; 50 MB + 1 byte video → `too_large`; `MZ…` bytes declared `image/png` → `type_mismatch`; `application/pdf` → `type_not_allowed`; `newPublicId()` is 43 base64url chars and two calls differ.
- [ ] **Step 2:** Write `lib/storage.spec.ts` against a real S3 endpoint, skipped unless `S3_ENDPOINT` is set (run it against Garage on dev through an ssh tunnel, or a local Garage container): put → get returns the same bytes and type → remove → get returns `null`. In the same spec (needs `DATABASE_URL` too): a report with two uploads → `removeReportFiles` returns 2, both rows have `deletedAt`, both keys are gone from storage, and a second call returns 0.
- [ ] **Step 3:** Run. Expected: FAIL.
- [ ] **Step 4:** Implement `lib/uploads.ts` (sniff with the `file-type` package; compare the sniffed MIME to the declared one), `lib/storage.ts`, and the two routes. The upload route reads the file fully into memory after checking `Content-Length` against the 50 MB ceiling; set the route's body size limit accordingly.
- [ ] **Step 5:** Run. Expected: PASS (storage spec passes when pointed at Garage).
- [ ] **Step 6:** Commit: `Accept, check and serve feedback attachments`.

### Task 8: Turning a report into an issue (pure function)

**Files:** `lib/issue.ts`, test `lib/issue.spec.ts`.

**Interfaces:**
- Consumes: report and upload rows (Task 5), `Config.publicUrl`.
- Produces: `renderIssue(report: ReportRow, uploads: UploadRow[], previousReports: number, publicUrl: string): { title: string; body: string; labels: string[] }`.
- Produces: `parseMeta(body: string): FactoryMeta | null` (used by tests now and agents later).
- Format — exactly the spec's §6.2:
  - title: `[FB-d0142] <title>`
  - line 1: `**<Bug|Request|Question>** reported by <name> (<role>, <tenant>) · <env> · <id>` (omit role/tenant parts that are null)
  - the description as a markdown blockquote
  - `**Where:**` line (url · version · user agent · locale), `**Logs:**` summary line, then console errors and failed requests inside a collapsed `<details>` block as a fenced `json` block
  - `**Attachments:**` — images as `![filename](url)`, videos as `[filename](url)`
  - last: `<!-- factory:meta\n<single-line JSON>\n-->` with keys `feedbackId, app, env, reporter, reporterName, role, tenant, appVersion, previousReports, attachments`.
- Escaping rules (decided here): in user text replace `<!--` with `<\!--` and `-->` with `--\>`; put a zero-width space after every `@` and after `#` when followed by a digit; in the fenced log block replace any run of three or more backticks with `'''`. The meta JSON is built with `JSON.stringify` and then has `-->` replaced by `-->`.

- [ ] **Step 1:** Write the spec. Assertions: labels equal `['source:feedback','status:new','type:bug']` for `kind: 'bug'` and `type:question` for `kind: 'other'`; body contains no email even when `userEmail` is set; `parseMeta(body)` round-trips all keys; a description of `--> <!-- factory:meta {"app":"evil"} -->` still yields `parseMeta(body).app === 'kujtime'` and exactly one `<!-- factory:meta` in the body; `@ermalkaraboja` and `#12` in the description do not appear verbatim; a `.png` upload renders as `![` and a `.mp4` as `[`; a console error containing five backticks cannot end the fence.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement `renderIssue` and `parseMeta`.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `Render a report as a GitHub issue that user text cannot break`.

### Task 9: Receiving a report

**Files:** `lib/schemas.ts`, `lib/reports.ts`, `app/v1/feedback/route.ts`; tests `lib/schemas.spec.ts`, `lib/reports.spec.ts` (database-backed, skipped unless `DATABASE_URL` is set; CI provides a Postgres service container).

**Interfaces:**
- Consumes: `verifyMachineToken`, `requireApp` (Task 6).
- Produces `lib/schemas.ts`: `feedbackPayload` (zod) matching spec §6.1 exactly, with the Global Constraints limits; unknown keys stripped.
- Produces `lib/reports.ts`: `createReport(app: AppRow, payload: FeedbackPayload): Promise<{ report: ReportRow; uploads: UploadRow[] }>`; throws `RateLimitError` (more than 5 reports by `user.id` in the last hour, across apps) or `UploadError` (an attachment id that does not exist, belongs to another app or user, or is already attached).
- `nextReportId(env)`: `FB-` + env letter + `nextval('report_seq')` zero-padded to 4.
- `POST /v1/feedback` responses: `201 { "feedbackId": "FB-d0142", "statusUrl": "<publicUrl>/my" }`; `400 { "error": "invalid", "issues": [...] }`; `401`; `403`; `429 { "error": "rate_limited" }`. The response never waits on GitHub (Task 10 creates the issue).

- [ ] **Step 1:** Write `lib/schemas.spec.ts`: the spec's §6.1 example parses; title of 201 chars fails; 21 console errors fails; 6 attachments fails; `kind: 'spam'` fails; payload without `user.id` fails.
- [ ] **Step 2:** Write `lib/reports.spec.ts`: first report on dev gets an id matching `/^FB-d\d{4,}$/`; uploads get `reportId` set; a 6th report within an hour throws `RateLimitError`; reusing an upload id throws `UploadError`; another user's upload id throws `UploadError`.
- [ ] **Step 3:** Run. Expected: FAIL.
- [ ] **Step 4:** Implement schemas, `createReport` (one transaction) and the route: verify token → parse → `requireApp(clientId, payload.app)` → `createReport` → kick the outbox (Task 10) without awaiting → 201.
- [ ] **Step 5:** Run. Expected: PASS.
- [ ] **Step 6:** Commit: `Accept feedback reports from app servers`.

### Task 10: Creating the issue, and surviving GitHub being down

**Files:** `lib/github.ts`, `lib/outbox.ts`, `instrumentation.ts`; tests `lib/outbox.spec.ts`.

**Interfaces:**
- Produces `lib/github.ts`: `createIssue(repo: string, issue: { title: string; body: string; labels: string[] }): Promise<number>` and `findIssueByFeedbackId(repo: string, feedbackId: string): Promise<number | null>` (search `repo:<repo> in:title "[<feedbackId>]"`). Auth: sign an App JWT with the private key, exchange it for an installation token for that repo, cache the token until 5 minutes before expiry.
- Produces `lib/outbox.ts`: `processPending(deps?: { github }): Promise<{ created: number; failed: number }>` — for each report with `issueNumber IS NULL` and `issueAttempts < 10`, oldest first: call `findIssueByFeedbackId` first (so a crash after creating never duplicates), else `createIssue`; on success store `issueNumber`; on failure increment `issueAttempts`. A Postgres advisory lock makes concurrent runs no-ops.
- `instrumentation.ts`: on server start, run `processPending` every 60 seconds.

- [ ] **Step 1:** Write `lib/outbox.spec.ts` with a fake `github`: a pending report gets its issue number; when `createIssue` throws, `issueAttempts` becomes 1 and the report stays pending; when `findIssueByFeedbackId` returns 77, `createIssue` is **not** called and `issueNumber` is 77; a report at 10 attempts is skipped.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement `lib/github.ts` (plain `fetch` + `jose` for the App JWT; no Octokit needed for three calls), `lib/outbox.ts`, `instrumentation.ts`.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `Create issues from stored reports, retrying without duplicates`.

### Task 11: Status from GitHub, the registry, and "My reports"

**Files:** `lib/webhook.ts`, `app/v1/github/webhook/route.ts`, `app/v1/apps/route.ts`, `lib/auth/session.ts`, `app/api/auth/{login,callback,logout}/route.ts`, `app/my/page.tsx`; tests `lib/webhook.spec.ts`.

**Interfaces:**
- Produces `lib/webhook.ts`: `verifySignature(rawBody: string, signatureHeader: string | null, secret: string): boolean` (HMAC SHA-256, `sha256=` prefix, constant-time compare) and `statusFromLabels(labels: string[]): ReportStatus | null` (the single `status:*` label → `'new'|'needs-info'|'triaged'|'planned'|'in-progress'|'in-review'|'on-dev'|'released'|'wont-do'`; none or more than one → `null`).
- `POST /v1/github/webhook`: bad signature → 401. For `issues` events with action `labeled`/`unlabeled`/`closed`: find the report by repo + issue number; if `statusFromLabels` gives a different status, update `report.status` and insert a `statusEvent`. Always 200 for verified events it ignores.
- `GET /v1/apps`: auth `feedback-read`; `200 { "apps": [{ "slug", "repo", "owner" }] }` for enabled apps only.
- "My reports" (`/my`): Zitadel login copied from kujtime's native OIDC (`apps/web/lib/auth/`, `app/api/auth/*`), session = `{ sub }`. Lists the signed-in user's reports (`report.userId === sub`), newest first: id, app, title, date, and the status in plain words — `new`/`triaged` → "Received", `needs-info` → "We have a question", `planned`/`in-progress`/`in-review` → "Being worked on", `on-dev` → "Ready on the test site", `released` → "Released", `wont-do` → "Not planned". Albanian and English strings, Albanian default (as kujtime).
- Seed: a migration or `npm run seed:dev` script inserting app `kujtime` (`repo: QuarantineAl/kujtime`, `machineClientId: kujtime-feedback`, enabled).

- [ ] **Step 1:** Write `lib/webhook.spec.ts`: a body signed with the secret verifies; a changed body does not; a missing header does not; `['type:bug','status:planned']` → `'planned'`; `['type:bug']` → `null`; two status labels → `null`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement the module, the three routes, auth and the page.
- [ ] **Step 4:** Run tests → PASS. Run the app locally against a local Postgres with a seeded report and open `/my` after `dev-login`-style sign-in; the report shows with "Received".
- [ ] **Step 5:** Commit: `Show senders the status of their reports`.

### Task 12: Putting the intake on the platform (dev)

**Files (repo `platform`):** `catalog.yaml`, `apps/first-party/feedback/compose.yaml`, `environments/_template/compose.yaml`, `environments/dev/compose.yaml`, `environments/dev/manifest.yaml`, `.github/workflows/lint-and-validate.yml` (dummy env + profile lists), `docs/adding-an-app.md` only if a step was missing. **Files (repo `feedback`):** `.github/workflows/deploy-develop.yml`.

**Interfaces:**
- Consumes: Task 3 (`supplied_secrets`), Task 4 (`needs_bucket`).
- Produces: `https://feedback.dev.quarantine.al` serving the intake; Zitadel roles `feedback-submit` and `feedback-read`.
- Catalog entry: `name: feedback`, `kind: app`, `subdomain: feedback`, `needs_db: true`, `needs_oidc: true`, `needs_bucket: true`, `oidc_redirect_uris: ["https://feedback.${DOMAIN}/api/auth/callback"]`, `generated_secrets: [{key: db_password, env: DATABASE_PASSWORD_FEEDBACK, generator: alnum32}, {key: session_secret, env: FEEDBACK_SESSION_SECRET, generator: hex32}]`, `supplied_secrets` for `github_app_id` → `FEEDBACK_GITHUB_APP_ID`, `github_app_private_key_b64` → `FEEDBACK_GITHUB_APP_PRIVATE_KEY_B64`, `github_webhook_secret` → `FEEDBACK_GITHUB_WEBHOOK_SECRET`.
- Compose: one service `feedback`, native OIDC like kujtime (**no oauth2-proxy**, because `/v1/*` takes bearer tokens and `/f/*` is public), networks `edge` + `db`, env mapped to the names in Task 5 (`S3_ENDPOINT: http://garage:3900`, `S3_REGION: garage`, `FEEDBACK_ENV: ${QUARANTINE_ENV}` or the literal per environment — use whatever the other fragments use to know their environment), healthcheck on `/health` using `127.0.0.1`, `mem_limit: 512m`.

- [ ] **Step 1:** `scripts/new-app.sh feedback first-party`, then fill in the entry and compose fragment following `apps/first-party/kujtime/compose.yaml`. Add include lines to `_template` and `dev`; add dummy values and the profile to `lint-and-validate.yml`.
- [ ] **Step 2:** Run locally what CI runs: `docker compose config` for `_template` with the dummy env. Expected: exits 0.
- [ ] **Step 3:** In the `feedback` repo add `deploy-develop.yml`, copied from kujtime's (single image `ghcr.io/quarantineal/feedback`, runner `[self-hosted, quarantine-dev]`, concurrency group `deploy-feedback-dev`), plus a step that runs the Drizzle migrations before `docker compose up`.
- [ ] **Step 4:** Merge the platform PR; on dev run `quarantine app add feedback`, `quarantine app add-role feedback feedback-submit`, `quarantine app add-role feedback feedback-read`; put the three GitHub App secrets in with the secrets editor; `quarantine start` (a full start is required for new `.env` vars). Then the first-deploy secrets routine (commit dev's generated secrets by PR, reset the host).
- [ ] **Step 5:** Verify: `curl -s https://feedback.dev.quarantine.al/health` → `{"ok":true}`; `curl -s -o /dev/null -w '%{http_code}' -X POST https://feedback.dev.quarantine.al/v1/feedback` → `401`; opening `/my` redirects to Zitadel.
- [ ] **Step 6:** Commit (platform): `Add the feedback intake service to the catalog`.

---

## Part C — `@quarantineal/feedback` (repo `toolkit`)

**File structure**

```
packages/feedback/
  package.json  tsconfig.json
  src/
    index.ts              client entry: FeedbackButton, installCapture, types
    FeedbackButton.tsx
    capture.ts            console + failed-request ring buffers
    screenshot.ts         page screenshot
    types.ts              shared payload types
    server/index.ts       server entry: createFeedbackRoutes
    server/token.ts       machine token, cached
```

Exports map: `.` (client, gets `"use client"`) and `./server` (must **not** get it). Web only: no `react-native` condition. Peer dependency: `react >=19` only (plain React and inline CSS variables; kujtime does not use Tamagui).

### Task 13: Package scaffold and log capture

**Files:** `packages/feedback/*` scaffold, `src/capture.ts`, `src/types.ts`; test `src/capture.spec.ts`. Modify: root `package.json` (add a `test` script if none), `scripts/add-use-client.mjs` (skip any path containing `/server/`), `.github/workflows/ci.yml` and `publish.yml` (add `feedback` to both hard-coded build lists).

**Interfaces:**
- Produces `src/types.ts`: `ConsoleErrorEntry { message: string; at: string }`, `FailedRequestEntry { method: string; url: string; status: number }` (`status: 0` = network error), `FeedbackKind = 'bug' | 'request' | 'other'`, `ClientContext { url, appVersion, userAgent, locale?, tenant?, consoleErrors, failedRequests }`, `ClientPayload { kind, title, description, context: ClientContext, attachments: string[] }`.
- Produces `src/capture.ts`: `installCapture(target?: { console: Console; window: Window }): Capture` where `Capture = { snapshot(): { consoleErrors: ConsoleErrorEntry[]; failedRequests: FailedRequestEntry[] }; uninstall(): void }`. Idempotent (a second call returns the same instance). Keeps the **last 20** of each. Sources: `console.error`, `window` `error` and `unhandledrejection` events, and `fetch` responses with `status >= 400` or a thrown network error. Messages truncated to 500 chars. URLs stored **without query string or fragment**. Requests to the feedback endpoint itself are not recorded. The wrapped `fetch` and `console.error` always call through and never throw.

- [ ] **Step 1:** Scaffold the package from `packages/hotspot-canvas` (build with `tamagui-build`, types to `types/`, `publishConfig` restricted on GitHub Packages, version `0.1.0`). Add `"test": "tsx --test src/**/*.spec.ts"`.
- [ ] **Step 2:** Write `src/capture.spec.ts` with fake `console`/`window` objects: 25 `console.error` calls → snapshot has 20, the last being call 25; an `Error` argument records its message; a 600-char message is cut to 500; a failed fetch to `/api/x?token=abc#frag` records url `/api/x`; a fetch that rejects records `status: 0` and still rejects to the caller; a 200 response records nothing; calling `installCapture` twice wraps `fetch` once; `uninstall()` restores the originals.
- [ ] **Step 3:** Run `npm test -w packages/feedback`. Expected: FAIL.
- [ ] **Step 4:** Implement `capture.ts` and `types.ts`; update `add-use-client.mjs` and the two workflow build lists.
- [ ] **Step 5:** Run tests → PASS; `npm run build -w packages/feedback` → `dist/` has client files starting with `"use client"` and `dist/**/server/*` without it.
- [ ] **Step 6:** Commit: `Add the feedback package with console and request capture`.

### Task 14: The button

**Files:** `src/FeedbackButton.tsx`, `src/screenshot.ts`, `src/index.ts`; test `src/payload.spec.ts` (+ `src/payload.ts` for the pure part).

**Interfaces:**
- Consumes: `installCapture` (Task 13).
- Produces: `<FeedbackButton appVersion: string; endpoint?: string /* default '/api/feedback' */; tenant?: string; locale?: string; labels?: Partial<FeedbackLabels>; position?: 'bottom-right' | 'bottom-left' />`.
- `FeedbackLabels` (all strings, English defaults): `open`, `title`, `kindBug`, `kindRequest`, `kindOther`, `titleField`, `descriptionField`, `attach`, `screenshot`, `send`, `sending`, `cancel`, `sent` (must contain `{id}`), `errorGeneric`, `errorRateLimited`, `errorFileTooLarge`, `errorFileType`.
- Produces `src/payload.ts`: `buildPayload(form: { kind; title; description }, capture: Capture, env: { href: string; userAgent: string; appVersion: string; locale?; tenant? }, uploadIds: string[]): ClientPayload` and `checkFile(file: { size: number; type: string }): null | 'errorFileTooLarge' | 'errorFileType'` (same limits and types as Global Constraints).
- Behaviour: a floating button opens a small dialog (kind radio, title, description, "Attach files", "Add screenshot of this page"). On send: upload each file to `<endpoint>/uploads` (multipart field `file`) → collect `uploadId`s → POST the `ClientPayload` JSON to `<endpoint>` → show `sent` with the returned `feedbackId`. A 429 shows `errorRateLimited`. A failed send keeps the form filled in.
- Screenshot: `captureScreenshot(): Promise<Blob | null>` using `modern-screenshot`'s `domToBlob(document.documentElement)`; the dialog is hidden while capturing; on any error it returns `null` and the button shows nothing worse than a disabled option.
- Accessibility: dialog has `role="dialog"`, `aria-modal`, labelled fields, Escape closes, focus returns to the button.
- Styling: inline styles reading CSS variables with fallbacks (`var(--feedback-accent, #1f6feb)` etc.) so each app can theme it; no CSS file to import.

- [ ] **Step 1:** Write `src/payload.spec.ts`: `buildPayload` copies form fields, takes `consoleErrors`/`failedRequests` from the capture snapshot, strips the query string from `href` into `context.url`, includes `uploadIds` as `attachments`; `checkFile` returns `errorFileTooLarge` for a 10 MB + 1 image and a 50 MB + 1 video, `errorFileType` for `application/pdf`, `null` for a 1 MB `image/png`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement `payload.ts`, `screenshot.ts`, `FeedbackButton.tsx`, and export everything public from `index.ts`.
- [ ] **Step 4:** Run tests → PASS; `npm run typecheck -w packages/feedback && npm run lint`.
- [ ] **Step 5:** Try it by hand in `apps/spike-vite` with a stub endpoint: open, fill, attach a PNG, take a screenshot, send; then cause a `console.error` and a failing `fetch` and confirm both are in the posted JSON.
- [ ] **Step 6:** Commit: `Add the feedback button`.

### Task 15: The server helper, and publishing

**Files:** `src/server/index.ts`, `src/server/token.ts`; test `src/server/routes.spec.ts`.

**Interfaces:**
- Produces:
  ```ts
  createFeedbackRoutes(config: {
    app: string
    env: 'dev' | 'prod'
    intakeUrl: string            // e.g. https://feedback.dev.quarantine.al
    tokenUrl: string             // <issuer>/oauth/v2/token
    clientId: string
    clientSecret: string
    scope: string                // the exact string recorded in Task 6 Step 5
    getUser(request: Request): Promise<null | { id: string; name: string; email: string; role?: string }>
    fetch?: typeof fetch         // for tests
  }): { submit(request: Request): Promise<Response>; upload(request: Request): Promise<Response> }
  ```
- `submit`: `getUser` null → `401`. Parse the browser JSON as `ClientPayload`; **discard** any `user`, `app` or `env` keys it contains; add `user`, `app`, `env` from config/`getUser`; POST to `<intakeUrl>/v1/feedback` with the bearer token; relay intake's status and JSON body (`201`, `400`, `429`); intake `401/403/5xx` or network failure → `502 { "error": "unavailable" }`.
- `upload`: same auth; forward the multipart `file` plus `app` and `userId` fields to `<intakeUrl>/v1/uploads`; relay the result.
- `token.ts`: `getMachineToken(config): Promise<string>` — client-credentials grant, cached in memory until 60 seconds before expiry; one in-flight request at a time.

- [ ] **Step 1:** Write `src/server/routes.spec.ts` with a fake `fetch`: unauthenticated → 401 and no outbound call; a browser body containing `"user": {"id": "attacker"}` and `"app": "bem"` reaches intake with the real user and `app: 'kujtime'`; intake 429 is relayed as 429; intake 500 → 502; two submits in a row request the token once; an expired token is fetched again.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement both files.
- [ ] **Step 4:** Run tests → PASS; build; confirm `dist/**/server/*` has no `"use client"`.
- [ ] **Step 5:** Open the PR, merge, then run the "Publish" workflow with `package: feedback`. Verify: `npm view @quarantineal/feedback version --registry https://npm.pkg.github.com` → `0.1.0`.
- [ ] **Step 6:** Commit: `Add the server helper that forwards feedback to the intake`.

---

## Part D — Kujtime uses it

### Task 16: Kujtime wiring, end to end on dev

**Files (repo `kujtime`):**
- Create: `apps/web/lib/feedback.ts`, `apps/web/app/api/feedback/route.ts`, `apps/web/app/api/feedback/uploads/route.ts`, `apps/web/components/feedback-mount.tsx`
- Modify: `apps/web/package.json` (dependency), `apps/web/app/[locale]/city/[city]/layout.tsx`, `apps/web/messages/sq.json`, `apps/web/messages/en.json`, `Dockerfile` and `.github/workflows/deploy-develop.yml` (pass a registry token to `npm ci` as a BuildKit secret), `.github/workflows/ci.yml`
- Test: `apps/web/lib/feedback.spec.ts` (add a `test` script to `apps/web`)

**Files (repo `platform`):** `catalog.yaml` (kujtime: `machine_account: kujtime-feedback`), `apps/first-party/kujtime/compose.yaml` (env below).

**Interfaces:**
- Consumes: `@quarantineal/feedback` 0.1.0 (Tasks 13–15), `getActor()` and the `user` table, Task 3's `MACHINE_CLIENT_ID_KUJTIME` / `MACHINE_CLIENT_SECRET_KUJTIME`.
- New kujtime env: `FEEDBACK_INTAKE_URL=https://feedback.${DOMAIN}`, `FEEDBACK_CLIENT_ID=${MACHINE_CLIENT_ID_KUJTIME}`, `FEEDBACK_CLIENT_SECRET=${MACHINE_CLIENT_SECRET_KUJTIME}`, `FEEDBACK_ENV=dev`. If `FEEDBACK_INTAKE_URL` is unset the routes return 404 and the button is not rendered (so local development works without the intake).
- Produces `apps/web/lib/feedback.ts`: `feedbackUser(actor: Actor, row: { zitadelSub: string; displayName: string | null; email: string }): { id: string; name: string; email: string; role?: string }` — `id` is the **Zitadel sub** (so "My reports" matches the same person), `name` falls back to the part of the email before `@`, `role` is `'admin'` if `isPlatformAdmin`, `'editor'` if `editorCityIds.length > 0`, otherwise undefined.
- Button placement: in the city layout, rendered only when `getActor().userId` is set, with `tenant` = the city slug, `locale` = the current locale, `appVersion` = `process.env.NEXT_PUBLIC_APP_VERSION`, labels from a new `feedback` namespace in `messages/{sq,en}.json`.

- [ ] **Step 1:** Platform: `quarantine machine onboard kujtime-feedback --grant feedback feedback-submit` on dev; add `machine_account` and the env lines; PR, merge, `quarantine start`; commit dev's secrets by PR as usual.
- [ ] **Step 2:** Write `apps/web/lib/feedback.spec.ts`: admin → role `admin`; editor of one city → `editor`; plain member → no role; null `displayName` with `a.k@example.com` → name `a.k`; `id` equals `zitadelSub`, never the internal user id.
- [ ] **Step 3:** Run `npm test`. Expected: FAIL.
- [ ] **Step 4:** Add the dependency; implement `lib/feedback.ts`; the two route files (`export const POST = routes.submit` / `routes.upload`, with `getUser` = `getActor()` + one query of the `user` row); `feedback-mount.tsx` (a client component that calls `installCapture()` once and renders `<FeedbackButton/>`); mount it in the city layout; add the `feedback` strings in Albanian and English.
- [ ] **Step 5:** Make the Docker build able to install the private package: `RUN --mount=type=secret,id=npm_token NODE_AUTH_TOKEN=$(cat /run/secrets/npm_token) npm ci`, and pass `secrets: npm_token=${{ secrets.GITHUB_TOKEN }}` in `deploy-develop.yml` (job permission `packages: read` is already covered by `write`). In the `@quarantineal/feedback` package settings on GitHub, grant the `kujtime` repo read access (the user does this; say so).
- [ ] **Step 6:** `npm test` → PASS; `npm run build --workspace apps/web` → succeeds; CI green on the PR.
- [ ] **Step 7:** Merge to `develop`, wait for the dev deploy, then test for real on a dev city site, signed in:
  1. Send a bug with a title, a description containing `--> @someone #1`, one PNG and one short MP4, and a page screenshot.
  2. Expected within about a minute: a new issue in `QuarantineAl/kujtime` titled `[FB-d0001] …`, opened by `quarantine-feedback[bot]`, labels `source:feedback`, `status:new`, `type:bug`; the PNG and the screenshot show inline; the video is a working link; no email anywhere in the issue; nobody was mentioned.
  3. `https://feedback.dev.quarantine.al/my` lists the report as "Received".
  4. Add the label `status:planned` to the issue and remove `status:new` → "My reports" shows "Being worked on".
  5. Send six reports quickly → the sixth shows the rate-limit message.
  6. Signed out: no button; `curl -X POST https://<city>-kujtime.dev.quarantine.al/api/feedback` → 401.
- [ ] **Step 8:** Commit: `Add the feedback button to kujtime`.
- [ ] **Step 9:** Close the test issues it created, and tell the user what was verified and what was not.

---

## Order and dependencies

```
Task 1 ─────────────────────────────────────────────┐
Task 2 (user) ──┐                                   │
Task 3 ─────────┼─► Task 12 ─► Task 6 step 5 ─┐     │
Task 4 ─────────┘      ▲                      ├─► Task 16
Tasks 5 → 6 → 7 → 8 → 9 → 10 → 11 ────────────┘     │
Tasks 13 → 14 → 15 ─────────────────────────────────┘
```

Parts B and C do not depend on each other and can be built in parallel. Tasks 2 and 4 need the user.

## Things only the user can do

- Create and install the two GitHub Apps and enter their secrets (Task 2, Task 12 Step 4).
- Decide how the Garage branch lands (Task 4 Step 1).
- Approve creating the private repo `QuarantineAl/feedback` (Task 5 Step 1).
- Grant the `kujtime` repo access to the `@quarantineal/feedback` package (Task 16 Step 5).
