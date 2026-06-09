-- ============================================================
--  NEWS SENTIMENT RADAR — Supabase Migration v3 (clean slate)
--
--  Run this entire file in the Supabase SQL Editor.
--  It drops and recreates everything from scratch.
--
--  PRE-REQUISITES (do these BEFORE running):
--    1. Supabase Dashboard → Database → Vault → New secret
--         Name:  app_key_passphrase
--         Value: any 32+ character random string
--       ⚠ Never change this value once keys are stored — it is the
--         master encryption passphrase for all user keys.
--
--    2. Default API keys are stored in app_config (see Section 5).
--       Update the INSERT values there with your real keys before
--       running this migration.
-- ============================================================


-- ============================================================
--  0. CLEAN SLATE  — drop everything in dependency order
-- ============================================================

-- Views first (they depend on tables)
drop view  if exists public.v_plan_features  cascade;
drop view  if exists public.v_effective_plan cascade;

-- RPCs / functions
drop function if exists public.admin_set_plan(uuid, text)                          cascade;
drop function if exists public.maybe_expire_trial(uuid)                            cascade;
drop function if exists public.activate_trial(uuid)                                cascade;
drop function if exists public.cleanup_stale_sessions()                            cascade;
drop function if exists public.deactivate_session(text)                            cascade;
drop function if exists public.check_device_access(uuid, text, text, text)         cascade;
drop function if exists public._upsert_session(uuid, text, text, text)             cascade;
drop function if exists public.get_crawl_count()                                   cascade;
drop function if exists public.increment_crawl_usage(uuid)                         cascade;
drop function if exists public.get_user_key(text)                                  cascade;
drop function if exists public.store_user_key(text, text)                          cascade;
drop function if exists public._decrypt_key(bytea)                                 cascade;
drop function if exists public._encrypt_key(text)                                  cascade;
drop function if exists public.handle_new_user()                                   cascade;
drop function if exists public._assert_own_user(uuid)                              cascade;
-- Legacy names from earlier migrations
drop function if exists public.encrypt_api_key(text)                               cascade;
drop function if exists public.decrypt_api_key(bytea)                              cascade;

-- Tables (children before parents)
drop trigger  if exists on_auth_user_created on auth.users;
drop table    if exists public.user_sessions  cascade;
drop table    if exists public.crawl_usage    cascade;
drop table    if exists public.user_settings  cascade;
drop table    if exists public.app_config     cascade;
drop table    if exists public.profiles       cascade;


-- ============================================================
--  EXTENSIONS
-- ============================================================
create extension if not exists "pgcrypto";
-- supabase_vault is pre-installed on all Supabase projects
create extension if not exists "supabase_vault" schema extensions;


-- ============================================================
--  1. INTERNAL HELPERS
-- ============================================================

-- Raise if the calling authenticated user is not p_user_id.
-- Every security-definer RPC that accepts a p_user_id calls this first.
create or replace function public._assert_own_user(p_user_id uuid)
returns void language plpgsql security definer as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if auth.uid() <> p_user_id then
    raise exception 'Unauthorized: user mismatch';
  end if;
end;
$$;
revoke all on function public._assert_own_user(uuid) from public, anon, authenticated;


-- ============================================================
--  2. ENCRYPTION HELPERS  (Vault-backed, never current_setting)
-- ============================================================

create or replace function public._encrypt_key(plaintext text)
returns bytea language plpgsql security definer as $$
declare
  v_pass text;
begin
  select decrypted_secret into v_pass
  from vault.decrypted_secrets
  where name = 'app_key_passphrase'
  limit 1;

  if v_pass is null or length(v_pass) < 16 then
    raise exception 'Vault secret "app_key_passphrase" is missing or too short (need 16+ chars)';
  end if;

  return pgp_sym_encrypt(plaintext, v_pass);
end;
$$;

create or replace function public._decrypt_key(ciphertext bytea)
returns text language plpgsql security definer as $$
declare
  v_pass text;
