-- ============================================================
-- TASK A — branch_crosswalk generator (READ-ONLY / prints INSERTs)
-- Run in the Supabase SQL editor. This does NOT modify any data.
-- It emits INSERT statements for unambiguous 1:1 matches and
-- flags every review address with 0 or >1 candidates for human review.
--
-- Matching rule: cert = 16068, year = 2025, matched by the leading
-- street number of both addresses AND the 5-digit ZIP.
-- ============================================================

-- Optional: create the target table first (safe to run; text uninumbr
-- keeps this loose for the later JS join). Adjust types if you prefer.
--
--   create table if not exists branch_crosswalk (
--     branch_address text primary key,
--     uninumbr       text not null,
--     note           text
--   );

with reviews as (
  -- (1) distinct Google Maps review addresses
  select distinct branch_address
  from ab_reviews
  where source = 'Google Maps'
    and branch_address is not null
),
rev as (
  select
    branch_address,
    substring(branch_address from '^\s*(\d+)')                                as street_no,  -- leading street number
    substring(branch_address from '(\d{5})(?:-\d{4})?(?:\s*,?\s*USA)?\s*$')   as zip5         -- trailing ZIP
  from reviews
),
sod as (
  -- Apple Bank branches for the 2025 snapshot
  select
    uninumbr,
    address, city, state, zip,
    substring(address from '^\s*(\d+)')                            as street_no,
    lpad(left(regexp_replace(zip::text, '\D', '', 'g'), 5), 5, '0') as zip5     -- normalize ZIP to 5 digits, restore leading zero
  from sod_branches
  where cert = 16068
    and year = 2025
),
matched as (
  select
    r.branch_address,
    r.street_no as rev_no,
    r.zip5      as rev_zip,
    s.uninumbr,
    s.address || ', ' || s.city || ', ' || s.state || ' ' || s.zip as sod_addr
  from rev r
  left join sod s
    on s.street_no is not null and r.street_no is not null and s.street_no = r.street_no
   and s.zip5     is not null and r.zip5     is not null and s.zip5     = r.zip5
),
agg as (
  select
    branch_address,
    rev_no,
    rev_zip,
    count(uninumbr)                                                       as n,
    array_agg(uninumbr order by uninumbr) filter (where uninumbr is not null) as uninumbrs,
    array_agg(sod_addr order by uninumbr) filter (where uninumbr is not null) as sod_addrs
  from matched
  group by branch_address, rev_no, rev_zip
)
select
  case
    when n = 1 then
      'INSERT INTO branch_crosswalk (branch_address, uninumbr, note) VALUES ('
        || quote_literal(branch_address) || ', '
        || quote_literal(uninumbrs[1]::text) || ', '
        || quote_literal('review: ' || branch_address || ' || sod: ' || sod_addrs[1])
        || ');'
    when n = 0 then
      '-- REVIEW NEEDED (0 candidates) [street_no=' || coalesce(rev_no,'?')
        || ' zip=' || coalesce(rev_zip,'?') || '] :: ' || branch_address
    else
      '-- REVIEW NEEDED (' || n || ' candidates) [street_no=' || coalesce(rev_no,'?')
        || ' zip=' || coalesce(rev_zip,'?') || '] :: ' || branch_address
        || ' :: candidates: ' || array_to_string(sod_addrs, ' | ')
  end                                              as output_line,
  n                                                as match_count
from agg
order by (n = 1) desc, n desc, branch_address;
