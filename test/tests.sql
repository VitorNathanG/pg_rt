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

SELECT ok(near(hit_plane(v3(0,3,0), v3(0,-1,0)), 3.0), 'ray/plane distance');
SELECT ok(hit_plane(v3(0,3,0), v3(0,1,0)) IS NULL, 'ray/plane miss when pointing up');
SELECT ok(near(hit_sphere(v3(0,0,5), v3(0,0,-1), v3(0,0,0), 1.0), 4.0),
          'ray/sphere front-face distance');
SELECT ok(near(hit_sphere(v3(0,0,0), v3(0,0,-1), v3(0,0,0), 1.0), 1.0),
          'ray/sphere from inside returns the exit');
SELECT ok(hit_sphere(v3(0,5,5), v3(0,0,-1), v3(0,0,0), 1.0) IS NULL, 'ray/sphere miss');

-- Entering the cube head-on, then leaving it from the inside.  A ray down the
-- centre axis crosses the local +z face, so it travels 6 less e/cos(yaw) --
-- not the cube's z-extent, which a corner away from the axis would set.
SELECT ok(near(hit_cube(cub_c() + v3(0,0,6), v3(0,0,-1)),
               6.0 - cub_h() / cos(cub_yaw()), 1e-9),
          'ray/cube entry hits the rotated face');
SELECT ok(hit_cube(cub_c(), v3(1,0,0)) > 0, 'ray/cube from inside returns the exit face');
SELECT ok(hit_cube(cub_c() + v3(0,20,0), v3(0,1,0)) IS NULL, 'ray/cube miss');
SELECT ok(near(v3_len(cube_normal(cub_c() + v3(0, cub_h(), 0))), 1.0)
          AND near(v3_dot(cube_normal(cub_c() + v3(0, cub_h(), 0)), v3(0,1,0)), 1.0),
          'cube normal on the top face points straight up');

-- scene_hit must always hand back a normal facing the incoming ray.
SELECT ok(bool_and(v3_dot(d, (scene_hit(v3(0,2,7), d)).n) <= 1e-12),
          'scene_hit normals always oppose the ray')
FROM (SELECT v3_unit(v3(x/9.0 - 0.5, y/9.0 - 0.35, -1))
      FROM generate_series(0,9) x, generate_series(0,9) y) AS q(d);

\echo
\echo == optics ==

-- Snell's law, independently per wavelength.  The ratio of the sines must
-- equal the index of refraction exactly.
SELECT ok(bool_and(near(sin(radians(45.0))
                        / sin(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                                      1.0 / glass_ior(k)), v3(0,1,0)))),
                        glass_ior(k), 1e-12)),
          'refraction satisfies Snell''s law for every channel')
FROM generate_series(1,3) k;

-- ...and the three channels must actually separate, or there is no dispersion.
SELECT ok(red_out > green_out AND green_out > blue_out AND red_out - blue_out > 1.5,
          'red, green and blue refract to measurably different angles')
FROM (SELECT degrees(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                             1.0 / glass_ior(k)), v3(0,1,0))))
      FROM generate_series(1,1) k) AS r(red_out),
     LATERAL (SELECT degrees(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                          1.0 / glass_ior(2)), v3(0,1,0))))) AS g(green_out),
     LATERAL (SELECT degrees(acos(-v3_dot(v3_refract(v3_unit(v3(1,-1,0)), v3(0,1,0),
                                          1.0 / glass_ior(3)), v3(0,1,0))))) AS b(blue_out);

-- Total internal reflection must begin exactly at the critical angle.
SELECT ok(v3_refract(v3_unit(v3(sin(crit - 0.01), -cos(crit - 0.01), 0)),
                     v3(0,1,0), glass_ior(2)) IS NOT NULL
          AND v3_refract(v3_unit(v3(sin(crit + 0.01), -cos(crit + 0.01), 0)),
                         v3(0,1,0), glass_ior(2)) IS NULL,
          'total internal reflection starts at the critical angle')
FROM (SELECT asin(1.0 / glass_ior(2))) AS q(crit);

SELECT ok(near(fresnel_dielectric(cos(asin(1.0/glass_ior(2)) + 0.05), glass_ior(2)), 1.0),
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
SELECT ok((beer(ROW(2.0, 3, v3(0,0,0), v3(0,1,0), true)::hit)).x
          < (beer(ROW(1.0, 3, v3(0,0,0), v3(0,1,0), true)::hit)).x
          AND (beer(ROW(1.0, 3, v3(0,0,0), v3(0,1,0), true)::hit)).x < 1.0,
          'absorption grows with path length inside the glass');
SELECT ok(beer(ROW(9.0, 1, v3(0,0,0), v3(0,1,0), false)::hit) = v3(1,1,1),
          'no absorption outside the glass');

\echo
\echo == transport ==

-- A glass hit must spawn a reflection plus one refraction per channel.  The
-- ray is aimed down the cube's axis so it actually lands on the top face; a
-- steeper angle drifts past the cube and hits the floor instead.
SELECT ok(count(*) = 4, 'an undispersed ray entering glass spawns 4 children')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3_unit(v3(0.05,-1,0.03)),
                               scene_hit(cub_c() + v3(0,6,0), v3_unit(v3(0.05,-1,0.03))),
                               v3(1,1,1), 0, k) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

-- Energy is conserved per wavelength, not across the split: the reflected
-- child carries all three channels while each refracted child carries one.
-- Green uses the same index as the achromatic reflection, so for that channel
-- R + T must come to exactly 1.
SELECT ok(near(refl + trans, 1.0, 1e-12),
          'reflected + transmitted weights sum to 1 for the green channel')
FROM (SELECT v3_unit(v3(0.05,-1,0.03))) AS q(d),
     LATERAL (SELECT scene_hit(cub_c() + v3(0,6,0), d) OFFSET 0) AS s(h),
     LATERAL (SELECT v3_maxc((child_ray(d, s.h, v3(1,1,1), 0, 0)).att)) AS a(refl),
     LATERAL (SELECT v3_maxc((child_ray(d, s.h, v3(1,1,1), 0, 2)).att)) AS b(trans);

SELECT ok(bool_and(v3_maxc((c.r).att) BETWEEN 0.0 AND 1.0),
          'no child ray amplifies the throughput it was given')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3_unit(v3(0.05,-1,0.03)),
                               scene_hit(cub_c() + v3(0,6,0), v3_unit(v3(0.05,-1,0.03))),
                               v3(1,1,1), 0, k) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

-- A ray already committed to one wavelength must not split again.
SELECT ok(count(*) = 2, 'a dispersed ray spawns only its own channel plus the mirror')
FROM generate_series(0,3) k,
     LATERAL (SELECT child_ray(v3_unit(v3(0.05,-1,0.03)),
                               scene_hit(cub_c() + v3(0,6,0), v3_unit(v3(0.05,-1,0.03))),
                               v3(1,1,1), 2, k) OFFSET 0) AS c(r)
WHERE (c.r).d IS NOT NULL;

SELECT ok((shadow_att(v3(-2.5,0.001,0.3), v3_unit(light_p() - v3(-2.5,0,0.3)),
                      v3_len(light_p() - v3(-2.5,0,0.3)))).x = 0.0,
          'the metal sphere casts an opaque shadow');
SELECT ok(v3_maxc(shadow_att(v3(-9,0.001,7), v3_unit(light_p() - v3(-9,0,7)),
                             v3_len(light_p() - v3(-9,0,7)))) = 1.0,
          'open floor is unshadowed');

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
