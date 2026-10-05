# Adversarial Review — Architecture Spine, Family Life Ledger v1

- **Reviewed:** `ARCHITECTURE-SPINE.md` (AD-1 … AD-16) with `data-model.md`, `rls-matrix.md`, `rpc-contracts.md`, `offline-queue.md` (`test-plan.md` for cross-checks), against `prds/prd-life-ledger-2026-10-05/prd.md`.
- **Method:** I built pairs of units one level down (stories or epics owned by different developers). Each unit follows every AD to the letter, and the pair still ends up incompatible or leaks data. I also checked the security-definer and view mechanics against how Postgres and Supabase actually behave, and checked the spine against its companions.
- **Reviewer stance:** adversarial. I assume a curious student with a valid JWT, an imperfect processor (a model with the full queue in context) and two developers who never talk to each other.
- **Date:** 2026-10-05

## Verdict

The paradigm is sound: rules live in Postgres, writes go through RPCs, and there is one readability predicate. As written, though, the spine leaves several ordinary Postgres behaviours to chance, and each one breaks a release-blocker privacy promise:

- Views run as their owner.
- Function `EXECUTE` is granted to `PUBLIC`.
- Security-definer functions bypass RLS.
- Storage is written directly by the client.

The spine also has no single *action* predicate to match its single *readability* predicate. And its processor isolation (AD-9) depends on a connector that, by the PRD's own admission (§6.2), has full database access. **Seven critical findings must be closed before any story that touches RLS, views, outputs or ingest is started.**

Severity key:
- **Critical:** a student can read parents_only or private data, the younger child's data or a private post reaches the processor, or a client can call a processor function.
- **High:** two compliant units build incompatibly in a way that corrupts history or status or weakens a privacy rule, or a mandated mechanism is not feasible on Supabase.
- **Medium:** divergence that causes rework or a narrow leak that needs a second mistake.
- **Low:** hygiene.

---

## Critical

### C-1 — Views bypass RLS: `timeline`, `service_hours`, `metric_*` (and processor views if any grant slips) run as the view owner

**Pair:**
- **Story A** (M1 timeline, FR-26) writes `create view ll.timeline as select … from ll.posts p left join ll.entries e …` and grants `select` to `authenticated`, because the data model says "Reader: authenticated (RLS)".
- **Story B** (M1 RLS) writes perfect SELECT policies on `posts` and `entries`.

Both follow AD-2 and AD-4. But a Postgres view without `security_invoker = true` runs with its **owner's** privileges. The owner is `postgres`, which owns the tables and has `BYPASSRLS` on Supabase. So the student's `select * from ll.timeline` returns every post and entry, including parents_only rows, the parents' private posts and parent notes.

`service_hours` has the same flaw: it leaks all service entries, including private ones. The `metric_*` views would expose everything to anyone granted `select`.

**Second path:** `_04_rls.sql` is likely to contain `grant select on all tables in schema ll to authenticated`, the usual Supabase idiom. If anyone reruns it after `_06_processor.sql`, or adds `alter default privileges … grant select on tables`, then `processing_queue`, `processor_context` and `output_request_queue` become readable by the student. Grants on "all tables" include views. Because those views run as owner, the student gets every waiting parents_only post body and every parents_only entry title.

`rls_never_01` would catch this only if its fixtures put parents_only rows behind every view. The spine never states the rule, so a developer has nothing to follow.

**Add AD-17 — View security:**
- Every view in a schema exposed to PostgREST is created `with (security_invoker = true)`, so the RLS of the underlying tables applies to the caller.
- Views that must see across RLS (the processor views and the `metric_*` views) live in separate schemas that are **not exposed** to the Data API: `ll_proc` and `ll_ops`. Clients get no `usage` on those schemas.
- `grant … on all tables in schema` is forbidden. Every grant names its object.
- A pgTAP catalog test fails CI if any view in `ll` lacks `security_invoker=true` in `pg_class.reloptions`, or if `anon` or `authenticated` hold any privilege in `ll_proc` or `ll_ops`.

### C-2 — `revoke … from anon, authenticated` does not revoke: functions are executable by `PUBLIC` by default

AD-3 says `ingest_draft` and `save_output` "are `revoke`d from `anon` and `authenticated`". In Postgres, `CREATE FUNCTION` grants `EXECUTE` to `PUBLIC`. Revoking from the two named roles leaves the `PUBLIC` grant in place, so both roles can still execute the function.

`ll` must be exposed to PostgREST for the client RPCs to work. That makes every function in `ll` callable at `/rest/v1/rpc/<name>` by any signed-in user, and by `anon` too. The affected functions:

- **`ingest_draft`:** the student can "process" any waiting post, including a parents_only one. He chooses titles, fields, `possible_duplicate` targets and `attachment_ids`. The response returns entry ids and visibilities.
- **`save_output`:** the student can write recommender_pointers or essay_angles versions.
- **`purge_expired`, `status_sweep`, `nightly_accuracy_check`:** ops functions callable by clients.

AD-2 has the same gap: "granted to `authenticated` only" is not true unless `PUBLIC` is revoked first.

Whether the processor functions are security definer is also ambiguous. AD-3 says they "run as the connector's privileged role". If a developer marks them `security definer` (the house style in AD-2), the `PUBLIC` grant becomes a full privilege escalation.

**Tighten AD-2 and AD-3:**
- Each migration that creates functions in a client-reachable schema starts with:
  - `alter default privileges in schema ll revoke execute on functions from public;`
  - one explicit `revoke all on function … from public, anon, authenticated` followed by `grant execute … to authenticated` for each client RPC.
