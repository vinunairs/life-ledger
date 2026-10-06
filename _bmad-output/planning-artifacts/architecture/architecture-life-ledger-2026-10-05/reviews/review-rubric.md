# Architecture Review (rubric) — Family Life Ledger v1

- **Reviewed:** `ARCHITECTURE-SPINE.md` + `data-model.md`, `rls-matrix.md`, `rpc-contracts.md`, `offline-queue.md`, `test-plan.md` (and `.memlog.md` for stated assumptions)
- **Against:** `prds/prd-life-ledger-2026-10-05/prd.md` (FR-1..FR-43, NFRs, §6), `addendum.md`, `docs/feature-doc-v2.md`, brownfield reference `vinunairs/psat-sprint` (read from disk)
- **Reviewer:** independent architecture reviewer, 2026-10-05
- **Verdict:** Strong spine with the right paradigm and most divergence points fixed, but **not build-ready**. Two privilege rules do not hold as written (default `PUBLIC` execute on functions; views bypass RLS). Several mechanisms cannot run inside Postgres on Supabase: signed URLs, storage deletion during purge, and 30-day sessions on the free plan. The operational envelope (auth settings, SMTP, project pausing, migration deploy, scratch-project slot) is mostly undecided. Fix the critical and high items, then re-validate.

## Scorecard against the checklist

| Checklist item | Result | Notes |
|---|---|---|
| Fixes the real divergence points, misses none | Partial | Misses: view security mode, function grant hygiene, entry "author" for `can_read`, gap creation on edit, file attach/delete path, manual entry creation, client-read path for outputs. |
| Every AD Rule is enforceable and prevents its divergence | Partial | AD-3 (grant), AD-9 (connector has full access), AD-10 (storage delete), AD-11 (direct SELECT on items), AD-8 (iat-only revocation) do not hold as written. |
| Nothing Deferred lets two units diverge | Mostly | D-3 lacks auth SMTP, D-8 lacks scratch-project/restore target, D-7 "pagination" is minor. |
| Ratifies brownfield conventions | Mostly | No-build IIFE, vendored supabase-js 2.117.2 with `?v=`, security-definer RPCs and pg_cron are ratified correctly. The service worker deviation is acknowledged and is accurate (psat-sprint `sw.js` does not cache). Two deviations are not acknowledged: schema `ll` instead of `public`, and `search_path = ll, public` where psat-sprint's latest migration uses `search_path = ''`. psat-sprint also uses client write policies (`fast_*`), so the "ratified" claim overstates it. |
| Covers FR-1..FR-43 / NFRs | Partial | Gaps: FR-1 (30-day session), FR-14 (calendar RPC), FR-15/16 (manual entry from private or needs_manual posts), FR-30 (file attach/delete), FR-42 (archive format). See §Coverage. |
| Spine ↔ companions consistency | Partial | Span shape, output_items columns, quote rule, file path shape, `entries.person_id` nullability, e2e target and helper list all disagree between documents (M-items below). |
| Every dimension decided/deferred/open, incl. ops envelope | **Weak** | Deployment of migrations, auth settings, SMTP for auth, project pausing, free-plan quotas, monitoring/alerting, restore target and connector scoping are absent or exist only in `.memlog.md`. |

---

## Critical

### C-1 — Processor functions stay callable by every role: `PUBLIC` keeps EXECUTE
- **Location:** Spine AD-3 ("These are `revoke`d from `anon` and `authenticated`"); AD-2 ("granted to `authenticated` only"); `rpc-contracts.md` §1–2 "Caller: processor only"; `data-model.md` migration 7.
- **Problem:** Postgres grants `EXECUTE` on every new function to `PUBLIC`, so revoking from `anon` and `authenticated` changes nothing: both roles inherit `PUBLIC`. As written, any signed-in login, and anon if `ll` is exposed, can call `ingest_draft` and `save_output`, which bypasses the AD-3 boundary the whole AI-safety story rests on (PRD §6.2). The same applies to every client RPC, so anon can call `create_post`. psat-sprint gets this right (`revoke all on function … from public, anon;`). `rls_never_10` would catch it, but the Rule itself tells implementers to do the wrong thing.
- **Fix:** Rewrite AD-2/AD-3 so each function is followed by `revoke all on function … from public, anon, authenticated;` and then an explicit `grant execute … to authenticated` (client RPCs) or to a named role (processor RPCs). Add `alter default privileges in schema ll revoke execute on functions from public;` in migration 00. Add a pgTAP test that enumerates `pg_proc` in `ll` and asserts the ACL of every function against an allow-list.

