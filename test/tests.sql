-- ---------------------------------------------------------------------------
-- Checks for the parts that are easy to get subtly wrong and hard to see:
-- the byte-level encoders and the optics.  A wrong Fresnel term still renders
-- a plausible picture, so the physics is checked against closed forms rather
-- than against how the output looks.
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

CREATE OR REPLACE FUNCTION ok(cond boolean, label text) RETURNS text
  AS $$ SELECT CASE WHEN cond THEN 'pass  ' ELSE 'FAIL  ' END || label $$
  LANGUAGE sql;

CREATE OR REPLACE FUNCTION near(a float8, b float8, tol float8 DEFAULT 1e-9) RETURNS boolean
  AS $$ SELECT a IS NOT NULL AND b IS NOT NULL AND abs(a - b) <= tol $$
  LANGUAGE sql;

-- For checking that bad input is refused rather than quietly accepted.  The
-- failed statement rolls back to this block, so nothing it wrote survives.
CREATE OR REPLACE FUNCTION raises(stmt text) RETURNS boolean AS $$
BEGIN
  EXECUTE stmt;
  RETURN false;
EXCEPTION WHEN others THEN RETURN true;
END $$ LANGUAGE plpgsql;

-- The default scene's materials, by name.  The optics used to be checked
-- against global constants; now they are properties of a row, so the tests
-- read the same row the renderer does.
CREATE OR REPLACE FUNCTION m_glass() RETURNS material
  AS $$ SELECT * FROM material WHERE name = 'crown-glass' $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION m_metal() RETURNS material
  AS $$ SELECT * FROM material WHERE name = 'chrome' $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION m_floor() RETURNS material
  AS $$ SELECT * FROM material WHERE name = 'checker-tile' $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION l_key() RETURNS light
  AS $$ SELECT * FROM light WHERE name = 'key' $$ LANGUAGE sql STABLE;

-- A hit on the glass block and one on the metal ball, straight down onto the
-- top of each, so the transport checks have real geometry underneath them.
CREATE OR REPLACE FUNCTION h_glass() RETURNS hit
  AS $$ SELECT scene_hit(v3(1.35, 6.0, 0.55), v3(0,-1,0)) $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION h_metal() RETURNS hit
  AS $$ SELECT scene_hit(v3(-1.15, 6.0, -0.20), v3(0,-1,0)) $$ LANGUAGE sql STABLE;

\echo == encoders ==

SELECT ok(crc32('123456789'::bytea) = x'cbf43926'::bigint,
          'CRC-32 matches the standard check vector');
SELECT ok(crc32(''::bytea) = 0, 'CRC-32 of the empty string is 0');
SELECT ok(adler32('Wikipedia'::bytea) = x'11e60398'::bigint,
          'Adler-32 matches the standard check vector');
SELECT ok(adler32(''::bytea) = 1, 'Adler-32 of the empty string is 1');

-- The closed-form Adler-32 must agree with the definition on a long buffer,
-- where the deferred modulo has the most room to go wrong.
SELECT ok(adler32(b) = (
            WITH RECURSIVE step(i, a, s) AS (
              SELECT 0, 1::bigint, 0::bigint
              UNION ALL
              SELECT i + 1, (a + get_byte(b, i)) % 65521,
                            (s + (a + get_byte(b, i)) % 65521) % 65521
              FROM step WHERE i < length(b)
            )
            SELECT a | (s << 16) FROM step ORDER BY i DESC LIMIT 1),
          'Adler-32 closed form agrees with the iterative definition')
FROM (SELECT decode(string_agg(lpad(to_hex((g * 37 + 11) % 256), 2, '0'), ''), 'hex')
      FROM generate_series(1, 2000) g) AS q(b);

-- Every DEFLATE stored block must carry LEN and its one's complement.
SELECT ok(get_byte(z, 2) = 1
          AND get_byte(z, 3) + get_byte(z, 4) * 256
              + get_byte(z, 5) + get_byte(z, 6) * 256 = 65535,
          'DEFLATE stored block header has LEN = ~NLEN')
