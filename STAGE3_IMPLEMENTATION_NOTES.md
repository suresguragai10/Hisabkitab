# HisabKitab Stage 3 Implementation Notes

Version: **6.2.0**  
Migration: `sql/phaseP0_3_inventory_cogs.sql`

## Last completed stage

Stage 2 payment allocations were implemented and the owner confirmed that the Stage 2 migration and function verification completed successfully. Stage 3 therefore resumes at the next unfinished accounting risk: inventory valuation and Cost of Goods Sold.

## Accounting method

Stage 3 uses **perpetual inventory with moving weighted-average cost**.

For tracked goods:

- A purchase increases quantity and Inventory Asset at the purchase-line amount excluding VAT.
- The moving weighted-average cost is `(old inventory value + purchase value) / new quantity`.
- A sale reduces quantity at the weighted-average cost immediately before the sale.
- The sales voucher includes `Dr Cost of Goods Sold / Cr Inventory Asset`.
- Manual stock gains post `Dr Inventory Asset / Cr Stock Adjustment`.
- Damage, shrinkage, and internal-use decreases post `Dr Stock Adjustment / Cr Inventory Asset`.
- Opening stock entered during item creation posts `Dr Inventory Asset / Cr Inventory Opening Equity`.

Services and non-inventory lines continue to debit the configured purchase expense account instead of Inventory Asset.

## Safe treatment of existing stock

Earlier releases tracked quantities without keeping the Inventory Asset ledger synchronized. The Stage 3 migration therefore takes a conservative approach:

1. Existing tracked items are initialized at `current_stock × existing cost_price`.
2. Existing stock movements are marked as legacy where a complete quantity/value roll-forward is unavailable.
3. The migration **does not automatically post** a catch-up journal.
4. `get_inventory_reconciliation()` compares maintained stock valuation with the Inventory Asset ledger.
5. After the quantities and costs have been reviewed in staging, an authorized user may call `reconcile_inventory_ledger(...)` from the Inventory screen.
6. The reviewed difference posts between Inventory Asset and **Inventory Opening Equity**, not current-period Stock Adjustment expense.

This avoids silently changing current-period profit during migration. The reconciliation journal is still an accounting decision and must be reviewed before posting.

## Main database changes

- Added system accounts:
  - `inventory_asset`
  - `cogs`
  - `stock_adjustment`
  - `purchase_return`
  - `inventory_opening`
- Added `average_cost`, `inventory_value`, and `valuation_method` to items.
- Added signed quantity/value deltas and running balances to inventory movements.
- Added cost snapshots to invoice and purchase lines.
- Replaced invoice and bill posting functions with perpetual-inventory versions.
- Added `record_inventory_adjustment(...)`.
- Added `get_inventory_reconciliation()`.
- Added `reconcile_inventory_ledger(...)` for a reviewed one-time or corrective reconciliation.
- Disabled the old quantity-only `update_stock(...)` and `record_stock_movement(...)` pathways.
- Protected inventory quantity/value fields from direct browser updates.

## Frontend changes

- Purchase and invoice lines now retain `item_id` and HSN snapshots for inventory posting.
- Removed the periodic “Post Closing Stock” action because it would double-count inventory under a perpetual method.
- Inventory displays moving average cost, maintained inventory value, movement value deltas, and live ledger reconciliation.
- Manual gains, damage, shrinkage, internal use, and opening corrections require a reason and post a balanced journal automatically.
- Item creation supports opening quantity and opening value through the trusted RPC.

## Returns boundary

The `Purchase Returns Clearing` system account is created for the next lifecycle stage. Complete sales and purchase returns must also reverse VAT, receivable/payable, source-document balances, and stock/COGS. Those immutable credit/debit-note controls belong to **Stage 4**.

Do not use a manual inventory adjustment as a substitute for a customer credit note or vendor debit note. Stage 3 supports only non-document stock gains/losses and reviewed opening corrections.

## Required migration order

Apply in a staging Supabase project after a backup:

1. Confirm `phaseP0_posting.sql` is present.
2. Confirm `phaseP0_1_manual_vouchers.sql` is present.
3. Confirm the accepted `phaseP0_2_payment_allocations.sql` migration is present.
4. Run `phaseP0_3_inventory_cogs_preflight.sql`; every missing-object result must be empty.
5. Confirm the item/category master objects from `phaseP3_masters.sql` are present. Apply that migration only if they are missing.
6. Apply `phaseP0_3_inventory_cogs.sql`.
7. Run `phaseP0_3_inventory_cogs_verify.sql`.
8. Review the reconciliation result before posting any opening difference.

## Acceptance test

Use a new tracked item:

1. Create opening stock: 10 units, total value NPR 1,000.
   - Expected average cost: NPR 100.
   - Expected Inventory Asset increase: NPR 1,000.
2. Purchase 10 units at NPR 120 each, excluding VAT.
   - Expected quantity: 20.
   - Expected inventory value: NPR 2,200.
   - Expected moving average: NPR 110.
3. Sell 5 units.
   - Expected COGS: NPR 550.
   - Expected quantity: 15.
   - Expected inventory value: NPR 1,650.
4. Record damage of 1 unit.
   - Expected Stock Adjustment debit: NPR 110.
   - Expected quantity: 14.
   - Expected inventory value: NPR 1,540.
5. Confirm Inventory reconciliation shows:
   - Stock valuation: NPR 1,540.
   - Inventory Asset ledger: NPR 1,540.
   - Difference: NPR 0.

Also verify that an attempted sale beyond available stock is rejected and that direct browser updates to `current_stock`, `average_cost`, or `inventory_value` are blocked.

## Release limitations

Stage 3 has passed source/build checks but has not been applied to or accepted in the owner’s Supabase staging database. Complete credit/debit-note returns, posted-document reversals, period locks, and structured report classifications remain open. The application is still not approved for production bookkeeping.
