-- Authenticated API for creating transactions from trusted personal automations.
-- Run once in Supabase SQL Editor after supabase_shared_finance_schema.sql.
-- Every call is restricted by auth.uid(); do not use a service-role key in a client.

create or replace function public.create_finance_transaction(
  p_portfolio_id text,
  p_description text,
  p_category text,
  p_amount numeric,
  p_inflow boolean,
  p_created_at timestamptz default now()
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_transaction_id text := gen_random_uuid()::text;
  v_transaction jsonb;
begin
  if v_user_id is null then
    raise exception 'You must sign in before creating a transaction';
  end if;
  if coalesce(trim(p_portfolio_id), '') = '' or coalesce(trim(p_description), '') = '' or coalesce(trim(p_category), '') = '' then
    raise exception 'Portfolio, description, and category are required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;
  if not exists (
    select 1 from public.finance_records
    where user_id = v_user_id and record_type = 'portfolio' and record_id = p_portfolio_id and deleted_at is null
  ) then
    raise exception 'Portfolio not found';
  end if;

  v_transaction := jsonb_build_object(
    'id', v_transaction_id,
    'description', trim(p_description),
    'category', trim(p_category),
    'amount', p_amount,
    'inflow', p_inflow,
    'createdAt', p_created_at
  );

  insert into public.finance_records (user_id, record_type, record_id, payload, updated_at)
  values (v_user_id, 'transaction', v_transaction_id, v_transaction || jsonb_build_object('portfolioId', p_portfolio_id), now());

  -- Keep the current web snapshot compatible while clients complete their move to finance_records.
  update public.app_state
  set data = jsonb_set(
        data,
        '{portfolios}',
        (
          select jsonb_agg(
            case when portfolio->>'id' = p_portfolio_id then
              jsonb_set(portfolio, '{transactions}', jsonb_build_array(v_transaction) || coalesce(portfolio->'transactions', '[]'::jsonb))
            else portfolio end
          )
          from jsonb_array_elements(coalesce(data->'portfolios', '[]'::jsonb)) as portfolio
        ),
        true
      ),
      updated_at = now()
  where user_id = v_user_id;

  -- Keep the Flutter snapshot compatible for the same reason.
  update public.flutter_app_state
  set data = jsonb_set(
        data,
        '{portfolios}',
        (
          select jsonb_agg(
            case when portfolio->>'id' = p_portfolio_id then
              jsonb_set(portfolio, '{transactions}', jsonb_build_array(v_transaction) || coalesce(portfolio->'transactions', '[]'::jsonb))
            else portfolio end
          )
          from jsonb_array_elements(coalesce(data->'portfolios', '[]'::jsonb)) as portfolio
        ),
        true
      ),
      updated_at = now()
  where user_id = v_user_id;

  return v_transaction || jsonb_build_object('portfolioId', p_portfolio_id);
end;
$$;

-- Convenience endpoints for integrations that prefer explicit action names.
create or replace function public.create_inflow(
  p_portfolio_id text, p_description text, p_category text, p_amount numeric, p_created_at timestamptz default now()
)
returns jsonb language sql security invoker set search_path = public
as $$ select public.create_finance_transaction(p_portfolio_id, p_description, p_category, p_amount, true, p_created_at); $$;

create or replace function public.create_outflow(
  p_portfolio_id text, p_description text, p_category text, p_amount numeric, p_created_at timestamptz default now()
)
returns jsonb language sql security invoker set search_path = public
as $$ select public.create_finance_transaction(p_portfolio_id, p_description, p_category, p_amount, false, p_created_at); $$;

revoke execute on function public.create_finance_transaction(text, text, text, numeric, boolean, timestamptz) from public, anon;
revoke execute on function public.create_inflow(text, text, text, numeric, timestamptz) from public, anon;
revoke execute on function public.create_outflow(text, text, text, numeric, timestamptz) from public, anon;
grant execute on function public.create_finance_transaction(text, text, text, numeric, boolean, timestamptz) to authenticated;
grant execute on function public.create_inflow(text, text, text, numeric, timestamptz) to authenticated;
grant execute on function public.create_outflow(text, text, text, numeric, timestamptz) to authenticated;