FROM (SELECT zlib_stored(decode(repeat('a5', 300), 'hex'))) AS q(z);

SELECT ok(substring(p FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea, 'PNG signature')
FROM (SELECT png_encode(2, 2, decode('00' || repeat('ff0000', 2)
                                  || '00' || repeat('0000ff', 2), 'hex'))) AS q(p);

SELECT ok(substring(p FROM 13 FOR 4) = 'IHDR'::bytea
          AND substring(p FROM length(p) - 7 FOR 4) = 'IEND'::bytea,
          'PNG begins with IHDR and ends with IEND')
FROM (SELECT png_encode(2, 2, decode('00' || repeat('ff0000', 2)
                                  || '00' || repeat('0000ff', 2), 'hex'))) AS q(p);

\echo
\echo == vector algebra ==

SELECT ok(near(v3_dot(v3(1,2,3), v3(4,-5,6)), 12), 'dot product');
SELECT ok(v3_cross(v3(1,0,0), v3(0,1,0)) = v3(0,0,1), 'cross product is right-handed');
SELECT ok(near(v3_len(v3_unit(v3(3,-4,12))), 1.0), 'normalisation yields unit length');
SELECT ok(near(v3_dot(v3_reflect(v3_unit(v3(1,-1,0)), v3(0,1,0)), v3(0,1,0)),
               -v3_dot(v3_unit(v3(1,-1,0)), v3(0,1,0))),
          'reflection flips the normal component and keeps the tangent');

\echo
\echo == geometry ==

-- Moller-Trumbore against a triangle whose answer is obvious by inspection.
SELECT ok(near(tri_hit(v3(0.25,0.25,3), v3(0,0,-1),
                       v3(0,0,0), v3(1,0,0), v3(0,1,0)), 3.0),
          'ray/triangle distance');
SELECT ok(tri_hit(v3(0.8,0.8,3), v3(0,0,-1),
                  v3(0,0,0), v3(1,0,0), v3(0,1,0)) IS NULL,
          'ray/triangle miss outside the u+v<=1 edge');
SELECT ok(tri_hit(v3(0.25,0.25,3), v3(0,0,1),
                  v3(0,0,0), v3(1,0,0), v3(0,1,0)) IS NULL,
          'ray/triangle miss when pointing away');
SELECT ok(tri_hit(v3(0.25,0.25,0), v3(1,0,0),
                  v3(0,0,0), v3(1,0,0), v3(0,1,0)) IS NULL,
          'a ray in the triangle plane does not intersect it');
-- A back-facing hit must still register: refracted rays leave through one.
SELECT ok(near(tri_hit(v3(0.25,0.25,-3), v3(0,0,1),
                       v3(0,0,0), v3(1,0,0), v3(0,1,0)), 3.0),
          'ray/triangle hits from behind too');

-- Barycentrics must reproduce the point they describe.
SELECT ok(near((bc).x, 0.5) AND near((bc).y, 0.25) AND near((bc).z, 0.25),
          'barycentric coordinates weight the vertices correctly')
FROM (SELECT tri_bary(v3(0.5,0.25,3), v3(0,0,-1),
                      v3(0,0,0), v3(1,0,0), v3(0,1,0))) AS q(bc);

SELECT ok(tri_normal(v3(0,0,0), v3(1,0,0), v3(0,1,0)) = v3(0,0,1),
          'facet normal follows the winding, right-handed');

-- The slab test, including the two cases the epsilon guard exists for.
SELECT ok(box_hit(v3(0,0,5), v3_inv(v3(0,0,-1)), v3(-1,-1,-1), v3(1,1,1)),
          'ray/box hit');
SELECT ok(NOT box_hit(v3(0,9,5), v3_inv(v3(0,0,-1)), v3(-1,-1,-1), v3(1,1,1)),
          'ray/box miss');
SELECT ok(NOT box_hit(v3(0,0,-5), v3_inv(v3(0,0,-1)), v3(-1,-1,-1), v3(1,1,1)),
          'ray/box miss when the box is behind the ray');
SELECT ok(box_hit(v3(0,0,0), v3_inv(v3(1,0,0)), v3(-1,-1,-1), v3(1,1,1)),
          'a ray starting inside the box hits it');
SELECT ok(box_hit(v3(0,0,5), v3_inv(v3(0,0,-1)), v3(-1,-1,-1), v3(1,1,1))
      AND NOT box_hit(v3(3,0,5), v3_inv(v3(0,0,-1)), v3(-1,-1,-1), v3(1,1,1)),
          'an axis-parallel ray is classified by the epsilon guard, not NULL');

\echo
\echo == meshes and materials ==

SELECT ok((SELECT count(*) FROM tri) > 1000, 'the default scene is a real mesh');
SELECT ok((SELECT count(*) FROM tri WHERE mesh_id =
             (SELECT mesh_id FROM mesh WHERE name = 'block')) = 12,
          'a box is twelve triangles');

-- Winding: a facet normal that disagrees with the vertex normal makes every
-- hit read as a back face, which renders the object as a black silhouette.
SELECT ok(bool_and(v3_dot(tri_normal(a,b,c), na) > 0),
          'every triangle is wound so its facet normal agrees with its vertex normals')
FROM tri WHERE na IS NOT NULL;

SELECT ok(bool_and(near(v3_len(na), 1.0) AND near(v3_len(nb), 1.0)
                   AND near(v3_len(nc), 1.0)),
          'stored vertex normals are unit length')
FROM tri WHERE na IS NOT NULL;

-- Smooth shading has to actually interpolate, or the sphere renders faceted.
SELECT ok(NOT (n1 = n2) AND near(v3_len(n1), 1.0),
          'the shading normal varies across a triangle with vertex normals')
FROM (SELECT * FROM tri WHERE na IS NOT NULL LIMIT 1) t,
     LATERAL (SELECT tri_shading_normal(t, v3(0.1, 0.1, 0.8))) AS a(n1),
     LATERAL (SELECT tri_shading_normal(t, v3(0.8, 0.1, 0.1))) AS b(n2);

-- ...and a mesh without vertex normals must fall back to the facet normal.
SELECT ok(tri_shading_normal(t, v3(0.3,0.3,0.4)) = tri_normal(t.a, t.b, t.c),
          'a mesh without vertex normals is shaded flat')
FROM (SELECT * FROM tri WHERE na IS NULL LIMIT 1) t;

-- Materials are selectable: the same geometry, a different look.
SELECT ok((SELECT mt.kind FROM mesh m JOIN material mt USING (mat_id)
           WHERE m.name = 'ball') = mat_metal(),
          'the ball mesh resolves to its material');

DO $x$ BEGIN PERFORM mesh_set_material('ball', 'crown-glass'); END $x$;
SELECT ok((SELECT mt.kind FROM mesh m JOIN material mt USING (mat_id)
           WHERE m.name = 'ball') = mat_glass()
          AND (SELECT count(*) FROM tri WHERE mesh_id =
                 (SELECT mesh_id FROM mesh WHERE name = 'ball')) > 1000,
          'a mesh can be reassigned to another material without touching geometry');
DO $x$ BEGIN PERFORM mesh_set_material('ball', 'chrome'); END $x$;
SELECT ok((SELECT mt.kind FROM mesh m JOIN material mt USING (mat_id)
           WHERE m.name = 'ball') = mat_metal(), 'and reassigned back');

-- Wavefront OBJ: a quad face, explicit normals, and a negative (relative)
-- index, which are the three spellings most likely to be got wrong.
--
-- Each load is its own statement: a function's INSERTs are not visible to the
-- snapshot of the statement that called it, so loading and counting in one
-- SELECT always reports zero.
DO $x$ BEGIN PERFORM mesh_load_obj('t_quad', 'chrome',
  E'v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nvn 0 0 -1\nf 1//1 2//1 3//1 4//1');
END $x$;
SELECT ok(count(*) = 2, 'an OBJ quad fan-triangulates into two triangles')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_quad');
SELECT ok(bool_and(na = v3(0,0,-1)), 'OBJ vertex normals are read')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_quad');

DO $x$ BEGIN PERFORM mesh_load_obj('t_slash', 'chrome',
  E'v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvn 0 0 1\nf 1/1/1 2/1/1 3/1/1');
END $x$;
SELECT ok(count(*) = 1 AND bool_and(na = v3(0,0,1)),
          'the v/vt/vn corner spelling is parsed')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_slash');

DO $x$ BEGIN PERFORM mesh_load_obj('t_neg', 'chrome',
  E'v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1'); END $x$;
SELECT ok(count(*) = 1 AND bool_and(a = v3(0,0,0)),
          'an OBJ negative index counts back from the last vertex')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_neg');

-- Placement: scale, yaw and translate must all reach the stored geometry.
DO $x$ BEGIN PERFORM mesh_load_obj('t_place', 'chrome',
  E'v 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3', 2.0, 0.0, v3(0,3,0)); END $x$;
SELECT ok(near((a).x, 2.0) AND near((a).y, 3.0),
          'a loaded mesh is scaled and translated into place')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_place');

DO $x$ BEGIN PERFORM mesh_load_obj('t_yaw', 'chrome',
  E'v 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3', 1.0, radians(90.0), v3(0,0,0));
END $x$;
SELECT ok(near((a).x, 0.0, 1e-12) AND near((a).z, -1.0, 1e-12),
          'a loaded mesh is yawed about Y')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_yaw');

-- A closed tetrahedron with no normals: smoothing must produce unit normals
-- averaged over the faces meeting each vertex.
DO $x$ BEGIN PERFORM mesh_load_obj('t_smooth', 'chrome',
  E'v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4',
  1.0, 0.0, v3(0,0,0), true); END $x$;
SELECT ok(count(*) = 4 AND bool_and(near(v3_len(na), 1.0)),
          'mesh_smooth generates unit vertex normals from bare geometry')
FROM tri WHERE mesh_id = (SELECT mesh_id FROM mesh WHERE name = 't_smooth');

-- A mesh with no faces is a silent way to render nothing; it must complain.
SELECT ok(raises($q$SELECT mesh_load_obj('t_bad', 'chrome', 'v 0 0 0')$q$),
          'an OBJ with no faces is rejected rather than loaded empty');
SELECT ok(raises($q$SELECT mesh_new('t_nomat', 'no-such-material')$q$),
          'an unknown material name is rejected');

-- New geometry is invisible to the renderer until the index is rebuilt.
SELECT ok(count(*) > 0, 'a freshly loaded mesh has no BVH leaf until reindex')
FROM tri WHERE cl IS NULL;

-- Take the probe meshes back out: several of them sit at the origin, in the
-- middle of the scene the checks below trace through.
DELETE FROM tri WHERE mesh_id IN (SELECT mesh_id FROM mesh WHERE name LIKE 't\_%');
DELETE FROM mesh WHERE name LIKE 't\_%';
DO $x$ BEGIN PERFORM scene_reindex(); END $x$;

\echo
\echo == acceleration ==

-- Every triangle must lie inside its own box, inside the leaf box that claims
-- it, and every leaf inside its mesh box.  A box that does not contain its
-- contents silently drops geometry from the render.
--
-- The triangle's box is a generated column, so it cannot drift from the
-- vertices -- but least/greatest transposed would still compile, and would
-- reject every ray that ought to hit.
SELECT ok(bool_and((v).x >= t.lox AND (v).x <= t.hix
               AND (v).y >= t.loy AND (v).y <= t.hiy
               AND (v).z >= t.loz AND (v).z <= t.hiz),
          'every triangle lies inside its own box')
FROM tri t, LATERAL (SELECT unnest(ARRAY[t.a, t.b, t.c])) AS q(v);

SELECT ok(bool_and((v).x >= (n.lo).x - 1e-9 AND (v).x <= (n.hi).x + 1e-9
               AND (v).y >= (n.lo).y - 1e-9 AND (v).y <= (n.hi).y + 1e-9
               AND (v).z >= (n.lo).z - 1e-9 AND (v).z <= (n.hi).z + 1e-9),
          'every triangle lies inside its BVH leaf box')
FROM tri t JOIN bvh_node n ON n.cl = t.cl,
     LATERAL (SELECT unnest(ARRAY[t.a, t.b, t.c])) AS q(v);

SELECT ok(bool_and((n.lo).x >= (mb.lo).x - 1e-9 AND (n.hi).x <= (mb.hi).x + 1e-9
               AND (n.lo).y >= (mb.lo).y - 1e-9 AND (n.hi).y <= (mb.hi).y + 1e-9
               AND (n.lo).z >= (mb.lo).z - 1e-9 AND (n.hi).z <= (mb.hi).z + 1e-9),
          'every leaf box lies inside its mesh box')
FROM bvh_node n JOIN mesh_box mb USING (mesh_id);

SELECT ok(count(*) = 0, 'every triangle is assigned to a leaf')
FROM tri WHERE cl IS NULL;

-- The point of the whole structure: it must not change any answer.  Compare
-- the accelerated nearest hit against a brute-force scan over every triangle,
-- for a fan of rays chosen to cross all three meshes.
SELECT ok(bool_and(near(fast, brute, 1e-9)),
          'the BVH returns exactly what a brute-force scan returns')
FROM (
  SELECT v3_unit(v3(gx.i / 6.0 - 1.0, gy.j / 6.0 - 0.55, -1)) AS d
  FROM generate_series(0, 12) gx(i), generate_series(0, 12) gy(j)
) AS r,
-- A miss is a sky record with t = 0, not a NULL, so it is compared on the
-- material flag rather than on the distance.
LATERAL (SELECT CASE WHEN (z.h).mat = 0 THEN -1 ELSE (z.h).t END
         FROM (SELECT scene_hit(v3(0.55,2.35,6.70), r.d)) AS z(h)) AS f(fast),
LATERAL (SELECT coalesce(min(x.t), -1) FROM tri t,
         LATERAL (SELECT tri_hit(v3(0.55,2.35,6.70), r.d, t.a, t.b, t.c)) AS x(t)
         WHERE x.t IS NOT NULL) AS s(brute);

-- Rebuilding the index must be idempotent, or repeated edits drift.
SELECT ok(before = after, 'scene_reindex is idempotent')
FROM (SELECT count(*) FROM bvh_node) AS a(before),
     LATERAL (SELECT scene_reindex()) x,
     LATERAL (SELECT count(*) FROM bvh_node) AS b(after);

-- Normals returned by the tracer must always oppose the incoming ray.
SELECT ok(bool_and(v3_dot(d, (scene_hit(v3(0.55,2.35,6.70), d)).n) <= 1e-12),
          'the returned normal always faces the incoming ray')
FROM (SELECT v3_unit(v3(gx.i / 6.0 - 1.0, gy.j / 6.0 - 0.55, -1))
      FROM generate_series(0,12) gx(i), generate_series(0,12) gy(j)) AS q(d);

\echo
\echo == optics ==

-- Snell's law, independently per wavelength.  The ratio of the sines must
-- equal the index of refraction exactly.
SELECT ok(bool_and(near(sin(radians(45.0))
                        / sin(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                                      1.0 / ior_of(m_glass(), k)), v3(0,1,0)))),
                        ior_of(m_glass(), k), 1e-12)),
          'refraction satisfies Snell''s law for every channel')
