# Where the time and the bytes go

**Absolute timings move a great deal with machine state** — the same binary and
scene measured 1.9× faster later in the day on the same laptop, purely from a
power-profile change. Every comparison here was measured **back-to-back in one
session**; only the ratios carry across machines.

## Per phase

`render(..., p_verbose => true)` reports each phase. At 240×160, one sample,
depth 4, on the default 1118-triangle scene:

| phase | rows | before inlining repair | after |
|---|---|---|---|
| bounce 0 | 38 400 | 0.37 s | 0.37 s |
| bounce 1 | 40 571 | 0.48 s | 0.47 s |
| bounce 2 | 33 912 | 0.47 s | 0.47 s |
| bounce 3 | 36 523 | 0.39 s | 0.39 s |
| bounce 4 | 22 698 | 0.23 s | 0.23 s |
| shadow rays | 49 470 | 0.56 s | 0.51 s |
| direct lighting | 101 892 lit hits | 0.20 s | 0.19 s |
| shading and tone mapping | | 0.66 s | 0.40 s |
| **whole frame** | | **4.90 s** | **4.16 s** |

The phases do not sum to the frame. Spawning each bounce's child rays happens
between the timers and is not reported, which is where the rest of the inlining
repair landed: `child_ray` reaches `v3_reflect` and `v3_refract`, and both were
paying executor runs per ray.

## Scaling with resolution

| resolution | samples | depth | before the inlining work | after |
|---|---|---|---|---|
| 120×80 | 1 | 4 | 5.6 s | **2.6 s** |
| 240×160 | 1 | 4 | 22.0 s | **10.1 s** |
| 480×320 | 2×2 | 5 | — | 144 s |
| 600×400 | 2×2 | 5 | — | 243 s |

Against the fixed-geometry version this replaced — three analytic primitives per
ray, no mesh at all — the same frame measures 5.98 s to this engine's 10.1 s, so
general geometry costs **1.7×** rather than the 3.7× it cost before the inlining
work. The BVH is what keeps it from being 40×.

## Scaling with light count

A light costs one shadow ray per hit it can reach, so cost is linear in the
light count exactly where it has to be and nowhere else. At 240×160, 2×2
samples, depth 5:

| | 1 light | 2 lights | 3 lights |
|---|---|---|---|
| shadow pass | 2.1 s | 4.7 s | 6.5 s |
| shadow rays | 205 009 | 420 987 | 632 812 |
| shading | 2.5 s | 2.5 s | 2.5 s |
| whole frame | 17.8 s | 19.8 s | 22.4 s |

Shading does not move at all. That is the point of splitting `light_rad` from
`shade`: everything depending only on the surface — albedo, the checker lookup,
the Fresnel weight, the specular strength — is computed once per hit no matter
how many lights reach it.

## Memory: what a full HD frame costs

1920×1080, one sample, depth 5, default scene — **262.8 s**, with these
intermediates:

| table | rows | size |
|---|---|---|
| **`rt_hit`** | **8 649 154** | **≈ 1.36 GB** (≈ 2.42 GB before it was flattened) |
| `rt_ray` / `rt_new` (peak) | 2 073 600 | ≈ 0.55 GB each |
| `rt_rad` | 5 353 903 | ≈ 0.46 GB |
| `rt_sray` | 2 557 607 | ≈ 0.30 GB |
| `img` | 2 073 600 | ≈ 0.10 GB |

`rt_hit` dominates by about 4× because it is the only **cumulative** table:
every other scratch table holds one bounce depth and is dropped and recreated at
the top of the next iteration, while `rt_hit` accumulates every hit at every
depth so that shading can run once over all of them.

Its size is worse than depth × rays would suggest, because the ray population
*grows*. Per-depth counts were 2 073 600 → 2 070 817 → 1 548 793 → 1 665 330 →
1 037 673 → 252 941: depth 1 is nearly as large as depth 0, because every glass
hit spawns four children and dispersion outruns absorption for the first bounce.
Total is 4.17× the primary ray count here, against 4.63× at 240×160 with 2×2
samples — the ratio is not quite resolution-independent.

### About half of that was tuple header, not data

Measured on probe tables of identical shape:

