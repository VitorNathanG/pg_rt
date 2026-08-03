# Area lights

A softbox is not sixteen lights. It is one light sampled sixteen times, and
the difference between those two sentences is most of this file.

Numbers are 320x200, one sample per pixel, depth 5, on the default scene,
unless said otherwise.

## The approximation that needs no code, and what is wrong with it

The renderer's unit of work is the `(hit, light)` pair, so `N*N` ordinary point
lights at `pow/N^2` spread over a rectangle already produce a penumbra without
a line of new SQL. It is worth knowing exactly why that is not enough, because
the failure is not the one people expect.

It is not that the result is wrong on average. A regular grid at `pow/N^2` is
the midpoint rule on the emitter's area, and it converges. The problem is that
**every hit in the frame sums the same rows**, so the error is deterministic
and identical everywhere: the penumbra comes out as `N^2` terraces at fixed
positions in the world. Antialiasing cannot remove them, because each
sub-sample of a pixel is a separate hit looking at the same light table.

And the sample count is not set by the softness wanted. It is set by the
tightest specular lobe in the scene. At `spec_e = 260` the chrome ball's lobe
is about five degrees wide; samples on an eight-unit panel at seven units are
twenty-five degrees apart, so each one glints separately and a 2x2 grid reads
as **two distinct highlights** on the ball while the same 2x2 grid is already
producing an acceptable shadow on the floor. Budget for the shadow and the
chrome gives it away.

Two further errors, smaller but worth naming: a grid of point lights has no
emitter cosine, so it lights a surface it is edge-on to at full strength, and
it is not one-sided, so it illuminates whatever stands behind it.

## What replaced it

One row with a shape. `light` gained `u` and `v` (half-extents, so the panel
spans `p +/- u +/- v`), `samples` (per axis, exactly as `aa` is per axis), and
a generated `nrm` which is `unit(u x v)` for a panel and NULL for a point
light. The sampled position is chosen per hit: sample `s` takes cell
`(s % samples, s / samples)` of the grid, jittered inside that cell by a hash
of the hit id.

Three properties of that choice, each of which was needed:

* **Stratified**, so the panel is covered evenly rather than clumpily. This
  turns out to be worth far more than expected -- see the table below.
* **Hashed rather than random**, so it is IMMUTABLE (the planner may hoist and
  parallelise it) and reproducible (a frame is still a function of the scene,
  which is what the golden hashes rely on).
* **Keyed on the hit**, so two hits look at different parts of the panel. This
  is the entire point. Without it this is `N^2` point lights with extra steps.

`nrm` being NULL for a point light is load-bearing and every reader tests for
it explicitly, because `greatest(NULL, 0.0)` is `0.0` -- folding the cosine in
the tidy way would switch every point light in the scene off in silence.

## What it costs when nothing uses it

Every existing scene has only point lights, so the first question is what the
machinery costs where it does nothing. The image is bit-identical -- both
golden hashes are unchanged -- and the shadow ray count is unchanged at 82 852.

| | shadow phase | frame |
|---|---|---|
| before | 848 ms | 7 250 ms |
| carrying the sampled point through `rt_sray` | 862 ms | |
| + the `generate_series` over samples | 888 ms | |
| + the hash and the stratified arithmetic | 978 ms | 7 428 ms |

**+15% of the shadow phase, +2.4% of the frame.** Nearly all of it is the
sample arithmetic rather than the plumbing; guarding the hash behind
`nrm IS NOT NULL` recovered about 5 ms, which is noise, so the branch is not
there.

Two shapes were tried and are slower, both measured on the same frame:

| spelling | shadow phase |
|---|---|
| the arithmetic inline in the CTAS | **978 ms** |
| lights x samples pre-expanded in a MATERIALIZED CTE, plain columns | 1 007 ms |
| the same CTE carrying the light as a composite | 1 084 ms |
| calling `light_sample()` from the CTAS | **3 270 ms** |

