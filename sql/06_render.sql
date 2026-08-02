-- ---------------------------------------------------------------------------
-- Camera and the render driver.
-- ---------------------------------------------------------------------------

-- The default camera.  A render may be given any other, so these are where a
-- view starts rather than what it is: render() takes p_from / p_at / p_fov and
-- falls back to these, and a `frame` row records the one actually used.
CREATE FUNCTION cam_from() RETURNS vec3   AS $$ SELECT ROW(0.55, 2.35, 6.70)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_at()   RETURNS vec3   AS $$ SELECT ROW(0.05, 1.00, 0.00)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_fov()  RETURNS float8 AS $$ SELECT 44.0 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- The basis, from a camera rather than from constants.
--
-- These took no arguments once, and read the constants above directly, which
-- let the planner fold the whole basis to three literal vectors before any
-- query ran.  That is not available to a camera that can change per render --
-- and it is worth being precise about what was actually lost, because it is
-- less than it looks.  Folding happened once per *query*, and the basis is
-- constant across a whole frame either way; what render() does instead is
-- compute it once into PL/pgSQL locals, which reach cam_dir as Params.  A
-- Param costs nothing to inline over, so the arithmetic below still collapses
-- into the ray query exactly as it did.  The saving that is gone is three
-- vector normalisations per frame.
--
-- What must not come back is the older failure, which was expensive: passing a
-- whole vec3 to v3_unit hands an argument to a parameter its body names
-- twenty-one times, and inlining stops silently.  Every one of these is in
-- component form for that reason, and test/tests.sql pins it.
CREATE FUNCTION cam_w(f vec3, a vec3) RETURNS vec3
  AS $$ SELECT v3_unit((f).x - (a).x,
                       (f).y - (a).y,
                       (f).z - (a).z) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_u(w vec3) RETURNS vec3
  AS $$ SELECT v3_unit((v3_cross(ROW(0,1,0)::vec3, w)).x,
                       (v3_cross(ROW(0,1,0)::vec3, w)).y,
                       (v3_cross(ROW(0,1,0)::vec3, w)).z) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_v(w vec3, u vec3) RETURNS vec3
  AS $$ SELECT v3_cross(w, u) $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Direction through a point on the image plane.  nx and ny are normalised
-- device coordinates in [-1, 1], with ny pointing up; u, v and w are the
-- basis and th is tan(fov/2), all four constant for the frame.
CREATE FUNCTION cam_dir(nx float8, ny float8, aspect float8,
                        u vec3, v vec3, w vec3, th float8) RETURNS vec3 AS $$
  SELECT v3_unit(
    (u).x * (nx * aspect * th) + (v).x * (ny * th) - (w).x,
    (u).y * (nx * aspect * th) + (v).y * (ny * th) - (w).y,
    (u).z * (nx * aspect * th) + (v).z * (ny * th) - (w).z)
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Extended Reinhard tone mapping followed by a gamma 2.2 transfer, quantised
-- to 8 bits.  The white point keeps plain Reinhard from washing the midtones
-- out: radiance at or above `white` maps to 1.0, and everything below it
-- keeps far more of its contrast than L/(1+L) would leave.
CREATE FUNCTION tone_white() RETURNS float8
  AS $$ SELECT 3.4 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- PL/pgSQL for the exposed radiance, which the tone curve names three times.
