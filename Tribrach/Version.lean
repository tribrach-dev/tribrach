import Tribrach.Contract
import Tribrach.Export

/-!
# Versions: one change, both directions, with proofs

A `Version Old New` says how values of one revision of a type become values
of the next, and how they go back. It is the same object whether the values
are messages on the wire or rows in a store:

* `upgrade` reads an old value as the new revision reads it;
* `downgrade?` gives the old form of a new value, or `none` when the old
  revision can't hold it (it is refused, never misread);
* `forward`: every old value comes back unchanged after an upgrade, so
  rolling back to the old revision loses nothing it wrote;
* `backRead`: whatever downgrades, upgrades back to itself, so a value read
  by the old revision and one read by the new never disagree.

`downgrade?` is required. A change with no way back says so explicitly with
`OneWay` (`Version.oneWay` is the only thing that drops a `Version` to one),
and is recorded as such in the contract history.

`Version.comp` chains revisions, carrying the proofs, so v1 to v3 needs no
new proof. `Serves` states that a service at the new revision answers
clients of the old one as the old service would, and `Serves.rollback`
derives from it that rolling the service back is safe for every request the
old revision can read. `ReadsOrRefuses` covers the other direction, a new
client and an old server: the old reader takes a new message without losing
anything, or refuses it.

`Revision.ofVersion` and `Revision.ofOneWay` write the contract history
record from the object itself, so the kind and the evidence come from Lean
rather than from a hand-written note:

| Object | Kind | Evidence |
| --- | --- | --- |
| `Version` | `extend both` | `checked`, naming the version |
| `OneWay` | `extend forward` | `checked`, naming the upgrade |
-/

namespace Tribrach

/-- One revision of a type to the next, with the way back. -/
structure Version (Old New : Type) where
  upgrade : Old → New
  downgrade? : New → Option Old
  /-- Every old value comes back unchanged. -/
  forward : ∀ o, downgrade? (upgrade o) = some o
  /-- What downgrades, upgrades back to itself. -/
  backRead : ∀ n o, downgrade? n = some o → upgrade o = n

/-- A change with no way back: only an upgrade. -/
structure OneWay (Old New : Type) where
  upgrade : Old → New

namespace Version

/-- A version that changes nothing. -/
def id (α : Type) : Version α α where
  upgrade a := a
  downgrade? a := some a
  forward _ := rfl
  backRead _ _ h := by cases h; rfl

/-- `v` then `w`. -/
def comp (v : Version α β) (w : Version β γ) : Version α γ where
  upgrade a := w.upgrade (v.upgrade a)
  downgrade? c := (w.downgrade? c).bind v.downgrade?
  forward a := by simp [w.forward, v.forward]
  backRead c a h := by
    cases hb : w.downgrade? c with
    | none => simp [hb] at h
    | some b =>
      simp only [hb, Option.bind_some] at h
      rw [v.backRead b a h, w.backRead c b hb]

/-- Explicitly give up the way back. -/
def oneWay (v : Version α β) : OneWay α β := ⟨v.upgrade⟩

/-- `upgrade` never merges two old values. -/
theorem upgrade_injective (v : Version α β) {a b : α} (h : v.upgrade a = v.upgrade b) : a = b := by
  have ha := v.forward a
  rw [h, v.forward b] at ha
  exact (Option.some.inj ha).symm

/-- A value the old revision can hold is exactly an upgraded old value. -/
theorem downgrade_some_iff (v : Version α β) (n : β) (o : α) :
    v.downgrade? n = some o ↔ v.upgrade o = n := by
  constructor
  · exact v.backRead n o
  · intro h; rw [← h]; exact v.forward o

end Version

namespace OneWay

def comp (v : OneWay α β) (w : OneWay β γ) : OneWay α γ := ⟨fun a => w.upgrade (v.upgrade a)⟩

end OneWay

/-- A service at the new revision (`h2`) answers every request of the old
revision the way the old service (`h1`) does, once its answer is put in the
old form (`back`, which may be lossy: an answer the old revision has no word
for becomes one it has). -/
def Serves (req : Version Q1 Q2) (back : R2 → R1) (h1 : Q1 → R1) (h2 : Q2 → R2) : Prop :=
  ∀ q, back (h2 (req.upgrade q)) = h1 q