- Processor functions live in `ll_proc`, are **`security invoker`**, and begin with `if current_user not in ('ll_processor','postgres') then raise …`. Because no client write policies exist, an invoker function called by `authenticated` fails closed even if a grant slips.
- Trigger functions and ops functions get no `EXECUTE` grant for clients.
- A pgTAP catalog test asserts `has_function_privilege('authenticated', f, 'execute')` is true **only** for the RPCs listed in `rpc-contracts.md` §4, and false for `anon` on everything.

### C-3 — `create_post` returns the existing row "either way": a known post id reads any post

AD-12 says `create_post(id, …)` is `insert … on conflict (id) do nothing` and **returns the row either way**. `create_post` is security definer, so the student who calls `create_post(<id of a parents_only or private post>, …)` gets that row back, body included. The spine never says the RPC re-checks `can_read` or `author_id = auth.uid()` on conflict.

How the student learns the id, using only compliant units:

- `entries.source_post_id` on any entry he can read. H-1 shows family entries can outlive their post being narrowed to parents_only, because there is no cascade.
- `span.post_id` inside `entries.fields`. After a merge (FR-18) combines spans, these can include spans from a parents_only post (see C-4).
- Object paths `posts/<post_id>/…` of files he can read.

**Tighten AD-12:**
- On conflict, `create_post` returns the row only when `author_id = auth.uid()` **and** the stored `(person_id, kind, body)` equal the arguments.
- Any other conflict raises `id-conflict` and returns nothing.
- Add `id-conflict` to the error list.
- General rule for every security-definer RPC: a function never returns a row the caller could not `select` under RLS (see H-13).

### C-4 — Duplicate flags and merges cross visibility boundaries

**Pair:**
- **Unit A** (M1 ingest): `processor_context` contains parents_only entries, because it filters only private posts and ai-excluded persons. Ingest step 6 accepts any `of_entry_id` that is "readable by `processor_context`". So a family draft from the student's post can be flagged as a duplicate of a parents_only parent note or entry.
- **Unit B** (M1 review): `duplicate_flags` is "readable if the entry is readable". The entry here is the *new* family draft. `rls-matrix` §3 lets the student `resolve_duplicate` on his own entries.

Results:
1. The student reads `duplicate_of` (a parents_only entry id, which feeds C-3) and `reason`. `reason` is model-written free text such as "Same event as the parent note about the regional piano anxiety". That is a direct content leak.
2. The student taps **Merge**. FR-18 says "merge keeps the older entry". If the older entry is the parents_only one, the student has written into an entry he cannot read, and `picks` may echo its values back to him in the RPC result. If the older entry is family and the newer one is parents_only (a parent's parents_only post produced a duplicate of the student's family entry), a parent's merge moves parents_only fields, spans and files **into the family entry**, and the student can read all of it. Two developers will implement merge visibility differently, because the rule says only "keeps the older entry".
3. Merge also combines spans, so family entries end up holding `post_id`s of parents_only posts (feeds C-3).

**Tighten AD-4 and FR-18 handling, adding a clause to AD-11 or a new AD-18:**
- A duplicate flag is valid only when both entries have the **same person, type and visibility**. `ingest_draft` returns `cite-not-eligible` otherwise.
- `processor_context` exposes duplicate candidates per visibility class, so a family draft never sees a parents_only candidate.
- `resolve_duplicate` requires `can_act('resolve', e)` on **both** entries.
- The merged entry's visibility is `narrowest(a, b)`.
- `duplicate_flags.reason` is readable only by logins who can read both entries.

### C-5 — `output_items` (and `output_versions`) are directly selectable, which bypasses AD-11's per-item hiding and FR-37's access log

**Pair:**
- **Unit A** (M3 outputs data) follows `data-model.md` and `rls-matrix` §2: `outputs / output_versions / output_items` readable by `can_read(outputs.visibility, null, person_id)`, with "items further filtered by `get_output`".
- **Unit B** (M3 activities screen) is told by AD-11 that "clients read outputs only through `ll.get_output`".

A table policy cannot "further filter" anything. So the student runs `select payload, generated_payload, cites from ll.output_items` on the family activities output and gets **every item in every version**. That includes items citing entries that have since been narrowed to parents_only or private, which FR-7 says must be hidden. A parent running the same query on recommender_pointers reads them without writing `output_access_log`, which breaks FR-37 and NFR-AUD-1.

AD-4 ("output items … call `can_read` via the owning row") and AD-11 ("only through `get_output`") contradict each other. This is where it surfaces.

**Tighten AD-11:**
- `output_items` and `output_versions` have **no** SELECT policy for `authenticated`, and no grant.
- The only read path is `get_output`, which applies the cite filter, writes the access log and returns `hidden_count`.
- `outputs` keeps a policy for listing only, with metadata and no payloads.
- `rls_never_01` adds `output_items` as a table that must return zero rows for every client role.

### C-6 — There is one readability predicate but no action predicate, so gap questions, queue items and blind writes leak across `parents_only`

The rls-matrix action cells use undefined terms: "entries they can edit", "own", "own posts / entries from own posts". AD-4 defines `can_read` only. Each RPC developer therefore writes their own check, usually role plus person. For example: "S on S ✓" means `my_person() = entry.person_id`.

