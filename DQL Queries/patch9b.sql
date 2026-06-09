-- ============================================================
--  PATCH 9b: Fix pgp_sym_encrypt not found
--  The pgcrypto functions live in the extensions schema.
--  SET search_path must include it.
-- ============================================================

-- ── 1. Confirm where pgcrypto is installed ───────────────────
SELECT ne.nspname, pe.proname
FROM pg_proc pe
JOIN pg_namespace ne ON pe.pronamespace = ne.oid
WHERE pe.proname = 'pgp_sym_encrypt';


-- ── 2. Replace _encrypt_key with correct search_path ─────────
CREATE OR REPLACE FUNCTION public._encrypt_key(plaintext text)
RETURNS bytea LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  v_pass text;
BEGIN
  SELECT value INTO v_pass
    FROM public.app_config
   WHERE key = 'key_passphrase'
   LIMIT 1;

  IF v_pass IS NULL OR length(v_pass) < 16 THEN
    RAISE EXCEPTION '_encrypt_key: passphrase missing or too short';
  END IF;

  RETURN extensions.pgp_sym_encrypt(plaintext, v_pass);
END;
$$;

REVOKE ALL ON FUNCTION public._encrypt_key(text) FROM public, anon, authenticated;


-- ── 3. Replace _decrypt_key with correct search_path ─────────
CREATE OR REPLACE FUNCTION public._decrypt_key(ciphertext bytea)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  v_pass text;
BEGIN
  IF ciphertext IS NULL THEN RETURN ''; END IF;

  SELECT value INTO v_pass
    FROM public.app_config
   WHERE key = 'key_passphrase'
   LIMIT 1;

  IF v_pass IS NULL OR length(v_pass) < 16 THEN
    RAISE EXCEPTION '_decrypt_key: passphrase missing or too short';
  END IF;

  RETURN extensions.pgp_sym_decrypt(ciphertext, v_pass);
EXCEPTION WHEN others THEN
  RETURN '';
END;
$$;

REVOKE ALL ON FUNCTION public._decrypt_key(bytea) FROM public, anon, authenticated;


-- ── 4. Verify round-trip ──────────────────────────────────────
DO $$
DECLARE
  v_enc bytea;
  v_dec text;
BEGIN
  v_enc := public._encrypt_key('test-value-12345');
  v_dec := public._decrypt_key(v_enc);
  IF v_dec = 'test-value-12345' THEN
    RAISE NOTICE 'SUCCESS: encrypt/decrypt round-trip works';
  ELSE
    RAISE EXCEPTION 'FAILED: got "%" instead', v_dec;
  END IF;
END;
$$;


-- ── 5. Backfill NULL keys for existing users ──────────────────
DO $$
DECLARE
  v_mistral_plain  text;
  v_rss2json_plain text;
BEGIN
  SELECT value INTO v_mistral_plain  FROM public.app_config WHERE key = 'default_mistral_key'  LIMIT 1;
  SELECT value INTO v_rss2json_plain FROM public.app_config WHERE key = 'default_rss2json_key' LIMIT 1;

  UPDATE public.user_settings
     SET
       mistral_key_enc  = COALESCE(mistral_key_enc,  public._encrypt_key(v_mistral_plain)),
       rss2json_key_enc = COALESCE(rss2json_key_enc, public._encrypt_key(v_rss2json_plain)),
       updated_at       = now()
   WHERE mistral_key_enc IS NULL OR rss2json_key_enc IS NULL;

  RAISE NOTICE 'Backfill complete';
END;
$$;


-- ── 6. Clean up debug column ──────────────────────────────────
ALTER TABLE public.user_settings DROP COLUMN IF EXISTS _debug_mistral;


-- ── 7. Confirm ────────────────────────────────────────────────
SELECT
  user_id,
  mistral_key_enc  IS NOT NULL AS mistral_set,
  rss2json_key_enc IS NOT NULL AS rss2json_set
FROM public.user_settings
ORDER BY updated_at DESC
LIMIT 10;
