-- Life Ledger M1: app actions (confirm, answer, dismiss) and the processing contract.
-- Processing runs outside the app, as Claude on the owner's subscription through the Supabase
-- connector. It may write ONLY through ingest_draft, mark_post_manual and save_output.

-- ---------------------------------------------------------------- app actions (signed-in users)

create function public.confirm_entry(p_entry uuid) returns public.entries
language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
  speaker_owner uuid;
  speaker_name text;
begin
  select * into e from public.entries where id = p_entry for update;
  if not found or not public.can_see(e.visibility, e.created_by) then
    raise exception 'That entry was not found.' using errcode = 'P0002';
  end if;
  if not public.can_write_person(e.person_id) then
    raise exception 'You can''t confirm entries on this profile.' using errcode = '42501';
  end if;
  if e.archived_at is not null then
    raise exception 'Restore this entry before confirming it.';
  end if;
  if e.type = 'reflection' then
    select owner_user_id, display_name into speaker_owner, speaker_name
      from public.people where id = e.speaker_person_id;
    if speaker_owner is not null and speaker_owner <> auth.uid() then
      raise exception 'Only % can confirm their own words.', speaker_name using errcode = '42501';
    end if;
  end if;
  if e.status = 'needs_detail' then
    raise exception 'Answer the open questions first, or mark them as not applicable.';
  end if;
  if e.status = 'confirmed' then
    return e;
  end if;

  update public.entries
     set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now()
   where id = p_entry
  returning * into e;
  return e;
end $$;

create function public.answer_gap(p_gap uuid, p_answer text) returns public.entries
language plpgsql security definer set search_path = '' as $$
declare
  g public.gaps;
  e public.entries;
  who text;
  v jsonb;
  a text := btrim(coalesce(p_answer, ''));
begin
  select * into g from public.gaps where id = p_gap for update;
  if not found then
    raise exception 'That question was not found.' using errcode = 'P0002';
  end if;
  select * into e from public.entries where id = g.entry_id;
  if not public.can_see(e.visibility, e.created_by) then
    raise exception 'That question was not found.' using errcode = 'P0002';
  end if;
  if not public.can_write_person(e.person_id) then
    raise exception 'You can''t answer questions on this profile.' using errcode = '42501';
  end if;
  if g.state <> 'open' then
    raise exception 'This question is already closed.';
  end if;
  if a = '' then
    raise exception 'Type an answer, or mark the question as not applicable.';
  end if;

  select display_name into who from public.app_users where user_id = auth.uid();

  if g.field = '@date' then
    begin
      update public.entries
         set date_start = a::date,
             source_spans = source_spans || jsonb_build_object('date_start', 'answered by ' || coalesce(who, 'a family member'))
       where id = e.id;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception 'Use a date like 2026-03-14.';
    end;
  else
    v := case
      when g.field = 'grade_levels' then
        (select coalesce(jsonb_agg(m[1]::int order by m[1]::int), '[]'::jsonb)
           from regexp_matches(a, '(9|10|11|12)', 'g') as m)
      when g.field in ('hours_per_week', 'weeks_per_year', 'hours', 'field_size')
           and a ~ '^\d+(\.\d+)?$' then to_jsonb(a::numeric)
      else to_jsonb(a)
    end;
    if g.field = 'grade_levels' and jsonb_array_length(v) = 0 then
      raise exception 'List the grades as numbers, like 9, 10.';
    end if;
    update public.entries
       set fields = fields || jsonb_build_object(g.field, v),
           source_spans = source_spans || jsonb_build_object(g.field, 'answered by ' || coalesce(who, 'a family member'))
     where id = e.id;
  end if;

  update public.gaps
     set state = 'answered', answer = a, answered_by = auth.uid(), answered_at = now()
   where id = g.id and state = 'open';

  -- Custom questions (not tied to a required field) don't trigger a status refresh on their own.
  update public.entries set updated_at = now() where id = e.id returning * into e;
  return e;
end $$;

create function public.dismiss_gap(p_gap uuid) returns public.entries
language plpgsql security definer set search_path = '' as $$
declare
  g public.gaps;
  e public.entries;
begin
  select * into g from public.gaps where id = p_gap for update;
  if not found then
    raise exception 'That question was not found.' using errcode = 'P0002';
  end if;
  select * into e from public.entries where id = g.entry_id;
  if not public.can_see(e.visibility, e.created_by) or not public.can_write_person(e.person_id) then
    raise exception 'You can''t change questions on this profile.' using errcode = '42501';
  end if;
  update public.gaps
     set state = 'not_applicable', answered_by = auth.uid(), answered_at = now()
   where id = g.id and state = 'open';
  update public.entries set updated_at = now() where id = e.id returning * into e;
  return e;
