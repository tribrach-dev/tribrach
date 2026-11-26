import Todo.Model

/-!
# Rule cards

A rule card restates one rule in plain English and shows it at work: a few
situations the rule allows (taken from the model) and, for each realistic bug
the rule catches, what the buggy app would show. Every example is found by search, not
written by hand, so the cards can't drift from the model.

The search covers every list with items 1, 2 and 3 that can be reached in up
to three steps, and every action on it. That makes the cards *checked*, not
*proved*: they say "true in every case we tried".

The "Did you know?" section asks questions a reader might not have thought
of and answers them with the shortest example found, so surprising
consequences of the rules show up before users find them.
-/

namespace Todo
namespace Cards

/-- The item ids the search uses. Three, so that removing one item still
leaves two whose order can be seen. -/
def ids : List Nat := [1, 2, 3]

def allOps : List Op :=
  ids.flatMap (fun i => [Op.add i, Op.complete i, Op.remove i])

/-- Every sequence of at most `n` actions, shortest first. -/
def seqs : Nat → List (List Op)
  | 0 => [[]]
  | n + 1 =>
    let shorter := seqs n
    shorter ++ (shorter.filter (fun s => s.length == n)).flatMap
      (fun s => allOps.map (fun o => s ++ [o]))

/-- Every list reachable from an empty list in up to three actions. -/
def reachable : List (List Item) :=
  ((seqs 3).map (fun ops => run [] ops)).eraseDups

/-- Every situation the cards are checked on: a list and an action. -/
def cases : List (List Item × Op) :=
  reachable.flatMap (fun b => allOps.map (fun o => (b, o)))

/-! ## Plain-English rendering -/

def showItem (it : Item) : String :=
  (if it.done then "[x] " else "[ ] ") ++ toString it.id

def showState (s : List Item) : String :=
  if s.isEmpty then "(empty list)" else "`" ++ ", ".intercalate (s.map showItem) ++ "`"

def showOp : Op → String
  | .add i => s!"`add {i}`"
  | .complete i => s!"`tick {i}`"
  | .remove i => s!"`remove {i}`"

/-! ## Rules -/

structure Rule where
  name : String
  plain : String
  /-- Which situations the rule talks about. -/
  applies : List Item → Op → Bool
  /-- Whether an outcome follows the rule. -/
  holds : List Item → Op → List Item → Bool

def hasId (s : List Item) (i : Nat) : Bool := s.any (fun it => it.id == i)

def isAddOf (present : Bool) (b : List Item) : Op → Bool
  | .add i => hasId b i == present
  | _ => false

def isTickOf (present : Bool) (b : List Item) : Op → Bool
  | .complete i => hasId b i == present
  | _ => false

def isRemove : Op → Bool
  | .remove _ => true
  | _ => false

def addsAtEnd (b : List Item) : Op → List Item → Bool
  | .add i, a => a == b ++ [⟨i, false⟩]
  | _, _ => true

def ticksOnly (b : List Item) : Op → List Item → Bool
  | .complete i, a =>
    a.map (·.id) == b.map (·.id) &&
      (a.zip b).all (fun p => if p.1.id == i then p.1.done else p.1.done == p.2.done)
  | _, _ => true

def removesOnly (b : List Item) : Op → List Item → Bool
  | .remove i, a => a.all (fun it => it.id != i) && a == b.filter (fun it => it.id != i)
  | _, _ => true

def rules : List Rule := [
  { name := "One entry per item"
    plain := "Every item appears on the list at most once."
    applies := fun _ _ => true
    holds := fun _ _ a => uniqueIds a },
  { name := "Adding something already there"
    plain := "Adding an item that is already on the list changes nothing."
    applies := fun b o => isAddOf true b o
    holds := fun b _ a => a == b },
  { name := "Adding something new"
    plain := "Adding a new item puts it at the end of the list, unticked."
    applies := fun b o => isAddOf false b o
    holds := fun b o a => addsAtEnd b o a },
  { name := "Ticking"
    plain := "Ticking an item ticks it and leaves every other item, and the order, as it was."
    applies := fun b o => isTickOf true b o
    holds := fun b o a => ticksOnly b o a },
  { name := "Ticking something that isn't there"
    plain := "Ticking an item that isn't on the list changes nothing."
    applies := fun b o => isTickOf false b o
    holds := fun b _ a => a == b },
  { name := "Removing"
    plain := "Removing an item takes it off the list and leaves everything else as it was."
    applies := fun _ o => isRemove o
    holds := fun b o a => removesOnly b o a }
]

