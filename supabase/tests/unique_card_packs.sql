-- Run only against a fresh disposable test database: psql -v ON_ERROR_STOP=1 -f unique_card_packs.sql
create role anon; create role authenticated;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql as $$ select current_setting('request.jwt.claim.sub',true)::uuid $$;
create table public.collectible_cards(id text primary key, active boolean,tier text);
create table public.user_cards(user_id uuid,card_id text,finish text,copies int default 1,primary key(user_id,card_id,finish));
create table public.flairs(id text,source text);
create table public.user_flairs(user_id uuid,flair_id text,primary key(user_id,flair_id));
create table public.card_pack_wallet(user_id uuid primary key,packs int default 0,last_free_day date,updated_at timestamptz default now());
create table public.card_pack_openings(user_id uuid,source text,local_day date,cards jsonb,flair_id text);
insert into auth.users values('00000000-0000-0000-0000-000000000001');
insert into collectible_cards values('g1',true,'gold'),('g2',true,'gold'),('g3',true,'gold'),('g4',true,'gold'),('f1',true,'foil');
insert into card_pack_openings values('00000000-0000-0000-0000-000000000001','free',current_date-1,'[{"card_id":"old1"},{"card_id":"old2"},{"card_id":"old3"},{"card_id":"old4"},{"card_id":"old5"}]',null);
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
\ir ../migrations/0039_unique_card_packs.sql
do $$
declare
 uid uuid := '00000000-0000-0000-0000-000000000001';
 opened jsonb;
 n int;
 before_packs int;
 before_copies int;
 rejected boolean := false;
begin
 perform set_config('request.jwt.claim.sub',uid::text,true);
 insert into card_pack_wallet(user_id,packs,last_free_day) values(uid,10,current_date);
 for n in 1..100 loop
  begin
   opened := public.open_card_pack(current_date);
   exit;
  exception when others then
   if sqlerrm <> 'catalog_too_small' then raise; end if;
  end;
 end loop;
 if opened is null then raise exception 'first_pack_not_dealt'; end if;
 if jsonb_array_length(opened->'cards') <> 5 then raise exception 'wrong_card_count'; end if;
 select packs into before_packs from card_pack_wallet where user_id=uid;
 select sum(copies) into before_copies from user_cards where user_id=uid;
 for n in 1..100 loop
  begin
   perform public.open_card_pack(current_date);
   raise exception 'reused_pack';
  exception when others then
   if sqlerrm='no_unique_packs' then rejected:=true;exit;
   elsif sqlerrm <> 'catalog_too_small' then raise;
   end if;
  end;
 end loop;
 if not rejected then raise exception 'reuse_guard_not_exercised'; end if;
 if (select packs from card_pack_wallet where user_id=uid) <> before_packs then raise exception 'charged_on_rejection'; end if;
 if (select sum(copies) from user_cards where user_id=uid) <> before_copies then raise exception 'granted_cards_on_rejection'; end if;
 if (select count(*) from card_pack_openings) <> 2 then raise exception 'recorded_rejected_opening'; end if;
 if exists(select 1 from card_pack_openings o where not exists(
  select 1 from card_pack_sets s where s.user_id=o.user_id and s.card_ids=array(select c->>'card_id' from jsonb_array_elements(o.cards) c order by c->>'card_id')
 )) then raise exception 'missing_historical_pack'; end if;
 -- Reversing the reveal order must still conflict with the same canonical set.
 begin
  insert into card_pack_sets values(uid,array(select x from unnest(array['f1','g4','g3','g2','g1']) x order by x));
  raise exception 'order_changed_identity';
 exception when unique_violation then null;
 end;
end $$;
select 'pack uniqueness, history backfill, reveal order, and wallet rollback passed' as result;
