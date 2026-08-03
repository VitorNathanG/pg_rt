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
--
-- Component form: the vector spelling hands `*` a Schlick term for a scalar
-- operand it names three times, which is over the inlining threshold, so the
-- addition above it stops folding too.  Written out, pow_safe sees a one
-- operator base and the whole expression collapses into the caller.
CREATE FUNCTION fresnel_metal(cosi float8, tint vec3) RETURNS vec3 AS $$
  SELECT ROW((tint).x + (1.0 - (tint).x) * pow_safe(1.0 - cosi, 5.0),
             (tint).y + (1.0 - (tint).y) * pow_safe(1.0 - cosi, 5.0),
             (tint).z + (1.0 - (tint).z) * pow_safe(1.0 - cosi, 5.0))::vec3
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
-- Direct lighting.
--
-- The work splits at the (hit, light) pair.  light_rad computes what one light
-- delivers to one hit; shade computes how the surface answers, and answers the
-- sum of the lights rather than one of them.  That split is the whole of
-- multi-light support: everything depending only on the surface -- the albedo,
-- the checker lookup, the Fresnel weight, the specular strength -- is computed
-- once per hit no matter how many lights the scene holds, and the renderer
-- resolves the pairs as one join instead of a loop.
-- ---------------------------------------------------------------------------

-- What one light delivers to one hit, already attenuated by `sh`, the shadow
-- transmission along the ray to that light.  Both `sh` and the summation are
-- the renderer's job, for the same reason: every shadow ray in the frame is
-- intersected in one pass, and every light is summed in one aggregate.
--
-- The two branches return different quantities on purpose.  A diffuse surface
-- wants irradiance; a specular one wants the value of its lobe toward the
-- light.  Each is exactly the factor that depends on which light this is, and
-- each hit takes exactly one branch, so shade knows which response to apply
-- from the material it already has in hand.
--
-- The half-vector cosine goes through a local for the reason spelled out on
-- make_hit: pow_safe names its base three times, so handing it twenty
-- operators' worth of arithmetic stops it inlining and turns a handful of
-- flops into a per-call executor run.
-- `lp` is the point on the light this shadow ray was actually aimed at, and it
-- is an argument rather than something read back off `l` for a reason that has
-- already cost this renderer a bug once: the position is used on both sides of
-- a dependency.  The shadow ray was built toward lp and tested for occlusion
-- along that line; if the shading then recomputed a position, the two would be
-- answering about different points, and every soft shadow would be lit from
-- somewhere it was never traced from.  A point light is the case where they
-- coincide, which is what the five-argument spelling below says.
--
-- `w` is what makes several samples add up to one emitter rather than to
-- several: each carries 1/samples^2 of it.  Averaging is right for both
-- branches -- the diffuse one because irradiance is linear in power, the
-- specular one because the soft highlight *is* the mean of the lobe taken over
-- the panel.
CREATE FUNCTION light_rad(d vec3, h hit, m material, l light, lp vec3, sh vec3)
RETURNS vec3 AS $$
DECLARE
  lv   vec3   := lp - (h).p;
  dist float8 := v3_len(lv);
  ld   vec3   := lv * (1.0 / dist);
  w    float8 := 1.0 / (l.samples * l.samples)::float8;
  hv   vec3;
  ndl  float8;
  cs   float8;
BEGIN
  -- A panel emits into the hemisphere it faces and carries its own
  -- foreshortening, so a surface off to its side sees less of it.  NULL is a
  -- point light, which has no orientation and therefore no cosine, and it has
  -- to be tested rather than folded into the arithmetic: greatest(NULL, 0.0)
  -- is 0.0, so the tidier spelling would darken every point light to nothing.
  IF l.nrm IS NOT NULL THEN
    w := w * greatest(-v3_dot(ld, l.nrm), 0.0);
  END IF;
  IF m.kind = mat_diffuse() THEN
    ndl := greatest(v3_dot((h).n, ld), 0.0);
    RETURN l.col * (l.pow / (dist * dist) * ndl * w) * sh;
  END IF;
  -- The half vector goes through a local as well: v3_dot names each of its
  -- arguments three times, and v3_unit expanded in place is far past the
  -- point where that stops inlining.
  hv := v3_unit(ld - d);
  cs := greatest(v3_dot((h).n, hv), 0.0);
  RETURN l.col * (pow_safe(cs, m.spec_e) * w) * sh;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- A light sampled at its own position, which for a point light is the only
