import Tribrach.Wire
import Parking.Meters

/-!
# Wire codecs for the three contracts

Each message is described once: field name, codec and getter side by side.
The JSON Schemas in `exported/schemas/` and the Lean decoders both come from
these descriptions, and so will the Go and Swift DTOs.

The wire mapping lives here, not in the model: money is a decimal string,
times are RFC 3339 instants, and absent optional fields are left out.
-/

namespace Parking.Codecs

open Lean Tribrach.Schema Tribrach.Wire Payments Meters

/-! ## payments.authorize -/

def amount : Codec Nat :=
  (Codec.decimal (min := some 1) (max := some (maxAmount : Int))).map Int.toNat (fun n => (n : Int))
    |>.doc "Minor units (cents), as a decimal string."

def AuthorizeRequest.codec : Codec AuthorizeRequest :=
  Obj.build AuthorizeRequest.mk
    |>.field "amount" amount (·.amount)
    |>.field "currency" (Codec.enum (currencies.map fun c => (c, c))) (·.currency)
    |>.field "token" (Codec.str (minLen := some 1) (maxLen := some 64)) (·.token)
    |>.codec

def AuthorizeResponse.codec : Codec AuthorizeResponse :=
  Codec.tagged "result" [
    Obj.case "authorized"
      (Obj.build (fun (i : String) (a : Nat) => (i, a))
        |>.field "authId" (Codec.str (minLen := some 1)) (·.1)
        |>.field "amount" amount (·.2))
      (fun | .authorized i a => some (i, a) | _ => none)
      (fun (i, a) => .authorized i a),
    Obj.case "declined"
      (Obj.build id |>.field "reason" (Codec.str (minLen := some 1)) id)
      (fun | .declined w => some w | _ => none)
      .declined]

/-! ## meters.start -/

def zone : Codec String := Codec.enum (zones.map fun (z, _) => (z, z))
def plate : Codec String :=
  Codec.str (minLen := some 2) (maxLen := some 8) (pat := some .upperAlnum)
def minutes : Codec Nat :=
  Codec.nat (min := some 15) (max := some 240) (multipleOf := some 15)
    |>.doc "Session length: 15 to 240 minutes, in steps of 15."
def sessionId : Codec String := Codec.str (minLen := some 1) (maxLen := some 64)
def reason : Codec String := Codec.str (minLen := some 1)

def StartRequest.codec : Codec StartRequest :=
  Obj.build StartRequest.mk
    |>.field "zone" zone (·.zone)
    |>.field "plate" plate (·.plate)
    |>.field "minutes" minutes (·.minutes)
    |>.codec

private def startedCase {α} (proj : α → Option (String × Int × Int × Nat))
    (inj : String × Int × Int × Nat → α) : Case α :=
  Obj.case "started"
    (Obj.build (fun (s : String) (a b : Int) (c : Nat) => (s, a, b, c))
      |>.field "sessionId" sessionId (·.1)
      |>.field "startsAt" Codec.instant (·.2.1)
      |>.field "expiresAt" Codec.instant (·.2.2.1)
      |>.field "charged" amount (·.2.2.2))
    proj inj

def StartResponse.codec : Codec StartResponse :=
  Codec.tagged "result" [
    startedCase (fun | .started s a b c => some (s, a, b, c) | _ => none)
      (fun (s, a, b, c) => .started s a b c),
    Obj.case "rejected" (Obj.build id |>.field "reason" reason id)
      (fun | .rejected w => some w | _ => none) .rejected]

def StartRequestV2.codec : Codec StartRequestV2 :=
  Obj.build StartRequestV2.mk
    |>.field "zone" zone (·.zone)
    |>.field "plate" plate (·.plate)
    |>.field "minutes" minutes (·.minutes)
    |>.optional "evCharging" Codec.bool (·.evCharging)
    |>.codec

def StartResponseV2.codec : Codec StartResponseV2 :=
  Codec.tagged "result" [
    startedCase (fun | .started s a b c => some (s, a, b, c) | _ => none)
      (fun (s, a, b, c) => .started s a b c),
    Obj.case "queued"
      (Obj.build (fun (s : String) (n : Nat) => (s, n))
        |>.field "sessionId" sessionId (·.1)
        |>.field "position" (Codec.nat (min := some 1)) (·.2))
      (fun | .queued s n => some (s, n) | _ => none)
      (fun (s, n) => .queued s n),
    Obj.case "rejected" (Obj.build id |>.field "reason" reason id)
      (fun | .rejected w => some w | _ => none) .rejected]

/-! ## A v2 client and a v1 server

