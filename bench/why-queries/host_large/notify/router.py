"""Decides which channels an event goes out on."""
from dataclasses import dataclass, field

from . import quiet, settings, throttle, urgency
from .model import Context, Event, Prefs
from .render import render


@dataclass
class Route:
    channels: list = field(default_factory=list)
    skipped: dict = field(default_factory=dict)
    messages: dict = field(default_factory=dict)


class Router:
    def route(self, inp):
        prefs = Prefs.from_json(inp["user"])
        event = Event.from_json(inp["event"])
        ctx = Context.from_json(inp)
        urgent = urgency.is_urgent(event)
        is_quiet = quiet.in_quiet_hours(ctx.hour, prefs.quiet_start, prefs.quiet_end)

        r = Route()
        for ch in settings.CHANNEL_ORDER:
            if ch not in prefs.channels:
                r.skipped[ch] = "turned off"
                continue
            reason = self._blocked(ch, prefs, ctx, urgent, is_quiet)
            if reason:
                r.skipped[ch] = reason
            else:
                r.channels.append(ch)
                r.messages[ch] = render(event, ch)
        return r

    def _blocked(self, ch, prefs, ctx, urgent, is_quiet):
        if ch == "push":
            if throttle.push_throttled(ctx, urgent):
                return "rate limited"
            if is_quiet and not urgent:
                return "quiet hours"
            return None
        if ch == "email":
            return "rate limited" if throttle.email_throttled(ctx) else None
        if ch == "sms":
            if not prefs.sms_verified:
                return "number not verified"
            if not urgent:
                return "not urgent"
            return None
        return "unknown channel"
