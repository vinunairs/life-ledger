# RLS Policy Matrix and Test Cases — Family Life Ledger v1

Companion to `ARCHITECTURE-SPINE.md` (AD-2, AD-4, AD-9). Reads are enforced by RLS SELECT policies; writes by RPC checks (no client write policies exist). Every row below is a pgTAP test in `supabase/tests/`, run as each role with `set local role authenticated; set local request.jwt.claims = '{"sub": "<uuid>"}'`.

Actors: **PA** = Parent A (owner, parent_admin), **PB** = Parent B (parent_admin), **S** = the student (student_owner, person = S), **Y** = the younger child (person only, `ai_excluded`), **Anon** = signed out, **Proc** = processor (connector's privileged role).

## 1. Readability predicate

`can_read(visibility, author_id, person_id)`:

| Visibility | PA | PB | S | Anon |
|---|---|---|---|---|
| private | only if author | only if author | only if author | no |
| family | yes | yes | yes (incl. Y's family rows, read-only) | no |
| parents_only | yes | yes | **never** | no |
| shareable | yes | yes | yes | no |

Plus: archived rows are visible only through the archive list (`archived_at is not null` requires an explicit `ll.archive_list()` call, readable by whoever could read the row).

## 2. Read policies by table

| Table | Policy |
|---|---|
| persons | any member can read all persons |
| members | own row; parents read all |
| posts | `can_read(visibility, author_id, person_id)` and not deleted |
| attachments | readable if its post or entry is readable |
| entries | `can_read(...)` and `archived_at is null` |
| gaps, comments, duplicate_flags, entry_versions | readable if the entry is readable |
| outputs / output_versions / output_items | `can_read(outputs.visibility, null, person_id)`; items further filtered by `get_output` (AD-11) |
| output_requests | parents all; S own person, kinds ≠ recommender_pointers |
| output_access_log, events | owner only |
| processing_queue, processor_context, output_request_queue | no grant to anon/authenticated |
| storage `ledger-files` | via attachments readability |

## 3. Action matrix (RPC checks) — PRD FR-6

| RPC | PA / PB on S | PA / PB on Y | S on S | S on Y | PA on PB's private |
|---|---|---|---|---|---|
| create_post / create_entry | ✓ | ✓ (manual milestone only) | ✓ | ✗ `forbidden` | n/a |
| edit_entry (facts) | ✓ | ✓ | ✓ | ✗ | ✗ |
| edit_entry (reflection text, speaker = student) | ✗ `student-text-locked` | n/a | ✓ | ✗ | ✗ |
| add_comment | ✓ | ✓ | ✓ | ✗ | ✗ |
| confirm_entry (facts) | ✓ | ✓ | ✓ | ✗ | ✗ |
| confirm_entry (reflection, speaker = student) | ✗ `student-must-confirm` | n/a | ✓ | ✗ | ✗ |
| set_visibility | own posts / entries from own posts | own | own | ✗ | ✗ |
| archive_entry | ✓ | ✓ | own posts' entries | ✗ | ✗ |
| answer_gap / mark_not_applicable | entries they can edit | ✓ | own | ✗ | ✗ |
| resolve_duplicate | ✓ | ✓ | own | ✗ | ✗ |
| attest_service_form | ✓ | n/a | ✗ `parent-only` | ✗ | n/a |
| request_output | ✓ all kinds | ✗ (Y has no outputs) | ✓ except recommender_pointers | ✗ | n/a |
| edit_output | ✓ (visible kinds) | ✗ | ✓ except recommender_pointers | ✗ | n/a |
| send_student_reset / signout_student | ✓ | n/a | ✗ | n/a | n/a |
| export_person | ✓ | ✓ | own, excluding parents_only | ✗ | n/a |

## 4. Test cases

Naming: `rls_<area>_<nn>`. Each test seeds fixtures with role labels only.

### Must-never (release blockers, NFR-SEC-1)
| ID | As | Action | Expect |
|---|---|---|---|
| rls_never_01 | S | `select * from` every table and view in `ll` | zero rows with visibility = parents_only, zero parent_note rows |
| rls_never_02 | S | `get_output` on recommender_pointers | `forbidden`, no items |
| rls_never_03 | S | signed URL for a file attached only to a parents_only entry | `forbidden` |
| rls_never_04 | S | read `entry_versions` of a parents_only entry | zero rows |
| rls_never_05 | PA, PB | `confirm_entry` on reflection with speaker = student created by PB | `student-must-confirm`; status unchanged |
| rls_never_06 | PA | `edit_entry` changing reflection text where speaker = student | `student-text-locked` |
| rls_never_07 | PA | read S's private post / entry | zero rows |
| rls_never_08 | S | read PA's private post | zero rows |
| rls_never_09 | Anon | any select, any RPC | zero rows / permission denied |
| rls_never_10 | authenticated (any) | call `ingest_draft`, `save_output`, select `processing_queue` | permission denied |
| rls_never_11 | Proc | `processing_queue` contains a Y post or a private post | never |
| rls_never_12 | Proc | `ingest_draft` with a Y post id or private post id | `ai-excluded` / `private-post` |

### Visibility rules
| ID | Case | Expect |
|---|---|---|
| rls_vis_01 | ingest parent_note from a family post | entry visibility parents_only |
| rls_vis_02 | ingest activity from a parents_only post | entry visibility parents_only (narrowest) |
| rls_vis_03 | set_visibility score → shareable | `check-violation` |
| rls_vis_04 | set_visibility widen entry beyond its post | `wider-than-post` |
| rls_vis_05 | narrow an entry cited by an activities output | S sees "1 item hidden" in every version (FR-7) |
| rls_vis_06 | S reads Y's family milestone | visible, all RPCs on it refused |
| rls_vis_07 | timeline as S contains PA's parents_only post | no |

### Action matrix
One test per ✓/✗ cell in §3: `rls_act_<rpc>_<actor>_<target>`. ✓ cells assert success and a new `entry_versions` row with the right `reason`; ✗ cells assert the listed error code and no row change.

### Lifecycle
| ID | Case | Expect |
|---|---|---|
| rls_life_01 | archived entry | invisible in timeline, profile, outputs; visible in archive list |
| rls_life_02 | purge after 30 days | entry, versions, gaps, sole-attached files gone; citing output_items redacted in all versions |
| rls_life_03 | delete post with confirmed entry | `post-has-confirmed-entries` |
| rls_life_04 | delete file with is_service_form | entry loses verified hours |
