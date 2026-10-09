-- Life Ledger security test suite.
-- Run any time with:  select * from tests.rls_suite();
-- Creates throwaway people and users, acts as each role, records results, then rolls everything back.

create schema if not exists tests;
revoke all on schema tests from public, anon, authenticated;

create or replace function tests.rls_suite()
returns table (test text, pass boolean, detail text)
language plpgsql set search_path = '' as $$
declare
  r jsonb := '[]';
  pa uuid := gen_random_uuid();
  pb uuid := gen_random_uuid();
  st uuid := gen_random_uuid();
  ou uuid := gen_random_uuid();
  p_child uuid; p_young uuid; p_pa uuid; p_pb uuid;
  post_fam uuid; post_po uuid; post_young uuid;
  e_fam uuid; e_note uuid; e_young uuid; e_priv uuid; e_refl uuid;
  o_essay uuid;
  g uuid; n int; s text; x jsonb;
begin
  begin
    -- ---------------------------------------------------------------- setup (as owner)
    insert into public.people (display_name, kind, grade_9_start, graduation_year)
      values ('T Student', 'child', '2025-08-01', 2029) returning id into p_child;
    insert into public.people (display_name, kind, ai_processing)
      values ('T Younger', 'child', false) returning id into p_young;
    insert into public.people (display_name, kind) values ('T Parent A', 'parent') returning id into p_pa;
    insert into public.people (display_name, kind) values ('T Parent B', 'parent') returning id into p_pb;
    insert into public.invites (email, kind, person_id, display_name) values
      ('t-pa@example.test', 'parent', p_pa, 'T Parent A'),
      ('t-pb@example.test', 'parent', p_pb, 'T Parent B'),
      ('t-st@example.test', 'student', p_child, 'T Student');
    insert into auth.users (id, email, aud, role) values
      (pa, 't-pa@example.test', 'authenticated', 'authenticated'),
      (pb, 't-pb@example.test', 'authenticated', 'authenticated'),
      (st, 't-st@example.test', 'authenticated', 'authenticated'),
      (ou, 't-outsider@example.test', 'authenticated', 'authenticated');

    select count(*) into n from public.app_users where user_id in (pa, pb, st, ou);
    r := r || jsonb_build_array(jsonb_build_object('test', 'only invited sign-ups become members', 'pass', n = 3, 'detail', n || ' members'));

    -- ---------------------------------------------------------------- parent A posts
    perform set_config('request.jwt.claims', json_build_object('sub', pa, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    insert into public.posts (person_id, body)
      values (p_child, 'T Student won the regional composition prize on March 14 2026 for an orchestra piece.')
      returning id into post_fam;
    insert into public.posts (person_id, body, visibility)
      values (p_child, 'Parents only: worried about workload this term.', 'parents_only') returning id into post_po;
    insert into public.posts (person_id, body)
      values (p_young, 'Younger child danced at the festival.') returning id into post_young;
    insert into public.entries (person_id, type, title, fields)
      values (p_child, 'parent_note', 'Handles setbacks', '{"text":"Bounced back after losing the first round."}')
      returning id into e_note;
    insert into public.entries (person_id, type, title, date_start)
      values (p_young, 'milestone', 'Festival dance', '2026-09-20') returning id into e_young;
    insert into public.entries (person_id, type, title, visibility)
      values (p_pa, 'activity', 'Parent private item', 'private') returning id into e_priv;
    insert into public.entries (person_id, type, title, fields, speaker_person_id)
      values (p_child, 'reflection', 'On composing', '{"text":"I learned to cut what does not serve the piece."}', p_child)
      returning id into e_refl;
    perform public.confirm_entry(e_note);
    execute 'reset role';

    select status into s from public.posts where id = post_young;
    r := r || jsonb_build_array(jsonb_build_object('test', 'younger child''s posts skip AI processing', 'pass', s = 'skipped', 'detail', s));
    select count(*) into n from public.processing_queue where post_id = post_young;
    r := r || jsonb_build_array(jsonb_build_object('test', 'younger child''s posts never reach the processing queue', 'pass', n = 0, 'detail', n || ' rows'));

    -- ---------------------------------------------------------------- processing contract
    x := public.ingest_draft(post_fam, jsonb_build_array(jsonb_build_object(
      'type', 'honor', 'title', 'Regional composition prize',
      'date_start', '2026-03-14',
      'fields', jsonb_build_object('award_name', 'regional composition prize', 'level', 'regional'),
      'source_spans', jsonb_build_object('award_name', 'regional composition prize', 'level', 'regional', 'date_start', 'March 14 2026'),
      'visibility', 'shareable', 'status', 'confirmed',
      'gaps', jsonb_build_array(jsonb_build_object('field', 'awarding_org', 'question', 'Who ran the competition?'))
    )));
    e_fam := (x -> 'entry_ids' ->> 0)::uuid;
    select status::text || '/' || visibility::text into s from public.entries where id = e_fam;
    r := r || jsonb_build_array(jsonb_build_object('test', 'processing cannot set status or visibility (injection ignored)', 'pass', s = 'needs_detail/family', 'detail', s));
    select fields ->> 'grade_levels' into s from public.entries where id = e_fam;
    r := r || jsonb_build_array(jsonb_build_object('test', 'grade level filled from the school calendar', 'pass', s = '[9]', 'detail', s));
    select question into s from public.gaps where entry_id = e_fam and field = 'awarding_org' and state = 'open';
    r := r || jsonb_build_array(jsonb_build_object('test', 'Claude''s question wording replaces the default', 'pass', s = 'Who ran the competition?', 'detail', coalesce(s, 'no gap')));

    begin
      perform public.ingest_draft(post_po, jsonb_build_array(jsonb_build_object(
        'type', 'honor', 'title', 'Invented',
        'fields', jsonb_build_object('award_name', 'national championship'),
        'source_spans', jsonb_build_object('award_name', 'national championship'))));
      r := r || jsonb_build_array(jsonb_build_object('test', 'processing rejects values not quoted from the post', 'pass', false, 'detail', 'accepted'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'processing rejects values not quoted from the post', 'pass', sqlerrm like '%not an exact quote%', 'detail', sqlerrm));
    end;

    begin
      perform public.ingest_draft(post_young, '[]'::jsonb);
      r := r || jsonb_build_array(jsonb_build_object('test', 'processing refuses the younger child''s posts', 'pass', false, 'detail', 'accepted'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'processing refuses the younger child''s posts', 'pass', true, 'detail', sqlerrm));
    end;

    -- ---------------------------------------------------------------- parent A answers, confirms, and hits the locks
    perform set_config('request.jwt.claims', json_build_object('sub', pa, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select id into g from public.gaps where entry_id = e_fam and field = 'awarding_org' and state = 'open';
    perform public.answer_gap(g, 'State Music Association');
    select status::text into s from public.entries where id = e_fam;
    r := r || jsonb_build_array(jsonb_build_object('test', 'answering the last question makes the entry ready to confirm', 'pass', s = 'draft', 'detail', s));
    perform public.confirm_entry(e_fam);
    select status::text into s from public.entries where id = e_fam;
    r := r || jsonb_build_array(jsonb_build_object('test', 'parent can confirm a complete entry', 'pass', s = 'confirmed', 'detail', s));

    begin
      perform public.confirm_entry(e_refl);
      r := r || jsonb_build_array(jsonb_build_object('test', 'parent cannot confirm the student''s own words', 'pass', false, 'detail', 'confirmed'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'parent cannot confirm the student''s own words', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      update public.entries set fields = '{"text":"Edited by a parent."}' where id = e_refl;
      r := r || jsonb_build_array(jsonb_build_object('test', 'parent cannot edit the student''s own words', 'pass', false, 'detail', 'edited'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'parent cannot edit the student''s own words', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    execute 'reset role';

    -- ---------------------------------------------------------------- outputs
    perform public.save_output(p_child, 'recommender_pointers',
      jsonb_build_array(jsonb_build_object('heading', 'Setbacks', 'body', 'Bounced back quickly.', 'cited_entry_ids', jsonb_build_array(e_note))));
    begin
      perform public.save_output(p_child, 'activities',
        jsonb_build_array(jsonb_build_object('body', 'Leaks a parent note.', 'cited_entry_ids', jsonb_build_array(e_note))));
      r := r || jsonb_build_array(jsonb_build_object('test', 'family outputs cannot cite parents-only notes', 'pass', false, 'detail', 'accepted'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'family outputs cannot cite parents-only notes', 'pass', true, 'detail', sqlerrm));
    end;
    x := public.save_output(p_child, 'essay_angles',
      jsonb_build_array(jsonb_build_object('heading', 'Creator', 'body', 'Writes music, not just plays it.', 'cited_entry_ids', jsonb_build_array(e_fam))));
    o_essay := (x ->> 'output_id')::uuid;

    -- ---------------------------------------------------------------- student
    perform set_config('request.jwt.claims', json_build_object('sub', st, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    select count(*) into n from public.entries where id = e_note;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot read parents-only entries', 'pass', n = 0, 'detail', n || ' rows'));
    select count(*) into n from public.posts where id = post_po;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot read parents-only posts', 'pass', n = 0, 'detail', n || ' rows'));
    select count(*) into n from public.gaps g2 join public.entries e on e.id = g2.entry_id where e.visibility = 'parents_only';
    r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot read questions on parents-only entries', 'pass', n = 0, 'detail', n || ' rows'));
    select count(*) into n from public.entries where id = e_priv;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot read a parent''s private entries', 'pass', n = 0, 'detail', n || ' rows'));
    select count(*) into n from public.outputs where kind = 'recommender_pointers';
    r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot read recommender pointers', 'pass', n = 0, 'detail', n || ' rows'));
    select count(*) into n from public.entries where id = e_young;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student can read the younger child''s family entries', 'pass', n = 1, 'detail', n || ' rows'));
    select count(*) into n from public.output_items where output_id = o_essay;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student can read family outputs', 'pass', n = 1, 'detail', n || ' items'));

    update public.entries set title = 'Changed by student' where id = e_young;
    get diagnostics n = row_count;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot edit the younger child''s profile', 'pass', n = 0, 'detail', n || ' rows changed'));

    begin
      insert into public.posts (person_id, body, visibility) values (p_child, 'Trying parents-only', 'parents_only');
      r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot post parents-only', 'pass', false, 'detail', 'inserted'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot post parents-only', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      insert into public.entries (person_id, type, title, fields) values (p_child, 'parent_note', 'Sneaky', '{"text":"x"}');
      r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot write parent notes', 'pass', false, 'detail', 'inserted'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot write parent notes', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      insert into public.entries (person_id, type, title, date_start) values (p_young, 'milestone', 'Not allowed', '2026-01-01');
      r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot add to the younger child''s profile', 'pass', false, 'detail', 'inserted'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'student cannot add to the younger child''s profile', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      update public.entries set visibility = 'shareable' where id = e_fam;
      r := r || jsonb_build_array(jsonb_build_object('test', 'only the poster can change who sees an entry', 'pass', false, 'detail', 'changed'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'only the poster can change who sees an entry', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      update public.entries set status = 'confirmed' where id = e_refl;
      r := r || jsonb_build_array(jsonb_build_object('test', 'status can only change through confirm', 'pass', false, 'detail', 'changed'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'status can only change through confirm', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      perform public.ingest_draft(post_fam, '[]'::jsonb);
      r := r || jsonb_build_array(jsonb_build_object('test', 'app users cannot call processing functions', 'pass', false, 'detail', 'called'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'app users cannot call processing functions', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      perform 1 from public.processing_queue limit 1;
      r := r || jsonb_build_array(jsonb_build_object('test', 'app users cannot read the processing queue', 'pass', false, 'detail', 'read'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'app users cannot read the processing queue', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    begin
      perform 1 from public.invites limit 1;
      r := r || jsonb_build_array(jsonb_build_object('test', 'app users cannot read invites', 'pass', false, 'detail', 'read'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'app users cannot read invites', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;

    perform public.confirm_entry(e_refl);
    select status::text into s from public.entries where id = e_refl;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student can confirm their own words', 'pass', s = 'confirmed', 'detail', s));
    execute 'reset role';

    -- ---------------------------------------------------------------- narrowing visibility hides old output items
    perform set_config('request.jwt.claims', json_build_object('sub', pa, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    update public.entries set visibility = 'parents_only' where id = e_fam;
    select count(*) into n from public.output_items where output_id = o_essay;
    r := r || jsonb_build_array(jsonb_build_object('test', 'parent still sees the item after narrowing', 'pass', n = 1, 'detail', n || ' items'));
    execute 'reset role';

    perform set_config('request.jwt.claims', json_build_object('sub', st, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from public.output_items where output_id = o_essay;
    r := r || jsonb_build_array(jsonb_build_object('test', 'student loses saved output items when a cited entry becomes parents-only', 'pass', n = 0, 'detail', n || ' items'));
    execute 'reset role';

    -- ---------------------------------------------------------------- parent B and outsider
    perform set_config('request.jwt.claims', json_build_object('sub', pb, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from public.entries where id = e_priv;
    r := r || jsonb_build_array(jsonb_build_object('test', 'parent B cannot read parent A''s private entries', 'pass', n = 0, 'detail', n || ' rows'));
    select count(*) into n from public.entries where id = e_note;
    r := r || jsonb_build_array(jsonb_build_object('test', 'parent B can read parents-only notes', 'pass', n = 1, 'detail', n || ' rows'));
    execute 'reset role';

    perform set_config('request.jwt.claims', json_build_object('sub', ou, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select (select count(*) from public.people) + (select count(*) from public.entries) + (select count(*) from public.posts) into n;
    r := r || jsonb_build_array(jsonb_build_object('test', 'uninvited sign-up sees nothing', 'pass', n = 0, 'detail', n || ' rows'));
    execute 'reset role';

    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    begin
      perform 1 from public.entries limit 1;
      r := r || jsonb_build_array(jsonb_build_object('test', 'signed-out visitors cannot read data', 'pass', false, 'detail', 'read'));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'signed-out visitors cannot read data', 'pass', sqlstate = '42501', 'detail', sqlerrm));
    end;
    execute 'reset role';

    raise exception using errcode = 'P0099', message = 'rollback test data';
  exception
    when sqlstate 'P0099' then
      null;
    when others then
      r := r || jsonb_build_array(jsonb_build_object('test', 'suite ran to completion', 'pass', false, 'detail', sqlstate || ' ' || sqlerrm));
  end;

  return query
    select t.test, t.pass, t.detail
      from jsonb_to_recordset(r) as t(test text, pass boolean, detail text);
end $$;

revoke all on function tests.rls_suite() from public, anon, authenticated;
