-- Cole no Supabase > SQL Editor e rode. Troque 'SEU_PIN' por um PIN (ex.: 4-6 dígitos).
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.app_pin (id int primary key default 1, pin_hash text not null);
insert into private.app_pin(id,pin_hash) values (1, extensions.crypt('SEU_PIN', extensions.gen_salt('bf')))
  on conflict (id) do update set pin_hash = excluded.pin_hash;

create or replace function private.ins_at(a jsonb, p int, x jsonb) returns jsonb language sql immutable as $f$
  select case when p >= jsonb_array_length(a) then a || jsonb_build_array(x)
              else jsonb_insert(a, array[p::text], x, false) end $f$;

create or replace function public.add_entry(pin text, kind text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d jsonb; dt text; arr jsonb; idx int; ph text; rec jsonb; old jsonb; ex jsonb; nm text; dbr text; pos int; n int; val numeric; mn numeric; mx numeric; v0 numeric; v1 numeric;
begin
  select pin_hash into ph from private.app_pin where id=1;
  if ph is null or pin is null or extensions.crypt(pin, ph) <> ph then
    raise exception 'PIN inválido' using errcode='28000';
  end if;
  select data into d from health_data where id='main' for update;
  if d is null then raise exception 'linha main não encontrada'; end if;
  dt := coalesce(payload->>'date', to_char(now() at time zone 'America/Sao_Paulo','YYYY-MM-DD'));
  if dt !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'data inválida'; end if;

  if kind = 'meal' then
    if coalesce(trim(payload->>'name'),'') = '' then raise exception 'nome obrigatório'; end if;
    rec := jsonb_build_object('name', left(trim(payload->>'name'),120),
             'kcal', coalesce((payload->>'kcal')::numeric,0), 'protein_g', coalesce((payload->>'protein_g')::numeric,0));
    d := jsonb_set(d, array['meals',dt], coalesce(d->'meals'->dt,'[]'::jsonb) || jsonb_build_array(rec), true);

  elsif kind = 'delete_meal' then
    arr := coalesce(d->'meals'->dt,'[]'::jsonb); idx := (payload->>'index')::int;
    if idx is null or idx < 0 or idx >= jsonb_array_length(arr) then raise exception 'refeição não encontrada'; end if;
    if payload ? 'name' and arr->idx->>'name' is distinct from payload->>'name' then raise exception 'refeição mudou, atualize'; end if;
    arr := arr - idx;
    if jsonb_array_length(arr)=0 then d := d #- array['meals',dt]; else d := jsonb_set(d, array['meals',dt], arr); end if;

  elsif kind = 'weight' then
    if payload ? 'kg' and payload->>'kg' is not null then
      select coalesce(jsonb_agg(w),'[]'::jsonb) into arr from jsonb_array_elements(coalesce(d->'weights','[]')) w where w->>'date' <> dt;
      d := jsonb_set(d,'{weights}', arr || jsonb_build_array(jsonb_build_object('kg',(payload->>'kg')::numeric,'date',dt)), true);
    end if;
    rec := jsonb_strip_nulls(jsonb_build_object('muscle_kg',(payload->>'muscle_kg')::numeric,'fat_pct',(payload->>'fat_pct')::numeric,
             'visceral',(payload->>'visceral')::numeric,'water_pct',(payload->>'water_pct')::numeric));
    if rec <> '{}'::jsonb then
      select b into old from jsonb_array_elements(coalesce(d->'body','[]')) b where b->>'date'=dt limit 1;
      select coalesce(jsonb_agg(b),'[]'::jsonb) into arr from jsonb_array_elements(coalesce(d->'body','[]')) b where b->>'date' <> dt;
      d := jsonb_set(d,'{body}', arr || jsonb_build_array(coalesce(old,'{}'::jsonb) || rec || jsonb_build_object('date',dt)), true);
    end if;
  elsif kind = 'exam' then
    nm := left(trim(coalesce(payload->>'name','')),80);
    if nm = '' or payload->>'value' is null then raise exception 'nome e valor obrigatórios'; end if;
    val := (payload->>'value')::numeric; mn := (payload->>'ref_min')::numeric; mx := (payload->>'ref_max')::numeric;
    dbr := to_char(dt::date,'DD/MM/YYYY');
    ex := coalesce(d->'exams', '{"dates":[],"rows":[]}'::jsonb);
    select ord-1 into pos from jsonb_array_elements_text(ex->'dates') with ordinality t(x,ord) where x=dbr;
    if pos is null then
      select count(*) into pos from jsonb_array_elements_text(ex->'dates') x where to_date(x,'DD/MM/YYYY') < dt::date;
      n := jsonb_array_length(ex->'dates');
      ex := jsonb_set(ex,'{dates}', private.ins_at(ex->'dates', pos, to_jsonb(dbr)));
      select coalesce(jsonb_agg(jsonb_set(r,'{v}', private.ins_at(r->'v', pos, 'null'::jsonb)) order by o),'[]'::jsonb)
        into arr from jsonb_array_elements(ex->'rows') with ordinality t(r,o);
      ex := jsonb_set(ex,'{rows}', arr);
    end if;
    n := jsonb_array_length(ex->'dates');
    select o-1 into idx from jsonb_array_elements(ex->'rows') with ordinality t(r,o) where lower(r->>'n')=lower(nm) limit 1;
    if idx is null then
      select jsonb_agg('null'::jsonb) into arr from generate_series(1,n);
      rec := jsonb_build_object('n',nm,'g',coalesce(nullif(trim(payload->>'group'),''),'Lançados'),'u',coalesce(payload->>'unit',''),'o','','r','—','s','g','d','','v',arr);
      ex := jsonb_set(ex,'{rows}', (ex->'rows') || jsonb_build_array(rec)); idx := jsonb_array_length(ex->'rows')-1;
    end if;
    rec := ex->'rows'->idx;
    rec := jsonb_set(rec, array['v',pos::text], to_jsonb(val));
    if coalesce(payload->>'unit','') <> '' then rec := rec || jsonb_build_object('u',payload->>'unit'); end if;
    if mn is not null or mx is not null then
      rec := rec || jsonb_strip_nulls(jsonb_build_object('min',mn,'max',mx)) || jsonb_build_object('r',
        case when mn is not null and mx is not null then replace(mn::text,'.',',')||'–'||replace(mx::text,'.',',')
             when mn is not null then '≥ '||replace(mn::text,'.',',') else '≤ '||replace(mx::text,'.',',') end);
    end if;
    -- recalcula variação (primeiro → último) e status pelo último valor vs referência
    select (array_agg(x::numeric order by o))[1], (array_agg(x::numeric order by o desc))[1] into v0, v1
      from jsonb_array_elements(rec->'v') with ordinality t(x,o) where jsonb_typeof(x)='number';
    if v0 is not null and v0 <> 0 then
      rec := rec || jsonb_build_object('d', case when v1>=v0 then '+' else '' end || replace(round(v1-v0,2)::text,'.',',')
        || ' (' || case when v1>=v0 then '+' else '' end || round((v1-v0)/v0*100)::text || '%)');
    end if;
    mn := (rec->>'min')::numeric; mx := (rec->>'max')::numeric;
    if mn is not null or mx is not null then
      rec := rec || jsonb_build_object('s', case when (mn is not null and v1<mn) or (mx is not null and v1>mx) then 'y' else 'g' end);
    end if;
    ex := jsonb_set(ex, array['rows',idx::text], rec);
    d := jsonb_set(d,'{exams}', ex, true);

  elsif kind = 'exam_upload' then
    if coalesce(payload->>'path','') !~ '^[A-Za-z0-9._/-]+$' then raise exception 'arquivo inválido'; end if;
    rec := jsonb_build_object('date',dt,'path',payload->>'path','file_name',left(coalesce(payload->>'file_name',''),160),
      'note',left(coalesce(payload->>'note',''),500),'status','pendente','rows_typed',coalesce((payload->>'rows_typed')::int,0),
      'uploaded_at',now());
    d := jsonb_set(d,'{exam_uploads}', coalesce(d->'exam_uploads','[]'::jsonb) || jsonb_build_array(rec), true);

  else
    raise exception 'tipo inválido: %', kind;
  end if;
  update health_data set data=d, updated_at=now() where id='main';
  return jsonb_build_object('ok',true,'updated_at',now());
end $$;

revoke all on function public.add_entry(text,text,jsonb) from public, anon;
grant execute on function public.add_entry(text,text,jsonb) to authenticated;
notify pgrst, 'reload schema';

-- Storage: bucket privado 'exames' (já criado). Políticas para usuário logado enviar/ler:
drop policy if exists "exames_insert_auth" on storage.objects;
create policy "exames_insert_auth" on storage.objects for insert to authenticated with check (bucket_id = 'exames');
drop policy if exists "exames_select_auth" on storage.objects;
create policy "exames_select_auth" on storage.objects for select to authenticated using (bucket_id = 'exames');
