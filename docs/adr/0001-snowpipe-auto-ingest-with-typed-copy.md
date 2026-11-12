# 0001. Load with Snowpipe auto-ingest, typed at load, original record kept

Date: 2026-11-12
Status: Accepted

## Context

Three sources drop files into an Azure Blob container: the web shop's order
events (JSON lines, a file an hour), the CRM's daily customer changes and the
catalogue's daily product snapshot (CSV). Orders should reach reports within
the hour. The options considered:

1. **Snowpipe with auto-ingest.** Event Grid puts a message on a storage
   queue for every new blob; a notification integration lets Snowflake read
   the queue, and each pipe copies its new files.
2. **A scheduled task running COPY INTO.** Simple, but every run lists the
   stage and resumes a warehouse whether or not a file arrived.
3. **The Kafka connector or Snowpipe Streaming.** Lower latency, but the web
   shop writes files, not a stream, and nothing needs seconds.
4. **External tables over the container.** No copy, but every query reads
   the files, and change capture would need refreshes and polling.

## Decision

One auto-ingest pipe per source, all reading the same notification
integration and stage, separated by path (`orders/`, `customers/`,
`products/`).

Each pipe's COPY types the columns the transforms need as it loads (a COPY
with a SELECT), and also keeps:

- the original record (`payload`, for the JSON events),
- `METADATA$FILENAME` and `METADATA$FILE_ROW_NUMBER`,
- the load time.

So every row can be traced to its file, and a transform can be replayed from
RAW without going back to the container. Bad files are skipped whole (the
pipe default `ON_ERROR = SKIP_FILE`) and show in `OPS.PIPE_LOAD_ERROR`, which
an alert reads.

## Consequences

- Snowpipe is serverless. Its credits are outside the resource monitors and
  are reported in `OPS.CREDITS_BY_DAY` (ADR-0005).
- Typing at load means a type change in the source fails the file, not a
  query a week later. The cost: a new field is not loaded into its own column
  until the pipe changes, though it is in `payload` from day one.
- A pipe cannot be altered in place to change its COPY. The change is a new
  versioned script that recreates the pipe, and the runbook has the steps:
  pause, recreate, refresh for the gap (section 4).
- Snowpipe skips a file it has loaded in the last 14 days, by name. A file
  loaded again after that, or with `FORCE`, duplicates rows in RAW. The
  transforms deduplicate, and a test reloads a day to show CORE does not
  change.
- Orders are one record per order line, with the header repeated, so no
  transform needs `FLATTEN`. That was the web shop's export format to agree
  on, and it is what made the transforms testable on DuckDB (ADR-0007).
