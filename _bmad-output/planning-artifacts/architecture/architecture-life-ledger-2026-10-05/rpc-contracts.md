# RPC Contracts — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md` (AD-2, AD-3, AD-11, AD-12). JSON Schema draft 2020-12. Both processor functions take a single `jsonb` argument and validate it in SQL (with a hand-written validator or the `pg_jsonschema` extension `[ASSUMPTION: use pg_jsonschema if enabled on the project, else plpgsql checks; the schema below is normative either way]`).

## Error codes

Raised as `errcode 'P0001'`, `message = <code>`:

`invalid-payload`, `unknown-post`, `post-not-waiting`, `ai-excluded`, `private-post`, `forbidden-key`, `missing-source-span`, `unknown-type`, `unknown-field`, `bad-enum`, `person-mismatch`, `unknown-entry`, `cite-not-eligible`, `quote-mismatch`, `over-limit`, `forbidden`, `student-text-locked`, `student-must-confirm`, `required-gap-open`, `wider-than-post`, `parent-only`, `post-has-confirmed-entries`.

## 1. `ll.ingest_draft(payload jsonb) returns jsonb`

Caller: processor only (revoked from anon, authenticated). One call per post. Atomic.

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
        "required": ["ref", "person_id", "type", "title", "fields"],
        "properties": {
          "ref": { "type": "string", "pattern": "^[a-z0-9_-]{1,32}$", "description": "local id so gaps can point at it" },
          "person_id": { "type": ["string", "null"], "format": "uuid", "description": "null → server adds a '_person' gap" },
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
            "additionalProperties": {
              "type": "object",
              "additionalProperties": false,
              "required": ["v", "span"],
              "properties": { "v": {}, "span": { "$ref": "#/$defs/span" } }
            }
          },
          "attachment_ids": { "type": "array", "items": { "type": "string", "format": "uuid" } },
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
      "oneOf": [
        { "type": "object", "additionalProperties": false, "required": ["kind", "start", "end", "quote"],
          "properties": { "kind": { "const": "text" }, "start": { "type": "integer", "minimum": 0 }, "end": { "type": "integer", "minimum": 0 }, "quote": { "type": "string", "minLength": 1 } } },
        { "type": "object", "additionalProperties": false, "required": ["kind", "attachment_id", "region"],
          "properties": { "kind": { "const": "image" }, "attachment_id": { "type": "string", "format": "uuid" },
            "region": { "type": "array", "items": { "type": "number" }, "minItems": 4, "maxItems": 4 } } }
      ]
    }
  }
}
```

### Server behaviour (in order)

1. Reject any top-level or entry key not in the schema — explicitly including `status`, `visibility`, `confirmed_by`, `confirmed_at`, `id` → `forbidden-key` (FR-16 injection test).
2. Lock the post `for update`; require `state='waiting'` (`post-not-waiting`), person not `ai_excluded` (`ai-excluded`), visibility ≠ private (`private-post`).
3. For each entry: type known; every field in `entry_type_fields` for that type (`unknown-field`); enums valid (`bad-enum`); every text span's `quote` equals `substring(post.body from start+1 for end-start)` (`missing-source-span`); person_id is the post's person or another non-excluded person mentioned (allowed so one post can produce entries for both children — but `ai_excluded` persons are refused).
4. Insert entries with `created_via='ingest'`, `source_post_id`, visibility from `narrowest(type default, post.visibility)`.
5. Create gaps: server computes one gap per missing required field from the registry (using the caller's `question` when supplied for that field, else `gap_question`); caller gaps for non-required fields are kept as optional; `person_id` null → `_person` gap.
6. Insert `duplicate_flags` for entries with `possible_duplicate` (target must be readable by `processor_context`).
7. Status is derived by trigger (AD-5) — `needs_detail` if any required gap, else `draft`.
8. Set post `state='processed'`, `processed_at=now()`.

Steps 3–8 run inside a plpgsql `begin … exception` block (a subtransaction). On a validation error the block's writes roll back, the function increments `posts.attempts`, sets `state='needs_manual'` once `attempts ≥ 2`, and **returns** `{ "ok": false, "code": "<error code>", "detail": "…", "attempts": n }` instead of raising, so the failure count survives. The processing guide retries once with a corrected payload (FR-16). Errors in steps 1–2 (`forbidden-key`, `ai-excluded`, `private-post`, `post-not-waiting`) also return `ok:false` but do not count as attempts.

### Output

```json
{ "ok": true, "post_id": "uuid", "entries": [{ "ref": "a", "id": "uuid", "status": "needs_detail", "visibility": "family", "gap_count": 2 }] }
```

## 2. `ll.save_output(payload jsonb) returns jsonb`

Caller: processor only.

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
    "payload": {
      "oneOf": [
        { "title": "activity", "type": "object", "additionalProperties": false,
          "required": ["activity_type", "position", "organization", "description", "grade_levels", "timing", "hours_per_week", "weeks_per_year", "reason"],
          "properties": {
            "activity_type": { "type": "string" },
            "position": { "type": "string" }, "organization": { "type": "string" }, "description": { "type": "string" },
            "grade_levels": { "type": "array", "items": { "enum": ["9", "10", "11", "12", "PG"] } },
            "timing": { "enum": ["school_year", "break", "all_year"] },
            "hours_per_week": { "type": "number", "minimum": 0 }, "weeks_per_year": { "type": "number", "minimum": 0, "maximum": 52 },
            "reason": { "type": "string", "maxLength": 200 } } },
        { "title": "honor", "type": "object", "additionalProperties": false,
          "required": ["title", "grade_levels", "level"],
          "properties": { "title": { "type": "string" }, "grade_levels": { "type": "array", "items": { "enum": ["9", "10", "11", "12", "PG"] } },
            "level": { "enum": ["school", "state_regional", "national", "international"] }, "reason": { "type": "string", "maxLength": 200 } } },
        { "title": "pointer", "type": "object", "additionalProperties": false,
          "required": ["brag_sheet_question", "text"],
          "properties": { "brag_sheet_question": { "type": "integer", "minimum": 1, "maximum": 12 }, "text": { "type": "string", "maxLength": 600 } } },
        { "title": "angle", "type": "object", "additionalProperties": false,
          "required": ["theme", "summary", "quotes"],
          "properties": { "theme": { "type": "string", "maxLength": 80 }, "summary": { "type": "string", "maxLength": 300 },
            "quotes": { "type": "array", "items": { "type": "object", "additionalProperties": false, "required": ["reflection_id", "text"],
              "properties": { "reflection_id": { "type": "string", "format": "uuid" }, "text": { "type": "string" } } } } } }
      ]
    }
  }
}
```

