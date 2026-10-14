-- A pack's five-card set may never repeat for the same account, regardless of reveal order.
create table if not exists public.card_pack_sets (
  user_id uuid not null references auth.users(id) on delete cascade,
  card_ids text[] not null,
  primary key (user_id, card_ids)
);
alter table public.card_pack_sets enable row level security;
revoke all on public.card_pack_sets from anon, authenticated;
insert into public.card_pack_sets (user_id, card_ids)
select o.user_id, array(select c->>'card_id' from jsonb_array_elements(o.cards) c order by c->>'card_id')
from public.card_pack_openings o
on conflict do nothing;

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
  attempt  int;
  registered int;
  canonical text[];
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

  -- Reserve the complete set before granting any cards. A unique key protects even
  -- concurrent calls; exhaustion aborts the transaction, including its wallet charge.
  for attempt in 1..100 loop
    chosen := '{}';
    for i in 1..5 loop
      select id into pick from collectible_cards
       where active and tier = finishes[i] and not (id = any(chosen))
       order by random() limit 1;
      if pick is null then raise exception 'catalog_too_small'; end if;
      chosen := chosen || pick;
    end loop;
    select array_agg(id order by id) into canonical from unnest(chosen) id;
    insert into card_pack_sets (user_id, card_ids) values (p_user, canonical)
    on conflict do nothing;
    get diagnostics registered = row_count;
    exit when registered = 1;
  end loop;
  if registered <> 1 then raise exception 'no_unique_packs'; end if;

  for i in 1..5 loop
    pick := chosen[i];
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
