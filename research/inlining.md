# Inlining

Almost every performance decision in this engine traces back to one rule.

**PostgreSQL inlines a SQL function only when its body is a single `SELECT`
with an empty range table** — no `FROM`. When it inlines, the body is
substituted into the caller's expression tree and there is no function call at
runtime at all. When it does not, the call is a full executor run.

That single fact cuts both ways, and the two directions are the first two
findings below.

## Macro expansion means a value named *n* times is computed *n* times

Inlining is textual substitution, not evaluation. Writing

```sql
LATERAL (SELECT child_ray(...)) AS c(r)
```

and then reading `(c.r).o`, `(c.r).d`, `(c.r).att`, `(c.r).chan` substitutes
the *entire call* at every one of those four references.

This is why `OFFSET 0` appears on the LATERAL joins throughout the renderer —
it is an optimisation fence that blocks subquery pull-up, forcing the
expression to be evaluated once and referenced as a Var. It is also why leaf
math is FROM-less SQL while anything that reuses an intermediate is PL/pgSQL.

In the fixed-geometry version this trap alone took a 120×80 render from **over
two minutes to 0.76 s**.

## The fence is not always enough

A ray must carry its inverse direction as a real column, not compute it in a
`LATERAL`. Computing it in a LATERAL looks equivalent, but the planner pulls
the single-row `Result` up into the join filter, and the slab test mentions the
inverse direction twelve times. `EXPLAIN` showed the entire
`ROW(1/nz(...), ...)` expression, with its three divisions, repeated twelve
times inside one box test.

## What the substituted arithmetic actually costs

| | cost |
|---|---|
| inlined expression node | ~2.5 ns |
| PL/pgSQL statement | ~45 ns (18×) |
| `(v).x` FieldSelect on a composite | ~10 ns |
| plain `float8` Var | ~1 ns |
| PL/pgSQL invocation, 5 vec3 args | 348 ns before the first statement |

The crossover is far past where intuition puts it. A fully inlined
Möller–Trumbore with ~90 duplicated expression nodes beats the PL/pgSQL version
by 5×, so `tri_hit` is FROM-less SQL over precomputed edges.

The FieldSelect number is why `tri`, `bvh_node`, `mesh_box` and the ray tables
all carry a flat `float8` mirror of their vectors as `GENERATED ALWAYS ...
STORED` columns: the inlined slab and triangle tests name their arguments some
sixty times between them. Measured over the 460 304 candidate pairs of one
240×160 frame:

| test | composite | flat columns |
|---|---|---|
| slab / box | 387 ns | **106 ns** |
| triangle | 1601 ns | **290 ns** |

Bit-identical results in both cases.

## Inlining fails silently when an argument is expensive

`inline_function` refuses when a parameter that the body names **more than
once** is passed an expression costing more than `10 * cpu_operator_cost`.
Otherwise inlining would multiply that expression by its usage count.

The function then runs as a real SQL function — a full executor run,
microseconds — and **`EXPLAIN` shows nothing unusual**. Same plan, same row
counts, same node types. Only the clock changes.

`v3_unit` is where this bites hardest: it names its argument twenty-one times,
so *any* caller passing more than ten operators' worth of arithmetic silently
gets a real function call per vector. `tri_shading_normal(t, tri_bary(...))`
was 900 ms of a 1347 ms query from this cause alone.

There are exactly two escapes, and both are used throughout the engine:

1. **Bind the argument to a PL/pgSQL local first.** It becomes a `Param`, which
   costs nothing to duplicate.
2. **Write the function in component form.** Three separate scalar parameters
   means the threshold applies *per component*, so ten operators buys three
   times as much.

This is the exact mirror of the first finding: there, naming a value twice made
it compute twice; here, naming it twice stops it inlining at all.

## Auditing it: `auto_explain` counts the failures exactly

Because a non-inlined SQL function runs through the executor, it can be logged
— and a SQL function body that appears as its own logged statement is by
definition one that did not inline. That turns an invisible failure mode into a
census.

```sql
LOAD 'auto_explain';                            -- no CREATE EXTENSION, no restart
SET auto_explain.log_min_duration      = 0;     -- log every nested statement
SET auto_explain.log_analyze           = off;   -- we want call sites, not timings
SET auto_explain.log_nested_statements = on;    -- the essential one
SELECT render(48, 32, 1, 3);
```