Pair:
- **`my_queue` / `my_badge`** (FR-23/24). The developer lists "open gaps across entries the caller can edit" with `my_person() = e.person_id`. That includes a **parents_only** entry about the student, created from a parent's parents_only post. The student's queue then shows its gap question. Gap questions are written by the processor from the post body: "How many sessions with the tutor did Parent B mention?". The student can answer it, which writes into an entry he cannot read.
- **`add_comment`, `edit_entry`, `confirm_entry`, `archive_entry`, `resolve_duplicate`** built with the same role-plus-person check accept entry ids the caller cannot read. Being security definer, they return or version data. `entry_versions.before/after` are then visible to whoever reads the entry later.

**Add to AD-4:**
- `ll.can_act(action text, entry_id uuid) returns boolean` is the single action predicate. It encodes the FR-6 matrix and **always ANDs** `can_read` of the row, including `archived_at is null` except for `restore`.
- Every client RPC that takes an entry, gap, comment, attachment or output id resolves it to its entry or output and calls `can_act` before anything else, raising `forbidden`.
- Queue and badge queries filter with `can_act('answer', e.id)`.
- The rls-matrix columns become `can_act` test vectors.

### C-7 — AD-9's processor isolation is not enforceable, and person-null and multi-child posts carry the younger child's data to the model anyway

**(a) Isolation is guide-only.** AD-3 and AD-9 talk as if the processor "reads only" three views. PRD §6.2 states the opposite: *"The connector has full database access, so safety cannot rely on the connector."* With the standard Supabase connector (Management API, project-wide SQL), the processing run can `select * from ll.posts where person_id = <Y>` or read private posts, and only the guide stops it. "The processor must never be given a broader view" is therefore a wish, not an invariant. A future guide edit or an injected instruction ("also list all posts to find context") breaks the PRD §6.1 promise that the younger child's data is never sent to the model.

**(b) Filters key off `posts.person_id`, not content.**
- `posts.person_id` may be null, which creates the "Who is this about?" gap. `processing_queue` excludes only posts "whose person is ai_excluded", and a null person is not excluded. A parent who forgets the picker posts "Y won the school spelling bee", and the post goes to the model.
- A post about the student that mentions the younger child ("S and Y both played at the recital; Y took first") goes to the model in full. The PRD (FR-16, "post mentions both children → separate entries per person") and AD-9 conflict here. Ingest refuses Y entries, but the text has already been sent.
- An entry extracted from a null-person post can have its `_person` gap answered with Y. That creates an AI-extracted entry about the younger child, which FR-17 forbids (manual milestones only).

**Tighten AD-9 and add an ops requirement:**
1. Create a dedicated Postgres login role `ll_processor` (`noinherit`, no `bypassrls`). Grant it `usage` on `ll_proc` only, `select` on the three views and `execute` on the two functions. The scheduled task connects with **that role's** connection string (for example a Postgres MCP server configured with the role, or a Supabase connector in read-only mode scoped to the role), **not** the owner's full-access Management connector. Record the residual risk in the spine if the owner keeps the full connector.
2. `processing_queue` excludes posts with `person_id is null`. The client asks "Who is this about?" on the post before it can be processed, which is a post-level person gap, not an entry gap.
3. `answer_gap('_person', …)` refuses `ai_excluded` persons for `created_via='ingest'` entries (`ai-excluded`).
4. Mixed-child posts: the post screen warns when the younger child is picked alongside text about the student. The PRD should note that one post with both children reaches the model; take this back to the PM as a requirement clarification.
5. Put `person_label` in `processing_queue` only as a role label ("Student"), never `display_label` (the real name).

---

## High

### H-1 — Narrowing a post does not cascade to its entries or files

AD-4 controls widening an *entry* relative to its post but says nothing about **narrowing the post**.

**Pair:**
- **Unit A** (set_visibility on posts) narrows `posts.visibility` from family to parents_only.
- **Unit B** (processing, already done) created family entries from that post.

Those entries stay family, now wider than their post. That violates FR-5 ("never more visible than the post it came from"). Their spans quote the post body, so the student still reads the text the parent just tried to hide, and their `source_post_id` feeds C-3.

**Tighten AD-4:**
- `set_visibility('post', …)` to a narrower level also narrows every entry from that post to `narrowest(entry, post)`, in the same transaction and versioned with reason `visibility`.
- Add `visibility` to the `ll.reason` list in AD-7. It is missing even though `set_visibility` must version.
- Add an invariant check `entries.visibility ≤ posts.visibility` to `status_sweep` or `nightly_accuracy_check`.

### H-2 — Attachment shape clash and the storage OR-rule leak

1. **Shape clash.** `attachments` has a single `entry_id`. Ingest gives each entry `attachment_ids`, and FR-18 merge "combines files". When one post with one certificate photo produces an honor entry and an activity entry, Developer A overwrites `attachments.entry_id`, which silently moves the file off the first entry. Developer B inserts a second `attachments` row with the same `object_path` and violates `unique(object_path)`. Purge's "files attached only to them" cannot be computed reliably under either design.
2. **OR-rule leak.** The storage policy allows a read when "an attachments row exists whose post **or** entry the caller can read". Three compliant paths attach a file from a narrower origin to a wider entry:
   - `ingest_draft` accepts any `attachment_ids`, for example the photo from a parents_only post or the younger child's milestone photo, and links them to a family entry. The spec never limits them to the post's own attachments.
   - `attest_service_form(entry_id, attachment_id)` accepts any attachment.
   - Merge combines files.

   The student then reads the file through the family entry, which defeats `rls_never_03`.

