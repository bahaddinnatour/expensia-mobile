-- Run after supabase_shared_finance_schema.sql.
-- Mobile data is the authority for this one-time migration.
insert into public.finance_records (user_id, record_type, record_id, payload, updated_at)
select user_id, 'profile', 'settings', jsonb_build_object(
  'name', data->>'name', 'email', data->>'email', 'selectedId', data->>'selectedId',
  'biometricEnabled', coalesce(data->'biometricEnabled', 'false'::jsonb)
), now()
from public.flutter_app_state
on conflict (user_id, record_type, record_id) do update
set payload = excluded.payload, updated_at = excluded.updated_at, deleted_at = null;

insert into public.finance_records (user_id, record_type, record_id, payload, updated_at)
select user_id, 'category', 'all', jsonb_build_object(
  'categories', coalesce(data->'categories', '[]'::jsonb),
  'icons', coalesce(data->'categoryIcons', '{}'::jsonb)
), now()
from public.flutter_app_state
on conflict (user_id, record_type, record_id) do update
set payload = excluded.payload, updated_at = excluded.updated_at, deleted_at = null;

insert into public.finance_records (user_id, record_type, record_id, payload, updated_at)
select state.user_id, 'portfolio', portfolio->>'id', portfolio - 'transactions', now()
from public.flutter_app_state state
cross join lateral jsonb_array_elements(coalesce(state.data->'portfolios', '[]'::jsonb)) portfolio
on conflict (user_id, record_type, record_id) do update
set payload = excluded.payload, updated_at = excluded.updated_at, deleted_at = null;

insert into public.finance_records (user_id, record_type, record_id, payload, updated_at)
select state.user_id, 'transaction', transaction->>'id', transaction || jsonb_build_object('portfolioId', portfolio->>'id'), now()
from public.flutter_app_state state
cross join lateral jsonb_array_elements(coalesce(state.data->'portfolios', '[]'::jsonb)) portfolio
cross join lateral jsonb_array_elements(coalesce(portfolio->'transactions', '[]'::jsonb)) transaction
on conflict (user_id, record_type, record_id) do update
set payload = excluded.payload, updated_at = excluded.updated_at, deleted_at = null;

insert into public.finance_records (user_id, record_type, record_id, payload, updated_at)
select state.user_id, 'plan', plan->>'id', plan, now()
from public.flutter_app_state state
cross join lateral jsonb_array_elements(coalesce(state.data->'monthlyPlans', '[]'::jsonb)) plan
on conflict (user_id, record_type, record_id) do update
set payload = excluded.payload, updated_at = excluded.updated_at, deleted_at = null;