FROM generate_series(1,3) k;

-- ...and the three channels must actually separate, or there is no dispersion.
SELECT ok(red_out > green_out AND green_out > blue_out AND red_out - blue_out > 1.5,
          'red, green and blue refract to measurably different angles')
FROM (SELECT degrees(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                             1.0 / ior_of(m_glass(), k)), v3(0,1,0))))
      FROM generate_series(1,1) k) AS r(red_out),
     LATERAL (SELECT degrees(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                          1.0 / ior_of(m_glass(), 2)), v3(0,1,0))))) AS g(green_out),
     LATERAL (SELECT degrees(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                          1.0 / ior_of(m_glass(), 3)), v3(0,1,0))))) AS b(blue_out);

-- Total internal reflection must begin exactly at the critical angle.
SELECT ok(v3_refract(v3_unit(v3(sin(crit - 0.01), -cos(crit - 0.01), 0)),
                     v3(0,1,0), ior_of(m_glass(), 2)) IS NOT NULL
          AND v3_refract(v3_unit(v3(sin(crit + 0.01), -cos(crit + 0.01), 0)),
                         v3(0,1,0), ior_of(m_glass(), 2)) IS NULL,
          'total internal reflection starts at the critical angle')
FROM (SELECT asin(1.0 / ior_of(m_glass(), 2))) AS q(crit);