/-! ## Realistic bugs

Forbidden examples come from bugs an app could plausibly have. Each bug is a
small change to the model. A rule earns its place by catching at least one,
and a bug no rule catches is a blind spot worth knowing about.
-/

structure Bug where
  name : String
  step : Op → List Item → List Item

def bugAddDuplicate : Op → List Item → List Item
  | .add i, s => s ++ [⟨i, false⟩]
  | o, s => step o s

def bugReaddUnticks : Op → List Item → List Item
  | .add i, s => if hasId s i then s.map (fun it => if it.id == i then { it with done := false } else it) else step (.add i) s
  | o, s => step o s

def bugAddAtTop : Op → List Item → List Item
  | .add i, s => if hasId s i then s else ⟨i, false⟩ :: s
  | o, s => step o s

def bugTickToggles : Op → List Item → List Item
  | .complete i, s => s.map (fun it => if it.id == i then { it with done := !it.done } else it)
  | o, s => step o s

def bugTickUnticksOthers : Op → List Item → List Item
  | .complete i, s => s.map (fun it => { it with done := it.id == i })
  | o, s => step o s

def bugTickMissingAdds : Op → List Item → List Item
  | .complete i, s => if hasId s i then step (.complete i) s else s ++ [⟨i, true⟩]
  | o, s => step o s

def bugRemoveUnticksOthers : Op → List Item → List Item
  | .remove i, s => (step (.remove i) s).map (fun it => { it with done := false })
  | o, s => step o s

def bugRemoveLastIgnored : Op → List Item → List Item
  | .remove i, s => if s.length == 1 then s else step (.remove i) s
  | o, s => step o s

def bugRemoveReverses : Op → List Item → List Item
  | .remove i, s => (step (.remove i) s).reverse
  | o, s => step o s

def bugs : List Bug := [
  { name := "adding an item that's already there adds a second copy", step := bugAddDuplicate },
  { name := "adding an item that's already there unticks it", step := bugReaddUnticks },
  { name := "new items go at the top", step := bugAddAtTop },
  { name := "ticking a ticked item unticks it", step := bugTickToggles },
  { name := "ticking one item unticks the others", step := bugTickUnticksOthers },
  { name := "ticking a missing item adds it, ticked", step := bugTickMissingAdds },
  { name := "removing an item unticks the others", step := bugRemoveUnticksOthers },
  { name := "the last item can't be removed", step := bugRemoveLastIgnored },
  { name := "removing an item reverses the rest", step := bugRemoveReverses }
]

/-! ## Finding examples -/

abbrev Example := List Item × Op × List Item

structure Card where
  rule : Rule
  checked : Nat
  allowed : List Example
  /-- An example per bug the rule catches: what the buggy app would show. -/
  forbidden : List (Example × String)
  /-- Situations where the model itself breaks the rule. Should be empty. -/
  broken : List (List Item × Op)
  /-- An applicable situation and an outcome the rule rejects, built
  independently of the bug list. -/
  rejects : Option Example

/-- Up to three examples spread across the list: first, middle, last. -/
def spread {α : Type} (xs : List α) : List α :=
  if xs.length ≤ 3 then xs
  else [0, xs.length / 2, xs.length - 1].filterMap (fun k => xs[k]?)

/-- The first situation where `bug` breaks rule `r`, if any. -/
def caught (r : Rule) (mine : List (List Item × Op)) (bug : Bug) : Option (Example × String) :=
  (mine.find? (fun c => !(r.holds c.1 c.2 (bug.step c.2 c.1)))).map
    (fun c => ((c.1, c.2, bug.step c.2 c.1), bug.name))