begin
  if ciphertext is null then return ''; end if;

  select decrypted_secret into v_pass
  from vault.decrypted_secrets
  where name = 'app_key_passphrase'
  limit 1;

  if v_pass is null or length(v_pass) < 16 then
    raise exception 'Vault secret "app_key_passphrase" is missing or too short';
  end if;

  return pgp_sym_decrypt(ciphertext, v_pass);
exception when others then
  -- Wrong passphrase or corrupted data — return empty rather than leaking errors
  return '';
end;
$$;

-- Internal only — never callable by any DB role
revoke all on function public._encrypt_key(text)  from public, anon, authenticated;
revoke all on function public._decrypt_key(bytea) from public, anon, authenticated;


-- ============================================================
--  3. APP_CONFIG  — global defaults (service_role access only)
-- ============================================================
create table public.app_config (
  key        text primary key,
  value      text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;
-- No SELECT/INSERT/UPDATE/DELETE policies for anon or authenticated.
-- Only security-definer functions (running as the DB owner) can read this.

-- ── Default API keys ─────────────────────────────────────────
-- ⚠ Replace these values with your real default keys before running.
insert into public.app_config (key, value) values
  ('default_mistral_key',  'REPLACE_WITH_YOUR_MISTRAL_KEY'),
  ('default_rss2json_key', 'REPLACE_WITH_YOUR_RSS2JSON_KEY')
on conflict (key) do update set value = excluded.value, updated_at = now();


-- ============================================================
--  4. PROFILES
-- ============================================================
create table public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  name             text,
  plan             text not null default 'free'
                   check (plan in ('free','trial','pro','enterprise')),
  trial_started_at timestamptz,
  trial_expires_at timestamptz,
  trial_used       boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles: own select"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles: own update name"
  on public.profiles for update
  using  (auth.uid() = id)
  with check (auth.uid() = id);

create index idx_profiles_plan
  on public.profiles (plan);

create index idx_profiles_trial_expires
  on public.profiles (trial_expires_at)
  where plan = 'trial';


-- ============================================================
--  5. USER_SETTINGS
-- ============================================================
create table public.user_settings (
  user_id             uuid primary key references auth.users(id) on delete cascade,
  ai_provider         text not null default 'anthropic'
                      check (ai_provider in ('anthropic','mistral')),
  anthropic_key_enc   bytea,   -- NULL  = not yet set by user
  mistral_key_enc     bytea,   -- NULL  = fall back to app_config default
  rss2json_key_enc    bytea,   -- NULL  = fall back to app_config default
  proxy_url           text,
  ai_keywords_enabled boolean not null default true,
  updated_at          timestamptz not null default now()
);

alter table public.user_settings enable row level security;

create policy "settings: own select"
  on public.user_settings for select
  using (auth.uid() = user_id);

create policy "settings: own update"
  on public.user_settings for update
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "settings: own insert"
  on public.user_settings for insert
  with check (auth.uid() = user_id);


-- ── store_user_key ────────────────────────────────────────────
-- Encrypts and persists an API key for the calling user.
-- p_key_type: 'anthropic' | 'mistral' | 'rss2json'
create or replace function public.store_user_key(
  p_key_type  text,
  p_key_value text
) returns void language plpgsql security definer as $$
declare
  v_enc bytea;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_key_type not in ('anthropic', 'mistral', 'rss2json') then
    raise exception 'Invalid key type: %', p_key_type;
  end if;
  if p_key_value is null or length(trim(p_key_value)) = 0 then
    raise exception 'Key value must not be empty';
  end if;

  v_enc := public._encrypt_key(p_key_value);

  if p_key_type = 'anthropic' then
    update public.user_settings
       set anthropic_key_enc = v_enc, updated_at = now()
     where user_id = auth.uid();
  elsif p_key_type = 'mistral' then
    update public.user_settings
       set mistral_key_enc = v_enc, updated_at = now()
     where user_id = auth.uid();
  elsif p_key_type = 'rss2json' then
    update public.user_settings
       set rss2json_key_enc = v_enc, updated_at = now()
     where user_id = auth.uid();
  end if;
end;
$$;

-- ── get_user_key ──────────────────────────────────────────────
-- Returns the decrypted API key for the calling user.
--
-- FALLBACK LOGIC (the core fix):
--   If the user's own *_key_enc column is NULL, the function reads
--   the corresponding default from app_config, encrypts it, writes
--   it back to the user's row (so future calls are fast), and returns
--   the plaintext.  This means every new user automatically gets the
--   default keys on their first request — no trigger race conditions,
--   no separate copy step.
create or replace function public.get_user_key(p_key_type text)
returns text language plpgsql security definer as $$
declare
  v_enc     bytea;
  v_plain   text;
  v_default text;
  v_config_key text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_key_type not in ('anthropic', 'mistral', 'rss2json') then
    raise exception 'Invalid key type: %', p_key_type;
  end if;

  -- 1. Read the user's own encrypted key
  if p_key_type = 'anthropic' then
    select anthropic_key_enc into v_enc
      from public.user_settings where user_id = auth.uid();
    v_config_key := 'default_anthropic_key';
  elsif p_key_type = 'mistral' then
    select mistral_key_enc into v_enc
      from public.user_settings where user_id = auth.uid();
    v_config_key := 'default_mistral_key';
  elsif p_key_type = 'rss2json' then
    select rss2json_key_enc into v_enc
      from public.user_settings where user_id = auth.uid();
    v_config_key := 'default_rss2json_key';
  end if;

  -- 2. If the user already has their own key, decrypt and return it
  if v_enc is not null then
    return public._decrypt_key(v_enc);
  end if;

  -- 3. No user key — look up the app-wide default in app_config
  --    (security-definer bypasses the RLS that blocks direct user access)
  select value into v_default
    from public.app_config
   where key = v_config_key
   limit 1;

  if v_default is null or length(trim(v_default)) = 0 then
    -- No default configured either — return empty; caller handles this
    return '';
  end if;

  -- 4. Encrypt the default and persist it as the user's own key so that:
  --    a) Future get_user_key calls hit branch (2) — no app_config read
  --    b) loadSettings sees *_key_enc IS NOT NULL → *KeySet = true
  --    c) The user can later overwrite it with their own key via saveSettings
  declare
    v_enc_default bytea;
  begin
    v_enc_default := public._encrypt_key(v_default);

    if p_key_type = 'anthropic' then
      update public.user_settings
         set anthropic_key_enc = v_enc_default, updated_at = now()
       where user_id = auth.uid();
    elsif p_key_type = 'mistral' then
      update public.user_settings
         set mistral_key_enc = v_enc_default, updated_at = now()
       where user_id = auth.uid();
    elsif p_key_type = 'rss2json' then
      update public.user_settings
         set rss2json_key_enc = v_enc_default, updated_at = now()
       where user_id = auth.uid();
    end if;
  exception when others then
    -- If the write fails (e.g. Vault passphrase issue), still return the
    -- plaintext so the user's session works — we just won't cache it.
    null;
  end;

  return v_default;
