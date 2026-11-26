"""Building access control service.

`decide(inp)` is the entry point the tests call. It evaluates one badge tap
and returns the sorted decisions, such as ["expiry_notice c3", "open d-12"].
"""
from .service import AccessService

_service = None


def decide(inp):
    global _service
    if _service is None:
        _service = AccessService.from_default_policy()
    return _service.handle_tap(inp).decisions()
