-- ---------------------------------------------------------------------------
-- Camera and the render driver.
-- ---------------------------------------------------------------------------

CREATE FUNCTION cam_from() RETURNS vec3   AS $$ SELECT ROW(0.55, 2.35, 6.70)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_at()   RETURNS vec3   AS $$ SELECT ROW(0.05, 1.00, 0.00)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_fov()  RETURNS float8 AS $$ SELECT 44.0 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Direction through a point on the image plane.  nx and ny are normalised
-- device coordinates in [-1, 1], with ny pointing up.  The basis depends only
-- on IMMUTABLE constants, so the planner folds it to three literal vectors
-- before the query executes.
CREATE FUNCTION cam_w() RETURNS vec3
  AS $$ SELECT v3_unit(cam_from() - cam_at()) $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_u() RETURNS vec3
  AS $$ SELECT v3_unit(v3_cross(ROW(0,1,0)::vec3, cam_w())) $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_v() RETURNS vec3
  AS $$ SELECT v3_cross(cam_w(), cam_u()) $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION cam_dir(nx float8, ny float8, aspect float8) RETURNS vec3 AS $$
  SELECT v3_unit(cam_u() * (nx * aspect * tan(radians(cam_fov()) / 2.0))
               + cam_v() * (ny * tan(radians(cam_fov()) / 2.0))
               - cam_w())
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Extended Reinhard tone mapping followed by a gamma 2.2 transfer, quantised
-- to 8 bits.  The white point keeps plain Reinhard from washing the midtones
-- out: radiance at or above `white` maps to 1.0, and everything below it
-- keeps far more of its contrast than L/(1+L) would leave.
CREATE FUNCTION tone_white() RETURNS float8
  AS $$ SELECT 3.4 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION quantize(v float8, exposure float8) RETURNS int AS $$
  SELECT least(255, greatest(0, round(255.0 * pow_safe(
           greatest(v, 0.0) * exposure
             * (1.0 + greatest(v, 0.0) * exposure / (tone_white() * tone_white()))
             / (1.0 + greatest(v, 0.0) * exposure),
           1.0 / 2.2))::int))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

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
                       p_verbose boolean DEFAULT false)
RETURNS void AS $$
DECLARE
  dep  int;
  live bigint;
  ts   timestamptz;
