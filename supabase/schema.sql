-- Schema of the Supabase backend (already applied to the project as migration "tavolo_schema").
-- Tables are closed (RLS on, no policies); clients only call the token-checked functions below.

create extension if not exists pgcrypto with schema extensions;

create table public.games (
  id uuid primary key default gen_random_uuid(),
  narr_hash text not null,
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.chars (
  game_id uuid not null references public.games(id) on delete cascade,
  slot text not null,
  code text not null unique,
  data jsonb not null default '{}'::jsonb,
  primary key (game_id, slot)
);
create table public.log (
  id bigserial primary key,
  game_id uuid not null references public.games(id) on delete cascade,
  gid text,
  ts timestamptz not null default now(),
  who text not null default '',
  text text not null
);
create index log_game_idx on public.log(game_id, id desc);

alter table public.games enable row level security;
alter table public.chars enable row level security;
alter table public.log enable row level security;
revoke all on public.games, public.chars, public.log from anon, authenticated;
revoke all on sequence public.log_id_seq from anon, authenticated;

-- recursive merge: objects merge, everything else (null included) replaces
create or replace function public.jsonb_deep_merge(a jsonb, b jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare k text; v jsonb; r jsonb;
begin
  if a is null or jsonb_typeof(a) <> 'object' then r := '{}'::jsonb; else r := a; end if;
  for k, v in select * from jsonb_each(b) loop
    if jsonb_typeof(v) = 'object' and jsonb_typeof(r->k) = 'object' then
      r := r || jsonb_build_object(k, public.jsonb_deep_merge(r->k, v));
    else
      r := r || jsonb_build_object(k, v);
    end if;
  end loop;
  return r;
end $$;

create or replace function public._hash(t text) returns text
language sql immutable set search_path = '' as $$ select encode(extensions.digest(t, 'sha256'), 'hex') $$;

create or replace function public._narr_game(p_token text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare g uuid;
begin
  select id into g from public.games where narr_hash = public._hash(p_token);
  if g is null then raise exception 'codice narratore non valido'; end if;
  return g;
end $$;

create or replace function public._new_code() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare alphabet text := 'ACDEFGHJKLMNPQRTUVWXY34679'; c text; i int; b bytea;
begin
  loop
    b := extensions.gen_random_bytes(6); c := '';
    for i in 0..5 loop c := c || substr(alphabet, (get_byte(b, i) % length(alphabet)) + 1, 1); end loop;
    exit when not exists (select 1 from public.chars where code = c);
  end loop;
  return c;
end $$;

create or replace function public._log_tail(g uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('ts', extract(epoch from ts)*1000, 'who', who, 'text', text, 'g', gid) order by id desc), '[]'::jsonb)
  from (select * from public.log where game_id = g order by id desc limit 150) t
$$;

-- narrator API
create or replace function public.create_game(p_state jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare t text := encode(extensions.gen_random_bytes(18), 'hex'); g uuid;
begin
  insert into public.games(narr_hash, state) values (public._hash(t), coalesce(p_state, '{}'::jsonb)) returning id into g;
  return jsonb_build_object('game_id', g, 'token', t);
end $$;

create or replace function public.narr_get(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token);
begin
  return jsonb_build_object(
    'game_id', g,
    'state', (select state from public.games where id = g),
    'chars', coalesce((select jsonb_object_agg(slot, jsonb_build_object('code', code, 'data', data)) from public.chars where game_id = g), '{}'::jsonb),
    'log', public._log_tail(g));
end $$;

create or replace function public.narr_set_state(p_token text, p_patch jsonb, p_replace boolean default false) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token);
begin
  update public.games set state = case when p_replace then p_patch else public.jsonb_deep_merge(state, p_patch) end, updated_at = now() where id = g;
end $$;

create or replace function public.narr_set_char(p_token text, p_slot text, p_patch jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token);
begin
  update public.chars set data = public.jsonb_deep_merge(data, p_patch) where game_id = g and slot = p_slot;
end $$;

create or replace function public.narr_create_char(p_token text, p_slot text, p_data jsonb) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token); c text := public._new_code();
begin
  delete from public.chars where game_id = g and slot = p_slot;
  insert into public.chars(game_id, slot, code, data) values (g, p_slot, c, p_data);
  return c;
end $$;

create or replace function public.narr_delete_char(p_token text, p_slot text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token);
begin delete from public.chars where game_id = g and slot = p_slot; end $$;

create or replace function public.narr_new_code(p_token text, p_slot text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token); c text := public._new_code();
begin update public.chars set code = c where game_id = g and slot = p_slot; return c; end $$;

create or replace function public.narr_reset(p_token text, p_state jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token);
begin
  delete from public.chars where game_id = g;
  delete from public.log where game_id = g;
  update public.games set state = p_state, updated_at = now() where id = g;
end $$;

create or replace function public.narr_log(p_token text, p_who text, p_text text, p_gid text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare g uuid := public._narr_game(p_token);
begin
  insert into public.log(game_id, gid, who, text) values (g, p_gid, left(coalesce(p_who,''), 60), left(p_text, 500));
  delete from public.log where game_id = g and id < (select min(id) from (select id from public.log where game_id = g order by id desc limit 300) t);
end $$;

-- player API (identified only by the character code)
create or replace function public._player(p_code text, out g uuid, out s text)
language plpgsql stable security definer set search_path = '' as $$
begin
  select game_id, slot into g, s from public.chars where code = upper(trim(p_code));
  if g is null then raise exception 'codice non valido'; end if;
end $$;

create or replace function public.player_get(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p record;
begin
  select * into p from public._player(p_code);
  return jsonb_build_object(
    'game_id', p.g, 'slot', p.s,
    'data', (select data from public.chars where game_id = p.g and slot = p.s),
    'state', (select state from public.games where id = p.g),
    'log', public._log_tail(p.g));
end $$;

create or replace function public.player_set_char(p_code text, p_patch jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare p record;
begin
  select * into p from public._player(p_code);
  update public.chars set data = public.jsonb_deep_merge(data, p_patch - 'cls') where game_id = p.g and slot = p.s;
end $$;

-- players may only touch the shared roll banner and the XP pool
create or replace function public.player_set_state(p_code text, p_patch jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare p record; f jsonb := '{}'::jsonb;
begin
  select * into p from public._player(p_code);
  if p_patch ? 'last' then f := f || jsonb_build_object('last', p_patch->'last'); end if;
  if p_patch ? 'xp' and jsonb_typeof(p_patch->'xp') = 'number' then f := f || jsonb_build_object('xp', greatest(0, (p_patch->>'xp')::int)); end if;
  update public.games set state = public.jsonb_deep_merge(state, f), updated_at = now() where id = p.g;
end $$;

create or replace function public.player_log(p_code text, p_who text, p_text text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare p record; gidv text;
begin
  select * into p from public._player(p_code);
  select state->>'gid' into gidv from public.games where id = p.g;
  insert into public.log(game_id, gid, who, text) values (p.g, gidv, left(coalesce(p_who,''), 60), left(p_text, 500));
end $$;

-- lock down: only the public API functions are callable
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.create_game(jsonb), public.narr_get(text), public.narr_set_state(text, jsonb, boolean),
  public.narr_set_char(text, text, jsonb), public.narr_create_char(text, text, jsonb), public.narr_delete_char(text, text),
  public.narr_new_code(text, text), public.narr_reset(text, jsonb), public.narr_log(text, text, text, text),
  public.player_get(text), public.player_set_char(text, jsonb), public.player_set_state(text, jsonb), public.player_log(text, text, text)
  to anon, authenticated;

-- ===== stage 1 (migration "tavolo_stage1") =====
alter table public.games add column if not exists lib jsonb not null default '{}'::jsonb;
-- narr_get also returns 'lib'; narr_set_lib(p_token, p_patch) deep-merges into lib (narrator only).
-- player_set_state accepts: last, xp, minions, foes.{id}.n, cres (own defense results stored under combat.cres).

-- ===== multi-character devices (migration "tavolo_multi_char") =====
alter table public.chars add column if not exists owner text;
-- narr_assign(p_token, p_slot, p_owner): the device playing p_owner also controls p_slot (null removes the link).
-- player_get returns 'linked': [{slot, code}] for characters owned by the caller's slot; narr_get returns 'owner' per character.

-- ===== table screen (migration "tavolo_table_screen") =====
alter table public.games add column if not exists view_code text unique;
-- narr_view_code(p_token): read-only code for the "Schermo giocatori" (created on first request).
-- table_get(p_view): public state plus, per investigator, only class, level and whether it is out of play.
