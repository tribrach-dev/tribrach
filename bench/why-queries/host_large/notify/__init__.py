"""Notification delivery.

`decide(inp)` is the entry point the tests call: it returns the sorted
channels one event goes out on, such as ["deliver email", "deliver push"].
"""
from .router import Router

_router = Router()


def decide(inp):
    return sorted("deliver " + c for c in _router.route(inp).channels)
