import Tribrach.Schema

/-!
# Example: the capture format, described in Lean

`schema/capture.schema.json` used to be written by hand. Now this module
describes the capture format once, and `#tribrach_write` at the end writes
the JSON Schema whenever the module is compiled. The same description gives
the Lean checker `schema.accepts`, which `Check.lean` runs on the capture
goldens.

The rule that ranges are in order and don't overlap can't be said in JSON
Schema, so it is a Lean function (`rangesInOrder`). The schema names it, with
its stamp, under `x-tribrach`.
-/

open Lean Tribrach Tribrach.Schema Tribrach.Export

namespace CaptureSchema

/-- The (start, end) pairs of a capture's ranges; anything malformed is
left to the shape check. -/
def bounds (j : Json) : List (Int × Int) :=
  match j.getObjValAs? (Array Json) "ranges" with
  | .ok rs => rs.toList.filterMap fun r =>
      match r.getObjValAs? Int "start", r.getObjValAs? Int "end" with
      | .ok s, .ok e => some (s, e)
      | _, _ => none
  | .error _ => []

/-- Each range ends at or after its start and begins after the previous one
ends. -/
def ordered : Int → List (Int × Int) → Bool
  | _, [] => true
  | prev, (s, e) :: rest => s ≤ e && prev < s && ordered e rest

def rangesInOrder (j : Json) : Bool := ordered 0 (bounds j)

def range : Ty :=
  .obj [req "start" (.int (min := some 1)), req "end" (.int (min := some 1))]

def schema : Schema where
  id := "https://github.com/tribrach-dev/tribrach/schema/capture.schema.json"
  title := "Tribrach capture, version 1"
  description := some "Generated from examples/capture-schema/CaptureSchema.lean; edit that file, not this one."
  root := .obj [
    req "version" (.constInt 1),
    req "repo" (.obj [
      req "host" (.str (minLen := some 1)),
      req "name" (.str (pat := some .ownerRepo))]),
    req "commit" (.str (pat := some (.hex 40))),
    req "path" (.str (minLen := some 1) (pat := some .relPath)),
    req "ranges" (.arr range (minItems := some 1)),
    req "snippet_sha256" (.str (pat := some (.hex 64))),
    req "note" (.str (maxLen := some 2000)),
    req "kind" (.enum ["behaviour", "code-shape", "unknown"]),
    req "source" (.obj [
      req "adapter" (.str (pat := some .slug)),
      opt "url" (.str (pat := some .uri))]),
    opt "reporter" (.str (minLen := some 1)),
    req "created_at" (.str (pat := some .dateTime))]
  rules := [
    { lean := lean% CaptureSchema.rangesInOrder,
      doc := "Each range ends at or after its start, and starts after the previous range ends.",
      check := rangesInOrder }]

def files : Files := { files := [schema.file "../../schema/capture.schema.json"] }

#tribrach_write CaptureSchema.files

end CaptureSchema
