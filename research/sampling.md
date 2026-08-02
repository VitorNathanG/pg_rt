# Adaptive sampling, and why it pays less than it looks like it should

Rendering at one sample per pixel, asking the image where it disagrees with
itself, and tracing only those pixels again is a two-line idea in a database:
the set of pixels worth more work is a `WHERE` clause.

It works, it is exact, and **it saves about half of what counting pixels says
it should** — because the pixels it selects are the expensive ones. That is the
finding worth keeping; everything else here is the argument for the shape.

Timings are back-to-back in one session on the default 1118-triangle scene at
depth 5. Only the ratios travel.

## The frame is made of two frames, exactly

A refined pixel **throws its coarse sample away** rather than averaging it in.
That looks wasteful and it is the whole reason the feature is checkable.

The coarse sample sits at the pixel centre. The 2×2 grid that replaces it has
no sample there — its four are at the quarter points. Keeping both would give a
refined pixel a five-tap reconstruction filter weighted toward its middle,
while every pixel around it kept a one-tap filter. The image would then be
reconstructed by a filter that varies from pixel to pixel *according to how the
image came out*, which is not a thing anyone can reason about later.

Discarding costs one traced ray per refined pixel. What it buys:

> Every pixel of an adaptive frame is bit-for-bit a pixel of one of two uniform
> renders — the one-sample frame where nothing was refined, the full-grid frame
> where something was.

There is no third value in the image, so the test in `test/tests.sql` is an
equality against two renders that already exist rather than a tolerance. It
also kills the mistake actually worth worrying about: keeping the coarse sample,
or dividing by the wrong count, produces a picture that looks entirely
plausible and is wrong only at the pixels a reader is least able to eyeball.

## The metric has to be contrast, not variance

The textbook criterion is the variance of the samples within a pixel. That is
unavailable here by construction: **after one pass a pixel has one sample, and
one sample has no variance.**

What a pixel's neighbours say about it is the only evidence a first pass leaves
behind — and it is the right evidence anyway, since aliasing is a disagreement
between adjacent pixels rather than a property of one of them.

Two details that are not arbitrary:

- **It is measured after the tone curve**, on the 8-bit values. Two units of
  radiance matter enormously in the shadows and not at all inside a highlight
  the curve is already compressing, and the curve is exactly the function that
  knows which is which. Spending four rays to resolve a difference that
  quantizes away is the failure this avoids.
- **Four offsets, not eight.** Contrast is symmetric, so testing each pair once
  and marking both ends of it covers the full eight-way neighbourhood at half
  the joins. The whole selection costs 106 ms at 400×260 — against the ~24 s of
  tracing it schedules, it does not appear in any budget.

## The finding: the refined set is the expensive set

At 400×260, threshold 16, from `p_verbose`:

| | primary rays | total hits | tracing time |
|---|---|---|---|
| pass 1 (every pixel, 1 sample) | 104 000 | 473 898 | 9.1 s |
| pass 2 (24 942 pixels, 2×2) | 99 768 | 896 667 | 19.4 s |

**Pass 2 fires 4% fewer primary rays than pass 1 and does 1.9× the work.** At
800×520 the same shape, harder: pass 2 fires 265 876 rays against pass 1's
416 000 — 64% as many — and produces 2 677 618 hits against 1 895 462, or 141%.

The per-depth counts say why:

| depth | pass 1 hits/ray | pass 2 hits/ray |
|---|---|---|
| 0 → 1 | 1.05 | 2.07 |

A glass hit spawns four children — three dispersed refraction rays and a
reflection. High local contrast in this scene *is* the glass ball: its
silhouette, its caustic, the chromatic fringing that dispersion produces. So
the contrast test, doing exactly its job, selects the pixels whose ray trees
branch hardest.

This is not a quirk of one scene. Contrast selects edges and specular
structure; edges and specular structure are where transport gets deep. Any
renderer with branching materials should expect the same gap between the pixel
fraction and the cost fraction.

## What it actually costs

At 400×260, against the uniform renders it sits between:

| | time | pixels differing from a true 2×2 render | worst channel |
|---|---|---|---|
| uniform 2×2 | 46.1 s | — | — |
| uniform 1× | 11.7 s | 19 996 (19.2%) | 206 |
| adaptive, threshold 8 | 38.3 s | 4 591 (4.4%) | 59 |
| adaptive, threshold 16 | 35.6 s | 6 671 (6.4%) | 59 |
| adaptive, threshold 32 | 33.0 s | 9 185 (8.8%) | 60 |

23% off at threshold 16, for 6.4% of pixels landing on their one-sample value
instead of their four-sample one.

**That is a thin result, and at this resolution it is the honest one.** The
worst-channel column is the more useful half of the table: a one-sample frame
is wrong by up to 206 levels somewhere, and every adaptive frame here is wrong
by at most 59 — most of the visible error is gone well before most of the time
is.

## It is a function of resolution, and that is the case for it

Edges grow with the width of a frame; pixels grow with its area. So the
fraction of the image that needs refining falls as the frame gets larger, which
is the opposite of how the cost of *not* refining behaves.

Fraction of pixels selected, one-sample pass, same scene and camera:

| frame | threshold 8 | threshold 16 | threshold 32 |
|---|---|---|---|
| 200×130 | 39.7% | 34.5% | 30.2% |
| 400×260 | 28.2% | 24.0% | 19.6% |
| 800×520 | 19.3% | 16.0% | 12.4% |
| 1200×780 | 15.2% | 12.6% | 9.5% |

Close to `width^-0.56` over that range, which is the geometry doing what it
should. And the saving follows it, measured back-to-back at each size:

| frame | uniform 2×2 | adaptive, threshold 16 | saved |
|---|---|---|---|
| 400×260 | 46.1 s | 35.6 s | 23% |
| 800×520 | 250.2 s | 151.5 s | **39%** |

Both points fit one model. A pass at one sample costs about a quarter of a
uniform 2×2 frame, and refined pixels cost about **2.15×** their share of it —
that constant comes out of the 400×260 pair as 2.13 and out of the 800×520 pair
as 2.19, which is the sense in which "the refined set is the expensive set" is a
number rather than a story:

```
adaptive / uniform  =  0.26 + 2.15 * refined_fraction
```

Extrapolating the fraction to 1920×1080 gives about 10% at threshold 16, so the
model puts a full HD adaptive frame near **47%** of a uniform one. That is an
extrapolation of two fits and should be re-measured before it is quoted as a
result.

**So the feature is aimed at the resolutions where 2×2 hurts**, and it gets
better exactly as the problem does. At 400×260, where a uniform 2×2 frame costs
46 s, nobody needs it. At full HD, where the same frame is roughly 18 minutes,
this is the difference between a render you start and one you schedule.

## What it cannot see

The metric asks the neighbours, so it is blind to anything that changes a
single pixel without changing its neighbourhood — a specular glint smaller than
a pixel, a thin feature that lands inside one. Those pixels keep their coarse
value, which is why the worst-channel column above stays at 59 rather than
falling to nothing as the threshold drops. A within-pixel variance test would
catch them, and cannot be run until there are at least two samples to compare —
which is a third pass, not a cheaper first one.