end;
$$;

grant execute on function public.store_user_key(text, text) to authenticated;
grant execute on function public.get_user_key(text)         to authenticated;


-- ============================================================
--  6. AUTO-PROVISION on signup
--     Creates profile + user_settings rows for every new user.
--     We do NOT copy keys here — get_user_key handles the lazy
--     copy on first use, which avoids any Vault read at trigger time
--     (triggers fire synchronously and should not call Vault RPCs).
-- ============================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  -- Profile row (free plan by default)
  insert into public.profiles (id, name, plan)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    'free'
  )
  on conflict (id) do nothing;

  -- Settings row (all key columns NULL — get_user_key fills them lazily)
  insert into public.user_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ============================================================
--  7. EFFECTIVE PLAN VIEW
-- ============================================================
create or replace view public.v_effective_plan
  with (security_invoker = true)
as
  select
    id,
    name,
    case
      when plan = 'trial'
           and trial_expires_at is not null
           and trial_expires_at < now()
      then 'free'
      else plan
    end as effective_plan,
    trial_started_at,
    trial_expires_at,
    trial_used,
    created_at
  from public.profiles;


-- ============================================================
--  8. PLAN FEATURES VIEW
-- ============================================================
create or replace view public.v_plan_features
  with (security_invoker = true)
as
  select
    p.id,
    p.name,
    ep.effective_plan                         as plan,
    ep.trial_expires_at,
    ep.trial_used,
    case ep.effective_plan
      when 'free'       then 50
      when 'trial'      then 2147483647
      when 'pro'        then 2147483647
      when 'enterprise' then 2147483647
      else 50
    end                                       as crawl_limit,
    ep.effective_plan <> 'free'               as can_use_briefs,
    ep.effective_plan <> 'free'               as can_use_drafts,
    ep.effective_plan <> 'free'               as all_sources,
    ep.effective_plan  = 'enterprise'         as multi_device
  from public.profiles p
  join public.v_effective_plan ep on ep.id = p.id;


