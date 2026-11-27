"""Deploy gate.

`decide(inp)` is the entry point the tests call. It evaluates one change and
returns the sorted decisions, such as ["canary payments", "page payments"].
"""
from .gate import Gate

_gate = Gate.default()


def decide(inp):
    return _gate.evaluate(inp).decisions()
