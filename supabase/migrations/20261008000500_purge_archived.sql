-- Life Ledger M1: 30-day archive cleanup. Kept in its own migration because it contains a delete.

-- Archived entries are kept 30 days, then removed; any output item that cited them is permanently redacted.
create function public.purge_archived() returns int
language plpgsql security definer set search_path = '' as $$
declare
  gone uuid[];
begin
  select coalesce(array_agg(id), '{}') into gone
    from public.entries where archived_at < now() - interval '30 days';
  if cardinality(gone) = 0 then
    return 0;
  end if;
  update public.output_items
     set body = '[removed]', heading = null, final_body = null, redacted = true
   where cited_entry_ids && gone;
  update public.entries set possible_duplicate_of = null where possible_duplicate_of = any (gone);
  delete from public.entries where id = any (gone);
  return cardinality(gone);
end $$;

revoke execute on function public.purge_archived() from public, anon, authenticated;