/-- Every list of up to three entries with ids 1 to 3, including broken ones
such as duplicates: the outcomes tried when asking "can this rule say no?". -/
def outcomeDomain : List (List Item) :=
  let its := ids.flatMap (fun i => [(⟨i, false⟩ : Item), ⟨i, true⟩])
  let ext := fun (ls : List (List Item)) => ls.flatMap (fun l => its.map (fun it => l ++ [it]))
  let l1 := ext [[]]
  let l2 := ext l1
  [[]] ++ l1 ++ l2 ++ ext l2

/-- The first applicable situation with an outcome the rule rejects. -/
def rejectWitness (r : Rule) (mine : List (List Item × Op)) : Option Example :=
  mine.findSome? (fun c =>
    (outcomeDomain.find? (fun a => !(r.holds c.1 c.2 a))).map (fun a => (c.1, c.2, a)))

def makeCard (r : Rule) : Card :=
  let mine := cases.filter (fun c => r.applies c.1 c.2)
  let broken := mine.filter (fun c => !(r.holds c.1 c.2 (step c.2 c.1)))
  let allowed := (spread mine).map (fun c => (c.1, c.2, step c.2 c.1))
  let forbidden := bugs.filterMap (caught r mine)
  { rule := r, checked := mine.length, allowed, forbidden, broken,
    rejects := rejectWitness r mine }

/-! ## Findings

Four questions about each rule, reported separately:

- **Model violation:** the model itself breaks the rule somewhere in scope.
- **Never applies:** no situation in scope matches the rule's precondition.
- **Never rejects:** the rule accepts every outcome in `outcomeDomain`, in
  every situation it applies to. This is exhaustive over a stated finite
  domain, so it is the only finding that calls a rule vacuous, and only
  within that domain.
- **No known bug caught:** none of the bugs in `bugs` breaks the rule. That
  is a fact about the bug list, not the rule, so it is reported as coverage
  and doesn't fail the build.
-/

inductive FindingKind where
  | modelViolation
  | neverApplies
  | neverRejects
  | noBugCaught
  deriving BEq, Repr

def FindingKind.name : FindingKind → String
  | .modelViolation => "model violation"
  | .neverApplies => "never applies"
  | .neverRejects => "never rejects"
  | .noBugCaught => "no known bug caught"

/-- Whether a finding fails the build. Coverage findings don't. -/
def FindingKind.blocking : FindingKind → Bool
  | .noBugCaught => false
  | _ => true

structure Finding where
  kind : FindingKind
  rule : String
  detail : String

def findingsFor (r : Rule) : List Finding :=
  let mine := cases.filter (fun c => r.applies c.1 c.2)
  let broken := mine.filter (fun c => !(r.holds c.1 c.2 (step c.2 c.1)))
  let violations : List Finding :=
    if broken.isEmpty then []
    else [{ kind := .modelViolation, rule := r.name,
            detail := s!"the model breaks it in {broken.length} situations" }]
  let vacuity : List Finding :=
    if mine.isEmpty then
      [{ kind := .neverApplies, rule := r.name,
         detail := s!"none of the {cases.length} situations in scope matches it" }]
    else
      match rejectWitness r mine with
      | some _ => []
      | none =>
        [{ kind := .neverRejects, rule := r.name,
           detail := s!"it accepts all {outcomeDomain.length} outcomes in each of the {mine.length} situations it applies to" }]
  let coverage : List Finding :=
    if (bugs.filterMap (caught r mine)).isEmpty then
      [{ kind := .noBugCaught, rule := r.name,
         detail := s!"none of the {bugs.length} known bugs breaks it" }]
    else []
  violations ++ vacuity ++ coverage

/-! ### Fixtures

Rules that exist only to check the findings above. They are not shown on the
page. -/

