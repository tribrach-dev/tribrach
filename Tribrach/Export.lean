import Lean
import Tribrach.Model
import Tribrach.Link

/-!
# Exporters: stamps, manifests and vectors

Instruments never read Lean. They read three files that a project's Lean
exporter writes:

* a **manifest** (`tribrach.manifest.v1`): one entry per link, naming the Lean
  definition, the instrument that owns the link, the host symbol and the
  definition's stamp;
* **vectors** (`tribrach.vectors.v1`): operation sequences with the state the
  model reaches after every step, for replay against host code;
* **stamps**, carried inside both: a hash of a Lean definition and of
  everything it uses from the same Lean file.

## Stamps

`stamp% Counter.counterStep` elaborates to the definition's stamp as a string
literal of 16 hex digits. The hash covers the definition's type and value
and, transitively, every project constant they use, in any file (auxiliary
`match` definitions, the operation type and its constructors, helpers in
other modules). The toolchain, Tribrach and common libraries
(`externalRoots`) are referred to by name only.

A stamp is stable for a given Lean toolchain. A toolchain bump may change
every stamp; instruments then report drift and the project refreshes the
recorded stamps, which is the intended behaviour: the stamp says "look
again", not "this is wrong".

## Writing an exporter

```lean
def bundle : Export.Bundle :=
  { manifest := { package := "counter",
                  links := [Export.link (lean% Counter.counterStep) .go "example.com/counter.Step"] },
    files := [(Export.vectors codec cases).file "counter.vectors.json"] }

#tribrach_export bundle   -- writes the files whenever this module compiles
```
-/

open Lean

namespace Tribrach
namespace Export

/-- A 64-bit value as 16 lowercase hex digits. -/
def hex64 (h : UInt64) : String :=
  let s := String.ofList (Nat.toDigits 16 h.toNat)
  "".pushn '0' (16 - s.length) ++ s

/-- Whether a string is a well-formed stamp: 16 lowercase hex digits. -/
def isStamp (s : String) : Bool :=
  s.length == 16 && s.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))

