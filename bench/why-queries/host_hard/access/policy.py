"""Parse the policy text into a Policy object."""
from dataclasses import dataclass, field

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


class PolicyError(ValueError):
    pass


def _split_list(value):
    return [v.strip() for v in value.split(",") if v.strip()]


def parse_sections(text):
    sections, current = {}, None
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            sections.setdefault(current, {})
            continue
        if current is None or "=" not in line:
            raise PolicyError(f"line {lineno}: expected key = value inside a section")
        key, value = line.split("=", 1)
        sections[current][key.strip()] = value.strip()
    return sections


def expand_days(spec):
    """'mon-fri' -> ['mon', ..., 'fri']; 'sat, sun' -> ['sat', 'sun']."""
    out = []
    for part in _split_list(spec):
        if "-" in part:
            start, end = (p.strip() for p in part.split("-", 1))
            i, j = DAYS.index(start), DAYS.index(end)
            out.extend(DAYS[i:j + 1])
        else:
            out.append(part)
    return out


def parse_clock(value):
    hh, _, mm = value.partition(":")
    return int(hh) + int(mm or 0) / 60


def parse_span(spec):
    """'07:00-19:00' -> (7.0, 19.0). The end is exclusive."""
    a, b = spec.split("-", 1)
    return parse_clock(a.strip()), parse_clock(b.strip())


@dataclass
class Policy:
    zones: list
    role_zones: dict
    training: dict
    second_factor_zones: set
    no_visitor_zones: set
    business_days: list
    business_span: tuple
    night_span: tuple
    report_days: list = field(default_factory=list)
    report_span: tuple = (0, 24)
    expiring_within_days: int = 7
    renewal_reminder_days: int = 30
    alert_cooldown_seconds: int = 120

    @classmethod
    def parse(cls, text):
        s = parse_sections(text)
        try:
            return cls(
                zones=_split_list(s["zones"]["names"]),
                role_zones={r: _split_list(z) for r, z in s["roles"].items()},
                training=dict(s.get("training", {})),
                second_factor_zones=set(_split_list(s["restrictions"]["second_factor_off_hours"])),
                no_visitor_zones=set(_split_list(s["restrictions"]["no_visitors"])),
                business_days=expand_days(s["hours"]["business_days"]),
                business_span=parse_span(s["hours"]["business"]),
                night_span=parse_span(s["hours"]["night"]),
                report_days=expand_days(s.get("reporting", {}).get("report_days", "mon-sun")),
                report_span=parse_span(s.get("reporting", {}).get("report_window", "00:00-24:00")),
                expiring_within_days=int(s["contracts"]["expiring_within_days"]),
                renewal_reminder_days=int(s["contracts"].get("renewal_reminder_days", 30)),
                alert_cooldown_seconds=int(s.get("alerts", {}).get("cooldown_seconds", 120)),
            )
        except KeyError as e:
            raise PolicyError(f"missing policy entry {e}") from None

    def zones_for_role(self, role):
        return list(self.role_zones.get(role, []))

    def training_for(self, zone):
        return self.training.get(zone)
