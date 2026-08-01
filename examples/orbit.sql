-- ---------------------------------------------------------------------------
-- A camera move, as rows.
--
-- The scene is whatever is already loaded -- the default one, or the torus
-- scene from torus_scene.sql.  Nothing here touches geometry: `tri` and the
-- BVH are identical at every frame and nothing is reindexed between them,
-- which is what makes moving the camera the one animation that costs only the
-- frames themselves.
--
--   docker exec -i pg_rt psql -U rt -d rt -f - < examples/orbit.sql
--
-- Then write the frames out, one PNG per file:
--
--   for i in $(seq 0 23); do
--     docker exec pg_rt psql -U rt -d rt -tAq \
--       -c "SELECT encode(png, 'hex') FROM frame WHERE name = 'orbit-$i'" \
--       | tr -d '\n' | xxd -r -p > orbit-$i.png
--   done
-- ---------------------------------------------------------------------------

DELETE FROM frame WHERE name LIKE 'orbit-%';

-- The path is trigonometry over a generate_series: twenty-four viewpoints on a
-- circle about the origin, each aimed at the same target.  The rows all exist
-- before anything is traced, which is the point -- the sequence is data, and
-- rendering it is a second step that can be interrupted and resumed.
INSERT INTO frame (name, w, h, aa, maxdepth, cam_from, cam_at)
SELECT format('orbit-%s', i), 320, 200, 1, 4,
       v3(6.72 * sin(radians(i * 15.0)),
          2.35,
          6.72 * cos(radians(i * 15.0))),
       v3(0.05, 1.00, 0.00)
FROM generate_series(0, 23) AS i;

-- Resuming an interrupted run is the same statement: `WHERE png IS NULL` is
-- the work queue, and a frame that already has its bytes is simply not in it.
SELECT count(*) AS frames_to_render FROM frame WHERE png IS NULL;

SELECT render_frame(frame_id)
FROM frame
WHERE name LIKE 'orbit-%' AND png IS NULL
ORDER BY frame_id;

-- What was rendered, and what it cost.  This is the part `img` could never
-- answer: every one of these rows knows the camera it was taken from.
SELECT name,
       round((cam_from).x::numeric, 2) AS cam_x,
       round((cam_from).z::numeric, 2) AS cam_z,
       elapsed_ms,
       pg_size_pretty(length(png)::bigint) AS png
FROM frame
WHERE name LIKE 'orbit-%'
ORDER BY frame_id;
