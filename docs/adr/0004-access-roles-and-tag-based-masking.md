# 0004. Database roles for access, account roles for people; masking by tag, rows by region

Date: 2026-11-12
Status: Accepted

## Context

Analysts read sales by region; regional analysts may see only their region;
customer email and name are personal data that most readers do not need. Grants
in Snowflake drift easily: someone grants a table to a person's role, and a
year later nobody knows why that role can read it.

## Decision

- **Two layers of roles.** Access roles are database roles inside each
  environment's database (`AR_RAW_READ`, `AR_CORE_WRITE`, `AR_MART_READ`
  and others). They hold all object privileges, including future grants per
  schema. Functional roles are account roles (`RL_<env>_ANALYST`,
  `RL_<env>_ENGINEER`, ...). They are granted access roles and nothing else,
  and people and services get functional roles.
- **Managed access schemas.** Only the schema owner (the deploy role) can
  grant on objects, so a grant cannot be made outside the scripts.
- **One owner.** `RL_<env>_DEPLOYER` owns every object in the database,
  including the tasks and pipes, so they run as one known role.
- **PII masked by tag.** The tag `GOVERNANCE.PII` is on `email` and
  `full_name`. Its masking policy shows the value to sessions with
  `RL_<env>_PII_READER` and masks it otherwise; an email keeps its domain.
- **Rows by region.** A row access policy on the MART views passes rows for
  sessions with `RL_<env>_ANALYST_ALL_REGIONS`, or whose roles are mapped to
  the row's region in `GOVERNANCE.REGION_ACCESS`.

## Consequences

- A new person is one `GRANT ROLE`. A new table is covered by the future
  grants without a script change.
- Database roles come along when the database is cloned or replicated. A
  clone for testing keeps its access roles, though not their grants to
  account roles.
- Tag-based masking needs Enterprise edition or higher.
- Policies cannot be replaced while attached. A change to a policy body is a
  new versioned script with `ALTER ... SET BODY` (CONTRIBUTING).
- Region access is data, not code, so it changes without a deployment. The
  cost: `GOVERNANCE.REGION_ACCESS` needs an owner and a review, like any
  grant list (open issue 6).
- Engineers read CORE directly, where the row policy does not apply. CORE is
  for the platform team; analysts only get MART.
