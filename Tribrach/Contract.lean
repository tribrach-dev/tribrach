/-!
# Contract identities and dependency edges

A link points at a Lean name, and a stamp shows that something changed. That
isn't enough to answer "what else needs review?". This module gives each
contract a **stable id** that survives renames, records the **revision** a
dependency relies on, and types the **edges** between contracts, so an
upstream change can be turned into an impact report.

## Identity

- `ContractId` is a stable, namespaced string (`shipping.orders`). The Lean
  name can change (`Shipping.OrderBook` to `Shipping.Orders`) without
  changing the id; manifests and claims refer to the id.
- `revision` counts changes to the contract's meaning. The stamp still
  detects any change; a new revision is recorded when the change is
  accepted, together with what is known about compatibility.

## Edges

- `dependsOn`: the downstream contract uses the upstream's guarantees. When
  the upstream changes, those uses must be re-checked unless the change is
  compatible.
- `refines`: every behaviour the downstream allows, the upstream allows too.
  When the upstream changes, the refinement must be re-established unless
  the change is compatible.

Each edge records the upstream revision it was last established against.

## Compatibility, weakest to strongest

- `structural`: the contract changed and nobody has said more. Review.
- `declared`: an author declares the change compatible. Not verified.
- `checked`: compatibility is backed by checked evidence: a theorem, or a
  vector suite run in CI. The report names the evidence.

Over a range of revisions, the weakest step decides.

## Graph checks

- `TR0201` an edge names a contract that doesn't exist.
- `TR0202` contracts depend on each other in a cycle. Edges must form a DAG,
  otherwise "upstream" has no meaning.
- `TR0203` an edge relies on a revision newer than the contract has.
-/

namespace Tribrach

structure ContractId where
  value : String
  deriving DecidableEq, Repr, Inhabited

instance : ToString ContractId := ⟨ContractId.value⟩

structure Contract where
  id : ContractId
  /-- The Lean definition currently stating the contract. May change. -/
  leanName : String
  revision : Nat
  stamp : String
  deriving Repr

inductive EdgeKind where
  | dependsOn
  | refines
  deriving DecidableEq, Repr

def EdgeKind.name : EdgeKind → String
  | .dependsOn => "depends on"
  | .refines => "refines"

/-- What has to be redone when the upstream end of an edge changes. -/
def EdgeKind.obligation : EdgeKind → String
  | .dependsOn => "re-check the uses of its guarantees"
  | .refines => "re-establish the refinement"

/-- `src` relies on `dst` as it was at `revision`. -/
structure Edge where
  src : ContractId
  kind : EdgeKind
  dst : ContractId
  revision : Nat
  deriving Repr

inductive Compat where
  | structural
  | declared (note : String)
  | checked (evidence : String)
  deriving Repr

/-- What is known about the step from `revision - 1` to `revision`. -/
structure Revision where
  id : ContractId
  revision : Nat
  compat : Compat
  deriving Repr

structure Graph where
  contracts : List Contract
  edges : List Edge
  history : List Revision := []

structure Issue where
  code : String
  message : String
  deriving Repr

namespace Graph

def find? (g : Graph) (id : ContractId) : Option Contract :=
  g.contracts.find? (fun c => c.id == id)

def upstreams (g : Graph) (id : ContractId) : List ContractId :=
  (g.edges.filter (fun e => e.src == id)).map (·.dst)

def downstreamEdges (g : Graph) (id : ContractId) : List Edge :=
  g.edges.filter (fun e => e.dst == id)

/-- Whether walking upstream from `frontier` reaches `target`. -/
def reachesUp (g : Graph) : Nat → List ContractId → ContractId → Bool
  | 0, _, _ => false
  | n + 1, frontier, target =>
    if frontier.contains target then true
    else
      let next := (frontier.flatMap g.upstreams).eraseDups
      if next.isEmpty then false else g.reachesUp n next target

def inCycle (g : Graph) (id : ContractId) : Bool :=
  g.reachesUp (g.contracts.length + 1) (g.upstreams id) id