-- Spelled as one expression it is well past the point where pow_safe -- whose
-- body names its base three times in turn -- stops inlining, so every channel
-- of every pixel paid a full executor run for a logarithm and an exponential.
-- One local removes it: `l` is a Param, pow_safe folds in, and what is left is
-- a single PL/pgSQL invocation per channel.
CREATE FUNCTION quantize(v float8, exposure float8) RETURNS int AS $$
DECLARE l float8 := greatest(v, 0.0) * exposure;
BEGIN
  RETURN least(255, greatest(0, round(255.0 * pow_safe(
           l * (1.0 + l / (tone_white() * tone_white())) / (1.0 + l),
           1.0 / 2.2))::int));
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- render: trace the scene and leave the result in the table `img`.
--
-- One set-based pass per bounce depth.  Every ray alive at a given depth is
-- intersected by a single query -- a join from the ray set through the mesh
-- boxes, through the BVH leaves, down to the triangles -- and reduced to one
-- nearest hit per ray by a hash aggregate.  Nothing is traced pixel by pixel.
--
-- This used to be one recursive CTE over hit records.  It cannot stay that
-- way: a set-based intersection has to reduce many candidate triangles to one
-- nearest hit, and PostgreSQL forbids aggregates in a recursive term.  The
-- bounce loop below is the recursion, unrolled by one level so that the work
-- inside it can be expressed as an ordinary aggregating join.  The loop runs
-- at most maxdepth+1 times and exits early when no rays survive.
--
-- A render is one or two of those passes.  Given p_refine it traces the frame
-- at a single sample, asks the resulting image which pixels its neighbours
-- disagree with by more than p_refine 8-bit levels, and traces those again at
-- the full aa-by-aa grid; without it there is one pass at the full grid and
-- nothing below behaves differently.  Where that pays and where it does not is
-- measured in research/sampling.md -- briefly, it is a function of resolution,
-- because edges grow with the width of a frame and pixels with its area.
--
-- The scratch tables are TEMP, and that is the one decision here that is about
-- running several renders rather than about running one.
--
-- They were ordinary unlogged tables in public, with fixed names, which made
-- them process-wide state in a design that has none anywhere else.  The
-- failure that caused was quiet: two sessions rendering at once neither
-- collided nor raised anything, the second just waited out the first's
-- ACCESS EXCLUSIVE lock on `rt_hit`, and the pair took as long as running them
-- in turn.  A temporary table is private to its session and reaped when the
-- session ends, so the collision cannot arise and nothing has to be cleaned up
-- afterwards.
--
-- The price is exact and it is the whole of it: **PostgreSQL cannot
-- parallelise a query that reads a temporary table**, so a render is now
-- single-threaded.  That sounds worse than it measured -- 8.7 s against 7.9 s
-- at 160x120, 33 s against 30 s at 320x240, a steady 9% -- and the reason it
-- is only 9% is worth keeping: writes are never parallel in PostgreSQL, so of
-- this function's phases only the CREATE TABLE AS ray builds could ever get a
-- Gather at all.  Every INSERT was already single-threaded.  Nine percent for
-- four workers, against 3.5x for running eight renders at once, is not a close
-- trade.
--
-- The alternative that avoids the trade is a schema per backend PID on the
-- search_path, keeping unlogged tables and their workers.  It was built and
-- measured before this and it is not worth it: it needs a garbage collector
-- for the schemas that sessions leave behind, and the collector needs an
-- elected sweeper, because DROP SCHEMA holds its lock until the transaction
-- ends and a render is one transaction -- so two sessions sweeping the same
-- corpses serialise exactly as badly as the bug being fixed.  About fifty
-- lines of machinery, one self-inflicted deadlock-shaped bug, and a schema
-- leaked per crashed session, to buy back nine percent.
-- ---------------------------------------------------------------------------

CREATE FUNCTION render(img_w int, img_h int, aa int DEFAULT 2, maxdepth int DEFAULT 5,
                       exposure float8 DEFAULT 1.35, cutoff float8 DEFAULT 0.01,
                       p_verbose boolean DEFAULT false,
                       p_from vec3 DEFAULT cam_from(),
                       p_at vec3 DEFAULT cam_at(),
                       p_fov float8 DEFAULT cam_fov(),
                       p_refine int DEFAULT NULL)
RETURNS void AS $$
DECLARE
  dep  int;
  pass int;
  live bigint;
  ts   timestamptz;
  -- Adaptive sampling is off unless asked for, and asking for it at aa = 1 is
  -- asking for nothing: the refinement rate and the base rate would be equal,
  -- so the second pass would retrace exactly the rays the first one did.
  adaptive boolean := p_refine IS NOT NULL AND aa > 1;
  -- The camera basis, once per frame.  These reach cam_dir as Params, which
  -- is what keeps it inlining now that the basis is no longer a constant the
  -- planner can fold; see the note on cam_w above.
  cu   vec3;
  cv   vec3;
  cw   vec3;
  cth  float8;
