-- Run once: Supabase dashboard -> SQL Editor -> New query -> paste -> Run.
-- Used by amcp-services/amcp-platform-services/services/gateway/alert_store.py

create table if not exists alerts (
    id bigint generated always as identity primary key,
    subject text not null,
    domain text,
    payload jsonb not null,
    received_at timestamptz not null default now()
);
create index if not exists alerts_domain_idx on alerts (domain);
create index if not exists alerts_received_at_idx on alerts (received_at desc);

-- The gateway connects with the postgres role (SUPABASE_DB_URL), which bypasses RLS.
-- Enabling RLS with no policies blocks the public anon key from reading alerts.
alter table alerts enable row level security;