**Tighten AD-4 and FR-30, adding AD-19 Files:**
- Replace `attachments.entry_id` with a join table `entry_attachments(entry_id, attachment_id)`. `attachments.origin` is either `post_id` or an entry.
- Linking an attachment to an entry is allowed only when everyone who can read the entry could already read the attachment's origin: same person, `entry.visibility ≤ origin visibility`, and the same author when private. `ingest_draft` may link only attachments of the post being ingested (`unknown-attachment` otherwise).
- File readability stays one predicate: `can_read` on the origin, or on a linked entry.

### H-3 — Direct storage writes reopen the write path AD-2 closed (upsert, overwrite, existence check)

- `offline-queue.md` uploads with `upsert: true`. In Supabase Storage, upsert requires **UPDATE** (and SELECT) policies on `storage.objects`, so the upload policy must allow updates under `posts/{id}/` for the post's author. The author can then **overwrite** a photo's bytes after confirmation, or swap a signed service form after a parent attested it (FR-32). No version is written, which bypasses AD-7 and NFR-AUD-1.
- The upload rule "a post id **not yet existing** or authored by the caller" is evaluated as the invoker. Under RLS, a parents_only or private post the student cannot read looks *not existing*, so the student may upload into, and with upsert overwrite inside, `posts/<their post>/`.
- Client-reported `mime`/`bytes` feed the `attachments` checks. Nothing says `create_post` reads the real values from `storage.objects.metadata`.

**Add to AD-19:**
- Storage INSERT is allowed only when `ll.post_upload_allowed(post_id)` returns true. This is a security-definer helper that sees all posts: the post does not exist anywhere, or it exists, is the caller's, and is still `waiting`.
- **No UPDATE or DELETE policies.** The queue uses `upsert: false` and treats "already exists" as success, which keeps it idempotent.
- File deletion goes through an RPC that versions the change and clears attestation (see M-7).
- `create_post` takes size and mime from `storage.objects.metadata`, and bucket limits (`file_size_limit`, `allowed_mime_types`) are set in the migration.

### H-4 — Mechanisms that cannot be written in SQL on Supabase: signed URLs, object deletion, and possibly `auth.sessions`

- **`ll.file_url(attachment_id)`** (AD-mapped RPC) and the signed URLs in **`export_person`**. Supabase Storage signs URLs with the Storage service's JWT secret, so a plpgsql function cannot create one without storing that secret in the database, which would be a severe secret-handling regression. Developer A puts the JWT secret in Vault. Developer B calls `createSignedUrl` from the client. Those designs are incompatible, and A's is unsafe.
- **`purge_expired()` deleting storage objects** (AD-10), and file deletion in the files RPCs. Supabase blocks direct `delete from storage.objects` with a protective trigger in current projects, and even where it is allowed, the bytes stay in the backing store. Deletion must go through the Storage API. `[VERIFY on project creation]`
- **`signout_student` deleting from `auth.sessions` / refresh tokens.** Supabase has been restricting `postgres` writes on the `auth` schema. `[VERIFY]` The `sessions_revoked_at` + `iat` check is sufficient on its own, so make the session delete best-effort.

**Tighten AD-10, AD-19 and the FR-30 mapping:**
- Signed URLs are created **by the client** with `storage.from('ledger-files').createSignedUrl(path, 600)`, authorized by the storage SELECT policy (one predicate). `file_url` is removed from the RPC list. `export_person` returns paths, and the client signs them.
- Object deletion (purge, file delete) happens in the ops workflow with the service role via the Storage API, driven by a `ll_ops.pending_object_deletes` table that `purge_expired` fills. Until that runs, the attachment row is already gone, so no policy grants access.

### H-5 — AD-5 and AD-7 together yield 2–3 version rows per RPC and recursive triggers; gap creation has three owners

**Pair:**
- **Unit A** implements AD-5 literally: `recompute_status()` "runs **after** any change to an entry's fields or gaps". It is an AFTER trigger on `entries` and on `gaps` that issues `update entries set status = …`.
- **Unit B** implements AD-7: an AFTER UPDATE trigger on `entries` writes a version.

What happens on `answer_gap`:
1. The fields update writes version 1.
2. The gap update fires recompute, which updates the entry status and writes version 2.
3. The recompute trigger on `entries` fires again on its own update, which means recursion unless it is guarded.

The test plan requires "every RPC writes exactly one `entry_versions` row". Unit A fails it, and a status-only "version" is noise in the "edited by X" history (FR-21).

Gap creation also has no single owner: ingest step 5 creates gaps in the RPC; `edit_entry` must open gaps when a required field is cleared (FR-20); merge "recalculates gaps"; `answer_gap('_person')` changes the person. Three developers will write three diverging versions of "missing required field ⇒ one open gap".

**Tighten AD-5:**
- Status is computed in a **BEFORE INSERT OR UPDATE** trigger on `entries`, from `ll.sync_gaps(NEW)`. That is the *only* writer of `gaps` rows for required fields, and it reads the registry.
- Gap state changes (answer, N/A) happen through RPCs that also touch the entry row once (`updated_at`), so exactly one entry UPDATE, and therefore one version, happens per RPC.
- `status_sweep` only **reports** drift to `ll.events` and never writes status, so AD-5 keeps a single writer.

**Tighten AD-7:** the version trigger writes one row per transaction per entry (`ll.reason` + txid de-duplication) and skips updates where only `status` or `updated_at` changed.

### H-6 — Derived and column-backed fields collide with the AD-6 provenance CHECK

- **Unit A** (FR-14, AD-13): `grade_levels` "is filled in from entry dates using the calendar". This is derived by `ll.grade_level()`, so it has neither `span` nor `by`.
- **Unit B** (AD-6): "a field without `span` (extracted) or `by` (answered) is rejected by a CHECK trigger".

