"""Code lifted out of an engine file for tests, without importing the file (engine/server.py loads the model at import).

    from server_src import lift
    ns = lift("mid_line", "mid_result", fim=fim, _complete=fake)    # stand-ins first
    ns["mid_line"](...)

`lift` runs the named top-level functions, classes and assignments (or, with `cls`, the methods of that class) in a
fresh namespace (or `into`, a namespace lifted earlier) that holds the stand-ins. Each name the lifted code uses that the file gets from its own module-level
imports, and that no stand-in covers, is imported here: a server function that starts using one more module does not
break the tests that lift it. Imports inside functions run as they always do. Not a test file: the release list runs
only tests/test_*.py and tests/run_*.py.
"""
import ast, builtins, importlib, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "engine" / "server.py"
for p in (str(ROOT / "engine"), str(ROOT)):
    if p not in sys.path: sys.path.insert(0, p)

_TREES = {}


def tree(path=SERVER):
    path = Path(path)
    if path not in _TREES: _TREES[path] = ast.parse(path.read_text())
    return _TREES[path]


def _defines(node):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)): return {node.name}
    if isinstance(node, ast.Assign): return {t.id for t in node.targets if isinstance(t, ast.Name)}
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name): return {node.target.id}
    return set()


def _imports(t):
    """name -> (module, attribute or None) for the file's module-level imports, wherever they sit at the top level."""
    out = {}
    for n in t.body:
        if isinstance(n, ast.Import):
            for a in n.names: out[a.asname or a.name.split(".")[0]] = (a.name if a.asname else a.name.split(".")[0], None)
        elif isinstance(n, ast.ImportFrom) and n.module and not n.level:
            for a in n.names: out[a.asname or a.name] = (n.module, a.name)
    return out


def lift(*names, path=SERVER, cls=None, into=None, **stand_ins):
    t = tree(path)
    body = next(n for n in t.body if isinstance(n, ast.ClassDef) and n.name == cls).body if cls else t.body
    nodes = [n for n in body if _defines(n) & set(names)]
    missing = set(names) - set().union(*map(_defines, nodes)) if nodes else set(names)
    if missing: raise KeyError(f"not at the top of {Path(path).name}{' ' + cls if cls else ''}: {sorted(missing)}")
    ns = into if into is not None else {}
    ns.update(stand_ins)
    used = {n.id for node in nodes for n in ast.walk(node) if isinstance(n, ast.Name)}
    for name, (module, attr) in _imports(t).items():
        if name in used and name not in ns and not hasattr(builtins, name):
            m = importlib.import_module(module)
            ns[name] = getattr(m, attr) if attr else m
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), ns)
    return ns
