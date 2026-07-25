-- Per-sport daily canonicality: puzzle_history constraint + whoami_history + grid_history
-- Applied live 2026-07-20 via the Supabase MCP (prod migration `daily_canonicality_history_tables`); recorded
-- here after the fact so the repo's migration ledger matches production. Idempotent
-- (IF NOT EXISTS / duplicate-safe DO blocks), so re-running is a no-op — schema.sql
-- remains the source of truth (CLAUDE.md).

-- One minted pick per calendar day PER SPORT: daily_puzzle.py's own pre-check
-- (fetch_served_pairs) is the primary defense, but that's a read-then-act check, not atomic
-- -- two concurrent/retried runs can both pass it before either writes. This constraint is
-- the hard backstop: it turns that race into a loud upsert failure instead of two puzzles
-- silently claiming the same day (exactly what happened once in production before this was
-- added -- see BALLIQ_SPEC.md). Originally (served_date, format) when only one sport minted
-- per night; widened to include sport when every sport gained its own daily mint. Wrapped in
-- a duplicate-safe DO block rather than a bare ALTER TABLE, which would fail outright if
-- pre-existing rows already violate it.
alter table public.puzzle_history
  drop constraint if exists puzzle_history_served_date_format_key;
do $$ begin
  alter table public.puzzle_history
    add constraint puzzle_history_served_date_sport_format_key unique (served_date, sport, format);
exception when duplicate_object then null;
end $$;
alter table public.puzzle_history enable row level security;
-- no policies -> service-role only

-- Who Am I's canonical-pick audit trail (tools/ingest/daily_whoami.py). The pool is a small
-- hand-authored set (whoami_facts.json), so the picker prefers the LEAST-RECENTLY-served
-- entry per sport rather than guaranteeing exact novelty like Keep4's signature check --
-- append-only history, one canonical pick per (day, sport).
create table if not exists public.whoami_history (
  id          bigint generated always as identity primary key,
  sport       text not null,
  player_key  text not null,     -- normalized canonical player name
  served_date date not null,
  puzzle_id   text not null
);
do $$ begin
  alter table public.whoami_history
    add constraint whoami_history_date_sport_key unique (served_date, sport);
exception when duplicate_object then null;
end $$;
alter table public.whoami_history enable row level security;
-- no policies -> service-role only

-- Grid's lightweight novelty guard (tools/ingest/grid.py): records each day's minted
-- team-set x decade-set so the generator's retry loop can reject a combo served within a
-- trailing window. Deliberately NOT signature-level dedup -- Grid stays deterministic
-- per (sport, date), this just stops verbatim repeats.
create table if not exists public.grid_history (
  id          bigint generated always as identity primary key,
  sport       text not null,
  row_teams   text not null,     -- '|'-joined sorted team abbrs
  col_decades text not null,     -- '|'-joined sorted decade labels
  served_date date not null
);
do $$ begin
  alter table public.grid_history
    add constraint grid_history_date_sport_key unique (served_date, sport);
exception when duplicate_object then null;
end $$;
alter table public.grid_history enable row level security;
-- no policies -> service-role only