### Server behaviour

1. Payload shape must match `kind` (activity ↔ activities, honor ↔ honors, pointer ↔ recommender_pointers, angle ↔ essay_angles).
2. Every cited entry: same person, `status='confirmed'`, not archived, visibility ≠ private; for kinds other than recommender_pointers, visibility ≠ parents_only; for activities, type in (activity, service, work_sample) and visibility in (family, shareable); for honors, type = honor; for essay_angles, no parent_note (`cite-not-eligible`).
3. Essay angle quotes: `reflection_id` must be cited, confirmed, speaker = student, and `text` must be an exact substring of its confirmed text (`quote-mismatch`). Summaries are capped at 300 chars and no field accepts multi-paragraph text (FR-41: no essay prose).
4. Character limits are **not** trimmed: over-limit values (position > 50, organization > 100, description > 150) are stored and flagged `over_limit: true` in `slot` (FR-38). Max 10 activities and 5 honors per version → else `over-limit`.
5. Insert `output_versions(origin='generated')` + items with `generated_payload = payload`; link and close `request_id` if given.

### Output

`{ "output_id": "uuid", "version_id": "uuid", "item_count": 10, "flags": { "over_limit": 2 } }`

## 3. Read views for the processor

- `ll.processing_queue`: `post_id, person_id, person_label, kind, body, links, attachments[{id, mime}], created_at, attempts`.
- `ll.processor_context`: `entry_id, person_id, type, title, date_start, date_end, status` — for duplicate detection.
- `ll.output_request_queue`: `request_id, person_id, kind, requested_at, eligible_entries jsonb` (pre-filtered per §2 rules).

## 4. Client RPCs (signatures)

All `security definer`, granted to `authenticated`, check role and `can_read`/edit rights, set `ll.reason`.

| RPC | Args | Notes |
|---|---|---|
| `create_post` | `id uuid, person_id uuid, kind, body, links text[], visibility, attachment_ids uuid[], opened_at timestamptz` | idempotent on id (AD-12); logs `post_duration` |
| `create_milestone` | `person_id, title, date, attachment_id` | Y only; created confirmed (FR-17) |
| `edit_entry` | `entry_id, patch jsonb` | field-level; span set to `{kind:'answer'}` + `by` |
| `answer_gap` | `gap_id, value jsonb` | writes field, closes gap |
| `mark_not_applicable` | `gap_id` | |
| `confirm_entry` | `entry_id` | |
| `bulk_confirm` | `entry_ids uuid[]` | all-or-nothing; skips none silently |
| `resolve_duplicate` | `entry_id, action ('keep_both','merge','discard'), picks jsonb` | merge rules FR-18 |
| `set_visibility` | `target ('post','entry'), id, visibility` | AD-4 |
| `archive_entry` / `restore_entry` | `entry_id` | |
| `delete_post` | `post_id` | |
| `add_comment` | `entry_id, body` | |
| `attest_service_form` | `entry_id, attachment_id` | parent only |
| `request_output` | `person_id, kind` | |
| `edit_output` | `version_id, items jsonb` | new version, `origin='edit'` |
| `get_output` | `output_id, version_id default null` | returns items + `hidden_count`; logs access for parents_only |
| `my_queue`, `my_badge` | — | FR-23, FR-24 |
| `file_url` | `attachment_id` | 600 s signed URL |
| `export_person` | `person_id` | JSON; files listed with signed URLs |
| `signout_student` | — | parents only. Deletes the student's `auth.sessions` / refresh tokens and sets `members.sessions_revoked_at = now()`; the role helpers reject any JWT whose `iat` is earlier, so already-issued access tokens stop working on the next request (FR-3). |
| *(password reset)* | — | not an RPC: the parent's client calls Supabase Auth `resetPasswordForEmail` with the student's address; the UI offers it to parents only. |
| `set_digest_opt_in` | `bool` | |
| `log_event` | `name, props` | allow-listed names |
