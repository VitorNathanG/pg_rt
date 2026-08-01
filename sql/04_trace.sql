-- ---------------------------------------------------------------------------
-- Light transport.
--
-- The tracer is a recursive CTE over *hit records* rather than over rays: a
-- row is a ray that has already found its surface.  That framing means each
-- ray is intersected exactly once, and the shading at a hit can be evaluated
-- with the geometry already in hand.
--
-- Each row spawns up to four children, indexed by a branch number k:
--
--   k = 0   specular reflection            (every surface)
--   k = 1   refraction, red   channel      (glass only)
--   k = 2   refraction, green channel      (glass only)
--   k = 3   refraction, blue  channel      (glass only)
--
-- Splitting refraction three ways is what produces dispersion.  A ray carries
-- a `chan` tag: 0 means it still represents all three wavelengths, 1-3 mean it
-- has been committed to one.  White light entering the glass splits into three
-- rays that then follow measurably different paths, because the index of
-- refraction differs per channel -- so the cube throws coloured fringes rather
-- than a grey silhouette.
--
-- Anything below that reuses an intermediate value is written in PL/pgSQL.  A
-- SQL function body is macro-expanded into the caller, so a value referenced
-- n times is *computed* n times, and that factor compounds through every level
-- of nesting.  Local variables make each intermediate cost exactly once.
-- ---------------------------------------------------------------------------

-- Fresnel reflectance at a dielectric boundary.  eta = n_from / n_into and
-- cosi = -dot(d, n) on the incident side.  Returns 1.0 under total internal
-- reflection, which lets a single scalar drive both branches: the reflection
-- child inherits all the energy exactly when refraction is impossible.
--
-- Schlick's approximation is only accurate from the thin side, so when the ray
-- is leaving the denser medium the transmitted cosine is substituted -- that
-- substitution is what makes the inside of the glass mirror at grazing angles.
CREATE FUNCTION fresnel_dielectric(cosi float8, eta float8) RETURNS float8 AS $$
  SELECT CASE
    WHEN eta * eta * (1.0 - cosi * cosi) >= 1.0 THEN 1.0
    ELSE fresnel_schlick(
           least(cosi, sqrt(greatest(1.0 - eta * eta * (1.0 - cosi * cosi), 0.0))),
           (eta - 1.0) * (eta - 1.0) / ((eta + 1.0) * (eta + 1.0)))
  END $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Metals reflect with a per-channel tint, so their Fresnel term is a vec3
-- whose normal-incidence value is the tint itself.
CREATE FUNCTION fresnel_metal(cosi float8, tint vec3) RETURNS vec3 AS $$
  SELECT tint + (ROW(1, 1, 1)::vec3 - tint) * pow_safe(1.0 - cosi, 5.0)
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Beer-Lambert transmission along the segment that terminated at h.  Because
-- the cube is convex and nothing else lives inside it, a ray was travelling
-- through glass exactly when it struck the cube from the back side.
CREATE FUNCTION beer(h hit) RETURNS vec3 AS $$
  SELECT CASE WHEN h.obj = 3 AND h.back
              THEN ROW(exp(-(glass_absorb()).x * h.t),
                       exp(-(glass_absorb()).y * h.t),
                       exp(-(glass_absorb()).z * h.t))::vec3
              ELSE ROW(1, 1, 1)::vec3
         END $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Channel isolation mask for a dispersed ray.
CREATE FUNCTION chan_mask(c int) RETURNS vec3
  AS $$ SELECT CASE c WHEN 1 THEN ROW(1,0,0)::vec3
                      WHEN 2 THEN ROW(0,1,0)::vec3
                      WHEN 3 THEN ROW(0,0,1)::vec3
                      ELSE        ROW(1,1,1)::vec3 END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Shadows.
--
-- Returns a per-channel transmission factor toward the light rather than a
-- boolean.  The metal sphere blocks outright; the glass cube instead tints and
-- dims what passes through it, using the actual traversed thickness.  It is
-- not a real caustic, but it keeps the cube from casting the flat black hole
-- that a binary shadow test would give a transparent object.
-- ---------------------------------------------------------------------------

CREATE FUNCTION shadow_att(p vec3, ld vec3, dist float8) RETURNS vec3 AS $$
DECLARE
  t  float8;
  th float8;
  a  vec3;
BEGIN
  t := hit_sphere(p, ld, sph_c(), sph_r());
  IF t IS NOT NULL AND t < dist THEN RETURN ROW(0, 0, 0)::vec3; END IF;

  t := hit_cube(p, ld);
  IF t IS NULL OR t >= dist THEN RETURN ROW(1, 1, 1)::vec3; END IF;

  -- Thickness: step just past the entry face and find the exit face.
  th := coalesce(hit_cube(p + ld * (t + 1e-3), ld), 0.0);
  a  := glass_absorb();
  RETURN ROW(exp(-a.x * th), exp(-a.y * th), exp(-a.z * th))::vec3 * 0.82;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- shade: the radiance a hit contributes directly, already weighted by the
