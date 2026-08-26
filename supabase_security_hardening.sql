-- Run once in Supabase SQL Editor after the existing schema scripts.
-- It limits every finance table to authenticated users and their own rows.

revoke all on table public.app_state from anon;
revoke all on table public.flutter_app_state from anon;
revoke all on table public.flutter_sync_records from anon;
revoke all on table public.finance_records from anon;
revoke all on table public.profiles from anon;
grant select, insert, update, delete on table public.app_state to authenticated;
grant select, insert, update, delete on table public.flutter_app_state to authenticated;
grant select, insert, update, delete on table public.flutter_sync_records to authenticated;
grant select, insert, update, delete on table public.finance_records to authenticated;
grant select, insert, update, delete on table public.profiles to authenticated;

alter table public.app_state enable row level security;
alter table public.flutter_app_state enable row level security;
alter table public.flutter_sync_records enable row level security;
alter table public.finance_records enable row level security;
alter table public.profiles enable row level security;

drop policy if exists "Users manage only their own finance data" on public.app_state;
drop policy if exists "app_state_select_own" on public.app_state;
drop policy if exists "app_state_insert_own" on public.app_state;
drop policy if exists "app_state_update_own" on public.app_state;
drop policy if exists "app_state_delete_own" on public.app_state;
create policy "app_state_select_own" on public.app_state for select to authenticated using ((select auth.uid()) = user_id);
create policy "app_state_insert_own" on public.app_state for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "app_state_update_own" on public.app_state for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "app_state_delete_own" on public.app_state for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users manage only their own Flutter finance data" on public.flutter_app_state;
drop policy if exists "flutter_app_state_select_own" on public.flutter_app_state;
drop policy if exists "flutter_app_state_insert_own" on public.flutter_app_state;
drop policy if exists "flutter_app_state_update_own" on public.flutter_app_state;
drop policy if exists "flutter_app_state_delete_own" on public.flutter_app_state;
create policy "flutter_app_state_select_own" on public.flutter_app_state for select to authenticated using ((select auth.uid()) = user_id);
create policy "flutter_app_state_insert_own" on public.flutter_app_state for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "flutter_app_state_update_own" on public.flutter_app_state for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "flutter_app_state_delete_own" on public.flutter_app_state for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users manage only their own Flutter sync records" on public.flutter_sync_records;
drop policy if exists "flutter_sync_records_select_own" on public.flutter_sync_records;
drop policy if exists "flutter_sync_records_insert_own" on public.flutter_sync_records;
drop policy if exists "flutter_sync_records_update_own" on public.flutter_sync_records;
drop policy if exists "flutter_sync_records_delete_own" on public.flutter_sync_records;
create policy "flutter_sync_records_select_own" on public.flutter_sync_records for select to authenticated using ((select auth.uid()) = user_id);
create policy "flutter_sync_records_insert_own" on public.flutter_sync_records for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "flutter_sync_records_update_own" on public.flutter_sync_records for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "flutter_sync_records_delete_own" on public.flutter_sync_records for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users access only their own shared finance records" on public.finance_records;
drop policy if exists "finance_records_select_own" on public.finance_records;
drop policy if exists "finance_records_insert_own" on public.finance_records;
drop policy if exists "finance_records_update_own" on public.finance_records;
drop policy if exists "finance_records_delete_own" on public.finance_records;
create policy "finance_records_select_own" on public.finance_records for select to authenticated using ((select auth.uid()) = user_id);
create policy "finance_records_insert_own" on public.finance_records for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "finance_records_update_own" on public.finance_records for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "finance_records_delete_own" on public.finance_records for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users manage only their own profile" on public.profiles;
drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
drop policy if exists "profiles_delete_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "profiles_insert_own" on public.profiles for insert to authenticated with check ((select auth.uid()) = id);
create policy "profiles_update_own" on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
create policy "profiles_delete_own" on public.profiles for delete to authenticated using ((select auth.uid()) = id);

-- The signup trigger does not need to be callable from the public API.
revoke execute on function public.create_profile_for_new_user() from public, anon, authenticated;
do $$
begin
  if to_regprocedure('public.create_finance_transaction(text,text,text,numeric,boolean,timestamptz)') is not null then
    execute 'revoke execute on function public.create_finance_transaction(text, text, text, numeric, boolean, timestamptz) from public, anon';
    execute 'grant execute on function public.create_finance_transaction(text, text, text, numeric, boolean, timestamptz) to authenticated';
  end if;
  if to_regprocedure('public.create_inflow(text,text,text,numeric,timestamptz)') is not null then
    execute 'revoke execute on function public.create_inflow(text, text, text, numeric, timestamptz) from public, anon';
    execute 'grant execute on function public.create_inflow(text, text, text, numeric, timestamptz) to authenticated';
  end if;
  if to_regprocedure('public.create_outflow(text,text,text,numeric,timestamptz)') is not null then
    execute 'revoke execute on function public.create_outflow(text, text, text, numeric, timestamptz) from public, anon';
    execute 'grant execute on function public.create_outflow(text, text, text, numeric, timestamptz) to authenticated';
  end if;
end $$;
