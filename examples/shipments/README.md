# Shipments: several valid outcomes

A relational contract (`Tribrach.RelModel`), for operations that can be
refused, can fail, or have more than one acceptable result. Asking to ship 3
units of a 5-unit order may ship 1, 2 or 3 units, or fail for lack of stock;
asking to ship 6 must be refused.

- `shipments_preserves`: whichever allowed outcome happens, the order never
  ships more than was ordered. `shipments_trace` extends that to every
  allowed sequence.
- `shipments_total`: every request has some allowed outcome, a refusal at
  worst. Progress is a separate promise from preservation.
- `lake exe replay` lists the allowed outcomes of one request and replays
  observed transitions as vectors. Each vector shows only that its one
  outcome was allowed. It can't show that the app never picks a forbidden
  outcome elsewhere, or that it can produce every allowed one.
