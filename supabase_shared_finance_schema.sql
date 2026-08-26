-- Shared, user-isolated finance records for Flutter and React.
-- Existing app_state and flutter_app_state tables remain untouched as backups.
create table if not exists public.finance_records (
  user_id uuid not null references auth.users(id) on delete cascade,
  record_type text not null check (record_type in ('profile','category','portfolio','transaction','plan')),
  record_id text not null,
  payload jsonb not null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, record_type, record_id)
);

alter table public.finance_records enable row level security;

create policy "Users access only their own shared finance records"
on public.finance_records for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- Required for instant updates on other signed-in devices and browsers.
alter publication supabase_realtime add table public.finance_records;
