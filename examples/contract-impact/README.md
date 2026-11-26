# Contract impact

Stable contract ids, typed dependency edges and an impact report
(`Tribrach.Contract`), across two domains: shipping (with inventory) and
billing.

- `shipping.orders` was renamed in Lean (`Shipping.OrderBook` became
  `Shipping.Orders`). Its id didn't change, so nothing that refers to it
  broke.
- `inventory.stock` moving to revision 4: revision 3 was checked by a
  theorem, but revision 4 has no compatibility record. So `shipping.orders`,
  which relied on revision 2, needs review. `shipping.partial` (refines it) and
  `billing.invoices` (depends on it) are listed as possibly affected through
  it.
- `shipping.orders` moving to revision 2 was declared compatible ("adds an
  optional note field"), so `billing.invoices` is reported as declared, not
  verified.
- If only revision 3 of `inventory.stock` were in play, the report would say
  "compatible, checked by theorem …" and list nothing indirect.
- A deliberately broken graph shows the checks: a missing contract
  (`TR0201`), a cycle (`TR0202`, once per contract in it) and a reliance on a
  revision that doesn't exist yet (`TR0203`).

`lake exe impact` prints the reports and fails if any verdict changes.
