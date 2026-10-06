# RPC Contracts — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md` (AD-2, AD-3, AD-9, AD-11, AD-12, AD-17). Processor payloads are JSON Schema draft 2020-12, validated in SQL with `pg_jsonschema` (`jsonschema_validation_errors()` mapped to `invalid-payload`; `detail` carries the first error path). The schemas below are normative.

## Error codes

Client RPCs raise `errcode 'P0001'`, `message = <code>`. Processor functions **return** `{ "ok": false, "code": <code>, "detail": "…" }` and never raise for a payload problem (AD-3.7).

| Group | Codes |
|---|---|
| Session and access | `session-expired`, `not-a-member`, `forbidden`, `parent-only`, `not-processor`, `wrong-run-class` |
| Payload | `invalid-payload`, `forbidden-key`, `unknown-type`, `type-not-allowed`, `unknown-field`, `bad-enum`, `bad-value`, `missing-source-span`, `value-not-in-span` |
| Targets | `unknown-post`, `post-not-waiting`, `unknown-entry`, `unknown-attachment`, `unknown-request`, `request-mismatch`, `id-conflict`, `file-missing` |
| Privacy | `ai-excluded`, `private-post`, `forbidden-visibility`, `wider-than-post` |
| Rules | `person-mismatch`, `duplicate-not-eligible`, `cite-not-eligible`, `quote-mismatch`, `over-limit`, `student-text-locked`, `student-must-confirm`, `required-gap-open`, `gap-not-open`, `post-has-confirmed-entries`, `post-not-manual` |

The client maps every code to plain-language copy (`web/js/api.js`); an unknown code shows a generic message with the code.

## 0. Calling the processor functions

Both functions live in `ll_proc`, are `security definer`, `set search_path = ''`, and are executable only by `ll_processor`. Their first statement refuses any caller whose active role is not `ll_processor` (`not-processor`; inside a definer body `current_user` is the owner, so the check reads `current_setting('role')`), and the second reads `ll.run_class` (`family` | `parents`, else `wrong-run-class`).

Every batch the run sends has exactly this shape (processing guide rule 1):

```sql
begin;
set local role ll_processor;
set local ll.run_class = 'family';           -- or 'parents'
select current_user;                          -- must print ll_processor
select ll_proc.ingest_draft($p7f3a9c$ { …payload… } $p7f3a9c$::jsonb);
commit;
```

- Payloads are **dollar-quoted with a fresh random tag** (`$p<6+ random alnum>$`) chosen so it does not occur in the payload; never single-quoted, never string-concatenated.
- Two scheduled tasks run at 8:45 pm Eastern, `family` first, then `parents`. A run reads only its class through the views (§3).
- Persons are named to the model only by role label (`person_label`, e.g. "Student").

## 1. `ll_proc.ingest_draft(payload jsonb) returns jsonb`

One call per post. Atomic.

