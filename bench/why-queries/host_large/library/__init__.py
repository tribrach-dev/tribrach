"""Library lending desk.

`decide(inp)` is the entry point the tests call: given the member at the desk
and the items they want, it returns the sorted loans the desk may issue, such
as ["lend m1 i2"].
"""
from .desk import Desk

_desk = Desk.default()


def decide(inp):
    return _desk.checkout(inp).decisions()
