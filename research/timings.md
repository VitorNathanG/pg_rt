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
| **`rt_hit`** | **8 649 154** | **≈ 2.29 GB** |
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

### About half of that is tuple header, not data

Measured on probe tables of identical shape:

| | bytes/row | useful payload |
|---|---|---|
| `rt_hit` / `rt_new` | 264.5 | 125 |
| `rt_ray` | 264.8 | 129 |
| `rt_sray` | 118.0 | 92 |
| `rt_rad` | 86.5 | 32 |

A standalone `vec3` measures **48 bytes for 24 bytes of floats** — the composite
tuple header doubles it — and a whole `hit` record is 127 bytes. An `rt_hit` row
carries three nested composites (`d`, `att`, `h`, the last containing two more),
so it pays that tax at several levels, then again for the row header and item
pointer.

This is the same problem `tri` solves with its flat `float8` mirror columns, but
for a different reason. `tri` is read once per *candidate pair*, millions of
times per bounce, so `FieldSelect` cost dominated there. `rt_hit` is read once
per ray, so nobody ever paid to flatten it — the cost shows up as bytes rather
than as time.

It is the practical ceiling on the current design: at 2×2 samples all of this
quadruples, putting `rt_hit` near 10 GB for a full HD frame. Lifting it is
straightforward — `rt_hit` never needs `d` and `att` as `vec3` at all.
