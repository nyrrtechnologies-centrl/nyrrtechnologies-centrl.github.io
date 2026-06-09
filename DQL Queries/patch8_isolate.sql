-- ============================================================
--  PATCH 8: Definitive isolation test
--
--  Step 1: Run this entire file.
--  Step 2: Sign up a brand new test user.
--  Step 3: Run the SELECT at the bottom to check results.
--  Tell me exactly what the SELECT shows.
-- ============================================================


-- ── Add a debug text column so we can see what the trigger ───
-- actually computed without encryption getting in the way
ALTER TABLE public.user_settings
  ADD COLUMN IF NOT EXISTS _debug_mistral text;


DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_mistral_plain  text;
  v_rss2json_plain text;
  v_mistral_enc    bytea;
  v_rss2json_enc   bytea;
BEGIN
  -- Profile
  INSERT INTO public.profiles (id, name, plan)
  VALUES (new.id, coalesce(new.raw_user_meta_data ->> 'name', ''), 'free')
  ON CONFLICT (id) DO NOTHING;

  -- Read app_config
  SELECT value INTO v_mistral_plain
    FROM public.app_config
   WHERE key = 'default_mistral_key'
   LIMIT 1;

  SELECT value INTO v_rss2json_plain
    FROM public.app_config
   WHERE key = 'default_rss2json_key'
   LIMIT 1;

  -- Encrypt
  BEGIN
    IF v_mistral_plain IS NOT NULL AND length(trim(v_mistral_plain)) > 0 THEN
      v_mistral_enc := public._encrypt_key(v_mistral_plain);
    END IF;
    IF v_rss2json_plain IS NOT NULL AND length(trim(v_rss2json_plain)) > 0 THEN
      v_rss2json_enc := public._encrypt_key(v_rss2json_plain);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_mistral_enc  := NULL;
    v_rss2json_enc := NULL;
  END;

  -- Insert — write debug column alongside so we can see
  -- whether the plain value was read even if encrypt failed
  INSERT INTO public.user_settings (
    user_id,
    mistral_key_enc,
    rss2json_key_enc,
    _debug_mistral
  )
  VALUES (
    new.id,
    v_mistral_enc,
    v_rss2json_enc,
    -- store first 6 chars of plaintext so we can confirm it was read
    -- without exposing the full key
    left(coalesce(v_mistral_plain, 'NULL'), 6)
  )
  ON CONFLICT (user_id) DO NOTHING;

  UPDATE public.user_settings
     SET
       mistral_key_enc  = COALESCE(mistral_key_enc,  v_mistral_enc),
       rss2json_key_enc = COALESCE(rss2json_key_enc, v_rss2json_enc),
       _debug_mistral   = left(coalesce(v_mistral_plain, 'NULL'), 6),
       updated_at       = now()
   WHERE user_id = new.id
     AND (mistral_key_enc IS NULL OR rss2json_key_enc IS NULL);

  RETURN new;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();


-- ── After signing up a new user, run this ────────────────────
SELECT
  user_id,
  mistral_key_enc  IS NOT NULL AS mistral_enc_set,
  rss2json_key_enc IS NOT NULL AS rss2json_enc_set,
  _debug_mistral,
  updated_at
FROM public.user_settings
ORDER BY updated_at DESC
LIMIT 5;
