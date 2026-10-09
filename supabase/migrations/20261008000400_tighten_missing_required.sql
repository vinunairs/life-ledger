-- Supabase advisor fix: missing_required no longer runs with owner rights and is not callable from the app.
-- Triggers still use it (they run as the owner).
alter function public.missing_required(uuid, public.entry_type, jsonb, date) security invoker;
revoke execute on function public.missing_required(uuid, public.entry_type, jsonb, date) from authenticated;