SELECT ok(near(fresnel_dielectric(cos(asin(1.0/ior_of(m_glass(), 2)) + 0.05), ior_of(m_glass(), 2)), 1.0),
          'reflectance is 1 beyond the critical angle');

-- Schlick at normal incidence must reduce to the exact Fresnel value.
SELECT ok(near(fresnel_dielectric(1.0, 1.0 / 1.53),
               power((1.53 - 1.0) / (1.53 + 1.0), 2.0), 1e-12),
          'normal-incidence reflectance matches ((n1-n2)/(n1+n2))^2');

SELECT ok(bool_and(fresnel_dielectric(c, 1.0/1.53) BETWEEN 0.0 AND 1.0),
          'dielectric reflectance stays within [0,1]')
FROM (SELECT g / 100.0 FROM generate_series(0,100) g) AS q(c);

-- Reflectance must rise monotonically from normal towards grazing incidence.
-- This is the property that makes glass look like glass: nearly transparent
-- face-on, mirror-like at a glancing angle.
SELECT ok(bool_and(hi >= lo) AND max(hi) > 0.9 AND min(lo) < 0.05,
          'reflectance grows monotonically towards grazing incidence')
FROM (SELECT fresnel_dielectric(g / 100.0, 1.0/1.53),
             fresnel_dielectric((g - 1) / 100.0, 1.0/1.53)
      FROM generate_series(1,100) g) AS q(lo, hi);