-- throughput `att` that the ray carried to get here.  Energy that continues
-- via reflection or refraction is *not* counted here -- the child rows carry
-- it, and the final sum over all rows of a pixel adds the two together.
-- ---------------------------------------------------------------------------

CREATE FUNCTION shade(d vec3, h hit, att vec3) RETURNS vec3 AS $$
DECLARE
  lv   vec3;
  ld   vec3;
  dist float8;
  ndl  float8;
  spec float8;
  sh   vec3;
BEGIN
  -- Miss: the ray escapes and picks up the sky it was pointing at.
  IF h.obj = obj_sky() THEN RETURN att * sky(d); END IF;

  lv   := light_p() - h.p;
  dist := v3_len(lv);
  ld   := lv * (1.0 / dist);

  IF h.obj = obj_plane() THEN
    -- Lambertian diffuse under the key light plus a sky fill term.  The
    -- (1 - kr) factor is the energy *not* handed to the reflection child.
    ndl := greatest(v3_dot(h.n, ld), 0.0);
    sh  := CASE WHEN ndl > 0.0
                THEN shadow_att(h.p + h.n * 1e-3, ld, dist)
                ELSE ROW(0, 0, 0)::vec3 END;
    RETURN att * floor_albedo(h.p)
               * (light_col() * (light_pow() / (dist * dist) * ndl) * sh
                  + sky_bg(h.n) * 0.09)
               * (1.0 - least(floor_kr_max(), fresnel_schlick(-v3_dot(d, h.n), 0.045)));
  END IF;

  -- Metal and glass contribute only a specular highlight locally; their
  -- appearance comes from the reflected and refracted children.  The
  -- highlight is tight, so the shadow ray is only worth firing where the
  -- lobe is actually visible -- which is a small fraction of those hits.
  spec := pow_safe(greatest(v3_dot(h.n, v3_unit(ld - d)), 0.0),
                   CASE WHEN h.obj = obj_sphere() THEN 260.0 ELSE 420.0 END);
  IF spec < 1e-4 THEN RETURN ROW(0, 0, 0)::vec3; END IF;

  sh := shadow_att(h.p + h.n * 1e-3, ld, dist);
  RETURN att * light_col()
             * (spec * CASE WHEN h.obj = obj_sphere() THEN 2.2 ELSE 1.6 END)
             * sh;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- child_ray: the ray leaving a hit along branch k, or NULL when that branch
-- carries no energy (wrong surface type, wrong channel, or total internal
-- reflection killing the transmitted lobe).
-- ---------------------------------------------------------------------------

CREATE TYPE ray AS (o vec3, d vec3, att vec3, chan int);

CREATE FUNCTION child_ray(d vec3, h hit, att vec3, chan int, k int) RETURNS ray AS $$
DECLARE
  cosi float8 := -v3_dot(d, h.n);
  eta  float8;
  dir  vec3;
  a    vec3;
BEGIN
  -- Branch 0: specular reflection off whichever surface was hit.
  IF k = 0 THEN
    IF h.obj = obj_plane() THEN
      a := att * least(floor_kr_max(), fresnel_schlick(cosi, 0.045));
    ELSIF h.obj = obj_sphere() THEN
      a := att * fresnel_metal(cosi, metal_tint());
    ELSIF h.obj = obj_cube() THEN
      eta := CASE WHEN h.back THEN glass_ior(chan) ELSE 1.0 / glass_ior(chan) END;
      a := att * fresnel_dielectric(cosi, eta);
    ELSE
      RETURN NULL;
    END IF;
    RETURN ROW(h.p + h.n * 1e-4, v3_reflect(d, h.n), a, chan)::ray;
  END IF;

  -- Branches 1-3: refraction into or out of the glass, one wavelength each.
  -- An undispersed ray (chan = 0) spawns all three and masks each down to its
  -- own channel; a ray already committed to a channel spawns only that one, so
  -- the split happens exactly once, at the first glass surface it meets.
  IF h.obj <> obj_cube() OR NOT (chan = 0 OR chan = k) THEN RETURN NULL; END IF;

  eta := CASE WHEN h.back THEN glass_ior(k) ELSE 1.0 / glass_ior(k) END;
  dir := v3_refract(d, h.n, eta);
  IF dir IS NULL THEN RETURN NULL; END IF;          -- total internal reflection

  a := att * (1.0 - fresnel_dielectric(cosi, eta));
  IF chan = 0 THEN a := a * chan_mask(k); END IF;
  RETURN ROW(h.p - h.n * 1e-4, dir, a, k)::ray;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;
