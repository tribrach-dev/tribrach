"""Normalise one tick's raw input into typed readings."""
from dataclasses import dataclass


@dataclass(frozen=True)
class ZoneReading:
    name: str
    kind: str
    moisture: int      # percent
    hold: bool


@dataclass(frozen=True)
class Conditions:
    hour: int          # local, 0-23
    temp_c: int
    rain_mm: int       # forecast, next 12 hours


def parse(inp):
    cond = Conditions(hour=int(inp["hour"]) % 24, temp_c=int(inp["temp_c"]),
                      rain_mm=max(0, int(inp["rain_mm"])))
    zones = [ZoneReading(name=z["name"], kind=z["kind"], moisture=int(z["moisture"]),
                         hold=bool(z.get("hold", False)))
             for z in inp.get("zones", [])]
    return cond, zones


def describe(cond):
    return f"{cond.hour:02d}:00, {cond.temp_c} °C, {cond.rain_mm} mm forecast"
