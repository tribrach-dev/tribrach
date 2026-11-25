/-!
# Logic layer: Datalog with "why" trees

A small Datalog engine. A program is a list of facts (`personal email`) and
rules (`reaches X Z :- flows X Y, reaches Y Z`). The engine derives every fact
that follows, and records for each one a *why tree*: the rule used and the
facts it was built from.

Datalog always finishes on a finite program, and once it reaches a fixpoint
its answers are complete. So "no" means "does not follow from these facts
and rules", not just "not found".

Trust model: the engine is the *suggester*. `Why.check` is a separate, much
smaller checker that re-verifies a why tree against the program without
using the engine. Every answer Tribrach reports must pass `Why.check`.
Larger external engines (Soufflé, SWI-Prolog, SAT/SMT solvers) can later
produce why trees that this same checker accepts.
-/

namespace Tribrach
namespace Logic

/-- A rule argument: a variable such as `X`, or a constant such as `email`. -/
inductive Term where
  | var (name : String)
  | const (value : String)
  deriving BEq, Repr, Inhabited

/-- A pattern such as `flows X Y`. -/
structure Atom where
  pred : String
  args : List Term
  deriving BEq, Repr, Inhabited

/-- A ground fact such as `flows email account`. -/
structure Fact where
  pred : String
  args : List String
  deriving BEq, Repr, Inhabited

/-- `head :- body₁, …, bodyₙ`. Every variable in the head must appear in the
body (checked by `Rule.safe`). -/
structure Rule where
  name : String
  head : Atom
  body : List Atom
  deriving Repr, Inhabited

/-- Why a fact holds: it was given, or a rule built it from other facts. -/
inductive Why where
  | given (f : Fact)
  | byRule (f : Fact) (rule : String) (premises : List Why)
  deriving Inhabited

def Why.fact : Why → Fact
  | .given f => f
  | .byRule f _ _ => f

/-! ## Matching -/

abbrev Subst := List (String × String)

def Subst.lookup (s : Subst) (x : String) : Option String :=
  (s.find? (fun p => p.1 == x)).map (·.2)

def matchTerm (s : Subst) : Term → String → Option Subst
  | .const c, v => if c == v then some s else none
  | .var x, v =>
    match s.lookup x with
    | some w => if w == v then some s else none
    | none => some ((x, v) :: s)

def matchArgs (s : Subst) : List Term → List String → Option Subst
  | [], [] => some s
  | t :: ts, v :: vs => (matchTerm s t v).bind (fun s' => matchArgs s' ts vs)
  | _, _ => none

def matchAtom (s : Subst) (a : Atom) (f : Fact) : Option Subst :=
  if a.pred == f.pred then matchArgs s a.args f.args else none

/-- Match atoms against facts pairwise, threading one substitution. -/
def matchAll (s : Subst) : List (Atom × Fact) → Option Subst
  | [] => some s
  | p :: rest => (matchAtom s p.1 p.2).bind (fun s' => matchAll s' rest)

/-- Fill in an atom's variables; fails if one is unbound. -/
def ground (s : Subst) (a : Atom) : Option Fact :=
  (a.args.mapM (fun t =>
    match t with
    | .const c => some c
    | .var x => s.lookup x)).map (fun args => { pred := a.pred, args })

def Term.vars : Term → List String
  | .var x => [x]
  | .const _ => []

/-- Every head variable appears in the body, so derived facts are ground. -/
def Rule.safe (r : Rule) : Bool :=
  (r.head.args.flatMap Term.vars).all (fun x =>
    r.body.any (fun a => (a.args.flatMap Term.vars).contains x))

/-! ## The checker (trusted)

Small on purpose: it only re-matches one rule per step and looks facts up. -/

