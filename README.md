# pg_rt — a raytracer in PostgreSQL 17

A recursive raytracer that runs entirely inside PostgreSQL and returns a PNG as
a `bytea`. It renders arbitrary triangular meshes with selectable materials.
No extensions, no procedural language beyond the two that ship in core, no
external image library — the PNG container, its checksums and its DEFLATE
stream are all built in SQL.

```sql
SELECT render(600, 400, 2, 5);                       -- trace into the table `img`
SELECT png_encode(600, 400, png_scanlines('img'));   -- -> bytea
```

![render](out.png)

A checkered ground plane, a metal sphere and a glass cube — all three are
triangle meshes, and the tracer does not know which is which.

## Running it

```bash
docker compose up -d      # PostgreSQL 17
./load.sh                 # install the engine and build the default scene
./test.sh                 # 74 checks on the encoders, the geometry and the optics
./render.sh 600 400 2 5   # width height samples-per-axis max-depth -> out.png
```

## Geometry lives in tables

A scene is rows. Meshes hold triangles, triangles carry optional vertex
normals, and each mesh points at a material:

```sql
SELECT mesh_add_sphere('ball', 'chrome', 1.0, ROW(-1.15, 1.0, -0.2)::vec3, 24);
SELECT mesh_load_obj('bunny', 'crown-glass', :'obj_text',
                     0.9, radians(30), ROW(1.4, 0.9, 0.6)::vec3);
SELECT scene_reindex();          -- rebuild the BVH after any change
```

Changing how something looks is an `UPDATE` of one foreign key — the geometry
is not touched:

```sql
SELECT mesh_set_material('ball', 'crown-glass');
```

A material is a row. `kind` selects the model (diffuse, metal, dielectric) and
the rest are its parameters, including a per-channel index of refraction, so a
second glass with a different dispersion is another `INSERT` rather than
another code path:

```sql
INSERT INTO material (name, kind, ior, absorb, spec_e)
VALUES ('flint-glass', mat_glass(),
        ROW(1.60, 1.68, 1.79)::vec3, ROW(0.20, 0.10, 0.12)::vec3, 420.0);
```

So is a light. A three-point setup is three rows, and nothing in the transport
code knows how many there are — it works on `(hit, light)` pairs and sums them:

```sql
INSERT INTO light (name, p, col, pow) VALUES
  ('fill', ROW(-4.8, 2.6,  5.2)::vec3, ROW(0.42, 0.55, 1.00)::vec3, 55.0),
  ('rim',  ROW(-2.2, 3.4, -6.5)::vec3, ROW(1.00, 0.55, 0.30)::vec3, 90.0);
```

`sky_k` gives a light a disc in the sky, so it shows up in a mirror and in the
background as well as on the surfaces it lights. Keeping that on the light
rather than in the sky is what holds the two consistent: move the light and its
reflection moves with it.

`examples/torus_scene.sql` builds a scene from `examples/torus.obj` — two
copies of one OBJ at different sizes and angles, wearing different materials:

![torus](examples/torus.png)

The OBJ reader handles `v`, `vn` and `f`, polygons of any size
(fan-triangulated), all of the `1`, `1/2`, `1//3` and `1/2/3` corner
spellings, and negative (relative) indices. A mesh loaded without normals can
be smoothed after the fact with `mesh_smooth()`, which averages the facet
normals meeting each vertex, weighted by area.

## What it renders

* **Diffuse** — Lambertian under every light in the scene, with an optional
  procedural checker and a Fresnel-weighted specular reflection on top.
* **Metal** — a conductor, so no diffuse lobe at all: lit entirely by what its
  mirror ray finds, tinted per channel by a Fresnel term whose
  normal-incidence value *is* the metal's colour.
* **Dielectric** — Snell refraction, Schlick–Fresnel reflection, total internal
  reflection past the critical angle, and Beer–Lambert absorption over the true
  path length through the medium.

### Dispersion

