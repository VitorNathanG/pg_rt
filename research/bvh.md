# The acceleration structure

Three levels of bounding volume, each expressed as one join level: mesh box →
BVH leaf → the triangle's own box. The number of levels has to be written into
the query text, which is why the tree is not deeper.

## Leaves are Morton-ordered runs

A leaf is a run of triangles in Z-order by centroid. Grouping by insertion
order instead produced boxes that spanned the whole object and filtered
nothing — measured **slower than no BVH at all**.

## Leaf size is not sqrt(n)

A triangle test costs about three times a box test, so the optimum sits well
below the square root. Measured over the default scene's 1104-triangle ball:

| leaf size | leaves | triangles tested per ray | time |
|---|---|---|---|
| 4 | 280 | 6.5 | 905 ms |
| **8** | **141** | **10.0** | **798 ms** |
| 12 | 94 | 12.1 | 810 ms |
| 20 | 58 | 18.8 | 1025 ms |
| 40 | 30 | 30.1 | 1446 ms |

`scene_reindex()` defaults to `sqrt(n)/3`, which lands in that basin, and
`p_leaf` overrides it.

**The default was re-measured when the triangle box arrived and deliberately
left alone.** Halving it looked like a win — 4610 ms against 4740 on the default
scene, 5270 against 5820 on the torus — but that result did not survive the
machine changing power profile underneath it. On a machine roughly twice as
fast the minimum moved back up to 11 and the ordering of the two candidates
reversed. Leaf size balances box tests against triangle tests, and that balance
belongs to the machine as much as to the geometry.

## The triangle's own box

A leaf is compact but not tight, so most of what a leaf admits goes on to miss
every triangle in it. A slab test costs about a third of a triangle test, so a
box on the triangle itself pays as soon as it rejects a third of what reaches
it — and it rejects far more.

Worth **1.09×** on the default scene and about **1.6×** on the 2050-triangle
torus, under both machine profiles. The win grows with the mesh.

It is six `GENERATED ALWAYS ... STORED` columns rather than a table, so it
cannot drift from the vertices it summarises, and it is stored flat with no
`vec3` beside it — the boxes on `bvh_node` and `mesh_box` mirror a stored
vector and keep one, whereas this one has no authority to mirror.

## The third interior level was built, measured, and rejected

Grouping leaves, so a ray clearing a mesh box need not test every leaf that mesh
owns, is a wash against the triangle box: a few percent each way depending on
the scene, and only at a fan-out of four.

What settled it is **how the fan-out fails**. Six leaves to a group — which
sounds every bit as reasonable as four — cost 38% on the torus. A tuning knob
that has to be guessed per mesh, buys single digits when guessed right, and
fails silently is not worth a table and an index.

### A correction on how that was diagnosed

The two fan-outs plan identically and report identical row counts at every node,
which is what made the 38% look like it appeared nowhere but the clock. The
reasoning was that the real work is slab tests at the leaf level — (rays
surviving the group) × fan — and that `EXPLAIN` counts only the rows that
*survive* a filter, never the number of times it ran.

That is true of plain `EXPLAIN`. It is **not** true under `ANALYZE`, which
reports `Rows Removed by Join Filter` alongside the surviving count — and
evaluations = removed + passed. On a 96×64 frame the three box levels show:

| level | rows removed by join filter |
|---|---|
| mesh box | 26 108 |
| BVH leaf | 127 779 |
| triangle box | 122 110 |

So the fan-out tuning that was done blind is measurable after all. Two caveats
before trusting the numbers: in a parallel plan these are per-worker averages,
and a join filter only runs on pairs that already matched the hash condition.

The source comment in `sql/03_mesh.sql` still describes the plain-`EXPLAIN`
situation. If the group level ever comes back up, start from `ANALYZE`.
