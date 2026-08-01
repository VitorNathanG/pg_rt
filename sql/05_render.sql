-- ---------------------------------------------------------------------------
-- Camera and the render driver.
-- ---------------------------------------------------------------------------

CREATE FUNCTION cam_from() RETURNS vec3   AS $$ SELECT ROW(0.55, 2.35, 6.70)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_at()   RETURNS vec3   AS $$ SELECT ROW(0.05, 1.00, 0.00)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cam_fov()  RETURNS float8 AS $$ SELECT 44.0 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Direction through a point on the image plane.  nx and ny are normalised
-- device coordinates in [-1, 1], with ny pointing up.
-- The basis vectors depend only on IMMUTABLE camera constants, so writing
-- them out as expressions costs nothing at run time: the planner folds the
-- whole basis to three literal vectors before the query executes.
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
-- to 8 bits.  Tone mapping matters here because specular highlights and the
-- sun disc carry radiances well above 1.0 that would otherwise clip to flat
-- white.  The white point keeps plain Reinhard from washing the midtones out:
-- radiance at or above `white` maps to 1.0, and everything below it keeps far
-- more of its contrast than L/(1+L) would leave.
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
-- The entire image is one recursive CTE.  The base term fires aa*aa primary
-- rays per pixel and intersects them; the recursive term repeatedly turns
-- every live hit into its reflected and refracted children and intersects
-- those, until either the depth limit or the throughput floor stops it.
-- Nothing is traced pixel by pixel -- every ray at a given bounce depth is
-- intersected in one set-oriented pass.
-- ---------------------------------------------------------------------------

CREATE FUNCTION render(img_w int, img_h int, aa int DEFAULT 2, maxdepth int DEFAULT 5,
                       exposure float8 DEFAULT 1.35, cutoff float8 DEFAULT 0.01)
RETURNS void AS $$
BEGIN
  DROP TABLE IF EXISTS img;
  CREATE UNLOGGED TABLE img (x int, y int, r int, g int, b int);

  INSERT INTO img (x, y, r, g, b)
  WITH RECURSIVE

  -- Primary rays: one per sub-pixel sample, already intersected.
  prim AS (
    SELECT gx.px, gy.py, cr.dir AS d, beer(sh.hh) AS att, 0 AS chan,
           0 AS depth, sh.hh AS h
    FROM generate_series(0, img_w - 1) AS gx(px),
         generate_series(0, img_h - 1) AS gy(py),
         generate_series(0, aa - 1) AS sx(i),
         generate_series(0, aa - 1) AS sy(j),
         LATERAL (SELECT cam_dir(
                    2.0 * ((gx.px + (sx.i + 0.5) / aa) / img_w) - 1.0,
                    1.0 - 2.0 * ((gy.py + (sy.j + 0.5) / aa) / img_h),
                    img_w::float8 / img_h) OFFSET 0) AS cr(dir),
         LATERAL (SELECT scene_hit(cam_from(), cr.dir) OFFSET 0) AS sh(hh)
  ),

  -- Every bounce, for every pixel, at once.
  --
  -- The OFFSET 0 on each LATERAL is load-bearing, not decoration.  Without it
  -- the planner flattens the subquery and substitutes the function call at
  -- every column that references it -- child_ray is read six times below and
  -- scene_hit twice, so the fence turns eight evaluations back into two.
  trace AS (
      SELECT * FROM prim
    UNION ALL
      SELECT s.px, s.py, s.d, s.att * beer(nh.hh), s.chan, s.depth, nh.hh
      FROM (
        SELECT t.px, t.py, t.depth + 1 AS depth,
               (c.r).o AS o, (c.r).d AS d, (c.r).att AS att, (c.r).chan AS chan
        FROM trace t
             -- Only glass needs the three refraction branches; an opaque
             -- surface spawns nothing but its mirror ray.
             CROSS JOIN LATERAL generate_series(
                 0, CASE WHEN (t.h).obj = obj_cube() THEN 3 ELSE 0 END) AS br(k)
             CROSS JOIN LATERAL (
                 SELECT child_ray(t.d, t.h, t.att, t.chan, br.k) OFFSET 0) AS c(r)
        WHERE t.depth < maxdepth
          AND (t.h).obj <> obj_sky()
          AND (c.r).d IS NOT NULL
          AND v3_maxc((c.r).att) > cutoff
      ) AS s
      CROSS JOIN LATERAL (SELECT scene_hit(s.o, s.d) OFFSET 0) AS nh(hh)
  )

  SELECT px, py,
         quantize((col).x, exposure),
         quantize((col).y, exposure),
         quantize((col).z, exposure)
  FROM (
    SELECT px, py, sum(shade(d, h, att)) * (1.0 / (aa * aa)) AS col
    FROM trace
    GROUP BY px, py
  ) AS q;
END $$ LANGUAGE plpgsql;

-- Convenience wrapper: render and hand back the encoded PNG in one call.
CREATE FUNCTION render_png(w int DEFAULT 480, h int DEFAULT 320, aa int DEFAULT 2,
                           maxdepth int DEFAULT 6, exposure float8 DEFAULT 1.35)
RETURNS bytea AS $$
  SELECT render(w, h, aa, maxdepth, exposure);
  SELECT png_encode(w, h, png_scanlines('img'));
$$ LANGUAGE sql;
