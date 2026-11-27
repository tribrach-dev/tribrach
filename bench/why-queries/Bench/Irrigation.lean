import Bench.Common

/-!
# Garden irrigation controller (specification)

Input:

```json
{"hour": 6, "temp_c": 12, "rain_mm": 1,
 "zones": [{"name": "lawn", "kind": "lawn", "moisture": 22, "hold": false}]}
```

`hour` is the local hour (0-23), `temp_c` the air temperature, `rain_mm` the
rain forecast for the next 12 hours, `moisture` the soil moisture in percent.

Decisions: `water Z` (open the valve for zone Z) and `alert Z` (tell the
owner that a held zone is parched).
-/

namespace Bench.Irrigation

open Tribrach.Logic
open Lean (Json)

/-- Soil moisture below this (percent) means the zone needs water. -/
def dryBelow : String → Int
  | "lawn" => 30
  | "beds" => 40
  | "pots" => 50
  | _ => 30

/-- Below this, the zone is parched. -/
def parchedBelow : Int := 15

/-- Rain of at least this much (mm in the next 12 hours) postpones watering. -/
def rainAtLeast : Int := 5

/-- At or below this air temperature (°C), never water. -/
def frostAtOrBelow : Int := 2

def encodeZone (z : Json) : Except String (List Fact) := do
  let name ← getStr z "name"
  let kind ← getStr z "kind"
  let m ← getInt z "moisture"
  let hold ← getBool z "hold"
  let t := dryBelow kind
  return [fact "zone" [name, kind], fact "moisture" [name, toString m]] ++
    when (m < t) (fact "dry" [name, toString m, toString t]) ++
    when (m < parchedBelow) (fact "parched" [name, toString m]) ++
    when hold (fact "on_hold" [name])

def encode (j : Json) : Except String (List Fact) := do
  let hour ← getInt j "hour"
  let temp ← getInt j "temp_c"
  let rain ← getInt j "rain_mm"
  let zones ← getArr j "zones"
  let zs ← zones.toList.mapM encodeZone
  return [fact "hour" [toString hour], fact "temp" [toString temp], fact "rain" [toString rain]] ++
    when (5 ≤ hour && hour < 9) (fact "morning" [toString hour]) ++
    when (19 ≤ hour && hour < 22) (fact "evening" [toString hour]) ++
    when (rain ≥ rainAtLeast) (fact "rain_expected") ++
    when (temp ≤ frostAtOrBelow) (fact "frost") ++
    zs.flatten

def rules : List Rule := [
  { name := "morning window"
    head := atom "window" [v "H"], body := [atom "morning" [v "H"]] },
  { name := "evening window"
    head := atom "window" [v "H"], body := [atom "evening" [v "H"]] },
  { name := "dry soil"
    head := atom "needs_water" [v "Z"], body := [atom "dry" [v "Z", v "M", v "T"]] },
  { name := "scheduled watering"
    head := atom "water" [v "Z"]
    body := [atom "needs_water" [v "Z"], atom "window" [v "H"]]
    neg := [atom "on_hold" [v "Z"], atom "rain_expected", atom "frost"] },
  { name := "parched pots"
    head := atom "water" [v "Z"]
    body := [atom "zone" [v "Z", c "pots"], atom "parched" [v "Z", v "M"]]
    neg := [atom "on_hold" [v "Z"], atom "frost"] },
  { name := "held zone parched"
    head := atom "alert" [v "Z"]
    body := [atom "parched" [v "Z", v "M"], atom "on_hold" [v "Z"]] }
]

def templates : Templates := [
  ("hour", "the hour is $1"),
  ("temp", "the air temperature is $1 °C"),
  ("rain", "$1 mm of rain is forecast"),
  ("zone", "$1 is a $2 zone"),
  ("moisture", "$1 soil moisture is $2%"),
  ("dry", "$1 is dry (moisture $2% is below $3%)"),
  ("parched", "$1 is parched (moisture $2% is below 15%)"),
  ("on_hold", "$1 is on hold"),
  ("morning", "hour $1 is in the morning window (5-9)"),
  ("evening", "hour $1 is in the evening window (19-22)"),
  ("rain_expected", "at least 5 mm of rain is expected"),
  ("frost", "it is at or below 2 °C"),
  ("window", "hour $1 is a watering hour"),
  ("needs_water", "$1 needs water"),
  ("water", "water $1"),
  ("alert", "alert the owner about $1")
]

def model : BenchModel :=
  { name := "irrigation", encode, rules, templates, decisions := ["water", "alert"] }

end Bench.Irrigation
