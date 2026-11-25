"""engine/server.py runs code at import (the model loads at module level). A function called there must be defined
above that line: on 2026-11-15 strength_setting() called settings_load(), defined further down, and the engine died
at start with a NameError that no test saw (tests extract single functions). This walks the module's top-level
statements in order and checks every call made while importing reaches only names already bound.

    .venv/bin/python -B tests/test_server_order.py
"""
import ast, builtins, unittest
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "engine" / "server.py"


def bound_by(node):
    out = set()
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)): out.add(node.name)
    elif isinstance(node, (ast.Import, ast.ImportFrom)):
        out |= {(a.asname or a.name).split(".")[0] for a in node.names}
    else:
        for n in ast.walk(node):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store): out.add(n.id)
    return out


class Order(unittest.TestCase):
    def test_import_time_calls_are_defined(self):
        tree = ast.parse(SRC.read_text())
        defs = {n.name: n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
        bound, problems = set(dir(builtins)) | {"__file__", "__name__"}, []

        def calls_in(node, seen):
            """Names called while running `node`, following calls into module functions."""
            for n in ast.walk(node):
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
                    name = n.func.id
                    yield name
                    if name in defs and name not in seen:
                        seen.add(name)
                        yield from calls_in(defs[name], seen)

        for stmt in tree.body:
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Import, ast.ImportFrom)):
                bound |= bound_by(stmt); continue
            if isinstance(stmt, ast.If) and isinstance(stmt.test, ast.Compare) and "__main__" in ast.dump(stmt.test):
                continue   # runs after the whole module is bound
            local = set()
            for n in ast.walk(stmt):
                if isinstance(n, (ast.FunctionDef, ast.Lambda)):
                    for a in ast.walk(n.args):
                        if isinstance(a, ast.arg): local.add(a.arg)
            for name in calls_in(stmt, set()):
                if name in defs and name not in bound:
                    problems.append(f"line {stmt.lineno}: {name}() runs at import before its def (line {defs[name].lineno})")
            bound |= bound_by(stmt)
        self.assertEqual(problems, [], "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
