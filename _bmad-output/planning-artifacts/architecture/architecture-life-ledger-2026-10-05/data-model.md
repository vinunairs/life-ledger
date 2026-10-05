# Data Model and Migration Plan — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md` (revision 2). Three schemas (AD-2, AD-4.6):

| Schema | Exposed to Data API | Holds | Grants |
|---|---|---|---|
| `ll` | yes (only exposed schema) | tables, client-readable invoker views, helpers, client RPCs | `usage` to `authenticated` (and `service_role` for the two ops RPCs); `select` only on the objects in `rls-matrix.md` §2; never `on all tables in schema` |
| `ll_proc` | no | processor views, `ingest_draft`, `save_output` | `usage` to `ll_processor` only |
| `ll_ops` | no | cron functions, metric views, `object_tombstones`, health | none to `anon`/`authenticated`/`ll_processor` |

Every `ll` table has RLS enabled with SELECT policies only; there are no client INSERT/UPDATE/DELETE policies and no client write grants. Writes happen only in the functions listed in `rpc-contracts.md`. Column lists are the cold-start seed; the migrations own the detail once written.

Type `ll.visibility` is an enum declared in visibility order: `('private','parents_only','family','shareable')`, so `ll.narrowest(a, b)` is `least(a, b)` (AD-4.1).

## Tables (schema `ll` unless noted)

### Identity

**`persons`** — who evidence is about (AD-8)
| Column | Type | Notes |
|---|---|---|
| id | uuid pk default gen_random_uuid() | |
| display_label | text not null | Shown in UI. Real names live only here, in the database. Never sent to the processor (AD-9). |
| kind | text check in ('student','child') | UI only; never a privacy gate (AD-9) |
| ai_excluded | bool not null default false | the only privacy gate for the younger child (AD-9) |
| grade_9_start | date null | Aug 1 of the 9th-grade year; set by `set_school_calendar` |
| graduation_year | int null | |
| created_at | timestamptz default now() | |

**`members`** — logins and roles (AD-8)
| Column | Type | Notes |
|---|---|---|
| user_id | uuid pk → auth.users on delete cascade | |
| role | text check in ('parent_admin','student_owner') | |
| person_id | uuid null → persons | required when role = student_owner |
| display_label | text not null | "Captured by …", "edited by …" (FR-21) |
| is_owner | bool not null default false | exactly one true (partial unique index) |
| digest_opt_in | bool not null default false | FR-25 |
| last_person_id | uuid null → persons | person-picker default (FR-8); written only by `create_post` / `create_milestone` on insert |
| sessions_revoked_at | timestamptz null | set by `signout_student`; sessions created earlier are rejected (AD-8) |
| created_at | timestamptz default now() | |

### Capture

**`posts`**
| Column | Type | Notes |
|---|---|---|
| id | uuid pk | client-generated (AD-12) |
| author_id | uuid not null → members | |
| person_id | uuid **not null** → persons | AD-9; picker always has a value (FR-8) |
| kind | text check in ('quick','brain_dump') | |
| body | text not null check (char_length(body) ≤ 8000) | quick posts limited in client; DB enforces 8,000 for both |
| links | text[] not null default '{}' | URLs only, never fetched |
| visibility | ll.visibility not null | |
| state | text check in ('waiting','processed','needs_manual') default 'waiting' | |
| processed_by | text null check in ('ingest','manual') | set with `state='processed'`; `manual` = `create_entry` from this post |
| attempts | int not null default 0 | processor attempts (FR-16, AD-3.7) |
| last_error | text null | last processor error code, shown on needs_manual posts |
| opened_at, created_at | timestamptz | from the device (FR-10) |
| received_at | timestamptz default now() | server time; SM-4 uses `received_at` (deliberate refinement of PRD `created_at`) |
| processed_at | timestamptz null | |
| deleted_at | timestamptz null | soft delete; refused while a non-archived confirmed entry cites the post (AD-10) |

**`post_events`** — post history (AD-7)
| Column | Notes |
|---|---|
| id bigint identity pk, post_id → posts on delete cascade | |
| at timestamptz, actor uuid null (null = system/processor) | |
| kind | `visibility`, `delete`, `processed`, `needs_manual` |
| before, after | jsonb |

