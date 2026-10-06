---
status: draft
stepsCompleted: [1]
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-life-ledger-2026-10-05/prd.md
  - _bmad-output/planning-artifacts/prds/prd-life-ledger-2026-10-05/addendum.md
  - _bmad-output/planning-artifacts/architecture/architecture-life-ledger-2026-10-05/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/architecture/architecture-life-ledger-2026-10-05/data-model.md
  - _bmad-output/planning-artifacts/architecture/architecture-life-ledger-2026-10-05/rls-matrix.md
  - _bmad-output/planning-artifacts/architecture/architecture-life-ledger-2026-10-05/rpc-contracts.md
  - _bmad-output/planning-artifacts/architecture/architecture-life-ledger-2026-10-05/offline-queue.md
  - _bmad-output/planning-artifacts/architecture/architecture-life-ledger-2026-10-05/test-plan.md
  - docs/feature-doc-v2.md
  - docs/bmad-prompt.md
---

# Family Life Ledger - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for Family Life Ledger, decomposing the requirements from the PRD and the Architecture into implementable stories. No UX design contract exists yet (`bmad-ux` was not run); screen-level detail is left to the stories and to a later UX pass. Scope is v1 only (M1–M3). People are referred to by role only.

## Requirements Inventory

### Functional Requirements

**M1 — Capture core**
- FR-1 (F1): A login can sign in with email and password and reset a forgotten password by email; signed-out visitors get only a sign-in screen; exactly three logins, no self-service sign-up; sessions last 30 days per device.
- FR-2 (F1): Roles parent_admin (Parent A, Parent B) and student_owner (the student); the student never receives a parents_only row (automated RLS test); parents can create/edit/archive on the younger child's profile, the student only reads her family entries.
- FR-3 (§3): A parent can send the student a password-reset email and sign out all his sessions; the student cannot do either for a parent.
- FR-4 (§3, F7): Four visibility levels (private, family, parents_only, shareable) enforced at the data layer.
- FR-5 (§3): Default visibility per type and author, never overridable by processing; parent notes always parents_only; score/academic never shareable; an entry is never more visible than its post.
- FR-6 (§3): The action matrix for create, read, edit facts, edit student-authored text, confirm, change visibility, archive; reflections/quotes with speaker = the student stay unconfirmed until he confirms the exact text; unconfirmed reflections are never quoted.
- FR-7 (§3, F7): Output items citing an entry the viewer can no longer see are hidden ("1 item hidden") in every saved version.
- FR-8 (F3): Quick post — text, up to 4 photos, links, person picker defaulting to the last person used, a visibility; one tap to submit; appears as "waiting to be processed".
- FR-9 (F3): Offline posting — saved locally and sent automatically when back online; shows "not sent yet"; never sent twice.
- FR-10 (F3): Time from opening the post screen to submit is logged per post.
- FR-11 (§4): Common fields on every entry, with a source span for every extracted field.
- FR-12 (§4): Entry types and required fields; each missing required field has exactly one open gap; activity_type from the stored Common App list.
- FR-13 (§4): Common App field mapping with limits.
- FR-14 (§4): Per-child school calendar (grade_9_start, graduation_year); school year Aug 1–Jul 31; grade_levels derived from dates and editable.
- FR-15 (F4): Processing queue excludes the younger child and private posts; posts leave only when processed or "needs manual entry"; a missed run loses nothing.
- FR-16 (F4): `ingest_draft` forces draft status and default visibility, rejects fields without a source span, marks the post processed; gap per missing field in plain language; both children → separate entries; unclear person → "Who is this about?"; prompt-injection test; content is data; retry once then "needs manual entry".
- FR-17 (F4): Younger child's milestones via a short manual form (title, date, photo); never processed.
- FR-18 (F4): Possible duplicates with Keep both / Merge / Discard; merge rules.
- FR-19 (F4): Processing guide (Claude skill) limits writes to the two functions; versioned in the repo with no personal data.
- FR-20 (F5): Status flow draft → needs_detail → confirmed; confirm disabled while required gaps open unless not applicable; editing a confirmed entry's required field reopens if a gap reopens; disabled Confirm names the blocking gap.
- FR-21 (§3): Last write wins; every change in entry_versions; "edited by X" with history one tap away.
- FR-22 (F5): Archive (restorable 30 days) and purge (cascade, redaction in all output versions); a post with confirmed entries cannot be deleted.
- FR-23 (F6): Needs-detail queue of open gaps on entries the login can edit, newest first, answerable inline; gap states open/answered/not_applicable.
- FR-24 (F6b): Badge counts open gaps, reflections waiting for the student, possible duplicates.
- FR-25 (F6b): Optional weekly email digest, Sunday 6 pm Eastern, counts and a link only, off by default.
- FR-26 (F8): Timeline newest first with entries and statuses, filters by person and type, first 20 items < 2 s on 4G, only readable items.

**M2 — Backfill and structure**
- FR-27 (F2): Brain-dump editor up to 8,000 characters with live counter; submit blocked above limit with split prompt.
- FR-28 (F2): Review list with bulk confirm, enabled only for drafts with no open required gaps; never confirms student-speaker reflections for a parent.
- FR-29 (F8b): Profile view: confirmed entries grouped by type with counts and an "incomplete" badge.
- FR-30 (F10): Private files — images/PDF ≤ 10 MB, audio ≤ 25 MB, signed links valid 10 minutes, readable only via readable posts/entries; deleting a service form removes verified state.
- FR-31 (F11): Service hours tracker — total, verified, progress to 75 and 100; only hours from start of 9th grade; only confirmed entries.
- FR-32 (F11): Verification needs a form file and a parent attestation; the student cannot attest; attestation is versioned.
- FR-33 (F11): Disclaimer copy shown once; the app does not judge eligibility.

