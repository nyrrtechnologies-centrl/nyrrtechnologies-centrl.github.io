-- ============================================================
--  DIAGNOSTIC PATCH — run this, sign up a new user, then check
--  the Supabase Dashboard → Database → Logs (or run the
--  SELECT at the bottom) to see exactly where it's failing.
-- ============================================================


-- ── Step 1: Check what the trigger can actually see ──────────
-- Run these three SELECTs manually first before anything else.

-- 1a. Confirm app_config has the keys
SELECT key, length(value) as value_length
FROM public.app_config
WHERE key IN ('default_mistral_key', 'default_rss2json_key');

-- 1b. Confirm the Vault secret exists and is readable
--     (run as superuser / service_role in the SQL editor)
SELECT name, length(decrypted_secret) as secret_length
FROM vault.decrypted_secrets
WHERE name = 'app_key_passphrase';

-- 1c. Confirm _encrypt_key works at all
SELECT length(public._encrypt_key('test-value')) as encrypted_length;

-- ── If any of the above return 0 rows or NULL, that is your
--    root cause. Fix it before proceeding. ───────────────────


-- ── Step 2: Replace handle_new_user with RAISE NOTICE logging ──
-- This version logs every step so you can see exactly where
-- it stops in the Supabase Postgres logs.
drop trigger if exists on_auth_user_created on auth.users;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
declare
  v_mistral_plain  text;
  v_rss2json_plain text;
  v_mistral_enc    bytea;
  v_rss2json_enc   bytea;
  v_err            text;
begin
  raise notice '[handle_new_user] fired for user %', new.id;

  -- ── Profile ───────────────────────────────────────────────
  insert into public.profiles (id, name, plan)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'name', ''), 'free')
  on conflict (id) do nothing;

  raise notice '[handle_new_user] profile inserted';

  -- ── Read app_config ───────────────────────────────────────
  select value into v_mistral_plain
    from public.app_config where key = 'default_mistral_key' limit 1;

  select value into v_rss2json_plain
    from public.app_config where key = 'default_rss2json_key' limit 1;

  raise notice '[handle_new_user] app_config read: mistral_plain_len=%, rss2json_plain_len=%',
    length(coalesce(v_mistral_plain, '')),
    length(coalesce(v_rss2json_plain, ''));

  -- ── Encrypt ───────────────────────────────────────────────
  -- NOT wrapped in exception block this time so we can see the real error
  if v_mistral_plain is not null and length(trim(v_mistral_plain)) > 0 then
    begin
      v_mistral_enc := public._encrypt_key(v_mistral_plain);
      raise notice '[handle_new_user] mistral key encrypted OK, len=%', length(v_mistral_enc);
    exception when others then
      get stacked diagnostics v_err = message_text;
      raise notice '[handle_new_user] mistral encrypt FAILED: %', v_err;
      v_mistral_enc := null;
    end;
  else
    raise notice '[handle_new_user] mistral plain is null/empty — skipping encrypt';
  end if;

  if v_rss2json_plain is not null and length(trim(v_rss2json_plain)) > 0 then
    begin
      v_rss2json_enc := public._encrypt_key(v_rss2json_plain);
      raise notice '[handle_new_user] rss2json key encrypted OK, len=%', length(v_rss2json_enc);
    exception when others then
      get stacked diagnostics v_err = message_text;
      raise notice '[handle_new_user] rss2json encrypt FAILED: %', v_err;
      v_rss2json_enc := null;
    end;
  else
    raise notice '[handle_new_user] rss2json plain is null/empty — skipping encrypt';
  end if;

  -- ── Insert user_settings ──────────────────────────────────
  insert into public.user_settings (user_id, mistral_key_enc, rss2json_key_enc)
  values (new.id, v_mistral_enc, v_rss2json_enc)
  on conflict (user_id) do update
    set
      mistral_key_enc  = coalesce(user_settings.mistral_key_enc,  excluded.mistral_key_enc),
      rss2json_key_enc = coalesce(user_settings.rss2json_key_enc, excluded.rss2json_key_enc),
      updated_at       = now();

  raise notice '[handle_new_user] user_settings upserted: mistral_enc_null=%, rss2json_enc_null=%',
    (v_mistral_enc is null),
    (v_rss2json_enc is null);

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ── Step 3: After signing up a new test user, run this ───────
-- Check whether the row was written and what it contains
SELECT
  user_id,
  mistral_key_enc  IS NOT NULL AS mistral_set,
  rss2json_key_enc IS NOT NULL AS rss2json_set,
  updated_at
FROM public.user_settings
ORDER BY updated_at DESC
LIMIT 5;

-- ── Step 4: Check Postgres logs for the RAISE NOTICE output ──
-- Supabase Dashboard → Database → Logs → Postgres logs
-- Filter for "handle_new_user" to see the trace.
