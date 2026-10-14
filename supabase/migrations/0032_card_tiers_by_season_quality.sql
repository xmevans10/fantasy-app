-- Card rarity follows the season, not the pull (product call, 2026-09-26: "the card rarity should
-- correlate with the quality of the season").
--
-- Each card now has one fixed tier, from where its season ranks inside its group (e.g. NBA by
-- PPG, QBs by passing TDs): top ~7% Polychrome, next ~13% Holographic, next ~25% Foil, the rest
-- Gold Base. A pack still rolls a tier per slot at the disclosed odds (70/20/8/2, one Foil+
-- guaranteed) and then draws a random card OF that tier — so the odds shown in the shop stay
-- exactly true, and Wilt '62 is always a Polychrome and always the hard pull.
--
-- Also tightens the Series 1 pick: one card per player by normalised name (person_id is missing
-- on many soccer rows, which let Messi, Ronaldo and Lewandowski in twice), and soccer only from
-- clubs that play in the big five leagues (the rule had admitted a Chinese Super League season).
-- Cards that fall out are deactivated, not deleted.

-- A full scan of player_seasons per group; the default API timeout is too short for it.
set local statement_timeout = '300s';

alter table public.collectible_cards
  add column if not exists tier text not null default 'gold'
  check (tier in ('gold', 'foil', 'holographic', 'polychrome'));

create index if not exists collectible_cards_tier_idx on public.collectible_cards (tier) where active;

update public.collectible_cards set active = false;

-- Soccer clubs that appear in a big-five league somewhere in the catalog. Per club, not per row,
-- because many famous seasons carry no competition tag. Computed once off the competition index.
create temp table big_five_clubs on commit drop as
  select distinct team_abbr from public.player_seasons
   where sport = 'soccer' and competition in ('eng.1', 'esp.1', 'ger.1', 'ita.1', 'fra.1');

do $$
declare
  s record;
begin
  for s in
    select * from (values
      ('nfl',      '{QB}'::text[],        'passing_tds',     12, 'games',       10, '{passing_tds,passing_yards,completion_pct}'::text[], '{PASS TD,PASS YDS,CMP%}'::text[]),
      ('nfl',      '{RB}',                'rushing_yards',   10, 'games',       10, '{rushing_yards,rushing_tds,ypc}',                   '{RUSH YDS,RUSH TD,YPC}'),
      ('nfl',      '{WR,TE}',             'receiving_yards', 10, 'games',       10, '{receiving_yards,receptions,receiving_tds}',        '{REC YDS,REC,REC TD}'),
      ('nba',      null,                  'ppg',             30, 'games',       50, '{ppg,rpg,apg}',                                     '{PPG,RPG,APG}'),
      ('baseball', '{H}',                 'home_runs',       16, null,          0,  '{home_runs,rbi,avg}',                               '{HR,RBI,AVG}'),
      ('baseball', '{P}',                 'strike_outs',     10, null,          0,  '{strike_outs,era,wins}',                            '{K,ERA,W}'),
      ('soccer',   '{FW,MF}',             'goals',           20, null,          0,  '{goals,assists,appearances}',                       '{GOALS,AST,APPS}'),
      ('hockey',   null,                  'points',          16, 'games',       40, '{points,goals,assists}',                            '{PTS,G,A}'),
      ('f1',       null,                  'wins',            10, null,          0,  '{wins,poles,podiums}',                              '{WINS,POLES,PODIUMS}'),
      ('tennis',   null,                  'titles',          10, null,          0,  '{titles,grand_slams,matches_won}',                  '{TITLES,SLAMS,WINS}')
    ) as spec(sport, positions, sort_key, n, games_key, min_games, keys, labels)
  loop
    insert into public.collectible_cards
      (id, sport, name, team_abbr, season_year, position, headshot, stat_line, signature, tier, active)
    select ranked.id, ranked.sport, ranked.name, ranked.team_abbr, ranked.season_year, ranked.position,
           ranked.headshot,
           (select jsonb_agg(jsonb_build_object('label', s.labels[k],
                                                'value', public._fmt_stat((ranked.stats ->> s.keys[k])::numeric))
                             order by k)
              from generate_subscripts(s.keys, 1) k),
           s.sort_key,
           case
             when (ranked.rn - 1)::numeric / ranked.total < 0.07 then 'polychrome'
             when (ranked.rn - 1)::numeric / ranked.total < 0.20 then 'holographic'
             when (ranked.rn - 1)::numeric / ranked.total < 0.45 then 'foil'
             else 'gold' end,
           true
      from (
        select top.*,
               row_number() over (order by (top.stats ->> s.sort_key)::numeric desc) rn,
               count(*) over () total
          from (
            select best.*
              from (
                select distinct on (lower(p.name)) p.*
                  from public.player_seasons p
                 where p.sport = s.sport
                   and p.career = false
                   and p.week is null
                   and p.headshot like '%/storage/v1/object/public/player-headshots/%'
                   and (s.positions is null or p.position = any(s.positions))
                   and (s.games_key is null or coalesce((p.stats ->> s.games_key)::numeric, 0) >= s.min_games)
                   and (p.stats ->> s.sort_key) is not null
                   and (p.sport <> 'soccer' or p.team_abbr in (select team_abbr from big_five_clubs))
                 order by lower(p.name), (p.stats ->> s.sort_key)::numeric desc
              ) best
             order by (best.stats ->> s.sort_key)::numeric desc
             limit s.n
          ) top
      ) ranked
    on conflict (id) do update set
      name = excluded.name, team_abbr = excluded.team_abbr, season_year = excluded.season_year,
      position = excluded.position, headshot = excluded.headshot, stat_line = excluded.stat_line,
      signature = excluded.signature, tier = excluded.tier, active = true;
  end loop;
end;
$$;

-- The deal: roll the tier per slot exactly as before, then draw a card of that tier.
create or replace function public._deal_card_pack(p_user uuid, p_source text, p_local_day date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  finishes text[] := '{}';
  r        double precision;
  chosen   text[] := '{}';
  pick     text;
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
  select array_agg(f order by case f when 'gold' then 0 when 'foil' then 1 when 'holographic' then 2 else 3 end)
    into finishes from unnest(finishes) f;

  for i in 1..5 loop
    select id into pick from collectible_cards
     where active and tier = finishes[i] and not (id = any(chosen))
     order by random() limit 1;
    if pick is null then raise exception 'catalog_too_small'; end if;
    chosen := chosen || pick;

    insert into user_cards (user_id, card_id, finish) values (p_user, pick, finishes[i])
    on conflict (user_id, card_id, finish) do update set copies = user_cards.copies + 1
    returning copies = 1 into was_new;
    result := result || jsonb_build_object('card_id', pick, 'finish', finishes[i], 'is_new', was_new);
    pick := null;
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

revoke all on function public._deal_card_pack(uuid, text, date) from public, anon, authenticated;
