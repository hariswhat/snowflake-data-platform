# Changelog

Changes to this repository, newest first. Dates are commit dates.

## 2026-11-12

- Generator for a fictional retailer's landing files, with planted
  duplicates, stale CRM rows, late customers, status-before-order events
  and unknown products.
- Account and database migrations for schemachange. Snowpipe auto-ingest
  from Azure Blob, streams and a task graph, SCD type 2 customers, a type 1
  product dimension, and point-in-time fact keys with a 7-day re-key. Also
  a dynamic table for daily sales, tag-based masking, a row access policy
  by region, and secure MART views.
- Monitoring views, two serverless alerts and a credit model.
- Tests on DuckDB against an independent model; static checks of every
  migration; CI and deployment workflows.
- Docs: ADRs 0001 to 0007, C4, NFRs, cost estimate, runbook, open issues.
- Fixes found while writing the docs:
  - The database change history moved from `OPS` to its own schema.
    schemachange creates the history table's schema before any script
    runs, which would have created `OPS` without managed access.
  - The row access policy is now part of each MART view's CREATE. Before,
    it was a separate ALTER, which left a replaced view readable without
    the policy until the ALTER ran.