### Input schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "ll/ingest_draft.input",
  "type": "object",
  "additionalProperties": false,
  "required": ["post_id", "entries", "gaps"],
  "properties": {
    "post_id": { "type": "string", "format": "uuid" },
    "entries": {
      "type": "array",
      "maxItems": 25,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["ref", "person_id", "type", "title", "title_span", "fields"],
        "dependentRequired": { "date_start": ["date_precision", "date_span"] },
        "properties": {
          "ref": { "type": "string", "pattern": "^[a-z0-9_-]{1,32}$", "description": "local id so gaps can point at it" },
          "person_id": { "type": ["string", "null"], "format": "uuid", "description": "null = unclear: server uses the post's person and opens the '_person' gap" },
          "type": { "enum": ["activity", "honor", "work_sample", "service", "academic", "score", "reflection", "parent_note"] },
          "title": { "type": "string", "minLength": 1, "maxLength": 200 },
          "title_span": { "$ref": "#/$defs/span" },
          "date_start": { "type": "string", "format": "date" },
          "date_end": { "type": "string", "format": "date" },
          "ongoing": { "type": "boolean" },
          "date_precision": { "enum": ["day", "month", "year"] },
          "date_span": { "$ref": "#/$defs/span" },
          "speaker": { "enum": ["student", "parent_a", "parent_b", "other"] },
          "fields": {
            "type": "object",
            "propertyNames": { "pattern": "^[a-z][a-z0-9_]{0,40}$" },
            "additionalProperties": {
              "type": "object",
              "additionalProperties": false,
              "required": ["v", "span"],
              "properties": { "v": {}, "span": { "$ref": "#/$defs/span" } }
            }
          },
          "attachment_ids": { "type": "array", "uniqueItems": true, "items": { "type": "string", "format": "uuid" } },
          "possible_duplicate": {
            "type": "object",
            "additionalProperties": false,
            "required": ["of_entry_id", "reason"],
            "properties": {
              "of_entry_id": { "type": "string", "format": "uuid" },
              "reason": { "type": "string", "minLength": 10, "maxLength": 300 }
            }
          }
        }
      }
    },
    "gaps": {
      "type": "array",
      "description": "optional-field questions only; required-field gaps come from the registry",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["entry_ref", "field", "question"],
        "properties": {
          "entry_ref": { "type": "string" },
          "field": { "type": "string" },
          "question": { "type": "string", "minLength": 5, "maxLength": 200 }
        }
      }
    }
  },
  "$defs": {
    "span": {
      "type": "object", "additionalProperties": false, "required": ["kind", "start", "end", "quote"],
      "properties": { "kind": { "const": "text" }, "start": { "type": "integer", "minimum": 0 },
        "end": { "type": "integer", "minimum": 1 }, "quote": { "type": "string", "minLength": 1 } }
    }
  }
}
```

Only `text` spans are accepted; image spans are rejected (`invalid-payload`) in v1.

### Server behaviour (in order)

1. Caller check (`not-processor`) and `ll.run_class` (`wrong-run-class`). Not counted.
2. Read `post_id` (`invalid-payload` if absent); lock the post `for update`: exists (`unknown-post`), `state='waiting'` and not deleted (`post-not-waiting`), person not `ai_excluded` (`ai-excluded`), visibility ≠ private (`private-post`), visibility class matches `ll.run_class` (`wrong-run-class`). These leave the post untouched and are **not counted**.
3. From here every error is processor-caused and **counts as an attempt**: schema (`invalid-payload`); any key `status`, `visibility`, `confirmed_by`, `confirmed_at`, `id`, `author_id` anywhere → `forbidden-key` (FR-16 injection test).
4. Per entry:
   - `type` known (`unknown-type`); `parent_note` only from a parent's post (`type-not-allowed`).
   - every field is a registry field of that type with `storage = fields` (`unknown-field`); `v` is canonical for its kind (`bad-value`, `bad-enum`; `data-model.md`).
   - every span's `quote = substring(post.body from start+1 for end-start)` (`missing-source-span`).
   - text-kind `v` is a substring of its span quote (`value-not-in-span`); normalization is allowed only for enum, enum[], int, number, date, daterange and bool kinds; a `url` must appear in the quote or in `post.links`.
   - `title_span` required; `title` (text) must be a substring of its quote; `date_span` required with dates.
   - `person_id` is the post's person, or another non-excluded person (`ai-excluded`, `person-mismatch` if unknown); null → post's person plus `fields._person = {v:null, span:{kind:'derived', rule:'post_person', from:['source_post_id']}}`, which opens the `_person` gap.
   - `attachment_ids` ⊆ attachments of this post (`unknown-attachment`); linked via `entry_attachments`.
   - `possible_duplicate.of_entry_id` is in `processor_context` for this run (`unknown-entry`), has the same person, type and computed visibility (same author if private), and dates overlapping or within 30 days (`duplicate-not-eligible`).
5. Insert entries with `created_via='ingest'`, `author_id = post.author_id`, `source_post_id`, `fields._title`, `fields._dates`; visibility is set by the trigger to `narrowest(type default, post.visibility)`. The BEFORE trigger derives `grade_levels`, runs `sync_gaps` (required-field gaps with registry questions) and sets status (`needs_detail` / `draft`).
6. Insert caller gaps for **optional** fields only; caller gaps naming a required field are ignored (the registry question is used). Gaps inherit the entry's visibility.
7. Insert `duplicate_flags`.
8. Set post `state='processed'`, `processed_by='ingest'`, `processed_at=now()`; write a `post_events` row.

Steps 3–8 run in a plpgsql `begin … exception` block. On error its writes roll back; the function increments `posts.attempts`, stores `last_error`, sets `state='needs_manual'` once `attempts ≥ 2` (post_events `needs_manual`), and returns `{ "ok": false, "code", "detail", "attempts": n }`. The guide retries once with a corrected payload (FR-16).

### Output

```json
{ "ok": true, "post_id": "uuid", "entries": [{ "ref": "a", "id": "uuid", "status": "needs_detail", "visibility": "family", "gap_count": 2 }] }
```

## 2. `ll_proc.save_output(payload jsonb) returns jsonb`

### Input schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "ll/save_output.input",
  "type": "object",
  "additionalProperties": false,
  "required": ["person_id", "kind", "items"],
  "properties": {
    "person_id": { "type": "string", "format": "uuid" },
    "kind": { "enum": ["activities", "honors", "recommender_pointers", "essay_angles"] },
    "request_id": { "type": "string", "format": "uuid" },
    "items": {
      "type": "array",
      "minItems": 1,
      "maxItems": 60,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["position", "cites", "payload"],
        "properties": {
          "position": { "type": "integer", "minimum": 1 },
          "cites": { "type": "array", "minItems": 1, "uniqueItems": true, "items": { "type": "string", "format": "uuid" } },
          "payload": { "$ref": "#/$defs/payload" }
        }
      }
    }
  },
  "$defs": {
    "grade_levels": { "type": "array", "uniqueItems": true, "items": { "enum": ["9", "10", "11", "12", "PG"] } },
    "payload": {
      "oneOf": [
        { "title": "activity", "type": "object", "additionalProperties": false,
          "required": ["activity_type", "position", "organization", "description", "grade_levels", "timing", "hours_per_week", "weeks_per_year", "reason"],
          "properties": {
            "activity_type": { "type": "string" },
            "position": { "type": "string" }, "organization": { "type": "string" }, "description": { "type": "string" },
            "grade_levels": { "$ref": "#/$defs/grade_levels" },
            "timing": { "enum": ["school_year", "break", "all_year"] },
            "hours_per_week": { "type": "number", "minimum": 0 }, "weeks_per_year": { "type": "number", "minimum": 0, "maximum": 52 },
            "reason": { "type": "string", "maxLength": 200 } } },
        { "title": "honor", "type": "object", "additionalProperties": false,
          "required": ["title", "grade_levels", "level"],
          "properties": { "title": { "type": "string" }, "grade_levels": { "$ref": "#/$defs/grade_levels" },
            "level": { "enum": ["school", "state_regional", "national", "international"] }, "reason": { "type": "string", "maxLength": 200 } } },
        { "title": "pointer", "type": "object", "additionalProperties": false,
          "required": ["brag_sheet_question", "text"],
          "properties": { "brag_sheet_question": { "type": "integer", "minimum": 1, "maximum": 12 }, "text": { "type": "string", "maxLength": 600 } } },
        { "title": "angle", "type": "object", "additionalProperties": false,
          "required": ["theme", "summary", "quotes"],
          "properties": { "theme": { "type": "string", "maxLength": 80 }, "summary": { "type": "string", "maxLength": 300 },
            "quotes": { "type": "array", "items": { "type": "object", "additionalProperties": false, "required": ["reflection_id", "text"],
              "properties": { "reflection_id": { "type": "string", "format": "uuid" }, "text": { "type": "string", "minLength": 1 } } } } } }
      ]
    }
  }
}
```