-- place it can be sampled.  The renderer never calls this -- it always knows
-- which sample it traced -- but it is the honest scalar spelling, and it keeps
-- the point-light case readable in psql and in the suite.
CREATE FUNCTION light_rad(d vec3, h hit, m material, l light, sh vec3)
RETURNS vec3 AS $$
  SELECT light_rad(d, h, m, l, l.p, sh)
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- A (hit, light) pair is worth a shadow ray only where that light can actually
-- show: on a diffuse surface facing it, or inside a specular lobe aimed at it.
-- The lobes are tight, so this rejects most of the frame's non-diffuse hits
-- before they cost an intersection -- and it decides per light, so a rim light
-- behind the subject pays only for the hits it can reach.
--
-- The same predicate also decides which pairs contribute at all: below these
-- thresholds light_rad's answer rounds away, so the renderer sums only what
-- survives here.
CREATE FUNCTION wants_light(d vec3, h hit, m material, l light, lp vec3)
RETURNS boolean AS $$
DECLARE ld vec3; hv vec3; cs float8;
BEGIN
  IF (h).mat = 0 THEN RETURN false; END IF;
  ld := v3_unit(lp - (h).p);
  -- Behind the panel there is nothing to trace toward, and this is the only
  -- place that costs nothing to check: rejecting here saves the shadow ray as
  -- well as the shading.
  IF l.nrm IS NOT NULL AND v3_dot(ld, l.nrm) >= 0.0 THEN RETURN false; END IF;
  IF m.kind = mat_diffuse() THEN RETURN v3_dot((h).n, ld) > 0.0; END IF;
  hv := v3_unit(ld - d);                    -- local: see light_rad
  cs := greatest(v3_dot((h).n, hv), 0.0);
  RETURN pow_safe(cs, m.spec_e) >= 1e-4;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION wants_light(d vec3, h hit, m material, l light)
RETURNS boolean AS $$
  SELECT wants_light(d, h, m, l, l.p)
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- shade: the radiance a hit contributes directly, already weighted by the
-- throughput `att` the ray carried to get here.  Energy that continues via
-- reflection or refraction is NOT counted here -- the child rows carry it,
-- and the sum over all rows of a pixel adds the two together.
--
-- `e` is everything the lights delivered to this hit, summed by the renderer
-- over the pairs that survived wants_light and shadowing.  A hit no light
-- reaches gets a zero vector, which is also the right answer for a scene with
-- no lights in it.
-- ---------------------------------------------------------------------------

-- Every vec3 below goes through a local before it is combined with another.
-- That is not stylistic: a vec3 operator names each operand three times, so
-- handing one the result of sky_bg or mat_albedo is over the inlining
-- threshold, and a call that fails to inline costs procost 100 -- which is
-- itself over the threshold, so the failure cascades up the whole expression.
-- Bound to locals every operand is a Param, and the entire arithmetic folds
-- into one expression tree with no calls in it.
CREATE FUNCTION shade(d vec3, h hit, att vec3, m material, e vec3) RETURNS vec3 AS $$
DECLARE
  bg   vec3;
  alb  vec3;
  lit  vec3;
  fres float8;
BEGIN
  -- Miss: the ray escapes and picks up the sky it was pointing at.  The light
  -- discs painted on that sky are in `e` as well -- looking at a light is the
  -- one way a miss is lit.
  IF (h).mat = 0 THEN
    bg := sky_bg(d);
    RETURN att * (bg + e);
  END IF;

  IF m.kind = mat_diffuse() THEN
    -- Lambertian diffuse under the lights plus a sky fill term.  The (1 - kr)
    -- factor is the energy *not* handed to the reflection child.
    alb  := mat_albedo(m, (h).p);
    bg   := sky_bg((h).n);
    fres := 1.0 - least(m.kr_max,
                        fresnel_schlick(-v3_dot(d, (h).n), m.f0));
    lit  := att * alb * (e + bg * 0.09);
    RETURN lit * fres;
  END IF;

  -- Metal and glass contribute only a specular highlight locally; their
  -- appearance comes from the reflected and refracted children.  `e` already
  -- holds each light's lobe value, so all that is left is the surface's own
  -- specular strength.
  RETURN att * e * m.spec_k;
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
  kr   float8;
  tint vec3;
BEGIN
  -- Branch 0: specular reflection off whichever surface was hit.
  --
  -- Each Fresnel term lands in a scalar local first.  Handed straight to the
  -- `*` operator it is an eight-to-twelve operator expression against a
  -- parameter named three times, which is over the threshold and costs an
  -- executor run per child ray -- see the note on shade.
  IF k = 0 THEN
    IF m.kind = mat_diffuse() THEN
      kr := least(m.kr_max, fresnel_schlick(cosi, m.f0));
      a  := att * kr;
    ELSIF m.kind = mat_metal() THEN
      tint := fresnel_metal(cosi, m.tint);
      a    := att * tint;
    ELSE
      eta := CASE WHEN (h).back THEN ior_of(m, chan)
                  ELSE 1.0 / ior_of(m, chan) END;
      kr  := fresnel_dielectric(cosi, eta);
      a   := att * kr;
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

  kr := 1.0 - fresnel_dielectric(cosi, eta);
  a  := att * kr;
  IF chan = 0 THEN
    tint := chan_mask(k);
    a    := a * tint;
  END IF;
  RETURN ROW((h).p - (h).n * 1e-4, dir, a, k)::ray;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;
