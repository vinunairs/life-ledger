# Data Model and Migration Plan — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md`. All objects live in schema `ll`. Every table has RLS enabled with SELECT policies only (AD-2); writes happen in the RPCs listed in `rpc-contracts.md`. Column lists are the cold-start seed; the migrations own the detail once written.

## Tables

### Identity

**`persons`** — who evidence is about (AD-8)
| Column | Type | Notes |
|---|---|---|
| id | uuid pk | |
| display_label | text not null | Shown in UI. Real name lives only here, in the database. |
| kind | text check in ('student','child') | |
| ai_excluded | bool not null default false | true for the younger child (AD-9) |
| grade_9_start | date null | Aug 1 of the 9th-grade year; null for the younger child |
| graduation_year | int null | |
| created_at | timestamptz default now() | |

**`members`** — logins and roles
| Column | Type | Notes |
|---|---|---|
| user_id | uuid pk → auth.users on delete cascade | |
| role | text check in ('parent_admin','student_owner') | |
| person_id | uuid null → persons | required when role = student_owner |
| is_owner | bool default false | exactly one true (partial unique index) |
| digest_opt_in | bool default false | FR-25 |
| last_person_id | uuid null → persons | person-picker default (FR-8) |
| sessions_revoked_at | timestamptz null | JWTs issued earlier are rejected by role helpers (FR-3) |

### Capture

**`posts`**
| Column | Type | Notes |
|---|---|---|
| id | uuid pk | client-generated (AD-12) |
| author_id | uuid not null → members | |
| person_id | uuid null → persons | null allowed → "Who is this about?" gap |
| kind | text check in ('quick','brain_dump') | |
| body | text check (char_length ≤ 8000) | quick posts limited in client; DB enforces 8,000 for both |
| links | text[] default '{}' | URLs only (FR-16 out of scope: fetching) |
| visibility | text check in ('private','family','parents_only','shareable') | Q1 decision |
| state | text check in ('waiting','processed','needs_manual') default 'waiting' | |
| attempts | int default 0 | ingest retries (FR-16) |
| created_at, received_at, processed_at | timestamptz | created_at from device; received_at server time (SM-4 uses received_at) |
| deleted_at | timestamptz null | soft delete; blocked while confirmed entries cite it |

**`attachments`** — files on posts and entries (FR-30)
| Column | Type | Notes |
|---|---|---|
| id | uuid pk | |
| object_path | text unique | `posts/{post_id}/{uuid}.{ext}` or `entries/{entry_id}/{uuid}.{ext}` in bucket `ledger-files` |
| post_id | uuid null → posts | |
| entry_id | uuid null → entries | an attachment can be on a post, an entry, or both |
| mime, bytes | text, int | check: image/pdf ≤ 10 MB, audio ≤ 25 MB |
| is_service_form | bool default false | FR-32 |
| uploaded_by | uuid → members | |

### Evidence

**`entries`**
| Column | Type | Notes |
|---|---|---|
| id | uuid pk | |
| person_id | uuid not null → persons | |
| type | text not null → entry_types | activity, honor, work_sample, service, academic, score, reflection, milestone, parent_note |
| title | text not null | |
| date_start | date | |
| date_end | date null | |
| ongoing | bool default false | |
| date_precision | text check in ('day','month','year') | |
| fields | jsonb not null default '{}' | `{field: {v, span, by}}` (AD-6) |
| visibility | text not null | set by trigger from type default ∧ post (AD-4) |
| status | text check in ('draft','needs_detail','confirmed') | trigger-owned (AD-5) |
| source_post_id | uuid null → posts | null for manual milestones |
| speaker | text null check in ('student','parent_a','parent_b','other') | reflections only |
| created_by | uuid null → members | null when created by ingest; `created_via` says which |
| created_via | text check in ('ingest','manual','merge') | |
| confirmed_by, confirmed_at | uuid, timestamptz | |
| attested_by, attested_at | uuid, timestamptz | service form attestation (FR-32) |
| archived_at | timestamptz null | AD-10 |
| updated_by, updated_at | uuid, timestamptz | "edited by X" (FR-21) |

Constraints: `type='parent_note' ⇒ visibility='parents_only'`; `type in ('score','academic') ⇒ visibility <> 'shareable'`; `type='reflection' ⇒ speaker not null`; milestone only on `persons.kind='child'` and only `created_via='manual'`.

**`entry_types`** — `type pk, default_visibility, label`.

**`entry_type_fields`** — the registry (AD-6)
| Column | Notes |
|---|---|
| type, field | pk |
| required | bool |
| kind | `text`, `int`, `number`, `date`, `daterange`, `enum`, `enum[]`, `url_or_file`, `bool` |
| enum_ref | → enum_values.set, for enum kinds |
| gap_question | plain-language question text used when missing |
| common_app_field, char_limit | mapping for FR-13 (e.g. `position`, 50) |

Seeded from PRD FR-12 / FR-13.

