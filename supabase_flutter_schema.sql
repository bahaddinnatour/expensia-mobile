create table if not exists public.flutter_app_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.flutter_app_state enable row level security;

create policy "Users manage only their own Flutter finance data"
on public.flutter_app_state for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);
