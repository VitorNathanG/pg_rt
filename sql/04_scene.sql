-- ---------------------------------------------------------------------------
-- The scene: lighting, the sky, and the meshes that make up the default view.
--
-- Nothing below is known to the tracer.  The transport code reads material
-- rows and triangle rows; it has no idea that this particular scene contains
-- a sphere, and would trace a teapot with the same query.
-- ---------------------------------------------------------------------------

-- Key light, and the sun disc the sky paints in the same direction so that
-- reflections stay consistent with the shading.
--
-- Placed behind and to the side of the subjects rather than over the camera's
-- shoulder: a frontal light throws every shadow behind the object that casts
-- it, where the object itself hides it, and the render comes out looking flat.
CREATE FUNCTION light_p()   RETURNS vec3   AS $$ SELECT ROW(5.2, 4.6, -2.4)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION light_col() RETURNS vec3   AS $$ SELECT ROW(1.00, 0.96, 0.88)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION light_pow() RETURNS float8 AS $$ SELECT 125.0 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION sky_bg(d vec3) RETURNS vec3 AS $$
  SELECT ROW(0.20, 0.40, 0.86)::vec3 * greatest((d).y, 0.0)
       + ROW(0.62, 0.76, 0.94)::vec3 * (1.0 - greatest((d).y, 0.0))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION sky(d vec3) RETURNS vec3 AS $$
  SELECT sky_bg(d) + light_col()
       * (22.0 * pow_safe(greatest(v3_dot(d, v3_unit(light_p())), 0.0), 420.0))
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Surface colour at a point.  A checker material fades toward its average
-- with distance, so the pattern does not alias into noise near the horizon.
CREATE FUNCTION mat_albedo(m material, p vec3) RETURNS vec3 AS $$
DECLARE fade float8; mix float8;
BEGIN
  IF m.checker <= 0.0 THEN RETURN m.albedo; END IF;
  fade := least(1.0, greatest(0.0, (v3_len(p) - 14.0) / 22.0));
  mix  := CASE WHEN (floor((p).x / m.checker)
                   + floor((p).z / m.checker))::int % 2 = 0
               THEN 1.0 ELSE 0.0 END * (1.0 - fade)
        + 0.5 * fade;
  RETURN m.albedo * mix + m.albedo2 * (1.0 - mix);
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- The default scene.
-- ---------------------------------------------------------------------------

CREATE FUNCTION scene_clear() RETURNS void AS $$
  DELETE FROM tri;
  DELETE FROM mesh_box;
  DELETE FROM bvh_node;
  DELETE FROM mesh;
$$ LANGUAGE sql;

CREATE FUNCTION scene_default(sphere_seg int DEFAULT 24) RETURNS void AS $$
BEGIN
  PERFORM scene_clear();
  DELETE FROM material;

  INSERT INTO material (name, kind, albedo, albedo2, checker, f0, kr_max)
  VALUES ('checker-tile', mat_diffuse(),
          ROW(0.90, 0.89, 0.86)::vec3, ROW(0.16, 0.17, 0.21)::vec3,
          1.0, 0.045,
          -- Physically this should approach 1 at grazing incidence, but an
          -- unclamped mirror floor reflects the bright uniform sky across the
          -- whole lower frame and erases its own shadows.
          0.17);

  INSERT INTO material (name, kind, tint, spec_e, spec_k)
  VALUES ('chrome', mat_metal(), ROW(0.96, 0.93, 0.86)::vec3, 260.0, 2.2);

  -- Crown glass, with the dispersion exaggerated so it reads at this
  -- resolution: blue is bent harder than red, which is what splits white
  -- light into a spectrum at every non-normal incidence.
  INSERT INTO material (name, kind, ior, absorb, spec_e, spec_k)
  VALUES ('crown-glass', mat_glass(),
          ROW(1.470, 1.530, 1.605)::vec3, ROW(0.28, 0.14, 0.16)::vec3,
          420.0, 1.6);

  PERFORM mesh_add_quad('ground', 'checker-tile', 40.0);
  PERFORM mesh_add_sphere('ball', 'chrome', 1.00,
                          ROW(-1.15, 1.00, -0.20)::vec3, sphere_seg);
  PERFORM mesh_add_box('block', 'crown-glass', 0.85,
                       ROW(1.35, 0.85, 0.55)::vec3, 0.42);

  PERFORM scene_reindex();
END $$ LANGUAGE plpgsql;

-- Build the default scene at install time so a fresh database can render.
DO $$ BEGIN PERFORM scene_default(); END $$;