-- Beer-Lambert must attenuate, never amplify, and must do so monotonically.
SELECT ok((beer(ROW(2.0, 0, v3(0,0,0), v3(0,1,0), true)::hit, m_glass())).x
          < (beer(ROW(1.0, 0, v3(0,0,0), v3(0,1,0), true)::hit, m_glass())).x
          AND (beer(ROW(1.0, 0, v3(0,0,0), v3(0,1,0), true)::hit, m_glass())).x < 1.0,
          'absorption grows with path length inside the glass');
SELECT ok(beer(ROW(9.0, 0, v3(0,0,0), v3(0,1,0), false)::hit, m_glass()) = v3(1,1,1),
          'no absorption on a front face -- the ray was outside the medium');
SELECT ok(beer(ROW(9.0, 0, v3(0,0,0), v3(0,1,0), true)::hit, m_metal()) = v3(1,1,1),
          'no absorption in an opaque material');

\echo == transport ==

-- The probe rays must actually land where the checks below assume.
SELECT ok((h_glass()).mat = (m_glass()).mat_id AND NOT (h_glass()).back,
          'the probe ray lands on the front face of the glass block');
SELECT ok((h_metal()).mat = (m_metal()).mat_id,
          'the probe ray lands on the metal ball');

-- A glass hit must spawn a reflection plus one refraction per channel.
SELECT ok(count(*) = 4, 'an undispersed ray entering glass spawns 4 children')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 0, k,
                               m_glass()) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

