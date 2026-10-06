# RLS Policy Matrix and Test Cases — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md` (AD-2, AD-4, AD-8, AD-9, AD-11, AD-17). Reads are enforced by RLS SELECT policies; writes only by client RPCs that call `ll.require_member()` then `ll.can_act(...)` (no client write policies or write grants exist). Every row below is a pgTAP test in `supabase/tests/`, run as `set local role authenticated; set local request.jwt.claims = '{"sub":"<uuid>","session_id":"<uuid>"}'` with a matching `auth.sessions` fixture row.

Actors: **PA** = Parent A (owner, parent_admin), **PB** = Parent B (parent_admin), **S** = the student (student_owner, person = S), **Y** = the younger child (person only, `ai_excluded`), **NM** = authenticated user with no `members` row, **Anon** = signed out, **Proc** = role `ll_processor` (`set local role ll_processor`).

## 1. Predicates

Visibility order: `private < parents_only < family < shareable` (enum order; `narrowest = least`).

`ll.can_read(visibility, author_id)` — first requires `ll.member_ok()` (members row + live session, AD-8); otherwise false for every row:

| Visibility | PA | PB | S | NM / Anon |
|---|---|---|---|---|
| private | only if `author_id = auth.uid()` | only if author | only if author | no |
| parents_only | yes | yes | **never** | no |
| family | yes | yes | yes (incl. Y's family rows, read-only) | no |
| shareable | yes | yes | yes | no |

- `ll.entry_visible(entry_id)` = `can_read(e.visibility, e.author_id)` ∧ `e.archived_at is null`.
- `ll.post_visible(post_id)` = `can_read(p.visibility, p.author_id)` ∧ `p.deleted_at is null`.
- Archived entries are reachable only through `ll.archive_list()`, which returns rows passing `can_read` (readability of the archived row, as for `restore`).
- A student can never choose `parents_only` (`create_post`, `create_entry`, `set_visibility` → `forbidden-visibility`).

## 2. Read policies and grants by object

`authenticated` gets `SELECT` only on the objects listed with a policy here; `anon` gets nothing in any schema.

| Object | Grant | Policy |
|---|---|---|
| persons | select | `member_ok()` |
| members | select on `(user_id, role, person_id, display_label, is_owner, digest_opt_in, last_person_id)` | `member_ok()` (labels for "captured by", FR-21) |
| posts | select | `post_visible(id)` |
| post_events | select | `post_visible(post_id)` |
| entries | select | `entry_visible(id)` |
| gaps, comments, entry_versions, entry_attachments | select | `entry_visible(entry_id)` |
| duplicate_flags | select | `entry_visible(entry_id) and entry_visible(duplicate_of)` |
| attachments | select | `(post_id is not null and post_visible(post_id))` or a link whose `entry_visible` |
| entry_types, entry_type_fields, enum_values | select | `member_ok()` |
| outputs | select (metadata only, no payload columns exist) | `can_read(visibility, null)` |
| output_requests | select | `can_read(case kind when 'recommender_pointers' then 'parents_only' else 'family' end, null)` |
| output_versions, output_items, output_access_log, events | **none** | — (read only through `get_output`, `metrics`) |
| views `timeline`, `profile_summary`, `service_hours` | select | `security_invoker = true`; underlying policies apply |
| `ll_proc.*`, `ll_ops.*` | **none** (no schema usage) | — |
| storage `ledger-files` | — | SELECT `ll.file_readable(name)`; INSERT `ll.upload_allowed(name)`; no UPDATE/DELETE |

## 3. Action predicate — `ll.can_act(action, target)` (PRD FR-6)

Every client RPC resolves its target (entry, gap → entry, comment → entry, attachment → entry, post, person, output) and calls `can_act`. `can_act` always ANDs `entry_visible` (or `post_visible`) of the target, except `entry.restore`, which ANDs readability of the archived row. When it is false the RPC raises `forbidden` if the target is not visible, else the cell's code. Queues and badges filter with `can_act('entry.answer', …)`. Each cell is a test vector.

"Profile" = `entry.person_id`. "Own" = `author_id = auth.uid()` (AD-4.4).

| Action (RPC) | PA / PB on S | PA / PB on Y | S on S | S on Y | anyone on another's private |
|---|---|---|---|---|---|
| `person.create_post` (create_post) | ✓ | ✗ `ai-excluded` (use milestone) | ✓ (no parents_only) | ✗ `forbidden` | n/a |
| `person.create_milestone` | ✗ `forbidden` | ✓ | ✗ | ✗ | n/a |
| `post.create_entry` / `person.create_entry` (create_entry) | ✓ | ✗ (milestone only) | ✓ (no parents_only) | ✗ | ✗ |
| `entry.edit` (facts, edit_entry) | ✓ | ✓ | ✓ | ✗ | ✗ |
| `entry.edit_student_text` (reflection text / speaker where speaker = student) | ✗ `student-text-locked` | n/a | ✓ | ✗ | ✗ |
| `entry.comment` (add_comment) | ✓ | ✓ | ✓ | ✗ | ✗ |
| `entry.confirm` (facts; confirm_entry, bulk_confirm) | ✓ | ✓ | ✓ | ✗ | ✗ |
| `entry.confirm` (reflection, speaker = student) | ✗ `student-must-confirm` | n/a | ✓ | ✗ | ✗ |
| `entry.answer` (answer_gap, mark_not_applicable) | ✓ | ✓ | ✓ | ✗ | ✗ |
| `entry.set_visibility`, `post.set_visibility` | own only | own only | own only | ✗ | ✗ |
| `entry.archive`, `entry.restore` | ✓ | ✓ | own only | ✗ | ✗ |
| `post.delete` (delete_post) | own only | n/a | own only | ✗ | ✗ |
| `entry.resolve` (resolve_duplicate) — required on **both** entries | ✓ | n/a | ✓ | ✗ | ✗ |
| `entry.attach`, `entry.detach` (attach_file, detach_file) | ✓ | ✓ | ✓ | ✗ | ✗ |
| `entry.attest` (attest_service_form) | ✓ | n/a | ✗ `parent-only` | ✗ | n/a |
| `person.request_output` | ✓ all kinds | ✗ (Y has no outputs) | ✓ except recommender_pointers | ✗ | n/a |
| `output.edit` (edit_output) | ✓ | n/a | ✓ except recommender_pointers | ✗ | n/a |
| `person.set_school_calendar`, `signout_student` | ✓ | ✓ (calendar) | ✗ `parent-only` | ✗ | n/a |
| `person.export` (export_person) | ✓ readable rows only | ✓ readable rows only | ✓ readable rows only | ✗ | ✗ |

### Duplicate and merge rules (FR-18)
- A flag is valid only when both entries have the same person, type and visibility (and, for private, the same author); the trigger and `ingest_draft` refuse others (`duplicate-not-eligible`).
- `resolve_duplicate` requires `can_act('entry.resolve', …)` on both entries. Merge keeps the older entry; merged visibility = `narrowest(a, b)`; values go through the `edit_entry` field-write path (so `student-text-locked` applies); a merge of reflections with speaker = student is allowed only for S; any value from an unconfirmed source clears `confirmed_at` (reason `merge`). `discard` = archive (reason `discard`).

### File link rules (AD-17)
- A link `entry_attachments(entry, attachment)` is allowed only when `entry.person_id = attachment.person_id` and `entry.visibility ≤ attachment.origin_visibility` (same author if private). Otherwise `forbidden-visibility`.
- `ingest_draft` links only attachments of the post being ingested (`unknown-attachment`).
- `attest_service_form` requires the attachment to be linked to that entry; it records `attested_attachment_id`. `detach_file` of that attachment clears the attestation (reason `detach`).

## 4. Test cases

Naming: `rls_<area>_<nn>`. Fixtures use role labels only.

### Must-never (release blockers, NFR-SEC-1)
| ID | As | Action | Expect |
|---|---|---|---|
| rls_never_01 | S | `select * from` every granted table and view in `ll` | zero parents_only rows, zero parent_note rows, zero of PA's/PB's private rows |
| rls_never_02 | S | `get_output` on recommender_pointers | `forbidden`, no items |
| rls_never_03 | S | `createSignedUrl` for a file linked only to a parents_only entry | storage denies (no SELECT) |
| rls_never_04 | S | read `entry_versions` of a parents_only entry | zero rows |
| rls_never_05 | PA, PB | `confirm_entry` on reflection with speaker = student created by PB | `student-must-confirm`; status unchanged |
| rls_never_06 | PA | `edit_entry` changing reflection text where speaker = student | `student-text-locked` |
| rls_never_07 | PA | read S's private post / entry | zero rows |
| rls_never_08 | S | read PA's private post | zero rows |
| rls_never_09 | Anon | any select, any RPC, any storage read or upload | permission denied |
| rls_never_10 | authenticated (any) | call `ll_proc.ingest_draft`, `ll_proc.save_output`; select `ll_proc.processing_queue` | permission denied (no schema usage) |
| rls_never_11 | Proc | `processing_queue` in either run class contains a Y post or a private post | never |
| rls_never_12 | Proc | `ingest_draft` with a Y post id or private post id | `{ok:false}` `ai-excluded` / `private-post` |
| rls_never_13 | catalog | every view in `ll` has `security_invoker=true`; as S, every view returns no parents_only row | pass |
| rls_never_14 | catalog | `has_function_privilege('anon'\|'authenticated', f, 'execute')` is true only for the allow-list in `rpc-contracts.md` §4/§5 | pass |
| rls_never_15 | S | `create_post` with the id of a parents_only post | `id-conflict`, no row returned |
| rls_never_16 | S, PA | `select * from ll.output_items` / `output_versions`; then narrow a cite and call `get_output` on every version | permission denied; item hidden in every version, `hidden_count` = 1 |
| rls_never_17 | S | `my_queue` with a gap on a parents_only entry about S; `answer_gap` on it | gap absent; `forbidden` |
| rls_never_18 | Proc, PA | ingest a duplicate flag across visibility classes; merge a parents_only draft into a family entry | `duplicate-not-eligible`; flag refused by trigger; no field becomes wider |
| rls_never_19 | Proc, PA | ingest with an `attachment_id` from another post; `attest_service_form` / `attach_file` linking a parents_only post's file to a family entry | `unknown-attachment`; `forbidden-visibility` |
| rls_never_20 | Proc | `processing_queue` rows with null person; `select from ll.posts` | none (column not null); permission denied |
| rls_never_21 | PA | narrow a family post to parents_only | its family entries are parents_only in the same transaction, versioned `visibility`; S reads none |
| rls_never_22 | PA | `edit_entry` with `speaker`, `type`, `person_id` or `visibility` keys | `forbidden-key` |
| rls_never_23 | NM | every select, every client RPC, every storage upload | zero rows; `not-a-member`; upload denied |
| rls_never_24 | S | session created > 30 days ago, or before `sessions_revoked_at` (also after a token refresh) | zero rows; RPCs raise `session-expired` |

### Visibility rules
| ID | Case | Expect |
|---|---|---|
| rls_vis_01 | ingest parent_note from a parent's family post | entry visibility parents_only |
| rls_vis_02 | ingest activity from a parents_only post | parents_only (narrowest) |
| rls_vis_03 | set_visibility score → shareable | `forbidden-visibility` |
| rls_vis_04 | set_visibility widen entry beyond its post | `wider-than-post` |
| rls_vis_05 | narrow an entry cited by an activities output | S sees "1 item hidden" in every version (FR-7) |
| rls_vis_06 | S reads Y's family milestone | visible; every RPC on it refused |
| rls_vis_07 | timeline as S contains PA's parents_only post | no |
| rls_vis_08 | S calls create_post / create_entry / set_visibility with parents_only | `forbidden-visibility` |
| rls_vis_09 | `duplicate_flags.reason` where one side is not readable | row not returned |

### Action matrix
One test per cell in §3: `rls_act_<action>_<actor>_<target>`. ✓ cells assert success and exactly one new `entry_versions` row with the right `reason` (or a `post_events` row); ✗ cells assert the listed code and no row change.

### Lifecycle
| ID | Case | Expect |
|---|---|---|
| rls_life_01 | archived entry | invisible in timeline, profile, outputs, child tables; visible in `archive_list` |
| rls_life_02 | purge after 30 days | entry, versions, gaps, comments, flags (both sides), links gone; orphaned attachments deleted and paths in `ll_ops.object_tombstones`; citing `output_items` redacted (`payload`, `generated_payload`, `slot.theme`) in every version; no purged string anywhere in `ll` |
| rls_life_03 | delete post with a non-archived confirmed entry | `post-has-confirmed-entries` |
| rls_life_04 | `detach_file` of the attested service form | `attested_*` cleared; `service_hours` drops verified hours |
| rls_life_05 | soft-deleted post with no entries, 31 days later | hard-deleted with its post_events; attachments tombstoned |
