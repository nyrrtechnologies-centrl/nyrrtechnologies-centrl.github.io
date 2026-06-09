-- ============================================================
--  Run each block separately in the SQL Editor
-- ============================================================

-- 1. Check vault secret is readable by a security definer function
--    (this mimics exactly what the trigger does)
create or replace function public._debug_trigger_context()
returns json language plpgsql security definer as $$
declare
  v_vault_len      int;
  v_mistral_plain  text;
  v_mistral_enc    bytea;
  v_err            text;
begin
  -- Can we read the vault?
  select length(decrypted_secret) into v_vault_len
    from vault.decrypted_secrets
   where name = 'app_key_passphrase'
   limit 1;

  -- Can we read app_config?
  select value into v_mistral_plain
    from public.app_config
   where key = 'default_mistral_key'
   limit 1;

  -- Can we encrypt?
  begin
    v_mistral_enc := public._encrypt_key(v_mistral_plain);
  exception when others then
    get stacked diagnostics v_err = message_text;
    return json_build_object(
      'vault_secret_len',  v_vault_len,
      'mistral_plain_len', length(coalesce(v_mistral_plain,'')),
      'encrypt_error',     v_err
    );
  end;

  return json_build_object(
    'vault_secret_len',  v_vault_len,
    'mistral_plain_len', length(coalesce(v_mistral_plain,'')),
    'encrypted_len',     length(v_mistral_enc),
    'encrypt_error',     null
  );
end;
$$;

select public._debug_trigger_context();