-- Energy is conserved per wavelength, not across the split: the reflected
-- child carries all three channels while each refracted child carries one.
-- Green uses the same index as the achromatic reflection, so for that channel
-- R + T must come to exactly 1.
SELECT ok(near(refl + trans, 1.0, 1e-12),
          'reflected + transmitted weights sum to 1 for the green channel')
FROM (SELECT v3_maxc((child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 0, 0,
                                m_glass())).att)) AS a(refl),
     LATERAL (SELECT v3_maxc((child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 0, 2,
                                        m_glass())).att)) AS b(trans);

SELECT ok(bool_and(v3_maxc((c.r).att) BETWEEN 0.0 AND 1.0),
          'no child ray amplifies the throughput it was given')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 0, k,
                               m_glass()) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

-- A ray already committed to one wavelength must not split again.
SELECT ok(count(*) = 2, 'a dispersed ray spawns only its own channel plus the mirror')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 2, k,
                               m_glass()) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

-- An opaque surface spawns its mirror ray and nothing else.
SELECT ok(count(*) = 1, 'a metal hit spawns only a reflection')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3(0,-1,0), h_metal(), v3(1,1,1), 0, k,
                               m_metal()) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

-- The dispersed children must leave along measurably different directions,
-- which is the whole point of splitting them.
SELECT ok(NOT ((child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 0, 1, m_glass())).d
             = (child_ray(v3(0,-1,0), h_glass(), v3(1,1,1), 0, 3, m_glass())).d)
          OR near(v3_dot(v3(0,-1,0), (h_glass()).n), -1.0),
          'red and blue refract apart unless the hit is exactly head-on');

