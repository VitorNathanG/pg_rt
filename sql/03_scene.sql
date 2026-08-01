-- ---------------------------------------------------------------------------
-- The scene: a checkered ground plane, a metal sphere, a glass cube.
--
-- Geometry is baked into the intersection routines rather than stored in a
-- table.  Three objects do not need a spatial index, and keeping the shapes
-- as inlinable expressions lets the planner fold them into the tracing query
-- instead of paying a function call per ray per object.
-- ---------------------------------------------------------------------------

-- Object ids, as returned by scene_hit().
--   0 = miss (ray escapes to the sky)
--   1 = ground plane
--   2 = metal sphere
--   3 = glass cube
CREATE FUNCTION obj_sky()    RETURNS int AS $$ SELECT 0 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION obj_plane()  RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION obj_sphere() RETURNS int AS $$ SELECT 2 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION obj_cube()   RETURNS int AS $$ SELECT 3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Scene constants.  Written as IMMUTABLE zero-argument functions so they can
-- be referenced by name from the tracing expressions and still be constant
-- folded by the planner.
CREATE FUNCTION sph_c() RETURNS vec3   AS $$ SELECT ROW(-1.15, 1.00, -0.20)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION sph_r() RETURNS float8 AS $$ SELECT 1.00 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION cub_c()   RETURNS vec3   AS $$ SELECT ROW(1.35, 0.85, 0.55)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cub_h()   RETURNS float8 AS $$ SELECT 0.85 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION cub_yaw() RETURNS float8 AS $$ SELECT 0.42 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;  -- radians

-- Key light, and the sun disc that the sky paints in the same direction so
-- reflections stay consistent with the shading.
--
-- Placed behind and to the side of the subjects rather than over the camera's
-- shoulder: a frontal light throws every shadow behind the object that casts
-- it, where the object itself hides it, and the render comes out looking flat.
-- From back-right the shadows rake across the floor toward the viewer, and the
-- glass gets lit from behind.
CREATE FUNCTION light_p()   RETURNS vec3   AS $$ SELECT ROW(5.2, 4.6, -2.4)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION light_col() RETURNS vec3   AS $$ SELECT ROW(1.00, 0.96, 0.88)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION light_pow() RETURNS float8 AS $$ SELECT 125.0 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Dispersion: index of refraction per channel.  Crown glass is more strongly
-- bent at the blue end than the red, which is what splits white light into a
-- spectrum at every non-normal incidence.  Exaggerated here so the effect is
-- visible at this resolution.
CREATE FUNCTION glass_ior(chan int) RETURNS float8
  AS $$ SELECT CASE chan WHEN 1 THEN 1.470 WHEN 2 THEN 1.530 WHEN 3 THEN 1.605
                         ELSE 1.530 END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Beer-Lambert absorption coefficients: how much of each channel is lost per
-- unit distance travelled inside the glass.  A faint cyan cast.
CREATE FUNCTION glass_absorb() RETURNS vec3
  AS $$ SELECT ROW(0.28, 0.14, 0.16)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Ceiling on the ground plane's Fresnel reflectance.  Physically it should
-- approach 1 at grazing incidence, but an unclamped mirror floor reflects the
-- bright uniform sky across the whole lower frame and erases its own shadows.
CREATE FUNCTION floor_kr_max() RETURNS float8
  AS $$ SELECT 0.17 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION metal_tint() RETURNS vec3
  AS $$ SELECT ROW(0.96, 0.93, 0.86)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Ray/shape intersections.  Each returns the smallest t > EPS along the ray,
-- or NULL for a miss.  Directions are assumed unit length, so t is a distance.
-- ---------------------------------------------------------------------------

CREATE FUNCTION rt_eps() RETURNS float8 AS $$ SELECT 1e-4 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Ground plane y = 0.
CREATE FUNCTION hit_plane(o vec3, d vec3) RETURNS float8
  AS $$ SELECT CASE WHEN d.y < -1e-9 AND -o.y / d.y > 1e-4
                    THEN -o.y / d.y END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Sphere, solved as a quadratic in t with b halved.
