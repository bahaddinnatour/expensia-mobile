-- Run this once in Supabase SQL Editor. It keeps flutter_app_state unchanged.
create table if not exists public.flutter_sync_records (
  user_id uuid not null references auth.users(id) on delete cascade,
  record_type text not null,
  record_id text not null,
  payload jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, record_type, record_id)
);

alter table public.flutter_sync_records enable row level security;

create policy "Users manage only their own Flutter sync records"
on public.flutter_sync_records for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- One private profile is created automatically for every registered email.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Users manage only their own profile"
on public.profiles for all
using (auth.uid() = id)
with check (auth.uid() = id);

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, coalesce(new.email, ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup
  after insert on auth.users
  for each row execute procedure public.create_profile_for_new_user();
