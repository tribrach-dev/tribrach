# Deploy gate: specification

The deploy gate decides whether and how one change ships. This document is
the source of truth for its behaviour.

## Input

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
- `hour` is the hour of the day, 0-23.

## Output

A sorted list of decisions:

- `deploy S`: ship the change to everyone.
- `canary S`: ship the change to the canary only.
- `page S`: page the on-call engineer when it ships.

S is the change's service.

## Rules

### Checks

All required checks are green when:

- unit and integration both pass;
- security passes, or it is skipped and the service is tier 3;
- perf passes, or the service is not tier 1 (perf is only required for
  tier 1).

### Approvals

An approval is **independent** when the approver is not the change's author.
Only independent approvals count for anything below.

| Risk | Approvals needed |
| --- | --- |
| low | at least one independent approval (any role) |
| medium | an independent owner approval |
| high | an independent owner approval, and independent approvals from at least two different people |

Also:

- a change with a migration needs an independent SRE approval;
- a change to a tier 1 service needs an independent owner approval.

### When it may ship

A change may ship now when either:

- it is inside the deploy window and there is no deploy freeze; or
- it is a hotfix with an independent SRE approval and the on-call engineer
  has acknowledged (`oncall.acked`). This applies outside the window and
  during a freeze.

Deploy windows: Monday to Thursday from 09:00 up to (not including) 17:00,
and Friday from 09:00 up to (not including) 15:00. No window on weekends.

### Error budget

The error budget is **healthy** when `error_budget_pct >= 20`, and **low**
otherwise.

### Decisions

A change is **ready** when its checks are green, its approvals are enough
for its risk, the migration and tier requirements are met, and it may ship
now. If it is not ready, there are no decisions.

For a ready change:

- `deploy S` when the budget is healthy and the risk is not high;
- `deploy S` when the budget is healthy, the risk is high, and the service
  has no canary;
- `canary S` when the service has a canary and the budget is low;
- `canary S` when the service has a canary and the risk is high;
- `page S` when the change is a hotfix;
- `page S` when the change has a migration and the service is tier 1.

These combine: for example a ready medium-risk change with a low budget and
a canary gets only `canary S`; with a low budget and no canary it gets no
deploy decision at all.