**`attachments`** — one row per stored object (AD-17)
| Column | Type | Notes |
|---|---|---|
| id | uuid pk | client-generated for post attachments; `gen_random_uuid()` or client id for entry-native files |
| origin | text not null check in ('post','entry') | single origin |
| post_id | uuid null → posts on delete set null | origin when `origin='post'` |
| origin_entry_id | uuid null → entries on delete set null | origin when `origin='entry'` (entry-native: milestone photo, file added to an entry) |
| object_path | text not null unique | `posts/<post_id>/<attachment_id>.<ext>` or `entries/<entry_id>/<attachment_id>.<ext>`, bucket `ledger-files` |
| origin_visibility | ll.visibility not null | visibility of the origin at upload; used by the link rule |
| person_id | uuid not null → persons | person of the origin |
| mime | text not null | read from `storage.objects.metadata`, never from the client |
| bytes | bigint not null | read from `storage.objects.metadata`; images/PDF ≤ 10 MB, audio ≤ 25 MB |
| is_service_form | bool not null default false | FR-32 |
| uploaded_by | uuid not null → members | |
| created_at | timestamptz default now() | |

Insert trigger: `origin='post'` requires `post_id`, `origin='entry'` requires `origin_entry_id`, never both. After a purge sets the origin to null, readability falls back to links; a row with neither origin nor link is deleted and its path tombstoned (AD-10).

**`entry_attachments`** — links files to entries (AD-17)
| Column | Notes |
|---|---|
| entry_id → entries on delete cascade, attachment_id → attachments on delete cascade | pk (entry_id, attachment_id) |
| linked_by uuid null, linked_at timestamptz | null `linked_by` = processor |

Link rule (checked in every function that inserts a link): `entry.person_id = attachment.person_id` and `entry.visibility ≤ attachment.origin_visibility`; if either is private, same author. `ingest_draft` links only attachments of the post being ingested.

### Evidence

**`entries`**
| Column | Type | Notes |
|---|---|---|
| id | uuid pk default gen_random_uuid() | |
| person_id | uuid not null → persons | immutable after insert except via the `_person` gap (AD-2.7) |
| author_id | uuid **not null** → members | source post's author (ingest) or the caller (manual). "Own" in FR-6 (AD-4.4) |
| type | text not null → entry_types | immutable |
| title | text not null | provenance in `fields._title` |
| date_start | date null | first day of the period; provenance in `fields._dates` |
| date_end | date null | |
| ongoing | bool not null default false | |
| date_precision | text check in ('day','month','year') | |
| fields | jsonb not null default '{}' | `{ "<field>": { "v": <canonical>, "span": <span> } }` plus `_title`, `_dates`, `_person` (AD-6) |
| visibility | ll.visibility not null | set at insert to `narrowest(type default, post.visibility)` (AD-4.5) |
| status | text check in ('draft','needs_detail','confirmed') | written only by the BEFORE trigger (AD-5) |
| source_post_id | uuid null → posts | immutable; null for manual entries without a post |
| speaker | text null check in ('student','parent_a','parent_b','other') | reflections only; set at creation (AD-2.7) |
| created_by | uuid null → members | null for ingest; `created_via` says which |
| created_via | text check in ('ingest','manual') | |
| confirmed_by, confirmed_at | uuid null, timestamptz null | set only by confirm RPCs; cleared when a required gap reopens or the speaker changes |
| attested_by, attested_at | uuid null, timestamptz null | service form attestation (FR-32) |
| attested_attachment_id | uuid null → attachments on delete set null | verified hours require this attachment still linked (AD-17) |
| archived_at | timestamptz null | AD-10 |
| updated_by, updated_at | uuid null, timestamptz | "edited by X" (FR-21) |

CHECK constraints: `type='parent_note' ⇒ visibility='parents_only'`; `type in ('score','academic') ⇒ visibility <> 'shareable'`; `type='reflection' ⇒ speaker is not null`; `attested_attachment_id is not null ⇒ attested_at is not null`.
Trigger checks: `type='milestone'` only with `created_via='manual'`; entries about an `ai_excluded` person are milestones only (AD-9); `entries.visibility ≤ posts.visibility` for the source post.

**`entry_types`** — `type pk, default_visibility ll.visibility, label`.

