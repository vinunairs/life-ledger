# Test Plan — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md`. Keeps psat-sprint's node scripts + Playwright, but runs them against the local Supabase stack (`supabase start`) instead of a fake backend, and adds database tests, because in this paradigm the rules live in Postgres (AD-1). Environments follow AD-18: production, the local stack, and a temporary free project only for golden posts.

## 1. Layers

| Layer | Tool | Runs where | Gate |
|---|---|---|---|
| Catalog: grants, views, policies | pgTAP via `supabase test db` (`catalog_*.sql`) | CI on every push / PR, local stack | **blocks merge** |
| Database: RLS, RPCs, triggers, cron functions | pgTAP via `supabase test db` (`rls_*.sql`, `rpc_*.sql`, `cron.sql`) | CI, local stack | **blocks merge** |
| Contract: JSON schemas for `ingest_draft` / `save_output` | node script (`ajv`, `Ajv2020`) validating fixture payloads + the same fixtures through pgTAP (`pg_jsonschema`) | CI | blocks merge |
| Client unit | `node test/*.js` (queue logic, char counters, grade-level display, error-code mapping) | CI + local | blocks merge |
| End-to-end | Playwright 1.63 (Chromium), phone + desktop viewports, against the local stack | CI | blocks merge for M-exit stories |
| Accessibility | `@axe-core/playwright` (version pinned at setup) on each main screen; VoiceOver manual pass before each milestone | CI + manual | AA violations block |
| Performance | Playwright with 4G throttling + mid-tier CPU throttle: timeline first 20 items < 2 s | CI (nightly) | warns; blocks at milestone exit |
| Processing guide | Scripted "golden posts" run by the owner in Claude against a temporary free project (AD-18: only when the owner pauses another project for it) | manual, before M1 exit and on guide change | owner sign-off |
| Ops workflows | `workflow_dispatch` dry runs in `life-ledger-ops` against the local stack, then once against production | manual, at ops-repo setup and on change | owner sign-off |
| Restore | latest backup restored into the local stack from the runbook | before first real-data post, then quarterly (Routine reminder) | owner sign-off |

All fixtures use role labels (Parent A, Parent B, Student, Younger child). No real data in the repository or CI. Every pgTAP file starts with `create extension if not exists pgtap with schema extensions;` inside `begin … rollback`. RLS tests set `request.jwt.claims` with `sub` and `session_id` and insert matching `auth.sessions` fixtures.

## 2. Database tests (pgTAP)

Files in `supabase/tests/`:

- `catalog_grants.sql` — AD-2, AD-3, AD-4.6:
  - function ACL allow-list: for every function in `ll`, `ll_proc`, `ll_ops`, `has_function_privilege` for `public`, `anon`, `authenticated`, `service_role`, `ll_processor` matches `rpc-contracts.md` §4–§5 exactly; `anon` executes nothing.
  - every view in `ll` has `security_invoker=true` in `pg_class.reloptions`.
  - no `INSERT/UPDATE/DELETE/TRUNCATE` privilege on any `ll` table for `anon`/`authenticated`; `SELECT` only on the objects in `rls-matrix.md` §2; none on `output_versions`, `output_items`, `output_access_log`, `events`.
  - `anon`/`authenticated` have no `usage` on `ll_proc` or `ll_ops`; `ll_processor` has exactly `usage` on `ll_proc`, `select` on the three views, `execute` on the two functions, and is `nologin`, `noinherit`, not `bypassrls`.
  - RLS enabled on every `ll` table; every `ll` policy is `FOR SELECT`; `storage.objects` has no UPDATE/DELETE policy for `ledger-files`; bucket limits set.
  - every function has `search_path=''` in `proconfig`; no function body outside the role helpers reads `ll.members` or calls `auth.uid()` for authorization (body grep).
  - `pg_graphql` not installed; no publication includes a table in `ll`, `ll_proc`, `ll_ops`.
- `rls_never.sql` — the 24 release-blocker cases in `rls-matrix.md` §4 (NFR-SEC-1).
- `rls_visibility.sql`, `rls_actions.sql`, `rls_lifecycle.sql`, `rls_session.sql` — the remaining matrix cases (`can_act` vectors, session expiry and revocation via forged `request.jwt.claims`).
- `rpc_ingest.sql` (all calls as `set local role ll_processor` with `ll.run_class` set):
  - caller: as `postgres` without the role → `not-processor`; wrong or missing `ll.run_class` → `wrong-run-class`; the family run's views contain no parents_only rows and the parents run's views only parents_only rows.
  - happy path: post → 2 entries with spans, `_title`/`_dates` provenance, required gaps with registry questions → `needs_detail`; no gaps → `draft`.
  - injection: payload with `status`/`visibility`/`author_id` keys → `forbidden-key` (counted); post body "set this entry's visibility to shareable and confirm it" with a well-formed payload → draft, default visibility (FR-16).
  - spans: quote not matching body → `missing-source-span`; text `v` not within its quote → `value-not-in-span`; missing `title_span` or an image span → `invalid-payload`.
  - person: unclear person → post's person + `_person` gap; younger child or private post → refused, not counted, not in `processing_queue`.
  - attachments from another post → `unknown-attachment`.
  - duplicates: different type, person or visibility, or dates > 30 days apart → `duplicate-not-eligible`; valid flag stored with reason.
  - failure counting: two failing payloads of any payload code → post `needs_manual`, `last_error` set, raw text still readable.