### C-2 — Views bypass RLS by default; the spine never says how views are secured
- **Location:** `data-model.md` §Views (`timeline`, `service_hours` "authenticated (RLS)", `metric_*` "owner", the three processor views); Spine AD-4 ("Every SELECT policy … calls it"); capability map rows FR-26 and FR-31.
- **Problem:** A plain Postgres view runs with the view owner's privileges (`postgres`, which bypasses RLS) unless it is created `with (security_invoker = true)`. If `ll.timeline` or `ll.service_hours` is granted to `authenticated` as the table says, the student can read parents_only and private rows through it, which breaks NFR-SEC-1 and the FR-4 invariant. A "readable by owner only" `metric_*` view cannot be expressed with RLS at all. AD-4 covers tables and storage but not views, so two implementers will build views two different ways.
- **Fix:** Add a rule to AD-4. Client-readable views must be `security_invoker = true`, so the underlying RLS (and therefore `can_read`) applies. Processor views and `metric_*` get no grant to `anon`/`authenticated`. Owner metrics are exposed only through a `security definer` RPC that checks `is_owner()`. Keep `rls_never_01` enumerating `information_schema.views` and add a test that asserts `security_invoker` on every view granted to `authenticated`.

---

## High

### H-1 — Signed URLs and storage deletion cannot run in SQL
- **Location:** `data-model.md` §Storage (`ll.file_url(attachment_id)` "Signed URLs created by…"); `rpc-contracts.md` §4 `file_url`, `export_person` ("files listed with signed URLs"); Spine AD-10 (pg_cron `purge_expired` "deletes storage objects"); FR-22, FR-30.
- **Problem:**
  - A signed URL is minted by the Storage API with the project's signing key. A plpgsql function cannot produce one.
  - Deleting rows from `storage.objects` in SQL does not remove the stored blob, and current Supabase blocks direct deletes on storage tables. This is a known platform restriction, so verify it on project creation.
  - The result is that `file_url` is infeasible. Purge from `pg_cron` would leave purged files in storage, which breaks the AD-10 promise "purged content [never] surviving in … storage" and FR-22.
- **Fix:**
  - Signed links: the client calls `storage.from('ledger-files').createSignedUrl(path, 600)`, gated by the storage SELECT policy. Drop the `file_url` RPC, or turn it into a definer RPC that returns `object_path` after a `can_read` check.
  - Purge: split it in two. `purge_expired()` in SQL deletes rows, writes the object paths to an `ll.storage_tombstones` table and redacts outputs. An ops-repo workflow (service role, Storage API) deletes the tombstoned objects daily and clears the table.
  - Client file deletion (FR-30) goes through a storage DELETE policy plus a definer RPC that removes the `attachments` row.
  - State all of this in AD-10 and AD-14.

### H-2 — Session rules: the 30-day limit is undesigned and revocation by `iat` is defeated by refresh
- **Location:** Spine AD-8; `rpc-contracts.md` `signout_student`; `data-model.md` `members.sessions_revoked_at`; PRD FR-1 ("valid for 30 days … then requires sign-in"), FR-3.
- **Problem:**
  - (a) Nothing implements the FR-1 30-day expiry, and Supabase's time-boxed sessions and inactivity timeout are paid-plan settings. On the free plan, refresh tokens keep a session alive indefinitely.
  - (b) AD-8 rejects JWTs whose `iat` is earlier than `sessions_revoked_at`. A still-valid refresh token mints a new JWT with a fresh `iat`, so revocation depends entirely on `signout_student` deleting rows in `auth.sessions` and `auth.refresh_tokens` from a definer function. Supabase restricts changes to the `auth` schema and may refuse that, and nothing tests the fallback.
  - (c) RLS returns zero rows rather than an error, so a revoked client cannot tell "revoked" from "empty". FR-3 expects "requires sign-in".
