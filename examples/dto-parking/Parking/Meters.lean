import Parking.Payments

/-!
# The meters service: `meters.start`, versions 1 and 2

A driver asks for a session in a zone for some minutes. Meters prices it from
the zone's rate, asks payments to authorize the charge, and only then starts
the session.

Version 2 adds an optional `evCharging` request and a `queued` answer for
when every charger is busy. A v2 server still serves v1 clients, on the v1
route, by upgrading the request and downgrading the answer;
`v2_serves_v1` proves that v1 clients see exactly what a v1 server would have
told them.
-/

namespace Parking.Meters

open Payments

/-- Rates in cents per 15 minutes. -/
def zones : List (String × Nat) := [("A1", 125), ("B2", 75), ("C3", 50)]

def rate? (zone : String) : Option Nat := zones.lookup zone

/-- Sessions are 15 to 240 minutes, in steps of 15. The wire decoder
enforces this, so the model can rely on it. -/
def validMinutes (m : Nat) : Prop := 15 ≤ m ∧ m ≤ 240 ∧ m % 15 = 0

def charge (rate minutes : Nat) : Nat := rate * (minutes / 15)

structure StartRequest where
  zone : String
  plate : String
  minutes : Nat
  deriving BEq, Repr, Inhabited

inductive StartResponse where
  | started (sessionId : String) (startsAt expiresAt : Int) (charged : Nat)
  | rejected (reason : String)
  deriving BEq, Repr, Inhabited

/-- What the server knows besides the request: the time, the id it would
give the session, the payment token on file, and how payments answers. -/
structure Env where
  now : Int
  sessionId : String
  token : String
  pay : AuthorizeRequest → AuthorizeResponse

def start (e : Env) (r : StartRequest) : StartResponse :=
  match rate? r.zone with
  | none => .rejected "unknown zone"
  | some rate =>
    let amount := charge rate r.minutes
    match e.pay ⟨amount, "CAD", e.token⟩ with
    | .authorized _ a =>
      if a = amount then .started e.sessionId e.now (e.now + 60 * r.minutes) amount
      else .rejected "payment did not match the charge"
    | .declined why => .rejected why

/-! ## What v1 promises -/

/-- Every started session was paid for: payments authorized exactly the
amount charged. -/
theorem started_is_paid {e r s a b c} (h : start e r = .started s a b c) :
    ∃ id, e.pay ⟨c, "CAD", e.token⟩ = .authorized id c := by
  unfold start at h
  split at h
  · cases h
  · dsimp only at h
    split at h
    · rename_i id amt hp
      split at h
      · rename_i heq
        cases h; subst heq; exact ⟨id, hp⟩
      · cases h
    · cases h

/-- A session runs exactly the minutes asked for, from now. -/
theorem expiry_exact {e r s a b c} (h : start e r = .started s a b c) :
    a = e.now ∧ b = a + 60 * r.minutes := by
  unfold start at h
  split at h
  · cases h
  · dsimp only at h
    split at h
    · split at h
      · cases h; exact ⟨rfl, rfl⟩
      · cases h
    · cases h

theorem rate_bounds {z rate} (h : rate? z = some rate) : 50 ≤ rate ∧ rate ≤ 125 := by
  unfold rate? zones at h
  simp [List.lookup] at h
  split at h <;> (try split at h) <;> (try split at h) <;> simp_all <;> omega

/-- The dearest session fits under payments' limit. This is where meters
relies on payments: lower `Payments.maxAmount` below 2,000 and this proof,
and the build, fail. -/
theorem charge_within_limit {z rate m} (hz : rate? z = some rate) (hm : validMinutes m) :
    1 ≤ charge rate m ∧ charge rate m ≤ maxAmount := by
  have ⟨lo, hi⟩ := rate_bounds hz
  unfold validMinutes at hm
  unfold charge maxAmount
  have h1 : 1 ≤ m / 15 := by omega
  have h2 : m / 15 ≤ 16 := by omega
  constructor
  · exact Nat.le_trans h1 (Nat.le_mul_of_pos_left _ (by omega))
  · calc rate * (m / 15) ≤ 125 * 16 := Nat.mul_le_mul hi h2
      _ ≤ 20000 := by decide