**M3 — Outputs**
- FR-34: `save_output` stores versioned outputs from confirmed entries only; every item cites at least one entry.
- FR-35: In-app output requests by Parent B and the student (and owner), queued for the next run; the student cannot request recommender pointers.
- FR-36: Outputs editable in-app; the generated vs final difference is stored; edits create a new version.
- FR-37: Every view of a parents_only output is access-logged.
- FR-38 (F9a): Activities draft — candidates, top 10 with reasons, pin/drop/reorder, 50/100/150 counters, flag not cut; visible to parents and the student.
- FR-39 (F9b): Honors draft — ordered by level then recency, top 5, same controls.
- FR-40 (F9c): Recommender pointers under the 12 Family Brag Sheet questions, citing entries; parents_only; copy per section.
- FR-41 (F9d): Essay angles — 3–5 themes with entries and exact confirmed student quotes; no parent notes; no essay prose.

**Cross-milestone**
- FR-42: One-tap export of everything the requesting login can read about one person (JSON + files in one archive); the student can export his own non-parents_only data.
- FR-43: Weekly encrypted full backup to the owner's private Google Drive folder; key in the password manager; quarterly restore test.

### NonFunctional Requirements

- NFR-SEC-1: RLS on every table; automated tests prove student_owner never reads parents_only rows, the action matrix holds cell by cell, and parents can never edit or confirm student-speaker reflections; tests block merge.
- NFR-SEC-2: No AI keys anywhere; the app holds only the publishable database key.
- NFR-PERF-1: Timeline first 20 items < 2 s on a mid-range phone on 4G.
- NFR-PERF-2: Median ≤ 20 s screen-open to submit for a quick post.
- NFR-REL-1: No post is ever lost (offline persistence, missed runs, failed ingests keep raw text).
- NFR-A11Y-1: WCAG AA contrast, 44 px tap targets, VoiceOver works for posting and confirming.
- NFR-PLAT-1: Mobile-first web app installable to the home screen; no native app.
- NFR-AUD-1: entry_versions for all edits; access log for parents_only outputs.
- NFR-OBS-1: Metrics only from the app's own events and data tables; no third-party analytics or scripts.
- NFR-PRIV-1 (§6.1): Younger child's data never sent to the model; private storage; confirm model provider data-retention terms before launch; no real names, seed data, keys or exports in the public repo.
- NFR-COST-1 (§6.3): $0 extra — free database plan, owner's Claude subscription.
- NFR-SAFE-1 (§6.2): Nothing extracted counts until a human confirms; zero confirmed fields without a source span or user answer (SM-5).

### Additional Requirements

From the architecture spine (AD-n) and companions. **No starter template**: greenfield, no-build static app following psat-sprint conventions (AD-15) — Epic 1 Story 1 is the project skeleton plus the database foundation.

- **Foundation (AD-2, AD-15, AD-18):** repo layout `web/`, `supabase/migrations`, `supabase/tests`, `processing/`, `test/`; vendored supabase-js 2.117.2 and fflate 0.8.3; Pages deploy workflow from `web/`; CI on the local Supabase stack (Supabase CLI 2.119.0, pgTAP, Node 24, Playwright 1.63.0).
- **Database security baseline (AD-2, AD-4):** schemas `ll` / `ll_proc` / `ll_ops`; default privilege revokes; explicit grants; `search_path = ''`; SELECT-only RLS; invoker views; `pg_graphql` off; no Realtime on these schemas; catalog pgTAP tests for function ACLs and view options.
- **Identity & sessions (AD-8):** `members`, `persons`, role helpers, `require_member()` with JWT `session_id` → `auth.sessions` (30-day limit, revocation); Auth settings runbook (sign-ups off, custom SMTP, redirect URLs); private bootstrap script.
- **Predicates (AD-4):** `can_read`, `entry_visible`, `post_visible`, `can_act`; `entries.author_id`; visibility order and narrowing cascade.
- **Evidence engine (AD-5, AD-6, AD-7):** registry + enum_values seed; `sync_gaps` BEFORE trigger; provenance trigger; one version per RPC; `post_events`.
- **Processor (AD-3, AD-9):** `ll_processor` role; `ll_proc` views split by run class; `ingest_draft` / `save_output` with pg_jsonschema; dollar-quoting; two scheduled Claude tasks (family run, parents run); processing guide; golden-post test.
- **Files (AD-17):** bucket limits, INSERT-only storage policy via `upload_allowed`, `entry_attachments`, client-side signed URLs, `detach_file`, tombstones.
- **Outputs (AD-11):** `get_output` only read path, shared `validate_output_items`, access log.
- **Offline queue (AD-12):** IndexedDB queue, client ids, `upsert:false`, `id-conflict`, per-login display, `navigator.storage.persist()`, shell-caching service worker.
- **Operations (AD-14, AD-18):** private `life-ledger-ops` repo — keepalive/health, digest, encrypted backup (`pg_dump` via pooler + storage sync + age 1.3.2), tombstone deletion, manual migration deploy; `pg_cron` purge, accuracy check, status sweep, `cron.job_run_details` prune; quarterly restore runbook.
- **Telemetry (AD-16):** `log_event` client allow-list; `post_duration` written by `create_post`; metric views in `ll_ops`, owner-only `metrics()`.
- **Owner decisions:** post screen reminder when the younger child is named in a student post; exports limited to what the requester can read.

### UX Design Requirements

None — no UX design contract exists. Stories carry the PRD's UI-level acceptance criteria (one-tap post, counters, badges, "1 item hidden", copy buttons) and NFR-A11Y-1.

### FR Coverage Map

{{requirements_coverage_map}}

## Epic List

{{epics_list}}