--
-- PL/pgSQL rather than SQL: the discriminant and the two roots are each used
-- more than once, and a SQL body would re-evaluate the entire subexpression
-- at every reference.  A local variable is computed exactly once.
CREATE FUNCTION hit_sphere(o vec3, d vec3, c vec3, r float8) RETURNS float8 AS $$
DECLARE
  oc   vec3   := o - c;
  b    float8 := v3_dot(oc, d);
  disc float8 := b * b - (v3_dot(oc, oc) - r * r);
  sq   float8;
  t    float8;
BEGIN
  IF disc < 0.0 THEN RETURN NULL; END IF;
  sq := sqrt(disc);
  t := -b - sq;
  IF t > 1e-4 THEN RETURN t; END IF;
  t := -b + sq;
  IF t > 1e-4 THEN RETURN t; END IF;
  RETURN NULL;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- The cube is an axis-aligned box in its own frame, rotated about Y by
-- cub_yaw().  Rather than intersect a general oriented box, the ray is
-- carried into the box's local frame, tested with the classic slab method,
-- and the resulting normal is rotated back out.
-- ---------------------------------------------------------------------------

-- Rotate about the Y axis by -yaw (world -> cube local).
CREATE FUNCTION to_cube(v vec3) RETURNS vec3
  AS $$ SELECT ROW(v.x * cos(cub_yaw()) - v.z * sin(cub_yaw()),
                   v.y,
                   v.x * sin(cub_yaw()) + v.z * cos(cub_yaw()))::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Rotate about the Y axis by +yaw (cube local -> world).
CREATE FUNCTION from_cube(v vec3) RETURNS vec3
  AS $$ SELECT ROW( v.x * cos(cub_yaw()) + v.z * sin(cub_yaw()),
                    v.y,
                   -v.x * sin(cub_yaw()) + v.z * cos(cub_yaw()))::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Guard against division by an exactly axis-parallel direction component.
-- Substituting a tiny value rather than NULL keeps the slab arithmetic
-- branch-free: the resulting +/-huge interval either swallows the axis (ray
-- inside the slab) or inverts tmin/tmax into a miss (ray outside it), which
-- is precisely the right answer in both cases.
CREATE FUNCTION nz(v float8) RETURNS float8
  AS $$ SELECT CASE WHEN abs(v) < 1e-12 THEN 1e-12 ELSE v END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Slab test.  Returns the near hit when the ray starts outside, and the far
-- hit when it starts inside -- which is exactly what a refracted ray needs in
-- order to find its own exit face.
CREATE FUNCTION hit_cube(o vec3, d vec3) RETURNS float8 AS $$
DECLARE
  lo   vec3   := to_cube(o - cub_c());
  ld   vec3   := to_cube(d);
  e    float8 := cub_h();
  tmin float8;
  tmax float8;
  a    float8;
  b    float8;
BEGIN
  a := (-e - lo.x) / nz(ld.x);  b := (e - lo.x) / nz(ld.x);
  tmin := least(a, b);          tmax := greatest(a, b);

  a := (-e - lo.y) / nz(ld.y);  b := (e - lo.y) / nz(ld.y);
  tmin := greatest(tmin, least(a, b));
  tmax := least(tmax, greatest(a, b));

  a := (-e - lo.z) / nz(ld.z);  b := (e - lo.z) / nz(ld.z);
  tmin := greatest(tmin, least(a, b));
  tmax := least(tmax, greatest(a, b));

  IF tmax < tmin OR tmax <= 1e-4 THEN RETURN NULL; END IF;
  IF tmin > 1e-4 THEN RETURN tmin; END IF;
  RETURN tmax;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- Outward normal of the cube at a world-space surface point: in local space