Plans land in the server log (`docker logs pg_rt`). The `CONTEXT:` block under
each record names the calling function and line, so every leak can be pinned to
a source location. Two practical notes: `docker logs --since` needs a timezone
suffix or it silently filters everything out, and `log_analyze = on` adds heavy
instrumentation — leave it off unless you want node timings.

`auto_explain` is a contrib *module*, not an extension: it ships in the stock
image, loads per session, and touches nothing in `sql/`.

### The audit result

A 48×32 frame logged **55 830** nested statements — about 36 per camera ray,
each an executor run standing in for a handful of flops. Every one was the same
failure: a `vec3` operator handed an operand past the threshold.

| | nested statements | 240×160, 2×2, depth 5 |
|---|---|---|
| before | 55 830 | 17 585 ms |
| after | **17 305** | **14 898 ms** |

**1.18× end to end**, with both example scenes rendering bit-identical.

Of the 17 305 that remain, 96% are **aggregate transition functions** —
`cand_min` under `nearest`, `v3_add` under `sum(vec3)`. An aggregate's
transition function is invoked through `fmgr` on every row and can never be
inlined, so this is a floor rather than a leak.

### Lowering the floor: the vec3 sum is worth 1.4x where it runs

About 9 900 of those calls were `v3_add` under `sum(vec3)`, at the two places
the renderer reduces vectors per row: the `rt_rad` collapse and the final
shading aggregate. Summing the three components with the built-in
`sum(float8)` and rebuilding the vector moves that arithmetic into C. Measured
at 240x160, 2x2 samples, depth 5, interleaved, three reps each:

| phase | `sum(vec3)` | three `sum(float8)` | |
|---|---|---|---|
| direct lighting | 709 / 698 / 697 ms | 510 / 513 / 514 ms | **1.37x** |
| shading | 1584 / 1577 / 1594 ms | 1137 / 1089 / 1111 ms | **1.43x** |
| whole frame | 15.1 / 14.4 / 14.8 s | 14.1 / 14.5 / 14.4 s | ~1.03x |

661 ms off a 14.8 s frame, so **4.5%** — and the frame-level column shows why
the phase timers are the honest measurement here: the run-to-run spread is
about the size of the effect, and one of the three pairs is a dead tie.

Output is bit-identical, on the default scene and on the dispersion-heavy torus
scene, at the settings each is normally rendered. That is not luck: `sum(float8)`
is strict with no initial condition, so its state starts at the first value
rather than at `0 + x`, and `0 + x = x` exactly in IEEE-754.

Two things worth carrying:

- **`shade()` has to be bound once**, in a `LATERAL ... OFFSET 0`. Named three
  times inside the three sums it is *called* three times per row, which costs
  far more than the aggregate ever did. The change only pays because the
  component split happens below the function call, not above it.
- **`cand_min` under `nearest` is the other 6 700 and has no such fix.** It is
  an argmin, not a sum, so there is no built-in to fall back to; C is out
  without extensions and PL/pgSQL would be slower. The one trick available is
  to make it sortable by a built-in — pack `(t, tri_id)` into a `bytea` as
  `float8send(t) || int4send(tri_id)` and take `min()`, since big-endian
  IEEE-754 compares correctly bytewise for non-negative values — but that
  trades a legible custom aggregate for a per-row palloc and a concatenation.
  Recorded as unmeasured and believed to be a dead end.

### Two things the audit taught

**Failure cascades.** A call that fails to inline costs `procost 100`, which is
itself ten times the threshold — so a single oversized operand un-inlines every
operator above it in the expression. `shade`'s diffuse term was paying six
executor runs because one `mat_albedo` sat in the wrong position in the chain.

**A comment claimed something false for a long time.** The note on `cam_dir`
said the camera basis folded to three literal vectors before the query ran. It
did not: `v3_unit(cam_from() - cam_at())` is over the threshold, so `cam_w`
stayed a live function call, `cam_u` and `cam_v` inherited it, and every camera
ray paid four executor runs for a value constant across the whole frame.

It folds now, and `test/tests.sql` pins it down — including at the shape the
renderer actually calls it. That last check earned its keep immediately: with
the device coordinates in a plain `LATERAL`, subquery pull-up splices the
arithmetic back into the argument and `v3_unit` un-inlines again. The `OFFSET 0`
is load-bearing.

Inlining leaves no trace in the *shape* of a plan, but it does leave one in the
expressions — a function that folded into its caller stops appearing by name in
the `Output` line. That is what those tests assert.