/-- Rolling back is safe: when the old service reads a new request (it
downgrades), it answers as the new service would have, and nothing in the
request was lost. -/
theorem Serves.rollback {req : Version Q1 Q2} {back : R2 → R1} {h1 : Q1 → R1} {h2 : Q2 → R2}
    (s : Serves req back h1 h2) {q2 : Q2} {q1 : Q1} (h : req.downgrade? q2 = some q1) :
    req.upgrade q1 = q2 ∧ back (h2 q2) = h1 q1 := by
  have hu := req.backRead q2 q1 h
  refine ⟨hu, ?_⟩
  rw [← hu]
  exact s q1

/-- Serving composes: v1 clients of a v3 service, through v2. -/
theorem Serves.comp {v : Version Q1 Q2} {w : Version Q2 Q3} {b2 : R2 → R1} {b3 : R3 → R2}
    {h1 : Q1 → R1} {h2 : Q2 → R2} {h3 : Q3 → R3}
    (s12 : Serves v b2 h1 h2) (s23 : Serves w b3 h2 h3) :
    Serves (v.comp w) (fun r => b2 (b3 r)) h1 h3 := by
  intro q
  show b2 (b3 (h3 (w.upgrade (v.upgrade q)))) = h1 q
  rw [s23, s12]

/-- An old reader takes from a new writer's message exactly what the new
reader takes, put in the old form, and refuses the rest: a value the old
revision can't hold is refused, never misread. `write` is the new writer,
`read1` and `read2` the old and new readers. This is the other half of
`Serves`, for a new client talking to an old server during a rollout or
after a rollback. -/
def ReadsOrRefuses (req : Version Q1 Q2) (read1 : W → Option Q1) (read2 : W → Option Q2)
    (write : Q2 → W) : Prop :=
  ∀ q, read1 (write q) = (read2 (write q)).bind req.downgrade?

/-- Whatever an old server reads from a new client is what the new server
would read, nothing lost, and it answers as the new server would. -/
theorem ReadsOrRefuses.answers {req : Version Q1 Q2} {read1 : W → Option Q1}
    {read2 : W → Option Q2} {write : Q2 → W} {back : R2 → R1} {h1 : Q1 → R1} {h2 : Q2 → R2}
    (r : ReadsOrRefuses req read1 read2 write) (s : Serves req back h1 h2) {q : Q2} {q1 : Q1}
    (h : read1 (write q) = some q1) :
    ∃ q2, read2 (write q) = some q2 ∧ req.upgrade q1 = q2 ∧ back (h2 q2) = h1 q1 := by
  rw [r q] at h
  cases h2r : read2 (write q) with
  | none => simp [h2r] at h
  | some q2 =>
    simp only [h2r, Option.bind_some] at h
    exact ⟨q2, rfl, s.rollback h⟩

/-- A request the old revision can't hold is refused by the old reader. -/
theorem ReadsOrRefuses.refuses {req : Version Q1 Q2} {read1 : W → Option Q1}
    {read2 : W → Option Q2} {write : Q2 → W} (r : ReadsOrRefuses req read1 read2 write)
    {q q2 : Q2} (h : read2 (write q) = some q2) (hn : req.downgrade? q2 = none) :
    read1 (write q) = none := by
  rw [r q, h, Option.bind_some, hn]

/-- The history record for a revision whose change is the `Version` `ref`
names: an extension both ways, checked by the version's proofs. -/
def Revision.ofVersion (id : ContractId) (revision : Nat) (ref : Export.LeanRef)
    (_ : Version Old New) (stamp : Option String := none) : Revision where
  id := id
  revision := revision
  compat := .checked s!"{ref.name}: a Tribrach.Version (forward and backRead proved)"
  kind := some (.extend .both)
  migration := some ref.name
  stamp := stamp

/-- The history record for a change with no way back: new readers read old
values through the upgrade, and old readers can't read new values. -/
def Revision.ofOneWay (id : ContractId) (revision : Nat) (ref : Export.LeanRef)
    (_ : OneWay Old New) (stamp : Option String := none) : Revision where
  id := id
  revision := revision
  compat := .checked s!"{ref.name}: a one-way upgrade (no downgrade)"
  kind := some (.extend .forward)
  migration := some ref.name
  stamp := stamp

end Tribrach
