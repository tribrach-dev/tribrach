import Bench.Common

/-!
# Notification delivery (specification)

Input: one event for one user.

```json
{"hour": 23, "sent_last_hour": 1,
 "user": {"quiet_start": 22, "quiet_end": 7,
          "channels": ["push", "email"], "sms_verified": false},
 "event": {"kind": "reminder", "priority": "normal"}}
```

`hour` is the user's local hour (0-23). Quiet hours run from `quiet_start`
up to (not including) `quiet_end` and may cross midnight; equal values mean
no quiet hours. `sent_last_hour` counts notifications already sent to the
user in the past hour. `kind` is `security`, `reminder` or `social`;
`priority` is `low`, `normal` or `urgent`.

Decision: `deliver C` for each channel C the event goes out on.
-/

namespace Bench.Notify

open Tribrach.Logic
open Lean (Json)

/-- At or above this many notifications in the past hour, hold back
non-urgent ones. -/
def rateLimit : Int := 3

/-- Is `h` inside the quiet window `[start, stop)`, which may cross midnight? -/
def inQuiet (start stop h : Int) : Bool :=
  if start == stop then false
  else if start < stop then start ≤ h && h < stop
  else h ≥ start || h < stop

def encode (j : Json) : Except String (List Fact) := do
  let hour ← getInt j "hour"
  let sent ← getInt j "sent_last_hour"
  let u ← j.getObjVal? "user"
  let qs ← getInt u "quiet_start"
  let qe ← getInt u "quiet_end"
  let chans ← getArr u "channels"
  let chs ← chans.toList.mapM (fun c => c.getStr?)
  let verified ← getBool u "sms_verified"
  let e ← j.getObjVal? "event"
  let kind ← getStr e "kind"
  let prio ← getStr e "priority"
  return [fact "hour" [toString hour], fact "quiet_hours" [toString qs, toString qe],
          fact "sent" [toString sent], fact "kind" [kind], fact "priority" [prio]] ++
    chs.map (fun c => fact "channel" [c]) ++
    when verified (fact "sms_verified") ++
    when (inQuiet qs qe hour) (fact "quiet") ++
    when (sent ≥ rateLimit) (fact "rate_limited")

def rules : List Rule := [
  { name := "security is urgent"
    head := atom "urgent", body := [atom "kind" [c "security"]] },
  { name := "urgent priority"
    head := atom "urgent", body := [atom "priority" [c "urgent"]] },
  { name := "push"
    head := atom "deliver" [c "push"], body := [atom "channel" [c "push"]]
    neg := [atom "quiet", atom "rate_limited"] },
  { name := "urgent push"
    head := atom "deliver" [c "push"], body := [atom "channel" [c "push"], atom "urgent"] },
  { name := "email"
    head := atom "deliver" [c "email"], body := [atom "channel" [c "email"]]
    neg := [atom "rate_limited"] },
  { name := "urgent sms"
    head := atom "deliver" [c "sms"]
    body := [atom "channel" [c "sms"], atom "sms_verified", atom "urgent"] }
]

def templates : Templates := [
  ("hour", "the user's local hour is $1"),
  ("quiet_hours", "quiet hours run from $1 to $2"),
  ("sent", "$1 notifications were sent in the past hour"),
  ("kind", "the event is a $1 event"),
  ("priority", "the event's priority is $1"),
  ("channel", "the user has $1 turned on"),
  ("sms_verified", "the user's phone number is verified"),
  ("quiet", "it is quiet hours for the user"),
  ("rate_limited", "3 or more notifications went out in the past hour"),
  ("urgent", "the event is urgent"),
  ("deliver", "deliver by $1")
]

def model : BenchModel :=
  { name := "notify", encode, rules, templates, decisions := ["deliver"] }

end Bench.Notify