end $$;

-- ---------------------------------------------------------------- processing contract (service only)

-- Posts waiting for the processing run. Excludes anyone with ai_processing = false.
create view public.processing_queue
with (security_invoker = true) as
select p.id          as post_id,
       p.person_id,
       pe.display_name as person_name,
       pe.kind       as person_kind,
       pe.grade_9_start,
       pe.graduation_year,
       au.display_name as author_name,
       au.kind       as author_kind,
       p.visibility  as post_visibility,
       p.body,
       p.links,
       p.created_at
  from public.posts p
  join public.people pe on pe.id = p.person_id
  left join public.app_users au on au.user_id = p.author_id
 where p.status = 'waiting'
   and pe.ai_processing
 order by p.created_at;

-- p_entries: JSON array of
--   { "type": entry_type, "title": text, "person_id"?: uuid,
--     "date_start"?: "YYYY-MM-DD", "date_end"?: "YYYY-MM-DD", "date_precision"?: "day"|"month"|"year",
--     "ongoing"?: bool,
--     "fields": { key: value, ... },
--     "source_spans": { key: "exact words copied from the post", ..., "date_start"?: "...", "date_end"?: "..." },
--     "speaker_person_id"?: uuid,                      -- reflections only; defaults to the entry's person
--     "possible_duplicate_of"?: uuid, "duplicate_reason"?: text,
--     "gaps"?: [ { "field": text, "question": text, "required"?: bool } ] }
-- Any "visibility" or "status" keys are ignored: visibility comes from the post, status is always draft.
create function public.ingest_draft(p_post uuid, p_entries jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_post        public.posts;
  v_author_kind text;
  v_person      public.people;
  v_body        text;
  e             jsonb;
  g             jsonb;
  k             text;
  v_span        text;
  v_type        public.entry_type;
  v_fields      jsonb;
  v_spans       jsonb;
  v_keep        jsonb;
  v_start       date;
  v_end         date;
  v_grade       int;
  v_dup         uuid;
  v_speaker     uuid;
  v_id          uuid;
  v_ids         uuid[] := '{}';
  v_n           int := 0;
begin
  select * into v_post from public.posts where id = p_post for update;
  if not found then
    raise exception 'ingest_draft: post % not found', p_post;
  end if;
  if v_post.status <> 'waiting' then
    raise exception 'ingest_draft: post % has status %, expected waiting', p_post, v_post.status;
  end if;
  if p_entries is null or jsonb_typeof(p_entries) <> 'array' then
    raise exception 'ingest_draft: entries must be a JSON array (use [] when the post has nothing to record)';
  end if;

  select kind into v_author_kind from public.app_users where user_id = v_post.author_id;
  v_body := lower(regexp_replace(v_post.body, '\s+', ' ', 'g'));

  for e in select value from jsonb_array_elements(p_entries) loop
    v_n := v_n + 1;

    select * into v_person from public.people
     where id = coalesce(nullif(e ->> 'person_id', '')::uuid, v_post.person_id);
    if not found then
      raise exception 'ingest_draft: entry %: person not found', v_n;
    end if;
    if not v_person.ai_processing then
      raise exception 'ingest_draft: entry %: this person is not processed by AI', v_n;
    end if;
    if not (v_person.owner_user_id = v_post.author_id
            or (v_person.kind = 'child' and v_author_kind = 'parent')) then
      raise exception 'ingest_draft: entry %: the post''s author cannot add entries for this person', v_n;
    end if;

    begin
      v_type := (e ->> 'type')::public.entry_type;
    exception when invalid_text_representation then
      raise exception 'ingest_draft: entry %: unknown type "%"', v_n, e ->> 'type';
    end;
    if v_type is null then
      raise exception 'ingest_draft: entry %: type is required', v_n;
    end if;
    if v_type = 'parent_note' and v_author_kind <> 'parent' then
      raise exception 'ingest_draft: entry %: only parents write parent notes', v_n;
    end if;

    v_fields := coalesce(e -> 'fields', '{}');
    v_spans  := coalesce(e -> 'source_spans', '{}');
    if jsonb_typeof(v_fields) <> 'object' or jsonb_typeof(v_spans) <> 'object' then
      raise exception 'ingest_draft: entry %: fields and source_spans must be JSON objects', v_n;
    end if;

    -- Every value must be backed by words actually in the post.
    v_keep := '{}';
    for k in select key from jsonb_each(v_fields) loop
      if not public.has_value(v_fields -> k) then
        v_fields := v_fields - k;
        continue;
      end if;
      v_span := v_spans ->> k;
      if v_span is null or btrim(v_span) = '' then
        raise exception 'ingest_draft: entry %: field "%" has no source_span', v_n, k;
      end if;
      if position(lower(regexp_replace(btrim(v_span), '\s+', ' ', 'g')) in v_body) = 0 then
        raise exception 'ingest_draft: entry %: source_span for "%" is not an exact quote from the post: "%"', v_n, k, v_span;
      end if;
      v_keep := v_keep || jsonb_build_object(k, btrim(v_span));
    end loop;

    v_start := null;
    v_end := null;
    begin
      v_start := nullif(e ->> 'date_start', '')::date;
      v_end   := nullif(e ->> 'date_end', '')::date;
    exception when others then
      raise exception 'ingest_draft: entry %: dates must look like YYYY-MM-DD', v_n;
    end;
    if v_start is not null then
      v_span := v_spans ->> 'date_start';
      if v_span is null or position(lower(regexp_replace(btrim(v_span), '\s+', ' ', 'g')) in v_body) = 0 then
        raise exception 'ingest_draft: entry %: date_start needs a source_span quoting the post (or leave it out and ask)', v_n;
      end if;
      v_keep := v_keep || jsonb_build_object('date_start', btrim(v_span));
    end if;
    if v_end is not null then
      v_span := v_spans ->> 'date_end';
      if v_span is null or position(lower(regexp_replace(btrim(v_span), '\s+', ' ', 'g')) in v_body) = 0 then
        raise exception 'ingest_draft: entry %: date_end needs a source_span quoting the post', v_n;
      end if;
      v_keep := v_keep || jsonb_build_object('date_end', btrim(v_span));
    end if;

    -- Grade levels can come from the school calendar instead of the post.
    if v_type in ('activity', 'honor') and not public.has_value(v_fields -> 'grade_levels')
       and v_start is not null and v_person.grade_9_start is not null then
      v_grade := 9 + public.school_year(v_start) - public.school_year(v_person.grade_9_start);
      if v_grade between 9 and 12 then
        v_fields := v_fields || jsonb_build_object('grade_levels', jsonb_build_array(v_grade));
        v_keep := v_keep || jsonb_build_object('grade_levels', 'calendar: from the date');
      end if;
    end if;

    v_speaker := null;
    if v_type = 'reflection' then
      v_speaker := coalesce(nullif(e ->> 'speaker_person_id', '')::uuid, v_person.id);
    end if;

    v_dup := nullif(e ->> 'possible_duplicate_of', '')::uuid;
    if v_dup is not null and not exists (
      select 1 from public.entries x where x.id = v_dup and x.person_id = v_person.id and x.type = v_type
    ) then
      v_dup := null;
    end if;

    insert into public.entries (
      person_id, post_id, type, title, date_start, date_end, ongoing, date_precision,
      fields, source_spans, speaker_person_id, visibility, created_by,
      possible_duplicate_of, duplicate_reason
    ) values (
      v_person.id, v_post.id, v_type,
      left(coalesce(nullif(btrim(e ->> 'title'), ''), 'Untitled'), 200),
      v_start, v_end,
      coalesce((e ->> 'ongoing')::boolean, false),
      case when e ->> 'date_precision' in ('day', 'month', 'year') then e ->> 'date_precision' else 'day' end,
      v_fields, v_keep, v_speaker,
      public.default_visibility(v_type, v_post.visibility, v_person.kind),
      v_post.author_id,
      v_dup, case when v_dup is null then null else left(e ->> 'duplicate_reason', 300) end
    ) returning id into v_id;

    -- Claude's own wording for questions; extra questions (like "Who is this about?") are added.
    for g in select value from jsonb_array_elements(coalesce(e -> 'gaps', '[]')) loop
      continue when nullif(btrim(g ->> 'field'), '') is null or nullif(btrim(g ->> 'question'), '') is null;
      if exists (select 1 from public.gaps where entry_id = v_id and field = g ->> 'field' and state = 'open') then
        update public.gaps set question = left(g ->> 'question', 300)
         where entry_id = v_id and field = g ->> 'field' and state = 'open';
      elsif not (g ->> 'field' = any (public.required_fields(v_type))) then
        insert into public.gaps (entry_id, field, question, required)
        values (v_id, g ->> 'field', left(g ->> 'question', 300), coalesce((g ->> 'required')::boolean, false));
      end if;
    end loop;

    update public.entries set updated_at = now() where id = v_id;  -- refresh status after extra questions
    v_ids := v_ids || v_id;
  end loop;

  update public.posts set status = 'processed', processed_at = now(), status_note = null where id = p_post;

  return jsonb_build_object('post_id', p_post, 'entries_created', cardinality(v_ids), 'entry_ids', to_jsonb(v_ids));
end $$;

create function public.mark_post_manual(p_post uuid, p_note text) returns void
language sql security definer set search_path = '' as $$
  update public.posts
     set status = 'manual', status_note = left(coalesce(p_note, 'Could not be processed automatically.'), 300),
         processed_at = now()
   where id = p_post and status = 'waiting'
$$;

-- p_items: JSON array of { "heading"?: text, "body": text, "cited_entry_ids": [uuid, ...] }
create function public.save_output(p_person uuid, p_kind public.output_kind, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_vis public.visibility := case when p_kind = 'recommender_pointers' then 'parents_only' else 'family' end;
  v_ver int;
  v_out uuid;
  it jsonb;
  c text;
  ent public.entries;
  pos int := 0;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'save_output: items must be a non-empty JSON array';
  end if;
  if not exists (select 1 from public.people where id = p_person) then
    raise exception 'save_output: person not found';
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    pos := pos + 1;
    if nullif(btrim(it ->> 'body'), '') is null then
      raise exception 'save_output: item % has no body', pos;
    end if;
    if jsonb_typeof(it -> 'cited_entry_ids') <> 'array' or jsonb_array_length(it -> 'cited_entry_ids') = 0 then
      raise exception 'save_output: item % cites no entries; every item needs evidence', pos;
    end if;
    for c in select value from jsonb_array_elements_text(it -> 'cited_entry_ids') loop
      select * into ent from public.entries where id = c::uuid;
      if not found or ent.person_id <> p_person then
        raise exception 'save_output: item % cites % which is not one of this person''s entries', pos, c;
      end if;
      if ent.status <> 'confirmed' or ent.archived_at is not null then
        raise exception 'save_output: item % cites an unconfirmed or archived entry (%)', pos, c;
      end if;
      if ent.visibility = 'private' then
        raise exception 'save_output: item % cites a private entry (%)', pos, c;
      end if;
      if ent.visibility = 'parents_only' and v_vis <> 'parents_only' then
        raise exception 'save_output: item % cites a parents-only entry in a family-visible output (%)', pos, c;
      end if;
      if p_kind = 'essay_angles' and ent.type = 'parent_note' then
        raise exception 'save_output: essay angles cannot use parent notes (item %)', pos;
      end if;
    end loop;
  end loop;

  select coalesce(max(version), 0) + 1 into v_ver from public.outputs where person_id = p_person and kind = p_kind;
  insert into public.outputs (person_id, kind, version, visibility)
  values (p_person, p_kind, v_ver, v_vis) returning id into v_out;

  insert into public.output_items (output_id, position, heading, body, cited_entry_ids)
  select v_out, x.ord, nullif(btrim(x.item ->> 'heading'), ''), btrim(x.item ->> 'body'),
         array(select value::uuid from jsonb_array_elements_text(x.item -> 'cited_entry_ids'))
    from jsonb_array_elements(p_items) with ordinality as x(item, ord);

  update public.output_requests set status = 'done', done_at = now()
   where person_id = p_person and kind = p_kind and status = 'queued';

  return jsonb_build_object('output_id', v_out, 'version', v_ver, 'items', jsonb_array_length(p_items));
end $$;

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

-- ---------------------------------------------------------------- privileges
revoke execute on function
  public.confirm_entry(uuid), public.answer_gap(uuid, text), public.dismiss_gap(uuid),
  public.ingest_draft(uuid, jsonb), public.mark_post_manual(uuid, text),
  public.save_output(uuid, public.output_kind, jsonb), public.purge_archived()
  from public, anon, authenticated;
grant execute on function
  public.confirm_entry(uuid), public.answer_gap(uuid, text), public.dismiss_gap(uuid)
  to authenticated;
revoke all on public.processing_queue from anon, authenticated;