def issues (g : Graph) : List Issue :=
  let missing : List Issue := g.edges.flatMap (fun e =>
    [e.src, e.dst].filterMap (fun id =>
      if (g.find? id).isSome then none
      else some { code := "TR0201",
                  message := s!"{e.src} {e.kind.name} {e.dst}, but there is no contract {id}" }))
  let cycles : List Issue := (g.contracts.filter (fun c => g.inCycle c.id)).map (fun c =>
    { code := "TR0202", message := s!"{c.id} is part of a dependency cycle" })
  let future : List Issue := g.edges.filterMap (fun e =>
    match g.find? e.dst with
    | some c =>
      if e.revision > c.revision then
        some { code := "TR0203",
               message := s!"{e.src} relies on {e.dst}@{e.revision}, but {e.dst} is at revision {c.revision}" }
      else none
    | none => none)
  missing ++ cycles ++ future

/-- What is known about every step from `fromRev` to `toRev`. A step with no
record counts as structural. -/
def stepsBetween (g : Graph) (id : ContractId) (fromRev toRev : Nat) : List Compat :=
  (List.range (toRev - fromRev)).map (fun k =>
    let rev := fromRev + k + 1
    ((g.history.find? (fun r => r.id == id && r.revision == rev)).map (·.compat)).getD .structural)

end Graph

/-- The weakest of a range of steps, with its notes. -/
def Compat.summarize (steps : List Compat) : Compat :=
  if steps.any (fun c => match c with | .structural => true | _ => false) then .structural
  else
    let declared := steps.filterMap (fun c => match c with | .declared n => some n | _ => none)
    if !declared.isEmpty then .declared ("; ".intercalate declared)
    else .checked ("; ".intercalate (steps.filterMap (fun c =>
      match c with | .checked e => some e | _ => none)))

/-- One line of an impact report. -/
structure Impact where
  contract : ContractId
  kind : EdgeKind
  /-- The contract whose review this waits on, for indirect impacts. -/
  through : Option ContractId
  compat : Compat
  text : String

def Impact.needsReview (i : Impact) : Bool :=
  match i.compat with
  | .checked _ => false
  | _ => true

namespace Graph

/-- Contracts downstream of `id`, transitively, with the edge that leads to
each. Stops after `fuel` levels. -/
def below (g : Graph) : Nat → List ContractId → List ContractId → List (ContractId × Edge)
  | 0, _, _ => []
  | n + 1, frontier, seen =>
    let found := frontier.flatMap (fun id =>
      (g.downstreamEdges id).filter (fun e => !seen.contains e.src) |>.map (fun e => (e.src, e)))
    if found.isEmpty then []
    else found ++ g.below n (found.map (·.1)) (seen ++ found.map (·.1))

/-- Impact of `id` moving to revision `newRev`. Direct dependents get a
compatibility verdict over the revisions they skipped. Their own dependents
are listed as indirect when the direct one needs review. -/
def impact (g : Graph) (id : ContractId) (newRev : Nat) : List Impact :=
  (g.downstreamEdges id).flatMap (fun e =>
    if e.revision ≥ newRev then []
    else
      let c := Compat.summarize (g.stepsBetween id e.revision newRev)
      let text := match c with
        | .structural => s!"review: {id} changed from @{e.revision} to @{newRev} with no compatibility claim; {e.kind.obligation}"
        | .declared n => s!"declared compatible, not verified ({n})"
        | .checked ev => s!"compatible, checked by {ev}"
      let direct : Impact := { contract := e.src, kind := e.kind, through := none, compat := c, text }
      if !direct.needsReview then [direct]
      else
        direct :: (g.below (g.contracts.length + 1) [e.src] [id, e.src]).map (fun p =>
          { contract := p.1, kind := p.2.kind, through := some e.src, compat := .structural,
            text := s!"may be affected through {e.src}; {p.2.kind.obligation} after {e.src} is reviewed" }))

end Graph

end Tribrach