### Server behaviour

1. Caller check and run class: `recommender_pointers` only in the `parents` run, other kinds only in the `family` run (`wrong-run-class`).
2. Schema (`invalid-payload`); forbidden keys (`forbidden-key`); person exists and is not `ai_excluded` (`ai-excluded`).
3. `request_id`, if given, is an open request (`unknown-request`) for the same `(person_id, kind)` (`request-mismatch`).
4. `ll.validate_output_items(kind, person_id, items, editor => null)` (shared with `edit_output`):
   - payload shape matches `kind` (activity ↔ activities, honor ↔ honors, pointer ↔ recommender_pointers, angle ↔ essay_angles).
   - every cite: same person, `status='confirmed'`, not archived, visibility ≠ private; kinds other than recommender_pointers: visibility ≠ parents_only; activities: type in (activity, service, work_sample) and visibility in (family, shareable); honors: type = honor; essay_angles: no parent_note; recommender_pointers: parent_note or confirmed family/shareable entries (`cite-not-eligible`). With an `editor`, every cite must also pass `entry_visible` for the editor.
   - essay quotes: `reflection_id` is cited, confirmed, speaker = student, and `text` is an exact substring of its confirmed `text` field (`quote-mismatch`). No essay prose: `summary` ≤ 300 chars, no line breaks in any value.
   - character limits are **not** trimmed: over-limit values (position > 50, organization > 100, description > 150) are stored and their field names listed in `slot.over_limit` (FR-38). More than 10 activities or 5 honors → `over-limit`.
5. Insert `output_versions(origin='generated', request_id)` and items with `generated_payload = payload`; close the request matching `request_id`, or the open request for `(person_id, kind)` when none is given (D-4).

Errors return `{ "ok": false, "code", "detail" }`; nothing is written. Requests stay open.

### Output

`{ "ok": true, "output_id": "uuid", "version_id": "uuid", "item_count": 10, "flags": { "over_limit": 2 } }`

