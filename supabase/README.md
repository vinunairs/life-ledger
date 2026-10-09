# Database

Migrations in `migrations/` are applied in filename order to the `life-ledger` Supabase project.

| File | Status |
|---|---|
| 000100_core | applied |
| 000200_processing | applied |
| 000400_tighten_missing_required | applied |
| 000500_purge_archived | not yet applied (needs approval: contains a delete) |

## Security tests

`tests/rls_suite.sql` creates throwaway users for every role, tries every allowed and forbidden action, and rolls everything back. Run after any database change:

```sql
select * from tests.rls_suite();
```

All tests must pass before app changes ship.

## Processing contract

The app has no AI inside it. A Claude run on the owner's subscription reads `processing_queue` and writes only through:

- `ingest_draft(post_id, entries)`: creates draft entries; every value must quote the post; status and visibility are set by the database
- `mark_post_manual(post_id, note)`: when a post can't be processed
- `save_output(person_id, kind, items)`: every item must cite confirmed entries
