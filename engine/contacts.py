"""Read-only Google Contacts snapshot. No I/O on import; refresh is explicit and daily.

GAM output stays on this Mac. A missing/slow GAM retains the last snapshot. Tests
inject a runner and temporary paths; they never invoke GAM.
"""
import csv
import fcntl
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import local
GAM = Path(local.setting('gam', 'bin') or '/nonexistent/gam')   # optional integration (engine/integrations.py)
EMAIL = re.compile(r'[^\s@]+@[^\s@]+\.[^\s@]+')


def parse(text):
    reader = csv.DictReader(io.StringIO(text.lstrip('\ufeff')))
    if not reader.fieldnames or 'resourceName' not in reader.fieldnames:
        raise ValueError('Contacts CSV has no resourceName')
    out = []
    for row in reader:
        resource = (row.get('resourceName') or '').strip()
        if not resource: continue
        other = resource.startswith('otherContacts/')
        emails, phones, names, addresses, orgs, roles = [], [], [], [], [], []
        for key, value in row.items():
            if not key or not isinstance(value, str) or not value.strip(): continue
            value = value.strip()
            if key in ('name', 'displayName') or re.fullmatch(r'names(?:\.\d+)?\.displayName', key): names.append(value)
            elif key in ('email', 'emailAddress') or re.fullmatch(r'emailAddresses(?:\.\d+)?\.value', key):
                emails.extend(v.strip() for v in re.split(r'[;\n]', value) if EMAIL.fullmatch(v.strip()))
            elif key in ('phone', 'phoneNumber') or re.fullmatch(r'phoneNumbers(?:\.\d+)?\.(?:value|canonicalForm)', key): phones.append(value)
            # for the @ mention list (app/MentionRules.swift): one line each, saved contacts only
            elif key == 'address' or re.fullmatch(r'addresses(?:\.\d+)?\.formattedValue', key): addresses.append(' '.join(value.split()))
            elif key in ('organization', 'company') or re.fullmatch(r'organizations(?:\.\d+)?\.name', key): orgs.append(' '.join(value.split()))
            elif re.fullmatch(r'organizations(?:\.\d+)?\.title', key): roles.append(' '.join(value.split()))
        emails.extend(n for n in names if EMAIL.fullmatch(n))
        phones.extend(n for n in names if re.fullmatch(r'[+\d\s().-]+', n))
        emails = sorted(set(emails), key=str.casefold)
        # Some saved cards use an address/number as their display name.
        names = [n for n in names if not EMAIL.fullmatch(n) and not re.fullmatch(r'[+\d\s().-]+', n)]
        if other and not emails: continue
        if not other and not (names or emails or phones): continue
        out.append({'id': 'google:' + resource, 'name': names[0] if names and not other else (emails[0] if emails else phones[0]),
                    'kind': 'person', 'aliases': names[1:] if not other else [],
                    'handles': {**({'email': emails} if emails else {}), **({'phone': sorted(set(phones))} if phones and not other else {}),
                                **({'address': list(dict.fromkeys(addresses))} if addresses and not other else {})},
                    'role': roles[0] if roles and not other else '', 'org': orgs[0] if orgs and not other else '', 'source': 'contacts', 'cards_only': other or not names})
    return out


def run_contacts(args, *, timeout, **kwargs):
    # run() kills only the parent on timeout, then can wait forever on a child's pipes.
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          **{k: v for k, v in kwargs.items() if k != 'capture_output'}) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def refresh(*, cache=None, workspace=None, gam=None, runner=None, now=None):
    from know import atomic
    cache = Path(cache) if cache is not None else ROOT / 'data/contacts.json'
    workspace = Path(workspace) if workspace is not None else ROOT / 'data/workspace.json'
    now = time.time() if now is None else now
    try:
        account = json.loads(workspace.read_text()).get('account', '').strip()
        if not EMAIL.fullmatch(account): return []
    except (OSError, ValueError, AttributeError, TypeError): return []
    def cached():
        try:
            old = json.loads(cache.read_text())
            if not isinstance(old, dict) or old.get('account') != account or not isinstance(old.get('entries'), list): return {}
            return old
        except (OSError, ValueError): return {}
    if gam is None and runner is None:
        import integrations   # optional integration: off, the last snapshot stays and GAM is never run
        if not integrations.available('gam'): return cached().get('entries', [])
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        lock = cache.with_suffix('.lock').open('a')
    except OSError: return cached().get('entries', [])
    with lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return cached().get('entries', [])
        old = cached(); entries = old.get('entries', [])
        interval = 3600 if old.get('failed') else 86400
        if isinstance(old.get('attempted'), (int, float)) and 0 <= now - old['attempted'] < interval: return entries
        snapshot = {'account': account, 'attempted': now, 'updated': old.get('updated'), 'entries': entries}
        # Persist the attempt first: overlapping nightly/on-demand runs and crashes
        # cannot create a retry loop against GAM.
        try: atomic(cache, json.dumps(snapshot, ensure_ascii=False) + '\n')
        except OSError: return entries
        try:
            result = (runner or run_contacts)([str(gam or GAM), 'user', account, 'print', 'contacts', 'fields', 'name,email,phone,addresses,organizations'],
                                             capture_output=True, text=True, timeout=25,
                                             stdin=subprocess.DEVNULL, start_new_session=True)
            if result.returncode or re.search(r'(?im)^\s*(ERROR|WARNING:.*(denied|unauthorized))', result.stderr):
                raise ValueError('Contacts unavailable')
            snapshot.update(entries=parse(result.stdout), updated=now, failed=False)
        except (OSError, ValueError, subprocess.TimeoutExpired): snapshot['failed'] = True
        try: atomic(cache, json.dumps(snapshot, ensure_ascii=False) + '\n')
        except OSError: pass  # an optional source must never break the knowledge build
        return snapshot['entries']


def merge(entries, contacts):
    """Aleph identity wins; combine handles. Other contacts contribute email cards only."""
    def keys(e):
        h = e.get('handles', {})
        keys = {('email', v.casefold()) for v in h.get('email', [])}
        keys |= {('phone', re.sub(r'\D', '', v)) for v in h.get('phone', []) if len(re.sub(r'\D', '', v)) >= 7}
        keys |= {('name', ' '.join(n.casefold().split())) for n in [e['name']] + e.get('aliases', []) if len(n.split()) >= 2}
        return keys
    result = list(entries)
    index = {key: i for i, e in enumerate(result) if e['kind'] == 'person' for key in keys(e)}
    # Saved contacts first so an other-contact copy cannot hide a saved person's name.
    for contact in sorted(contacts, key=lambda e: bool(e.get('cards_only'))):
        ck = keys(contact)
        hits = {index[k] for k in ck if k in index}
        if len(hits) > 1: continue  # conflicting identities: do not attach one person's handle to another
        if hits:
            i = next(iter(hits)); e = result[i]
            for kind, values in contact['handles'].items():
                e['handles'][kind] = sorted(set(e['handles'].get(kind, []) + values))
            if contact.get('org') and not e.get('org'): e['org'] = contact['org']
            if not contact.get('cards_only'):
                e['aliases'] = sorted(set(e.get('aliases', []) + [contact['name']] + contact.get('aliases', [])) - {e['name']})
        else:
            i = len(result); result.append(dict(contact, handles=dict(contact['handles']), aliases=list(contact.get('aliases', []))))
        for key in ck: index[key] = i
    return result


if __name__ == '__main__':
    print(f'contacts: {len(refresh())} cached entries')
