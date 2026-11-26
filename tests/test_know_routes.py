"""Real route and cache functions, compiled alone; no sockets or engine import."""
from email.message import Message
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'engine'))
import know
from test_know_typing import entry, pack
from test_ahead import load
from server_src import lift

class Routes(unittest.TestCase):
    def test_people_decodes_query_and_excludes_private(self):
        e=entry('Hanna'); e['handles']={'email':['hanna@example.test']}
        p=pack(e)
        ns=lift('H',LOCAL_HOSTS={'127.0.0.1'},knowledge=p); ns['H'].token='test-token'
        h=ns['H'].__new__(ns['H']); h.path='/people?q=%3Bhan'; h.client_address=('127.0.0.1',1234)
        h.headers=Message(); h.headers['Host']='127.0.0.1'; h.headers['X-Drafter-Token']='test-token'; h.send=Mock()
        h.do_GET()
        self.assertEqual(h.send.call_args.args[0]['people'][0]['name'],'Hanna')
        h.headers['Origin']='https://example.test'; h.do_GET()
        self.assertEqual(h.send.call_args.args,({'error':'forbidden'},403))

    def test_pack_reload_changes_ahead_key(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'know.json'; know.atomic(path,json.dumps({'entries':[entry('Hanna')]}))
            ns=load(lambda req,**kw: {'text':''},[0]); ns['knowledge']=know.Pack(path)
            old=ns['ahead_key']({'before':'Ha'})
            know.atomic(path,json.dumps({'entries':[]}))
            self.assertNotEqual(old,ns['ahead_key']({'before':'Ha'}))

if __name__=='__main__': unittest.main()
