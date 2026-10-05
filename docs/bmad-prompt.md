# Family Life Ledger — BMAD input

## Project type
Private family web app (mobile-first, installable to home screen). Solo developer. Greenfield repo. Full feature spec: `docs/feature-doc-v2.md` (source of truth; rated 9.5 — follow it, don't re-scope).

## Core problem
Families lose the specific evidence college applications and recommendation letters need, then rebuild it from memory under deadline. Anyone posts in any form; Claude turns posts into draft entries plus gap questions; only human-confirmed entries feed outputs.

## Users
- Parent A (owner), Parent B: parent_admin
- The student (10th grade): student_owner of his own profile
- Younger child (10): profile only, no login, manual entries, never processed by AI

## v1 features, in build order
**M1 — capture core:** email/password auth with three accounts and roles; quick post (text, photos, links, person picker, offline queue); the processing contract (below); review flow draft → needs_detail → confirmed with versioning and 30-day archive; needs-detail queue with badges and opt-in weekly email (counts only); four visibility levels (private, family, parents_only, shareable); timeline view.
**M2 — backfill:** brain-dump editor (8,000 characters) with bulk confirm; profile view by type; private file storage; Bright Futures service-hours tracker (75/100, verified only with a signed-form file and a parent attestation).
**M3 — outputs:** Common App activities draft (10 slots, 50/100/150-character limits) and honors (5); recommender pointers mapped to Common App's 12 Family Brag Sheet questions (parents_only); essay angles that quote only the student-confirmed words and never write essay prose. All outputs are versioned, and their items are hidden from viewers who lose access to a cited entry.

## Technical constraints
- GitHub Pages static front end, plus a new, separate Supabase free-plan project (Postgres, Auth, Storage). No edge functions or AI SDK in v1.
- **No AI inside the app.** Processing runs externally: a Claude scheduled task on the owner's subscription, using the Supabase connector. The app must provide:
  - `ingest_draft(post_id, entries, gaps)` — forces status = draft and default visibility, rejects any field without a source_span, marks the post processed.
  - `save_output(person_id, kind, items)` — stores a new output version with cited entry IDs.
  - A `processing_queue` view (unprocessed posts, excluding the younger child) and an output-request queue.
- Row-level security on every table, with automated tests proving that student_owner can never read parents_only rows. Parents cannot edit or confirm reflections where the student is the speaker.
- Schema per spec section 4, including the Common App field mapping and a per-child school calendar.
- No analytics or third-party scripts; timing events go to the app's own events table.
- Weekly encrypted export to the owner's Google Drive; one-tap per-person export.

## Reference architecture
Same stack and conventions as the owner's Test Prep Hub. Loop: post → external Claude run → ingest_draft → review → confirm → outputs.

## Asks for BMAD
PM agent: PRD and user stories per persona, using the spec's acceptance criteria verbatim. Architect agent: data model and migrations, RLS policy matrix with test cases, the two RPC contracts with JSON schemas, offline queue design, and a test plan. Leave out anything listed as v1.1 or v2.
