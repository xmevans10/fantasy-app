-- Collectibles: trading cards of famous seasons, flairs, and the packs that deal them.
--
-- Every roll happens here, never on the device. A pack is a random draw that can be paid for,
-- so the odds, the daily free pack and the paid balance all have to live where a modified client
-- cannot reach them. The client asks `open_card_pack` for a pack and renders what comes back.
--
-- Named `card_*` throughout because `packs` / `pack_items` already mean Week Packs (0028).
--
-- Odds (disclosed in the app before any purchase, App Store Guideline 3.1.1):
--   per card:  Gold Base 70%, Foil 20%, Holographic 8%, Polychrome 2%
--   per pack:  five cards, at least one Foil or better; 1 in 12 packs also carries a flair.

-- ---------------------------------------------------------------- catalog

create table if not exists public.collectible_cards (
  id           text primary key,                 -- the player_seasons.id the card depicts
  set_key      text not null default 'series-1',
  sport        text not null,
  name         text not null,
  team_abbr    text,
  season_year  int  not null,
  position     text,
  headshot     text not null,                    -- store-hosted only, so a card never shows a blank face
  stat_line    jsonb not null,                   -- [{"label":"PASS TD","value":"55"}, ...], in display order
  signature    text not null,                    -- the stat the season was picked for
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table if not exists public.flairs (
  id      text primary key,
  label   text not null,
  symbol  text not null,                          -- SF Symbol name
  rarity  text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  source  text not null check (source in ('unlock', 'pack')),
  sort    int  not null default 0
);

create table if not exists public.unlocks (
  id            text primary key,
  label         text not null,
  detail        text not null,
  reward_packs  int  not null default 0,
  reward_flair  text references public.flairs(id),
  sort          int  not null default 0
);

-- ---------------------------------------------------------------- per-user state

create table if not exists public.user_cards (
  user_id          uuid not null references auth.users(id) on delete cascade,
  card_id          text not null references public.collectible_cards(id),
  finish           text not null check (finish in ('gold', 'foil', 'holographic', 'polychrome')),
  copies           int  not null default 1 check (copies > 0),
  first_pulled_at  timestamptz not null default now(),
  primary key (user_id, card_id, finish)
);

create table if not exists public.user_flairs (
  user_id      uuid not null references auth.users(id) on delete cascade,
  flair_id     text not null references public.flairs(id),
  acquired_at  timestamptz not null default now(),
  primary key (user_id, flair_id)
);

create table if not exists public.user_unlocks (
  user_id     uuid not null references auth.users(id) on delete cascade,
  unlock_id   text not null references public.unlocks(id),
  claimed_at  timestamptz not null default now(),
  primary key (user_id, unlock_id)
);

-- `packs` is the unopened balance from purchases and unlock rewards. The free pack is not a
-- balance: it is "has this user opened a free pack on this device-local day yet".
create table if not exists public.card_pack_wallet (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  packs          int  not null default 0 check (packs >= 0),
  last_free_day  date,
  updated_at     timestamptz not null default now()
);

-- One row per Apple transaction, so a replayed receipt can never grant twice.
create table if not exists public.card_pack_purchases (
  transaction_id  text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  product_id      text not null,
  packs           int  not null check (packs > 0),
  created_at      timestamptz not null default now()
);

create table if not exists public.card_pack_openings (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  source     text not null check (source in ('free', 'paid')),
  local_day  date not null,
  cards      jsonb not null,
  flair_id   text references public.flairs(id),
  opened_at  timestamptz not null default now()
);
create index if not exists card_pack_openings_user_idx on public.card_pack_openings (user_id, opened_at desc);

alter table public.profiles add column if not exists equipped_flair text references public.flairs(id);

-- ---------------------------------------------------------------- RLS

alter table public.collectible_cards   enable row level security;
alter table public.flairs              enable row level security;
alter table public.unlocks             enable row level security;
alter table public.user_cards          enable row level security;
alter table public.user_flairs         enable row level security;
alter table public.user_unlocks        enable row level security;
alter table public.card_pack_wallet    enable row level security;
alter table public.card_pack_purchases enable row level security;
alter table public.card_pack_openings  enable row level security;

drop policy if exists "active cards readable" on public.collectible_cards;
create policy "active cards readable" on public.collectible_cards for select using (active);
drop policy if exists "flairs readable" on public.flairs;
create policy "flairs readable" on public.flairs for select using (true);
drop policy if exists "unlocks readable" on public.unlocks;
create policy "unlocks readable" on public.unlocks for select using (true);
drop policy if exists "own cards" on public.user_cards;
create policy "own cards" on public.user_cards for select using (auth.uid() = user_id);
drop policy if exists "own flairs" on public.user_flairs;
create policy "own flairs" on public.user_flairs for select using (auth.uid() = user_id);
drop policy if exists "own unlocks" on public.user_unlocks;
create policy "own unlocks" on public.user_unlocks for select using (auth.uid() = user_id);
drop policy if exists "own wallet" on public.card_pack_wallet;
create policy "own wallet" on public.card_pack_wallet for select using (auth.uid() = user_id);
drop policy if exists "own openings" on public.card_pack_openings;
create policy "own openings" on public.card_pack_openings for select using (auth.uid() = user_id);
-- No write policies anywhere: every write goes through the security-definer functions below.
-- card_pack_purchases has no read policy either; it is bookkeeping for the service role.

-- ---------------------------------------------------------------- the roll

-- Deals one pack to `p_user`. Internal: callers are `open_card_pack` (after it has charged the
-- pack) and tests. Not granted to any client role.
create or replace function public._deal_card_pack(p_user uuid, p_source text, p_local_day date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  finishes text[] := '{}';
  r        double precision;
  card_ids text[];
  result   jsonb := '[]'::jsonb;
  flair    text;
  was_new  boolean;
  i        int;
begin
  for i in 1..5 loop
    r := random();
    finishes := finishes || case
      when r < 0.02 then 'polychrome'
      when r < 0.10 then 'holographic'
      when r < 0.30 then 'foil'
      else 'gold' end;
  end loop;
  if not ('foil' = any(finishes) or 'holographic' = any(finishes) or 'polychrome' = any(finishes)) then
    finishes[5] := 'foil';
  end if;
  -- Rarest last, so the reveal builds instead of peaking on card one.
  select array_agg(f order by case f when 'gold' then 0 when 'foil' then 1 when 'holographic' then 2 else 3 end)
    into finishes from unnest(finishes) f;

  select array_agg(id) into card_ids
    from (select id from collectible_cards where active order by random() limit 5) c;
  if coalesce(array_length(card_ids, 1), 0) < 5 then
    raise exception 'catalog_too_small';
  end if;

  for i in 1..5 loop
    insert into user_cards (user_id, card_id, finish) values (p_user, card_ids[i], finishes[i])
    on conflict (user_id, card_id, finish) do update set copies = user_cards.copies + 1
    returning copies = 1 into was_new;
    result := result || jsonb_build_object('card_id', card_ids[i], 'finish', finishes[i], 'is_new', was_new);
  end loop;

  if random() < 1.0 / 12 then
    select f.id into flair from flairs f
     where f.source = 'pack'
       and not exists (select 1 from user_flairs u where u.user_id = p_user and u.flair_id = f.id)
     order by random() limit 1;
    if flair is not null then
      insert into user_flairs (user_id, flair_id) values (p_user, flair) on conflict do nothing;
    end if;
  end if;

  insert into card_pack_openings (user_id, source, local_day, cards, flair_id)
  values (p_user, p_source, p_local_day, result, flair);

  return jsonb_build_object('source', p_source, 'cards', result, 'flair_id', flair);
end;
$$;

-- Opens the caller's free pack for `p_local_day` if it hasn't been opened, otherwise spends one
-- from the balance. `p_local_day` is the device's calendar day (the same convention dailies
-- use); it must sit within a day of the server's, so a changed device clock can't mint packs.
create or replace function public.open_card_pack(p_local_day date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid    uuid := auth.uid();
  wallet card_pack_wallet;
  source text;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if p_local_day not between current_date - 1 and current_date + 1 then
    raise exception 'bad_local_day';
  end if;

  insert into card_pack_wallet (user_id) values (uid) on conflict do nothing;
  select * into wallet from card_pack_wallet where user_id = uid for update;

  if wallet.last_free_day is null or wallet.last_free_day < p_local_day then
    source := 'free';
    update card_pack_wallet set last_free_day = p_local_day, updated_at = now() where user_id = uid;
  elsif wallet.packs > 0 then
    source := 'paid';
    update card_pack_wallet set packs = packs - 1, updated_at = now() where user_id = uid;
  else
    raise exception 'no_packs';
  end if;

  return public._deal_card_pack(uid, source, p_local_day);
end;
$$;

-- Credits packs for one verified Apple transaction. Service role only (the `grant-card-packs`
-- Edge Function, after it has verified the signed transaction). Returns false for a transaction
-- already credited, which the function reports as success: the client may finish it.
create or replace function public.grant_card_packs(p_user uuid, p_transaction text, p_product text, p_packs int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare inserted int;
begin
  insert into card_pack_purchases (transaction_id, user_id, product_id, packs)
  values (p_transaction, p_user, p_product, p_packs)
  on conflict (transaction_id) do nothing;
  get diagnostics inserted = row_count;
  if inserted = 0 then return false; end if;
  insert into card_pack_wallet (user_id, packs) values (p_user, p_packs)
  on conflict (user_id) do update set packs = card_pack_wallet.packs + excluded.packs, updated_at = now();
  return true;
end;
$$;

-- Checks every unlock the caller hasn't claimed against what they've actually done, and pays
-- out the ones they now meet. Idempotent: returns only what this call newly claimed.
create or replace function public.claim_unlocks()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid      uuid := auth.uid();
  games    int;
  perfects int;
  streak   int;
  claimed  jsonb := '[]'::jsonb;
  u        unlocks;
  met      boolean;
begin
  if uid is null then raise exception 'not_authenticated'; end if;

  select count(*), count(*) filter (where perfect), coalesce(max(streak_after), 0)
    into games, perfects, streak from game_results where user_id = uid;
  streak := greatest(streak, coalesce((select p.streak from progress p where p.user_id = uid), 0));

  for u in select * from unlocks
            where id not in (select unlock_id from user_unlocks where user_id = uid)
            order by sort loop
    met := case u.id
      when 'first_game'   then games >= 1
      when 'games_50'     then games >= 50
      when 'games_250'    then games >= 250
      when 'perfect_10'   then perfects >= 10
      when 'streak_7'     then streak >= 7
      when 'streak_30'    then streak >= 30
      when 'week_pack'    then exists (
        select 1 from pack_items i
          join game_results g on g.puzzle_id = i.id and g.user_id = uid and g.mode = 'pack'
         group by i.pack_id
        having count(distinct i.id) = (select count(*) from pack_items j where j.pack_id = i.pack_id))
      when 'versus_win'   then exists (select 1 from versus_challenges v where v.winner_id = uid)
      when 'ladder_10'    then exists (select 1 from ladder_progress l where l.user_id = uid and l.highest_rung >= 10)
      when 'season_badge' then exists (select 1 from season_badges s where s.user_id = uid)
      when 'collector_25' then (select count(distinct card_id) from user_cards c where c.user_id = uid) >= 25
      when 'polychrome'   then exists (select 1 from user_cards c where c.user_id = uid and c.finish = 'polychrome')
      else false end;
    continue when not met;

    insert into user_unlocks (user_id, unlock_id) values (uid, u.id) on conflict do nothing;
    if u.reward_packs > 0 then
      insert into card_pack_wallet (user_id, packs) values (uid, u.reward_packs)
      on conflict (user_id) do update set packs = card_pack_wallet.packs + excluded.packs, updated_at = now();
    end if;
    if u.reward_flair is not null then
      insert into user_flairs (user_id, flair_id) values (uid, u.reward_flair) on conflict do nothing;
    end if;
    claimed := claimed || jsonb_build_object('unlock_id', u.id, 'reward_packs', u.reward_packs, 'reward_flair', u.reward_flair);
  end loop;

  return claimed;
end;
$$;

-- Wears a flair the caller owns, or clears it with null.
create or replace function public.equip_flair(p_flair text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if p_flair is not null and not exists (select 1 from user_flairs where user_id = uid and flair_id = p_flair) then
    raise exception 'flair_not_owned';
  end if;
  update profiles set equipped_flair = p_flair where id = uid;
end;
$$;

revoke all on function public._deal_card_pack(uuid, text, date) from public, anon, authenticated;
revoke all on function public.grant_card_packs(uuid, text, text, int) from public, anon, authenticated;
revoke all on function public.open_card_pack(date) from public, anon;
revoke all on function public.claim_unlocks() from public, anon;
revoke all on function public.equip_flair(text) from public, anon;
grant execute on function public.open_card_pack(date) to authenticated;
grant execute on function public.claim_unlocks() to authenticated;
grant execute on function public.equip_flair(text) to authenticated;

-- ---------------------------------------------------------------- seed: flairs + unlocks

insert into public.flairs (id, label, symbol, rarity, source, sort) values
  ('rookie',         'Rookie',         'figure.walk',            'common',    'unlock', 10),
  ('grinder',        'Grinder',        'hammer.fill',            'common',    'unlock', 20),
  ('iron_man',       'Iron Man',       'shield.lefthalf.filled', 'epic',      'unlock', 30),
  ('on_fire',        'On Fire',        'flame.fill',             'rare',      'unlock', 40),
  ('flawless',       'Flawless',       'checkmark.seal.fill',    'rare',      'unlock', 50),
  ('weekly_warrior', 'Weekly Warrior', 'calendar',               'rare',      'unlock', 60),
  ('duelist',        'Duelist',        'bolt.fill',              'rare',      'unlock', 70),
  ('climber',        'Climber',        'figure.stairs',          'rare',      'unlock', 80),
  ('ranked',         'Ranked',         'rosette',                'rare',      'unlock', 90),
  ('collector',      'Collector',      'square.stack.3d.up.fill','rare',      'unlock', 100),
  ('prism',          'Prism',          'sparkles',               'epic',      'unlock', 110),
  ('clutch',         'Clutch',         'timer',                  'rare',      'pack',   200),
  ('ball_knower',    'Ball Knower',    'brain.head.profile',     'epic',      'pack',   210),
  ('dynasty',        'Dynasty',        'building.columns.fill',  'epic',      'pack',   220),
  ('hall_of_famer',  'Hall of Famer',  'star.circle.fill',       'legendary', 'pack',   230),
  ('goat',           'GOAT',           'crown.fill',             'legendary', 'pack',   240)
on conflict (id) do update set label = excluded.label, symbol = excluded.symbol,
  rarity = excluded.rarity, source = excluded.source, sort = excluded.sort;

insert into public.unlocks (id, label, detail, reward_packs, reward_flair, sort) values
  ('first_game',   'First whistle',   'Finish your first game.',                    1, 'rookie',         10),
  ('streak_7',     'Seven straight',  'Reach a 7-day streak.',                      1, 'on_fire',        20),
  ('perfect_10',   'Perfect ten',     'Score 10 perfect games.',                    1, 'flawless',       30),
  ('week_pack',    'Full week',       'Finish every board in a Week Pack.',         1, 'weekly_warrior', 40),
  ('versus_win',   'First blood',     'Win a Versus duel.',                         1, 'duelist',        50),
  ('games_50',     'Fifty up',        'Finish 50 games.',                           1, 'grinder',        60),
  ('ladder_10',    'Up the ladder',   'Reach rung 10 on the ladder.',               1, 'climber',        70),
  ('season_badge', 'Rated',           'Earn a rating-season badge.',                1, 'ranked',         80),
  ('collector_25', 'Binder',          'Own 25 different cards.',                    2, 'collector',      90),
  ('streak_30',    'Thirty straight', 'Reach a 30-day streak.',                     2, 'iron_man',      100),
  ('games_250',    'Lifer',           'Finish 250 games.',                          3, null,            110),
  ('polychrome',   'Oil slick',       'Pull a Polychrome card.',                    0, 'prism',         120)
on conflict (id) do update set label = excluded.label, detail = excluded.detail,
  reward_packs = excluded.reward_packs, reward_flair = excluded.reward_flair, sort = excluded.sort;
