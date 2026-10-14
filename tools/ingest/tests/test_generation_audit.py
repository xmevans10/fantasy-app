"""Regression checks for canonical history, archive safety, and provider cache integrity."""
import io
import json
from urllib.parse import parse_qs, urlparse
from unittest.mock import Mock
import pytest
from tools.ingest import main, upsert
from tools.ingest.providers import http

@pytest.mark.parametrize('reader,cursor', [
    ('fetch_history_signatures', 'signature'),
    ('fetch_whoami_history', 'id'),
    ('fetch_journeyman_history', 'id'),
])
def test_complete_history_survives_small_server_cap(monkeypatch, reader, cursor):
    monkeypatch.setenv('SUPABASE_URL', 'https://test.invalid')
    monkeypatch.setenv('SUPABASE_SERVICE_ROLE_KEY', 'fake-key')
    rows = [{'id': i, 'signature': f'theme|player{i}', 'sport': 'nfl',
             'player_key': f'p{i}', 'served_date': f'2026-09-0{i}'} for i in range(1, 6)]
    calls = []
    def server(req, timeout):
        query = parse_qs(urlparse(req.full_url).query)
        calls.append(query)
        last = query.get(cursor, ['gt.0' if cursor == 'id' else 'gt.'])[0][3:]
        if cursor == 'id':
            remaining = [r for r in rows if r['id'] > int(last)]
        else:
            remaining = [r for r in rows if r['signature'] > last]
        return io.BytesIO(json.dumps(remaining[:2]).encode())
    monkeypatch.setattr(upsert.urllib.request, 'urlopen', server)
    result = getattr(upsert, reader)()
    assert len(result) == len(rows)
    assert len(calls) == 4
    assert all(q['order'] == [f'{cursor}.asc'] for q in calls)

def test_invalid_json_response_does_not_poison_disk_cache(monkeypatch, tmp_path):
    monkeypatch.setattr(http, 'CACHE_DIR', tmp_path)
    replies = iter(['not JSON', '{"healthy": true}'])
    monkeypatch.setattr(http, '_get', lambda *a, **kw: next(replies))
    with pytest.raises(json.JSONDecodeError):
        http.fetch_json('https://test.invalid', cache_key='provider.json', ttl_hours=8760)
    assert not (tmp_path / 'provider.json').exists()
    assert http.fetch_json('https://test.invalid', cache_key='provider.json') == {'healthy': True}

def test_archive_claim_lookup_failure_prevents_puzzle_writes(monkeypatch):
    monkeypatch.setattr(main.sys, 'argv', ['ingest', '--upsert'])
    monkeypatch.setattr(main, 'load_dotenv', lambda: None)
    monkeypatch.setattr(main, 'gather_seasons', lambda *a: [])
    monkeypatch.setattr(main, 'apply_headshot_ledger', lambda *a: None)
    monkeypatch.setattr(main, 'build_rows', lambda *a: ([], [], {'themes': []}))
    monkeypatch.setattr(main.health, 'write_report', lambda *a: None)
    monkeypatch.setattr(upsert, 'fetch_rows_keyset', lambda *a, **kw: [])
    monkeypatch.setattr(upsert, 'fetch_served_pairs', Mock(side_effect=RuntimeError('lookup offline')))
    write = Mock()
    monkeypatch.setattr(upsert, 'upsert', write)
    with pytest.raises(RuntimeError, match='lookup offline'):
        main.main()
    write.assert_not_called()
