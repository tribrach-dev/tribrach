import Bench.Common

/-!
# Deploy gate (specification)

Input: one change waiting to ship.

```json
{"change": {"id": "c1", "service": "payments", "author": "u1", "risk": "medium",
            "migration": false, "hotfix": false},
 "service": {"tier": 1, "error_budget_pct": 35, "canary": true},
 "checks": {"unit": "pass", "integration": "pass", "security": "pass", "perf": "skipped"},
 "approvals": [{"by": "u2", "role": "owner"}],
 "calendar": {"day": "thu", "hour": 11, "freeze": false},
 "oncall": {"acked": true}}
```

- `risk` is `low`, `medium` or `high`; `tier` is 1, 2 or 3.
- Each check is `pass`, `fail` or `skipped`.
- Approver roles are `owner`, `sre`, `security` or `peer`.

Decisions: `deploy S` (ship to everyone), `canary S` (ship to the canary
only) and `page S` (page the on-call engineer when it ships).

**Tier 0.** `tier` may also be 0, for the most critical services. A tier 0
change needs an independent owner approval and independent approvals from
two different SREs; its perf check must pass; a hotfix may not skip the
deploy window; and every tier 0 change that ships pages the on-call engineer.

**Service freezes.** `change.depends_on` lists the services the change
depends on and `calendar.frozen` lists services that are frozen today (both
optional, empty when missing). A change whose own service or any dependency
is frozen may not ship inside the deploy window; a hotfix still may.
-/

namespace Bench.Deploy3

open Tribrach.Logic
open Lean (Json)

/-- At or above this share of error budget left, a service is healthy. -/
def healthyBudgetPct : Int := 20

/-- Deploy windows: Monday to Thursday 9-17, Friday 9-15. -/
def inWindow (day : String) (hour : Int) : Bool :=
  if ["mon", "tue", "wed", "thu"].contains day then 9 ≤ hour && hour < 17
  else if day == "fri" then 9 ≤ hour && hour < 15
  else false

/-- An optional list of strings; missing or null means empty. -/
def optStrs (j : Json) (k : String) : Except String (List String) :=
  match j.getObjVal? k with
  | .ok Json.null => pure []
  | .ok a => do let xs ← a.getArr?; xs.toList.mapM (·.getStr?)
  | .error _ => pure []

def encode (j : Json) : Except String (List Fact) := do
  let ch ← j.getObjVal? "change"
  let svc ← getStr ch "service"
  let author ← getStr ch "author"
  let risk ← getStr ch "risk"
  let migration ← getBool ch "migration"
  let hotfix ← getBool ch "hotfix"
  let s ← j.getObjVal? "service"
  let tier ← getInt s "tier"
  let budget ← getInt s "error_budget_pct"
  let canary ← getBool s "canary"
  let checks ← j.getObjVal? "checks"
  let cs ← ["unit", "integration", "security", "perf"].mapM (fun k => do
    let st ← getStr checks k
    return fact "check" [k, st])
  let apps ← getArr j "approvals"
  let as ← apps.toList.mapM (fun a => do
    let by_ ← getStr a "by"
    let role ← getStr a "role"
    return (by_, role))
  let ids := (as.map (·.1)).eraseDups
  let cal ← j.getObjVal? "calendar"
  let day ← getStr cal "day"
  let hour ← getInt cal "hour"
  let freeze ← getBool cal "freeze"
  let oc ← j.getObjVal? "oncall"
  let acked ← getBool oc "acked"
  let deps ← optStrs ch "depends_on"
  let frozen ← optStrs cal "frozen"
  let freezeHit := frozen.contains svc || deps.any frozen.contains
  return [fact "service" [svc], fact "tier" [svc, toString tier], fact "risk" [risk],
          fact "author" [author], fact "budget" [svc, toString budget],
          fact "day" [day], fact "hour" [toString hour], fact "perf_required" ["1"], fact "perf_required" ["0"]] ++
    cs ++
    as.map (fun (u, r) => fact "approved" [u, r]) ++
    (ids.flatMap (fun a => ids.filterMap (fun b => if a != b then some (fact "distinct" [a, b]) else none))) ++
    when (tier == 1) (fact "tier_one") ++
    when (tier == 0) (fact "tier_zero") ++
    deps.map (fun d => fact "depends_on" [d]) ++
    frozen.map (fun f => fact "frozen_service" [f]) ++
    when freezeHit (fact "freeze_hit") ++
    when migration (fact "migration") ++
    when hotfix (fact "hotfix") ++
    when canary (fact "has_canary") ++
    when (budget ≥ healthyBudgetPct) (fact "budget_healthy") ++
    when (budget < healthyBudgetPct) (fact "budget_low") ++
    when (inWindow day hour) (fact "in_window") ++
    when freeze (fact "freeze") ++
    when acked (fact "oncall_acked")

