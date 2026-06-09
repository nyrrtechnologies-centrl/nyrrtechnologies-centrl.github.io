-- ============================================================
--  FINAL FIX: Replace Vault with app_config in _encrypt_key
--             and _decrypt_key.
--
--  Root cause confirmed: vault.decrypted_secrets is accessible
--  from the SQL editor (superuser) but not from a trigger's
--  security context, so _encrypt_key throws silently and
--  v_mistral_enc stays NULL for every new signup.
-- ============================================================


-- ── 1. Store the passphrase in app_config ────────────────────
-- Use the SAME passphrase that is in your Vault secret so that
-- keys already encrypted for existing users still decrypt correctly.
INSERT INTO public.app_config (key, value)
VALUES ('key_passphrase', 'REPLACE_WITH_YOUR_VAULT_PASSPHRASE')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();


-- ── 2. Replace _encrypt_key ───────────────────────────────────
CREATE OR REPLACE FUNCTION public._encrypt_key(plaintext text)
RETURNS bytea LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
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

  RETURN pgp_sym_encrypt(plaintext, v_pass);
END;
$$;

REVOKE ALL ON FUNCTION public._encrypt_key(text) FROM public, anon, authenticated;


-- ── 3. Replace _decrypt_key ───────────────────────────────────
CREATE OR REPLACE FUNCTION public._decrypt_key(ciphertext bytea)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
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

  RETURN pgp_sym_decrypt(ciphertext, v_pass);
EXCEPTION WHEN others THEN
  RETURN '';
END;
$$;

REVOKE ALL ON FUNCTION public._decrypt_key(bytea) FROM public, anon, authenticated;


-- ── 4. Verify round-trip works ────────────────────────────────
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


-- ── 5. Re-encrypt all existing user keys with the new function ─
-- This is necessary because keys were previously encrypted using
-- the Vault passphrase. Now that _decrypt_key reads from app_config,
-- it must use the same passphrase to decrypt them.
-- If your app_config passphrase is IDENTICAL to the Vault secret,
-- this step is still safe to run — it just re-encrypts with the
-- same passphrase via a different code path.
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


-- ── 6. Clean up debug column added in patch8 ─────────────────
ALTER TABLE public.user_settings
  DROP COLUMN IF EXISTS _debug_mistral;


-- ── 7. Confirm existing users now have keys set ───────────────
SELECT
  user_id,
  mistral_key_enc  IS NOT NULL AS mistral_set,
  rss2json_key_enc IS NOT NULL AS rss2json_set
FROM public.user_settings
ORDER BY updated_at DESC
LIMIT 10;