Unit A's insert fails, so Unit A puts `grade_levels` in a column instead, and the registry, the gap logic and the Common App mapping (which read `fields`) never see it.

The same split affects facts that appear twice:
- The registry's `work_sample.date`, `service` "date or range", `honor.award_name` and `parent_note.child` against the common columns `date_start`, `title` and `person_id`.
- Ingest sends `title_span` and `date_span`, but no column stores them, so SM-5's nightly check cannot cover titles and dates at all.

**Tighten AD-6:**
- Add a provenance kind `{"kind":"derived","rule":"grade_level","from":["date_start","date_end"]}`, which is valid only for fields the registry marks `derived`.
- The registry gets a `storage` column (`fields` | `column:<name>`) so exactly one place holds each fact. Common-column provenance lives in `entries.fields['_title']`, `['_dates']` and so on, in the same `{v, span, by}` shape.
- `nightly_accuracy_check` covers these fields too.

### H-7 — The `edit_entry` patch scope is undefined: visibility, type, speaker and person can be patched around their dedicated rules

AD-3 rejects forbidden keys for the processor. No equivalent exists for `edit_entry(entry_id, patch jsonb)`.

- **Speaker flip.** A parent patches `speaker: 'student' → 'other'` ("facts"), confirms (allowed, since the speaker is no longer the student), then patches the speaker back. The result is a confirmed reflection with speaker = the student that the student never confirmed, and it can be quoted in essay angles. That breaks FR-6 and §6.2.
- **Retype.** `type: parent_note → activity` keeps parents_only via the CHECK constraint. Then `set_visibility` widens it to family, which defeats "parent note → parents_only, always; cannot be changed".
- **Person reassignment.** `person_id: S → Y` turns an AI-extracted entry into data about the younger child. `Y → S` moves the younger child's data into `processor_context`.
- **Column patching.** A developer who applies the patch generically to columns lets a client set `visibility`, `confirmed_at` or `archived_at` and skip their RPCs.

**Tighten AD-2:**
- `edit_entry` accepts only registry fields plus `_title` and `_dates`. Any other key is `forbidden-key`, the same as for the processor.
- `type`, `person_id` and `source_post_id` are immutable after insert (except through the `_person` gap, see C-7).
- `speaker` is immutable once it equals `student`, unless the student makes the change.
- Any speaker change clears `confirmed_at`.

### H-8 — `resolve_duplicate` merges bypass the student-text lock and the confirm rule

FR-18's merge lets the user "pick" when both values are confirmed and differ, and makes "confirmed beat draft".

- A parent merging two reflections with speaker = the student picks `text` from either one. That is a parent editing student-authored text without the `student-text-locked` check, because the check lives in `edit_entry`, not in the merge.
- Merging a draft into a confirmed older entry copies **unconfirmed** draft values into fields the older entry lacked, and the entry stays `confirmed`. Unconfirmed, model-extracted values then reach outputs without a human confirm, which breaks PRD §6.2 ("nothing extracted counts until a human confirms").

**Tighten AD-5 and add AD-18:**
- Merge goes through the same field-write path as `edit_entry`, so the lock checks apply.
- A merge that adds any value whose source entry was unconfirmed clears `confirmed_at`.
- A merge of reflections with speaker = the student is allowed only for the student.

### H-9 — `edit_output` has none of `save_output`'s cite validation and no rule for hidden items

**Pair:**
- **Unit A** (FR-36) builds `edit_output(version_id, items jsonb)` from the client's item list.
- **Unit B** (AD-11) puts all cite rules in `save_output`, which is processor-only.

Consequences:
- The student, or a parent, can cite unconfirmed, private, parent_note or other-person entries in an edited version, because nothing validates them.
- When the student edits an activities output in which one item is hidden from him, his client cannot send that item, so the new version **drops it** and parents lose it. If Developer B instead copies hidden items forward server-side, the two diffs (SM-7) disagree.

**Tighten AD-11:**
- `edit_output` runs the same `ll.validate_output_items(kind, person_id, items)` as `save_output`.
- Items hidden from the editor are carried forward server-side unchanged.
- The essay-angle quote rule applies to edits too, so a student cannot paste a fabricated quote.

### H-10 — `export_person` versus FR-4: "every entry" for a parent includes the student's private rows

FR-42 says a parent's export "contains every entry, version, gap, output version and file for that person". `export_person` is security definer, so a developer who implements the PRD literally exports the student's **private** entries to a parent (against FR-4). It also exports items in family outputs that are hidden from the caller (against FR-7) and recommender_pointers versions without writing the access log (against FR-37). The student's export "excluding parents_only" must also drop hidden output items, the parents_only comments and duplicate reasons from C-4, and files linked through a wider entry.

**Tighten AD-4:**
- Every read RPC, including `export_person`, `my_queue`, `my_badge`, `get_output` and `archive_list`, is `security invoker` where possible, so RLS applies.
- A read RPC that must be definer composes `can_read`/`can_act` per row.
- Amend the PRD wording: "every entry the requesting login can read".

### H-11 — Purge leaves purged content behind in the shapes the companions actually define

AD-10 sets `redacted = true, text = null`, but `output_items` has **no `text` column**. It has `payload`, `generated_payload` and `slot`.

**Pair:** Developer A nulls `payload` only, so `generated_payload` (kept for the SM-7 diff) still holds the purged text. Developer B's migration fails on the missing column and they improvise.