/-- Modules whose constants a stamp refers to by name only: the toolchain,
Tribrach itself and common libraries. Everything else (the project's own
modules, in any file) is hashed, so a change anywhere upstream in the
project moves the stamps of everything downstream. -/
def externalRoots : List Name :=
  [`Init, `Std, `Lean, `Lake, `Tribrach, `Mathlib, `Batteries, `Aesop, `Qq,
   `Plausible, `ProofWidgets]

/-- Whether a constant belongs to the project (it is hashed into stamps). -/
def inProject (c : Name) : CoreM Bool := do
  match ← findModuleOf? c with
  | none => return true
  | some mod => return !externalRoots.any (·.isPrefixOf mod)

/-- One node of the dependency graph: a project constant, the hash of its
own type and value, and the project constants it uses directly. -/
structure Node where
  name : Name
  hash : UInt64
  uses : Array Name

/-- The project constants a root depends on, itself included, each with its
own hash. -/
def closure (root : Name) : CoreM (Array Node) := do
  let env ← getEnv
  let mut todo : Array Name := #[root]
  let mut seen : NameSet := {}
  let mut out : Array Node := #[]
  let mut i := 0
  while i < todo.size do
    let n := todo[i]!
    i := i + 1
    if seen.contains n then continue
    seen := seen.insert n
    let some ci := env.find? n
      | throwError "stamp%: unknown constant {n}"
    let mut h : UInt64 := mixHash (hash n) ci.type.hash
    let mut used : Array Name := ci.type.getUsedConstants
    if let some v := ci.value? then
      h := mixHash h v.hash
      used := used ++ v.getUsedConstants
    if let .inductInfo iv := ci then
      used := used ++ iv.ctors.toArray
    let mut uses : Array Name := #[]
    for c in used do
      if c != n && !uses.contains c && (← inProject c) then
        uses := uses.push c
        if !seen.contains c then
          todo := todo.push c
    out := out.push { name := n, hash := h, uses }
  return out

/-- Combine a closure into one stamp, independent of traversal order. -/
def stampOfNodes (nodes : Array Node) : String :=
  let sorted := nodes.qsort (fun a b => a.name.toString < b.name.toString)
  hex64 (sorted.foldl (fun acc nd => mixHash (mixHash acc (hash nd.name)) nd.hash) 1469598103934665603)

/-- The stamp of a constant: a hash of its type and value and of every
project constant it uses, followed transitively across files. -/
def stampOf (root : Name) : CoreM String :=
  return stampOfNodes (← closure root)

/-- A Lean definition as a manifest refers to it: its full name and stamp. -/
structure LeanRef where
  name : String
  stamp : String
  deriving Repr, Inhabited

/-- `stamp% Foo.bar` is the stamp of `Foo.bar`, as a string literal. -/
elab "stamp% " id:ident : term => do
  let n ← Elab.realizeGlobalConstNoOverloadWithInfo id
  return mkStrLit (← stampOf n)

/-- `lean% Foo.bar` is a `LeanRef` for `Foo.bar`: its name and stamp. -/
elab "lean% " id:ident : term => do
  let n ← Elab.realizeGlobalConstNoOverloadWithInfo id
  let s ← stampOf n
  return mkAppN (mkConst ``LeanRef.mk) #[mkStrLit n.toString, mkStrLit s]

/-- A manifest link from a Lean reference. -/
def link (r : LeanRef) (owner : InstrumentId) (symbol : String) : Link :=
  { leanName := r.name, owner, symbol, stamp := r.stamp }

def linkJson (l : Link) : Json :=
  Json.mkObj [("lean", Json.str l.leanName), ("owner", Json.str (toString l.owner)),
              ("symbol", Json.str l.symbol), ("stamp", Json.str l.stamp)]

/-- `tribrach.manifest.v1`: the links of one package. -/
structure Manifest where
  /-- The project or package the links belong to. -/
  package : String
  links : List Link

def Manifest.toJson (m : Manifest) : Json :=
  Json.mkObj [("format", Json.str "tribrach.manifest.v1"), ("package", Json.str m.package),
              ("links", Json.arr (m.links.map linkJson).toArray)]

def Manifest.render (m : Manifest) : String := m.toJson.pretty ++ "\n"

/-- How a model's states and operations are written for host code. By
convention an operation is an object whose `op` field names it, with its
arguments as further fields: `{"op": "add", "title": "milk"}`. -/
structure Codec (m : Model) where
  /-- The model id vectors and reports name, such as `counter.v1`. -/
  model : String
  encodeState : m.State → Json
  encodeOp : m.Op → Json

/-- One replay case: a start state and the operations to perform. -/
structure Case (m : Model) where
  id : String
  start : m.State
  ops : List m.Op

/-- The state after each operation, in order. -/
def _root_.Tribrach.Model.trace (m : Model) : List m.Op → m.State → List m.State
  | [], _ => []
  | o :: os, s => m.step o s :: m.trace os (m.step o s)

/-- There is one expected state per operation. -/
theorem _root_.Tribrach.Model.trace_length (m : Model) :
    ∀ (ops : List m.Op) (s : m.State), (m.trace ops s).length = ops.length
  | [], _ => rfl
  | _ :: os, s => by
    simp only [Model.trace, List.length_cons, Model.trace_length m os]

/-- When the model keeps its rules, every expected state in a vector keeps
them too, so a host that matches the vectors never needs a state the model
would reject. -/
theorem _root_.Tribrach.Model.trace_preserves (m : Model) (h : m.Preserves) :
    ∀ (ops : List m.Op) (s : m.State), m.Inv s → ∀ x ∈ m.trace ops s, m.Inv x
  | [], _, _, x, hx => by simp [Model.trace] at hx
  | o :: os, s, hs, x, hx => by
    simp only [Model.trace, List.mem_cons] at hx
    rcases hx with rfl | hx
    · exact h o s hs
    · exact Model.trace_preserves m h os (m.step o s) (h o s hs) x hx

def Case.toJson {m : Model} (c : Codec m) (k : Case m) : Json :=
  Json.mkObj [("id", Json.str k.id), ("start", c.encodeState k.start),
              ("ops", Json.arr (k.ops.map c.encodeOp).toArray),
              ("states", Json.arr ((m.trace k.ops k.start).map c.encodeState).toArray)]

/-- `tribrach.vectors.v1`: replay cases for one model. -/
structure Vectors (m : Model) where
  codec : Codec m
  cases : List (Case m)

def vectors {m : Model} (codec : Codec m) (cases : List (Case m)) : Vectors m :=
  { codec, cases }

def Vectors.toJson {m : Model} (v : Vectors m) : Json :=
  Json.mkObj [("format", Json.str "tribrach.vectors.v1"), ("model", Json.str v.codec.model),
              ("cases", Json.arr (v.cases.map (Case.toJson v.codec)).toArray)]

def Vectors.render {m : Model} (v : Vectors m) : String := v.toJson.pretty ++ "\n"

/-! ## Exporting on build

`#tribrach_export bundle` writes a project's files while Lean compiles the
module that contains it. Lake recompiles that module whenever anything it
imports changes, so `lake build` keeps the exported files current, and an
editor rewrites them as you edit the model.

Next to the manifest it writes:

* `tribrach.graph.json` (`tribrach.graph.v1`): every project constant behind
  each link, with its own hash and what it uses. Commit it: it is what the
  next export compares against.
* `tribrach.refresh.json` (`tribrach.refresh.v1`): what changed since the
  committed graph and manifest, per instrument, with the upstream
  definitions that caused it. It is a build output for people and CI
  comments; don't commit it.
-/

/-- A file to write, relative to the directory of the exporting module. -/
structure File where
  path : String
  text : String

def Vectors.file {m : Model} (v : Vectors m) (path : String) : File :=
  { path, text := v.render }

/-- Everything a project exports. -/
structure Bundle where
  manifest : Manifest
  /-- Where the manifest goes; the graph and refresh files go beside it. -/
  manifestPath : String := "tribrach.manifest.json"
  /-- Other files, such as vectors. -/
  files : List File := []

/-- The graph of every project constant behind the links. -/
def graphJson (package : String) (nodes : Array Node) : Json :=
  let sorted := nodes.qsort (fun a b => a.name.toString < b.name.toString)
  Json.mkObj [("format", Json.str "tribrach.graph.v1"), ("package", Json.str package),
    ("nodes", Json.arr (sorted.map fun nd => Json.mkObj [
      ("name", Json.str nd.name.toString), ("hash", Json.str (hex64 nd.hash)),
      ("uses", Json.arr ((nd.uses.qsort (fun a b => a.toString < b.toString)).map
        (fun u => Json.str u.toString)))]))]

/-- Node hashes from a graph file, by name. -/
def readGraph (j : Json) : List (String × String) :=
  match j.getObjValAs? (Array Json) "nodes" with
  | .ok nodes => nodes.toList.filterMap fun n =>
      match n.getObjValAs? String "name", n.getObjValAs? String "hash" with
      | .ok name, .ok h => some (name, h)
      | _, _ => none
  | .error _ => []

/-- Links from a manifest file as (owner, lean, symbol, stamp). -/
def readLinks (j : Json) : List (String × String × String × String) :=
  match j.getObjValAs? (Array Json) "links" with
  | .ok links => links.toList.filterMap fun l =>
      match l.getObjValAs? String "owner", l.getObjValAs? String "lean",
            l.getObjValAs? String "symbol", l.getObjValAs? String "stamp" with
      | .ok o, .ok n, .ok sym, .ok st => some (o, n, sym, st)
      | _, _, _, _ => none
  | .error _ => []

/-- What changed between the previous export (graph and manifest) and this
one. `closures` gives, for each Lean name, the project constants behind it. -/
def refreshJson (package : String) (oldGraph newGraph : List (String × String))
    (oldLinks newLinks : List (String × String × String × String))
    (closures : List (String × List String)) : Json :=
  let changed := (newGraph.filter fun (n, h) => oldGraph.lookup n != some h).map (·.1)
    ++ (oldGraph.filter fun (n, _) => (newGraph.lookup n).isNone).map (·.1)
  let key (l : String × String × String × String) := (l.1, l.2.1, l.2.2.1)
  let findOld (l : String × String × String × String) :=
    oldLinks.find? fun o => key o == key l
  let because (lean : String) : List String :=
    (((closures.lookup lean).getD []).filter changed.contains).toArray.qsort (· < ·) |>.toList
  let item (o lean sym status : String) (extra : List (String × Json)) : Json :=
    Json.mkObj ([("owner", Json.str o), ("lean", Json.str lean), ("symbol", Json.str sym),
      ("status", Json.str status)] ++ extra)
  let fromNew := newLinks.filterMap fun l =>
    let (o, lean, sym, st) := l
    match findOld l with
    | none => some ((o, lean, sym), item o lean sym "new" [("to", Json.str st)])
    | some (_, _, _, old) =>
      if old == st then none
      else some ((o, lean, sym), item o lean sym "changed"
        [("from", Json.str old), ("to", Json.str st),
         ("because", Json.arr ((because lean).map Json.str).toArray)])
  let removed := oldLinks.filterMap fun l =>
    let (o, lean, sym, st) := l
    if (newLinks.find? fun n => key n == key l).isSome then none
    else some ((o, lean, sym), item o lean sym "removed" [("from", Json.str st)])
  let items := (fromNew ++ removed).toArray.qsort (fun a b =>
    a.1.1 < b.1.1 || (a.1.1 == b.1.1 && (a.1.2.1 < b.1.2.1 ||
      (a.1.2.1 == b.1.2.1 && a.1.2.2 < b.1.2.2))))
  Json.mkObj [("format", Json.str "tribrach.refresh.v1"), ("package", Json.str package),
    ("changed", Json.arr ((changed.toArray.qsort (· < ·)).map Json.str)),
    ("items", Json.arr (items.map (·.2)))]

unsafe def evalBundleImpl (env : Environment) (opts : Options) (n : Name) : Except String Bundle :=
  env.evalConstCheck Bundle opts ``Bundle n

@[implemented_by evalBundleImpl]
opaque evalBundle (env : Environment) (opts : Options) (n : Name) : Except String Bundle

def readJson? (path : System.FilePath) : IO (Option Json) := do
  if !(← path.pathExists) then return none
  match Json.parse (← IO.FS.readFile path) with
  | .ok j => return some j
  | .error _ => return none

/-- Write a bundle's files, the graph and the refresh report. -/
def exportBundle (n : Name) : CoreM Unit := do
  let b ← match evalBundle (← getEnv) (← getOptions) n with
    | .ok b => pure b
    | .error e => throwError "#tribrach_export: {e}"
  let dir := (System.FilePath.mk (← read).fileName).parent.getD "."
  let manifestPath := dir / b.manifestPath
  let side := manifestPath.parent.getD dir
  -- Rebuild every link's closure and check its stamp still matches.
  let mut nodes : Array Node := #[]
  let mut closures : List (String × List String) := []
  for l in b.manifest.links do
    let c := l.leanName.toName
    if ((← getEnv).find? c).isNone then
      throwError "#tribrach_export: unknown Lean name {l.leanName}"
    let cl ← closure c
    if stampOfNodes cl != l.stamp then
      throwError "#tribrach_export: the stamp for {l.leanName} is stale; build it with lean%"
    closures := (l.leanName, cl.toList.map (·.name.toString)) :: closures
    for nd in cl do
      if !nodes.any (·.name == nd.name) then nodes := nodes.push nd
  let graph := graphJson b.manifest.package nodes
  let oldGraph := ((← readJson? (side / "tribrach.graph.json")).map readGraph).getD []
  let oldLinks := ((← readJson? manifestPath).map readLinks).getD []
  let newLinks := readLinks b.manifest.toJson
  let refresh := refreshJson b.manifest.package oldGraph (readGraph graph) oldLinks newLinks closures
  IO.FS.createDirAll side
  IO.FS.writeFile manifestPath b.manifest.render
  IO.FS.writeFile (side / "tribrach.graph.json") (graph.pretty ++ "\n")
  IO.FS.writeFile (side / "tribrach.refresh.json") (refresh.pretty ++ "\n")
  for f in b.files do
    let p := dir / f.path
    if let some parent := p.parent then IO.FS.createDirAll parent
    IO.FS.writeFile p f.text

/-- `#tribrach_export bundle` writes the bundle's files when this module is
compiled. -/
elab "#tribrach_export " id:ident : command => do
  Elab.Command.liftCoreM do
    let n ← Elab.realizeGlobalConstNoOverloadWithInfo id
    exportBundle n

/-- Files with no manifest, such as a generated JSON Schema. -/
structure Files where
  files : List File

unsafe def evalFilesImpl (env : Environment) (opts : Options) (n : Name) : Except String Files :=
  env.evalConstCheck Files opts ``Files n

@[implemented_by evalFilesImpl]
opaque evalFiles (env : Environment) (opts : Options) (n : Name) : Except String Files

/-- `#tribrach_write files` writes the files, relative to this module's
directory, when this module is compiled. Unlike `#tribrach_export` it writes
no manifest, graph or refresh report. -/
elab "#tribrach_write " id:ident : command => do
  Elab.Command.liftCoreM do
    let n ← Elab.realizeGlobalConstNoOverloadWithInfo id
    let fs ← match evalFiles (← getEnv) (← getOptions) n with
      | .ok fs => pure fs
      | .error e => throwError "#tribrach_write: {e}"
    let dir := (System.FilePath.mk (← read).fileName).parent.getD "."
    for f in fs.files do
      let p := dir / f.path
      if let some parent := p.parent then IO.FS.createDirAll parent
      IO.FS.writeFile p f.text

end Export
end Tribrach
