-- ---------------------------------------------------------------------------
-- Light transport.
--
-- Every branch here is taken on a material's `kind`, never on the identity of
-- an object.  Adding a second glass with a different dispersion, or turning
-- the ground metallic, is an INSERT or an UPDATE -- no function below changes.
--
-- A hit spawns up to four children, indexed by a branch number k:
--
--   k = 0   specular reflection            (every surface)
--   k = 1   refraction, red   channel      (dielectrics only)
--   k = 2   refraction, green channel      (dielectrics only)
--   k = 3   refraction, blue  channel      (dielectrics only)
--
-- Splitting refraction three ways is what produces dispersion.  A ray carries
-- a `chan` tag: 0 means it still represents all three wavelengths, 1-3 mean it
-- has been committed to one.  White light entering glass splits into three
-- rays that then follow measurably different paths, because the index of
-- refraction differs per channel.
--
-- Anything that reuses an intermediate is PL/pgSQL: a SQL function body is
-- macro-expanded into its caller, so a value referenced n times is computed
-- n times, and the factor compounds through every level of nesting.
-- ---------------------------------------------------------------------------

-- Fresnel reflectance at a dielectric boundary.  eta = n_from / n_into and
-- cosi = -dot(d, n) on the incident side.  Returns 1.0 under total internal
-- reflection, which lets a single scalar drive both branches: the reflection
-- child inherits all the energy exactly when refraction is impossible.
--
-- Schlick's approximation is only accurate from the thin side, so when the
-- ray is leaving the denser medium the transmitted cosine is substituted --
-- that substitution is what makes the inside of glass mirror at grazing
-- angles.
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

-- Index of refraction for the wavelength a ray has been committed to.  An
-- undispersed ray (chan = 0) uses the middle channel.
CREATE FUNCTION ior_of(m material, chan int) RETURNS float8
  AS $$ SELECT CASE chan WHEN 1 THEN (m.ior).x WHEN 3 THEN (m.ior).z
                         ELSE (m.ior).y END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Channel isolation mask for a dispersed ray.
CREATE FUNCTION chan_mask(c int) RETURNS vec3
  AS $$ SELECT CASE c WHEN 1 THEN ROW(1,0,0)::vec3
                      WHEN 2 THEN ROW(0,1,0)::vec3
                      WHEN 3 THEN ROW(0,0,1)::vec3
                      ELSE        ROW(1,1,1)::vec3 END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Beer-Lambert transmission along the segment that terminated at h.  A ray
-- was inside the medium exactly when it struck the surface from the back,
-- which holds for any closed mesh, not just for a convex one.
CREATE FUNCTION beer(h hit, m material) RETURNS vec3 AS $$
  SELECT CASE WHEN m.kind = mat_glass() AND (h).back
              THEN ROW(exp(-(m.absorb).x * (h).t),
                       exp(-(m.absorb).y * (h).t),
                       exp(-(m.absorb).z * (h).t))::vec3
              ELSE ROW(1, 1, 1)::vec3
         END $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- shade: the radiance a hit contributes directly, already weighted by the
-- throughput `att` the ray carried to get here.  Energy that continues via
-- reflection or refraction is NOT counted here -- the child rows carry it,
-- and the sum over all rows of a pixel adds the two together.
--
-- `sh` is the shadow transmission toward the key light, computed set-based by
-- the renderer.  Passing it in rather than tracing it here is what lets every
-- shadow ray in the frame be intersected in one pass.
-- ---------------------------------------------------------------------------

CREATE FUNCTION shade(d vec3, h hit, att vec3, m material, sh vec3) RETURNS vec3 AS $$
DECLARE
  lv   vec3;
  ld   vec3;
  dist float8;
  ndl  float8;
  cs   float8;
  spec float8;
