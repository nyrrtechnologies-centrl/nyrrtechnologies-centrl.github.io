-- ============================================================
--  PATCH 7: Fix trigger blocked by RLS on user_settings UPDATE
--
--  Root cause: handle_new_user() is SECURITY DEFINER so it runs
--  as the DB owner and bypasses RLS for direct statements.
--  HOWEVER, ON CONFLICT DO UPDATE internally re-evaluates the
--  UPDATE policy — and auth.uid() is NULL inside a trigger,
--  so "auth.uid() = user_id" is always false, silently blocking
--  the update and leaving the encrypted keys as NULL.
--
--  Fix: ALTER the table to FORCE RLS bypass for the trigger
--  function, OR (simpler and safer) do the insert and update
--  as two separate statements so the security-definer context
--  applies cleanly to both.
-- ============================================================


-- ── 1. Verify current state: check if existing users have NULLs
SELECT
  user_id,
  mistral_key_enc  IS NOT NULL AS mistral_set,
  rss2json_key_enc IS NOT NULL AS rss2json_set
FROM public.user_settings
ORDER BY user_id
LIMIT 10;


-- ── 2. Fix the trigger ────────────────────────────────────────
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
-- SET search_path ensures the function runs with a clean, predictable
-- schema path and prevents search_path injection attacks.
SET search_path = public AS $$
DECLARE
  v_mistral_plain  text;
  v_rss2json_plain text;
  v_mistral_enc    bytea;
  v_rss2json_enc   bytea;
BEGIN
  -- ── Profile row ───────────────────────────────────────────
  INSERT INTO public.profiles (id, name, plan)
  VALUES (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    'free'
  )
  ON CONFLICT (id) DO NOTHING;

  -- ── Read default keys ─────────────────────────────────────
  SELECT value INTO v_mistral_plain
    FROM public.app_config
   WHERE key = 'default_mistral_key'
   LIMIT 1;

  SELECT value INTO v_rss2json_plain
    FROM public.app_config
   WHERE key = 'default_rss2json_key'
   LIMIT 1;

  -- ── Encrypt ───────────────────────────────────────────────
  BEGIN
    IF v_mistral_plain  IS NOT NULL AND length(trim(v_mistral_plain))  > 0 THEN
      v_mistral_enc  := public._encrypt_key(v_mistral_plain);
    END IF;
    IF v_rss2json_plain IS NOT NULL AND length(trim(v_rss2json_plain)) > 0 THEN
      v_rss2json_enc := public._encrypt_key(v_rss2json_plain);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_mistral_enc  := NULL;
    v_rss2json_enc := NULL;
  END;

  -- ── Insert user_settings ──────────────────────────────────
  -- Use two separate statements instead of ON CONFLICT DO UPDATE.
  -- ON CONFLICT DO UPDATE re-evaluates the UPDATE RLS policy which
  -- fails because auth.uid() is NULL inside a trigger context.
  -- A plain INSERT followed by a conditional UPDATE both run under
  -- the SECURITY DEFINER context which bypasses RLS correctly.
  INSERT INTO public.user_settings (user_id, mistral_key_enc, rss2json_key_enc)
  VALUES (new.id, v_mistral_enc, v_rss2json_enc)
  ON CONFLICT (user_id) DO NOTHING;

  -- If the row already existed (ON CONFLICT DO NOTHING skipped the insert),
  -- update only the columns that are still NULL.
  UPDATE public.user_settings
     SET
       mistral_key_enc  = COALESCE(mistral_key_enc,  v_mistral_enc),
       rss2json_key_enc = COALESCE(rss2json_key_enc, v_rss2json_enc),
       updated_at       = now()
   WHERE user_id = new.id
     AND (mistral_key_enc IS NULL OR rss2json_key_enc IS NULL);

  RETURN new;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();


-- ── 3. Backfill any existing users with NULL keys ─────────────
DO $$
DECLARE
  v_mistral_plain  text;
  v_rss2json_plain text;
BEGIN
  SELECT value INTO v_mistral_plain
    FROM public.app_config WHERE key = 'default_mistral_key' LIMIT 1;
  SELECT value INTO v_rss2json_plain
    FROM public.app_config WHERE key = 'default_rss2json_key' LIMIT 1;

  UPDATE public.user_settings
     SET
       mistral_key_enc  = COALESCE(mistral_key_enc,  public._encrypt_key(v_mistral_plain)),
       rss2json_key_enc = COALESCE(rss2json_key_enc, public._encrypt_key(v_rss2json_plain)),
       updated_at       = now()
   WHERE mistral_key_enc IS NULL OR rss2json_key_enc IS NULL;

  RAISE NOTICE 'Backfill complete';
END;
$$;


-- ── 4. Confirm backfill worked ────────────────────────────────
SELECT
  user_id,
  mistral_key_enc  IS NOT NULL AS mistral_set,
  rss2json_key_enc IS NOT NULL AS rss2json_set
FROM public.user_settings
ORDER BY user_id
LIMIT 10;
