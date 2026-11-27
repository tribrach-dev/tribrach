"""Tiny counters, exported to the monitoring agent."""
from collections import Counter


class Counters:
    def __init__(self):
        self._c = Counter()

    def inc(self, name, by=1):
        self._c[name] += by

    def get(self, name):
        return self._c[name]

    def snapshot(self):
        return dict(sorted(self._c.items()))

    def prometheus(self, prefix="access"):
        return "\n".join(f"{prefix}_{k.replace('.', '_')} {v}" for k, v in sorted(self._c.items()))
