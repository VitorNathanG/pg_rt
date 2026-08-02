-- ---------------------------------------------------------------------------
-- Moving geometry, as one row per frame.
--
-- The block turns on the spot and the ball rises and falls.  Nothing here
-- touches a vertex: `tri` and the BVH are byte for byte what scene_default()
-- built, and the only thing written per frame is `mesh.xform`.  That is the
-- whole point of transforming the ray into the mesh's coordinates instead of
-- the mesh into the world's -- geometry that never moves never needs
-- reindexing.
--
--   docker exec -i pg_rt psql -U rt -d rt -f - < examples/spin.sql
--
-- Then write the frames out:
--
--   for i in $(seq 0 11); do
--     docker exec pg_rt psql -U rt -d rt -tAq \
--       -c "SELECT encode(png, 'hex') FROM frame WHERE name = 'spin-$i'" \
--       | tr -d '\n' | xxd -r -p > spin-$i.png
--   done
--
-- **This one cannot use render_frames.sh, and the reason is worth knowing.**
-- A camera move is data: every frame row carries its own camera, so the rows
-- can all exist before anything is traced and any number of sessions can pull
-- from the queue.  A geometry move is not, yet.  A frame row records the
-- camera it was taken from but not the scene it was pointed at, so the twelve
-- rows below would all be rendered against whatever transform happened to be
-- set last.  Until a frame can name a scene, moving geometry has to interleave
-- the UPDATE and the render, which means one session and strict order.
--
-- And the failure mode is worse than a stale pose, which is why this is a
-- comment rather than a footnote.  render() is VOLATILE, so under READ
-- COMMITTED every statement inside it takes a fresh snapshot -- a pose
-- committed by another session part-way through is picked up by the *later
-- bounces of a render already in flight*.  Measured: two reads of mesh.xform
-- inside one call returned 0 and then 99.  The frame that comes out has its
-- primary hits against one pose and its reflections against another, and
-- nothing anywhere reports a problem.  Anyone who really must animate and
-- render at once needs BEGIN ISOLATION LEVEL REPEATABLE READ around it.
-- ---------------------------------------------------------------------------

DELETE FROM frame WHERE name LIKE 'spin-%';

INSERT INTO frame (name, w, h, aa, maxdepth)
SELECT format('spin-%s', i), 320, 200, 1, 4
FROM generate_series(0, 11) AS i;

-- Set the pose, then render, then move on.  The UPDATE is the entire animation
-- system: one row per mesh per frame, no reindex between them.
DO $$
DECLARE
  f      record;
  i      int := 0;
  turn   float8;
BEGIN
  FOR f IN SELECT frame_id FROM frame WHERE name LIKE 'spin-%' ORDER BY frame_id
  LOOP
    turn := 2 * pi() * i / 12.0;

    -- The block spins about its own centre.  m34_place scales, yaws and then
    -- translates, so translating by the centre after the yaw is what keeps it
    -- turning on the spot rather than orbiting the origin.
    PERFORM mesh_place('block',
              m34_place(1.0, turn, v3(1.35 - 1.35 * cos(turn) - 0.55 * sin(turn),
                                      0.0,
                                      0.55 + 1.35 * sin(turn) - 0.55 * cos(turn))));

    -- The ball just bounces.
    PERFORM mesh_place('ball', m34_place(1.0, 0.0, v3(0, 0.55 * abs(sin(turn)), 0)));

    PERFORM render_frame(f.frame_id);
    i := i + 1;
  END LOOP;
END $$;

SELECT mesh_place('block', m34_identity());
SELECT mesh_place('ball',  m34_identity());

-- The claim, checked rather than asserted: the acceleration structure is
-- exactly what it was before the animation ran.
SELECT count(*) AS triangles,
       count(*) FILTER (WHERE cl IS NULL) AS unassigned
FROM tri;

SELECT name, elapsed_ms, pg_size_pretty(length(png)::bigint) AS png
FROM frame WHERE name LIKE 'spin-%' ORDER BY frame_id;