/-- Rejects a transition (removing must not add a ticked item), but no known
bug does that, so it should report coverage only. -/
def fixtureNoBugCaught : Rule :=
  { name := "fixture: removing never adds a ticked item"
    plain := "Removing an item never adds a ticked item."
    applies := fun _ o => isRemove o
    holds := fun b _ a => a.all (fun it => !it.done || b.contains it) }

/-- Its precondition (a list of four items) can't be reached with three
actions, so it should never apply. -/
def fixtureUnreachable : Rule :=
  { name := "fixture: ticking on a list of four items"
    plain := "Ticking on a list of four items ticks only that item."
    applies := fun b o => b.length == 4 && isTickOf true b o
    holds := fun b o a => ticksOnly b o a }

/-- Accepts everything, so it should never reject. -/
def fixtureAcceptsAll : Rule :=
  { name := "fixture: removing allows anything"
    plain := "Removing an item may produce any list."
    applies := fun _ o => isRemove o
    holds := fun _ _ _ => true }

def fixtures : List (Rule × List FindingKind) := [
  (fixtureNoBugCaught, [.noBugCaught]),
  (fixtureUnreachable, [.neverApplies, .noBugCaught]),
  (fixtureAcceptsAll, [.neverRejects, .noBugCaught])
]

def fixtureFailures : List String :=
  fixtures.filterMap (fun p =>
    let got := (findingsFor p.1).map (·.kind)
    if got == p.2 then none
    else some s!"{p.1.name}: expected {p.2.map FindingKind.name}, got {got.map FindingKind.name}")

/-! ## Did you know?

Questions are answered by a *tabled* breadth-first search. Instead of trying
every sequence of actions, it walks the distinct situations a sequence can
lead to, and never visits the same situation twice. A situation is the list
plus a small memo of what the question needs to remember (for example, which
items have ever been ticked).

- Level by level, so the first example found is a shortest one.
- If every reachable situation has been visited without reaching the goal,
  the answer is a complete "no", for sequences of any length, not just short
  ones.
-/

/-- What a question remembers about the past, kept in a canonical order so
equal memories compare equal. -/
abbrev Memo := List (List Nat)

def ticked (s : List Item) (i : Nat) : Bool := s.any (fun it => it.id == i && it.done)
def unticked (s : List Item) (i : Nat) : Bool := s.any (fun it => it.id == i && !it.done)

def memoKey (l : List Nat) : Nat := l.foldl (fun acc n => acc * 100 + n) 0

/-- Add an entry to a memo, keeping it sorted and free of duplicates. -/
def remember (m : Memo) (x : List Nat) : Memo :=
  if m.contains x then m else (x :: m).mergeSort (fun p q => decide (memoKey p ≤ memoKey q))

structure Question where
  ask : String
  /-- Update the memo after one action: memo, list before, action, list after. -/
  track : Memo → List Item → Op → List Item → Memo
  /-- Whether the goal is reached, given the memo and the current list. -/
  goal : Memo → List Item → Bool

/-- Remember every item that has ever been ticked. -/
def trackTicked (m : Memo) (_ : List Item) (_ : Op) (after : List Item) : Memo :=
  (after.filter (·.done)).foldl (fun acc it => remember acc [it.id]) m

def goalUnticked (m : Memo) (s : List Item) : Bool :=
  m.any (fun l => l.any (fun i => unticked s i))

/-- Remember the item the last action added, if it was an add. -/
def trackLastAdd (_ : Memo) (_ : List Item) (o : Op) (_ : List Item) : Memo :=
  match o with
  | .add i => [[i]]
  | _ => []

def goalAddedTicked (m : Memo) (s : List Item) : Bool :=
  m.any (fun l => l.any (fun i => ticked s i))

/-- Pairs `[a, b]` where `a` has been seen above `b`. -/
def orderPairs (s : List Item) : List (List Nat) :=
  let idsInOrder := s.map (·.id)
  (List.range idsInOrder.length).flatMap (fun k =>
    (idsInOrder.drop (k + 1)).map (fun b => [idsInOrder.getD k 0, b]))

def trackOrder (m : Memo) (_ : List Item) (_ : Op) (after : List Item) : Memo :=
  (orderPairs after).foldl remember m

