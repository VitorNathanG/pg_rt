# Query shape

Given the same arithmetic, the shape it is expressed in moves the clock by an
order of magnitude. These are the shapes that were tried and rejected.

## The executor beats an interpreted loop — but only in the right shape

Two comparisons, each between shapes doing identical work.

4000 rays against 512 triangles, no acceleration structure:

| shape | time |
|---|---|
| set-based join, one PL/pgSQL call per (ray, triangle) | **145 ms** |
| PL/pgSQL loop over the same geometry held in an array | 1311 ms |

16 000 rays against the 514-triangle scene:

| shape | time |
|---|---|
| set-based join through the BVH | **388 ms** |
| per-ray correlated subquery through the BVH | 1097 ms |
| every ray against every triangle, `DISTINCT ON` for the nearest | 10 036 ms |

The first pair says a per-ray tree walk with an explicit stack — the textbook
BVH traversal — is the **wrong** design here: interpreted loop iterations cost
more than the triangle tests they skip.

The second says the reduction must not sort. A correlated subquery pays rescan
setup per ray, and that setup costs more than the arithmetic it performs.

Hence a two-level hierarchy expressed as a chain of joins, closed by an
aggregate.

## Why the bounce loop is not a recursive CTE

It was one, and it cannot stay one. A set-based intersection has to aggregate
many candidate triangles down to one nearest hit, and PostgreSQL forbids that:

```
ERROR:  aggregate functions are not allowed in a recursive query's recursive term
```

So the recursion is unrolled by one level into a PL/pgSQL loop, and the work
inside each iteration becomes an ordinary aggregating join. The loop is bounded
by `maxdepth` and exits early when no rays survive the throughput cutoff.

`nearest` is a custom aggregate that keeps the smallest `t`, with ties broken on
`tri_id`. The tie-break is not cosmetic: a combine function must be commutative
for a parallel aggregate to have a defined answer, and a `Gather` delivers
candidates in whatever order workers finish. Ties are not exotic either — both
triangles of a quad face share a first vertex and a facet normal, so any ray
crossing the diagonal ties exactly. Left unbroken, roughly 1% of the pixels of a
120×80 frame moved from run to run.

## CREATE TABLE AS, not INSERT INTO

**PostgreSQL refuses to parallelise any statement that writes, with `CREATE
TABLE AS` as the one exception.** The identical query gets a `Gather` as a CTAS
and none at all as an `INSERT ... SELECT`. Worth about 9%.

The planner still assigns only one worker, because it sizes workers by page
count and a ray table is small no matter how much arithmetic each row costs.
That is what `min_parallel_table_scan_size = 0` and `parallel_setup_cost = 100`
in `render()` are for, alongside an explicit `parallel_workers = 4` on each ray
table.

Parallel workers also need more shared memory than Docker's default 64 MB
`/dev/shm`, which is why `docker-compose.yml` sets `shm_size`.

One related trap: **`PARALLEL SAFE` is not the default.** A single unmarked
function anywhere in a query makes the whole query ineligible for parallel
execution, silently.

## JIT is off because it was measured

These are arithmetic-heavy queries over millions of rows, which looks like
exactly the JIT's target. It loses badly:

| setting | effect |
|---|---|
| default thresholds | +5% |
| thresholds at zero | **68× slower** |
| default thresholds, *after* the inlining work | 3× slower |

The last row is the interesting one: the newly inlined kernels grew past
`jit_above_cost`, so the optimisation that made the engine fast is what made
the JIT start firing.

The penalty is a roughly constant 4.5–5 s per render regardless of resolution —
`render()` issues a fixed number of distinct queries and each is compiled once
per execution — so there is no crossover at which it pays back.