A dielectric's index of refraction differs per channel (1.470 / 1.530 / 1.605
for the default glass), so white light entering it splits. A ray carries a
`chan` tag: `0` means it still stands for all three wavelengths, `1`–`3` mean
it has been committed to one. At the first glass surface an undispersed ray
spawns *three* refracted children, each masked down to its own channel and
bent by its own index; from then on each follows a measurably different path.
At 45° incidence red and blue separate by 2.6°, which is what puts the coloured
fringes along the glass edges.

Shadow rays are attenuated rather than binary, so glass casts a tinted shadow
whose colour comes from Beer–Lambert absorption over the thickness the ray
actually traverses.

## How it works

### One set-based pass per bounce

There is no per-pixel loop. Every ray alive at a given bounce depth is
intersected by a *single* query: a join from the ray set through the mesh
boxes, through the BVH leaves, down to the triangles, reduced to one nearest
hit per ray by a hash aggregate.

```sql
SELECT r.rid, nearest(ROW(x.t, t.tri_id)::cand)
FROM rt_ray r
     JOIN mesh_box mb ON box_hit(r.o, r.iv, mb.lo, mb.hi)
     JOIN bvh_node n  ON n.mesh_id = mb.mesh_id AND box_hit(r.o, r.iv, n.lo, n.hi)
     JOIN tri t       ON t.cl = n.cl
     CROSS JOIN LATERAL (SELECT tri_hit(r.o, r.d, t.a, t.b, t.c) OFFSET 0) AS x(t)
WHERE x.t IS NOT NULL
GROUP BY r.rid;
```

`nearest` is a custom aggregate that keeps the smallest `t`. Reducing millions
of candidates with `DISTINCT ON` would mean sorting all of them; an aggregate
does it in one hash pass, and a combine function makes it parallel-safe.

**This used to be one recursive CTE, and it cannot stay that way.** A
set-based intersection has to aggregate many candidate triangles down to one
nearest hit, and PostgreSQL forbids aggregates in a recursive term:

```
ERROR:  aggregate functions are not allowed in a recursive query's recursive term
```

So the recursion is unrolled by one level into a bounce loop, and the work
inside each iteration becomes an ordinary aggregating join. The loop is
bounded by `maxdepth` and exits early when no rays survive the throughput
cutoff.

### The PNG is built byte by byte in SQL

PostgreSQL exposes no zlib binding to SQL, so the container is assembled from
scratch:

* **CRC-32** for the chunk trailers, from a 256-entry table generated at
  install time by a recursive CTE.
* **Adler-32** for the zlib trailer. It is a running sum plus a running sum of
  that sum, so it closes into a form with no loop at all —
  `a = 1 + Σb[j]`, `b = n + Σb[j]·(n−j+1)` — evaluated as one aggregate.
* **DEFLATE** as *stored* (uncompressed) blocks. A stored block is a legal
  DEFLATE block, so the output is a fully conformant PNG that stock decoders
  read; it is simply about as large as the raw pixel data.

## Performance, and what it cost to find

The engine is written around six measured facts. Each one contradicted the
obvious approach, so they are recorded here rather than rediscovered.

**1. A SQL function body is macro-expanded into its caller.** Writing

```sql
LATERAL (SELECT child_ray(...)) AS c(r)
```

and then reading `(c.r).o`, `(c.r).d`, `(c.r).att`, `(c.r).chan` substitutes
the *entire call* at every one of those references. This is why `OFFSET 0`
appears on the LATERAL joins — it is an optimisation fence that blocks
subquery pull-up — and why leaf math has no `FROM` clause (PostgreSQL only
inlines a SQL function whose body is a single `SELECT` with an empty range
table), while anything reusing an intermediate is PL/pgSQL. In the
fixed-geometry version this trap alone took a 120×80 render from *over two
minutes* to 0.76 s.

