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

end Parking.Codecs