| | bytes/row | useful payload |
|---|---|---|
| `rt_hit` / `rt_new`, as records | 264.5 (279.5 in place) | 125 |
| `rt_ray` | 264.8 | 129 |
| `rt_sray` | 118.0 | 92 |
| `rt_rad` | 86.5 | 32 |

A standalone `vec3` measures **48 bytes for 24 bytes of floats** — the composite
tuple header doubles it — and a whole `hit` record is 127 bytes. An `rt_hit` row
carried three nested composites (`d`, `att`, `h`, the last containing two more),
so it paid that tax at several levels, then again for the row header and item
pointer.

This is the same problem `tri` solves with its flat `float8` mirror columns, but
it reached `rt_hit` much later and for a different reason. `tri` is read once per
*candidate pair*, millions of times per bounce, so `FieldSelect` cost dominated
there and forced the issue early. `rt_hit` is read about three times per ray, so
its cost never showed up on a clock — only on a disk.

### Flattening it: 1.77x on the only table that accumulates

`rt_hit` now stores loose `float8` and rebuilds the records on read through
`hit_of()` and `v3()`, both of which inline. Measured on the real table at
240×160, 2×2 samples, depth 5 — 711 087 rows, same rows either way:

| | bytes/row | table |
|---|---|---|
| nested records | 279.5 | 190 MB |
| flat columns | **157.5** | **107 MB** |

**Column order was worth 8.8 bytes of that.** Written in reading order, `mat`
sits between two `float8` and every row pays four bytes of alignment padding to
climb back onto an eight-byte boundary — 167.8 bytes/row against 159.0 on
probes of the two orderings. The narrow columns are therefore grouped ahead of
the wide ones, which is the one place in the schema where declaration order is
load-bearing rather than editorial.

**It costs about 1.8% of a frame, and that is the right trade.** Interleaved,
three reps each, same settings:

| phase | records | flat |
|---|---|---|
| shadow rays | 1856 / 1888 / 1821 ms | 1972 / 1791 / 1774 ms |
| direct lighting | 521 / 537 / 553 ms | 527 / 516 / 532 ms |
| shading | 1101 / 1138 / 1115 ms | 1208 / 1224 / 1195 ms |
| whole frame | 13.61 / 13.69 / 13.73 s | 13.97 / 13.83 / 13.97 s |

The whole cost lands in shading, ~8%, and it is exactly what you would expect:
`shade()` takes a `hit`, so where the record used to be read already-formed off
the page it is now constructed per row. Reconstruction is not free even when it
inlines. Everything else is a wash.

Paying 1.8% of a frame to lift the memory ceiling by 1.77× is worth it because
the ceiling is the binding constraint and the clock is not: at 2×2 samples a
full HD frame's intermediates all quadruple, and `rt_hit` as records was heading
for roughly 10 GB — a disk-space failure rather than a slow render. Anything
that raises the ray count per hit multiplies that table directly, so the cheapest
time to have done this was before such a feature, not after.

Output is bit-identical on both example scenes, which the flat arithmetic has to
be written deliberately to preserve: `v3_scale` multiplies by a reciprocal, so
the shadow-ray direction is `v * (1.0 / dist)` and **not** `v / dist`. Those are
different in floating point.

## Several frames at once, and what a render gave up to allow it

The scratch tables were unlogged tables in `public` with fixed names, so two
sessions rendering at once did not collide and did not error — the second
simply waited out the first's `ACCESS EXCLUSIVE` lock on `rt_hit`. Making them
`TEMP` makes them private to the session and removes the collision entirely,
and PostgreSQL reaps them when the session ends, so nothing has to be cleaned
up.

The cost is that **PostgreSQL will not parallelise a query that reads a
temporary table**, so a render is now single-threaded. That is a real loss and
it is a small one, measured back-to-back on the default scene:

| | 160×120, 2×2, depth 4 | 320×240, 2×2, depth 5 |
|---|---|---|
| unlogged, four workers | 7.90 s | 30.4 s |
| unlogged, `max_parallel_workers_per_gather = 0` | 8.71 s | 33.0 s |
| **temp** | **8.57 s** | **32.8 s** |