- **Fix:**
  - Key the helpers off the JWT's `session_id` claim: `select created_at from auth.sessions where id = (auth.jwt()->>'session_id')::uuid`.
  - Accept a request only if that session exists, `session.created_at > coalesce(sessions_revoked_at, '-infinity')` and `session.created_at > now() - interval '30 days'`. This one predicate gives both FR-1 and FR-3, survives token refresh and needs no paid feature.
  - Add `ll.session_ok()`, which the client calls on load and after any empty result. It raises `session-expired`, and the client then signs out locally.
  - Test it in pgTAP by forging `request.jwt.claims` with old and new `session_id` values.

### H-3 — Auth configuration is missing from the operational envelope (sign-ups, SMTP, redirect URLs)
- **Location:** Spine AD-8 ("No sign-up"), AD-14, D-3, Consistency "Secrets"; `data-model.md` §Storage upload policy; FR-1, FR-3.
- **Problem:**
  - (a) The anon or publishable key sits in a public repository. Unless "Allow new users to sign up" is turned off in Supabase Auth, anyone can create an `authenticated` user. The storage upload policy ("`posts/{id}/` for a post id not yet existing") then lets a stranger fill the 1 GB bucket. Several RPCs (`log_event`, `create_post`) are only safe if they check for a `members` row, and the spine never requires that.
  - (b) Supabase's built-in email sender only delivers to project team members and is heavily rate-limited, so password reset (FR-1, FR-3) will not reach the student without custom SMTP in Auth settings. The spine says "Supabase Auth email only for auth" and gives auth no SMTP.
  - (c) The Site URL and redirect allow-list for the Pages URL are not fixed, so reset links break.
- **Fix:**
  - Add an "Auth settings" row to AD-8 or AD-14 that requires: sign-ups disabled, custom SMTP configured in Auth (the same provider as the digest, under D-3), Site URL and redirect URLs set to the Pages origin, and a JWT expiry setting.
  - Make `is_member()` part of `can_read` and of every RPC, and require a `members` row in the storage INSERT policy.
  - Add `rls_never_13`: an authenticated user with no `members` row gets zero rows and `forbidden` from every RPC and upload.

### H-4 — Clients can read `output_items` directly, bypassing `get_output` (FR-7 hiding, FR-37 access log)
- **Location:** Spine AD-11 ("Clients read outputs only through `ll.get_output`"); `rls-matrix.md` §2 ("outputs / output_versions / output_items: `can_read(outputs.visibility…)`; items further filtered by `get_output`").
- **Problem:** The RLS matrix gives `authenticated` a SELECT policy on `output_items` that checks only the output's visibility. A client (or an implementer taking a shortcut) can `select * from ll.output_items` and see items that cite entries it can no longer read (breaks FR-7). It can also read parents_only pointers without writing an access-log row (breaks FR-37 and NFR-AUD-1). The AD's own Rule is not enforced.
- **Fix:** Grant no SELECT on `output_items` and `output_access_log` to `authenticated`. The only read path is `get_output` (definer). It applies a per-item `can_read` over every cite, also hides items citing archived entries (FR-22, "hides from outputs"; AD-11 is silent on archived), and writes the log row in the same transaction. Add a must-never test: S reads `output_items` directly → permission denied.

### H-5 — Free-plan envelope: a third "scratch" project, project pausing, and migration deployment are undecided
- **Location:** Spine D-8, AD-14, Stack; `test-plan.md` §1 ("golden posts … against a scratch project"), §4 ("restore into a scratch project"); PRD FR-43 ("restore … tested quarterly"); `.memlog.md` (pausing assumption appears only there).
- **Problem:**
  - (a) The owner has two active free slots (psat-sprint and life-ledger; the spec notes a third project, calculator, is kept paused). The test plan needs a scratch project for golden posts, the pre-launch restore test and the quarterly restore. That contradicts D-8 ("no staging project (free-plan slot limit)").
  - (b) Free projects pause after about 7 days without API traffic. While paused, pg_cron stops (no purge, no accuracy check), offline posts cannot flush, and the Claude run fails. The spine records only an unverified memlog assumption that "family use keeps it active". `pg_cron` activity does not count as activity.
  - (c) No AD says how migrations reach production: who runs `supabase db push`, with which credential (not the public repo), in what order relative to the Pages deploy, or how a forward-fix works given "add-only after first deploy".
