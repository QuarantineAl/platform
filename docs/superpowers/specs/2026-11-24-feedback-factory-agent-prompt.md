# Prompt: brainstorm and plan the feedback factory

Copy everything below the line into a fresh agent session (Claude Code or Lazzaretto, working
directory `~/Workspaces/qualitech/quarantine`).

---

You are helping design and plan a **feedback factory** for the QuarantineAl platform: a reusable
flow where signed-in users of an app send feedback, it becomes GitHub issues, and agents
running in Lazzaretto triage and build changes on a schedule. Green pull requests merge to `develop`
and deploy to dev; a person tests there and ships to prod by hand.

## Read first

1. `platform/docs/superpowers/specs/2026-11-24-feedback-factory-design.md` — the agreed design.
   Treat its decisions (sections 4, 6, 7, 9) as settled: do not reopen them unless you find a
   concrete reason they cannot work, and then say exactly why. Section 10 lists calls the
   previous agent made on its own; challenge those freely if the code says otherwise.
2. `platform/README.md`, `platform/catalog.yaml`, `platform/docs/adding-an-app.md`,
   `platform/docs/runners-and-sandboxing.md` — how apps are added and deployed.
3. `dot-github/.github/workflows/` — the shared deploy and PR-sandbox workflows.
4. `lazaretto/docs/ARCHITECTURE.md`, `lazaretto/docs/headless-api.md`,
   `lazaretto/backend/src/scheduler/` — the agent brain: scheduled tasks and headless tasks.
5. `kujtime/README.md` and `kujtime/.github/workflows/` — the pilot app.
6. `toolkit/README.md` — where the feedback button package will live.

Comments in these repos are sometimes stale. Check claims against the code before relying on them.

## What I want from you

1. **Verify feasibility** against the real code: for each row of the design's "What changes, and where"
   table (section 8), say what already exists, what's missing, and anything the design got wrong.
2. **Ask me questions** one at a time, only where the answer changes what gets built.
   Propose an answer with your reason when you can.
3. **Produce an implementation plan** for build-order steps 1 and 2 only (foundations: kujtime
   CI, the two GitHub Apps, the Garage `storage` service on dev; feedback in: intake service,
   `@quarantineal/feedback`, button and route in kujtime, "My reports"). The pilot runs on dev
   only; don't plan kujtime prod, "Ship to prod" or the deploy gate yet. Small steps, each one
   testable, each one naming the repo and files it touches.

## Principles

- Start simple and clean; evolve gradually. If something can wait for a later step, it waits.
- GitHub is the only record of workflow state. Don't add a second one.
- Reusable from day one: nothing kujtime-specific in the intake service, Lazzaretto tasks or
  shared workflows. Turning on a new app must need no code changes there.
- Own apps first, other businesses later: record an owner on every app, but build no customer
  features yet.
- Safety rules in section 9 of the design are not negotiable.

## Out of scope

Genesis (creating new apps from a requirements doc), customer portals or billing, smart
triage, anonymous feedback.
