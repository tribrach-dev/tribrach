import Todo.Model

/-!
# Rule cards

A rule card restates one rule in plain English and shows it at work: a few
situations the rule allows (taken from the model) and, for each realistic bug
the rule catches, what the buggy app would show. Every example is found by search, not
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

/-- Up to three examples spread across the list: first, middle, last. -/
def spread {α : Type} (xs : List α) : List α :=
  if xs.length ≤ 3 then xs
  else [0, xs.length / 2, xs.length - 1].filterMap (fun k => xs[k]?)

/-- The first situation where `bug` breaks rule `r`, if any. -/
def caught (r : Rule) (mine : List (List Item × Op)) (bug : Bug) : Option (Example × String) :=
  (mine.find? (fun c => !(r.holds c.1 c.2 (bug.step c.2 c.1)))).map
    (fun c => ((c.1, c.2, bug.step c.2 c.1), bug.name))

def makeCard (r : Rule) : Card :=
  let mine := cases.filter (fun c => r.applies c.1 c.2)
  let broken := mine.filter (fun c => !(r.holds c.1 c.2 (step c.2 c.1)))
  let allowed := (spread mine).map (fun c => (c.1, c.2, step c.2 c.1))
  let forbidden := bugs.filterMap (caught r mine)
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
   s!"The search tried {bugs.length} realistic bugs against every rule."] ++
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
    (if c.forbidden.isEmpty then [s!"\"{c.rule.name}\" catches none of the known bugs"] else []))

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
  "\n".intercalate (header ++ body ++ renderBlindSpots ++ dyk)

end Cards
end Todo
