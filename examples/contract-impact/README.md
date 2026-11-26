# Contract impact

Stable contract ids, typed dependency edges and revision records
(`Tribrach.Contract`), and an impact report where every verdict is either
**proved** by a theorem or **derived** by a policy rule, each with a checked
why tree (`Tribrach.Impact`). The domains are shipping (with inventory) and
billing (with tax).

- `shipping.orders` was renamed in Lean (`Shipping.OrderBook` became
  `Shipping.Orders`). Its id didn't change, so nothing that refers to it
  broke.
- `inventory.stock` moving to revision 3 is a refinement: revision 3 also
  caps stock at the shelf space. `Inventory.orders_keep_stock_guarantee`
  is a corollary of `Model.carry_over`. It shows that what
  `shipping.orders` used from revision 2 still holds, so the verdict is
  **proved**.
- `inventory.stock` moving to revision 4 has no record, so
  `shipping.orders` needs review. `shipping.partial` and
  `billing.invoices` wait on that review.
- `shipping.orders` moving to revision 2 is a backward-compatible extension
  declared by its author ("adds an optional note field"). `billing.invoices`
  should confirm the claim and review its uses, because a new case can
  break code that assumed the old cases were all.
- `billing.tax` moving to revision 2 shows conflicting records:
  - The author declared it a refinement.
  - A vector run passed, but it was recorded before the last edit, so it is
    stale (`TR0205`).
  - The current vectors fail.

  The refutation wins (`TR0204`), so `billing.invoices` must be re-proved.
- Adding a shortcut rule ("passing vectors are good enough") that concludes
  `proved` without a theorem is reported (`TR0206`). After that, no proved
  verdict is credited until the shortcut is removed or backed.
- A deliberately broken graph shows the graph checks: a missing contract
  (`TR0201`), a cycle (`TR0202`, once per contract in it) and a reliance on a
  revision that doesn't exist yet (`TR0203`).

`lake exe impact` prints the reports with their why trees, and fails if any
verdict changes or any why tree fails the checker.