The last one is the important one. `light_sample()` is a `LANGUAGE sql`
set-returning function and **is not inlined the way a scalar one is**: it
becomes a function scan with a tuplestore, executed once per lit pair, and
costs 3.3x the whole shadow phase for arithmetic worth a tenth of it. So the
renderer duplicates the expression and a golden hash over an area-light frame
is what stops the copy drifting. This is the same trade `sky()` already makes.

The CTE result is the one that was expected to win and did not: pre-expanding
the lights removes the per-row function scan, but composite field extraction
costs more than the scan saved.

## What it costs when something does use it

An eight-unit softbox, the same one in every row:

| samples/axis | rays per hit | shadow rays | shadow | lights | frame |
|---|---|---|---|---|---|
| 1 | 1 | 80 146 | 1.00 s | 0.31 s | 7.3 s |
| 2 | 4 | 320 823 | 3.88 s | 0.95 s | 10.8 s |
| 4 | 16 | 1 282 768 | 15.1 s | 3.57 s | 24.8 s |
| 8 | 64 | 5 131 251 | 61.9 s | 15.2 s | 83.1 s |

Linear in `samples^2`, as it must be. Against the point-light grid at the
matching ray counts -- 3.26 s, 12.9 s, 55.2 s -- sampling costs **12-19% more
per shadow ray**, which is the arithmetic above scaled up. That is the whole
price of the proper version over the approximation.

Transport does not move at all. A softbox is not a more expensive scene to
trace; it is a more expensive scene to *shade*.

## Stratification is worth more than antialiasing

The obvious idea, once the sample depends on the hit, is that `aa` should
multiply light samples for free: four sub-samples of a pixel are four
different hits, so they look at four different parts of the panel. It does --
and it is still the wrong way to buy shadow quality. Measured as the median
of `|2p - p(left) - p(right)|` over a strip of floor, which reads pixel-to-
pixel roughness while ignoring the checker edges that dominate the mean:

| configuration | shadow rays/px | median roughness | frame |
|---|---|---|---|
| point light | 1 | 0 | 7.3 s |
| 16 point lights in a grid | 16 | 1 | 22.1 s |
| area, samples 4, aa 1 | 16 | **4** | 24.8 s |
| area, samples 2, aa 2 | 16 | **6** | 39.6 s |
| area, samples 1, aa 4 | 16 | **10** | 98.6 s |
| area, samples 8, aa 1 | 64 | 1 | 83.1 s |

Every one of the middle three averages sixteen points on the emitter per
pixel, and they are not equally good. **Samples within a hit are stratified;
samples spread across `aa` sub-samples are independent**, because a hit does
not know which sub-sample of its pixel it is, so each one draws from the whole
panel rather than from its own cell. Sixteen stratified draws beat sixteen
independent ones, and they cost a quarter of the time besides, because `aa`
multiplies transport as well as shadow rays.

So the rule is: **buy shadow quality with `samples`, never with `aa`.** `aa` is
for edges.

The first two rows are the bias-variance trade in one place. The point-light
grid has no variance at all -- it is deterministic -- and pays for that with
terraces the metric above cannot see. The area light has no terraces and pays
for that with noise, which at 64 samples per hit falls back to the grid's
roughness at 12% more cost.

What would close the gap is stratifying across `aa` as well, which needs the
sub-sample index carried on the ray through every bounce so that a hit knows
which cell is its own. That is an extra int on every ray at every depth, and
it was not built: `samples` is both cheaper and better than `aa` for this, so
the configuration it would improve is one nobody should choose.

## What is still an approximation

The sampling is uniform over the panel's **area**, which is the high-variance
choice exactly when the panel is large and close -- the far corners contribute
almost nothing and still get a quarter of the samples. Sampling uniformly over
the solid angle the rectangle subtends is the standard fix and would cut the
noise in the table above without touching the ray count.

The specular response is also averaged rather than importance-sampled, which
is why a large panel dims the chrome highlight rather than broadening it: the
material's lobe is a bare `cos^n` with no normalisation, so its mean over a
wide panel is small. Sampling the lobe and asking whether the ray reached the
panel -- and weighting the two strategies against each other -- is what a real
renderer does here, and it is the thing this file is furthest from.