**`entry_type_fields`** — the registry (AD-6)
| Column | Notes |
|---|---|
| type, field | pk |
| required | bool |
| kind | `text`, `int`, `number`, `date`, `daterange`, `enum`, `enum[]`, `url_or_file`, `bool` |
| enum_ref | → enum_values.set, for `enum` / `enum[]` |
| storage | `fields` (in `entries.fields`) or `column:<name>` (`column:title`, `column:dates`, `column:person_id`, `column:speaker`) |
| derived | null or the rule that fills it (`grade_level`); a derived value carries a `derived` span unless a person answered it |
| gap_question | plain-language question; the only source of required-field gap questions (AD-3.5) |
| common_app_field, char_limit | FR-13 mapping (e.g. `position`, 50) |

Seed (non-personal, from PRD FR-12 / FR-13), required fields in **bold**:

| Type | Fields (kind, storage) |
|---|---|
| activity | **activity_type** (enum `activity_type`), **organization** (text, 100), **role** (text, 50 → Common App position), **grade_levels** (enum[] `grade_level`, derived `grade_level`), **timing** (enum `timing`), **hours_per_week** (number), **weeks_per_year** (number ≤ 52), **description** (text, 150), result (text), leadership (bool), still_active (bool) |
| honor | **award_name** (text, `column:title`), **awarding_org** (text), **level** (enum `honor_level`), **grade_levels** (enum[], derived), placement (text), field_size (int), related_entry (text) |
| work_sample | **title** (text, `column:title`), **date** (date, `column:dates`), **kind** (enum `work_kind`), **link_or_file** (url_or_file), **role** (enum `work_role`), tools (text), platforms (text) |
| service | **organization** (text), **date_or_range** (daterange, `column:dates`), **hours** (number), **what_he_did** (text), cause (text), supervisor_name (text) |
| academic | **course** (text, `column:title`), **term** (text), standout_reason (text), teacher_comment_excerpt (text) |
| score | **test** (text, `column:title`), **date** (date, `column:dates`), **score** (text), sub_scores (text) |
| reflection | **text** (text), **speaker** (enum `speaker`, `column:speaker`), prompt (text), related_entries (text) |
| milestone | **title** (text, `column:title`), **date** (date, `column:dates`), note (text) |
| parent_note | **text** (text), **child** (`column:person_id`), brag_sheet_question (int 1–12) |
| every ingestable type | `_person` (`column:person_id`, required only while `v` is null; question "Who is this about?") |

**`enum_values`** — `(set, value, label, sort)`, pk `(set, value)`. Sets: `activity_type` (Common App list, refreshed by migration, D-2), `timing` (`school_year`, `break`, `all_year`), `honor_level` (`school`, `state_regional`, `national`, `international`), `work_kind` (`composition`, `recording`, `project`, `writing`), `work_role` (`solo`, `collaborative`), `grade_level` (`9`, `10`, `11`, `12`, `PG`), `speaker` (`student`, `parent_a`, `parent_b`, `other`). Values are snake_case; UI labels come from `label`.

#### Canonical JSON per kind (the only accepted encodings)

`ll.check_provenance()` validates `v` against this table; `answer_gap` and `edit_entry` take the raw canonical value (not `{v: …}`).

| Kind | Canonical `v` | Example |
|---|---|---|
| text | JSON string, trimmed, non-empty | `"Jazz band"` |
| int | JSON integer | `12` |
| number | JSON number, finite | `4.5` |
| date | ISO string at its precision: `YYYY-MM-DD`, `YYYY-MM` or `YYYY` | `"2026-03"` |
| daterange | `{"start": <date>, "end": <date> \| null, "ongoing": bool}` | `{"start":"2025-09","end":null,"ongoing":true}` |
| enum | string equal to an `enum_values.value` in `enum_ref` | `"state_regional"` |
| enum[] | array of distinct enum values, ordered by `enum_values.sort` | `["9","10"]` |
| url_or_file | exactly one of `{"url": "https://…"}` or `{"attachment_id": "<uuid>"}` (the attachment must be linked to the entry) | `{"url":"https://example.org/x"}` |
| bool | JSON `true` / `false` | `true` |

Column-backed facts are stored once, in their column; `fields` holds only their provenance:
- `_title`: `{ "v": <title>, "span": <span> }`
- `_dates`: `{ "v": {"start","end","ongoing","precision"}, "span": <span> }` (present when `date_start` is set)
- `_person`: `{ "v": <person uuid> | null, "span": <span> }` (present only on ingested entries whose person was unclear, or after the `_person` gap is answered)

