-- ---------------------------------------------------------------------------
-- An arbitrary mesh, loaded from a Wavefront OBJ, with materials picked per
-- mesh.  Nothing in the tracer knows what a torus is.
--
--   docker exec -i pg_rt psql -U rt -d rt \
--     -v obj="$(sed -e 's/'"'"'/'"''"'/g' examples/torus.obj)" \
--     -f examples/torus_scene.sql
--
-- or, more simply, from a psql session started in the repository root:
--
--   \set obj `cat examples/torus.obj`
--   \i examples/torus_scene.sql
--   SELECT render(480, 320, 2, 5);
-- ---------------------------------------------------------------------------

BEGIN;

SELECT scene_clear();

-- Reuse whatever materials the default scene installed, and add one more so
-- the two rings can be told apart.
INSERT INTO material (name, kind, tint, spec_e, spec_k)
VALUES ('copper', mat_metal(), ROW(0.95, 0.64, 0.54)::vec3, 220.0, 2.2)
ON CONFLICT (name) DO NOTHING;

SELECT mesh_add_quad('ground', 'checker-tile', 40.0);

-- The same OBJ twice, at different sizes and angles, wearing different
-- materials.  Selecting a material is picking a name.
-- Standing on edge, so the hole reads: pitch is the last argument.
SELECT mesh_load_obj('ring-metal', 'copper', :'obj',
                     1.00, radians(-25.0), ROW(-1.30, 1.15, -0.30)::vec3,
                     false, radians(78.0));
SELECT mesh_load_obj('ring-glass', 'crown-glass', :'obj',
                     0.85, radians(35.0), ROW(1.45, 0.95, 0.60)::vec3,
                     false, radians(72.0));

SELECT scene_reindex();

COMMIT;

SELECT m.name, mt.name AS material, count(*) AS triangles
FROM tri t JOIN mesh m USING (mesh_id) JOIN material mt USING (mat_id)
GROUP BY m.name, mt.name ORDER BY m.name;
