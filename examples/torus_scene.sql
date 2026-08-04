-- ---------------------------------------------------------------------------
-- An arbitrary mesh, loaded from a Wavefront OBJ, with materials picked per
-- mesh.  Nothing in the tracer knows what a torus is.
--
--   docker cp examples/torus.obj       pg_rt:/tmp/
--   docker cp examples/torus_scene.sql pg_rt:/tmp/
--   printf '\\set obj `cat /tmp/torus.obj`\n\\i /tmp/torus_scene.sql\n' \
--     | docker exec -i pg_rt psql -U rt -d rt
--
-- The mesh goes through the container's filesystem rather than through a psql
-- variable on the command line, and that is not fussiness.  A -v obj="$(cat
-- ...)" puts 212 kB of OBJ into argv, which docker exec refuses outright --
-- and if stderr is being discarded it refuses *silently*, leaving whatever
-- scene was already loaded in place to be rendered and measured as though it
-- were the new one.  psql's own backtick runs inside the container, so the
-- file never reaches an argument list.
--
-- From a psql session on the host, started in the repository root, the short
-- form still works -- \set builds the variable internally:
--
--   \set obj `cat examples/torus.obj`
--   \i examples/torus_scene.sql
--   SELECT render(480, 320, 2, 5, p_refine => 16);
-- ---------------------------------------------------------------------------

BEGIN;

SELECT scene_clear();

-- Reuse whatever materials the default scene installed, and add one more so
-- the two rings can be told apart.
INSERT INTO material (name, kind, tint, spec_e, spec_k)
VALUES ('copper', mat_metal(), ROW(0.95, 0.64, 0.54)::vec3, 220.0, 2.2)
ON CONFLICT (name) DO NOTHING;

-- The lighting is stated rather than inherited.  scene_clear() empties the
-- geometry and leaves `light` alone, so this file used to render under
-- whatever the last scene happened to install -- which works, and hides the
-- fact that the picture depends on it.  A key of its own is one delete and one
-- call, and it means this file describes the whole of what it renders.
--
-- Slightly wider than the default scene's panel, because two rings standing on
-- edge cast far longer shadows than a ball does and a bigger source keeps
-- their far ends from going to a hard line.  See the note on scene_default for
-- where the sample count and sky_e come from.
DELETE FROM light;
SELECT light_softbox('key',
                     ROW(5.2, 4.6, -2.4)::vec3,
                     ROW(0.05, 1.0, 0.0)::vec3,
                     3.0, 3.0, 2, 125.0,
                     ROW(1.00, 0.96, 0.88)::vec3, 22.0, 36.0);

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