def goalSwapped (m : Memo) (s : List Item) : Bool :=
  (orderPairs s).any (fun p => m.contains p.reverse)

/-- Remember whether the last action removed one item and changed another. -/
def trackRemoveSideEffect (_ : Memo) (before : List Item) (o : Op) (after : List Item) : Memo :=
  match o with
  | .remove i => if before.filter (fun it => it.id != i) != after then [[1]] else []
  | _ => []

def goalSideEffect (m : Memo) (_ : List Item) : Bool := !m.isEmpty

def questions : List Question := [
  { ask := "Can a ticked item end up unticked again?", track := trackTicked, goal := goalUnticked },
  { ask := "Can adding an item leave it already ticked?", track := trackLastAdd, goal := goalAddedTicked },
  { ask := "Can two items swap places?", track := trackOrder, goal := goalSwapped },
  { ask := "Can removing one item change another?", track := trackRemoveSideEffect, goal := goalSideEffect }
]

abbrev Node := List Item × Memo × List Op

/-- Visit the next level, skipping situations already seen. -/
def expand (q : Question) (seen : List (List Item × Memo)) (frontier : List Node) :
    List (List Item × Memo) × List Node :=
  frontier.foldl (fun acc n =>
    allOps.foldl (fun acc2 o =>
      let after := step o n.1
      let m := q.track n.2.1 n.1 o after
      if acc2.1.contains (after, m) then acc2
      else ((after, m) :: acc2.1, acc2.2 ++ [(after, m, n.2.2 ++ [o])])) acc) (seen, [])

structure Found where
  /-- The shortest example, if one was found. -/
  ops : Option (List Op)
  /-- How many distinct situations the search visited. -/
  visited : Nat
  /-- True if every reachable situation was visited, so "no" is complete. -/
  exhausted : Bool

def searchFrom (q : Question) : Nat → List (List Item × Memo) → List Node → Found
  | 0, seen, frontier =>
    match frontier.find? (fun n => q.goal n.2.1 n.1) with
    | some n => { ops := some n.2.2, visited := seen.length, exhausted := false }
    | none => { ops := none, visited := seen.length, exhausted := frontier.isEmpty }
  | k + 1, seen, frontier =>
    match frontier.find? (fun n => q.goal n.2.1 n.1) with
    | some n => { ops := some n.2.2, visited := seen.length, exhausted := false }
    | none =>
      let r := expand q seen frontier
      if r.2.isEmpty then { ops := none, visited := r.1.length, exhausted := true }
      else searchFrom q k r.1 r.2

/-- The most actions the search will take before giving up. -/
def searchLimit : Nat := 12

def search (q : Question) : Found :=
  searchFrom q searchLimit [([], [])] [([], [], [])]

/-- How many sequences of up to `n` actions exist, for comparison. -/
def sequencesUpTo (n : Nat) : Nat :=
  (List.range (n + 1)).foldl (fun acc k => acc + allOps.length ^ k) 0

/-! ## The page -/

def row (ex : Example) : String :=
  s!"| {showState ex.1} | {showOp ex.2.1} | {showState ex.2.2} |"

def renderCard (n : Nat) (c : Card) : List String :=
  [s!"## {n}. {c.rule.name}", "", c.rule.plain, "",
   s!"Checked on {c.checked} situations; the model follows the rule in every one.", "",
   (match c.rejects with
    | some ex => s!"It can say no: {showState ex.1} then {showOp ex.2.1} must not give {showState ex.2.2}."
    | none => "It never says no to any outcome tried."),
   s!"It catches {c.forbidden.length} of the {bugs.length} known bugs.", "",
   "**Allowed.** What the model does:", "",
   "| Before | Action | After |", "| --- | --- | --- |"] ++
  c.allowed.map row ++
  ["", "**Forbidden.** Bugs this rule catches, and what the buggy app would show:", "",
   "| Bug | Before | Action | Buggy app shows |", "| --- | --- | --- | --- |"] ++
  c.forbidden.map (fun f =>
    s!"| {f.2} | {showState f.1.1} | {showOp f.1.2.1} | {showState f.1.2.2} |") ++ [""]

