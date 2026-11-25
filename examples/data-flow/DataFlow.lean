import Tribrach.Logic

/-!
# Does personal data reach telemetry?

A made-up note-taking app, described as facts about where data goes. The
rules say what "reaches" and "leaks" mean. Queries answer questions an
architect or product manager might ask, each with a plain-English why tree.
-/

namespace DataFlow

open Tribrach.Logic

def c (s : String) : Term := .const s
def v (s : String) : Term := .var s
def fact (p : String) (args : List String) : Fact := { pred := p, args }
def atom (p : String) (args : List Term) : Atom := { pred := p, args }

/-- What the app does with data. In a real project the language instruments
would extract these facts from code. -/
def facts : List Fact := [
  fact "personal" ["email"],
  fact "personal" ["location"],
  fact "flows" ["email", "account"],
  fact "flows" ["account", "crash_report"],
  fact "flows" ["location", "note_metadata"],
  fact "flows" ["note_metadata", "sync_payload"],
  fact "flows" ["note_metadata", "usage_event"],
  fact "flows" ["note_text", "sync_payload"],
  fact "telemetry" ["crash_report"],
  fact "telemetry" ["usage_event"]
]

def rules : List Rule := [
  { name := "sent directly"
    head := atom "reaches" [v "X", v "Y"]
    body := [atom "flows" [v "X", v "Y"]] },
  { name := "sent along a chain"
    head := atom "reaches" [v "X", v "Z"]
    body := [atom "flows" [v "X", v "Y"], atom "reaches" [v "Y", v "Z"]] },
  { name := "personal data in telemetry"
    head := atom "exposed" [v "D", v "E"]
    body := [atom "personal" [v "D"], atom "reaches" [v "D", v "E"], atom "telemetry" [v "E"]] }
]

def templates : Templates := [
  ("personal", "$1 is personal data"),
  ("flows", "$1 is sent to $2"),
  ("reaches", "$1 ends up in $2"),
  ("telemetry", "$1 is a telemetry event"),
  ("exposed", "personal data $1 reaches telemetry event $2")
]

/-- A question, the pattern that answers it, and the answers we expect, so CI
notices if the program changes what it says. -/
structure Question where
  ask : String
  pattern : Atom
  expected : List (List String)

def questions : List Question := [
  { ask := "Which personal data reaches a telemetry event?"
    pattern := atom "exposed" [v "D", v "E"]
    expected := [["email", "crash_report"], ["location", "usage_event"]] },
  { ask := "Where does a user's location end up?"
    pattern := atom "reaches" [c "location", v "Where"]
    expected := [["location", "note_metadata"], ["location", "sync_payload"], ["location", "usage_event"]] },
  { ask := "Does note text reach any telemetry event?"
    pattern := atom "exposed" [c "note_text", v "E"]
    expected := [] }
]

end DataFlow
