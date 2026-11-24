import Todo.Model

/-!
# Rule cards

A rule card restates one rule in plain English and shows it at work: a few
situations the rule allows (taken from the model) and a few it forbids (the
nearest outcome that would break it). Every example is found by search, not
written by hand, so the cards can't drift from the model.

The search covers every list with items 1 and 2 that can be reached in up to
three steps, and every action on it. That makes the cards *checked*, not
*proved*: they say "true in every case we tried".

The "Did you know?" section asks questions a reader might not have thought
of and answers them with the shortest example found, so surprising
consequences of the rules show up before users find them.
-/

namespace Todo
namespace Cards

/-- The item ids the search uses. Two is enough to show interactions. -/
def ids : List Nat := [1, 2]

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

/-- Outcomes to search for forbidden examples, including broken ones such as
duplicates. -/
def items : List Item :=
  ids.flatMap (fun i => [⟨i, false⟩, ⟨i, true⟩])

def smallStates : List (List Item) :=
  [[]] ++ items.map (fun a => [a]) ++ items.flatMap (fun a => items.map (fun b => [a, b]))

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

/-! ## Finding examples -/

def mismatches (e a : List Item) : Nat :=
  ((e.zip a).filter (fun p => !(p.1 == p.2))).length

/-- How far an outcome is from what the model does. -/
def dist (e a : List Item) : Nat :=
  (a.length - e.length) + (e.length - a.length) + mismatches e a

/-- The outcome closest to `e` among `cands`, earliest first on ties. -/
def closest (e : List Item) (cands : List (List Item)) : Option (List Item) :=
  cands.foldl (fun best c =>
    match best with
    | none => some c
    | some b => if dist e c < dist e b then some c else some b) none

abbrev Example := List Item × Op × List Item

structure Card where
  rule : Rule
  checked : Nat
  allowed : List Example
  forbidden : List Example
  /-- Situations where the model itself breaks the rule. Should be empty. -/
  broken : List (List Item × Op)

def nearMisses (r : Rule) (mine : List (List Item × Op)) : List (Example × Nat) :=
  mine.filterMap (fun c =>
    let e := step c.2 c.1
    match closest e (smallStates.filter (fun a => !(r.holds c.1 c.2 a))) with
    | some a => some ((c.1, c.2, a), dist e a)
    | none => none)

def makeCard (r : Rule) : Card :=
  let mine := cases.filter (fun c => r.applies c.1 c.2)
  let broken := mine.filter (fun c => !(r.holds c.1 c.2 (step c.2 c.1)))
  let allowed := (mine.take 3).map (fun c => (c.1, c.2, step c.2 c.1))
  let misses := nearMisses r mine
  let nearestFirst := [1, 2, 3, 4, 5].flatMap (fun d => misses.filter (fun m => m.2 == d))
  let forbidden := (nearestFirst.take 3).map (·.1)
  { rule := r, checked := mine.length, allowed, forbidden, broken }

/-! ## Did you know? -/

structure Question where
  ask : String
  found : List Op → Bool

def ticked (s : List Item) (i : Nat) : Bool := s.any (fun it => it.id == i && it.done)
def unticked (s : List Item) (i : Nat) : Bool := s.any (fun it => it.id == i && !it.done)

/-- The proper prefixes of a sequence, shortest first. -/
def prefixes (ops : List Op) : List (List Op) :=
  (List.range ops.length).map (fun k => ops.take k)

def addLeavesTicked (ops : List Op) : Bool :=
  match ops.getLast? with
  | some (.add i) => ticked (run [] ops) i
  | _ => false

def removeTouchesOthers (ops : List Op) : Bool :=
  match ops.getLast? with
  | some (.remove i) =>
    let before := run [] ops.dropLast
    before.filter (fun it => it.id != i) != run [] ops
  | _ => false

def reordered (ops : List Op) : Bool :=
  let f := (run [] ops).map (·.id)
  (prefixes ops).any (fun p =>
    let s := (run [] p).map (·.id)
    s.length == f.length && s != f && s.all (fun x => f.contains x))

def everUnticked (ops : List Op) : Bool :=
  let final := run [] ops
  ids.any (fun i => unticked final i && (prefixes ops).any (fun p => ticked (run [] p) i))

def questions : List Question := [
  { ask := "Can a ticked item end up unticked again?", found := everUnticked },
  { ask := "Can adding an item leave it already ticked?", found := addLeavesTicked },
  { ask := "Can the same items end up in a different order?", found := reordered },
  { ask := "Can removing one item change another?", found := removeTouchesOthers }
]

/-- How many actions the question search tries, from an empty list. -/
def searchDepth : Nat := 4

/-! ## The page -/

def row (ex : Example) : String :=
  s!"| {showState ex.1} | {showOp ex.2.1} | {showState ex.2.2} |"

def renderCard (n : Nat) (c : Card) : List String :=
  [s!"## {n}. {c.rule.name}", "", c.rule.plain, "",
   s!"Checked on {c.checked} situations; the model follows the rule in every one.", "",
   "**Allowed.** What the model does:", "",
   "| Before | Action | After |", "| --- | --- | --- |"] ++
  c.allowed.map row ++
  ["", "**Forbidden.** An app that did this would break the rule:", "",
   "| Before | Action | Not allowed after |", "| --- | --- | --- |"] ++
  c.forbidden.map row ++ [""]

def renderTrace (ops : List Op) : List String :=
  (List.range ops.length).map (fun k =>
    let o := ops.getD k (.add 0)
    s!"{k + 1}. {showOp o} gives {showState (run [] (ops.take (k + 1)))}")

def renderQuestion (q : Question) : List String :=
  match (seqs searchDepth).find? q.found with
  | some ops =>
    [s!"### {q.ask}", "", "**Yes.** The shortest way, starting from an empty list:", ""] ++
    renderTrace ops ++
    ["", "If this isn't what users should see, it's a rule to change, not a bug in the app.", ""]
  | none =>
    [s!"### {q.ask}", "",
     s!"**No.** Not in any sequence of up to {searchDepth} actions from an empty list.", ""]

def cards : List Card := rules.map makeCard

/-- Problems that make the cards untrustworthy: the model breaks a rule, a
rule never applies, or a rule forbids nothing (it's vacuous). -/
def problems : List String :=
  cards.flatMap (fun c =>
    (if c.broken.isEmpty then [] else [s!"the model breaks \"{c.rule.name}\" in {c.broken.length} situations"]) ++
    (if c.checked == 0 then [s!"\"{c.rule.name}\" never applies in the search"] else []) ++
    (if c.forbidden.isEmpty then [s!"\"{c.rule.name}\" forbids nothing, so it says nothing"] else []))

def render : String :=
  let header := [
    "# Rule cards: to-do example", "",
    "Generated by `lake exe cards --write RULES.md` from `Todo/Model.lean` and",
    "`Todo/Cards.lean`. Don't edit by hand: CI fails if this page is out of date.", "",
    s!"Every example below was found by search. The search tries all {reachable.length} lists",
    "with items 1 and 2 that can be reached in up to three actions, and every action",
    "on each one. \"Checked\" means true in all of those cases, not proved for every",
    "possible list.", ""]
  let body := ((List.range cards.length).zip cards).flatMap (fun p => renderCard (p.1 + 1) p.2)
  let dyk := ["## Did you know?", "",
    "Questions about the rules, answered with the shortest example the search finds.", ""] ++
    questions.flatMap renderQuestion
  "\n".intercalate (header ++ body ++ dyk)

end Cards
end Todo