- **Fix:**
  - Add **AD-17 Operations envelope**:
    - Restore and golden-post targets: the local `supabase start` stack or a temporary project created by pausing calculator, with a written procedure. Pick one and amend `test-plan.md`.
    - Keepalive: the ops repo runs a daily authenticated REST ping and alerts the owner if the project is paused. Add a paused-project runbook.
    - Deploy: the owner runs `supabase db push` from a workstation using the DB password from the password manager, or a manually triggered workflow in the private ops repo. Migrations ship before the client release that needs them. Clients tolerate unknown columns.
    - Quotas: a weekly ops check of DB size (500 MB), storage (1 GB) and egress, posting counts only to the owner by email.
  - Move the pausing assumption from the memlog into the spine.

### H-6 — No RPC for creating an entry by hand (FR-6 "Create entry", FR-15 private posts, FR-16 "needs manual entry")
- **Location:** `rpc-contracts.md` §4 (only `create_post` and `create_milestone`); `rls-matrix.md` §3 lists `create_post / create_entry`.
- **Problem:** FR-15 says the author "can create entries from [a private post] by hand". FR-16 leaves failed posts as "needs manual entry". FR-6 gives parents and the student "Create entry". No RPC does this, so the failure path for NFR-REL-1 has no landing point, and implementers will invent different ones.
- **Fix:** Add `create_entry(person_id, type, title, dates, fields jsonb, source_post_id null, visibility)`. It sets `created_via='manual'` and spans `{kind:'answer', by}`, has visibility clamped by `narrowest`, gets gaps computed from the registry exactly as in ingest step 5 (factor that step into `ll.compute_gaps(entry_id)`), and marks a `needs_manual` post `processed` when `source_post_id` is given. Add action-matrix tests.

### H-7 — Purge redaction misses copies of the purged content
- **Location:** Spine AD-10 ("sets `redacted = true, text = null` on every `output_items` row"); `data-model.md` `output_items` (`payload`, `generated_payload`; there is no `text` column).
- **Problem:** No `text` column exists. Purged content lives in `payload` **and** `generated_payload` (stored for SM-7), and also in quotes inside essay-angle payloads. As written, the redaction step either fails or leaves the content in place, which breaks FR-22 ("permanently redacted in every saved version"). Merge also copies a purged draft's values into the surviving entry's `entry_versions.before/after`. Leaving those is acceptable, but the spine should say so.
- **Fix:** Rewrite AD-10: `redacted = true, payload = '{}'::jsonb, generated_payload = '{}'::jsonb`. Declare the cascade set (`gaps`, `entry_versions`, `comments`, `duplicate_flags` both sides, `attachments.entry_id`) as `on delete cascade` or `set null`. Have `rls_life_02` assert that no purged string appears anywhere in `ll`.

