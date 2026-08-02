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
-- Then write the whole sequence out as one animated GIF:
--
--   docker exec pg_rt psql -U rt -d rt -tAq \
--     -c "SELECT encode(frames_gif('orbit-%'), 'hex')" \
--     | tr -d '\n' | xxd -r -p > orbit.gif
--
-- or the frames individually, one PNG per file:
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
--
-- `delay_ms` is how long each frame is held on playback.  It is a column
-- rather than a setting of the animation because a hold -- the same camera for
-- three frames' worth of time -- belongs to the shot, and GIF carries only one
-- rate for a whole file.  Twenty-four frames at 80 ms is a two-second loop.
--
-- The other three settings are all about the glass, and each fixes a different
-- artifact.  Measured on the default scene at 320x200:
--
--   maxdepth 8 rather than 4.  A dielectric contributes only a specular
--   highlight where it is hit; everything it transmits or reflects is carried
--   by its child rays, so a glass hit landing on the final depth throws its
--   energy away.  At depth 4 that was 35 660 live hits discarded, and every
--   one of the 2 917 pixels it changed came out *darker* than it should be.
--   The four extra depths cost nothing measurable -- 19.7 s against 20.3 s --
--   because the ray population collapses once rays leave the glass.
--
--   aa 2 with refine 16 rather than one sample.  Dispersion sends the three
--   channels down different paths, so at one sample a pixel where red lands on
--   a white checker square and blue lands on a black one comes out saturated.
--   1 727 such pixels at aa 1, 1 062 at aa 2.  Past that it is asymptotic --
--   987 at aa 3, 958 at aa 4, for 1.8x and 3.1x the time -- because what is
--   left is real dispersion rather than aliasing, and averaging more
--   sub-samples that disagree the same way does not help.
--
--   640x400 rather than 320x200.  This does not reduce the speckle *rate* at
--   all -- 1.66% of pixels against 1.76% -- it makes each speckle a quarter of
--   the screen area, which is what turns blotches into fine sparkle.
INSERT INTO frame (name, w, h, aa, maxdepth, refine, delay_ms, cam_from, cam_at)
SELECT format('orbit-%s', i), 640, 400, 2, 8, 16, 80,
       v3(6.72 * sin(radians(i * 15.0)),
          2.35,
          6.72 * cos(radians(i * 15.0))),
       v3(0.05, 1.00, 0.00)
FROM generate_series(0, 23) AS i;

-- Resuming an interrupted run is the same statement: `WHERE png IS NULL` is
-- the work queue, and a frame that already has its bytes is simply not in it.
SELECT count(*) AS frames_to_render FROM frame WHERE png IS NULL;

-- One session, in frame order.  These frames are not cheap -- about 146 s each
-- -- so an hour this way.  For the same twenty-four through the same queue
-- with several sessions pulling from it, for identical bytes, stop after the
-- INSERT above and run
--
--   ./render_frames.sh 8
--
-- The speedup was measured on a lighter version of this same orbit, 24 frames
-- at 320x200 and one sample: 144 s at one session against 37 s at eight.
--
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

-- The sequence as one file, against the frames it was built from.  The GIF
-- comes in at about half the total because a GIF pixel is one byte where a PNG
-- pixel is three; what it gives up is every colour past the 256th, chosen once
-- over the whole animation so that flat areas do not shift between frames.
SELECT pg_size_pretty(sum(length(png))::bigint) AS frames_as_png,
       pg_size_pretty(length(frames_gif('orbit-%'))::bigint) AS one_gif
FROM frame WHERE name LIKE 'orbit-%';
