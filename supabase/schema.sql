-- Run this once in Supabase Dashboard -> SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  graph_images jsonb not null default '{}'::jsonb,
  stress_points jsonb not null default '[]'::jsonb,
  avg_stress double precision,
  created_at timestamptz not null default now(),
  constraint sessions_avg_stress_range check (avg_stress is null or (avg_stress >= 0 and avg_stress <= 100))
);

alter table public.users enable row level security;
alter table public.sessions enable row level security;

drop policy if exists "users_select_own" on public.users;
create policy "users_select_own" on public.users for select using (auth.uid() = id);
drop policy if exists "users_insert_own" on public.users;
create policy "users_insert_own" on public.users for insert with check (auth.uid() = id);
drop policy if exists "users_update_own" on public.users;
create policy "users_update_own" on public.users for update using (auth.uid() = id);

drop policy if exists "sessions_select_own" on public.sessions;
create policy "sessions_select_own" on public.sessions for select using (auth.uid() = user_id);
drop policy if exists "sessions_insert_own" on public.sessions;
create policy "sessions_insert_own" on public.sessions for insert with check (auth.uid() = user_id);
drop policy if exists "sessions_update_own" on public.sessions;
create policy "sessions_update_own" on public.sessions for update using (auth.uid() = user_id);
drop policy if exists "sessions_delete_own" on public.sessions;
create policy "sessions_delete_own" on public.sessions for delete using (auth.uid() = user_id);

insert into storage.buckets (id, name, public)
values ('session-graphs', 'session-graphs', false)
on conflict (id) do nothing;

drop policy if exists "session_graphs_read_own" on storage.objects;
create policy "session_graphs_read_own" on storage.objects for select
using (bucket_id = 'session-graphs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "session_graphs_insert_own" on storage.objects;
create policy "session_graphs_insert_own" on storage.objects for insert
with check (bucket_id = 'session-graphs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "session_graphs_update_own" on storage.objects;
create policy "session_graphs_update_own" on storage.objects for update
using (bucket_id = 'session-graphs' and (storage.foldername(name))[1] = auth.uid()::text);