A v1 server reads a v2 request exactly as `Meters.downgradeRequest?` says:
one that doesn't ask for EV charging is read with nothing lost, and one that
does is refused, because the v1 object doesn't name `evCharging`. Together
with `Meters.v2_serves_v1`, the v1 server then answers as v2 would
(`ReadsOrRefuses.answers`). -/

theorem v1_reads_or_refuses :
    Tribrach.ReadsOrRefuses requestVersion StartRequest.codec.dec StartRequestV2.codec.dec
      StartRequestV2.codec.enc := by
  intro ⟨z, p, m, ev⟩
  show StartRequest.codec.dec _ = (StartRequestV2.codec.dec _).bind downgradeRequest?
  cases ev with
  | some b =>
    have hk : (StartRequestV2.codec.enc ⟨z, p, m, some b⟩).getObjVal? "evCharging" =
        .ok (Json.bool b) := rfl
    have h1 : StartRequest.codec.dec (StartRequestV2.codec.enc ⟨z, p, m, some b⟩) = none := by
      unfold StartRequest.codec
      exact Obj.codec_refuses_unknown _ hk (by decide)
    rw [h1]
    simp only [StartRequestV2.codec, Obj.codec, Obj.build, Obj.field, Obj.optional, Codec.guarded]
    split
    · simp only [Except.toOption, Option.pure_def, Option.bind_eq_bind, Option.bind_assoc,
        Option.bind_some]
      generalize (Json.mkObj _).getObjVal? "zone" = oz
      generalize (Json.mkObj _).getObjVal? "plate" = op
      generalize (Json.mkObj _).getObjVal? "minutes" = om
      have he : (Json.mkObj [("zone", zone.enc z), ("plate", plate.enc p), ("minutes", minutes.enc m),
          ("evCharging", Codec.bool.enc b)]).getObjVal? "evCharging" = .ok (Codec.bool.enc b) := rfl
      cases oz <;> cases op <;> cases om <;> simp [he] <;>
        (generalize Codec.bool.dec (Codec.bool.enc b) = ob; cases ob <;> simp [downgradeRequest?])
    · rfl
  | none =>
    simp only [StartRequest.codec, StartRequestV2.codec, Obj.codec, Obj.build, Obj.field,
      Obj.optional, Codec.guarded, Option.map_none, Option.getD_none, List.nil_append,
      List.cons_append]
    generalize zone.enc z = a, plate.enc p = b, minutes.enc m = c
    have hj : Json.mkObj [("zone", a), ("plate", b), ("minutes", c)] =
        .obj (Std.TreeMap.Raw.ofList [("zone", a), ("plate", b), ("minutes", c)]) := rfl
    rw [hj]
    generalize hJ : Std.TreeMap.Raw.ofList [("zone", a), ("plate", b), ("minutes", c)] compare = kvs
    have hz : (Json.obj kvs).getObjVal? "zone" = .ok a := by subst hJ; rfl
    have hp : (Json.obj kvs).getObjVal? "plate" = .ok b := by subst hJ; rfl
    have hm : (Json.obj kvs).getObjVal? "minutes" = .ok c := by subst hJ; rfl
    have he : (Json.obj kvs).getObjVal? "evCharging" = .error "property not found: evCharging" := by
      subst hJ; rfl
    have k1 : (kvs.all fun k _ => [("zone", zone.ty, true), ("plate", plate.ty, true),
        ("minutes", minutes.ty, true)].any fun x => x.fst == k) = true := by subst hJ; rfl
    have k2 : (kvs.all fun k _ => [("zone", zone.ty, true), ("plate", plate.ty, true),
        ("minutes", minutes.ty, true), ("evCharging", Codec.bool.ty, false)].any
          fun x => x.fst == k) = true := by subst hJ; rfl
    simp only [Ty.check, Ty.checkFields, k1, k2, hz, hp, hm, he, req, opt, Bool.true_and,
      Bool.not_false, Bool.and_true, Except.toOption, Option.bind_eq_bind]
    split
    · simp [Option.pure_def, Option.bind_assoc, downgradeRequest?]
    · rfl

/-- A v1 server reading a v2 client's request: whatever it reads, the v2
server would have read too, nothing lost, and the v1 answer is the v2 answer
as the v1 route sends it. -/
theorem v1_server_answers_v2_client (e : EnvV2) {q : StartRequestV2} {q1 : StartRequest}
    (h : StartRequest.codec.dec (StartRequestV2.codec.enc q) = some q1) :
    ∃ q2, StartRequestV2.codec.dec (StartRequestV2.codec.enc q) = some q2 ∧
      upgrade q1 = q2 ∧ downgrade (startV2 e q2) = start e.toEnv q1 :=
  v1_reads_or_refuses.answers (v2_serves_v1 e) h

end Parking.Codecs
