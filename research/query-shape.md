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

The planner assigned only one worker to it, because it sizes workers by page
count and a ray table is small no matter how much arithmetic each row costs, so
each ray table carried `min_parallel_table_scan_size = 0`,
`parallel_setup_cost = 100` and an explicit `parallel_workers = 4`.

**None of that is in the engine any more, and the reason is the more useful
half of this finding.** The scratch tables are `TEMP` now, so that several
frames can render at once, and a query that reads a temporary table is never
parallel — so the 9% above is not a benefit the renderer collects, it is the
exact price of concurrency, and `research/timings.md` prices it from the other
direction and gets the same number.

What is worth keeping is the shape of the rule rather than the tuning. Because
writes are never parallel, CTAS was the *only* phase of this renderer that had
parallelism to gain or lose in the first place; every `INSERT` was
single-threaded throughout. A design whose phases are mostly writes has far
less to gain from `max_parallel_workers` than its CPU count suggests, and that
is worth knowing before tuning for it.

One related trap, for the queries that can still parallelise: **`PARALLEL SAFE`
is not the default.** A single unmarked function anywhere in a query makes the
whole query ineligible for parallel execution, silently.

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

## `OFFSET 0` stops a node moving up, not down

The engine leans on `OFFSET 0` throughout to stop the planner pulling a
subquery up into the join filter, where an inlined expression gets re-evaluated
at every mention. Per-mesh transforms turned up the other half of that rule,
and it cost 2x before it was found.

The intersection join has to carry each ray into each mesh's coordinates
between the mesh-box test and the BVH test. Written the way everything else
here is written — a fenced `LATERAL` computing twelve products — it measured
**18 s against 8.9 s** on a 160x120 frame.

The fence worked. The expression was not pulled up and not duplicated. It was
*pushed down*: the planner placed the node below the `bvh_node` join, so it ran
once per (ray, mesh, leaf) rather than once per (ray, mesh) — **254 660
evaluations where 49 000 were needed**. `EXPLAIN ANALYZE` shows it plainly as
`loops=254660` on a `Result`, which is the only place it is visible; the plan
shape is otherwise exactly what was intended.

For extra measure the planner wrapped it in a `Memoize` keyed on eighteen
float8 columns, which scored **zero hits in 49 493 lookups** and held 10 MB.
Disabling memoize recovered 1.4 s of the 9 s gap, so it was a symptom rather
than the cause.

**The fix is to materialise, which fixes the count rather than the position.**
A `WITH ... AS MATERIALIZED` CTE evaluates once and is scanned once:

| | 160x120, 2x2, depth 4 |
|---|---|
| fenced `LATERAL` in the join | 18.0 s |
| `CREATE TEMP TABLE` per bounce | 10.9 s |
| **`WITH ... AS MATERIALIZED`** | **9.1 s** |
| no transform at all (baseline) | 8.7 s |

The temp table gets the same single evaluation and then gives it back: creating,
`ANALYZE`-ing and dropping one per bounce costs about 1.5 s a frame. The CTE has
no catalog cost and no statistics, and the estimates were good enough here that
the plan came out the same.

So the three fence lessons are distinct, and the first two do not imply the
third:

1. An inlined expression named *n* times is evaluated *n* times — fence it.
2. A fence is not enough when the planner pulls the single-row `Result` up
   anyway — store the value as a real column.
3. A fence says nothing about how far *down* the join tree the node may be
   pushed, and therefore nothing about how many times it runs. Only
   materialising decides that.

Five percent is what a general affine transform per mesh actually costs, once
it is evaluated the right number of times.
