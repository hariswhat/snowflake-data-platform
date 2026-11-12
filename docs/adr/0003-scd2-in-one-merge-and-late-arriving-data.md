# 0003. Customer history in one MERGE; late and out-of-order data handled explicitly

Date: 2026-11-12
Status: Accepted

## Context

Reports need sales by the region and loyalty tier a customer had when they
ordered, so the customer dimension keeps history. The sources misbehave in
ways the design has to cover:

- the CRM export sometimes re-sends an older version of a customer after a
  newer one;
- a customer can reach the CRM export a day or two after their first order;
- a customer change can be exported after orders placed after it were
  loaded;
- order events arrive twice, and a status can arrive before the lines it
  belongs to.

## Decision

- **Customer: SCD type 2 in one MERGE.** Each changed key appears twice in
  the MERGE source: once with its key, which matches and expires the current
  version, and once with a NULL key, which matches nothing and is inserted as
  the new version. Expiry and insert are one statement, so no reader sees a
  customer with no current version or two.
- Change detection is a SHA-256 over the tracked attributes. Within a batch,
  the newest row per customer wins.
- **Stale rows are not history.** A CRM row no newer than the one the current
  version came from (`source_updated_at`) is skipped and written to
  `OPS.LATE_ARRIVAL`. `valid_from` cannot be used for this, because a first
  version starts in 1900.
- **First versions start in 1900.** An order placed before its customer
  reached the CRM export still finds a version.
- **Point-in-time keys, re-keyed when the dimension catches up.** A line gets
  the customer version valid at the order time, or -1 if there is none yet.
  Each fact run re-keys the lines whose customer versions changed in the last
  seven days. This repairs both a late customer and a late change.
- **Products: type 1.** Lines carry their own unit price, so catalogue price
  history is not needed for revenue.
- **Orders:** status is the newest event by event time, and an older event
  never overwrites a newer one. A line is inserted once, from its
  ORDER_CREATED event. Re-sent events change nothing.

## Consequences

- A customer whose versions are rewritten later (a correction to history) is
  not handled; stale rows only land in `OPS.LATE_ARRIVAL`, and back-dating a
  version is a manual job (runbook section 6).
- The re-key window is seven days of dimension changes. A graph stopped for
  longer needs the re-key statement run by hand without the window.
- In the 90-day run, 73 stale CRM rows were planted. 72 were skipped and
  logged. The other arrived in the same export as a newer row for the same
  customer, so the newer one won within the batch. The plain-Python model in
  `tests/expected.py` gives the same versions and the same count.
- Product changes overwrite. A report of sales by category as it was then is
  not possible without making the product dimension type 2 as well.