**`enum_values`** — `(set, value, label, sort)`: `activity_type` (Common App list, D-2), `timing`, `honor_level`, `work_kind`, `work_role`, `grade_level`.

**`gaps`**
| Column | Notes |
|---|---|
| id uuid pk, entry_id → entries | |
| field | text; `'_person'` for "Who is this about?" |
| question | text |
| required | bool |
| state | `open` / `answered` / `not_applicable` |
| answered_by, answered_at | |

Unique `(entry_id, field) where state='open'`.

**`duplicate_flags`** — `entry_id pk (the new draft), duplicate_of → entries, reason text, resolution null|'keep_both'|'merged'|'discarded', resolved_by, resolved_at`.

**`entry_versions`** — `id, entry_id, editor (null = system/processor), at, reason, before jsonb, after jsonb` (AD-7). Cascades on purge.

**`comments`** — `id, entry_id, author_id, body, created_at` (D-5 default).

### Outputs

**`outputs`** — `id, person_id, kind ('activities','honors','recommender_pointers','essay_angles'), visibility` (recommender_pointers = parents_only; others = family). Unique `(person_id, kind)`.

**`output_versions`** — `id, output_id, parent_id null, origin ('generated','edit'), created_by null, created_at, cited_entry_ids uuid[]`. Immutable.

**`output_items`** — `id, version_id, position, slot jsonb (pinned/dropped flags, brag_sheet_question, theme), payload jsonb (field texts, reason, quotes), generated_payload jsonb (for diff, SM-7), cites uuid[], redacted bool default false`.

**`output_requests`** — `id, person_id, kind, requested_by, requested_at, fulfilled_version_id null`. Partial unique `(person_id, kind) where fulfilled_version_id is null` (D-4 default).

**`output_access_log`** — `id, output_id, version_id, viewer, at` (FR-37, parents_only outputs).

### Operations

**`events`** — `id bigint identity, at, actor null, name, props jsonb`. Allow-listed names: `post_duration`, `post_submitted`, `queue_flushed`, `accuracy_check`, `purge_run`, `digest_sent`, `backup_run`.

## Views

| View | Reader | Purpose |
|---|---|---|
| `processing_queue` | processor only | posts `state='waiting'`, visibility ≠ private, person not ai_excluded, not deleted; includes attachment paths and existing-entry digest for the person |
| `processor_context` | processor only | confirmed + draft entries (id, type, title, dates) of non-excluded persons, non-private, for duplicate detection |
| `output_request_queue` | processor only | open output requests with the confirmed entries eligible for that kind |
| `timeline` | authenticated (RLS) | posts + entries + status for FR-26 |
| `service_hours` | authenticated (RLS) | per person totals / verified, from grade_9_start (FR-31) |
| `metric_*` | owner | SM-1 … SM-7, SM-C1 … SM-C3 |

## Functions (non-RPC helpers)

`is_parent()`, `is_owner()`, `my_person()`, `can_read(visibility, author_id, person_id)`, `narrowest(a, b)`, `grade_level(person_id, date)`, `recompute_status()` (trigger), `write_version()` (trigger), `apply_visibility()` (trigger), `check_field_provenance()` (trigger).

## Storage

Bucket `ledger-files`, private. Policy: `select` allowed when an `attachments` row for `name` exists whose post or entry the caller can read; uploads allowed only to `posts/{id}/` for a post id not yet existing or authored by the caller, or `entries/{id}/` for an entry the caller can edit. Signed URLs created by `ll.file_url(attachment_id)` with 600 s expiry. Free-plan storage is 1 GB; files are not resized server-side.

## Migration order

Each file is idempotent and add-only after first production deploy.

1. `…_00_schema_roles.sql` — schema `ll`, extensions (`pgcrypto`, `pg_cron`), `persons`, `members`, role helpers.
2. `…_01_registry.sql` — `entry_types`, `entry_type_fields`, `enum_values` + seed (non-personal).
3. `…_02_capture.sql` — `posts`, `attachments`, storage bucket and policies.
4. `…_03_evidence.sql` — `entries`, `gaps`, `duplicate_flags`, `entry_versions`, `comments`, constraints, triggers.
5. `…_04_rls.sql` — `can_read`, all SELECT policies, `revoke` defaults.
6. `…_05_client_rpcs_m1.sql` — M1 client RPCs.
7. `…_06_processor.sql` — views + `ingest_draft`, grants to privileged role only.
8. `…_07_ops_m1.sql` — `events`, `log_event`, `purge_expired`, `nightly_accuracy_check`, `status_sweep`, `pg_cron` schedules.
9. `…_08_m2.sql` — `bulk_confirm`, files RPCs, `service_hours`, `attest_service_form`.
10. `…_09_outputs.sql` — output tables, `save_output`, `get_output`, `request_output`, `edit_output`, access log.
11. `…_10_metrics.sql` — `metric_*` views.

Account bootstrap (not in the repo): the owner creates three Auth users in the dashboard, then inserts `persons` and `members` rows in the SQL editor from a private, git-ignored script (`supabase/seed.private.sql`, already in `.gitignore`).