-- Shadow rays are only worth firing where the light could show at all.
SELECT ok(wants_light(v3(0,-1,0),
                      ROW(1.0, (m_floor()).mat_id, v3(-6,0,4), v3(0,1,0), false)::hit,
                      m_floor(), l_key()),
          'open floor facing the light wants a shadow ray');
SELECT ok(NOT wants_light(v3(0,-1,0),
                          ROW(1.0, (m_floor()).mat_id, v3(-6,0,4), v3(0,-1,0), false)::hit,
                          m_floor(), l_key()),
          'a surface facing away from the light does not');
SELECT ok(NOT wants_light(v3(0,-1,0), ROW(0.0, 0, v3(0,0,0), v3(0,1,0), false)::hit,
                          NULL::material, l_key()),
          'a ray that escaped to the sky wants nothing');

-- A light behind a surface is rejected for that surface alone: the same hit
-- can want one light and not another, which is what makes lights independent.
SELECT ok(wants_light(v3(0,-1,0), h, m_floor(), l_key())
          AND NOT wants_light(v3(0,-1,0), h, m_floor(), l_under),
          'the same hit wants the light above it and not the one below')
FROM (SELECT ROW(1.0, (m_floor()).mat_id, v3(-6,0,4), v3(0,1,0), false)::hit) AS q(h),
     LATERAL (SELECT ROW(0, 'below', v3(-6,-8,4), v3(1,1,1), 125.0, 0.0, 420.0,
                         v3_unit(v3(-6,-8,4)))::light) AS u(l_under);

\echo
\echo == lights ==

-- Falloff is inverse square, so doubling the distance quarters the irradiance.
-- Checked as a ratio because it holds whatever the light's power happens to be.
SELECT ok(near((v3_maxc(light_rad(v3(0,-1,0), far, m_floor(), l_key(), v3(1,1,1)))
                / v3_maxc(light_rad(v3(0,-1,0), near_h, m_floor(), l_key(), v3(1,1,1)))),
               0.25, 1e-9),
          'irradiance falls off as one over distance squared')
FROM (SELECT ROW(1.0, (m_floor()).mat_id, (l_key()).p - v3(0,2,0), v3(0,1,0), false)::hit,
             ROW(1.0, (m_floor()).mat_id, (l_key()).p - v3(0,1,0), v3(0,1,0), false)::hit)
     AS q(far, near_h);

-- Shadow transmission scales what a light delivers, and blocks it entirely at
-- zero -- which is what a shadow is.
SELECT ok(v3_maxc(light_rad(v3(0,-1,0), h, m_floor(), l_key(), v3(0,0,0))) = 0.0
          AND near(v3_maxc(light_rad(v3(0,-1,0), h, m_floor(), l_key(), v3(0.5,0.5,0.5)))
                   * 2.0,
                   v3_maxc(light_rad(v3(0,-1,0), h, m_floor(), l_key(), v3(1,1,1)))),
          'shadow transmission scales the light linearly and blocks it at zero')
FROM (SELECT ROW(1.0, (m_floor()).mat_id, v3(-6,0,4), v3(0,1,0), false)::hit) AS q(h);