#### Spans (AD-6)

| Kind | Shape | Valid for |
|---|---|---|
| text | `{"kind":"text","start":int,"end":int,"quote":string}`; offsets into `source_post.body` (characters); `quote = substring(body from start+1 for end-start)` | ingest; text-kind `v` must be a substring of `quote` |
| answer | `{"kind":"answer","by":uuid,"gap_id":uuid \| null}` | answers (`gap_id` set), direct edits and manual entries (`gap_id` null) |
| derived | `{"kind":"derived","rule":string,"from":[string]}` | only fields whose registry `derived` matches `rule` (e.g. `grade_level` from `["_dates"]`), and `_person` with rule `post_person` |

No image spans in v1. `check_provenance()` rejects any field, `_title` or `_dates` without a valid span.

**`gaps`**
| Column | Notes |
|---|---|
| id uuid pk, entry_id → entries on delete cascade | |
| field | registry field, or `_person` |
| question | text; registry `gap_question` for required fields; processor text accepted only for optional fields |
| required | bool |
| state | `open` / `answered` / `not_applicable` |
| answered_by, answered_at | |

Unique `(entry_id, field) where state='open'`. Required gaps are written only by `ll.sync_gaps(NEW)` (AD-5); optional gaps are written by `ingest_draft`; state changes by `answer_gap` / `mark_not_applicable`.

**`duplicate_flags`** — `entry_id pk → entries on delete cascade (the new draft)`, `duplicate_of → entries on delete cascade`, `reason text`, `resolution null|'keep_both'|'merged'|'discarded'`, `resolved_by`, `resolved_at`. Trigger check: both entries have the same `person_id`, `type` and `visibility` (AD-4, FR-18).

**`entry_versions`** — `id, entry_id → entries on delete cascade, editor uuid null (null = system/processor), at, txid bigint, reason, before jsonb, after jsonb`. Unique `(entry_id, txid)`. `reason` ∈ `edit, answer, not_applicable, confirm, unconfirm, merge, visibility, archive, restore, attest, attach, detach, discard` (AD-7). Written only by the AFTER UPDATE trigger.

**`comments`** — `id, entry_id → entries on delete cascade, author_id → members, body text (≤ 2000), created_at` (D-5 default).

### Outputs

**`outputs`** — `id, person_id, kind ('activities','honors','recommender_pointers','essay_angles'), visibility ll.visibility, created_at, latest_version_id`. `visibility` is `parents_only` for recommender_pointers, `family` otherwise (CHECK). Unique `(person_id, kind)`. Listable by clients (metadata only).

**`output_versions`** — `id, output_id, parent_id null, origin ('generated','edit'), request_id null, created_by null (null = processor), created_at, cited_entry_ids uuid[]`. Immutable. No client grant.

**`output_items`** — no client grant (AD-11):
| Column | Notes |
|---|---|
| id uuid pk, version_id → output_versions | |
| position | int |
| from_item_id | uuid null → output_items; lineage for diffs and for carrying hidden items forward |
| slot | jsonb: `pinned`, `dropped`, `over_limit` (array of field names), `brag_sheet_question` (int), `theme` (text) |
| payload | jsonb: the kind's payload (`rpc-contracts.md` §2) |
| generated_payload | jsonb: payload as generated, carried through edits (SM-7 diff) |
| cites | uuid[] not empty |
| redacted | bool default false; purge sets true and empties `payload`, `generated_payload` and `slot.theme` |

**`output_requests`** — `id, person_id, kind, requested_by, requested_at, state ('open','fulfilled','cancelled'), fulfilled_version_id null, closed_at`. Partial unique `(person_id, kind) where state='open'` (D-4).

**`output_access_log`** — `id, output_id, version_id, viewer, at` (FR-37). No client grant; written by `get_output` in the same transaction.

### Operations

**`ll.events`** — `id bigint identity, at, actor uuid null, name, props jsonb`. No client grant. Client names (via `log_event`): `post_opened`, `post_submitted`, `post_duration`, `queue_flushed`. Server names (written directly): `accuracy_check`, `purge_run`, `digest_sent`, `backup_run`, `status_drift`, `health`.