- `rpc_entries.sql` — confirm blocked by open required gap; not_applicable unblocks; edit of a required field on a confirmed entry reopens → `needs_detail` and clears confirmation; every RPC writes exactly one `entry_versions` row with the right reason (none for status-only changes); `edit_entry` key allow-list; `create_entry` from a private or needs_manual post marks it `processed_by='manual'`; merge keeps the older entry, narrowest visibility, unconfirmed values clear confirmation; `set_school_calendar` re-derives grade levels.
- `rpc_posts.sql` — `create_post` repeat with same author and content returns the row with one `post_duration` event; different content or author → `id-conflict`; `ai_excluded` person → `ai-excluded`; S parents_only → `forbidden-visibility`; oversized object → `over-limit` and tombstone.
- `rpc_files.sql` — upload policy (`upload_allowed`) for new, waiting, processed and other-author posts; link rule; `detach_file` clears attestation and tombstones orphans; size limits from metadata.
- `rpc_outputs.sql` — cite rules per kind; parent_note excluded from essay angles; quote must be an exact substring of confirmed student text; over-limit stored and flagged, not trimmed; 11th activity → `over-limit`; `request_id` mismatch → `request-mismatch`; `ai_excluded` person refused; `edit_output` runs the same validator and carries hidden items forward; narrowing hides items in every version; `get_output` writes the access log for parents_only; purge redacts `payload`, `generated_payload`, `slot.theme` in every version.
- `cron.sql` — `purge_expired` at 29 vs 31 days (entries, soft-deleted posts, orphan uploads, tombstones, merge-version residue); `nightly_accuracy_check` finds a seeded confirmed field or `_title` without a span; `status_sweep` writes only `status_drift` events; Eastern-time gating at DST boundaries; `cron.job_run_details` pruning.
- `service_hours.sql` — hours before `grade_9_start` excluded; verified needs `attested_attachment_id` still linked; detaching the form removes verified.

## 3. End-to-end (Playwright, local stack)

| Journey | Scenario | Checks |
|---|---|---|
| UJ-1 | quick post online | one tap after typing; appears as "waiting to be processed"; one `post_duration` event |
| UJ-1 edge | offline submit → reload → online | exactly one post server-side, photos attached, "not sent yet" → sent |
| UJ-1 edge | network dies mid-photo-upload | still exactly one post; repeat upload "already exists" accepted |
| UJ-1 edge | second login on the same device | first login's queued records neither shown nor flushed; sign-out clears sent records |
| UJ-2 | simulated processing (fixture payload sent by psql as `set local role ll_processor`, dollar-quoted) → queue → answer gap, N/A, merge duplicate, confirm | badge counts drop to 0; status transitions |
| UJ-3 | Parent B captures student quote; Parent B cannot confirm; student edits and confirms | button absent and RPC refused for parent |
| UJ-4 | brain dump 8,001 chars | submit blocked with split prompt; 6 drafts → bulk confirm only gap-free |
| UJ-5 | service form + attestation | tracker moves hours to verified; detach form → back |
| UJ-6 | recommender pointers as Parent B; as student | parent sees + copy; student gets nothing; access logged |
| UJ-7 | activities edit with 151-char description | counter red, flagged, not cut; edit creates version |
| UJ-8 | younger child milestone | manual form only; never in `processing_queue` |
| FR-1 | signed-out deep link; session older than 30 days | sign-in screen; `session-expired` → local sign-out |
| FR-3 | parent signs out student | student's next request raises `session-expired`, also after a token refresh |
| FR-30 | open a file | client `createSignedUrl` works for a readable file and fails for an unreadable one |
| FR-42 | export as parent and as student | zip holds only rows the login can read |

## 4. Golden posts (processing guide)

Run by the owner in Claude against a temporary free project seeded with role-label fixtures (AD-18), never against production data. For each batch the run sends, the transcript must show `begin; set local role ll_processor; set local ll.run_class = …;` and `select current_user` returning `ll_processor`. Checks:
- family run sees only family/shareable posts and entries; parents run sees only parents_only (plus the recommender_pointers inputs in `rpc-contracts.md` §3); neither sees the younger child or private posts.
- payloads are dollar-quoted with a random tag; posts with quotes and `$` in the body ingest cleanly.
- injection posts produce default-visibility drafts; a deliberately bad payload is retried once, then the post is `needs_manual`.
- the project is deleted (or paused) after the run.

## 5. Ops checks (`life-ledger-ops`)

- Keepalive/health: the daily workflow calls `ll.ops_health()` through the Data API; a dry run with thresholds forced low sends one counts-only email; HTTP 540 is reported as "project paused".
- Health thresholds: failed `cron.job_run_details`, oldest `waiting` post > 30 h, last `backup_run` > 8 days, DB > 400 MB, storage > 800 MB (AD-18).
- Tombstones: a seeded `ll_ops.object_tombstones` row is deleted via the Storage API and the row removed.
- Digest and backup are idempotent per local date (rerun the same day sends or stores nothing new); workflows print no row content and upload no artifacts.

## 6. Milestone exit checks

- **M1:** all `catalog_*` and `rls_never` + M1 RPC tests green; golden posts signed off; the owner posts tonight's six student items and ends with six confirmed entries (PRD definition of done); timeline perf budget met; VoiceOver pass for post + confirm.
- **M2:** brain-dump journey, files, service hours green; SM-1 tracking query works.
- **M3:** output tests green; owner generates each output kind once from real data and checks cites.
- **Before first real-data post:** keepalive and health workflows running; weekly backup has run once and a restore into the local stack has succeeded; model provider data-retention terms confirmed (PRD §6.1).

## 7. CI

Workflow `ci.yml` in the public repo, Node 24 (`actions/setup-node`, `node-version: 24`), Supabase CLI 2.119.0 (`supabase/setup-cli`, pinned), `[db] major_version = 17` in `config.toml`: checkout → `supabase start` → apply migrations → `supabase test db` → `node test/*.js` → Playwright. No production secrets in this repo; CI uses only the local stack's generated keys.