Other places purged content survives:
- `entry_versions.before/after` of **other** entries, for example the kept entry of a merge, which holds the purged entry's merged-in fields.
- `comments` and `duplicate_flags.reason`, which AD-10 does not mention and which may block the delete through their foreign keys.
- `span.post_id` and quotes in other entries.
- Soft-deleted posts (`deleted_at`), whose bodies are never purged.
- Weekly backups, which have no retention period.

**Tighten AD-10:**
- Redaction nulls `payload`, `generated_payload` and `slot` text keys and sets `redacted=true`.
- Purge deletes comments and duplicate flags (both directions).
- Purge redacts the purged entry's values from the merge versions of surviving entries.
- Soft-deleted posts with no remaining entries are hard-deleted after 30 days.
- Backups older than N weeks are deleted by the ops workflow (state N).

### H-12 — Free-text fields carry content across posts inside one processing run

One processing run reads the whole `processing_queue`: parents_only posts next to family posts, plus parents_only titles in `processor_context`. Several free-text outputs of the processor are not tied to their own post's text:

- `title` (`title_span` is optional).
- Field `v`. The span quote must match the body, but `v` itself can be any text.
- Gap `question` (5–200 characters of free text).
- `possible_duplicate.reason`.
- In `save_output`, activity `description` and `reason` plus angle `summary`, when a recommender_pointers request with parent notes is handled in the same run.

A model that saw a parents_only post a moment earlier can write its content into a family draft that the student can read. No database check catches this.

**Tighten AD-3 and AD-9:**
- `title_span` is required.
- For text-kind fields, `v` must be a substring of, or equal to, the span quote. Normalizations are allowed only for enum, number and date kinds.
- Gap questions come from the registry `gap_question` for required fields. Caller questions are accepted only for optional fields and are stored with the entry's visibility.
- `processing_queue` and `output_request_queue` return **one visibility class per run**: a family-and-shareable run and a separate parents_only run. They are scheduled as two tasks, so one context window never mixes the classes.
- Record the residual risk explicitly.

### H-13 — Required RPCs are missing, which invites improvised paths

These RPCs are referenced but undefined:

| Missing RPC | Referenced by | Risk |
|---|---|---|
| `create_entry` | rls-matrix §3; FR-15 (author creates entries by hand from a private post); FR-16 (`needs_manual`) | Two developers will invent different ones (or let `create_post` do it). Nothing says whether the post becomes `processed`. When a private post is widened, the processor re-extracts entries the author already made by hand. |
| `archive_list` | AD-10, rls-matrix §1 | Not in `rpc-contracts.md`. |
| `set_school_calendar` | FR-14 | Missing. Changing `grade_9_start` should re-derive grade levels. |
| attach / delete file (M2 "files RPCs") | FR-30, FR-32 | Shape unspecified. |
| writes to `members.last_person_id` | FR-8 | Unassigned; AD-2 forbids a client write. |

There is also a contradiction: `create_post` is "✓ (manual milestone only)" for the younger child. A `create_post` about the younger child never leaves `waiting` (the queue excludes it), so it shows "waiting to be processed" forever and skews SM-4.

**Tighten AD-2:**
- `rpc-contracts.md` §4 is exhaustive. Add the RPCs above.
- `create_post` refuses `ai_excluded` persons (`ai-excluded`), so the UI must use `create_milestone`.
- Manual entry creation from a post sets the post to `processed` with `processed_by='manual'`.

---

## Medium

