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

- **Customer: SCD type 2 in one MERGE.** The MERGE source has one row per
  new version with a NULL key, which matches nothing and is inserted. A
  customer with a current version also has one row with its key, which
  matches and expires it. Expiry and inserts are one statement, so no reader
  sees a customer with no current version or two.
- Change detection is a SHA-256 over the tracked attributes. **Every** CRM
  row newer than the current version is applied, in timestamp order, so a
  batch that spans several exports (a stopped graph) keeps each
  intermediate version. Rows with no change from the one before are not
  versions.
- **Stale rows are not history.** A CRM row no newer than the one the current
  version came from (`source_updated_at`) is skipped and written to
  `OPS.LATE_ARRIVAL`. `valid_from` cannot be used for this, because a first
  version starts in 1900.
- **First versions start in 1900.** An order placed before its customer
  reached the CRM export still finds a version.
- **Point-in-time keys, re-keyed when the dimension catches up.** A line gets
  the customer version valid at the order time, or -1 if there is none yet.
  Each fact run re-keys the lines of customer versions written in the last
  seven days. This repairs both a late customer and a late change.
- **Products: type 1.** Lines carry their own unit price, so catalogue price
  history is not needed for revenue.
- **Orders:** status is the newest event by event time, and an older event
  never overwrites a newer one. A tie goes to the later step, within a
  batch and across batches. A line is inserted once, from its ORDER_CREATED
  event. Re-sent events change nothing. An ORDER_CREATED event missing a
  required field goes to `OPS.REJECTED_EVENT`, so one bad record cannot
  fail every run.

## Consequences

- A customer whose versions are rewritten later (a correction to history) is
  not handled; stale rows only land in `OPS.LATE_ARRIVAL`, and back-dating a
  version is a manual job (runbook section 6).
- The re-key window is seven days of dimension changes, by when the version
  was written. The customer task runs just before the fact task, so after an
  outage both catch up in the same run. The window is only missed if the
  fact task keeps failing for seven days while the customer task succeeds.
  Then the re-key is run by hand without the window (runbook section 5).
- A stale row is logged unless the same row (customer and timestamp) was
  loaded before, so reloading files does not fill the log.
- Within one batch, rows are ordered by their CRM timestamp, not by when
  they arrived. A stale row in the same batch as the row it is older than,
  and newer than the current version, becomes a short-lived version rather
  than a logged one.
- In the 90-day run, 73 stale CRM rows were planted, and all 73 were
  skipped and logged. The plain-Python model in `tests/expected.py` gives
  the same versions and the same count.
- Product changes overwrite. A report of sales by category as it was then is
  not possible without making the product dimension type 2 as well.