**2. The fence is not always enough — a ray must carry its inverse direction
as a real column.** Computing it in a `LATERAL` looks equivalent, but the
planner pulls a single-row `Result` up into the join filter, and the slab test
mentions the inverse direction twelve times. `EXPLAIN` showed the entire
`ROW(1/nz(...), ...)` expression, with its three divisions, repeated twelve
times inside one box test.

**3. An inlined expression node costs ~2.5 ns; a PL/pgSQL statement ~45 ns.**
Eighteen times. That crossover is far past where it looks: a fully inlined
Möller–Trumbore with ~90 duplicated expression nodes beats the PL/pgSQL
version by 5×, so `tri_hit` is FROM-less SQL over precomputed edges. A
`(v).x` FieldSelect on a composite costs ~10 ns against ~1 ns for a plain
`float8` Var, and the inlined slab and triangle tests name their arguments
some sixty times between them — which is why `tri`, `bvh_node`, `mesh_box`
and the ray tables all carry a flat `float8` mirror of their vectors as
`GENERATED ALWAYS ... STORED` columns. Measured over the 460 304 candidate
pairs of one 240×160 frame: box test 387 → 106 ns, triangle test 1601 → 290 ns.

**4. Inlining fails silently when an argument is expensive.** `inline_function`
refuses when a parameter the body names more than once is passed an
expression costing more than `10 * cpu_operator_cost`. The function then runs
as a real SQL function — a full executor run, microseconds — and **`EXPLAIN`
shows nothing unusual**. Only timing does. Three instances were live in this
code: `tri_shading_normal(t, tri_bary(...))` was 900 ms of a 1347 ms query
from that cause alone. The escapes are to assign the argument to a PL/pgSQL
local (it becomes a `Param`, cost 0) or to pass components rather than a
composite. This is the exact mirror of fact 1: there, naming a value twice
made it compute twice; here, naming it twice stops it inlining at all.

**5. The executor beats interpreted PL/pgSQL, but only in the right shape.**
Two comparisons, each between shapes doing identical work.

4000 rays against 512 triangles, no acceleration:

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
BVH traversal — is the *wrong* design here: interpreted loop iterations cost
more than the triangle tests they skip. The second says the reduction must not
sort. Hence a two-level hierarchy expressed as a chain of joins, closed by an
aggregate.

**6. Leaf size is not sqrt(n).** A triangle test costs about three times a box
test, so the optimum sits well below it. Measured over the default scene's
1104-triangle ball:

| leaf size | leaves | triangles tested per ray | time |
|---|---|---|---|
| 4 | 280 | 6.5 | 905 ms |
| **8** | **141** | **10.0** | **798 ms** |
| 12 | 94 | 12.1 | 810 ms |
| 20 | 58 | 18.8 | 1025 ms |
| 40 | 30 | 30.1 | 1446 ms |

`scene_reindex()` defaults to `sqrt(n)/3`, which lands in that basin.

**JIT is off because it was measured, not because it is safer.** These are
arithmetic-heavy queries over millions of rows, which looks like exactly the
JIT's target, and it loses badly: +5% at default thresholds, **68× slower**
with the thresholds at zero, and 3× slower *after* the optimisations above,
because the newly inlined kernels grew past `jit_above_cost`. The penalty is
a roughly constant 4.5–5 s per render regardless of resolution — `render()`
issues a fixed number of distinct queries and each is compiled once per
execution — so there is no crossover at which it pays back.

A smaller effect, kept because it is free: every ray set is built with
`CREATE TABLE AS` rather than `INSERT INTO`. PostgreSQL refuses to parallelise
any statement that writes, with CTAS as the one exception — the identical
query gets a `Gather` as a CTAS and none at all as an `INSERT ... SELECT`.
Worth about 9%; the planner still assigns only one worker, because it sizes
workers by page count and a ray table is small no matter how much arithmetic
each row costs. Parallel workers also need more shared memory than Docker's
default 64 MB `/dev/shm`, which is why `docker-compose.yml` sets `shm_size`.

### Where the time goes