BEGIN
  DROP TABLE IF EXISTS img;
  CREATE UNLOGGED TABLE img (x int, y int, r int, g int, b int);

  DROP TABLE IF EXISTS rt_ray;
  DROP TABLE IF EXISTS rt_new;
  DROP TABLE IF EXISTS rt_hit;
  DROP TABLE IF EXISTS rt_sray;
  DROP TABLE IF EXISTS rt_shadow;

  -- The planner decides how many workers to give a scan from how many PAGES
  -- it holds, which is exactly the wrong measure here: a ray table is small
  -- but every row costs thousands of arithmetic operations in a function
  -- call.  Left at the defaults the intersection is planned single-threaded.
  SET LOCAL min_parallel_table_scan_size = 0;
  SET LOCAL parallel_setup_cost = 100;

  CREATE UNLOGGED TABLE rt_hit (
    hid bigserial, px int, py int, d vec3, att vec3, h hit);

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
         cam_from() AS o, cr.dir AS d,
         (cam_from()).x AS ox, (cam_from()).y AS oy, (cam_from()).z AS oz,
         (cr.dir).x AS dx, (cr.dir).y AS dy, (cr.dir).z AS dz,
         (v3_inv(cr.dir)).x AS ivx, (v3_inv(cr.dir)).y AS ivy,
         (v3_inv(cr.dir)).z AS ivz,
         ROW(1,1,1)::vec3 AS att, 0 AS chan
  FROM generate_series(0, img_w - 1) AS gx(px),
       generate_series(0, img_h - 1) AS gy(py),
       generate_series(0, aa - 1) AS sx(i),
       generate_series(0, aa - 1) AS sy(j),
       LATERAL (SELECT cam_dir(
                  2.0 * ((gx.px + (sx.i + 0.5) / aa) / img_w) - 1.0,
                  1.0 - 2.0 * ((gy.py + (sy.j + 0.5) / aa) / img_h),
                  img_w::float8 / img_h) OFFSET 0) AS cr(dir);
  ALTER TABLE rt_ray SET (parallel_workers = 4);
  ANALYZE rt_ray;

  FOR dep IN 0 .. maxdepth LOOP
    ts := clock_timestamp();

    -- Intersect every live ray at once.  The mesh box rejects whole objects,
    -- the BVH leaf rejects clusters of triangles, and only what survives both
    -- reaches tri_hit.
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

    INSERT INTO rt_hit (px, py, d, att, h)
    SELECT px, py, d, att, h FROM rt_new;

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

  -- Shadow rays, also in one pass.  Only hits where the key light could
  -- actually show get one.
  ts := clock_timestamp();
  CREATE UNLOGGED TABLE rt_sray AS
  SELECT h.hid,
         (so.p).x AS ox, (so.p).y AS oy, (so.p).z AS oz,
         (sl.ld).x AS dx, (sl.ld).y AS dy, (sl.ld).z AS dz,
         1.0 / nz((sl.ld).x) AS ivx, 1.0 / nz((sl.ld).y) AS ivy,
         1.0 / nz((sl.ld).z) AS ivz, dd.dist
  FROM rt_hit h
       JOIN material m ON m.mat_id = (h.h).mat
       CROSS JOIN LATERAL (SELECT (h.h).p + (h.h).n * 1e-3 OFFSET 0) AS so(p)
       CROSS JOIN LATERAL (SELECT light_p() - (h.h).p OFFSET 0) AS lv(v)
       CROSS JOIN LATERAL (SELECT v3_len(lv.v) OFFSET 0) AS dd(dist)
       CROSS JOIN LATERAL (SELECT lv.v * (1.0 / dd.dist) OFFSET 0) AS sl(ld)
  WHERE wants_light(h.d, h.h, m);
  ALTER TABLE rt_sray SET (parallel_workers = 4);
  ANALYZE rt_sray;

  -- Transmission toward the light, per blocking mesh.  An opaque mesh stops
  -- the ray outright; a dielectric dims and tints it by Beer-Lambert over the
  -- thickness actually traversed, which for a closed mesh is the span between
  -- the ray's first and last crossing of it.  Not a real caustic, but it
  -- keeps glass from casting the flat black hole a binary test would give it.
  CREATE UNLOGGED TABLE rt_shadow AS
  WITH blocker AS (
    SELECT s.hid, n.mesh_id, mm.kind, mm.absorb,
           min(x.t) AS t0, max(x.t) AS t1
    FROM rt_sray s
         JOIN mesh_box mb ON box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                     mb.lox, mb.loy, mb.loz,
                                     mb.hix, mb.hiy, mb.hiz)
         JOIN bvh_node n  ON n.mesh_id = mb.mesh_id
                         AND box_hit(s.ox, s.oy, s.oz, s.ivx, s.ivy, s.ivz,
                                     n.lox, n.loy, n.loz, n.hix, n.hiy, n.hiz)
         JOIN tri t       ON t.cl = n.cl
         JOIN mesh ms     ON ms.mesh_id = n.mesh_id
         JOIN material mm ON mm.mat_id = ms.mat_id
         CROSS JOIN LATERAL (
           SELECT tri_hit(s.ox, s.oy, s.oz, s.dx, s.dy, s.dz,
                          t.ax, t.ay, t.az, t.e1x, t.e1y, t.e1z,
                          t.e2x, t.e2y, t.e2z, t.gnx, t.gny, t.gnz)
           OFFSET 0) AS x(t)
    WHERE x.t IS NOT NULL AND x.t < s.dist
    GROUP BY s.hid, n.mesh_id, mm.kind, mm.absorb
  )
  SELECT hid,
         CASE WHEN bool_or(kind <> mat_glass()) THEN ROW(0, 0, 0)::vec3
              ELSE ROW(exp(-sum((absorb).x * (t1 - t0))),
                       exp(-sum((absorb).y * (t1 - t0))),
                       exp(-sum((absorb).z * (t1 - t0))))::vec3 * 0.82
         END AS att
  FROM blocker GROUP BY hid;

  CREATE INDEX ON rt_shadow (hid);
  ANALYZE rt_shadow;

  IF p_verbose THEN
    RAISE NOTICE 'shadows  : % rays in % ms', (SELECT count(*) FROM rt_sray),
      round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
    ts := clock_timestamp();
  END IF;

  INSERT INTO img (x, y, r, g, b)
  SELECT px, py,
         quantize((col).x, exposure),
         quantize((col).y, exposure),
         quantize((col).z, exposure)
  FROM (
    SELECT h.px, h.py,
           sum(shade(h.d, h.h, h.att, m,
                     coalesce(sh.att, ROW(1,1,1)::vec3))) * (1.0 / (aa * aa)) AS col
    FROM rt_hit h
         LEFT JOIN material m  ON m.mat_id = (h.h).mat
         LEFT JOIN rt_shadow sh ON sh.hid = h.hid
    GROUP BY h.px, h.py
  ) AS q;

  IF p_verbose THEN
    RAISE NOTICE 'shading  : % ms',
      round(extract(epoch FROM clock_timestamp() - ts)::numeric * 1000);
  END IF;

  DROP TABLE rt_ray, rt_new, rt_hit, rt_sray, rt_shadow;
END $$ LANGUAGE plpgsql;

-- Convenience wrapper: render and hand back the encoded PNG in one call.
CREATE FUNCTION render_png(w int DEFAULT 480, h int DEFAULT 320, aa int DEFAULT 2,
                           maxdepth int DEFAULT 6, exposure float8 DEFAULT 1.35)
RETURNS bytea AS $$
  SELECT render(w, h, aa, maxdepth, exposure);
  SELECT png_encode(w, h, png_scanlines('img'));
$$ LANGUAGE sql;
