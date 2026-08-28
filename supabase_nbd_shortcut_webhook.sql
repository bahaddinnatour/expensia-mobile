-- Secure NBD Shortcut webhook. Run in Supabase SQL Editor once.
-- Replace YOUR_EMAIL_ADDRESS and YOUR_NBD_PORTFOLIO_ID before running.
create table if not exists public.shortcut_ingest_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  portfolio_id text not null,
  key_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

-- Migration for the initial one-key-per-user version of this script.
alter table public.shortcut_ingest_keys drop constraint if exists shortcut_ingest_keys_pkey;
alter table public.shortcut_ingest_keys add primary key (user_id, portfolio_id);

alter table public.shortcut_ingest_keys enable row level security;

-- Run this query once after the function definitions below to create a key.
-- It returns the plaintext key once; save it only in your iPhone Shortcut.
-- select public.rotate_shortcut_ingest_key('YOUR_EMAIL_ADDRESS', 'YOUR_NBD_PORTFOLIO_ID');

create or replace function public.rotate_shortcut_ingest_key(
  p_email text,
  p_portfolio_id text
) returns text
language plpgsql security definer set search_path = public
as $$
declare v_key text := replace(gen_random_uuid()::text, '-', ''); v_user uuid;
begin
  select id into v_user from auth.users where email = lower(trim(p_email));
  if v_user is null then raise exception 'User not found'; end if;
  insert into public.shortcut_ingest_keys(user_id, portfolio_id, key_hash)
  values(v_user, p_portfolio_id, md5(v_key))
  on conflict(user_id, portfolio_id) do update set key_hash = excluded.key_hash, active = true, created_at = now(), last_used_at = null;
  return v_key;
end;
$$;

create or replace function public.create_shortcut_outflow(
  p_key text,
  p_description text,
  p_category text,
  p_amount numeric,
  p_created_at timestamptz,
  p_external_id text
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_user uuid; v_portfolio text; v_id text; v_tx jsonb;
begin
  select user_id, portfolio_id into v_user, v_portfolio
  from public.shortcut_ingest_keys
  where active and key_hash = md5(p_key);
  if v_user is null then raise exception 'Invalid shortcut key'; end if;
  if coalesce(trim(p_description), '') = '' or coalesce(trim(p_category), '') = '' or p_amount <= 0 then
    raise exception 'Description, category, and positive amount are required';
  end if;
  v_id := 'shortcut_' || md5(p_external_id);
  select payload into v_tx from public.finance_records where user_id = v_user and record_type = 'transaction' and record_id = v_id and deleted_at is null;
  if v_tx is not null then return v_tx || jsonb_build_object('duplicate', true); end if;
  v_tx := jsonb_build_object('id', v_id, 'description', trim(p_description), 'category', trim(p_category), 'amount', p_amount, 'inflow', false, 'createdAt', p_created_at);
  insert into public.finance_records(user_id, record_type, record_id, payload, updated_at, deleted_at)
  values(v_user, 'transaction', v_id, v_tx || jsonb_build_object('portfolioId', v_portfolio), now(), null)
  on conflict(user_id, record_type, record_id) do update set
    payload = excluded.payload, updated_at = now(), deleted_at = null;
  update public.app_state set data = jsonb_set(data, '{portfolios}', (select jsonb_agg(case when item->>'id' = v_portfolio then jsonb_set(item, '{transactions}', jsonb_build_array(v_tx) || coalesce(item->'transactions', '[]'::jsonb)) else item end) from jsonb_array_elements(coalesce(data->'portfolios', '[]'::jsonb)) item), true), updated_at = now() where user_id = v_user;
  update public.flutter_app_state set data = jsonb_set(data, '{portfolios}', (select jsonb_agg(case when item->>'id' = v_portfolio then jsonb_set(item, '{transactions}', jsonb_build_array(v_tx) || coalesce(item->'transactions', '[]'::jsonb)) else item end) from jsonb_array_elements(coalesce(data->'portfolios', '[]'::jsonb)) item), true), updated_at = now() where user_id = v_user;
  update public.shortcut_ingest_keys set last_used_at = now() where user_id = v_user;
  return v_tx || jsonb_build_object('portfolioId', v_portfolio);
end;
$$;

revoke all on function public.create_shortcut_outflow(text, text, text, numeric, timestamptz, text) from public;
grant execute on function public.create_shortcut_outflow(text, text, text, numeric, timestamptz, text) to anon, authenticated;