-- Radiance is linear in the light's power.  That is what makes an area light
-- -- several rows sampling one emitter -- add up to the emitter it samples,
-- and it is the property the renderer leans on when it sums pairs.
SELECT ok(near(v3_maxc(light_rad(v3(0,-1,0), h, m_floor(), l_half, v3(1,1,1))) * 2.0,
               v3_maxc(light_rad(v3(0,-1,0), h, m_floor(), l_key(), v3(1,1,1)))),
          'diffuse radiance is linear in the light power')
FROM (SELECT ROW(1.0, (m_floor()).mat_id, v3(-6,0,4), v3(0,1,0), false)::hit) AS q(h),
     LATERAL (SELECT ROW((l_key()).light_id, 'half', (l_key()).p, (l_key()).col,
                         (l_key()).pow / 2.0, 0.0, 420.0,
                         (l_key()).sky_dir)::light) AS u(l_half);

-- The sky disc must sit where the light does, because that is the whole reason
-- it is a column of the light rather than a constant of the sky.
SELECT ok(v3_maxc(sky(v3_unit((l_key()).p))) > v3_maxc(sky(-v3_unit((l_key()).p))),
          'the sky is brightest looking straight at the light');
SELECT ok(near(v3_maxc(sky(v3_unit((l_key()).p)) - sky_bg(v3_unit((l_key()).p))),
               v3_maxc(sky_sun(v3_unit((l_key()).p), l_key()))),
          'the sky is its background plus the light discs');

-- The stored direction is derived, so it cannot drift from the position.
SELECT ok(bool_and(sky_dir = v3_unit(p) AND near(v3_len(sky_dir), 1.0)),
          'every light carries a unit direction matching its position')
FROM light;

-- A light at the origin has no direction, so it is refused rather than
-- silently producing a NULL that would poison the radiance sum.
SELECT ok(raises($$INSERT INTO light (name, p) VALUES ('nowhere', ROW(0,0,0)::vec3)$$),
          'a light at the world origin is refused');

\echo
\echo == end to end ==

SELECT render(24, 16, 1, 3);
SELECT ok(count(*) = 24 * 16, 'render fills every pixel exactly once') FROM img;
SELECT ok(bool_and(r BETWEEN 0 AND 255 AND g BETWEEN 0 AND 255 AND b BETWEEN 0 AND 255),
          'all samples are within 8-bit range') FROM img;
SELECT ok(count(DISTINCT (r,g,b)) > 8, 'the render is not a flat fill') FROM img;
SELECT ok(length(png_encode(24, 16, png_scanlines('img'))) = 8 + 25 + 12 + 12
                                                             + length(zlib_stored(png_scanlines('img'))),
          'PNG length is signature + IHDR + IDAT + IEND');

-- The two halves of "lights are rows": a second light must travel the whole
-- pipeline -- its own shadow ray per lit hit, its own row in every pair join,
-- its own term in every sum -- and it must change the picture by exactly what
-- it emits.  A light emitting nothing is the sharper of the two checks: it
-- drags all of that machinery through the renderer and must still be invisible.
DROP TABLE IF EXISTS one_light;
CREATE TEMP TABLE one_light AS SELECT * FROM img;

INSERT INTO light (name, p, col, pow)
VALUES ('dark', ROW(-4.0, 6.0, 5.0)::vec3, ROW(0, 0, 0)::vec3, 90.0);
SELECT render(24, 16, 1, 3);
SELECT ok(count(*) = 0, 'a light that emits nothing changes no pixel')
FROM img i JOIN one_light o USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (o.r, o.g, o.b);
DELETE FROM light WHERE name = 'dark';

INSERT INTO light (name, p, col, pow)
VALUES ('fill', ROW(-5.0, 3.0, 4.0)::vec3, ROW(0.25, 0.40, 1.00)::vec3, 140.0);
SELECT render(24, 16, 1, 3);
SELECT ok(count(*) > 20, 'a blue fill light lifts the blue channel of the frame')
FROM img i JOIN one_light o USING (x, y) WHERE i.b > o.b;
DELETE FROM light WHERE name = 'fill';
