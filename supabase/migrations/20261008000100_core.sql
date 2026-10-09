-- Life Ledger M1: core schema, roles and row-level security.
-- Spec: docs/feature-doc-v2.md sections 3 (permissions) and 4 (schema).
-- No real names or family data in this file; people and invites are seeded separately.

-- ---------------------------------------------------------------- types
create type public.visibility as enum ('private', 'family', 'parents_only', 'shareable');
create type public.entry_status as enum ('draft', 'needs_detail', 'confirmed');
create type public.entry_type as enum (
  'activity', 'honor', 'work_sample', 'service', 'academic',
  'score', 'reflection', 'milestone', 'parent_note'
);
create type public.post_status as enum ('waiting', 'processed', 'manual', 'skipped');
create type public.gap_state as enum ('open', 'answered', 'not_applicable');
create type public.output_kind as enum ('activities', 'honors', 'recommender_pointers', 'essay_angles');

-- ---------------------------------------------------------------- tables
create table public.app_users (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  kind         text not null check (kind in ('parent', 'student')),
  created_at   timestamptz not null default now()
);

create table public.people (
  id              uuid primary key default gen_random_uuid(),
  display_name    text not null,
  kind            text not null check (kind in ('parent', 'child')),
  owner_user_id   uuid unique references auth.users(id) on delete set null,
  grade_9_start   date,
  graduation_year int,
  ai_processing   boolean not null default true,
  created_at      timestamptz not null default now()
);

-- Only invited emails become members. Uninvited sign-ups get no app_users row and see nothing.
create table public.invites (
  email        text primary key check (email = lower(email)),
  kind         text not null check (kind in ('parent', 'student')),
  person_id    uuid not null references public.people(id) on delete cascade,
  display_name text not null,
  used_at      timestamptz
);

create table public.posts (
  id                 uuid primary key default gen_random_uuid(),
  person_id          uuid not null references public.people(id) on delete cascade,
  author_id          uuid not null default auth.uid() references auth.users(id),
  body               text not null check (char_length(body) between 1 and 8000),
  links              text[] not null default '{}',
  visibility         public.visibility not null default 'family',
  status             public.post_status not null default 'waiting',
  status_note        text,
  client_duration_ms int check (client_duration_ms >= 0),
  created_at         timestamptz not null default now(),
  processed_at       timestamptz
);
create index posts_waiting_idx on public.posts (created_at) where status = 'waiting';

create table public.entries (
  id                    uuid primary key default gen_random_uuid(),
  person_id             uuid not null references public.people(id) on delete cascade,
  post_id               uuid references public.posts(id) on delete restrict,
  type                  public.entry_type not null,
  title                 text not null check (char_length(title) between 1 and 200),
  date_start            date,
  date_end              date,
  ongoing               boolean not null default false,
  date_precision        text not null default 'day' check (date_precision in ('day', 'month', 'year')),
  fields                jsonb not null default '{}' check (jsonb_typeof(fields) = 'object'),
  source_spans          jsonb not null default '{}' check (jsonb_typeof(source_spans) = 'object'),
  speaker_person_id     uuid references public.people(id),
  visibility            public.visibility not null default 'family',
  status                public.entry_status not null default 'draft',
  possible_duplicate_of uuid references public.entries(id) on delete set null,
  duplicate_reason      text,
  created_by            uuid not null default auth.uid() references auth.users(id),
  confirmed_by          uuid references auth.users(id),
  confirmed_at          timestamptz,
  archived_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint parent_note_is_parents_only check (type <> 'parent_note' or visibility = 'parents_only'),
  constraint scores_never_shareable check (type not in ('score', 'academic') or visibility <> 'shareable'),
  constraint reflection_has_speaker check (type <> 'reflection' or speaker_person_id is not null)
);
create index entries_person_idx on public.entries (person_id, type) where archived_at is null;
create index entries_post_idx on public.entries (post_id);

create table public.entry_versions (
  id         bigint generated always as identity primary key,
  entry_id   uuid not null references public.entries(id) on delete cascade,
  editor_id  uuid,
  snapshot   jsonb not null,
  created_at timestamptz not null default now()
);
create index entry_versions_entry_idx on public.entry_versions (entry_id, created_at desc);

