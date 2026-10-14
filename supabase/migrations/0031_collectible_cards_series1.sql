-- Series 1 of the collectible cards: the biggest single seasons in the catalog, one card per
-- player (their best season by the stat that group is famous for), store-hosted photo required.
--
-- Picked by rule rather than by hand so every number on a card is exactly what `player_seasons`
-- holds, and a later series is another row in `spec` plus a new `set_key`. Re-runnable: existing
-- cards keep their id and are refreshed in place.

create or replace function public._fmt_stat(v numeric)
returns text language sql immutable set search_path = '' as $$
  select case
    when v is null then '–'
    when v <> trunc(v) and abs(v) < 1 then ltrim(to_char(v, 'FM0.000'), '0')     -- .349 AVG
    when v <> trunc(v) then to_char(v, 'FM999990.0')                              -- 30.1 PPG
    else to_char(v, 'FM999,999,990') end                                         -- 5,477
$$;

do $$
declare
  s record;
begin
  for s in
    select * from (values
      -- sport,     positions (null = any), sort stat,        n,  min games key, min games, stat keys,                                          labels
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
      (id, sport, name, team_abbr, season_year, position, headshot, stat_line, signature)
    select best.id, best.sport, best.name, best.team_abbr, best.season_year, best.position, best.headshot,
           (select jsonb_agg(jsonb_build_object('label', s.labels[k],
                                                'value', public._fmt_stat((best.stats ->> s.keys[k])::numeric))
                             order by k)
              from generate_subscripts(s.keys, 1) k),
           s.sort_key
      from (
        select distinct on (coalesce(p.person_id, p.name)) p.*
          from public.player_seasons p
         where p.sport = s.sport
           and p.career = false
           and p.week is null
           and p.headshot like '%/storage/v1/object/public/player-headshots/%'
           and (s.positions is null or p.position = any(s.positions))
           and (s.games_key is null or coalesce((p.stats ->> s.games_key)::numeric, 0) >= s.min_games)
           and (p.stats ->> s.sort_key) is not null
         order by coalesce(p.person_id, p.name), (p.stats ->> s.sort_key)::numeric desc
      ) best
     order by (best.stats ->> s.sort_key)::numeric desc
     limit s.n
    on conflict (id) do update set
      name = excluded.name, team_abbr = excluded.team_abbr, season_year = excluded.season_year,
      position = excluded.position, headshot = excluded.headshot, stat_line = excluded.stat_line,
      signature = excluded.signature;
  end loop;
end;
$$;
