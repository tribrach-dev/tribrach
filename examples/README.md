# Examples

Each folder is a self-contained project that CI builds; if it has a
`check.sh`, CI runs that too. Examples are neutral:
they never contain code or data from a real application.

| Example | Shows |
| --- | --- |
| [counter](counter) | The smallest model and its proofs |
| [shipments](shipments) | A relational contract: refusals, failures and several valid outcomes per operation |
| [feedback-triage](feedback-triage) | Replaying user feedback against the model to sort code bugs from spec questions |
| [data-flow](data-flow) | The logic layer: asking "does personal data reach telemetry?" and getting checked, plain-English why trees |
| [guardrail-lab](guardrail-lab) | Planted incidents for testing guardrails (planned) |

Golden files and conformance cases live in [`/tests`](../tests), not here.
