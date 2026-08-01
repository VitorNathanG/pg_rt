# pg_rt — a raytracer in PostgreSQL 17

A recursive raytracer that runs entirely inside PostgreSQL and returns a PNG as
a `bytea`. No extensions, no procedural language beyond the two that ship in
core, no external image library — the PNG container, its checksums and its
DEFLATE stream are all built in SQL.

```sql
SELECT render(720, 480, 2, 6);              -- trace into the table `img`
SELECT png_encode(720, 480, png_scanlines('img'));   -- -> bytea
```

![render](out.png)

A checkered ground plane, a metal sphere, and a glass cube with dispersion.

## Running it

```bash
docker compose up -d      # PostgreSQL 17
./load.sh                 # install the engine
./test.sh                 # 41 checks on the encoders and the optics
./render.sh 720 480 2 6   # width height samples-per-axis max-depth -> out.png
```

## What it renders

* **Ground plane** — checkerboard albedo, Lambertian diffuse under the key
  light, with a Fresnel-weighted specular reflection on top.
* **Metal sphere** — a conductor, so no diffuse lobe at all: it is lit
  entirely by what its mirror ray finds, tinted per channel by a Fresnel term
  whose normal-incidence value *is* the metal's colour.
* **Glass cube** — an oriented box with Snell refraction, Schlick–Fresnel
  reflection, total internal reflection past the critical angle, and
  Beer–Lambert absorption over the true path length through the glass.

### Dispersion

The cube's index of refraction differs per channel (1.470 / 1.530 / 1.605), so
white light entering it splits. A ray carries a `chan` tag: `0` means it still
stands for all three wavelengths, `1`–`3` mean it has been committed to one.
At the first glass surface an undispersed ray spawns *three* refracted
children, each masked down to its own channel and bent by its own index; from
then on each follows a measurably different path. At 45° incidence red and
blue separate by 2.6°, which is what puts the coloured fringes along the cube's
edges.

Shadow rays are attenuated rather than binary, so the cube casts a tinted
shadow whose colour comes from Beer–Lambert absorption over the thickness the
ray actually traverses.

## How it works

### The tracer is one recursive CTE

There is no per-pixel loop. `render()` issues a single `WITH RECURSIVE` query
whose rows are *hit records* — a ray that has already found its surface. The
base term fires `aa²` primary rays per pixel and intersects them. The recursive
term turns every live hit into its reflected and refracted children and
intersects those. Every ray at a given bounce depth is traced in one
set-oriented pass, and the whole image falls out of one `GROUP BY`:

```sql
SELECT px, py, sum(shade(d, h, att)) FROM trace GROUP BY px, py
```

Rows die when they exceed the depth limit or when their throughput drops below
a cutoff, which is what keeps the branching factor from exploding through the
glass.

Modelling rows as hits rather than as rays is what makes this cheap: each ray
is intersected exactly once, and the shading at a hit is evaluated with the
geometry already in hand.

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

`test.sh` checks the checksums against their published vectors, and the
rendered file decompresses cleanly under real zlib.

## The performance problem, and the fix

The first working version took **over two minutes for a 120×80 image**. The
cause was not the algorithm — it was a PostgreSQL evaluation trap worth
knowing about.

**A SQL function body is macro-expanded into its caller.** So when you write

```sql
LATERAL (SELECT child_ray(...)) AS c(r)
```

and then reference `(c.r).o`, `(c.r).d`, `(c.r).att`, `(c.r).chan`, the planner
flattens that subquery and substitutes the *entire `child_ray(...)` call at
every one of those references*. Six references meant six evaluations. The same
thing happened one level down inside `scene_hit`, which referenced its own
intermediate `t` about eight times — each one re-running `hit_cube`, which
re-ran `to_cube` twelve times. The factors multiply. A single ray was costing
thousands of redundant evaluations.

Three changes fixed it, and the code is written to keep them true:

1. **`OFFSET 0` on the LATERAL joins in the tracing query.** It is an
   optimisation fence that blocks subquery pull-up, so each function is
   evaluated once and its result read as a real column. Load-bearing, not
   decoration.
2. **Leaf math has no `FROM` clause.** PostgreSQL only inlines a SQL function
   whose body is a single `SELECT` with an empty range table. Written that way,
   `v3_dot` and friends fold into the caller's expression tree instead of
   costing a call each. Where that means recomputing a square root three times,
   that is still far cheaper than the call it avoids.
3. **Anything that reuses an intermediate is PL/pgSQL.** A local variable is
   computed exactly once. This is why `scene_hit`, `hit_cube`, `shade` and
   `child_ray` are procedural while the vector algebra is not — the split is
   about evaluation counts, not about taste.

Result: the 120×80 render that had not finished in 120 s now takes **0.76 s**,
and cost is linear in pixels again.

| resolution | samples | depth | time |
|---|---|---|---|
| 120×80 | 1 | 4 | 0.76 s |
| 240×160 | 1 | 5 | 3.1 s |
| 480×320 | 1 | 5 | 12.6 s |
| 480×320 | 2×2 | 5 | 52 s |
| 720×480 | 2×2 | 6 | 116 s |

Encoding the 720×480 PNG — a megabyte of CRC-32 through a PL/pgSQL loop plus
the Adler-32 aggregate — adds about 0.6 s on top.

## Layout

| file | contents |
|---|---|
| `sql/01_vec3.sql` | `vec3` type, operators, reflection and Snell refraction |
| `sql/02_png.sql` | CRC-32, Adler-32, DEFLATE, PNG chunk framing |
| `sql/03_scene.sql` | scene constants, ray/shape intersections, `scene_hit` |
| `sql/04_trace.sql` | Fresnel, absorption, shadows, shading, ray spawning |
| `sql/05_render.sql` | camera, tone mapping, the recursive CTE |
| `test/tests.sql` | 41 checks on the encoders and the optics |

## Notes and limitations

* Stored DEFLATE blocks mean the PNG is roughly the size of the raw pixels
  (~1 MB at 720×480). Implementing real Huffman coding in SQL would fix that
  and is the obvious next step.
* The point light gives hard shadows. Area lights would need stochastic
  sampling, which needs a PRNG — `random()` is `VOLATILE` and would break the
  recursive CTE's assumptions, so it would have to be a hash of the ray index.
* The ground plane's Fresnel reflectance is capped below its physical value.
  Uncapped, a grazing-angle mirror floor reflects the bright uniform sky across
  the whole lower frame and erases its own shadows.
* No spatial index: with three objects, every ray tests every shape. A BVH
  would matter the moment the scene grew.
