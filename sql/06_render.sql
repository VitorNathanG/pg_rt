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
-- ---------------------------------------------------------------------------

CREATE FUNCTION render(img_w int, img_h int, aa int DEFAULT 2, maxdepth int DEFAULT 5,
                       exposure float8 DEFAULT 1.35, cutoff float8 DEFAULT 0.01,
                       p_verbose boolean DEFAULT false,
                       p_from vec3 DEFAULT cam_from(),
                       p_at vec3 DEFAULT cam_at(),
                       p_fov float8 DEFAULT cam_fov())
RETURNS void AS $$
DECLARE
  dep  int;
  live bigint;
  ts   timestamptz;
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

  DROP TABLE IF EXISTS img;
  CREATE UNLOGGED TABLE img (x int, y int, r int, g int, b int);

  DROP TABLE IF EXISTS rt_ray;
  DROP TABLE IF EXISTS rt_new;
  DROP TABLE IF EXISTS rt_hit;
  DROP TABLE IF EXISTS rt_sray;
  DROP TABLE IF EXISTS rt_shadow;
  DROP TABLE IF EXISTS rt_rad;

  -- The planner decides how many workers to give a scan from how many PAGES
  -- it holds, which is exactly the wrong measure here: a ray table is small
  -- but every row costs thousands of arithmetic operations in a function
  -- call.  Left at the defaults the intersection is planned single-threaded.
  SET LOCAL min_parallel_table_scan_size = 0;
  SET LOCAL parallel_setup_cost = 100;

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
  CREATE UNLOGGED TABLE rt_hit (
    hid  bigserial,
    px   int,    py int,                    -- pixel this ray belongs to
    mat  int,    back boolean,              -- from the hit record; see below
    dx   float8, dy float8, dz float8,      -- ray direction
    ax   float8, ay float8, az float8,      -- attenuation carried to this hit
    t    float8,                            -- and the rest of the hit record:
    hx   float8, hy float8, hz float8,      -- point,
    nx   float8, ny float8, nz float8);     -- and shading normal

  -- Every ray set is built with CREATE TABLE AS rather than INSERT INTO.
  -- PostgreSQL refuses to parallelise any statement that writes, and CTAS is
  -- the one exception: the identical query gets a Gather as a CTAS and none
  -- at all as an INSERT ... SELECT.  Worth about 9% here -- the planner still
  -- assigns only one worker, because it sizes workers by page count and a ray
  -- table is small no matter how much arithmetic each row costs.
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
  CREATE UNLOGGED TABLE rt_ray AS
  SELECT row_number() OVER () AS rid, gx.px, gy.py,
         p_from AS o, cr.dir AS d,
         (p_from).x AS ox, (p_from).y AS oy, (p_from).z AS oz,
         (cr.dir).x AS dx, (cr.dir).y AS dy, (cr.dir).z AS dz,
         (v3_inv(cr.dir)).x AS ivx, (v3_inv(cr.dir)).y AS ivy,
         (v3_inv(cr.dir)).z AS ivz,
         ROW(1,1,1)::vec3 AS att, 0 AS chan
  FROM generate_series(0, img_w - 1) AS gx(px),
       generate_series(0, img_h - 1) AS gy(py),
       generate_series(0, aa - 1) AS sx(i),
       generate_series(0, aa - 1) AS sy(j),
       -- The device coordinates are materialised before cam_dir sees them,
       -- and that is load-bearing rather than tidy.  cam_dir's body reaches
       -- v3_unit, which names each component three times; spelled inline
       -- these two expressions push that argument past the point where
       -- PostgreSQL will inline, and the camera ray costs a whole executor
       -- run per sample.  As Vars they cost nothing to duplicate and the
       -- entire camera folds to arithmetic over literals.
       LATERAL (SELECT 2.0 * ((gx.px + (sx.i + 0.5) / aa) / img_w) - 1.0,
                       1.0 - 2.0 * ((gy.py + (sy.j + 0.5) / aa) / img_h)
                OFFSET 0) AS nd(nx, ny),
       LATERAL (SELECT cam_dir(nd.nx, nd.ny, img_w::float8 / img_h,
                               cu, cv, cw, cth)
                OFFSET 0) AS cr(dir);
  ALTER TABLE rt_ray SET (parallel_workers = 4);
  ANALYZE rt_ray;

  FOR dep IN 0 .. maxdepth LOOP
    ts := clock_timestamp();

    -- Intersect every live ray at once.  Three levels of box, one join each:
    -- the mesh box rejects whole objects, the BVH leaf rejects clusters of
    -- triangles, the triangle's own box rejects the triangle, and only what
    -- survives all three reaches tri_hit.
    DROP TABLE IF EXISTS rt_new;
    CREATE UNLOGGED TABLE rt_new AS
    WITH best AS (
      SELECT r.rid, nearest(ROW(x.t, t.tri_id)::cand) AS c
      FROM rt_ray r
           JOIN mesh_box mb ON box_hit(r.ox, r.oy, r.oz, r.ivx, r.ivy, r.ivz,
                                       mb.lox, mb.loy, mb.loz,
                                       mb.hix, mb.hiy, mb.hiz)
           JOIN bvh_node n  ON n.mesh_id = mb.mesh_id
                           AND box_hit(r.ox, r.oy, r.oz, r.ivx, r.ivy, r.ivz,
                                       n.lox, n.loy, n.loz, n.hix, n.hiy, n.hiz)
           JOIN tri t       ON t.cl = n.cl
                           AND box_hit(r.ox, r.oy, r.oz, r.ivx, r.ivy, r.ivz,
                                       t.lox, t.loy, t.loz, t.hix, t.hiy, t.hiz)
           CROSS JOIN LATERAL (
             SELECT tri_hit(r.ox, r.oy, r.oz, r.dx, r.dy, r.dz,
                            t.ax, t.ay, t.az, t.e1x, t.e1y, t.e1z,
                            t.e2x, t.e2y, t.e2z, t.gnx, t.gny, t.gnz)
             OFFSET 0) AS x(t)
      WHERE x.t IS NOT NULL
      GROUP BY r.rid
    )
    SELECT r.px, r.py, r.d, r.att * beer(hh.h, m) AS att, r.chan, hh.h
    FROM rt_ray r
         LEFT JOIN best b   ON b.rid = r.rid
         LEFT JOIN tri t    ON t.tri_id = (b.c).tri_id
         LEFT JOIN mesh ms  ON ms.mesh_id = t.mesh_id
         LEFT JOIN material m ON m.mat_id = ms.mat_id
         CROSS JOIN LATERAL (
           SELECT make_hit(r.o, r.d, b.c, t, coalesce(m.mat_id, 0)) OFFSET 0) AS hh(h);
    ALTER TABLE rt_new SET (parallel_workers = 4);
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
    CREATE UNLOGGED TABLE rt_ray AS
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
    ALTER TABLE rt_ray SET (parallel_workers = 4);
    ANALYZE rt_ray;
  END LOOP;

  -- Shadow rays, also in one pass -- one per (hit, light) pair that the light
  -- in question could actually show on.  The pair, not the hit, is the unit of
  -- work from here down: a scene with three lights fires three shadow rays at
  -- an open floor and none at all at a wall facing away from all three.
  ts := clock_timestamp();
  CREATE UNLOGGED TABLE rt_sray AS
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
  ALTER TABLE rt_sray SET (parallel_workers = 4);
  ANALYZE rt_sray;

  -- Transmission toward the light, per blocking mesh.  An opaque mesh stops
  -- the ray outright; a dielectric dims and tints it by Beer-Lambert over the
  -- thickness actually traversed, which for a closed mesh is the span between
  -- the ray's first and last crossing of it.  Not a real caustic, but it
  -- keeps glass from casting the flat black hole a binary test would give it.
  CREATE UNLOGGED TABLE rt_shadow AS
  WITH blocker AS (
    SELECT s.hid, s.light_id, n.mesh_id, mm.kind, mm.absorb,
           min(x.t) AS t0, max(x.t) AS t1
    FROM rt_sray s
         JOIN mesh_box mb ON box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                     mb.lox, mb.loy, mb.loz,
                                     mb.hix, mb.hiy, mb.hiz)
         JOIN bvh_node n  ON n.mesh_id = mb.mesh_id
                         AND box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                     n.lox, n.loy, n.loz, n.hix, n.hiy, n.hiz)
         JOIN tri t       ON t.cl = n.cl
                         AND box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                     t.lox, t.loy, t.loz, t.hix, t.hiy, t.hiz)
         JOIN mesh ms     ON ms.mesh_id = n.mesh_id
         JOIN material mm ON mm.mat_id = ms.mat_id
         CROSS JOIN LATERAL (
           SELECT tri_hit(s.ox, s.oy, s.oz, s.dx, s.dy, s.dz,
                          t.ax, t.ay, t.az, t.e1x, t.e1y, t.e1z,
                          t.e2x, t.e2y, t.e2z, t.gnx, t.gny, t.gnz)
           OFFSET 0) AS x(t)
    WHERE x.t IS NOT NULL AND x.t < s.dist
    GROUP BY s.hid, s.light_id, n.mesh_id, mm.kind, mm.absorb
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
  CREATE UNLOGGED TABLE rt_rad AS
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

  INSERT INTO img (x, y, r, g, b)
  SELECT px, py,
         quantize((col).x, exposure),
         quantize((col).y, exposure),
         quantize((col).z, exposure)
  FROM (
    -- Component sums again, for the reason given at rt_rad -- worth 1.43x
    -- here.  shade() is bound once in the LATERAL rather than named three
    -- times inside the sums, which would call it three times per row and cost
    -- far more than the aggregate ever did.
    SELECT h.px, h.py,
           ROW(sum((sh.c).x), sum((sh.c).y), sum((sh.c).z))::vec3
             * (1.0 / (aa * aa)) AS col
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
  ) AS q;

  IF p_verbose THEN
    RAISE NOTICE 'shading  : % ms',
      round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
  END IF;

  DROP TABLE rt_ray, rt_new, rt_hit, rt_sray, rt_shadow, rt_rad;
END $$ LANGUAGE plpgsql;

-- Convenience wrapper: render and hand back the encoded PNG in one call.
CREATE FUNCTION render_png(w int DEFAULT 480, h int DEFAULT 320, aa int DEFAULT 2,
                           maxdepth int DEFAULT 6, exposure float8 DEFAULT 1.35,
                           p_from vec3 DEFAULT cam_from(),
                           p_at vec3 DEFAULT cam_at(),
                           p_fov float8 DEFAULT cam_fov())
RETURNS bytea AS $$
  SELECT render(w, h, aa, maxdepth, exposure, 0.01, false, p_from, p_at, p_fov);
  SELECT png_encode(w, h, png_scanlines('img'));
$$ LANGUAGE sql;