**`ll_ops.object_tombstones`** — `object_path text pk, reason text ('purge','detach','over_limit','orphan_upload'), queued_at`. Filled by SQL; drained by the ops workflow through the Storage API (AD-10, AD-17).

## Views

| View | Schema | Security | Reader | Purpose |
|---|---|---|---|---|
| `timeline` | `ll` | `security_invoker = true` | authenticated (RLS applies) | posts + their readable entries + status (FR-26) |
| `profile_summary` | `ll` | `security_invoker = true` | authenticated | confirmed entries by type, counts, incomplete flag (FR-29) |
| `service_hours` | `ll` | `security_invoker = true` | authenticated | per person totals from `grade_9_start`; verified = `attested_attachment_id` still in `entry_attachments` (FR-31, FR-32) |
| `processing_queue` | `ll_proc` | owner (not exposed) | `ll_processor` | waiting posts of the current `ll.run_class`; no private, no `ai_excluded`, not deleted (AD-3, AD-9) |
| `processor_context` | `ll_proc` | owner | `ll_processor` | non-archived entries of the run class (duplicate candidates) |
| `output_request_queue` | `ll_proc` | owner | `ll_processor` | open requests of the run class with eligible confirmed entries |
| `metric_*` | `ll_ops` | owner | ops workflow; owner via `ll.metrics()` | SM-1 … SM-7, SM-C1 … SM-C3 |

All three `ll_proc` views read `current_setting('ll.run_class', true)`; when it is unset they return no rows. Column lists are in `rpc-contracts.md` §3.

## Functions (non-RPC)

All `set search_path = ''`, schema-qualified, followed by `revoke all … from public, anon, authenticated` and the one grant they need.

| Function | Schema | Kind | Grant |
|---|---|---|---|
| `member_ok()` | ll | definer stable; boolean form of the session rule in AD-8 | authenticated (policies) |
| `require_member()` | ll | definer; raises `not-a-member` / `session-expired` | authenticated |
| `is_parent()`, `is_owner()`, `my_person()` | ll | definer stable; policies call `(select ll.is_parent())` | authenticated |
| `narrowest(a, b)` | ll | immutable | authenticated |
| `can_read(visibility, author_id)` | ll | definer stable | authenticated |
| `post_visible(post_id)`, `entry_visible(entry_id)` | ll | definer stable | authenticated |
| `can_act(action, target)`, `can_act_as(user_id, action, target)` | ll | definer stable; `can_act` = `can_act_as(auth.uid(), …)` | authenticated (`can_act` only) |
| `file_readable(object_path)`, `upload_allowed(object_path)` | ll | definer stable; storage policies | authenticated |
| `grade_level(person_id, date)` | ll | stable | none (internal) |
| `validate_output_items(kind, person_id, items, editor)` | ll | definer | none (internal) |
| `sync_gaps(entries)`, `check_provenance()`, `entries_before()`, `write_version()`, `cascade_post_visibility()`, `post_events_write()` | ll | trigger functions | none |
| `purge_expired()`, `nightly_accuracy_check()`, `status_sweep()`, `prune_cron_history()`, `health()` | ll_ops | definer | none (pg_cron runs as owner) |
| `badge_for(user_id)` | ll | definer stable; same counts as `my_badge` | service_role (digest workflow) |
| `ops_health()` | ll | definer; returns `ll_ops.health()` counts only | service_role (keepalive workflow) |

`entries_before()` (BEFORE INSERT OR UPDATE) sets visibility at insert, derives `grade_levels` unless answered, calls `sync_gaps(NEW)`, then sets `status` (AD-5). `write_version()` (AFTER UPDATE) writes one row per entry per `txid_current()`, skipping status/updated_at-only changes (AD-7). `cascade_post_visibility()` narrows a post's entries in the same transaction (reason `visibility`).

## Storage