create table public.gaps (
  id          uuid primary key default gen_random_uuid(),
  entry_id    uuid not null references public.entries(id) on delete cascade,
  field       text not null,
  question    text not null,
  required    boolean not null default true,
  state       public.gap_state not null default 'open',
  answer      text,
  answered_by uuid references auth.users(id),
  answered_at timestamptz,
  created_at  timestamptz not null default now()
);
create unique index gaps_one_live_per_field on public.gaps (entry_id, field) where state <> 'answered';

create table public.outputs (
  id         uuid primary key default gen_random_uuid(),
  person_id  uuid not null references public.people(id) on delete cascade,
  kind       public.output_kind not null,
  version    int not null,
  visibility public.visibility not null check (visibility in ('family', 'parents_only')),
  created_at timestamptz not null default now(),
  unique (person_id, kind, version)
);

create table public.output_items (
  id              uuid primary key default gen_random_uuid(),
  output_id       uuid not null references public.outputs(id) on delete cascade,
  position        int not null,
  heading         text,
  body            text not null,
  final_body      text,
  cited_entry_ids uuid[] not null default '{}',
  redacted        boolean not null default false
);
create index output_items_output_idx on public.output_items (output_id, position);

create table public.output_requests (
  id           uuid primary key default gen_random_uuid(),
  person_id    uuid not null references public.people(id) on delete cascade,
  kind         public.output_kind not null,
  requested_by uuid not null default auth.uid() references auth.users(id),
  status       text not null default 'queued' check (status in ('queued', 'done', 'failed')),
  created_at   timestamptz not null default now(),
  done_at      timestamptz
);

create table public.events (
  id         bigint generated always as identity primary key,
  user_id    uuid default auth.uid(),
  name       text not null check (char_length(name) <= 60),
  value      numeric,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- helpers
create function public.my_kind() returns text
language sql stable security definer set search_path = '' as $$
  select kind from public.app_users where user_id = auth.uid()
$$;

create function public.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.app_users where user_id = auth.uid())
$$;

create function public.is_parent() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.my_kind() = 'parent', false)
$$;

-- Who can create and edit on a person's profile (spec section 3, action matrix).
create function public.can_write_person(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.people pp
    where pp.id = p
      and (pp.owner_user_id = auth.uid() or (pp.kind = 'child' and public.is_parent()))
  )
$$;