BEGIN
  cw  := cam_w(p_from, p_at);
  cu  := cam_u(cw);
  cv  := cam_v(cw, cu);
  cth := tan(radians(p_fov) / 2.0);

  -- Every table here is TEMP, which is what lets two sessions render at once;
  -- see the note above.  Only `img` can survive a previous call -- the scratch
  -- tables are dropped at the end of a successful render and rolled away by a
  -- failed one -- and it is cleared through the catalog rather than with DROP
  -- TABLE IF EXISTS only to keep a NOTICE off every session's first render.
  IF to_regclass('pg_temp.img') IS NOT NULL THEN
    DROP TABLE img;
  END IF;
  CREATE TEMP TABLE img (x int, y int, r int, g int, b int);


  -- Where a pixel is accumulated, in radiance and before the tone curve.
  --
  -- The shading pass used to divide by aa*aa and quantize in the same
  -- statement, which quietly asserted two things: that every pixel got the
  -- same number of samples, and that a pixel is finished the first time it is
  -- looked at.  Neither is a property of the renderer, only of the sampling
  -- pattern it happens to use, and both are exactly what a scheme that spends
  -- more samples on some pixels than others has to stop assuming.
  --
  -- Splitting them costs one table and buys the tone curve a single, final
  -- position.  That matters more than the count does: sRGB is not a linear
  -- space, so averaging quantized bytes is not averaging light, and it goes
  -- wrong precisely at the high-contrast edges that any extra sample would be
  -- aimed at.  Radiance stays linear here and is quantized once per pixel.
  CREATE TEMP TABLE img_acc (px int, py int, n int, r float8, g float8, b float8);

  -- Which pixels to sample and how finely, as rows.
  --
  -- This used to be the cross join below: every pixel, at one fixed rate, with
  -- the rate arriving as a PL/pgSQL Param.  Written that way the sampling
  -- pattern is a property of the query text, so there is nowhere to say "this
  -- pixel and not that one" without writing a second query that repeats the
  -- camera.  As a table it is a WHERE clause, and the ray builder below stops
  -- caring where the work came from.
  --
  -- `side` is the grid side rather than the sample count, because that is what
  -- the sample positions are computed from; a pixel gets side*side rays.
  --
  -- Reading the rate from a column instead of a Param costs 32 ms of a 413 ms
  -- ray build at 400x260, and nothing anywhere else -- the camera still folds
  -- to arithmetic over literals, checked in the plan.  That is 0.3% of a frame,
  -- which is below the run-to-run spread of the whole render and had to be
  -- timed as its own phase to be seen at all.
  -- An adaptive render starts coarse and everything else starts finished: one
  -- sample per pixel if a second pass is coming to fix what needs fixing, the
  -- full grid straight away if it is not.
  CREATE TEMP TABLE rt_todo AS
  SELECT gx.px, gy.py, CASE WHEN adaptive THEN 1 ELSE aa END AS side
  FROM generate_series(0, img_w - 1) AS gx(px),
       generate_series(0, img_h - 1) AS gy(py);
  ANALYZE rt_todo;

  -- At most two passes, and the second one is optional.
  --
  -- Everything from here down to the accumulation is written against rt_todo
  -- and cannot tell which pass it is running.  That is the whole of what makes
  -- a second pass cheap: a pass is not a mode, it is the same query over a
  -- different set of pixels.
  FOR pass IN 1 .. 2 LOOP
    -- Flat float8 rather than the vec3 and hit records the shading functions
    -- take, because this is the one table that accumulates.  Every other scratch
    -- table here holds a single bounce and is dropped at the top of the next;
    -- rt_hit keeps every hit at every depth so that shading can run once over
    -- all of them, which makes its width the practical ceiling on resolution.
    --
    -- A nested composite pays a tuple header at every level, so as records this
    -- row measured 279.5 bytes to carry 125 bytes of floats; flat it is 157.5,
    -- and a full HD frame at one sample builds 8.6 million of them.
    --
    -- The seam is not free.  hit_of() and v3() inline, but a record shade() used
    -- to read already-formed off the page now gets constructed per row, which
    -- costs about 8% of the shading phase and 1.8% of a frame.  That buys 1.77x
    -- on the one table whose size is a ceiling rather than a cost.
    --
    -- The narrow columns are grouped ahead of the wide ones rather than kept
    -- with the fields they belong to.  Left in reading order, `mat` sits between
    -- two float8 and every row pays four bytes of alignment padding to get back
    -- onto an eight-byte boundary: 167.8 bytes/row against 159.0 measured.
    CREATE TEMP TABLE rt_hit (
      hid  bigserial,
      px   int,    py int,                    -- pixel this ray belongs to
      mat  int,    back boolean,              -- from the hit record; see below
      dx   float8, dy float8, dz float8,      -- ray direction
      ax   float8, ay float8, az float8,      -- attenuation carried to this hit
      t    float8,                            -- and the rest of the hit record:
      hx   float8, hy float8, hz float8,      -- point,
      nx   float8, ny float8, nz float8);     -- and shading normal
    -- Every ray set is built with CREATE TABLE AS rather than INSERT INTO, which
    -- was once worth about 9%: PostgreSQL refuses to parallelise any statement
    -- that writes and CTAS is the one exception, so the identical query got a
    -- Gather as a CTAS and none at all as an INSERT ... SELECT.  That is exactly
    -- the 9% given up by making these tables temporary, and it is the same 9%
    -- twice rather than a coincidence -- CTAS was the only phase that had it to
    -- lose.  The form stays because it is the shorter way to write it.
    --
    -- A ray also carries its inverse direction as a real column.  Recomputing
    -- it in the query costs far more than storing it: the slab test mentions
    -- it twelve times, and an inlined expression is evaluated at every mention.
    --
    -- Origin and direction are carried twice: once as vec3 for the shading and
    -- spawning code, which is written in vector algebra, and once broken out
    -- into float8 columns for the two intersection joins.  The duplication is
    -- 48 bytes a row and it removes a FieldSelect from every one of the ~60
    -- places the inlined slab and triangle tests name a ray component.  The
    -- inverse direction has no vector form at all -- nothing but box_hit ever
    -- reads it.
    CREATE TEMP TABLE rt_ray AS
    SELECT row_number() OVER () AS rid, td.px, td.py,
           p_from AS o, cr.dir AS d,
           (p_from).x AS ox, (p_from).y AS oy, (p_from).z AS oz,
           (cr.dir).x AS dx, (cr.dir).y AS dy, (cr.dir).z AS dz,
           (v3_inv(cr.dir)).x AS ivx, (v3_inv(cr.dir)).y AS ivy,
           (v3_inv(cr.dir)).z AS ivz,
           ROW(1,1,1)::vec3 AS att, 0 AS chan
    FROM rt_todo td,
         generate_series(0, td.side - 1) AS sx(i),
         generate_series(0, td.side - 1) AS sy(j),
         -- The device coordinates are materialised before cam_dir sees them,
         -- and that is load-bearing rather than tidy.  cam_dir's body reaches
         -- v3_unit, which names each component three times; spelled inline
         -- these two expressions push that argument past the point where
         -- PostgreSQL will inline, and the camera ray costs a whole executor
         -- run per sample.  As Vars they cost nothing to duplicate and the
         -- entire camera folds to arithmetic over literals.
         LATERAL (SELECT 2.0 * ((td.px + (sx.i + 0.5) / td.side) / img_w) - 1.0,
                         1.0 - 2.0 * ((td.py + (sy.j + 0.5) / td.side) / img_h)
                  OFFSET 0) AS nd(nx, ny),
         LATERAL (SELECT cam_dir(nd.nx, nd.ny, img_w::float8 / img_h,
                                 cu, cv, cw, cth)
                  OFFSET 0) AS cr(dir);
    ANALYZE rt_ray;

    -- How many samples each pixel actually got, counted rather than assumed.
    -- Taken here because the bounce loop rebuilds rt_ray with the children and
    -- the camera rays are gone after the first pass; this is the last moment the
    -- sample population exists.  One aggregate over the ray table, against a
    -- bounce loop that will join the same rows against the BVH many times over.
    CREATE TEMP TABLE rt_spp AS
    SELECT px, py, count(*)::int AS n FROM rt_ray GROUP BY px, py;
    ANALYZE rt_spp;

    FOR dep IN 0 .. maxdepth LOOP
      ts := clock_timestamp();

      -- Intersect every live ray at once.  Three levels of box, one join each:
      -- the mesh box rejects whole objects, the BVH leaf rejects clusters of
      -- triangles, the triangle's own box rejects the triangle, and only what
      -- survives all three reaches tri_hit.
      IF dep > 0 THEN            -- nothing to clear on the first pass, and
        DROP TABLE rt_new;       -- IF EXISTS would only be a NOTICE
      END IF;

      -- The world/object boundary, materialised.
      --
      -- The mesh box is the last thing tested in world coordinates; everything
      -- below it -- leaf box, triangle box, triangle -- is tested against the
      -- ray carried into that mesh's own space, which is why a mesh can move
      -- without touching bvh_node or tri.  They never knew where it was.
      --
      -- `AS MATERIALIZED` is doing the work of the whole feature's performance,
      -- and it is a third distinct lesson about fences rather than a repeat of
      -- the other two.  Written as a fenced LATERAL inside the join below, the
      -- transform lands *underneath* the bvh_node join and is re-executed per
      -- leaf rather than per mesh: 254 660 evaluations of twelve multiplies
      -- where 49 000 were needed, wrapped for good measure in a Memoize scoring
      -- zero hits on an eighteen-column key.  18 s against 8.9 s.
      --
      -- OFFSET 0 stops an expression being pulled *up*; it says nothing about
      -- how far *down* the node it guards may be pushed, and it is the second of
      -- those that bites here.
      --
      -- A real TEMP table fixes it too and was measured -- 10.9 s, because
      -- creating, analysing and dropping one per bounce costs about 1.5 s a
      -- frame.  The CTE gets the same single evaluation with none of that.
      --
      -- One row per (ray, mesh) pair the mesh box admits, so it is bounded by
      -- the ray count times the mesh count and in practice far below that.
      CREATE TEMP TABLE rt_new AS
      WITH mray AS MATERIALIZED (
        SELECT r.rid, mb.mesh_id, q.ox, q.oy, q.oz, q.dx, q.dy, q.dz,
               1.0 / nz(q.dx) AS ivx, 1.0 / nz(q.dy) AS ivy, 1.0 / nz(q.dz) AS ivz
        FROM rt_ray r
             JOIN mesh_box mb ON box_hit(r.ox, r.oy, r.oz, r.ivx, r.ivy, r.ivz,
                                         mb.lox, mb.loy, mb.loz,
                                         mb.hix, mb.hiy, mb.hiz)
             JOIN mesh ms     ON ms.mesh_id = mb.mesh_id
             CROSS JOIN LATERAL (
               SELECT ms.ixx * r.ox + ms.ixy * r.oy + ms.ixz * r.oz + ms.itx,
                      ms.iyx * r.ox + ms.iyy * r.oy + ms.iyz * r.oz + ms.ity,
                      ms.izx * r.ox + ms.izy * r.oy + ms.izz * r.oz + ms.itz,
                      ms.ixx * r.dx + ms.ixy * r.dy + ms.ixz * r.dz,
                      ms.iyx * r.dx + ms.iyy * r.dy + ms.iyz * r.dz,
                      ms.izx * r.dx + ms.izy * r.dy + ms.izz * r.dz
               OFFSET 0) AS q(ox, oy, oz, dx, dy, dz)
      ),
      best AS (
        SELECT mr.rid, nearest(ROW(x.t, t.tri_id)::cand) AS c
        FROM mray mr
             JOIN bvh_node n  ON n.mesh_id = mr.mesh_id
                             AND box_hit(mr.ox, mr.oy, mr.oz,
                                         mr.ivx, mr.ivy, mr.ivz,
                                         n.lox, n.loy, n.loz, n.hix, n.hiy, n.hiz)
             JOIN tri t       ON t.cl = n.cl
                             AND box_hit(mr.ox, mr.oy, mr.oz,
                                         mr.ivx, mr.ivy, mr.ivz,
                                         t.lox, t.loy, t.loz, t.hix, t.hiy, t.hiz)
             CROSS JOIN LATERAL (
               SELECT tri_hit(mr.ox, mr.oy, mr.oz, mr.dx, mr.dy, mr.dz,
                              t.ax, t.ay, t.az, t.e1x, t.e1y, t.e1z,
                              t.e2x, t.e2y, t.e2z, t.gnx, t.gny, t.gnz)
               OFFSET 0) AS x(t)
        WHERE x.t IS NOT NULL
        GROUP BY mr.rid
      )
      -- The winner is re-transformed rather than carried through the aggregate:
      -- `nearest` reduces to one row per ray, so this runs once per ray instead
      -- of once per candidate, and a cand wide enough to hold a ray would have
      -- cost more in the aggregate than the six multiplies cost here.
      SELECT r.px, r.py, r.d, r.att * beer(hh.h, m) AS att, r.chan, hh.h
      FROM rt_ray r
           LEFT JOIN best b   ON b.rid = r.rid
           LEFT JOIN tri t    ON t.tri_id = (b.c).tri_id
           LEFT JOIN mesh ms  ON ms.mesh_id = t.mesh_id
           LEFT JOIN material m ON m.mat_id = ms.mat_id
           CROSS JOIN LATERAL (
             SELECT CASE WHEN ms.mesh_id IS NULL THEN r.o
                         ELSE (m34_ray(ms, r.o, r.d)).oo END,
                    CASE WHEN ms.mesh_id IS NULL THEN r.d
                         ELSE (m34_ray(ms, r.o, r.d)).od END
             OFFSET 0) AS orr(oo, od)
           CROSS JOIN LATERAL (
             SELECT make_hit(r.o, r.d, orr.oo, orr.od, b.c, t, ms,
                             coalesce(m.mat_id, 0)) OFFSET 0) AS hh(h);
      ANALYZE rt_new;

      -- rt_new keeps its records: it is rebuilt every bounce, and child_ray
      -- wants them.  Only what accumulates is worth flattening.
      INSERT INTO rt_hit (px, py, mat, back, dx, dy, dz, ax, ay, az,
                          t, hx, hy, hz, nx, ny, nz)
      SELECT px, py, (h).mat, (h).back,
             (d).x, (d).y, (d).z, (att).x, (att).y, (att).z,
             (h).t, ((h).p).x, ((h).p).y, ((h).p).z,
             ((h).n).x, ((h).n).y, ((h).n).z
      FROM rt_new;

      IF p_verbose THEN
        GET DIAGNOSTICS live = ROW_COUNT;
        RAISE NOTICE 'depth % : % hits in % ms', dep, live,
          round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
      END IF;

      EXIT WHEN dep = maxdepth;

      -- Spawn the children of everything just hit.  Joining to material drops
      -- the sky rows, which spawn nothing.
      DROP TABLE rt_ray;
      CREATE TEMP TABLE rt_ray AS
      SELECT row_number() OVER () AS rid, s.px, s.py, s.o, s.d,
             (s.o).x AS ox, (s.o).y AS oy, (s.o).z AS oz,
             (s.d).x AS dx, (s.d).y AS dy, (s.d).z AS dz,
             1.0 / nz((s.d).x) AS ivx, 1.0 / nz((s.d).y) AS ivy,
             1.0 / nz((s.d).z) AS ivz,
             s.att, s.chan
      FROM (
        SELECT h.px, h.py, (c.r).o AS o, (c.r).d AS d,
               (c.r).att AS att, (c.r).chan AS chan
        FROM rt_new h
             JOIN material m ON m.mat_id = (h.h).mat
             CROSS JOIN LATERAL generate_series(
               0, CASE WHEN m.kind = mat_glass() THEN 3 ELSE 0 END) AS br(k)
             CROSS JOIN LATERAL (
               SELECT child_ray(h.d, h.h, h.att, h.chan, br.k, m) OFFSET 0) AS c(r)
        WHERE (c.r).d IS NOT NULL
          AND v3_maxc((c.r).att) > cutoff
      ) AS s;

      GET DIAGNOSTICS live = ROW_COUNT;
      EXIT WHEN live = 0;
      ANALYZE rt_ray;
    END LOOP;

    -- Shadow rays, also in one pass -- one per (hit, light) pair that the light
    -- in question could actually show on.  The pair, not the hit, is the unit of
    -- work from here down: a scene with three lights fires three shadow rays at
    -- an open floor and none at all at a wall facing away from all three.
    ts := clock_timestamp();
    CREATE TEMP TABLE rt_sray AS
    SELECT h.hid, l.light_id,
           h.hx + h.nx * 1e-3 AS ox,
           h.hy + h.ny * 1e-3 AS oy,
           h.hz + h.nz * 1e-3 AS oz,
           sl.ldx AS dx, sl.ldy AS dy, sl.ldz AS dz,
           1.0 / nz(sl.ldx) AS ivx, 1.0 / nz(sl.ldy) AS ivy,
           1.0 / nz(sl.ldz) AS ivz, dd.dist
    FROM rt_hit h
         JOIN material m ON m.mat_id = h.mat
         CROSS JOIN light l
         CROSS JOIN LATERAL (SELECT (l.p).x - h.hx, (l.p).y - h.hy,
                                    (l.p).z - h.hz OFFSET 0) AS lv(vx, vy, vz)
         CROSS JOIN LATERAL (SELECT sqrt(lv.vx * lv.vx + lv.vy * lv.vy
                                         + lv.vz * lv.vz) OFFSET 0) AS dd(dist)
         CROSS JOIN LATERAL (SELECT lv.vx * (1.0 / dd.dist),
                                    lv.vy * (1.0 / dd.dist),
                                    lv.vz * (1.0 / dd.dist)
                             OFFSET 0) AS sl(ldx, ldy, ldz)
    WHERE wants_light(v3(h.dx, h.dy, h.dz),
                      hit_of(h.t, h.mat, h.hx, h.hy, h.hz,
                             h.nx, h.ny, h.nz, h.back), m, l);
    ANALYZE rt_sray;

    -- Transmission toward the light, per blocking mesh.  An opaque mesh stops
    -- the ray outright; a dielectric dims and tints it by Beer-Lambert over the
    -- thickness actually traversed, which for a closed mesh is the span between
    -- the ray's first and last crossing of it.  Not a real caustic, but it
    -- keeps glass from casting the flat black hole a binary test would give it.
    -- Shadow rays cross the same world/object boundary as camera rays, and are
    -- materialised at it for the same measured reason -- see `mray` above.  It
    -- is worth even more here: 2.5 s of shadow phase against 1.1 s.
    --
    -- `dist` is carried across so the "did something block it before the light"
    -- test can stay below, and it is comparable to an object-space `t` only
    -- because the direction was not normalised on the way in.
    CREATE TEMP TABLE rt_shadow AS
    WITH smray AS MATERIALIZED (
        SELECT s.hid, s.light_id, s.dist, mb.mesh_id, ms.mat_id,
               q.ox, q.oy, q.oz, q.dx, q.dy, q.dz,
               1.0 / nz(q.dx) AS ivx, 1.0 / nz(q.dy) AS ivy, 1.0 / nz(q.dz) AS ivz
        FROM rt_sray s
             JOIN mesh_box mb ON box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                         mb.lox, mb.loy, mb.loz,
                                         mb.hix, mb.hiy, mb.hiz)
             JOIN mesh ms     ON ms.mesh_id = mb.mesh_id
             CROSS JOIN LATERAL (
               SELECT ms.ixx * s.ox + ms.ixy * s.oy + ms.ixz * s.oz + ms.itx,
                      ms.iyx * s.ox + ms.iyy * s.oy + ms.iyz * s.oz + ms.ity,
                      ms.izx * s.ox + ms.izy * s.oy + ms.izz * s.oz + ms.itz,
                      ms.ixx * s.dx + ms.ixy * s.dy + ms.ixz * s.dz,
                      ms.iyx * s.dx + ms.iyy * s.dy + ms.iyz * s.dz,
                      ms.izx * s.dx + ms.izy * s.dy + ms.izz * s.dz
               OFFSET 0) AS q(ox, oy, oz, dx, dy, dz)
    ),
    blocker AS (
      SELECT s.hid, s.light_id, s.mesh_id, mm.kind, mm.absorb,
             min(x.t) AS t0, max(x.t) AS t1
      FROM smray s
           JOIN bvh_node n  ON n.mesh_id = s.mesh_id
                           AND box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                       n.lox, n.loy, n.loz, n.hix, n.hiy, n.hiz)
           JOIN tri t       ON t.cl = n.cl
                           AND box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                       t.lox, t.loy, t.loz, t.hix, t.hiy, t.hiz)
           JOIN material mm ON mm.mat_id = s.mat_id
           CROSS JOIN LATERAL (
             SELECT tri_hit(s.ox, s.oy, s.oz, s.dx, s.dy, s.dz,
                            t.ax, t.ay, t.az, t.e1x, t.e1y, t.e1z,
                            t.e2x, t.e2y, t.e2z, t.gnx, t.gny, t.gnz)
             OFFSET 0) AS x(t)
      WHERE x.t IS NOT NULL AND x.t < s.dist
      GROUP BY s.hid, s.light_id, s.mesh_id, mm.kind, mm.absorb
    )
    SELECT hid, light_id,
           CASE WHEN bool_or(kind <> mat_glass()) THEN ROW(0, 0, 0)::vec3
                ELSE ROW(exp(-sum((absorb).x * (t1 - t0))),
                         exp(-sum((absorb).y * (t1 - t0))),
                         exp(-sum((absorb).z * (t1 - t0))))::vec3 * 0.82
           END AS att
    FROM blocker GROUP BY hid, light_id;

    CREATE INDEX ON rt_shadow (hid, light_id);
    ANALYZE rt_shadow;

    IF p_verbose THEN
      RAISE NOTICE 'shadows  : % rays in % ms', (SELECT count(*) FROM rt_sray),
        round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
      ts := clock_timestamp();
    END IF;

    -- Collapse the (hit, light) pairs back to one radiance per hit.  This is
    -- where the light count disappears: everything below sees a single vector
    -- per hit and cannot tell three lights from one.
    --
    -- The second branch is the escaping rays, which are lit only by looking at a
    -- light -- no shadow ray, since nothing stands between a ray and the sky.
    -- Both branches key on hid, so the two grains reduce in one aggregate.
    --
    -- The three component sums are not a stylistic slip.  An aggregate's
    -- transition function is reached through fmgr on every row and can never be
    -- inlined, so sum(vec3) pays a call per row for what the built-in
    -- sum(float8) does in C.  Splitting it is worth 1.37x on this phase.
    CREATE TEMP TABLE rt_rad AS
    SELECT hid, ROW(sum((e).x), sum((e).y), sum((e).z))::vec3 AS rad
    FROM (
      SELECT s.hid,
             light_rad(v3(h.dx, h.dy, h.dz),
                       hit_of(h.t, h.mat, h.hx, h.hy, h.hz,
                              h.nx, h.ny, h.nz, h.back),
                       m, l, coalesce(sh.att, ROW(1,1,1)::vec3)) AS e
      FROM rt_sray s
           JOIN rt_hit h    ON h.hid = s.hid
           JOIN material m  ON m.mat_id = h.mat
           JOIN light l     ON l.light_id = s.light_id
           LEFT JOIN rt_shadow sh ON sh.hid = s.hid AND sh.light_id = s.light_id
      UNION ALL
      SELECT h.hid, sky_sun(v3(h.dx, h.dy, h.dz), l)
      FROM rt_hit h CROSS JOIN light l
      WHERE h.mat = 0 AND l.sky_k > 0.0
    ) AS p
    GROUP BY hid;
    CREATE INDEX ON rt_rad (hid);
    ANALYZE rt_rad;

    IF p_verbose THEN
      RAISE NOTICE 'lights   : % lit hits in % ms', (SELECT count(*) FROM rt_rad),
        round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
      ts := clock_timestamp();
    END IF;

    -- Radiance per pixel, carrying the sample count that produced it.  The join
    -- is from rt_spp outwards so that a pixel is recorded as having been sampled
    -- even if nothing it fired came back with anything to shade -- which cannot
    -- happen today, since a ray that hits nothing still lands in rt_hit as a sky
    -- row, but it is the direction that fails safe if that ever stops holding.
    INSERT INTO img_acc (px, py, n, r, g, b)
    SELECT s.px, s.py, s.n,
           coalesce(q.sr, 0), coalesce(q.sg, 0), coalesce(q.sb, 0)
    FROM rt_spp s
         LEFT JOIN (
      -- Component sums again, for the reason given at rt_rad -- worth 1.43x
      -- here.  shade() is bound once in the LATERAL rather than named three
      -- times inside the sums, which would call it three times per row and cost
      -- far more than the aggregate ever did.
      SELECT h.px, h.py, sum((sh.c).x), sum((sh.c).y), sum((sh.c).z)
      FROM rt_hit h
           LEFT JOIN material m ON m.mat_id = h.mat
           LEFT JOIN rt_rad e   ON e.hid = h.hid
           CROSS JOIN LATERAL (
             SELECT shade(v3(h.dx, h.dy, h.dz),
                          hit_of(h.t, h.mat, h.hx, h.hy, h.hz,
                                 h.nx, h.ny, h.nz, h.back),
                          v3(h.ax, h.ay, h.az), m,
                          coalesce(e.rad, ROW(0,0,0)::vec3))
             OFFSET 0) AS sh(c)
      GROUP BY h.px, h.py
    ) AS q(px, py, sr, sg, sb) ON q.px = s.px AND q.py = s.py;

    -- Everything this pass built is spent.  A second pass rebuilds all of it
    -- against its own, much smaller, ray population.
    DROP TABLE rt_ray, rt_new, rt_hit, rt_sray, rt_shadow, rt_rad, rt_spp;

    -- The tone curve, over what this pass accumulated.  Dividing by the summed
    -- count rather than multiplying by a precomputed reciprocal is the more
    -- accurate of the two, since 1/(aa*aa) is exact only when aa is a power of
    -- two -- but only in principle: at aa = 3 the frame came back identical
    -- anyway, because a difference of one ulp has to cross an 8-bit rounding
    -- boundary before it can reach a pixel.
    --
    -- Publishing per pass rather than once at the end is what lets the test
    -- below read the image as it will actually be seen -- through the curve,
    -- in 8 bits -- without quantizing the frame a second time.  Pass 2 rewrites
    -- only the pixels it redrew, so the cost is one quantize per pixel plus one
    -- per refined pixel rather than two per pixel.
    DELETE FROM img USING rt_todo td WHERE img.x = td.px AND img.y = td.py;
    INSERT INTO img (x, y, r, g, b)
    SELECT a.px, a.py,
           quantize(sum(a.r) / sum(a.n), exposure),
           quantize(sum(a.g) / sum(a.n), exposure),
           quantize(sum(a.b) / sum(a.n), exposure)
    FROM img_acc a JOIN rt_todo td ON td.px = a.px AND td.py = a.py
    GROUP BY a.px, a.py;

    IF p_verbose THEN
      RAISE NOTICE 'shading  : % ms',
        round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
    END IF;

    EXIT WHEN pass = 2 OR NOT adaptive;

    -- Where the picture is moving faster than one sample per pixel can follow.
    --
    -- The test is local contrast on the displayed image rather than the
    -- variance of the samples within a pixel, and it has to be: at one sample
    -- a pixel has no within-pixel variance to measure.  What its neighbours
    -- say about it is the only evidence a first pass leaves behind, and it is
    -- the right evidence anyway, since aliasing is a disagreement between
    -- adjacent pixels rather than a property of one.
    --
    -- Contrast is measured after the tone curve on purpose.  Two units of
    -- radiance matter enormously in the shadows and not at all inside a
    -- highlight the curve is already compressing, and the curve is exactly the
    -- function that knows which is which.  Spending rays to resolve a
    -- difference that quantizes away is the failure this avoids.
    --
    -- Four offsets rather than eight, because contrast is symmetric: testing
    -- each pair once and marking both ends of it covers the full eight-way
    -- neighbourhood at half the joins.
    ts := clock_timestamp();
    DROP TABLE rt_todo;
    CREATE TEMP TABLE rt_todo AS
    SELECT DISTINCT e.px, e.py, aa AS side
    FROM img a
         CROSS JOIN (VALUES (1, 0), (0, 1), (1, 1), (-1, 1)) AS o(dx, dy)
         JOIN img b ON b.x = a.x + o.dx AND b.y = a.y + o.dy
         CROSS JOIN LATERAL (VALUES (a.x, a.y), (b.x, b.y)) AS e(px, py)
    WHERE greatest(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) > p_refine;
    GET DIAGNOSTICS live = ROW_COUNT;

    IF p_verbose THEN
      RAISE NOTICE 'refine   : % of % px in % ms', live, img_w * img_h,
        round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
    END IF;
    EXIT WHEN live = 0;
    ANALYZE rt_todo;

    -- The coarse sample is thrown away rather than averaged in, and that is
    -- the decision the scheme rests on.  It sits at the pixel centre, and the
    -- grid replacing it has no sample there, so keeping it would weight the
    -- middle of a refined pixel more heavily than the middle of every pixel
    -- around it -- a reconstruction filter that varies across the image
    -- according to how the image happened to come out.
    --
    -- Discarding costs one traced ray per refined pixel and buys an exact
    -- property in return: a refined pixel is bit-for-bit what a uniform render
    -- at this rate would have put there, and an unrefined one is bit-for-bit
    -- the one-sample frame.  The whole feature is then checkable against two
    -- renders that already exist rather than against a tolerance.
    DELETE FROM img_acc a USING rt_todo td WHERE a.px = td.px AND a.py = td.py;
  END LOOP;

  DROP TABLE rt_todo, img_acc;
END $$ LANGUAGE plpgsql;

-- Convenience wrapper: render and hand back the encoded PNG in one call.
CREATE FUNCTION render_png(w int DEFAULT 480, h int DEFAULT 320, aa int DEFAULT 2,
                           maxdepth int DEFAULT 6, exposure float8 DEFAULT 1.35,
                           p_from vec3 DEFAULT cam_from(),
                           p_at vec3 DEFAULT cam_at(),
                           p_fov float8 DEFAULT cam_fov(),
                           p_refine int DEFAULT NULL)
RETURNS bytea AS $$
  SELECT render(w, h, aa, maxdepth, exposure, 0.01, false, p_from, p_at, p_fov,
                p_refine);
  SELECT png_encode(w, h, png_scanlines('img'));
$$ LANGUAGE sql;