## 3. Processor views (`ll_proc`, filtered by `ll.run_class`)

All exclude `ai_excluded` persons, private posts and entries, deleted posts and archived entries. `family` class = visibility family or shareable; `parents` class = parents_only.

- `ll_proc.processing_queue`: `post_id, person_id, person_label (role label only), kind, visibility, body, links, attachments [{id, mime}], created_at, attempts` — `state='waiting'`, run class only.
- `ll_proc.processor_context`: `entry_id, person_id, type, visibility, title, date_start, date_end, status` — run class only; duplicate candidates.
- `ll_proc.output_request_queue`: `request_id, person_id, kind, requested_at, eligible_entries jsonb` — `family` run: open activities/honors/essay_angles requests, eligible entries per §2 (family/shareable only); `parents` run: open recommender_pointers requests, eligible entries = confirmed parent_notes and parents_only entries plus confirmed family/shareable entries (FR-40; the output is parents_only, so nothing flows to a wider class).

## 4. Client RPCs (exhaustive)

All in `ll`, `security definer` unless marked *invoker*, `set search_path = ''`, `revoke all … from public, anon, authenticated` then `grant execute … to authenticated`. Mutations: first `perform ll.require_member()`, then resolve the target and check `ll.can_act(...)` (`rls-matrix.md` §3), then `set local ll.reason`. No RPC reads `ll.members` directly for authorization, and none returns a row the caller could not `SELECT`.