-- Who can read a row with a given visibility.
create function public.can_see(v public.visibility, creator uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case v
    when 'private'      then creator is not null and creator = auth.uid()
    when 'parents_only' then public.is_parent()
    else public.is_member()
  end
$$;

create function public.has_value(v jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select v is not null
     and jsonb_typeof(v) <> 'null'
     and not (jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '')
     and not (jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 0)
$$;

-- Required fields per type. '@date' means the date_start column.
create function public.required_fields(t public.entry_type) returns text[]
language sql immutable set search_path = '' as $$
  select case t
    when 'activity'    then array['activity_type','organization','role','grade_levels','timing','hours_per_week','weeks_per_year','description']
    when 'honor'       then array['award_name','awarding_org','level','grade_levels']
    when 'work_sample' then array['@date','kind','link','collaboration']
    when 'service'     then array['@date','organization','hours','description']
    when 'academic'    then array['course','term']
    when 'score'       then array['@date','test','score']
    when 'reflection'  then array['text']
    when 'milestone'   then array['@date']
    when 'parent_note' then array['text']
  end
$$;

create function public.default_question(k text) returns text
language sql immutable set search_path = '' as $$
  select case k
    when '@date'          then 'When did this happen?'
    when 'activity_type'  then 'Which Common App activity type fits best (for example Music: Instrumental, Community Service)?'
    when 'organization'   then 'Which organization or group was this with?'
    when 'role'           then 'What was the role or position?'
    when 'grade_levels'   then 'Which grades did this cover (9, 10, 11, 12)?'
    when 'timing'         then 'Was this during the school year, during breaks, or all year?'
    when 'hours_per_week' then 'About how many hours a week?'
    when 'weeks_per_year' then 'About how many weeks a year?'
    when 'description'    then 'In one sentence, what was done?'
    when 'award_name'     then 'What is the exact name of the award?'
    when 'awarding_org'   then 'Which organization gave the award?'
    when 'level'          then 'What level was it: school, state or regional, national, or international?'
    when 'kind'           then 'What kind of work is it: composition, recording, project, or writing?'
    when 'link'           then 'Is there a link to it (Apple Music, YouTube, a website)?'
    when 'collaboration'  then 'Was this solo or with others?'
    when 'hours'          then 'How many hours in total?'
    when 'course'         then 'Which course or assignment?'
    when 'term'           then 'Which term or semester?'
    when 'test'           then 'Which test was it?'
    when 'score'          then 'What was the score?'
    when 'text'           then 'What are the exact words?'
    else 'What is the ' || replace(k, '_', ' ') || '?'
  end
$$;

create function public.missing_required(p_id uuid, p_type public.entry_type, p_fields jsonb, p_date date)
returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(k), '{}')
  from unnest(public.required_fields(p_type)) as k
  where (case when k = '@date' then p_date is null else not public.has_value(p_fields -> k) end)
    and not exists (
      select 1 from public.gaps g
      where g.entry_id = p_id and g.field = k and g.state = 'not_applicable'
    )
$$;

-- School year starting August 1.
create function public.school_year(d date) returns int
language sql immutable set search_path = '' as $$
  select extract(year from d)::int - case when extract(month from d) < 8 then 1 else 0 end
$$;

create function public.default_visibility(t public.entry_type, post_vis public.visibility, person_kind text)
returns public.visibility
language sql immutable set search_path = '' as $$
  select case
    when t = 'parent_note'            then 'parents_only'::public.visibility
    when post_vis = 'private'         then 'private'::public.visibility
    when post_vis = 'parents_only'    then 'parents_only'::public.visibility
    when person_kind = 'parent'       then 'private'::public.visibility
    else 'family'::public.visibility
  end
$$;

-- ---------------------------------------------------------------- triggers
-- New sign-ups become members only if invited.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare inv public.invites;
begin
  select * into inv from public.invites where email = lower(new.email) and used_at is null;
  if found then
    insert into public.app_users (user_id, display_name, kind) values (new.id, inv.display_name, inv.kind);
    update public.people set owner_user_id = new.id where id = inv.person_id;
    update public.invites set used_at = now() where email = inv.email;
  end if;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.posts_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not (select ai_processing from public.people where id = new.person_id) then
    new.status := 'skipped';
    new.status_note := 'Not processed by AI; add entries by hand.';
  end if;
  return new;
end $$;

create trigger posts_before_insert
  before insert on public.posts
  for each row execute function public.posts_before_insert();

-- Guards, provenance and status for every entry write.
create function public.entries_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  who text;
  k text;
  speaker_owner uuid;
  missing text[];
  open_required boolean;
begin
  if new.type = 'parent_note' then
    new.visibility := 'parents_only';
  end if;

  if uid is not null then
    select display_name into who from public.app_users where user_id = uid;

    if new.visibility = 'parents_only' and not public.is_parent() then
      raise exception 'Only parents can make something parents-only.' using errcode = '42501';
    end if;

    if tg_op = 'UPDATE' then
      if new.visibility is distinct from old.visibility and old.created_by <> uid then
        raise exception 'Only the person who posted this can change who sees it.' using errcode = '42501';
      end if;
      if new.archived_at is distinct from old.archived_at and old.created_by <> uid and not public.is_parent() then
        raise exception 'You can only archive your own posts.' using errcode = '42501';
      end if;
      if old.type = 'reflection' and (new.fields -> 'text') is distinct from (old.fields -> 'text') then
        select owner_user_id into speaker_owner from public.people where id = old.speaker_person_id;
        if speaker_owner is not null and speaker_owner <> uid then
          raise exception 'These are someone else''s own words, so only they can change them.' using errcode = '42501';
        end if;
      end if;
      -- Any field the user changed is now sourced from that user.
      for k in select key from jsonb_each(new.fields) loop
        if (new.fields -> k) is distinct from (old.fields -> k)
           and (new.source_spans -> k) is not distinct from (old.source_spans -> k) then
          new.source_spans := new.source_spans || jsonb_build_object(k, 'edited by ' || coalesce(who, 'a family member'));
        end if;
      end loop;
      if new.date_start is distinct from old.date_start
         and (new.source_spans -> 'date_start') is not distinct from (old.source_spans -> 'date_start') then
        new.source_spans := new.source_spans || jsonb_build_object('date_start', 'edited by ' || coalesce(who, 'a family member'));
      end if;
    else
      -- Entered by hand: every field is sourced from the person who typed it.
      for k in select key from jsonb_each(new.fields) loop
        if not public.has_value(new.source_spans -> k) then
          new.source_spans := new.source_spans || jsonb_build_object(k, 'entered by ' || coalesce(who, 'a family member'));
        end if;
      end loop;
      if new.date_start is not null and not public.has_value(new.source_spans -> 'date_start') then
        new.source_spans := new.source_spans || jsonb_build_object('date_start', 'entered by ' || coalesce(who, 'a family member'));
      end if;
    end if;
  end if;

  -- Status follows completeness. Only confirm_entry() can set confirmed.
  missing := public.missing_required(new.id, new.type, new.fields, new.date_start);
  open_required := exists (
    select 1 from public.gaps g where g.entry_id = new.id and g.state = 'open' and g.required
      and not (g.field = any (public.required_fields(new.type)))
  );
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.confirmed_by := null;
    new.confirmed_at := null;
  end if;
  if cardinality(missing) > 0 or open_required then
    new.status := 'needs_detail';
    new.confirmed_by := null;
    new.confirmed_at := null;
  elsif new.status = 'needs_detail' then
    new.status := 'draft';
  end if;

  new.updated_at := now();
  return new;
end $$;

create trigger entries_before_write
  before insert or update on public.entries
  for each row execute function public.entries_before_write();

-- Keep one open question per missing required field; close questions whose answer arrived.
create function public.entries_sync_gaps() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  foreach k in array public.missing_required(new.id, new.type, new.fields, new.date_start) loop
    if not exists (select 1 from public.gaps where entry_id = new.id and field = k and state <> 'answered') then
      insert into public.gaps (entry_id, field, question, required)
      values (new.id, k, public.default_question(k), true);
    end if;
  end loop;

  update public.gaps g
     set state = 'answered',
         answer = coalesce(g.answer, case when g.field = '@date' then new.date_start::text else new.fields ->> g.field end),
         answered_by = coalesce(g.answered_by, auth.uid()),
         answered_at = coalesce(g.answered_at, now())
   where g.entry_id = new.id
     and g.state = 'open'
     and g.field = any (public.required_fields(new.type))
     and not (g.field = any (public.missing_required(new.id, new.type, new.fields, new.date_start)));
  return null;
end $$;

create trigger entries_sync_gaps
  after insert or update on public.entries
  for each row execute function public.entries_sync_gaps();

-- Version history: keep the previous state on every meaningful change.
create function public.entries_keep_version() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (to_jsonb(old) - 'updated_at' - 'status' - 'confirmed_by' - 'confirmed_at')
     is distinct from (to_jsonb(new) - 'updated_at' - 'status' - 'confirmed_by' - 'confirmed_at')
     or old.status is distinct from new.status then
    insert into public.entry_versions (entry_id, editor_id, snapshot)
    values (old.id, auth.uid(), to_jsonb(old));
  end if;
  return null;
end $$;

create trigger entries_keep_version
  after update on public.entries
  for each row execute function public.entries_keep_version();

-- ---------------------------------------------------------------- row-level security
alter table public.app_users       enable row level security;
alter table public.people          enable row level security;
alter table public.invites         enable row level security;
alter table public.posts           enable row level security;
alter table public.entries         enable row level security;
alter table public.entry_versions  enable row level security;
alter table public.gaps            enable row level security;
alter table public.outputs         enable row level security;
alter table public.output_items    enable row level security;
alter table public.output_requests enable row level security;
alter table public.events          enable row level security;

create policy "members read members" on public.app_users
  for select to authenticated using (public.is_member());

create policy "members read people" on public.people
  for select to authenticated using (public.is_member());

create policy "read posts by visibility" on public.posts
  for select to authenticated using (public.can_see(visibility, author_id));
create policy "post on profiles you can write" on public.posts
  for insert to authenticated
  with check (author_id = auth.uid()
              and public.can_write_person(person_id)
              and (visibility <> 'parents_only' or public.is_parent()));
create policy "delete own unprocessed posts" on public.posts
  for delete to authenticated using (author_id = auth.uid());

create policy "read entries by visibility" on public.entries
  for select to authenticated using (public.can_see(visibility, created_by));
create policy "add entries on profiles you can write" on public.entries
  for insert to authenticated
  with check (public.can_write_person(person_id) and created_by = auth.uid());
create policy "edit entries on profiles you can write" on public.entries
  for update to authenticated
  using (public.can_write_person(person_id) and public.can_see(visibility, created_by))
  with check (public.can_write_person(person_id));

create policy "read history of readable entries" on public.entry_versions
  for select to authenticated
  using (exists (select 1 from public.entries e where e.id = entry_id));

create policy "read questions on readable entries" on public.gaps
  for select to authenticated
  using (exists (select 1 from public.entries e where e.id = entry_id));

create policy "read outputs by visibility" on public.outputs
  for select to authenticated using (public.can_see(visibility, null));

-- An item disappears for anyone who cannot read every entry it cites.
create policy "read output items you are allowed to see" on public.output_items
  for select to authenticated
  using (
    not redacted
    and exists (select 1 from public.outputs o where o.id = output_id)
    and not exists (
      select 1 from unnest(cited_entry_ids) as c(id)
      where not exists (select 1 from public.entries e where e.id = c.id and e.archived_at is null)
    )
  );
create policy "edit final text of visible items" on public.output_items
  for update to authenticated
  using (
    not redacted
    and exists (select 1 from public.outputs o where o.id = output_id and public.can_write_person(o.person_id))
    and not exists (
      select 1 from unnest(cited_entry_ids) as c(id)
      where not exists (select 1 from public.entries e where e.id = c.id and e.archived_at is null)
    )
  );

create policy "read own or (parents) all requests" on public.output_requests
  for select to authenticated using (requested_by = auth.uid() or public.is_parent());
create policy "request outputs for profiles you can write" on public.output_requests
  for insert to authenticated
  with check (requested_by = auth.uid()
              and public.can_write_person(person_id)
              and (kind <> 'recommender_pointers' or public.is_parent()));

create policy "log own events" on public.events
  for insert to authenticated with check (user_id = auth.uid());

-- ---------------------------------------------------------------- privileges
-- Start from nothing, then grant exactly what the app needs.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on public.app_users, public.people to authenticated;

grant select, delete on public.posts to authenticated;
grant insert (person_id, body, links, visibility, client_duration_ms) on public.posts to authenticated;

grant select on public.entries to authenticated;
grant insert (person_id, post_id, type, title, date_start, date_end, ongoing, date_precision,
              fields, source_spans, speaker_person_id, visibility)
  on public.entries to authenticated;
grant update (title, date_start, date_end, ongoing, date_precision, fields, source_spans,
              visibility, archived_at)
  on public.entries to authenticated;

grant select on public.entry_versions, public.gaps, public.outputs to authenticated;
grant select on public.output_items to authenticated;
grant update (final_body) on public.output_items to authenticated;
grant select on public.output_requests to authenticated;
grant insert (person_id, kind) on public.output_requests to authenticated;
grant insert (name, value) on public.events to authenticated;

-- Helper functions: callable by signed-in users (policies need them), never by anonymous visitors.
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.my_kind(), public.is_member(), public.is_parent(),
  public.can_write_person(uuid), public.can_see(public.visibility, uuid),
  public.has_value(jsonb), public.required_fields(public.entry_type),
  public.default_question(text), public.school_year(date),
  public.missing_required(uuid, public.entry_type, jsonb, date),
  public.default_visibility(public.entry_type, public.visibility, text)
  to authenticated;
revoke execute on function
  public.handle_new_user(), public.posts_before_insert(), public.entries_before_write(),
  public.entries_sync_gaps(), public.entries_keep_version()
  from authenticated;
