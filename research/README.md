# Research notes

Measurements and findings behind the engine's design, kept out of the top-level
README so that it can stay about *using* the thing.

Almost everything here contradicted the obvious approach, which is why it is
written down rather than rediscovered. Numbers are from a laptop in Docker and
are not portable; the ratios are the part that carries.

| file | what is in it |
|---|---|
| [`inlining.md`](inlining.md) | The rule the whole engine rests on, what it costs when it silently stops applying, and how to audit it with `auto_explain` |
| [`query-shape.md`](query-shape.md) | Joins against loops, why the bounce loop is not a recursive CTE, `CREATE TABLE AS` against `INSERT`, and why JIT is off |
| [`bvh.md`](bvh.md) | Morton-ordered leaves, leaf-size sweeps, the triangle box, and the third level that was built and rejected |
| [`timings.md`](timings.md) | Per-phase and per-resolution breakdowns, scaling with light count, and what a full HD frame costs in bytes |
| [`deflate.md`](deflate.md) | The PNG compressor: accumulators, a quadratic detoast, Huffman under a depth cap, and why per-scanline filtering loses here |
| [`sampling.md`](sampling.md) | Adaptive antialiasing: why a refined pixel discards its coarse sample, and why selecting edges selects the expensive rays |
| [`gif.md`](gif.md) | The 256-colour quantiser: a palette that wasted a fifth of itself, a lookup that was wrong half the time, and why dithering is off |
| [`area-lights.md`](area-lights.md) | Softboxes: why a grid of point lights terraces, what per-hit sampling costs when nothing uses it, and why stratification beats antialiasing |

Two habits these notes assume, both learned the hard way:

* **Measure interleaved, never sequentially.** This machine changed power
  profile mid-session once and made the same binary 1.9× faster, which
  invalidated a day of absolute numbers and nearly shipped a wrong default.
* **`EXPLAIN` agreeing is not evidence that two variants cost the same.** Plans
  can be identical, row counts identical at every node, and wall time 38%
  apart.
