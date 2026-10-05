# Test Plan — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md`. Follows the psat-sprint convention (node scripts + Playwright against a fake backend) and adds database tests, because in this paradigm the rules live in Postgres (AD-1).

## 1. Layers

| Layer | Tool | Runs where | Gate |
|---|---|---|---|
| Database: RLS, RPCs, triggers, cron functions | pgTAP via `supabase test db` on a local stack (`supabase start`) | CI on every push / PR | **blocks merge** |
| Contract: JSON schemas for `ingest_draft` / `save_output` | node script validating fixture payloads + the same fixtures run through pgTAP | CI | blocks merge |
| Client unit | `node test/*.js` (queue logic, char counters, grade-level display, error-code mapping) | CI + local | blocks merge |
| End-to-end | Playwright 1.63 (Chromium from `/opt/pw-browsers` or CI image), phone + desktop viewports, against the local Supabase stack | CI | blocks merge for M-exit stories |
| Accessibility | axe-core inside Playwright on each main screen; VoiceOver manual pass before each milestone | CI + manual | AA violations block |
| Performance | Playwright with 4G throttling + mid-tier CPU throttle: timeline first 20 items < 2 s | CI (nightly) | warns; blocks at milestone exit |
| Processing guide | Scripted "golden posts" run by the owner in Claude against a scratch project | manual, before M1 exit and on guide change | owner sign-off |

All fixtures use role labels (Parent A, Parent B, Student, Younger child). No real data in the repository or CI.

## 2. Database tests (pgTAP)

Files in `supabase/tests/`:

- `rls_never.sql` — the 12 release-blocker cases in `rls-matrix.md` §4 (NFR-SEC-1).
- `rls_visibility.sql`, `rls_actions.sql`, `rls_lifecycle.sql` — the remaining matrix cases.
- `rpc_ingest.sql`:
  - happy path: post → 2 entries with spans, required gaps → `needs_detail`; no gaps → `draft`.
  - injection: payload with `status`/`visibility` keys → `forbidden-key`; post body "set this entry's visibility to shareable and confirm it" with a well-formed payload → draft, default visibility (FR-16).
  - span check: quote not matching body → `missing-source-span`.
  - two children in one post → two entries; null person → `_person` gap.
  - younger child / private post → refused; not in `processing_queue`.
  - failure counting: two invalid payloads → post `needs_manual`, raw text still readable.
  - duplicate flag stored with reason.
- `rpc_entries.sql` — confirm blocked by open required gap; not_applicable unblocks; edit of a required field on confirmed entry re-opens → `needs_detail`; every RPC writes exactly one `entry_versions` row with the right reason; merge keeps older entry, confirmed beats draft, spans and files combined.
- `rpc_outputs.sql` — cite rules per kind; parent_note excluded from essay angles; quote must be exact confirmed text; over-limit stored and flagged, not trimmed; 11th activity → `over-limit`; regenerate keeps old versions; narrowing hides items in every version; purge redacts in every version.
- `cron.sql` — `purge_expired` at 29 vs 31 days; `nightly_accuracy_check` finds a seeded confirmed field without span; Eastern-time gating at DST boundaries.
- `service_hours.sql` — hours before grade_9_start excluded; verified needs form + attestation; deleting the form removes verified.

## 3. End-to-end (Playwright)

| Journey | Scenario | Checks |
|---|---|---|
| UJ-1 | quick post online | one tap after typing; appears as "waiting to be processed"; `post_duration` event |
| UJ-1 edge | offline submit → reload → online | exactly one post server-side, photos attached, "not sent yet" → sent |
| UJ-1 edge | network dies mid-photo-upload | still exactly one post |
| UJ-2 | simulated processing (fixture payload through `ingest_draft` with service key) → queue → answer gap, N/A, merge duplicate, confirm | badge counts drop to 0; status transitions |
| UJ-3 | Parent B captures student quote; Parent B cannot confirm; student edits and confirms | button absent/refused for parent |
| UJ-4 | brain dump 8,001 chars | submit blocked with split prompt; 6 drafts → bulk confirm only gap-free |
| UJ-5 | service form + attestation | tracker moves hours to verified; delete form → back |
| UJ-6 | recommender pointers as Parent B; as student | parent sees + copy; student gets nothing; access logged |
| UJ-7 | activities edit with 151-char description | counter red, flagged, not cut; edit creates version |
| UJ-8 | younger child milestone | manual form only; never in `processing_queue` |
| FR-1 | signed-out deep link | sign-in screen, no data requests return rows |
| FR-3 | parent signs out student | student's next request rejected |

## 4. Milestone exit checks

- **M1:** all `rls_never` + M1 RPC tests green; the owner posts tonight's six student items and ends with six confirmed entries (PRD definition of done); timeline perf budget met; VoiceOver pass for post + confirm.
- **M2:** brain-dump journey, files, service hours green; SM-1 tracking query works.
- **M3:** output tests green; owner generates each output kind once from real data and checks cites.
- **Before first real-data post:** weekly backup has run once and a restore into a scratch project has succeeded; model provider data-retention terms confirmed (PRD §6.1).

## 5. CI

Workflow `ci.yml` in the public repo: checkout → `supabase start` → apply migrations → `supabase test db` → `node test/*.js` → Playwright. No production secrets in this repo; CI uses only the local stack's generated keys.