-- ============================================================
--  9. CRAWL USAGE
-- ============================================================
create table public.crawl_usage (
  user_id     uuid not null references auth.users(id) on delete cascade,
  month       date not null,
  crawl_count int  not null default 0 check (crawl_count >= 0),
  primary key (user_id, month)
);

alter table public.crawl_usage enable row level security;

create policy "crawl_usage: own select"
  on public.crawl_usage for select
  using (auth.uid() = user_id);

create index idx_crawl_usage_user_month
  on public.crawl_usage (user_id, month);

-- Atomically increment, enforcing the plan limit server-side.
create or replace function public.increment_crawl_usage(p_user_id uuid)
returns int language plpgsql security definer as $$
declare
  v_month       date := date_trunc('month', now())::date;
  v_new_count   int;
  v_crawl_limit int;
  v_plan        text;
begin
  perform public._assert_own_user(p_user_id);

  select ep.effective_plan,
         case ep.effective_plan
           when 'free'       then 50
           when 'trial'      then 2147483647
           when 'pro'        then 2147483647
           when 'enterprise' then 2147483647
           else 50
         end
    into v_plan, v_crawl_limit
    from public.v_effective_plan ep
   where ep.id = p_user_id;

  -- Only bother checking count for limited plans
  if v_crawl_limit < 2147483647 then
    select coalesce(crawl_count, 0) into v_new_count
      from public.crawl_usage
     where user_id = p_user_id and month = v_month;

    if coalesce(v_new_count, 0) >= v_crawl_limit then
      raise exception 'Crawl limit reached (% / %)', v_new_count, v_crawl_limit
        using errcode = 'P0001';
    end if;
  end if;

  insert into public.crawl_usage (user_id, month, crawl_count)
  values (p_user_id, v_month, 1)
  on conflict (user_id, month) do update
    set crawl_count = crawl_usage.crawl_count + 1
  returning crawl_count into v_new_count;

  return v_new_count;
end;
$$;

-- Read calling user's crawl count for the current month.
create or replace function public.get_crawl_count()
returns int language plpgsql security definer as $$
declare
  v_count int;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;

  select coalesce(crawl_count, 0) into v_count
    from public.crawl_usage
   where user_id = auth.uid()
     and month   = date_trunc('month', now())::date;

  return coalesce(v_count, 0);
end;
$$;

grant execute on function public.increment_crawl_usage(uuid) to authenticated;
grant execute on function public.get_crawl_count()           to authenticated;


-- ============================================================
--  10. USER SESSIONS  (single-device enforcement)
-- ============================================================
create table public.user_sessions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  ip_address         text not null,
  device_fingerprint text not null,
  session_token      text not null,
  last_seen          timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  is_active          boolean not null default true,
  unique (user_id, device_fingerprint)
);

