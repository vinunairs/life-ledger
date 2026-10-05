# Addendum — Family Life Ledger PRD

Detail the PRD deliberately leaves out because it is implementation or downstream-architecture material. Carried forward from `docs/bmad-prompt.md` and `docs/feature-doc-v2.md` §8 so the Architect step has it in one place.

## Fixed technical constraints (from the owner; not open for re-decision)

- **Front end:** static site on GitHub Pages; mobile-first, installable to home screen (PWA).
- **Back end:** a new, separate Supabase free-plan project (Postgres, Auth, Storage). This is the owner's second active free slot; the existing test-prep project is the first. No edge functions and no AI SDK in v1.
- **Reference architecture:** same stack and conventions as the owner's Test Prep Hub.
- **Processing:** a Claude scheduled task on the owner's subscription (daily 8:45 pm Eastern, plus on demand), reaching the database through the owner's Supabase connector.
- **Auth:** email + password (chosen over magic link — spec §9 default).
- **Secrets:** only the Supabase public (anon) key in the app.

## Loop

post → external Claude run → `ingest_draft` → review → confirm → outputs (`save_output`).

## Architect asks (from the kickoff prompt)

1. Data model and migrations per spec §4, including the Common App field mapping and the per-child school calendar.
2. RLS policy matrix with a test case per cell of PRD FR-6, plus the student-never-reads-parents_only test and the parent-cannot-confirm-student-reflection test.
3. The two RPC contracts with JSON schemas:
   - `ingest_draft(post_id, entries, gaps)` — forces `status = draft` and default visibility; rejects any field without `source_span`; marks the post processed; rejects younger-child posts.
   - `save_output(person_id, kind, items)` — stores a new output version with cited entry IDs; rejects unconfirmed / archived citations.
4. A `processing_queue` view (unprocessed posts, excluding the younger child) and an output-request queue.
5. Offline queue design for quick post (local persistence, retry, idempotency so a post is never sent twice).
6. Test plan.
7. Leave out anything listed as v1.1 or v2.

## Mechanism notes for the Architect

- **Scheduled jobs without edge functions** (PRD Q4): purge after 30 days, Sunday 6 pm Eastern digest email, weekly encrypted export to Google Drive. Options to evaluate: Postgres-side scheduler for purge; GitHub Actions on a schedule for backup/digest (keys held as repo secrets, never in code); or extending the Claude scheduled task. Note the digest must contain counts and a link only.
- **Timing events:** `events` table, e.g. `post_duration` from screen-open to submit.
- **Nightly accuracy check:** a query asserting zero confirmed fields without a source span or user answer (SM-5).
- **Output diff:** store generated text and final text per item so the character-difference metric (SM-7) is computable.
- **Upgrade seam:** an in-app Claude API step can later replace the daily run without schema changes, so keep all AI writes behind the two RPCs.
- **Backup restore:** quarterly restore test into a scratch Supabase project; encryption key in the owner's password manager, never in the same Drive account.
- **Pre-launch check:** confirm the model provider's API data-retention and training terms.