def S := v "S"
def U := v "U"

def rules : List Rule := [
  -- Checks
  { name := "unit and integration pass"
    head := atom "core_green", body := [atom "check" [c "unit", c "pass"], atom "check" [c "integration", c "pass"]] },
  { name := "security scan passed"
    head := atom "security_ok", body := [atom "check" [c "security", c "pass"]] },
  { name := "tier 3 may skip the security scan"
    head := atom "security_ok", body := [atom "check" [c "security", c "skipped"], atom "tier" [S, c "3"]] },
  { name := "perf passed"
    head := atom "perf_ok", body := [atom "check" [c "perf", c "pass"]] },
  { name := "perf not required for this tier"
    head := atom "perf_ok", body := [atom "tier" [S, v "T"]]
    neg := [atom "perf_required" [v "T"]] },
  { name := "checks green"
    head := atom "checks_green", body := [atom "core_green", atom "security_ok", atom "perf_ok"] },
  -- Approvals
  { name := "independent approval"
    head := atom "independent" [U, v "R"], body := [atom "approved" [U, v "R"]]
    neg := [atom "author" [U]] },
  { name := "two independent approvers"
    head := atom "two_approvers"
    body := [atom "independent" [U, v "R1"], atom "independent" [v "V", v "R2"], atom "distinct" [U, v "V"]] },
  { name := "owner approved"
    head := atom "owner_ok", body := [atom "independent" [U, c "owner"]] },
  { name := "sre approved"
    head := atom "sre_ok", body := [atom "independent" [U, c "sre"]] },
  { name := "two sres approved"
    head := atom "two_sres"
    body := [atom "independent" [U, c "sre"], atom "independent" [v "V", c "sre"], atom "distinct" [U, v "V"]] },
  { name := "low risk: any independent approval"
    head := atom "approvals_ok", body := [atom "risk" [c "low"], atom "independent" [U, v "R"]] },
  { name := "medium risk: owner"
    head := atom "approvals_ok", body := [atom "risk" [c "medium"], atom "owner_ok"] },
  { name := "high risk: owner and two approvers"
    head := atom "approvals_ok", body := [atom "risk" [c "high"], atom "owner_ok", atom "two_approvers"] },
  { name := "no migration"
    head := atom "migration_ok", body := [atom "service" [S]], neg := [atom "migration"] },
  { name := "migration needs sre"
    head := atom "migration_ok", body := [atom "migration", atom "sre_ok"] },
  { name := "not tier 0 or 1"
    head := atom "tier_ok", body := [atom "service" [S]], neg := [atom "tier_one", atom "tier_zero"] },
  { name := "tier 1 needs owner"
    head := atom "tier_ok", body := [atom "tier_one", atom "owner_ok"] },
  { name := "tier 0 needs owner and two sres"
    head := atom "tier_ok", body := [atom "tier_zero", atom "owner_ok", atom "two_sres"] },
  -- When
  { name := "inside the deploy window"
    head := atom "when_ok", body := [atom "in_window"], neg := [atom "freeze", atom "freeze_hit"] },
  { name := "hotfix with sre and on-call"
    head := atom "when_ok", body := [atom "hotfix", atom "sre_ok", atom "oncall_acked"], neg := [atom "tier_zero"] },
  -- Decisions
  { name := "ready"
    head := atom "ready"
    body := [atom "checks_green", atom "approvals_ok", atom "migration_ok", atom "tier_ok", atom "when_ok"] },
  { name := "full deploy"
    head := atom "deploy" [S], body := [atom "ready", atom "service" [S], atom "budget_healthy"]
    neg := [atom "risk" [c "high"]] },
  { name := "high risk without canary"
    head := atom "deploy" [S], body := [atom "ready", atom "service" [S], atom "risk" [c "high"], atom "budget_healthy"]
    neg := [atom "has_canary"] },
  { name := "canary on low budget"
    head := atom "canary" [S], body := [atom "ready", atom "service" [S], atom "has_canary", atom "budget_low"] },
  { name := "canary for high risk"
    head := atom "canary" [S], body := [atom "ready", atom "service" [S], atom "has_canary", atom "risk" [c "high"]] },
  { name := "page for hotfix"
    head := atom "page" [S], body := [atom "ready", atom "service" [S], atom "hotfix"] },
  { name := "page for tier 1 migration"
    head := atom "page" [S], body := [atom "ready", atom "service" [S], atom "migration", atom "tier_one"] },
  { name := "page for tier 0"
    head := atom "page" [S], body := [atom "ready", atom "service" [S], atom "tier_zero"] }
]

