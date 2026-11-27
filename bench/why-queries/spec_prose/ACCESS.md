# Building access: specification

The access service decides what happens when one person taps a badge at one
door. This document is the source of truth for its behaviour.

## Input

```json
{"now": {"day": "tue", "hour": 20, "holiday": false},
 "site": {"lockdown": false, "fire_alarm": false},
 "person": {"id": "f1", "kind": "employee", "role": "facilities", "badge": "active",
            "contract_days_left": null, "training": ["server_access"], "responder": false,
            "escort": null},
 "door": {"id": "roof-1", "zone": "roof", "after_hours": false, "egress": false}}
```

- `kind` is `employee`, `contractor` or `visitor`.
- `role` is `engineer`, `lab_tech`, `facilities`, `security`, `exec` or
  `none`.
- `badge` is `active`, `suspended` or `lost`.
- `contract_days_left` is set for contractors only.
- `escort` is set for visitors: `{"id", "role", "on_site", "training"}`. An
  escort is always an employee with an active badge.
- `hour` is the hour of the day, 0-23.
- Zones: `lobby`, `office`, `lab`, `server`, `loading`, `roof`.

## Output

A sorted list of decisions:

- `open D`: unlock door D.
- `two_factor D`: unlock door D only after a second factor.
- `alert P D`: tell security about person P's tap at door D.
- `expiry_notice P`: remind contractor P that their contract ends soon.

## Policy tables

| Role | Zones the role may enter |
| --- | --- |
| engineer | office |
| lab_tech | office, lab |
| facilities | office, loading, roof, server |
| security | lobby, office, lab, server, loading, roof |
| exec | office |
| none | (none) |

Anyone with an active badge may also enter the lobby.

| Zone | Training required |
| --- | --- |
| lab | lab_safety |
| server | server_access |
| roof | fall_protection |
| others | none |

- **Restricted zones** (second factor outside business hours): lab, server,
  roof.
- **No-visitor zones** (visitors may never enter, escorted or not): server,
  roof.

## Time

- **Business hours**: Monday to Friday, from 07:00 up to (not including)
  19:00, and not a holiday. In hours: `7 <= hour < 19`.
- **Night**: from 22:00 to 06:00, that is `hour >= 22` or `hour < 6`.

## Contracts

For a contractor:

- the contract is **running** while `contract_days_left > 0`;
- it has **ended** when `contract_days_left <= 0`;
- it is **ending soon** when `1 <= contract_days_left <= 7`.

## Rules

### Which zones a person may enter

- The zones their role grants, plus the lobby if their badge is active.
- A **visitor** whose escort is on site may also enter every zone their
  escort may enter (the escort's role zones, plus the lobby), except the
  no-visitor zones.

### Training

A person is **cleared** for a zone when they may enter it and either the zone
needs no training or they have the required training. A visitor who may
enter the zone is also cleared when their escort is cleared for it (the
escort may enter the zone and has its training, if any).

### Credential

A person has a **valid credential** when their badge is active and:

- they are an employee; or
- they are a contractor whose contract is running; or
- they are a visitor whose escort is on site.

### Hours

A person may use a door at this hour when any of these holds:

- it is business hours;
- the door is an after-hours door (`after_hours: true`) and it is not night;
- the person's role is security (any hour);
- the person's role is facilities and the door leads into the loading zone
  (any hour).

### Entry

A person **may go through** a door when they have a valid credential, are
cleared for the door's zone, may use the door at this hour, and the site is
not in lockdown.

During a **lockdown**, only emergency responders (`responder: true`) with a
valid credential may go through, and they may go through any door; nobody
else may.

### Decisions

- `open D` when the person may go through D and D's zone is not restricted.
- `open D` when the person may go through D, D's zone is restricted, and it
  is business hours.
- `two_factor D` when the person may go through D, D's zone is restricted,
  and it is outside business hours.
- `open D` whenever the fire alarm is on and D is a fire exit
  (`egress: true`), whoever taps.
- `alert P D` at every tap by a person whose badge is suspended or lost, by a
  contractor whose contract has ended, or by a visitor whose escort is not
  on site (or who has none). These alerts do not depend on entry.
- `expiry_notice P` when contractor P's contract is ending soon and P may go
  through the door.
