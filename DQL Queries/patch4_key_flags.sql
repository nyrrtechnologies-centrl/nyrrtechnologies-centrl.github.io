-- ============================================================
--  PATCH 4: Add get_user_key_flags RPC
--
--  Fixes the root cause: PostgREST returns bytea columns as null
--  in the JSON response, so checking key existence by selecting
--  the raw bytea column always yields null on the client side.
--
--  This RPC returns three booleans instead — safe to send to
--  the browser, and correctly reflects whether each key is set.
-- ============================================================

create or replace function public.get_user_key_flags()
returns json language plpgsql security definer as $$
declare
  v_row public.user_settings%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_row
    from public.user_settings
   where user_id = auth.uid();

  return json_build_object(
    'anthropic_set', (v_row.anthropic_key_enc is not null),
    'mistral_set',   (v_row.mistral_key_enc   is not null),
    'rss2json_set',  (v_row.rss2json_key_enc  is not null)
  );
end;
$$;

grant execute on function public.get_user_key_flags() to authenticated;


-- ── Verify it works ──────────────────────────────────────────
-- Run this while logged in as any user who has keys set.
-- Should return {"anthropic_set":false,"mistral_set":true,"rss2json_set":true}
-- (or similar depending on what keys are stored for that user)
select public.get_user_key_flags();