alter table public.user_sessions enable row level security;

create policy "sessions: own select"
  on public.user_sessions for select
  using (auth.uid() = user_id);

create index idx_user_sessions_user_active
  on public.user_sessions (user_id, is_active, last_seen);

-- Internal session upsert — not user callable
create or replace function public._upsert_session(
  p_user_id            uuid,
  p_device_fingerprint text,
  p_ip_address         text,
  p_session_token      text
) returns void language plpgsql security definer as $$
begin
  insert into public.user_sessions
    (user_id, device_fingerprint, ip_address, session_token)
  values
    (p_user_id, p_device_fingerprint, p_ip_address, p_session_token)
  on conflict (user_id, device_fingerprint) do update
    set last_seen     = now(),
        ip_address    = p_ip_address,
        session_token = p_session_token,
        is_active     = true;
end;
$$;
revoke all on function public._upsert_session(uuid, text, text, text)
  from public, anon, authenticated;

-- Device access check — called on every page load requiring auth
create or replace function public.check_device_access(
  p_user_id            uuid,
  p_device_fingerprint text,
  p_ip_address         text,
  p_session_token      text
) returns text language plpgsql security definer as $$
declare
  v_plan         text;
  v_active_count int;
  v_exists       boolean;
begin
  perform public._assert_own_user(p_user_id);

  select effective_plan into v_plan
    from public.v_effective_plan
   where id = p_user_id;

  -- Enterprise: unlimited devices
  if v_plan = 'enterprise' then
    perform public._upsert_session(p_user_id, p_device_fingerprint, p_ip_address, p_session_token);
    return 'enterprise';
  end if;

  -- Known device on this account?
  select exists(
    select 1 from public.user_sessions
     where user_id            = p_user_id
       and device_fingerprint = p_device_fingerprint
       and is_active          = true
  ) into v_exists;

  if v_exists then
    update public.user_sessions
       set last_seen     = now(),
           ip_address    = p_ip_address,
           session_token = p_session_token
     where user_id            = p_user_id
       and device_fingerprint = p_device_fingerprint;
    return 'allowed';
  end if;

  -- Count truly active sessions (stale > 30 min are ignored)
  select count(*) into v_active_count
    from public.user_sessions
   where user_id   = p_user_id
     and is_active = true
     and last_seen > now() - interval '30 minutes';

  if v_active_count >= 1 then
    return 'blocked';
  end if;

  -- No conflict — register new device
  perform public._upsert_session(p_user_id, p_device_fingerprint, p_ip_address, p_session_token);
  return 'allowed';
end;
$$;

-- Deactivate session on logout
create or replace function public.deactivate_session(p_device_fingerprint text)
returns void language plpgsql security definer as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;

  update public.user_sessions
     set is_active = false
   where user_id            = auth.uid()
     and device_fingerprint = p_device_fingerprint;
end;
$$;

-- Scheduled cleanup — wire to pg_cron: "0 3 * * *"
create or replace function public.cleanup_stale_sessions()
returns void language plpgsql security definer as $$
begin
  delete from public.user_sessions
   where is_active = false
      or last_seen < now() - interval '90 days';
end;
$$;

grant execute on function public.check_device_access(uuid, text, text, text) to authenticated;
grant execute on function public.deactivate_session(text)                    to authenticated;
revoke all on function public.cleanup_stale_sessions() from public, anon, authenticated;


-- ============================================================
--  11. TRIAL MANAGEMENT
-- ============================================================

-- Activate a 3-day trial (once per account, race-condition safe)
create or replace function public.activate_trial(p_user_id uuid)
returns json language plpgsql security definer as $$
declare
  v_trial_used boolean;
  v_plan       text;