### M-1 — The visibility order and the meaning of "author" are undefined for entries
- `narrowest()` and "widen only to ≤ post" assume an order, presumably private < parents_only < family < shareable, that no document states.
- Entries have no `author_id`; ingest sets `created_by` to null. A *private* entry is readable "only if author", so Developer A (author = `created_by`) makes it unreadable to everyone, while Developer B (author = the source post's author) gets the intended result.
- `can_read`'s `person_id` argument has no defined role.
- The student can create a parents_only post (no rule stops him) and then cannot read his own post, which conflicts with offline-queue display and FR-8.

**AD-4 fix:**
- State the order.
- Define the entry author as `coalesce(created_by, source_post.author_id)` and store it as `entries.author_id`.
- `student_owner` may not choose parents_only.
- Define what `person_id` does in `can_read`, or drop the argument.

### M-2 — The `search_path` and helper conventions are weak for security-definer functions
`set search_path = ll, public` puts a schema with broad grants on the definer path and leaves `pg_temp`'s position implicit; Postgres searches `pg_temp` first for relations. The Supabase linter (`function_search_path_mutable`) recommends `search_path = ''`.

Role helpers called from RLS policies (`is_parent()` reads `members`, which has an RLS policy that calls `is_parent()`) recurse infinitely unless they are definer functions.

**AD-2 fix:**
- All functions use `set search_path = ''` with schema-qualified names, or `pg_catalog, ll, pg_temp` explicitly.
- `can_read`, `can_act`, `is_parent`, `my_person` and `is_owner` are `security definer stable`, and policies call them as `(select ll.is_parent())` so Postgres plans them once (helps NFR-PERF-1).

### M-3 — Contradictions between the spine and its companions

| # | Spine | Companion | Fix |
|---|---|---|---|
| a | AD-12: RPC "accepts only object **paths** under `posts/<post_id>/`" | `create_post(… attachment_ids uuid[] …)` | Choose ids. The server derives the path `posts/<id>/<attachment_id>`. |
| b | data-model: `posts/{post_id}/{uuid}.{ext}` | offline-queue: `posts/{id}/{attachment_id}` (no extension) | One path grammar in AD-19. |
| c | Spine source span: image `file_id` | rpc-contracts: image `attachment_id` | Use `attachment_id`. |
| d | Spine answer span `{kind:'answer', gap_id}` | `edit_entry`: `{kind:'answer'}` + `by`, with no gap | Allow `gap_id: null` for direct edits. |
| e | AD-11: quote must **equal** the confirmed text; PRD: "exact confirmed text" | rpc-contracts §2.3: **exact substring** | Decide: substring is the useful one. Fix the AD and the PRD wording. |
| f | AD-8: "`is_parent()` and `my_person()` are the **only** role helpers" | data-model adds `is_owner()` | List all three. |
| g | Structural seed: `test/ … Playwright e2e with fake Supabase` | test-plan and memlog: local Supabase stack | Use the local stack. |
| h | data-model `processing_queue`: "includes attachment **paths**" | rpc-contracts: `attachments[{id, mime}]` | Ids only. |
| i | rls_vis_03 expects `check-violation` | Not in the error-code list | Map to `forbidden-visibility`. |
| j | AD-4 / rls-matrix: output items readable via `can_read` | AD-11: only via `get_output` | See C-5. |
| k | AD-7 reasons: `edit, confirm, merge, answer, attest, archive` | `set_visibility`, `restore_entry`, `mark_not_applicable` and `resolve_duplicate('discard')` also change entries | Make the reason list exhaustive. |

### M-4 — Archived entries in outputs and children
`can_read(visibility, author, person)` has no archive input. `get_output`, which filters cites "pass `can_read`", therefore still shows items citing archived entries, against FR-22 ("archive hides from outputs"). Developer A implements the gaps/versions/comments policy as `exists (select 1 from ll.entries …)` under RLS, which hides children of archived entries. Developer B uses `can_read(e.visibility…)` through a definer join, which shows them.

**Fix:** a single row-level predicate `ll.entry_visible(entry_id)` (readability plus not archived plus not purged), used for cites and for child tables.

### M-5 — Session revocation is bypassable by any RPC that reads `members` directly
AD-8 puts the `iat < sessions_revoked_at` check in the helpers. An RPC that checks `exists(select 1 from ll.members where user_id = auth.uid() and role = 'student_owner')` follows AD-2 ("checks `auth.uid()` and role") and skips the check.

**Fix:** every RPC's first statement is `perform ll.require_member()`, which raises `session-revoked`. A catalog test greps function bodies for `auth.uid()` outside the helpers.

### M-6 — The per-kind JSON value encoding is unspecified
The registry `kind`s `daterange`, `url_or_file`, `enum[]` and `bool` have no canonical JSON form. `grade_levels` is `"9"…"PG"` strings in `save_output` but is an `enum_values` set of unknown representation. The `honor.level` value `state_regional` (contract) differs from "state-regional" (PRD). `timing` values must match the `enum_values` rows.

**Pair:** the ingest writer, the client renderer and the activities mapper each choose differently. `answer_gap(gap_id, value jsonb)` gives no hint whether `value` is raw or `{v: …}`.

**Fix:** a table in `data-model.md` giving the canonical JSON for each kind, validated by `check_field_provenance()`. `answer_gap` takes a raw value.

### M-7 — Two owners of "verified hours"
Developer A computes "verified" in the `service_hours` view (a form attachment exists and `attested_at` is set). Developer B clears `attested_*` in the file-delete RPC. Under A, re-attaching any file later restores "verified" without a new attestation. Under B, the view and the columns can disagree.

**Fix:** attestation records the attachment id (`attested_attachment_id`). Verified means that attachment is still linked and has not been replaced. File delete clears the attestation with a versioned change.

### M-8 — The offline queue keeps other logins' content readable on a shared device
"Sent" records stay in IndexedDB for 7 days "for display". "Keep on this device" keeps queued private or parents_only bodies after sign-out. A compliant timeline developer who merges local records into the view can show Parent B's parents_only post to the student on the family iPad. Rule 5 covers only *flushing*, not display.

**Fix (in `offline-queue.md` / AD-12):**
- Local records are rendered only when `record.user_id = current user`.
- Sent records are deleted on sign-out.
- The local "sent" display shows a body only while the record is `queued`.

### M-9 — Output request and processor-output gaps
- D-4 says later requests "attach" to the open one, but the partial unique index makes the second `insert` fail. Developer A returns the existing row; Developer B surfaces an error.
- `save_output` does not check that `request_id` matches `(person_id, kind)`, so it can close the wrong request.
- `save_output` does not reject `ai_excluded` persons.
- AD-9 lists `processing_queue` and `processor_context` but not `output_request_queue`, which must apply the same person and private filters.

**Fix:**
- `request_output` uses `on conflict do nothing returning` or a select.
- `save_output` validates `request_id` and person.
- AD-9 enumerates every relation in `ll_proc`.

### M-10 — `metric_*` views marked "owner" have no mechanism behind them
Views cannot carry RLS. Invoker views give the owner wrong totals (the owner cannot read Parent B's private posts), and definer views expose everything to every grantee.

**Fix:** put them in `ll_ops` (see C-1) and read them only through a definer RPC `ll.metrics()` that checks `is_owner()`, or only from the ops workflow.

### M-11 — Ingest duplicate validation is incomplete
Ingest step 6 checks only that the target is in `processor_context`, not the FR-18 rule (same person and type, dates within 30 days), so a processor can flag across persons. Merge across persons then moves data between the student and the younger child.

**Fix:** step 6 checks same person, same type and same visibility (C-4), and requires dates within 30 days.

### M-12 — `create_post` side effects on retry
The `post_duration` event is logged on every call, so retries double-count SM-3. Nothing says whether `received_at` and `last_person_id` update on a conflict.

**Fix:** side effects run only on actual insert (`xmax = 0` / `found`).

---

## Low

- **L-1** `log_event` allow-list: the client can emit server-only names (`digest_sent`, `purge_run`, `backup_run`, `accuracy_check`) and skew metrics. Split the client and server allow-lists. Cap `props` size and keys, and allow no free text.
- **L-2** Count leaks: `my_badge`, timeline "N entries" counts and digest counts can reveal that hidden rows exist. The digest workflow uses the service role (RLS bypassed), so it must call the same `ll.badge_for(user_id)` function instead of counting gaps itself.
- **L-3** Comments have no visibility of their own. A parent's comment on a family entry is always visible to the student, which may not be what parents expect (PRD Q8). Consider `comments.visibility ≤ entry.visibility` before M1 review stories.
- **L-4** There are two "younger child" gates: the milestone constraint uses `persons.kind='child'`, and processing uses `ai_excluded`. State that `ai_excluded` is the only privacy gate and `kind` is for UI only.
- **L-5** Post visibility changes and soft deletes are not versioned (AD-7 covers entries only), which leaves an audit gap for the very action that hides data. Add `post_events` or extend versions.
- **L-6** Other Supabase surfaces: if `pg_graphql` or Realtime is ever enabled for `ll`, definer views and grants become reachable through them too. Say "Data API only; `pg_graphql` disabled; no Realtime publication on `ll`".
- **L-7** `resolve_duplicate('discard')`: decide between hard delete (bypasses AD-7 and AD-10) and archive. Archive is the consistent choice.
- **L-8** Signed URLs issued before `signout_student` stay valid for 600 s. That is acceptable, but record it.

---

## Proposed AD changes (summary)

| Change | Closes |
|---|---|
| **New AD-17 View security:** `security_invoker` on every exposed view; `ll_proc` and `ll_ops` schemas not exposed; no blanket grants; catalog test. | C-1, M-10 |
| **AD-2 tightened:** revoke from PUBLIC and default privileges; `search_path=''`; exhaustive RPC list; `require_member()` first; `edit_entry` key allow-list; immutable `type`/`person_id`/`speaker`; read RPCs are invoker. | C-2, H-7, H-10, H-13, M-2, M-5 |
| **AD-3 / AD-9 tightened:** `ll_processor` login role with real grants; invoker processor functions with a `current_user` check; null-person posts excluded; one visibility class per run; text `v` ⊆ span quote; `title_span` required; registry gap questions; `output_request_queue` covered. | C-2, C-7, H-12, M-9 |
| **AD-4 tightened:** `can_act(action, entry)` that ANDs `can_read`; visibility order stated; entry `author_id`; post narrowing cascades; `entry_visible()` includes archive. | C-6, H-1, M-1, M-4 |
| **AD-5 / AD-7 tightened:** BEFORE-trigger status; `sync_gaps()` as the only gap writer; one version per RPC; sweep reports only; exhaustive reason list. | H-5, M-3k |
| **AD-6 tightened:** `derived` provenance; registry `storage` column; common-column provenance; canonical JSON per kind. | H-6, M-6 |
| **AD-10 tightened:** redact `payload`, `generated_payload` and `slot`; purge comments, flags and merge-version residue; hard-delete old soft-deleted posts; backup retention; object deletes via the ops Storage API. | H-11, H-4 |
| **AD-11 tightened:** no client SELECT on `output_items`/`output_versions`; shared `validate_output_items()` for `edit_output`; hidden items carried forward. | C-5, H-9 |
| **AD-12 tightened:** conflict returns the row only to the same author with identical content, else `id-conflict`; side effects only on insert; local display per `user_id`. | C-3, M-8, M-12 |
| **New AD-18 Duplicates & merge:** same person, type and visibility; `can_act` on both; narrowest visibility; merge through the field-write path; unconfirmed values clear the confirm. | C-4, H-8, M-11 |
| **New AD-19 Files:** `entry_attachments` join; linking only to entries no wider than the origin; INSERT-only storage policy through a definer existence check; no UPDATE/DELETE; client-side signed URLs; attestation pinned to an attachment. | H-2, H-3, H-4, M-7 |

## Tests to add to `rls_never` (release blockers)

- `rls_never_13`: as S, select from every view in `ll`; every view has `security_invoker=true` (catalog assertion).
- `rls_never_14`: `has_function_privilege('authenticated'|'anon', f, 'execute')` is false for every function outside the published client RPC list.
- `rls_never_15`: as S, `create_post` with the id of a parents_only post returns `id-conflict` and no row.
- `rls_never_16`: as S, `select * from ll.output_items` returns zero rows. `get_output` hides an item after its cite narrows, in every version.
- `rls_never_17`: as S, `my_queue` contains no gap on a parents_only entry about S; `answer_gap` on it returns `forbidden`.
- `rls_never_18`: a duplicate flag across visibility classes is refused by ingest. A merge never widens any field's visibility.
- `rls_never_19`: ingest with an `attachment_id` from another post returns `unknown-attachment`; `attest_service_form` with a parents_only post's file is refused.
- `rls_never_20`: `processing_queue` never contains a post with `person_id is null`. As `ll_processor`, `select from ll.posts` returns permission denied.
- `rls_never_21`: narrowing a post to parents_only makes its family entries parents_only in the same transaction.
- `rls_never_22`: a parent's `edit_entry` on `speaker`, `type`, `person_id` or `visibility` returns `forbidden-key`.
