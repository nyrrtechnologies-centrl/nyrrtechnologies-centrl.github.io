-- ============================================================
--  PATCH: Auto-fill default API keys at signup
--
--  Run this in the Supabase SQL Editor.
--  It replaces two functions only — no tables are touched.
--
--  ROOT CAUSE:
--    handle_new_user() inserted a user_settings row with NULL keys.
--    loadSettings() in auth.js checks (mistral_key_enc IS NOT NULL)
--    to set mistralKeySet=true. With NULLs, mistralKeySet was always
--    false, so _fetchAndCacheKey() was never called, so get_user_key()
--    was never called, so the app_config defaults were never used.
--
--  FIX:
--    handle_new_user() now reads app_config and encrypts the defaults
--    directly into the new user's row at the moment of signup.
--    get_user_key() keeps a simpler fallback for any edge cases.
-- ============================================================


-- ============================================================
--  1. REPLACE handle_new_user
--     Writes encrypted default keys into the new user's row
--     at signup time so loadSettings immediately sees
--     mistralKeySet=true / rss2jsonKeySet=true.
-- ============================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
declare
  v_mistral_plain  text;
  v_rss2json_plain text;
  v_mistral_enc    bytea;
  v_rss2json_enc   bytea;
begin
  -- ── 1. Profile row ────────────────────────────────────────
  insert into public.profiles (id, name, plan)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    'free'
  )
  on conflict (id) do nothing;

  -- ── 2. Read default keys from app_config ─────────────────
  --    security definer means this function runs as the DB owner
  --    and can read app_config even though authenticated users
  --    have no SELECT policy on it.
  select value into v_mistral_plain
    from public.app_config
   where key = 'default_mistral_key'
   limit 1;

  select value into v_rss2json_plain
    from public.app_config
   where key = 'default_rss2json_key'
   limit 1;

  -- ── 3. Encrypt the defaults (best-effort — signup never fails) ──
  begin
    if v_mistral_plain  is not null and length(trim(v_mistral_plain))  > 0 then
      v_mistral_enc  := public._encrypt_key(v_mistral_plain);
    end if;
    if v_rss2json_plain is not null and length(trim(v_rss2json_plain)) > 0 then
      v_rss2json_enc := public._encrypt_key(v_rss2json_plain);
    end if;
  exception when others then
    -- Vault unavailable at signup time — keys will remain NULL.
    -- get_user_key() will retry the fallback on first dashboard load.
    v_mistral_enc  := null;
    v_rss2json_enc := null;
  end;

  -- ── 4. Insert user_settings with encrypted defaults ──────
  insert into public.user_settings (
    user_id,
    mistral_key_enc,
    rss2json_key_enc
  )
  values (
    new.id,
    v_mistral_enc,   -- NULL if Vault was unavailable; fallback handles it
    v_rss2json_enc
  )
  on conflict (user_id) do update
    set
      -- Only backfill NULLs — never overwrite a key the user already set
      mistral_key_enc  = coalesce(public.user_settings.mistral_key_enc,  excluded.mistral_key_enc),
      rss2json_key_enc = coalesce(public.user_settings.rss2json_key_enc, excluded.rss2json_key_enc);

  return new;
end;
$$;

-- Trigger already exists — no need to recreate it.
-- (If you dropped and recreated the function, the trigger still points to it.)


-- ============================================================
--  2. REPLACE get_user_key
--     Simplified now that the trigger handles the happy path.
--     Still has the fallback copy for users who signed up before
--     this patch, or when the trigger's Vault call failed.
-- ============================================================
create or replace function public.get_user_key(p_key_type text)
returns text language plpgsql security definer as $$
declare
  v_enc        bytea;
  v_plain      text;
  v_default    text;
  v_config_key text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_key_type not in ('anthropic', 'mistral', 'rss2json') then
    raise exception 'Invalid key type: %', p_key_type;
  end if;

  -- ── 1. Try the user's own stored key first ────────────────
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

  if v_enc is not null then
    return public._decrypt_key(v_enc);
  end if;

  -- ── 2. Fallback: read from app_config, persist, return ────
  --    Reaches here only when the trigger's Vault call failed at
  --    signup (e.g. passphrase not yet configured), or for users
  --    who existed before this patch was applied.
  select value into v_default
    from public.app_config
   where key = v_config_key
   limit 1;

  if v_default is null or length(trim(v_default)) = 0 then
    return '';
  end if;

  -- Persist so loadSettings sees *KeySet=true on next login
  begin
    declare v_enc_default bytea;
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
    end;
  exception when others then
    null; -- still return the plaintext even if the write fails
  end;

  return v_default;
end;
$$;

grant execute on function public.get_user_key(text) to authenticated;


-- ============================================================
--  3. BACKFILL existing users who have NULL keys
--     Runs once. Safe to re-run (coalesce skips non-NULL rows).
--     Uses a DO block because we need to loop over users server-side
--     where security-definer access to app_config is available.
-- ============================================================
do $$
declare
  v_mistral_plain  text;
  v_rss2json_plain text;
  v_mistral_enc    bytea;
  v_rss2json_enc   bytea;
  v_uid            uuid;
begin
  -- Read defaults once
  select value into v_mistral_plain  from public.app_config where key = 'default_mistral_key'  limit 1;
  select value into v_rss2json_plain from public.app_config where key = 'default_rss2json_key' limit 1;

  if v_mistral_plain  is not null and length(trim(v_mistral_plain))  > 0 then
    v_mistral_enc  := public._encrypt_key(v_mistral_plain);
  end if;
  if v_rss2json_plain is not null and length(trim(v_rss2json_plain)) > 0 then
    v_rss2json_enc := public._encrypt_key(v_rss2json_plain);
  end if;

  -- Update only the rows that are still NULL (never overwrite user-set keys)
  update public.user_settings
     set
       mistral_key_enc  = coalesce(mistral_key_enc,  v_mistral_enc),
       rss2json_key_enc = coalesce(rss2json_key_enc, v_rss2json_enc),
       updated_at       = now()
   where mistral_key_enc is null or rss2json_key_enc is null;

  raise notice 'Backfill complete.';
end;
$$;
