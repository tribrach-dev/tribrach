import Counter
import Tribrach.Export

/-!
# Example: exporting a manifest and replay vectors

The exporter a project writes once. It names the host symbols that implement
`Counter.counterStep`, stamps the definition, and writes replay vectors for
the counter with `max = 3`. Instruments read only these two files.

    lake exe export out    # writes out/counter.manifest.json and out/counter.vectors.json
-/

open Lean Tribrach Tribrach.Export Counter

namespace CounterExport

def model : Model := counter 3

def manifest : Manifest :=
  { package := "counter",
    links := [
      link (lean% Counter.counterStep) InstrumentId.go "example.com/counter.Step",
      link (lean% Counter.counterStep) InstrumentId.swift "Counter.step(_:in:max:)" ] }

/-- States are numbers; operations are `{"op": name}` objects. -/
def codec : Codec model where
  model := "counter.v1"
  encodeState := fun (n : Nat) => toJson n
  encodeOp := fun (o : CounterOp) =>
    match o with
    | CounterOp.incr => Json.mkObj [("op", Json.str "incr")]
    | CounterOp.reset => Json.mkObj [("op", Json.str "reset")]

def cases : List (Case model) :=
  [ { id := "climb-to-max", start := (0 : Nat),
      ops := [CounterOp.incr, CounterOp.incr, CounterOp.incr, CounterOp.incr] },
    { id := "reset-then-climb", start := (3 : Nat),
      ops := [CounterOp.reset, CounterOp.incr] },
    { id := "no-ops", start := (2 : Nat), ops := [] } ]

/-- Every state in these vectors keeps the counter's rule, so a host that
matches them never holds a count above `max`. -/
theorem vectors_keep_rule (ops : List model.Op) (s : model.State) (h : model.Inv s) :
    ∀ x ∈ model.trace ops s, model.Inv x :=
  model.trace_preserves (counter_preserves 3) ops s h

end CounterExport

def main (args : List String) : IO Unit := do
  let dir : System.FilePath := args.headD "out"
  IO.FS.createDirAll dir
  IO.FS.writeFile (dir / "counter.manifest.json") CounterExport.manifest.render
  IO.FS.writeFile (dir / "counter.vectors.json")
    (vectors CounterExport.codec CounterExport.cases).render
  IO.println s!"wrote {dir}/counter.manifest.json and {dir}/counter.vectors.json"
