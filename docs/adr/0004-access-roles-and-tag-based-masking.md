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
  `RL_<env>_ENGINEER`, ...). Apart from warehouse usage, they are granted
  access roles and nothing else, and people and services get functional
  roles.
- **Managed access schemas.** Only the schema owner (the deploy role) can
  grant on objects in them, so an engineer cannot share a table by granting
  it. SECURITYADMIN, or any role with MANAGE GRANTS, still can. Those roles
  are held by the admins who run the admin deployment.
- **One owner.** `RL_<env>_DEPLOYER` owns every object in the database,
  including the tasks and pipes, so they run as one known role.
- **PII masked by tag.** The tag `GOVERNANCE.PII` is on `email` and
  `full_name`, in RAW and in CORE. Its masking policy shows the value to
  sessions with `RL_<env>_PII_READER` and masks it otherwise; an email keeps
  its domain. The deploy role is granted `RL_<env>_PII_READER`, because the
  tasks it owns copy the values from RAW to CORE. Engineers, below it in the
  hierarchy, do not inherit it.
- **Rows by region.** A row access policy on the MART views passes rows for
  sessions with `RL_<env>_ANALYST_ALL_REGIONS`, or whose roles are mapped to
  the row's region in `GOVERNANCE.REGION_ACCESS`.

## Consequences

- A new person is one `GRANT ROLE`. A new table is covered by the future
  grants without a script change.
- Database roles come along when the database is cloned or replicated. A
  clone for testing keeps its access roles, though not their grants to
  account roles.
- Tag-based masking needs Enterprise edition or higher. Setting a policy on
  a tag needs `APPLY MASKING POLICY` on the account, which lets the deploy
  role set or unset masking policies anywhere in the account (open
  issue 9).
- Policies cannot be replaced while attached. A change to a policy body is a
  new versioned script with `ALTER ... SET BODY` (CONTRIBUTING).
- Region access is data, not code, so it changes without a deployment. The
  cost: `GOVERNANCE.REGION_ACCESS` needs an owner and a review, like any
  grant list (open issue 6).
- The row policy's argument is `row_region`, not `region`. Inside its
  subquery, an unqualified `region` would be the mapping table's column,
  and the filter would always pass. A test checks the names differ.
- Engineers read CORE directly, where the row policy does not apply. CORE is
  for the platform team; analysts only get MART.