The temp row lands on the workers-off row, which is the check that the 9% gap
is the workers and nothing else — `temp_buffers` at 512 MB instead of the 8 MB
default moved it by 40 ms.

**Nine percent is the whole of intra-render parallelism, and the reason is
structural: writes are never parallel in PostgreSQL.** Of this renderer's
phases only the `CREATE TABLE AS` ray builds could ever get a Gather; every
`INSERT` was already single-threaded. The 9% here is the same 9% recorded
under CTAS-against-INSERT, seen from the other side.

Against that, running frames concurrently. Same scene, one 160×120 frame per
session, wall clock for all of them:

| sessions | wall clock | per frame | speedup |
|---|---|---|---|
| 1 | 8.76 s | 8.76 s | 1.0× |
| 2 | 9.38 s | 4.69 s | 1.87× |
| 4 | 11.68 s | 2.92 s | 3.00× |
| 8 | 17.33 s | 2.17 s | 4.04× |

and end to end on the orbit example, 24 frames at 320×200: **144 s serially,
80 s at two, 50 s at four, 37 s at eight** — 3.9×, byte-identical to the
serial run. Ten cores, so the curve flattening between four and eight is the
machine, not the queue.

### The design that keeps the workers is not worth it

The alternative is a schema per backend PID put in front of `public` on the
`search_path`: the scratch tables stay unlogged, keep their workers, and stop
colliding because each session creates its own. It was built and measured
before the temp version, and it is worth recording why it lost.

A workspace named for a PID outlives the session that made it, so it needs a
garbage collector — and the collector has to run somewhere, and the only
somewhere is a render. That is where it falls apart. `DROP SCHEMA` takes an
`AccessExclusiveLock` held until the transaction ends, and a render *is* one
transaction, so two sessions starting together find the same dead workspaces,
one takes the locks, and the other waits out an entire render before it can
start its own. Measured: exactly the 2× serialisation the workspaces existed
to remove, moved one level down and visible only in `pg_locks`.

It is fixable — elect one sweeper with an advisory lock, add a `lock_timeout`
so no sweep ever waits — and the fix works. It is about fifty lines, it leaks a
schema per crashed session, and it buys nine percent.

### What instancing would and would not buy

There is no instancing: `tri.mesh_id` means a mesh *is* its triangles, so N
copies of one object are N copies of its geometry. Measured by duplicating the
default scene's 1104-triangle ball seven times, each at its own transform:

| | 1 ball | 8 balls |
|---|---|---|
| rows in `tri` | 1 118 | 8 846 |
| `tri` on disk | 1 240 kB | 9 864 kB |
| `scene_reindex()` | 30 ms | 148 ms |
| render, 160x120 depth 3 | 3 496 ms | 4 263 ms |

**Storage went up 8x and reindexing 5x, and the render went up 22%** — and that
last number is the interesting one, because it is the number instancing would
*not* improve. A ray still has to be carried into each instance's coordinates
and still has to walk a BVH per instance; sharing the triangles behind those
instances changes what is in the buffer cache, not how many box tests run. The
22% is the eight mesh boxes and eight traversals, and it would be paid either
way.

So instancing here is a memory and build-time feature, not a rendering one, and
that is what sizes its urgency: at ~1.14 kB per triangle, two hundred instances
of a 10k-triangle tree is 2.3 GB of `tri` and a reindex over two million rows
every time anything is added, against 11 MB and 10 000 rows if the geometry
were shared. It is the difference between a scene fitting and not, rather than
between a frame being fast and slow.

### A pose can change under a render that is already running

`render()` is `VOLATILE` and PL/pgSQL takes a fresh snapshot per statement
under `READ COMMITTED`, so `mesh.xform` is re-read at every bounce. Two reads
inside a single function call, with another session committing between them,
returned **0 and then 99**.

The consequence is specific: a geometry animation that overlapped a render
would not produce a frame of the wrong pose, it would produce a frame with its
primary hits at one pose and its reflections and shadows at another, silently.
This is why `examples/spin.sql` is strictly serial while `examples/orbit.sql`
can use the queue — a camera lives on the frame row and cannot change under
the render that is reading it, and geometry, for now, can.
