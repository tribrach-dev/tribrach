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

## What changed, and how well it is known

Each accepted revision has a record in the graph's `history`:

- `kind`: `refine` (allows fewer behaviours, keeps every guarantee),
  `extend` with a direction (`backward`: old consumers still work;
  `forward`: new consumers can read old data; `both`), `breaking`, or
  `deprecate`. A rename keeps the id and needs no revision. A record without
  a kind is *unclassified*.
- `compat`, the evidence, weakest to strongest: `refuted` (a check failed),
  `structural` (nothing is known), `declared` (an author says so), `tested`
  (vectors were replayed), `checked` (a theorem).
- `migration`: an optional reference to the migration and its proof.
- `stamp`: the contract's stamp when the record was made. A record for the
  current revision whose stamp no longer matches is stale and is ignored.

Several records may describe the same revision. A refutation always wins;
otherwise the strongest evidence counts. Over a range of revisions, the
weakest step decides. `Tribrach.Impact` turns this into an impact report.

## Graph checks

- `TR0201` an edge names a contract that doesn't exist.
- `TR0202` contracts depend on each other in a cycle. Edges must form a DAG,
  otherwise "upstream" has no meaning.
- `TR0203` an edge relies on a revision newer than the contract has.
- `TR0204` records for one revision disagree: one claims compatibility and
  another refutes it. The refutation wins.
- `TR0205` a record is stale: the definition changed after it was made.
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
  | refuted (evidence : String)
  | structural
  | declared (note : String)
  | tested (suite : String)
  | checked (evidence : String)
  deriving Repr

/-- Weakest (refuted) is 0, strongest (checked) is 4. -/
def Compat.rank : Compat → Nat
  | .refuted _ => 0
  | .structural => 1
  | .declared _ => 2
  | .tested _ => 3
  | .checked _ => 4

def Compat.level : Compat → String
  | .refuted _ => "refuted"
  | .structural => "structural"
  | .declared _ => "declared"
  | .tested _ => "tested"
  | .checked _ => "checked"

def Compat.note : Compat → String
  | .refuted e => e
  | .structural => "no record"
  | .declared n => n
  | .tested s => s
  | .checked e => e

/-- Which side of an extension keeps working. -/
inductive Direction where
  /-- Old consumers still work with the new revision. -/
  | backward
  /-- New consumers can still read what the old revision produced. -/
  | forward
  | both
  deriving DecidableEq, Repr

inductive ChangeKind where
  | refine
  | extend (dir : Direction)
  | breaking
  | deprecate
  deriving DecidableEq, Repr

/-- What is known about the step from `revision - 1` to `revision`. -/
structure Revision where
  id : ContractId
  revision : Nat
  compat : Compat
  kind : Option ChangeKind := none
  migration : Option String := none
  stamp : Option String := none
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

/-- A record for the current revision whose stamp no longer matches. -/
def isStale (g : Graph) (r : Revision) : Bool :=
  match r.stamp, g.find? r.id with
  | some st, some c => r.revision == c.revision && st != c.stamp
  | _, _ => false

/-- The records for one revision that still count. -/
def live (g : Graph) (id : ContractId) (rev : Nat) : List Revision :=
  g.history.filter (fun r => r.id == id && r.revision == rev && !g.isStale r)

/-- What is known about the step to `rev`: a refutation wins, otherwise the
strongest evidence. The kind is the first one recorded. -/
def step (g : Graph) (id : ContractId) (rev : Nat) : Option ChangeKind × Compat :=
  let rs := g.live id rev
  let compat := match rs.find? (fun r => r.compat.rank == 0) with
    | some r => r.compat
    | none => rs.foldl (fun best r => if r.compat.rank > best.rank then r.compat else best)
        Compat.structural
  ((rs.filterMap (·.kind)).head?, compat)

/-- Every step from `fromRev` to `toRev`. -/
def stepsBetween (g : Graph) (id : ContractId) (fromRev toRev : Nat) :
    List (Option ChangeKind × Compat) :=
  (List.range (toRev - fromRev)).map (fun k => g.step id (fromRev + k + 1))

/-- Stale records (`TR0205`) and revisions whose records disagree (`TR0204`). -/
def revisionIssues (g : Graph) : List Issue :=
  let stale : List Issue := (g.history.filter g.isStale).map (fun r =>
    let now := ((g.find? r.id).map (·.stamp)).getD ""
    { code := "TR0205",
      message := s!"the {r.compat.level} record for {r.id}@{r.revision} was made at stamp {r.stamp.getD ""}, but the definition is now at stamp {now}; it is ignored" })
  let keys := (g.history.map (fun r => (r.id, r.revision))).eraseDups
  let conflicts : List Issue := keys.filterMap (fun k =>
    let rs := g.live k.1 k.2
    let refuted := rs.filterMap (fun r => match r.compat with | .refuted e => some e | _ => none)
    let claims := rs.filter (fun r => r.compat.rank ≥ 2)
    if !refuted.isEmpty && !claims.isEmpty then
      let said := ", ".intercalate (claims.map (fun r => s!"{r.compat.level} ({r.compat.note})"))
      some { code := "TR0204",
             message := s!"{k.1}@{k.2}: {said} says compatible, but {"; ".intercalate refuted}; the refutation wins" }
    else none)
  stale ++ conflicts

end Graph

end Tribrach