begin
  perform public._assert_own_user(p_user_id);

  select trial_used, plan
    into v_trial_used, v_plan
    from public.profiles
   where id = p_user_id
   for update;

  if not found then
    raise exception 'Profile not found';
  end if;
  if v_trial_used then
    return json_build_object('success', false, 'reason', 'Trial already used');
  end if;
  if v_plan <> 'free' then
    return json_build_object('success', false, 'reason', 'Already on a paid plan');
  end if;

  update public.profiles
     set plan             = 'trial',
         trial_started_at = now(),
         trial_expires_at = now() + interval '3 days',
         trial_used       = true,
         updated_at       = now()
   where id = p_user_id;

  return json_build_object('success', true,
    'expires_at', (now() + interval '3 days')::text);
end;
$$;

-- Auto-expire a trial if it has passed its end date
create or replace function public.maybe_expire_trial(p_user_id uuid)
returns text language plpgsql security definer as $$
declare
  v_plan       text;
  v_expires_at timestamptz;
begin
  perform public._assert_own_user(p_user_id);

  select plan, trial_expires_at
    into strict v_plan, v_expires_at
    from public.profiles
   where id = p_user_id;

  if v_plan = 'trial'
     and v_expires_at is not null
     and v_expires_at < now()
  then
    update public.profiles
       set plan = 'free', updated_at = now()
     where id = p_user_id;
    return 'expired';
  end if;

  return v_plan;

exception when no_data_found then
  raise exception 'Profile not found for user %', p_user_id;
end;
$$;

grant execute on function public.activate_trial(uuid)     to authenticated;
grant execute on function public.maybe_expire_trial(uuid) to authenticated;


-- ============================================================
--  12. ADMIN PLAN UPDATE  (service_role only)
-- ============================================================
create or replace function public.admin_set_plan(
  p_user_id uuid,
  p_plan    text
) returns void language plpgsql security definer as $$
begin
  if current_setting('role', true) <> 'service_role'
     and auth.role() <> 'service_role'
  then
    raise exception 'admin_set_plan requires service_role';
  end if;

  if p_plan not in ('free','trial','pro','enterprise') then
    raise exception 'Invalid plan: %', p_plan;
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User profile not found: %', p_user_id;
  end if;

  update public.profiles
     set plan = p_plan, updated_at = now()
   where id = p_user_id;
end;
$$;
revoke all on function public.admin_set_plan(uuid, text) from public, anon, authenticated;


-- ============================================================
--  POST-RUN CHECKLIST
-- ============================================================
--
--  1. VAULT SECRET (mandatory — do this BEFORE running the migration)
--       Dashboard → Database → Vault → New secret
--       Name:  app_key_passphrase
--       Value: 32+ random characters
--       ⚠ The name must be exactly "app_key_passphrase" (underscore, not hyphen).
--
--  2. DEFAULT KEYS (in Section 3 of this file, already inserted above)
--       Update the INSERT block to use your real keys, then re-run.
--       To update later: run just the INSERT with ON CONFLICT DO UPDATE.
--
--  3. CRON JOB for stale session cleanup
--       Dashboard → Database → Cron Jobs → New cron job
--       Schedule: 0 3 * * *
--       Command:  select public.cleanup_stale_sessions();
--
--  4. ADMIN PLAN UPGRADES
--       Call admin_set_plan() from a server-side Edge Function that
--       uses the service_role key (e.g. after a Stripe webhook).
--       Never expose the service_role key to the browser.
--
--  5. TEST KEY AUTOFILL (after running)
--       Sign up as a new user, open the dashboard Settings tab.
--       The Mistral and RSS2JSON indicators should show "Key loaded & ready"
--       within a couple of seconds — no manual key entry needed.
--
--  6. TEST RLS
--       Log in as user A: SELECT * FROM public.v_plan_features;
--       Should return exactly one row (your own).
--
--  7. TEST CRAWL LIMIT
--       Set a free user's crawl_count to 49, then call
--       increment_crawl_usage — should succeed.
--       Call again — should raise P0001.
-- ============================================================