def templates : Templates := [
  ("service", "the change is for $1"),
  ("tier", "$1 is tier $2"),
  ("risk", "the change is $1 risk"),
  ("author", "$1 wrote the change"),
  ("budget", "$1 has $2% of its error budget left"),
  ("day", "the day is $1"),
  ("hour", "the hour is $1"),
  ("perf_required", "tier $1 needs a passing perf check"),
  ("check", "the $1 check is $2"),
  ("approved", "$1 approved as $2"),
  ("distinct", "$1 and $2 are different people"),
  ("tier_one", "the service is tier 1"),
  ("tier_zero", "the service is tier 0"),
  ("two_sres", "two different SREs approved independently"),
  ("depends_on", "the change depends on $1"),
  ("frozen_service", "$1 is frozen today"),
  ("freeze_hit", "the service or one of its dependencies is frozen"),
  ("migration", "the change has a migration"),
  ("hotfix", "the change is a hotfix"),
  ("has_canary", "the service has a canary"),
  ("budget_healthy", "the error budget is healthy (20% or more left)"),
  ("budget_low", "the error budget is low (under 20% left)"),
  ("in_window", "it is inside the deploy window"),
  ("freeze", "a deploy freeze is on"),
  ("oncall_acked", "the on-call engineer has acknowledged"),
  ("core_green", "unit and integration checks pass"),
  ("security_ok", "the security requirement is met"),
  ("perf_ok", "the perf requirement is met"),
  ("checks_green", "all required checks are green"),
  ("independent", "$1 approved as $2 and is not the author"),
  ("two_approvers", "two different people approved independently"),
  ("owner_ok", "an owner approved independently"),
  ("sre_ok", "an sre approved independently"),
  ("approvals_ok", "the approvals are enough for this risk"),
  ("migration_ok", "the migration requirement is met"),
  ("tier_ok", "the tier requirement is met"),
  ("when_ok", "it may ship now"),
  ("ready", "the change is ready"),
  ("deploy", "deploy $1 to everyone"),
  ("canary", "deploy $1 to the canary"),
  ("page", "page on-call for $1")
]

def model : BenchModel :=
  { name := "deploy3", encode, rules, templates, decisions := ["deploy", "canary", "page"] }

end Bench.Deploy3