| RPC | Args | Notes |
|---|---|---|
| `create_post` | `id uuid, person_id, kind, body, links text[], visibility, attachments jsonb [{id, ext}], opened_at, created_at` | Refuses `ai_excluded` person (`ai-excluded`), S with parents_only (`forbidden-visibility`), body > 8000 (`over-limit`). Paths are derived `posts/<id>/<attachment_id>.<ext>`; each object must exist (`file-missing`); mime/bytes read from `storage.objects.metadata`, images/PDF > 10 MB → `over-limit` (object tombstoned). Insert; on id conflict returns the stored row only if `author_id = auth.uid()` and `(person_id, kind, body, visibility, links, attachment ids)` match, else `id-conflict`. Side effects only on actual insert: `post_duration` event (from `opened_at`/`created_at`), `members.last_person_id`. |
| `create_milestone` | `person_id, title, date, date_precision` | Parents; `ai_excluded` (younger child) persons only; created confirmed with `answer` spans; sets `last_person_id`. Photo added with `attach_file`. |
| `create_entry` | `person_id, type, title, date_start, date_end, ongoing, date_precision, fields jsonb, visibility, source_post_id null, speaker null` | Manual entry (FR-6, FR-15, FR-16). Not milestone; parent_note parents only; S cannot use parents_only. With `source_post_id`: post readable, same person, and either the caller's private post or `state in ('needs_manual')` or `processed_by='manual'` (`post-not-manual`); marks the post `processed`, `processed_by='manual'`. `author_id` = caller; spans `{kind:'answer', by, gap_id:null}`; visibility = `narrowest(type default, requested, post.visibility)`. |
| `edit_entry` | `entry_id, patch jsonb` | Keys: registry fields (raw canonical values) plus `_title`, `_dates`; any other key → `forbidden-key`. Exception: S may patch `speaker` on a reflection whose speaker is the student (clears confirmation). Student-speaker text → `student-text-locked` for parents. Spans `{kind:'answer', by, gap_id:null}`. Reason `edit`. |
| `answer_gap` | `gap_id, value jsonb` | Raw canonical value; writes the field with `{kind:'answer', by, gap_id}`, closes the gap (`gap-not-open`). `_person` on an ingested entry refuses `ai_excluded` persons. Reason `answer`. |
| `mark_not_applicable` | `gap_id` | Reason `not_applicable`. |
| `confirm_entry` | `entry_id` | Sets `confirmed_at/by` only; `required-gap-open`, `student-must-confirm`. Reason `confirm`. |
| `bulk_confirm` | `entry_ids uuid[]` | All-or-nothing; any refusal raises its code for the first failing id. |
| `resolve_duplicate` | `entry_id, action ('keep_both','merge','discard'), picks jsonb` | `can_act('entry.resolve')` on both entries; merge rules in `rls-matrix.md` §3 (reason `merge`); discard = archive (reason `discard`). |
| `set_visibility` | `target ('post','entry'), id, visibility` | Own only. Entry: narrows freely, widens up to its post (`wider-than-post`); CHECK violations → `forbidden-visibility`. Post: narrowing narrows its entries in the same transaction (reason `visibility`) and writes `post_events`; widening a private post re-queues it only if `state='waiting'`. |
| `archive_entry` / `restore_entry` | `entry_id` | Reasons `archive` / `restore`; restore within 30 days. |
| `archive_list` | `person_id null` | Read. Archived entries the caller can read (`can_read`), with `archived_at` and days left. |
| `delete_post` | `post_id` | Own only; soft delete; `post-has-confirmed-entries` while a non-archived confirmed entry cites it; `post_events` `delete`. |
| `add_comment` | `entry_id, body` | ≤ 2000 chars. |
| `attach_file` | `entry_id, attachment_id, ext null, is_service_form bool default false` | Existing attachment → link (link rule, `forbidden-visibility`). New: object `entries/<entry_id>/<attachment_id>.<ext>` must exist (`file-missing`); size/mime from metadata (`over-limit`, tombstoned); inserts `attachments(origin='entry')` and the link. Reason `attach`. |
| `detach_file` | `entry_id, attachment_id` | Removes the link (reason `detach`); clears `attested_*` if it was `attested_attachment_id`; an attachment left with no live origin and no link is deleted and its path tombstoned. |
| `attest_service_form` | `entry_id, attachment_id` | Parents only (`parent-only`); service entry; attachment linked to it (`unknown-attachment`); sets `attested_by/at`, `attested_attachment_id`; reason `attest`. |
| `set_school_calendar` | `person_id, grade_9_start, graduation_year` | Parents only; re-derives `grade_levels` on that person's entries whose value is not answered (reason `edit`). |
| `request_output` | `person_id, kind` | Returns the open request for `(person, kind)` if one exists, else inserts. S: not recommender_pointers. |
| `cancel_output_request` | `request_id` | Requester only; `state='cancelled'`. |
| `get_output` | `output_id, version_id default null` | Read; definer. Returns `versions[]` metadata, the items whose every cite passes `entry_visible` for the caller, and `hidden_count`; writes `output_access_log` for parents_only outputs in the same transaction. Only read path for items. |
| `edit_output` | `version_id, items jsonb [{from_item_id null, position, slot, payload, cites}]` | `can_act('output.edit')`; `validate_output_items(kind, person, items, editor => auth.uid())`; items hidden from the editor are carried forward unchanged; new version `origin='edit'`, `parent_id = version_id`; `generated_payload` carried via `from_item_id`. |
| `my_queue` | — | Read; *invoker*. Open gaps on entries where `can_act('entry.answer')`, reflections awaiting S's confirmation (S only), open duplicate flags; newest first. |
| `my_badge` | — | Read; definer; `= badge_for(auth.uid())`. A parent's count excludes reflections they cannot confirm. |
| `export_person` | `person_id` | Read; *invoker*. JSON of readable rows only: person, posts, entries, versions, gaps, comments, files `[{attachment_id, object_path, mime}]` and each output via `get_output` (hiding and access log apply). The client signs paths and zips with `fflate`. |
| `signout_student` | — | Parents only. Sets `members.sessions_revoked_at = now()` for the student and best-effort deletes their `auth.sessions`; the student's next request raises `session-expired` (AD-8). |
| `set_digest_opt_in` | `bool` | Caller's own row. |
| `log_event` | `name, props` | Client allow-list `post_opened`, `post_submitted`, `queue_flushed` (`post_duration` is server-written by `create_post`); props: ≤ 8 keys, numeric or allow-listed enum values, no free text. |
| `metrics` | — | Read; owner only (`is_owner()`, else `forbidden`); returns `ll_ops.metric_*`. |
| *(password reset)* | — | Not an RPC: the parent's client calls `resetPasswordForEmail` with the student's address and `redirectTo` = the Pages origin; offered to parents only. |
| *(file links)* | — | Not an RPC: the client calls `storage.from('ledger-files').createSignedUrl(path, 600)`. |

## 5. Other executable functions (allow-list for the catalog test)

| Function | Executable by |
|---|---|
| `ll_proc.ingest_draft(jsonb)`, `ll_proc.save_output(jsonb)` | `ll_processor` only |
| `ll.badge_for(uuid)` (digest), `ll.ops_health()` (keepalive and health) | `service_role` only |
| Policy helpers `ll.member_ok`, `require_member`, `is_parent`, `is_owner`, `my_person`, `narrowest`, `can_read`, `post_visible`, `entry_visible`, `can_act`, `file_readable`, `upload_allowed` | `authenticated` (policies run as the caller); they reveal only what the caller may already know |
| Everything else (`validate_output_items`, `grade_level`, `can_act_as`, triggers, `ll_ops.*`) | nobody but the owner |