/-- Composed with the real payments service: a valid request in a known zone
starts a session whenever the card approves. -/
theorem start_succeeds {now sid token id r rate} (hz : rate? r.zone = some rate)
    (hm : validMinutes r.minutes) :
    start ⟨now, sid, token, authorize true id⟩ r =
      .started sid now (now + 60 * r.minutes) (charge rate r.minutes) := by
  have ⟨h1, h2⟩ := charge_within_limit hz hm
  have hc : currencies.contains "CAD" = true := by decide
  unfold start
  simp only [hz]
  rw [authorize_accepts (r := ⟨charge rate r.minutes, "CAD", token⟩) h1 h2 hc]
  simp

/-! ## Version 2 -/

structure StartRequestV2 where
  zone : String
  plate : String
  minutes : Nat
  evCharging : Option Bool
  deriving BEq, Repr, Inhabited

inductive StartResponseV2 where
  | started (sessionId : String) (startsAt expiresAt : Int) (charged : Nat)
  | queued (sessionId : String) (position : Nat)
  | rejected (reason : String)
  deriving BEq, Repr, Inhabited

structure EnvV2 extends Env where
  chargersFree : Nat

def startV2 (e : EnvV2) (r : StartRequestV2) : StartResponseV2 :=
  if r.evCharging = some true ∧ e.chargersFree = 0 then .queued e.sessionId 1
  else
    match start e.toEnv ⟨r.zone, r.plate, r.minutes⟩ with
    | .started s a b c => .started s a b c
    | .rejected why => .rejected why

/-- A v1 request as v2 reads it: no EV charging asked. -/
def upgrade (r : StartRequest) : StartRequestV2 := ⟨r.zone, r.plate, r.minutes, none⟩

/-- A v2 answer as the v1 route sends it. `queued` has no v1 form; it can't
happen for a v1 request, and is sent as a rejection if it ever does. -/
def downgrade : StartResponseV2 → StartResponse
  | .started s a b c => .started s a b c
  | .queued _ _ => .rejected "waiting for a free charger"
  | .rejected why => .rejected why

/-- A v2 request a v1 server can read without losing anything: one that
doesn't ask for EV charging. -/
def downgradeRequest? (r : StartRequestV2) : Option StartRequest :=
  if r.evCharging.isNone then some ⟨r.zone, r.plate, r.minutes⟩ else none

/-- Forward compatibility: a v2 server on the v1 route answers every v1
request exactly as a v1 server would. -/
theorem v2_serves_v1 (e : EnvV2) (r : StartRequest) :
    downgrade (startV2 e (upgrade r)) = start e.toEnv r := by
  unfold startV2 upgrade
  simp only [reduceCtorEq, false_and, ite_false]
  cases start e.toEnv r <;> rfl

/-- v1 requests never queue, so the v1 route never has to turn `queued` into
a rejection. -/
theorem v1_never_queued (e : EnvV2) (r : StartRequest) (s n) :
    startV2 e (upgrade r) ≠ .queued s n := by
  unfold startV2 upgrade
  simp only [reduceCtorEq, false_and, ite_false]
  cases start e.toEnv r <;> simp

/-- Rollback: a v1 server reads a v2 request only when doing so loses
nothing, and then answers as the v2 server would have. -/
theorem rollback_safe (e : EnvV2) (r : StartRequestV2) (r1 : StartRequest)
    (h : downgradeRequest? r = some r1) : upgrade r1 = r ∧
      downgrade (startV2 e r) = start e.toEnv r1 := by
  unfold downgradeRequest? at h
  split at h
  · rename_i hn
    cases h
    have : r.evCharging = none := by simpa using hn
    refine ⟨?_, ?_⟩
    · cases r; simp_all [upgrade]
    · have := v2_serves_v1 e ⟨r.zone, r.plate, r.minutes⟩
      cases r; simp_all [upgrade]
  · cases h

end Parking.Meters