`render(..., p_verbose => true)` reports each phase. At 240×160, one sample,
depth 4, on the default 1118-triangle scene:

| phase | rows | time |
|---|---|---|
| bounce 0 | 38 400 | 0.76 s |
| bounce 1 | 40 571 | 1.08 s |
| bounce 2 | 33 912 | 1.09 s |
| bounce 3 | 36 523 | 0.86 s |
| bounce 4 | 22 698 | 0.53 s |
| shadow rays | 49 470 | 1.05 s |
| direct lighting | 101 892 lit hits | 0.39 s |
| shading and tone mapping | | 1.34 s |

Absolute timings move a great deal with machine state — the same binary and
scene measured 1.9× faster earlier in the day on this same laptop — so the
table below gives before and after **measured back-to-back in one session**.
Only the ratio carries across machines.

| resolution | samples | depth | before | after |
|---|---|---|---|---|
| 120×80 | 1 | 4 | 5.6 s | **2.6 s** |
| 240×160 | 1 | 4 | 22.0 s | **10.1 s** |
| 480×320 | 2×2 | 5 | — | 144 s |
| 600×400 | 2×2 | 5 | — | 243 s |

Against the fixed-geometry version this replaced — three analytic primitives
per ray, no mesh at all — the same frame measures 5.98 s to this engine's
10.1 s, so general geometry now costs **1.7×** rather than the 3.7× it cost
before the inlining work. The BVH is what keeps it from being 40×.

## Layout

| file | contents |
|---|---|
| `sql/01_vec3.sql` | `vec3` type, operators, reflection and Snell refraction |
| `sql/02_png.sql` | CRC-32, Adler-32, DEFLATE, PNG chunk framing |
| `sql/03_mesh.sql` | mesh/material/triangle tables, intersection, BVH, OBJ loader |
| `sql/04_scene.sql` | the light table, sky, the default scene |
| `sql/05_trace.sql` | Fresnel, absorption, direct lighting, ray spawning |
| `sql/06_render.sql` | camera, tone mapping, the bounce loop |
| `test/tests.sql` | 85 checks |
| `examples/` | a torus OBJ and the scene that loads it |

## Notes and limitations

* The BVH is two levels deep because the number of join levels has to be
  written into the query text. A tree of arbitrary depth would need a
  recursive descent per bounce, which is expressible now that the bounce loop
  is no longer itself a recursive CTE — it is the obvious next step, and it is
  what a scene of 100k triangles would need.
* `scene_reindex()` must be called after changing geometry. New triangles have
  no BVH leaf until it runs, and the renderer will not see them.
* Placement is scale, pitch and yaw. That is enough to aim a mesh but not to
  shear or mirror one; a real 4×4 transform would need a type and an
  inverse-transpose for the normals.
* Stored DEFLATE blocks mean the PNG is roughly the size of the raw pixels.
  Implementing real Huffman coding in SQL would fix that.
* Lights are points, so shadows are hard-edged. An area light is several rows
  sampling one emitter — the renderer already sums them and needs no change —
  but placing those samples well needs a PRNG, and `random()` is `VOLATILE` and
  would break the planner's assumptions, so it would have to be a hash of the
  ray index.
* A light costs one shadow ray per hit it can reach, so cost is linear in the
  light count where it is not free: measured at 240×160, going from one light
  to three took the shadow pass from 2.1 s to 6.5 s and the whole frame from
  17.8 s to 22.4 s. The shading pass does not move at all (2.5 s in both),
  because everything that depends only on the surface is computed once per hit
  regardless of how many lights reach it.
* The ground plane's Fresnel reflectance is capped below its physical value.
  Uncapped, a grazing-angle mirror floor reflects the bright uniform sky
  across the whole lower frame and erases its own shadows.
* Glass shows some speckle at one sample per pixel: three refracted channels
  each take a different path, and where one of them hits a checker edge the
  disagreement shows up as a coloured pixel. More samples per pixel resolve it.