/-- `f` follows from `premises` by one use of the rule called `name`. -/
def ruleStepOk (rules : List Rule) (name : String) (f : Fact) (premises : List Fact) : Bool :=
  match rules.find? (fun r => r.name == name) with
  | none => false
  | some r =>
    r.safe && r.body.length == premises.length &&
      match matchAll [] (r.body.zip premises) with
      | some s => ground s r.head == some f
      | none => false

mutual
/-- Re-verify a why tree against the program, without the engine. -/
def Why.check (facts : List Fact) (rules : List Rule) : Why → Bool
  | .given f => facts.contains f
  | .byRule f name ps =>
    ruleStepOk rules name f (Why.factsOf ps) && Why.checkAll facts rules ps

def Why.checkAll (facts : List Fact) (rules : List Rule) : List Why → Bool
  | [] => true
  | w :: ws => Why.check facts rules w && Why.checkAll facts rules ws

def Why.factsOf : List Why → List Fact
  | [] => []
  | w :: ws => w.fact :: Why.factsOf ws
end

/-! ## The engine (untrusted)

Bottom-up evaluation in rounds. A fact gets the why tree from the first round
that derives it, so trees are as shallow as the rules allow. -/

abbrev Db := List (Fact × Why)

/-- All ways to satisfy a rule body from known facts. -/
def solve (known : Db) : List Atom → Subst → List (Subst × List Why)
  | [], s => [(s, [])]
  | a :: rest, s =>
    known.flatMap (fun p =>
      match matchAtom s a p.1 with
      | some s' => (solve known rest s').map (fun q => (q.1, p.2 :: q.2))
      | none => [])

def addNew (db : Db) (f : Fact) (w : Why) : Db :=
  if db.any (fun p => p.1 == f) then db else db ++ [(f, w)]

/-- One round: apply every rule to the facts known at the start of the round. -/
def round (rules : List Rule) (known : Db) : Db :=
  rules.foldl (fun acc r =>
    (solve known r.body []).foldl (fun acc2 q =>
      match ground q.1 r.head with
      | some f => addNew acc2 f (.byRule f r.name q.2)
      | none => acc2) acc) known

/-- The result of running a program. -/
structure Result where
  db : Db
  /-- True if no new facts appeared before fuel ran out, so answers are complete. -/
  complete : Bool

def saturateFrom (rules : List Rule) : Nat → Db → Result
  | 0, db => { db, complete := false }
  | n + 1, db =>
    let next := round rules db
    if next.length == db.length then { db, complete := true }
    else saturateFrom rules n next

/-- Derive everything. `fuel` bounds the number of rounds. -/
def saturate (facts : List Fact) (rules : List Rule) (fuel : Nat := 1000) : Result :=
  saturateFrom rules fuel (facts.foldl (fun db f => addNew db f (.given f)) [])

/-- Facts matching a pattern, with the variable bindings and why tree. -/
def query (res : Result) (q : Atom) : List (Subst × Why) :=
  res.db.filterMap (fun p => (matchAtom [] q p.1).map (fun s => (s, p.2)))

/-! ## Plain English -/

/-- Sentence templates per predicate, with `$1`, `$2`, … for arguments, such
as `("flows", "$1 is sent to $2")`. -/
abbrev Templates := List (String × String)

def say (tpl : Templates) (f : Fact) : String :=
  match tpl.find? (fun p => p.1 == f.pred) with
  | some p =>
    ((List.range f.args.length).zip f.args).foldl
      (fun acc q => acc.replace s!"${q.1 + 1}" q.2) p.2
  | none => f.pred ++ " " ++ " ".intercalate f.args

/-- A why tree as a nested Markdown list. -/
partial def Why.explain (tpl : Templates) (indent : String := "") : Why → List String
  | .given f => [s!"{indent}- {say tpl f} (given)"]
  | .byRule f rule ps =>
    [s!"{indent}- {say tpl f}, by rule \"{rule}\", because:"] ++
      ps.flatMap (Why.explain tpl (indent ++ "  "))

end Logic
end Tribrach
