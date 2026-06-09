-- ============================================================
--  PATCH 4: Add get_user_key_flags RPC
--  Run this in the Supabase SQL Editor.
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