- Bucket `ledger-files`: `public = false`, `file_size_limit = 25 MB`, `allowed_mime_types = {image/jpeg, image/png, image/heic, image/webp, application/pdf, audio/mpeg, audio/mp4, audio/aac}`. RPCs re-check 10 MB for images and PDFs from `storage.objects.metadata` (`over-limit`, object tombstoned).
- Path grammar: `posts/<post_id>/<attachment_id>.<ext>` and `entries/<entry_id>/<attachment_id>.<ext>`, ids lower-case uuids, `ext` in `jpg|png|heic|webp|pdf|mp3|m4a|aac`.
- Policies on `storage.objects` for this bucket, role `authenticated` only:
  - SELECT: `ll.file_readable(name)` — an `attachments` row with that path whose origin post passes `post_visible`, or that has a link whose entry passes `entry_visible`.
  - INSERT: `ll.upload_allowed(name)` — `member_ok()` and either a post path whose post does not exist, or exists, is the caller's, is `waiting` and not deleted; or an entry path whose entry passes `can_act('entry.attach', id)`.
  - **No UPDATE or DELETE policies.** Uploads use `upsert: false`.
- Signed URLs are created by the client: `storage.from('ledger-files').createSignedUrl(path, 600)`, authorized by the SELECT policy. No SQL function signs URLs.
- Objects are deleted only by the ops workflow (service role, Storage API) from `ll_ops.object_tombstones`. `purge_expired` also tombstones uploads older than 7 days that have no `attachments` row (abandoned queue uploads).
- Free plan: 1 GB storage; images are resized on device (≤ 2,048 px).

## Migration order

Files are `supabase/migrations/YYYYMMDDHHMM_<slug>.sql`, idempotent, add-only after the first production deploy. Every migration ends with its explicit `revoke`/`grant` statements; no `grant … on all tables/functions in schema`.

1. `_00_foundation` — schemas `ll`, `ll_proc`, `ll_ops`; `alter default privileges in schema ll, ll_proc, ll_ops revoke all on functions from public` and `… revoke all on tables, sequences from public, anon, authenticated`; `grant usage on schema ll to authenticated`; extensions `pgcrypto`, `pg_cron`, `pg_jsonschema` (in `extensions`); `pg_graphql` disabled; role `ll_processor` (`nologin noinherit nobypassrls`); type `ll.visibility`; `persons`, `members`; `member_ok`, `require_member`, `is_parent`, `is_owner`, `my_person`. Schema exposure: `[api] schemas = ["ll"]` in `supabase/config.toml` and the dashboard Data API setting (runbook); no Realtime publication includes `ll`, `ll_proc` or `ll_ops`.
2. `_01_registry` — `entry_types`, `entry_type_fields`, `enum_values` + seed (non-personal).
3. `_02_capture` — `posts`, `post_events`.
4. `_03_evidence` — `entries`, `gaps`, `duplicate_flags`, `entry_versions`, `comments`, `attachments`, `entry_attachments`, constraints, trigger functions and triggers.
5. `_04_security` — `narrowest`, `can_read`, `post_visible`, `entry_visible`, `can_act[_as]`, `file_readable`, `upload_allowed`; all SELECT policies; table grants per `rls-matrix.md` §2; invoker views `timeline`, `profile_summary`; bucket `ledger-files` with limits and storage policies.
6. `_05_client_rpcs_m1` — M1 client RPCs (`rpc-contracts.md` §4), including `create_entry`, `create_milestone`, `export_person`, `archive_list`, `signout_student`.
7. `_06_processor` — `ll_proc` views, `ll_proc.ingest_draft`; grants to `ll_processor` only.
8. `_07_ops_m1` — `ll.events`, `log_event`, `ll_ops.object_tombstones`, `purge_expired`, `nightly_accuracy_check`, `status_sweep`, `prune_cron_history`, `health`, `ll.badge_for`, `ll.ops_health` (service_role), `pg_cron` schedules (hourly UTC, Eastern-gated, AD-13).
9. `_08_m2` — `bulk_confirm`, `attach_file`, `detach_file`, `attest_service_form`, `set_school_calendar`, `service_hours` view.
10. `_09_outputs` — output tables, `validate_output_items`, `ll_proc.save_output`, `output_request_queue`, `get_output`, `request_output`, `cancel_output_request`, `edit_output`, access log.
11. `_10_metrics` — `ll_ops.metric_*` views, `ll.metrics()`.

Account bootstrap (not in the repo): the owner creates three Auth users in the dashboard (sign-ups disabled), then inserts `persons` and `members` rows in the SQL editor from a private, git-ignored script (`supabase/seed.private.sql`, already in `.gitignore`). Fixtures in the repo use role labels only.
