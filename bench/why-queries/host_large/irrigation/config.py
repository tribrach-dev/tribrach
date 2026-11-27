"""Controller settings.

Values can be overridden from a site file; the defaults below are what ships.
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SoilSettings:
    # Soil moisture (percent) below which a zone of each kind needs water.
    dry_below: dict = field(default_factory=lambda: {
        "lawn": 30,
        "beds": 40,
        "pots": 50,
    })
    default_dry_below: int = 30
    parched_below: int = 15


@dataclass(frozen=True)
class WeatherSettings:
    rain_postpone_mm: int = 5     # forecast for the next 12 hours
    frost_max_c: int = 2          # at or below this, never water


@dataclass(frozen=True)
class ScheduleSettings:
    # [start, end) local hours
    windows: tuple = ((5, 9), (19, 22))


@dataclass(frozen=True)
class ValveSettings:
    max_open_at_once: int = 2
    flush_seconds: int = 20
    run_minutes: dict = field(default_factory=lambda: {"lawn": 25, "beds": 15, "pots": 5})


@dataclass(frozen=True)
class Settings:
    soil: SoilSettings = SoilSettings()
    weather: WeatherSettings = WeatherSettings()
    schedule: ScheduleSettings = ScheduleSettings()
    valves: ValveSettings = ValveSettings()
    site_name: str = "garden"


def load(overrides=None):
    """Build settings, applying a flat dict of overrides such as
    {"weather.frost_max_c": 1}. Unknown keys are ignored."""
    s = Settings()
    for key, value in (overrides or {}).items():
        section, _, name = key.partition(".")
        part = getattr(s, section, None)
        if part is None or not hasattr(part, name):
            continue
        part = part.__class__(**{**part.__dict__, name: value})
        s = Settings(**{**s.__dict__, section: part})
    return s
