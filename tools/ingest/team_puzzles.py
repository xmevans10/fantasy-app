"""Discover and mint shared team collections from the stored catalog, never per fan.

python -m tools.ingest.team_puzzles --env-file PATH --output PATH [--publish]
The publisher is immutable/idempotent. New recipe families require a version bump.
"""
from __future__ import annotations
import argparse, collections, datetime as dt, hashlib, json, math, os, time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from .assemble import build_keep4_rows
from .models import RawSeason, slug
from .themes import Theme, StatColumn
from .validate import validate, HEADSHOT_STORE_MARKER

VERSION = 1
SCALES = {
    'QB': ('nfl_qb_fantasy', [('passing_yards','Pass Yds'),('passing_tds','Pass TD'),('interceptions','INT'),('rushing_yards','Rush Yds'),('rushing_tds','Rush TD')]),
    'WR': ('nfl_skill_ppr', [('receptions','Rec'),('receiving_yards','Rec Yds'),('receiving_tds','Rec TD'),('rushing_yards','Rush Yds'),('rushing_tds','Rush TD')]),
    'RB': ('nfl_skill_ppr', [('receptions','Rec'),('receiving_yards','Rec Yds'),('receiving_tds','Rec TD'),('rushing_yards','Rush Yds'),('rushing_tds','Rush TD')]),
}

def eligible(rows, team='NO', through_year=None):
    through_year = through_year if through_year is not None else dt.date.today().year - (1 if dt.date.today().month >= 3 else 2)
    result = {}; rejected = collections.Counter()
    for r in rows:
        pos = r.get('position'); stats = r.get('stats') or {}
        if r.get('sport') != 'nfl' or r.get('team_abbr') not in {team, 'NOR' if team == 'NO' else team} or r.get('career') or r.get('week') is not None or r.get('season_year',9999) > through_year or pos not in SCALES:
            rejected['scope'] += 1; continue
        if not r.get('person_id'):
            rejected['missing_person_id'] += 1; continue
        if any(not isinstance(stats.get(k),(int,float)) or not math.isfinite(stats[k]) for k,_ in SCALES[pos][1]):
            rejected['missing_stat'] += 1; continue
        floor_key, floor = {'QB':('passing_yards',2000),'WR':('receiving_yards',400),'RB':('rushing_yards',300)}[pos]
        if stats[floor_key] < floor:
            rejected['production_floor'] += 1; continue
        identity = (r['person_id'], r['season_year'])
        if identity in result:
            # Conflicting versions cannot be picked arbitrarily.
            if result[identity]['stats'] != stats: raise ValueError(f'Conflicting season {identity}')
            rejected['duplicate_season'] += 1; continue
        result[identity] = dict(r, team_abbr=team)
    return sorted(result.values(),key=lambda r:(r['person_id'],r['season_year'])),dict(rejected)

