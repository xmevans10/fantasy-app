-- Series 1 seeding as a function, so a re-tier is one call instead of a copied DO block.
-- Same rule as 0032 plus two catalog fixes found on-device (2026-09-26):
--   * one card per player by ACCENT-FOLDED name ("Kylian Mbappe" and "Kylian Mbappé" were two
--     people to lower(), so he had two cards);
--   * baseball from 1901 on (Charlie Buffinton 1884 was a strikeout Polychrome).
-- Cards that drop out are deactivated, never deleted.

create or replace function public._fold_name(v text)
returns text language sql immutable set search_path = '' as $$
  select lower(translate(v, 'áàâäãåéèêëíìîïóòôöõúùûüñçøšžćčłőű', 'aaaaaaeeeeiiiiooooouuuuncoszcclou'))
$$;

create or replace function public._seed_collectible_series1()
returns int
language plpgsql
security definer
set search_path = public
set statement_timeout = '300s'
as $fn$
declare
  s record;
  n int;
begin
  update collectible_cards set active = false;

  create temp table if not exists big_five_clubs on commit drop as
    select distinct team_abbr from player_seasons
     where sport = 'soccer' and competition in ('eng.1', 'esp.1', 'ger.1', 'ita.1', 'fra.1');

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
    insert into collectible_cards
      (id, sport, name, team_abbr, season_year, position, headshot, stat_line, signature, tier, active)
    select ranked.id, ranked.sport, ranked.name, ranked.team_abbr, ranked.season_year, ranked.position,
           ranked.headshot,
           (select jsonb_agg(jsonb_build_object('label', s.labels[k],
                                                'value', _fmt_stat((ranked.stats ->> s.keys[k])::numeric))
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
                select distinct on (_fold_name(p.name)) p.*
                  from player_seasons p
                 where p.sport = s.sport
                   and p.career = false
                   and p.week is null
                   and p.headshot like '%/storage/v1/object/public/player-headshots/%'
                   and (s.positions is null or p.position = any(s.positions))
                   and (s.games_key is null or coalesce((p.stats ->> s.games_key)::numeric, 0) >= s.min_games)
                   and (p.stats ->> s.sort_key) is not null
                   -- Modern era only for baseball: 1880s pitchers threw 400+ innings and would
                   -- otherwise own the strikeout Polychromes.
                   and (p.sport <> 'baseball' or p.season_year >= 1901)
                   and (p.sport <> 'soccer' or p.team_abbr in (select team_abbr from big_five_clubs))
                 order by _fold_name(p.name), (p.stats ->> s.sort_key)::numeric desc
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

  select count(*) into n from collectible_cards where active;
  return n;
end;
$fn$;

revoke all on function public._seed_collectible_series1() from public, anon, authenticated;

select public._seed_collectible_series1();