-- the coordinate closest to its face plane names the face.
CREATE FUNCTION cube_normal(p vec3) RETURNS vec3 AS $$
DECLARE
  lp vec3   := to_cube(p - cub_c());
  e  float8 := cub_h();
  dx float8;
  dy float8;
  dz float8;
BEGIN
  dx := abs(abs(lp.x) - e);
  dy := abs(abs(lp.y) - e);
  dz := abs(abs(lp.z) - e);
  IF dx <= dy AND dx <= dz THEN RETURN from_cube(ROW(sign(lp.x), 0, 0)::vec3); END IF;
  IF dy <= dz            THEN RETURN from_cube(ROW(0, sign(lp.y), 0)::vec3); END IF;
  RETURN from_cube(ROW(0, 0, sign(lp.z))::vec3);
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- scene_hit: nearest intersection over the whole scene.
--
-- The normal is returned already flipped to face the incoming ray, with a
-- separate `back` flag recording whether the original geometric normal
-- pointed away -- the refraction code needs to know which side of the glass
-- it is standing on.
-- ---------------------------------------------------------------------------

CREATE TYPE hit AS (
  t    float8,   -- distance along the ray
  obj  int,      -- obj_* id, 0 for a miss
  p    vec3,     -- world-space hit point
  n    vec3,     -- normal, oriented against the incoming ray
  back boolean   -- true when the ray struck the inside of the surface
);

CREATE FUNCTION scene_hit(o vec3, d vec3) RETURNS hit AS $$
DECLARE
  tp float8 := hit_plane(o, d);
  ts float8 := hit_sphere(o, d, sph_c(), sph_r());
  tc float8 := hit_cube(o, d);
  t  float8 := least(tp, ts, tc);      -- least() ignores NULLs, so a miss is NULL
  ob int;
  p  vec3;
  gn vec3;
  bk boolean;
BEGIN
  IF t IS NULL THEN
    RETURN ROW(0.0, obj_sky(), o, -d, false)::hit;
  END IF;

  p := o + d * t;
  IF    t = tp THEN ob := obj_plane();  gn := ROW(0, 1, 0)::vec3;
  ELSIF t = ts THEN ob := obj_sphere(); gn := v3_unit(p - sph_c());
  ELSE              ob := obj_cube();   gn := cube_normal(p);
  END IF;

  bk := v3_dot(d, gn) > 0.0;
  RETURN ROW(t, ob, p, CASE WHEN bk THEN -gn ELSE gn END, bk)::hit;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Sky: a horizon-to-zenith gradient with a sun disc placed in the direction
-- of the key light, so mirrors show a highlight that agrees with the shading.
-- ---------------------------------------------------------------------------

CREATE FUNCTION sky_bg(d vec3) RETURNS vec3 AS $$
  SELECT ROW(0.20, 0.40, 0.86)::vec3 * greatest(d.y, 0.0)
       + ROW(0.62, 0.76, 0.94)::vec3 * (1.0 - greatest(d.y, 0.0))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION sky(d vec3) RETURNS vec3 AS $$
  SELECT sky_bg(d) + light_col()
       * (22.0 * pow_safe(greatest(v3_dot(d, v3_unit(light_p())), 0.0), 420.0))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Checkerboard albedo, fading to a flat tone with distance so the pattern
-- does not alias into noise near the horizon.
CREATE FUNCTION floor_mix(p vec3) RETURNS float8 AS $$
  SELECT CASE WHEN (floor(p.x) + floor(p.z))::int % 2 = 0 THEN 1.0 ELSE 0.0 END
              * (1.0 - least(1.0, greatest(0.0, (v3_len(p) - 14.0) / 22.0)))
       + 0.5 * least(1.0, greatest(0.0, (v3_len(p) - 14.0) / 22.0))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION floor_albedo(p vec3) RETURNS vec3 AS $$
  SELECT ROW(0.90, 0.89, 0.86)::vec3 * floor_mix(p)
       + ROW(0.16, 0.17, 0.21)::vec3 * (1.0 - floor_mix(p))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