def discover(rows, team='NO', through_year=None):
    start=time.perf_counter(); pool,rejections=eligible(rows,team,through_year)
    recipes=[]
    by_person=collections.defaultdict(list)
    for r in pool: by_person[(r['person_id'],r['position'])].append(r)
    for (person,pos),rs in sorted(by_person.items()):
        names={r['name'] for r in rs}
        if len(rs)>=8 and len(names)==1:
            name=rs[0]['name']; recipes.append((f'icon-{slug(person)}',f'{name}: peak Saints seasons','icons',pos,rs,True))
    for pos,label in [('QB','quarterback'),('WR','receiving'),('RB','rushing')]:
        rs=[r for r in pool if r['position']==pos]
        recipes.append((f'position-{pos}',f'Saints {label} seasons','history',pos,rs,False))
        for decade in sorted({r['season_year']//10*10 for r in rs}):
            recipes.append((f'era-{pos}-{decade}',f'Saints {label}: the {decade}s','deep_cuts',pos,[r for r in rs if decade<=r['season_year']<decade+10],False))
    recipes.append(('receiving-backs','Saints backs who caught passes','deep_cuts','RB',[r for r in pool if r['position']=='RB' and r['stats']['receptions']>=40],False))
    accepted=[];fingerprints=[];diagnostics=[]
    for key,title,shelf,pos,rs,ladder in recipes:
        scale,cols=SCALES[pos]
        seasons=[RawSeason(name=r['name'],team_abbr=team,season_year=r['season_year'],sport='nfl',position=pos,stats=r['stats'],person_id=r['person_id'],headshot=r.get('headshot') if HEADSHOT_STORE_MARKER in (r.get('headshot') or '') else '',source='stored-catalog') for r in rs]
        theme=Theme(key=key,title=title,sport='nfl',scale=scale,positions=frozenset({pos}),min_stats={},columns=[StatColumn(k,label,'comma_int') for k,label in cols],pool_cap=1000,window_mode='top' if ladder else 'close',dedupe_person=not ladder)
        boards=build_keep4_rows(theme,seasons,max_variants=24)
        reason=collections.Counter();count=0
        for board in boards:
            try: validate(board)
            except ValueError: reason['validator']+=1;continue
            cards=frozenset(p['id'] for p in board.content['players'])
            if any(len(cards & prior)>5 for prior in fingerprints): reason['overlap']+=1;continue
            if any(p['teamAbbr']!=team for p in board.content['players']): raise ValueError('Team attribution failure')
            identity_content = dict(board.content, players=[{k:v for k,v in card.items() if k != 'headshot'} for card in board.content['players']])
            digest=hashlib.sha256(json.dumps({'recipe':key,'version':VERSION,'content':identity_content},sort_keys=True).encode()).hexdigest()
            if count: board.content['theme'] += ': second look'
            puzzle_id=f'team-nfl-{team.lower()}-v{VERSION}-{digest[:20]}'
            board.content['id']=puzzle_id
            accepted.append({'id':puzzle_id,'sport':'nfl','team_abbr':team,'format':'keep4','shelf':shelf,'recipe':key,'recipe_version':VERSION,'content_hash':digest,'content':board.content,'status':'validated','sort_order':len(accepted),'is_starter':False})
            fingerprints.append(cards); count+=1
            # At most two low-overlap boards per cross-player recipe.
            if count >= (1 if ladder else 2): break
        diagnostics.append({'recipe':key,'candidates':len(rs),'distinct_people':len({r['person_id'] for r in rs}),'accepted':count,'rejected':dict(reason)})
    # A recognizable anchor leads, while the remainder is interleaved by shelf.
    anchor = [r for r in accepted if r['content']['theme'].startswith('Drew Brees:')]
    queues = [collections.deque(r for r in accepted if r['shelf']==s and r not in anchor) for s in ['deep_cuts','icons','history']]
    accepted = anchor
    while any(queues):
        for queue in queues:
            if queue: accepted.append(queue.popleft())
    for i,r in enumerate(accepted):r['sort_order']=i;r['is_starter']=i==0
    snapshot=hashlib.sha256(json.dumps(pool,sort_keys=True).encode()).hexdigest()
    return {'version':VERSION,'team':team,'snapshot':snapshot,'eligible_seasons':len(pool),'rejections':rejections,'recipes':diagnostics,'puzzles':accepted,'seconds':round(time.perf_counter()-start,3)}

def request(cfg,table,query=None,body=None):
    url=cfg['SUPABASE_URL'].rstrip('/')+'/rest/v1/'+table
    if query:url+='?'+urlencode(query)
    key=cfg['SUPABASE_SERVICE_ROLE_KEY']; headers={'apikey':key,'Authorization':'Bearer '+key,'Content-Type':'application/json'}
    if body is not None:headers['Prefer']='resolution=ignore-duplicates,return=minimal'
    req=Request(url,data=json.dumps(body).encode() if body is not None else None,headers=headers)
    with urlopen(req,timeout=60) as r:
        raw=r.read();return json.loads(raw) if raw else None

def main():
    p=argparse.ArgumentParser();p.add_argument('--env-file',type=Path);p.add_argument('--catalog',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--publish',action='store_true');a=p.parse_args()
    cfg=dict(os.environ)
    if a.env_file:
        for line in a.env_file.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k,v=line.split('=',1);cfg[k.strip()]=v.strip().strip('"\'')
    if a.catalog:rows=json.loads(a.catalog.read_text())
    else:
        rows=[];offset=0
        while True:
            page=request(cfg,'player_seasons',{'select':'*','sport':'eq.nfl','team_abbr':'in.(NO,NOR)','career':'eq.false','week':'is.null','order':'id','limit':1000,'offset':offset})
            rows+=page
            if len(page)<1000:break
            offset+=1000
    report=discover(rows);a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n')
    if a.publish:
        if len(report['puzzles'])<12:raise SystemExit('Pilot gate: fewer than 12 distinct puzzles')
        # Explicit publish: immutable IDs and ignore-duplicates preserve already served boards.
        existing=request(cfg,'team_puzzles',{'select':'id,content','sport':'eq.nfl','team_abbr':'eq.NO','limit':1000})
        sets=[{p['id'] for p in r['content']['players']} for r in existing]
        ids={r['id'] for r in existing}
        additions=[r for r in report['puzzles'] if r['id'] not in ids and not any(len({p['id'] for p in r['content']['players']} & prior)>5 for prior in sets)]
        if additions:
            request(cfg,'team_puzzles',{'on_conflict':'id'},[dict(r,status='published',source_snapshot=report['snapshot']) for r in additions])
        print(json.dumps({'published_additions':len(additions),'existing':len(existing)}))
    print(json.dumps({k:v for k,v in report.items() if k!='puzzles'},indent=2))

if __name__=='__main__':main()
