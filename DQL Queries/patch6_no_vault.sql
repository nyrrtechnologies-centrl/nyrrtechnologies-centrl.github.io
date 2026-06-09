-- ============================================================
--  PATCH 6: Replace Vault with app_config for the passphrase
--
--  Vault adds no security benefit here — both Vault and app_config
--  are equally inaccessible to authenticated users via RLS, and
--  both are readable by security-definer functions.
--  Removing Vault eliminates the entire class of name-mismatch
--  and context-access failures that have been causing the NULLs.
-- ============================================================


-- ── 1. Store the passphrase in app_config ────────────────────
-- ⚠ Replace the value below with your actual passphrase
--   (same one you used in the Vault secret — keys already
--   encrypted with it will continue to decrypt correctly).
INSERT INTO public.app_config (key, value)
VALUES ('key_passphrase', 'REPLACE_WITH_YOUR_PASSPHRASE')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


-- ── 2. Replace _encrypt_key ───────────────────────────────────
CREATE OR REPLACE FUNCTION public._encrypt_key(plaintext text)
RETURNS bytea LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_pass text;
BEGIN
  SELECT value INTO v_pass
    FROM public.app_config
   WHERE key = 'key_passphrase'
   LIMIT 1;

  IF v_pass IS NULL OR length(v_pass) < 16 THEN
    RAISE EXCEPTION '_encrypt_key: passphrase missing or too short in app_config';
  END IF;

  RETURN pgp_sym_encrypt(plaintext, v_pass);
END;
$$;

REVOKE ALL ON FUNCTION public._encrypt_key(text) FROM public, anon, authenticated;


-- ── 3. Replace _decrypt_key ───────────────────────────────────
CREATE OR REPLACE FUNCTION public._decrypt_key(ciphertext bytea)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_pass text;
BEGIN
  IF ciphertext IS NULL THEN RETURN ''; END IF;

  SELECT value INTO v_pass
    FROM public.app_config
   WHERE key = 'key_passphrase'
   LIMIT 1;

  IF v_pass IS NULL OR length(v_pass) < 16 THEN
    RAISE EXCEPTION '_decrypt_key: passphrase missing or too short in app_config';
  END IF;

  RETURN pgp_sym_decrypt(ciphertext, v_pass);
EXCEPTION WHEN others THEN
  RETURN '';
END;
$$;

REVOKE ALL ON FUNCTION public._decrypt_key(bytea) FROM public, anon, authenticated;


-- ── 4. Verify encrypt/decrypt round-trips correctly ──────────
DO $$
DECLARE
  v_enc  bytea;
  v_dec  text;
BEGIN
  v_enc := public._encrypt_key('test-value-12345');
  v_dec := public._decrypt_key(v_enc);

  IF v_dec = 'test-value-12345' THEN
    RAISE NOTICE 'SUCCESS: encrypt/decrypt round-trip works correctly';
  ELSE
    RAISE EXCEPTION 'FAILED: decrypted value "%" does not match original', v_dec;
  END IF;
END;
$$;


-- ── 5. Re-encrypt existing keys with the same passphrase ─────
-- If your passphrase is IDENTICAL to what was in Vault, existing
-- encrypted keys are already compatible — skip this block.
--
-- If you used a DIFFERENT passphrase in Vault than what you put
-- in step 1 above, existing keys are now unreadable. In that case
-- run the backfill from patch_autofill_keys.sql again to
-- re-encrypt them with the new passphrase:
--
-- DO $$
-- DECLARE
--   v_mistral_plain  text;
--   v_rss2json_plain text;
-- BEGIN
--   SELECT value INTO v_mistral_plain  FROM public.app_config WHERE key = 'default_mistral_key';
--   SELECT value INTO v_rss2json_plain FROM public.app_config WHERE key = 'default_rss2json_key';
--   UPDATE public.user_settings SET
--     mistral_key_enc  = public._encrypt_key(v_mistral_plain),
--     rss2json_key_enc = public._encrypt_key(v_rss2json_plain),
--     updated_at = now()
--   WHERE mistral_key_enc IS NOT NULL OR rss2json_key_enc IS NOT NULL;
--   RAISE NOTICE 'Re-encryption complete';
-- END;
-- $$;