/-- Bugs no rule catches anywhere in the search. -/
def blindSpots : List Bug :=
  bugs.filter (fun bug => rules.all (fun r =>
    (caught r (cases.filter (fun c => r.applies c.1 c.2)) bug).isNone))

def renderBlindSpots : List String :=
  ["## Bugs these rules would miss", "",
   s!"The search tried {bugs.length} realistic bugs against every rule.", ""] ++
  (if blindSpots.isEmpty then
    ["Every one is caught by at least one rule.", ""]
  else
    ["These ones slip past every rule, so a buggy app would still pass:", ""] ++
    blindSpots.map (fun b => s!"- {b.name}") ++ [""])

def renderTrace (ops : List Op) : List String :=
  (List.range ops.length).map (fun k =>
    let o := ops.getD k (.add 0)
    s!"{k + 1}. {showOp o} gives {showState (run [] (ops.take (k + 1)))}")

def renderQuestion (q : Question) : List String :=
  let r := search q
  match r.ops with
  | some ops =>
    [s!"### {q.ask}", "", "**Yes.** The shortest way, starting from an empty list:", ""] ++
    renderTrace ops ++
    ["", s!"Found after visiting {r.visited} distinct situations; trying every sequence of up to {ops.length} actions would mean {sequencesUpTo ops.length}.",
     "", "If this isn't what users should see, it's a rule to change, not a bug in the app.", ""]
  | none =>
    if r.exhausted then
      [s!"### {q.ask}", "",
       s!"**No**, never, in any number of actions: the search visited all {r.visited} situations reachable with items 1, 2 and 3.", ""]
    else
      [s!"### {q.ask}", "",
       s!"**No** within {searchLimit} actions (the search stopped there, so this is not a complete answer).", ""]

def cards : List Card := rules.map makeCard

def findings : List Finding := rules.flatMap findingsFor

/-- What fails the build: blocking findings, and fixtures whose findings
changed. -/
def problems : List String :=
  (findings.filter (·.kind.blocking)).map (fun f => s!"{f.kind.name}: \"{f.rule}\": {f.detail}") ++
    fixtureFailures.map (fun m => s!"fixture check failed: {m}")

def renderFindings : List String :=
  ["## Findings", "",
   s!"Scope: {cases.length} situations (every list reachable in up to three actions, times",
   s!"every action) and {outcomeDomain.length} possible outcomes (every list of up to three entries",
   "with ids 1 to 3, including broken ones such as duplicates). Model violations, rules that",
   "never apply and rules that never say no fail the build. Coverage findings don't: they",
   "describe the list of known bugs, not the rule.", ""] ++
  (let cov := findings.filter (fun f => !f.kind.blocking)
   if cov.isEmpty then ["None: every rule applies, can say no, and catches at least one known bug.", ""]
   else cov.map (fun f => s!"- {f.kind.name}: \"{f.rule}\": {f.detail}") ++ [""])

def render : String :=
  let header := [
    "# Rule cards: to-do example", "",
    "Generated by `lake exe cards --write RULES.md` from `Todo/Model.lean` and",
    "`Todo/Cards.lean`. Don't edit by hand: CI fails if this page is out of date.", "",
    s!"Every example below was found by search. The search tries all {reachable.length} lists",
    "with items 1, 2 and 3 that can be reached in up to three actions, and every action",
    "on each one. \"Checked\" means true in all of those cases, not proved for every",
    "possible list.", ""]
  let body := ((List.range cards.length).zip cards).flatMap (fun p => renderCard (p.1 + 1) p.2)
  let dyk := ["## Did you know?", "",
    "Questions about the rules, answered with the shortest example a tabled search",
    "finds. The search never visits the same situation twice, so a \"no\" can cover",
    "sequences of any length.", ""] ++
    questions.flatMap renderQuestion
  "\n".intercalate (header ++ body ++ renderBlindSpots ++ renderFindings ++ dyk)

end Cards
end Todo