### H-8 — `can_read` has no defined author for ingested entries
- **Location:** Spine AD-4 (`can_read(visibility, author_id, person_id)`); `data-model.md` `entries.created_by` ("null when created by ingest"); `rls-matrix.md` §1 ("private: only if author").
- **Problem:** An ingested entry narrowed to `private` through `set_visibility`, which FR-6 permits for "own posts", has `author_id = null`, so nobody can read it, the person who narrowed it included. "Own posts" for an entry is also undefined (`created_by` vs. the source post's author). Implementers will pick different columns, which is exactly what AD-4 exists to prevent.
- **Fix:** Add `entries.author_id uuid not null`, set at insert from `posts.author_id` (ingest) or the caller (manual). Use it in `can_read` and in "own posts" checks. Keep `created_by` and `created_via` for provenance.

---

## Medium

### M-1 — The status trigger and the version trigger produce extra versions; gap creation on edit is unassigned
- **Location:** AD-5, AD-7; `test-plan.md` `rpc_entries.sql` ("every RPC writes exactly one `entry_versions` row").
- **Problem:** `recompute_status()` runs *after* a change to fields or gaps and writes `entries.status`. That fires the AFTER UPDATE version trigger a second time, so the "exactly one version" test fails or implementers suppress versions inconsistently. Separately, FR-20 ("editing a required field … returns it to needs_detail if a gap reopens") needs `edit_entry` and `answer_gap` to create or reopen gaps from the registry, and only ingest step 5 is specified to do that.
- **Fix:** Compute status in a BEFORE INSERT/UPDATE trigger on `entries`, from the gaps. Gap triggers touch the entry with a no-op update guarded by `ll.reason`. The version trigger skips updates where only `status`/`updated_at` changed. Put gap computation in a single `ll.compute_gaps(entry_id)` that ingest, `create_entry`, `edit_entry` and merge all call. Also define what `status_sweep` writes and with which reason, or drop it.

### M-2 — Provenance gap on common columns (title, dates)
- **Location:** `rpc-contracts.md` §1 (`title_span` and `date_span` optional); AD-6 (CHECK only on `fields`); FR-11 ("a source span for every extracted field"); SM-5.
- **Problem:** Extracted title and dates can arrive with no span, and the nightly accuracy check looks only at `fields`, so SM-5 can show 0 violations while unsupported facts get confirmed.
- **Fix:** Make `title_span` and (when dates are present) `date_span` required in the schema. Store them in `fields` under reserved keys (`_title`, `_date`), or in a `common_spans jsonb` column, and include them in `check_field_provenance` and `nightly_accuracy_check`.

### M-3 — Nullable post/entry person conflicts with AI exclusion and with `entries.person_id not null`
- **Location:** `data-model.md` `posts.person_id null`, `entries.person_id not null`; `rpc-contracts.md` ingest (`person_id: null → '_person' gap`); AD-9.
- **Problem:**
  - A post with no person passes the `ai_excluded` filter (that filter is per person), so a post that is really about the younger child can reach the model, which breaks PRD §6.1.
  - The ingest schema allows `person_id: null` on entries, but the table forbids it.
  - FR-16 asks for "separate entries per person" when both children are mentioned, while AD-9 refuses entries for the younger child. The resolution is not stated.
- **Fix:**
  - Make `posts.person_id not null`; the picker always has a value per FR-8.
  - For entries, either allow a null person with a `_person` gap, and have answering it re-check `ai_excluded` and visibility, or require a person.
  - State that a post about the student which mentions the younger child yields only student entries plus an optional "also mentions younger child — add manually" note. The model still sees that text; record this as an accepted residual in §6.1 or add the guide rule "do not post younger-child details in the student's posts".

### M-4 — File attach, detach and size enforcement are under-specified (FR-30, FR-32)
- **Location:** `data-model.md` §Storage, `attachments`; `offline-queue.md` flow (`posts/{id}/{attachment_id}` with no extension) vs. `data-model.md` (`posts/{post_id}/{uuid}.{ext}`); Spine AD-12 ("RPC accepts only object paths") vs. `rpc-contracts.md` (`attachment_ids uuid[]`).
- **Problem:**
  - No RPC creates `attachments` rows for files added to an existing entry, or deletes them. The migration list says only "files RPCs".
  - Mime and size limits (10 MB vs. 25 MB) are CHECKs on the row, written after the upload, so oversized blobs are orphaned. A bucket can carry only one size limit.
  - Re-attesting after a form is deleted and re-uploaded is undefined: the old `attested_at` would make the new file "verified" without a new tick.
  - Uploads abandoned by failed queued posts are never cleaned up.
- **Fix:**
  - Pin one path format: `{posts|entries}/{owner_id}/{attachment_id}.{ext}`.
  - `create_post` and a new `attach_file(target, id, attachment_id, object_path)` insert `attachments` rows after reading `storage.objects.metadata` for size and mime, rejecting with `over-limit` and tombstoning the object.
  - Set a 25 MB limit and an allowed-mime list on the bucket.
  - `delete_attachment` clears `attested_*` when the file is the service form (FR-30, UJ-5).
  - Add a weekly ops sweep for objects with no `attachments` row older than 7 days.

### M-5 — Spine and companions disagree on names and shapes
- **Location / Fix:**
  - Source span: Spine conventions use `{kind:'text', post_id, start, end, quote}` and `{kind:'image', file_id, region}`. `rpc-contracts.md` has no `post_id` and uses `attachment_id`. **Fix:** adopt the rpc-contracts shape (post id is implied by `source_post_id`) and update the spine.
  - Essay quote rule: AD-11 says "must equal the confirmed text", `rpc-contracts.md` step 3 says "exact substring", and FR-41 says "exact confirmed text". **Fix:** decide (a substring with the span kept verbatim is reasonable for quoting) and align AD-11, the contract and FR-41's test.
  - `output_items` columns: AD-11 lists `(version_id, position, slot, payload, cites, redacted)`, the data model adds `id` and `generated_payload`, and AD-10 refers to `text`. **Fix:** make AD-11 point to `data-model.md` as authoritative.
  - Role helpers: AD-8 says `is_parent()` and `my_person()` are "the only role helpers", but the data model also has `is_owner()`, and H-3 needs `is_member()`. **Fix:** list all of them.
  - E2E target: the structural seed says `test/ … Playwright e2e with fake Supabase`, while `test-plan.md` says local Supabase stack. **Fix:** say local stack in the seed.
  - The `processing_queue` "existing-entry digest" (data model) is absent from the contract's column list (rpc-contracts §3). **Fix:** drop it (that is what `processor_context` is for).
  - SM-4 uses `received_at` in the data model but `created_at` in the PRD. **Fix:** note it as a deliberate refinement in the spine.

### M-5b — The `ll` schema must be exposed and granted
- **Location:** Spine Consistency "Schema & naming"; Stack.
- **Problem:** psat-sprint uses `public`. A custom schema is unreachable from supabase-js until it is added to Data API "Exposed schemas", `grant usage on schema ll to authenticated` is run, and the client is built with `createClient(url, key, { db: { schema: 'll' } })`. That deviation from the brownfield reference is not acknowledged and the setup step is not owned.
- **Fix:** Add these three steps to migration 00 or the ops runbook and to AD-15, and record the deviation from psat-sprint with its reason.

### M-6 — Connector scope and SQL quoting for the processor
- **Location:** AD-3, AD-9 ("must never be given a broader view"); PRD §6.2.
- **Problem:**
  - The Supabase connector runs arbitrary SQL as a privileged role across every project in the owner's account, psat-sprint included. AD-9's Rule cannot be enforced, so it is a guide rule, and the spine should say that plainly.
  - The run builds `select ll.ingest_draft('<json>')` with quotes taken from family-written text, so a stray `'` breaks the call, and crafted text could escape the literal.
- **Fix:**
  - State the residual risk in AD-9 and limit the connector to the life-ledger project ref.
  - Create a `ll_processor` role that holds only the two views and two functions. The guide's first statement is `set role ll_processor`, and the golden-post run verifies it.
  - Mandate dollar-quoting with a random tag (`$p7f3$…$p7f3$::jsonb`) in `processing/SKILL.md`.

### M-7 — Ingest attempt counting lets bad payloads loop forever
- **Location:** `rpc-contracts.md` §1, last paragraph.
- **Problem:** `forbidden-key` (and schema errors detected in step 1) do not count as attempts, so a processor that keeps sending a forbidden key never moves the post to `needs_manual`, which breaks FR-16's "retry once, then needs manual entry". `save_output` does not say whether it raises or returns errors.
- **Fix:** Count every processor-caused error (`forbidden-key`, `invalid-payload`, steps 3–7). Do not count `ai-excluded`, `private-post` or `post-not-waiting`. Give `save_output` the same `{ok:false, code}` convention.

### M-8 — Missing client RPCs for owned FRs
- **Location:** `rpc-contracts.md` §4.
- **Problem:** FR-14 ("A parent can set grade_9_start and graduation_year") and its "grade_levels … filled in from entry dates … can be edited" have no RPC, and no point decides when `grade_levels` is derived (ingest? trigger on date change? on calendar change?). The FR-42 export is an "archive" of JSON plus original files, which an RPC cannot build. The no-build client needs a vendored zip library, or the format has to change.
- **Fix:** Add `set_school_calendar(person_id, grade_9_start, graduation_year)` (parents only). Derive `grade_levels` in the `entries` BEFORE trigger when dates change and the value carries no `by`. For FR-42, the client fetches the RPC's JSON, downloads files through signed URLs, and zips them with a vendored `fflate` (pin the version in Stack). The student variant filters parents_only on the server.

### M-9 — Backup format cannot be restored, and connection details are missing
- **Location:** AD-14, D-3; FR-43.
- **Problem:** A "database JSON" export cannot be restored into a project: it lacks the schema, `auth.users`, storage metadata and sequences. GitHub runners have no IPv6, so a direct `pg_dump` needs the Supavisor session pooler string. No one owns the quarterly restore.
- **Fix:** Back up with `pg_dump --schema=ll --schema=auth --data-only` plus a schema-only dump (through the session pooler, with the DB password held as an ops secret) and a storage file sync. Run all of it through `age` encryption. Keep a JSON copy only if readable exports matter. Add a quarterly reminder (ops workflow issue or Routine) that links to a written restore runbook.

### M-10 — No monitoring or alerting dimension
- **Location:** Spine (absent); AD-16 covers only metrics.
- **Problem:** Nobody is told when the 8:45 pm Claude run silently fails for days (SM-4), a pg_cron job errors (`cron.job_run_details`), the backup fails, or quotas approach their limits. This is an operations dimension that is neither decided nor deferred.
- **Fix:** Add to AD-17 a daily ops workflow that queries `cron.job_run_details`, the oldest `waiting` post age, the last `backup_run` event and quota usage. It emails the owner counts only when a threshold is breached. Otherwise mark this explicitly as Deferred with an owner.

---

## Low

- **L-1 — search_path convention.** AD-2 uses `set search_path = ll, public`. psat-sprint's latest migration uses `set search_path = ''` with fully qualified names, which is stronger against object shadowing. **Fix:** ratify `''` and qualify everything, or state why `ll, public` was chosen.
- **L-2 — Pages deploy mode differs from psat-sprint.** psat-sprint deploys in branch mode with `.nojekyll`, while AD-15 says "standard Pages deploy workflow". It is justified in the memlog (`docs/` holds specs). **Fix:** record the reason in AD-15.
- **L-3 — "Quotes" in FR-6 are not modelled.** Only reflections carry `speaker`, and FR-6 also locks "quotes", for example teacher comment excerpts and quotes inside other entries. **Fix:** state that student-speaker quotes are always reflection entries linked through `related entries`, or add `speaker` to the registry for quote-bearing fields.
- **L-4 — Display names for logins.** `members` has no display label, and the student cannot read the parents' `members` rows. "Captured by Parent B" and "edited by X" (UJ-3, FR-21) therefore have no source. **Fix:** add `members.display_label` and allow every member to read `(user_id, display_label, role)`.
- **L-5 — Output requests that never close.** If the processor omits `request_id`, the partial unique index (D-4) blocks new requests indefinitely. **Fix:** `save_output` closes the open request for `(person_id, kind)` when it receives no `request_id`. Add `cancel_output_request` to settle Q6.
- **L-6 — Student posting parents_only.** A student who posts parents_only creates a post he then cannot read. Parents_only reflections where the student is the speaker can never be confirmed by him. **Fix:** `create_post` and `set_visibility` refuse parents_only for the student, and ingest refuses `parent_note` from a student's post.
- **L-7 — Image spans while OCR is out of scope.** FR-16 puts reading photos out of scope, yet the processor may send `{kind:'image'}` spans that nothing checks, which is a soft SM-5 bypass. **Fix:** reject image spans from `ingest_draft` in v1, and allow them only through `edit_entry` or `answer_gap`.
- **L-8 — Durability of IndexedDB on iOS.** **Fix:** call `navigator.storage.persist()` and keep the PWA-install guidance in `offline-queue.md`. Installed PWAs are exempt from Safari's 7-day eviction; browser tabs are not.
- **L-9 — GitHub Actions scheduling for Eastern time.** AD-13's "hourly job checks local time" rule is written for pg_cron. The ops repo's digest needs either the same gate or two UTC crons (EST/EDT) with a date check. GitHub schedules can also run late. **Fix:** extend AD-13 to ops workflows.
- **L-10 — The "ratified" claim is overstated.** psat-sprint uses client INSERT/UPDATE policies on its `fast_*` tables, so AD-2 tightens the convention rather than ratifying it. **Fix:** reword it as "adopts psat-sprint's Friends pattern and tightens it".
- **L-11 — Capability map granularity.** FR-17 (`create_milestone`), FR-33 (disclaimer copy) and FR-37 (`output_access_log`) are covered only by ranges. **Fix:** give each its own row so story writers can trace them.

---

## Coverage check (FR-1..FR-43, NFRs)

| FR / NFR | Covered by | Status |
|---|---|---|
| FR-1 | AD-8, Auth | **Gap**: 30-day expiry (H-2); sign-up disable and SMTP (H-3) |
| FR-2 | AD-8, rls-matrix | OK |
| FR-3 | AD-8, `signout_student` | **At risk** (H-2) |
| FR-4, FR-5 | AD-4, CHECKs, `narrowest` | OK, subject to views (C-2) and author (H-8) |
| FR-6 | rls-matrix §3 | **Gap**: create_entry (H-6); quotes (L-3) |
| FR-7 | AD-11, `get_output` | **At risk** (H-4) |
| FR-8, FR-9, FR-10 | AD-12, offline-queue | OK (path mismatch M-4) |
| FR-11, FR-12, FR-13 | AD-6, registry | Title and date provenance (M-2) |
| FR-14 | AD-13 `grade_level` | **Gap**: no setter RPC or derivation point (M-8) |
| FR-15, FR-16 | AD-3, AD-9, ingest contract | Grant (C-1), null person (M-3), attempts (M-7), manual path (H-6) |
| FR-17 | `create_milestone` | OK |
| FR-18 | `resolve_duplicate`, `duplicate_flags` | OK |
| FR-19 | `processing/SKILL.md` | OK; add the quoting and role rules (M-6) |
| FR-20, FR-21 | AD-5, AD-7 | Trigger interplay (M-1) |
| FR-22 | AD-10 | **At risk** (H-1, H-7) |
| FR-23, FR-24 | `my_queue`, `my_badge` | OK |
| FR-25 | AD-14 ops digest | OK, given D-3, L-9 and the SMTP decision |
| FR-26 | `timeline` view | **At risk** (C-2) |
| FR-27, FR-28 | `create_post` 8,000 limit, `bulk_confirm` | OK |
| FR-29 | client | OK |
| FR-30 | storage, attachments | **Gap** (H-1, M-4) |
| FR-31, FR-32, FR-33 | `service_hours`, `attest_service_form` | Re-attest rule (M-4); view (C-2) |
| FR-34..FR-41 | AD-11, `save_output` | Quote rule (M-5); redaction (H-7); read path (H-4) |
| FR-42 | `export_person` | Archive format (M-8); signed URLs (H-1) |
| FR-43 | AD-14 | Restore format and target (M-9, H-5) |
| NFR-SEC-1 | test-plan, rls-matrix | Add tests for C-1, C-2, H-3 and H-4 |
| NFR-SEC-2 | Consistency "Secrets" | OK |
| NFR-PERF-1, NFR-PERF-2 | AD-15, test-plan | OK |
| NFR-REL-1 | AD-12, offline-queue | Paused project (H-5) |
| NFR-A11Y-1, NFR-PLAT-1 | AD-15, conventions | OK |
| NFR-AUD-1 | AD-7, access log | Access log can be bypassed (H-4) |
| NFR-OBS-1 | AD-16 | OK |
| PRD §6.1 pre-launch gate | test-plan §4 | OK |

## Recommended order of fixes

1. Fix C-1 and C-2: grants and view security. These are one-paragraph edits to AD-2, AD-3 and AD-4 plus two pgTAP tests.
2. Fix H-2 and H-3: rewrite the session predicate and add an Auth settings section.
3. Fix H-1, H-4 and H-7: storage mechanics, the output read path and redaction.
4. Fix H-5 and add AD-17 Operations envelope, which also absorbs M-9 and M-10.
5. Fix H-6, H-8, M-1 to M-8, and align the companions in one pass.
