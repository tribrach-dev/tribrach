"""Garden irrigation controller.

`decide(inp)` is the entry point the tests call: it returns the sorted list
of decisions for one hourly tick, such as ["alert pots", "water lawn"].
"""
from .controller import Controller

_controller = None


def decide(inp):
    global _controller
    if _controller is None:
        _controller = Controller.default()
    return _controller.tick(inp).decisions()
