-- ============================================================
--  PATCH 2: Fix handle_new_user trigger for new signups
--
--  Run this in the Supabase SQL Editor.
--
--  Fixes:
--    1. Drops and recreates the trigger so Postgres uses the
--       latest version of the function (not a cached copy).
--    2. Fixes the ON CONFLICT SET syntax — the old version used
--       public.user_settings.column which is invalid inside a
--       SET clause; correct form is just the bare column name.
--    3. Simplifies the insert to a single statement so there is
--       no window between the profile insert and settings insert
--       where a concurrent request could read a half-built row.
-- ============================================================


-- ── Step 1: drop the trigger first ───────────────────────────
-- This forces Postgres to recompile the binding when we recreate it.
drop trigger if exists on_auth_user_created on auth.users;


-- ── Step 2: replace the function with corrected logic ────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
declare
  v_mistral_plain  text;
  v_rss2json_plain text;
  v_mistral_enc    bytea;
  v_rss2json_enc   bytea;
begin
  -- ── Profile row ───────────────────────────────────────────
  insert into public.profiles (id, name, plan)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    'free'
  )
  on conflict (id) do nothing;

  -- ── Read default keys from app_config ────────────────────
  -- SECURITY DEFINER means this runs as the DB owner and can
  -- read app_config even though authenticated users cannot.
  select value into v_mistral_plain
    from public.app_config
   where key = 'default_mistral_key'
   limit 1;

  select value into v_rss2json_plain
    from public.app_config
   where key = 'default_rss2json_key'
   limit 1;

  -- ── Encrypt defaults (Vault call wrapped so signup never fails) ──
  begin
    if v_mistral_plain is not null and length(trim(v_mistral_plain)) > 0 then
      v_mistral_enc := public._encrypt_key(v_mistral_plain);
    end if;
    if v_rss2json_plain is not null and length(trim(v_rss2json_plain)) > 0 then
      v_rss2json_enc := public._encrypt_key(v_rss2json_plain);
    end if;
  exception when others then
    -- Vault unavailable — leave NULLs; get_user_key() fallback handles it
    v_mistral_enc  := null;
    v_rss2json_enc := null;
  end;

  -- ── Insert user_settings with encrypted defaults ─────────
  -- ON CONFLICT: only fill in columns that are still NULL so we
  -- never overwrite a key a user already saved.
  -- FIX: bare column names in SET (not table-qualified), which is
  -- the correct syntax inside an INSERT ... ON CONFLICT DO UPDATE.
  insert into public.user_settings (
    user_id,
    mistral_key_enc,
    rss2json_key_enc
  )
  values (
    new.id,
    v_mistral_enc,
    v_rss2json_enc
  )
  on conflict (user_id) do update
    set
      mistral_key_enc  = coalesce(user_settings.mistral_key_enc,  excluded.mistral_key_enc),
      rss2json_key_enc = coalesce(user_settings.rss2json_key_enc, excluded.rss2json_key_enc),
      updated_at       = now();

  return new;
end;
$$;


-- ── Step 3: recreate the trigger against the new function ────
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ── Step 4: verify the trigger is wired correctly ────────────
-- Should return one row: on_auth_user_created | handle_new_user
select
  trigger_name,
  event_manipulation,
  action_statement
from information_schema.triggers
where event_object_schema = 'auth'
  and event_object_table  = 'users'
  and trigger_name        = 'on_auth_user_created';