BEGIN
  -- Miss: the ray escapes and picks up the sky it was pointing at.
  IF (h).mat = 0 THEN RETURN att * sky(d); END IF;

  lv   := light_p() - (h).p;
  dist := v3_len(lv);
  ld   := lv * (1.0 / dist);

  IF m.kind = mat_diffuse() THEN
    -- Lambertian diffuse under the key light plus a sky fill term.  The
    -- (1 - kr) factor is the energy *not* handed to the reflection child.
    ndl := greatest(v3_dot((h).n, ld), 0.0);
    RETURN att * mat_albedo(m, (h).p)
               * (light_col() * (light_pow() / (dist * dist) * ndl) * sh
                  + sky_bg((h).n) * 0.09)
               * (1.0 - least(m.kr_max,
                              fresnel_schlick(-v3_dot(d, (h).n), m.f0)));
  END IF;

  -- Metal and glass contribute only a specular highlight locally; their
  -- appearance comes from the reflected and refracted children.
  --
  -- The half-vector cosine goes through a local for the reason spelled out on
  -- make_hit: pow_safe names its base three times, so handing it twenty
  -- operators' worth of arithmetic stops it inlining and turns a handful of
  -- flops into a per-call executor run.
  cs   := greatest(v3_dot((h).n, v3_unit(ld - d)), 0.0);
  spec := pow_safe(cs, m.spec_e);
  IF spec < 1e-4 THEN RETURN ROW(0, 0, 0)::vec3; END IF;
  RETURN att * light_col() * (spec * m.spec_k) * sh;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- A hit is worth a shadow ray only where the light can actually show: on a
-- diffuse surface facing the light, or inside a specular lobe.  The lobes are
-- tight, so this rejects most of the frame's non-diffuse hits before they
-- cost an intersection.
CREATE FUNCTION wants_light(d vec3, h hit, m material) RETURNS boolean AS $$
DECLARE ld vec3; cs float8;
BEGIN
  IF (h).mat = 0 THEN RETURN false; END IF;
  ld := v3_unit(light_p() - (h).p);
  IF m.kind = mat_diffuse() THEN RETURN v3_dot((h).n, ld) > 0.0; END IF;
  cs := greatest(v3_dot((h).n, v3_unit(ld - d)), 0.0);
  RETURN pow_safe(cs, m.spec_e) >= 1e-4;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- child_ray: the ray leaving a hit along branch k, or NULL when that branch
-- carries no energy (wrong surface type, wrong channel, or total internal
-- reflection killing the transmitted lobe).
-- ---------------------------------------------------------------------------

CREATE TYPE ray AS (o vec3, d vec3, att vec3, chan int);

CREATE FUNCTION child_ray(d vec3, h hit, att vec3, chan int, k int, m material)
RETURNS ray AS $$
DECLARE
  cosi float8 := -v3_dot(d, (h).n);
  eta  float8;
  dir  vec3;
  a    vec3;
BEGIN
  -- Branch 0: specular reflection off whichever surface was hit.
  IF k = 0 THEN
    IF m.kind = mat_diffuse() THEN
      a := att * least(m.kr_max, fresnel_schlick(cosi, m.f0));
    ELSIF m.kind = mat_metal() THEN
      a := att * fresnel_metal(cosi, m.tint);
    ELSE
      eta := CASE WHEN (h).back THEN ior_of(m, chan)
                  ELSE 1.0 / ior_of(m, chan) END;
      a := att * fresnel_dielectric(cosi, eta);
    END IF;
    RETURN ROW((h).p + (h).n * 1e-4, v3_reflect(d, (h).n), a, chan)::ray;
  END IF;

  -- Branches 1-3: refraction into or out of the medium, one wavelength each.
  -- An undispersed ray (chan = 0) spawns all three and masks each down to its
  -- own channel; a ray already committed to a channel spawns only that one,
  -- so the split happens exactly once, at the first dielectric it meets.
  IF m.kind <> mat_glass() OR NOT (chan = 0 OR chan = k) THEN RETURN NULL; END IF;

  eta := CASE WHEN (h).back THEN ior_of(m, k) ELSE 1.0 / ior_of(m, k) END;
  dir := v3_refract(d, (h).n, eta);
  IF dir IS NULL THEN RETURN NULL; END IF;        -- total internal reflection

  a := att * (1.0 - fresnel_dielectric(cosi, eta));
  IF chan = 0 THEN a := a * chan_mask(k); END IF;
  RETURN ROW((h).p - (h).n * 1e-4, dir, a, k)::ray;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;
