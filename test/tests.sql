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

-- The verbose plan of a query, as one string.  Inlining leaves no trace in the
-- shape of a plan, but it does leave one in the expressions: a function that
-- folded into its caller stops appearing by name in the Output line.
CREATE OR REPLACE FUNCTION plan_of(q text) RETURNS text AS $$
DECLARE r text; acc text := '';
BEGIN
  FOR r IN EXECUTE 'EXPLAIN (VERBOSE, COSTS OFF) ' || q LOOP
    acc := acc || r || E'\n';
  END LOOP;
  RETURN acc;
END $$ LANGUAGE plpgsql;

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
\echo == deflate ==

-- Four streams produced by a real zlib, decoded here.
--
-- These are the only checks in the file with an oracle outside this repository,
-- and that is the whole point of them.  Everything else about the codec is
-- verified by compressing and then decompressing, which passes just as happily
-- when the encoder and the decoder are wrong in the same direction -- a
-- mirrored bit order, a mis-numbered code table.  A byte string this
-- repository did not produce cannot agree with a private mistake.
SELECT ok(inflate('\x2bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a75b8379e88a8b7352530b8af500'::bytea)
          = convert_to('the quick brown fox jumps over the lazy dog; '
                    || 'the quick brown fox sleeps.', 'SQL_ASCII'),
          'inflate reads a dynamic-Huffman block written by zlib');
SELECT ok(inflate('\x4b4c048224100000'::bytea) = 'aaaaabbbbb'::bytea,
          'inflate reads a fixed-Huffman block written by zlib');
SELECT ok(inflate('\x010400fbff00010203'::bytea) = '\x00010203'::bytea,
          'inflate reads a stored block written by zlib');
SELECT ok(zlib_inflate('\x78da0bc82f2e492f4a0d0ef4010015f403d5'::bytea) = 'PostgreSQL'::bytea,
          'zlib_inflate reads a real zlib stream, checksum and all');

-- Every level must round-trip every shape.  The shapes are chosen for the
-- branches they reach rather than for variety: an empty and a one-byte buffer
-- for the degenerate trees, a long run for the 258-byte match cap, prose for
-- ordinary matching, zeroes for a single dominant symbol, and md5 output for
-- input with nothing in it to find.
SELECT ok(bool_and(inflate(deflate(b, lvl)) = b),
          'deflate round-trips through inflate at every level')
FROM (VALUES (''::bytea), ('A'::bytea), ('AB'::bytea),
             (decode(repeat('61', 1000), 'hex')),
             (convert_to(repeat('the quick brown fox jumps over the lazy dog. ', 50),
                         'SQL_ASCII')),
             (decode(repeat('00', 5000), 'hex')),
             ((SELECT decode(string_agg(md5(g::text), ''), 'hex')
               FROM generate_series(1, 500) AS g))) AS v(b),
     generate_series(0, 9) AS lvl;

SELECT ok(bool_and(zlib_inflate(zlib_deflate(b, lvl)) = b),
          'the zlib wrapper round-trips at every level')
FROM (VALUES (''::bytea), ('A'::bytea),
             (convert_to(repeat('abcabcabd', 200), 'SQL_ASCII'))) AS v(b),
     generate_series(0, 9) AS lvl;

SELECT ok(length(deflate(convert_to(repeat('the quick brown fox. ', 400), 'SQL_ASCII'), 6)) * 20
          < 8400,
          'a repetitive buffer compresses by more than 20x');

-- 20000 bytes of one value is 77 matches at the 258-byte cap, and 258 is the
-- length that has its own code.  Reaching it the other way -- code 284 with
-- all five extra bits set -- also decodes to 258, so nothing round-trips
-- differently and only the size says which was used: 37 bytes against 85.
SELECT ok(length(deflate(decode(repeat('61', 20000), 'hex'), 6)) < 50,
          'the longest match uses length code 285 rather than 284 plus extra bits');

-- The property the block chooser exists to guarantee, and the one that caught
-- the cost model leaving out extra bits: incompressible input must never come
-- back bigger than a stored block, however tempting the Huffman estimate
-- looks.  70000 bytes also puts it over the 65535 stored-block limit, so the
-- multi-block path is on the same check.
SELECT ok(length(deflate(b, 6)) <= length(b) + 5 * (length(b) / 65535 + 1),
          'incompressible input never grows past a stored block')
FROM (SELECT decode(string_agg(md5(g::text), ''), 'hex')
      FROM generate_series(1, 4375) AS g) AS q(b);

-- Twenty symbols with Fibonacci frequencies, shuffled by md5 so the match
-- finder has nothing to collapse.  That distribution wants a 19-deep tree and
-- DEFLATE allows 15, so this is the input that makes the cap load-bearing
-- rather than theoretical -- and it has to reach the encoder through deflate()
-- itself, because a tree deep enough to be illegal is emitted as a legal-
-- looking stream that decodes to rubbish.
SELECT ok(inflate(deflate(v, 6)) = v AND length(deflate(v, 6)) < length(v),
          'a distribution that wants codes longer than 15 bits still round-trips')
FROM (WITH RECURSIVE fib(i, a, b) AS (
        SELECT 0, 1::bigint, 1::bigint
        UNION ALL SELECT i + 1, b, a + b FROM fib WHERE i < 19)
      SELECT decode(string_agg(lpad(to_hex(i), 2, '0'), ''
                               ORDER BY md5((i * 99991 + k)::text)), 'hex')
      FROM fib, generate_series(1, a) AS k) AS q(v);

-- The far edge of the window, from both sides.  A 64-byte block is repeated at
-- distance 32768, which is the largest DEFLATE can encode, and again at 32769,
-- which it cannot.  The first must be found and the second must be passed over
-- -- and getting the boundary wrong by one is not a missed byte of ratio, it
-- is a distance with no code to write it in.
SELECT ok(bool_and(inflate(d) = v)
          AND bool_or(gap = 32768 AND length(d) < length(v))
          AND bool_or(gap = 32769 AND length(d) > length(v)),
          'a match at distance 32768 is used and one at 32769 is not')
FROM (SELECT gap, p || substring(fill FROM 1 FOR gap - 64) || p
      FROM generate_series(32768, 32769) AS gap,
           (SELECT decode(string_agg(md5((g * 7)::text), ''), 'hex')
            FROM generate_series(1, 4) AS g) AS a(p),
           (SELECT decode(string_agg(md5((g * 13 + 1)::text), ''), 'hex')
            FROM generate_series(1, 2100) AS g) AS b(fill)) AS q(gap, v),
     LATERAL (SELECT deflate(v, 6)) AS z(d);

-- Reading a bytea out of a table is the case that goes quadratic if anyone
-- forgets to detoast: the argument arrives as a pointer, and `get_byte`
-- resolves it again on every call.  The timeout is what makes this a test
-- rather than a comment, because both answers are *correct* and only one of
-- them finishes -- 1.6 s here against about two minutes without, on 512 kB.
-- The gap is wide enough that the threshold is not delicate.
-- Both columns are stored, so both directions are exercised against a pointer
-- rather than against a value that happens to still be in memory.
CREATE TEMP TABLE toasty AS
SELECT b, deflate(b, 6) AS z
FROM (SELECT decode(string_agg(md5(s.g::text), ''), 'hex')
      FROM generate_series(1, 32768) AS s(g)) AS q(b);

SET statement_timeout = '20s';
SELECT ok(deflate((SELECT b FROM toasty), 6) = (SELECT z FROM toasty)
          AND inflate((SELECT z FROM toasty)) = (SELECT b FROM toasty)
          AND adler32((SELECT b FROM toasty)) > 0
          AND crc32((SELECT b FROM toasty)) > 0,
          'a bytea read from a table is read once, not once per byte');
RESET statement_timeout;

SELECT ok(raises($$SELECT zlib_inflate('\x78da0bc82f2e492f4a0d0ef4010015f403d6'::bytea)$$),
          'zlib_inflate rejects a stream whose Adler-32 does not match');
SELECT ok(raises($$SELECT zlib_inflate('\x0000'::bytea)$$),
          'zlib_inflate rejects a header that is not deflate');
SELECT ok(raises($$SELECT inflate('\x07'::bytea)$$),
          'inflate rejects the reserved block type');

-- A stored block repeats its length inverted, and that is the only integrity
-- check DEFLATE has before the zlib trailer.  The same block with the last
-- NLEN byte changed from ff to fe still has a length that looks perfectly
-- reasonable, so a decoder that skips the comparison copies four bytes and
-- reports success.
SELECT ok(inflate('\x010400fbff00010203'::bytea) = '\x00010203'::bytea
          AND raises($$SELECT inflate('\x010400fbfe00010203'::bytea)$$),
          'inflate rejects a stored block whose NLEN is not ~LEN');

-- Kraft equality: a prefix code is complete exactly when its lengths use up
-- all the code space.  Short of decoding something, this is the strongest
-- statement that can be made about a set of code lengths, and it fails for
-- every off-by-one a tree builder can make.  The sum is exact in float8 --
-- every term is a power of two no smaller than 2^-15.
SELECT ok(sum(2.0 ^ (-len)) = 1.0, 'huff_lengths produces a complete code')
FROM unnest(huff_lengths((SELECT array_agg((g * 37 + 11) % 97 + 1)
                          FROM generate_series(1, 286) AS g))) AS u(len)
WHERE len > 0;

-- Fibonacci weights are the worst case for tree depth -- each merge is only
-- just heavier than the next leaf -- so 40 of them build a 39-deep tree that
-- DEFLATE cannot express.  The cap has to bite here, and the result has to
-- still be a complete code.
SELECT ok(max(len) <= 15 AND sum(2.0 ^ (-len)) = 1.0,
          'code lengths stay within 15 bits on a Fibonacci-shaped distribution')
FROM (WITH RECURSIVE fib(i, a, b) AS (
        SELECT 1, 1::bigint, 1::bigint
        UNION ALL SELECT i + 1, b, a + b FROM fib WHERE i < 40)
      SELECT unnest(huff_lengths((SELECT array_agg(a ORDER BY i) FROM fib)))) AS u(len)
WHERE len > 0;

-- The decoder walks `sym` in canonical order and uses `cnt` to know where each
-- length's run ends, so those two have to agree with each other and with the
-- lengths: every used symbol listed exactly once, sorted by length, and
-- counted.  A symbol dropped or transposed here decodes into plausible
-- rubbish rather than failing.
SELECT ok(array_length(t.sym, 1) = (SELECT count(*) FROM unnest(q.lens) AS x(v) WHERE v > 0)
          AND (SELECT sum(c) FROM unnest(t.cnt) AS u(c)) = array_length(t.sym, 1)
          AND (SELECT bool_and(q.lens[t.sym[i] + 1] <= q.lens[t.sym[i + 1] + 1])
               FROM generate_series(1, array_length(t.sym, 1) - 1) AS i),
          'huff_decode_table lists every used symbol once, in canonical order')
FROM (SELECT array_agg((g * 37 + 11) % 9 + (g % 4) ORDER BY g)
      FROM generate_series(1, 100) AS g) AS q(lens),
     LATERAL huff_decode_table(q.lens) AS t;

\echo
\echo == png filters ==

-- The Paeth predictor picks whichever neighbour is closest to the linear
-- estimate a + b - c.  The three cases have to be checked separately because
-- the cancelled form this file uses -- |b-c|, |a-c|, |a+b-2c| -- shares no
-- subexpression with the definition it replaces.
SELECT ok(paeth(10, 20, 30) = 10, 'Paeth picks left when it is nearest');
SELECT ok(paeth(0, 100, 0) = 100, 'Paeth picks above');
SELECT ok(paeth(100, 0, 50) = 50, 'Paeth picks upper-left');
SELECT ok(paeth(7, 7, 7) = 7, 'Paeth on three equal neighbours is that value');

\echo == png decoding ==

-- Reading a PNG back exercises the three pieces that had never been run in
-- this direction -- png_idat, zlib_inflate, png_unfilter -- and a mistake in
-- any of them produces pixels rather than an error.  So the check is an
-- identity against the table the PNG was made from, not a plausibility test.
CREATE TEMP TABLE t_img AS
SELECT x, y, (x * 7 + y * 3) % 256 AS r, (x * x + y) % 256 AS g,
       (x + y * y * 5) % 256 AS b
FROM generate_series(0, 23) AS gx(x), generate_series(0, 17) AS gy(y);

SELECT ok(w = 24 AND h = 18, 'png_size reads the dimensions out of IHDR')
FROM png_size(png_encode(24, 18, png_scanlines('t_img')));

SELECT ok(length(png_raw(png_encode(24, 18, png_scanlines('t_img')))) = 24 * 18 * 3,
          'png_raw returns three bytes a pixel');

SELECT ok(count(*) = 0, 'a PNG decodes back to exactly the pixels it was made from')
FROM png_pixels(png_encode(24, 18, png_scanlines('t_img'))) AS d
     FULL JOIN t_img i ON i.x = d.x AND i.y = d.y
WHERE d.r IS DISTINCT FROM i.r OR d.g IS DISTINCT FROM i.g
   OR d.b IS DISTINCT FROM i.b;

-- The same, through every filter, because the decoder undoes all five and only
-- the one the encoder happened to choose is covered above.
SELECT ok(bool_and(png_raw(png_encode(24, 18, png_scanlines('t_img', f)))
                   = png_raw(png_encode(24, 18, png_scanlines('t_img', 0)))),
          'all five scanline filters reconstruct the same pixels')
FROM generate_series(0, 4) AS g(f);

SELECT ok(raises($$SELECT png_size('\x00010203'::bytea)$$),
          'something that is not a PNG is refused rather than decoded');

\echo
\echo == gif ==

-- ## The codec
--
-- A hand-derived vector, because a round trip only proves the two halves agree
-- with each other.  Six copies of byte 1 at a minimum code size of 2 emit the
-- codes 4 (clear), 1, 6, 7, 5 (end), all three bits wide, packed
-- least-significant-bit first: 0x8c 0x5f.
SELECT ok(gif_lzw('\x010101010101'::bytea, 2) = '\x8c5f'::bytea,
          'LZW emits the bytes worked out by hand from the format');

-- Round trips at every legal code size and past the point where the dictionary
-- fills and has to be cleared.  Code-width growth is the mistake this catches:
-- an encoder that widens one code early or late produces a stream that decodes
-- into plausible rubbish rather than failing.
SELECT ok(bool_and(gif_unlzw(gif_lzw(b, mc), mc) = b),
          'LZW round trips at every minimum code size')
FROM generate_series(2, 8) AS m(mc),
     LATERAL (SELECT decode(string_agg(lpad(to_hex(i % (1 << mc)), 2, '0'), ''), 'hex')
              FROM generate_series(1, 9000) AS g(i)) AS q(b);

-- Long, and deliberately incompressible: a stream with no repeated pairs
-- invents a dictionary entry per byte, so this fills all 4096 and clears them
-- dozens of times.  It is also the case where LZW comes out larger than it went
-- in, which is legal and worth having pass through unharmed.
SELECT ok(gif_unlzw(gif_lzw(b, 8), 8) = b AND length(gif_lzw(b, 8)) > length(b),
          'LZW round trips input long enough to fill and reset the dictionary')
FROM (SELECT decode(string_agg(md5(g::text), ''), 'hex')
      FROM generate_series(1, 7500) AS g) AS q(b);

SELECT ok(gif_unlzw(gif_lzw(''::bytea, 8), 8) = ''::bytea,
          'an empty image is a clear and an end code');

SELECT ok(raises($$SELECT gif_lzw('\x00'::bytea, 1)$$),
          'a minimum code size below 2 is refused');

-- Sub-blocks: runs of 255 with their own length byte, and a zero to finish.
SELECT ok(length(gif_blocks(b)) = 604
      AND get_byte(gif_blocks(b), 0)   = 255
      AND get_byte(gif_blocks(b), 256) = 255
      AND get_byte(gif_blocks(b), 512) = 90
      AND get_byte(gif_blocks(b), 603) = 0,
          'sub-block framing splits at 255 and terminates')
FROM (SELECT decode(repeat('aa', 600), 'hex')) AS q(b);

SELECT ok(gif_blocks(''::bytea) = '\x00'::bytea,
          'no data is still a terminator');

-- ## The quantiser
--
-- An image with few enough colours to fit the palette must come back exactly.
-- This is the check that the whole chain -- histogram, median cut, weighted
-- means, nearest-entry lookup -- is lossless when it has no reason not to be,
-- and it is worth more than a tolerance because the failure modes here (a
-- dropped box, a wrong mean, an off-by-one index) all survive a tolerance.
CREATE TEMP TABLE t_four AS
SELECT x, y,
       CASE WHEN x < 8 AND y < 8 THEN 255 WHEN x < 8 THEN 0
            WHEN y < 8 THEN 17 ELSE 200 END AS r,
       CASE WHEN x < 8 AND y < 8 THEN 0   WHEN x < 8 THEN 128
            WHEN y < 8 THEN 240 ELSE 200 END AS g,
       CASE WHEN x < 8 AND y < 8 THEN 0   WHEN x < 8 THEN 64
            WHEN y < 8 THEN 9 ELSE 200 END AS b
FROM generate_series(0, 15) AS gx(x), generate_series(0, 15) AS gy(y);

SELECT gif_hist_reset();
SELECT gif_hist_add('t_four');
SELECT ok((SELECT count(*) FROM gif_hist) = 4
      AND (SELECT sum(n) FROM gif_hist) = 256,
          'the histogram is one row a colour and accounts for every pixel');

SELECT ok(gif_palette(256) = 4,
          'a four-colour image needs four palette entries, not 256');

SELECT ok(count(*) = 4, 'and they are that image''s colours, exactly')
FROM gif_pal p JOIN (SELECT DISTINCT r, g, b FROM t_four) s
  ON s.r = p.r AND s.g = p.g AND s.b = p.b;

SELECT ok(bool_and(p.r = t.r AND p.g = t.g AND p.b = t.b) AND count(*) = 256,
          'with no dither every pixel maps back to its own colour')
FROM (SELECT gs AS k, get_byte(gif_indices('t_four', 0.0), gs) AS i
      FROM generate_series(0, 255) AS gs) AS ix
     JOIN gif_pal p ON p.i = ix.i
     JOIN t_four t ON t.x = ix.k % 16 AND t.y = ix.k / 16;

-- A colour table is a power of two long, so asking for a size that is not one
-- has to mean something definite rather than being rejected or rounded twice.
SELECT ok(gif_palette(100) <= 64, 'a palette size rounds down to a power of two');

-- The histogram is what makes one palette serve a whole animation, so adding a
-- second image has to accumulate rather than replace.
SELECT gif_hist_add('t_img');
SELECT ok((SELECT sum(n) FROM gif_hist) = 256 + 24 * 18,
          'a second image folds into the histogram rather than replacing it');

-- ## The container
--
-- The header is fixed-width up to the first sub-block, so its length is
-- arithmetic: 6 signature + 7 screen descriptor + 3 * 4 colour table
-- + 8 graphic control + 10 image descriptor + 1 code size.  Checking the
-- offset pins the layout; decoding from it proves the pixels survived.
SELECT gif_hist_reset();
SELECT gif_hist_add('t_four');
SELECT gif_palette(4);

CREATE TEMP TABLE t_gif AS SELECT gif_of('t_four', 4, 0.0) AS g;

SELECT ok(substring(g from 1 for 6) = convert_to('GIF89a', 'SQL_ASCII')
      AND substring(g from length(g) for 1) = '\x3b'::bytea
      AND get_byte(g, 10) = 241            -- global table, 8-bit source, 4 entries
      AND get_byte(g, 6) = 16 AND get_byte(g, 8) = 16,
          'the header says GIF89a, 16x16, four colours, and the file ends')
FROM t_gif;

SELECT ok(gif_unlzw(substring(g from 46 for get_byte(g, 44)), 2)
          = gif_indices('t_four', 0.0),
          'the image data decodes back to the indices that went in')
FROM t_gif;

-- A single image has nothing to loop, so the Netscape block is only written
-- when there is more than one frame to loop over.
SELECT ok(position(convert_to('NETSCAPE2.0', 'SQL_ASCII') in g) = 0,
          'a one-frame GIF carries no loop extension')
FROM t_gif;

SELECT ok(position(convert_to('NETSCAPE2.0', 'SQL_ASCII') in
                   gif_encode(16, 16, ARRAY[gif_image(gif_indices('t_four', 0.0)),
                                            gif_image(gif_indices('t_four', 0.0))],
                              ARRAY[7, 7])) > 0,
          'a two-frame GIF carries one');

SELECT ok(raises($$SELECT gif_encode(16, 16, ARRAY[]::bytea[])$$),
          'a GIF with no images is refused');

DROP TABLE t_gif, t_four, t_img;

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

-- Across a coordinate change, so the corners are transformed before they are
-- compared: leaf boxes are in the mesh's own space and the mesh box is in the
-- world.  Written naively this passes for the wrong reason whenever every
-- transform happens to be the identity, and starts failing the moment one is
-- not -- which is exactly when it would be worth having.
SELECT ok(bool_and((w).x >= (mb.lo).x - 1e-9 AND (w).x <= (mb.hi).x + 1e-9
               AND (w).y >= (mb.lo).y - 1e-9 AND (w).y <= (mb.hi).y + 1e-9
               AND (w).z >= (mb.lo).z - 1e-9 AND (w).z <= (mb.hi).z + 1e-9),
          'every leaf box lies inside its mesh box')
FROM bvh_node n
     JOIN mesh_box mb USING (mesh_id)
     JOIN mesh m USING (mesh_id),
     LATERAL (SELECT m34_point(m.xform, cx.x, cy.y, cz.z)
              FROM (VALUES ((n.lo).x), ((n.hi).x)) AS cx(x),
                   (VALUES ((n.lo).y), ((n.hi).y)) AS cy(y),
                   (VALUES ((n.lo).z), ((n.hi).z)) AS cz(z)) AS corner(w);

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
-- The brute-force side transforms the ray per mesh too.  It has to: without
-- it this would compare an accelerated hit that respects mesh.xform against a
-- scan that does not, and the check would fail on any moved scene while the
-- renderer was perfectly correct.
LATERAL (SELECT coalesce(min(x.t), -1)
         FROM tri t
              JOIN mesh m USING (mesh_id)
              CROSS JOIN LATERAL m34_ray(m, v3(0.55,2.35,6.70), r.d) AS o,
              LATERAL (SELECT tri_hit(o.oo, o.od, t.a, t.b, t.c)) AS x(t)
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
\echo == transforms ==

SELECT ok(m34_inverse(m34_identity()) = m34_identity(),
          'the identity transform inverts to itself');

-- A transform composed with its own inverse has to be the identity map, and
-- checking it on points rather than on the matrix is what catches the affine
-- mistake: inverting the linear part and negating the translation separately
-- looks right and is wrong, because the translation has to go through the
-- inverted linear part as well.
SELECT ok(bool_and(near((rt).x, (p).x, 1e-12)
              AND near((rt).y, (p).y, 1e-12)
              AND near((rt).z, (p).z, 1e-12)),
          'a transform composed with its inverse is the identity on points')
FROM (VALUES (v3(1,2,3)), (v3(-4,0.5,7)), (v3(0,0,0))) AS q(p),
     (VALUES (m34_place(2.0, 0.7, v3(3,-1,4))),
             (m34_scale(0.5, 3.0, 2.0, v3(-2,1,0)))) AS x(m),
     LATERAL (SELECT m34_point(m34_inverse(x.m), (f).x, (f).y, (f).z)
              FROM (SELECT m34_point(x.m, (q.p).x, (q.p).y, (q.p).z)) AS s(f))
       AS r(rt);

-- A mesh scaled to nothing has no object space to carry a ray into, and the
-- failure is far easier to read here than as a frame full of NaN.
SELECT ok(raises($$SELECT m34_inverse(m34_scale(1.0, 0.0, 1.0, v3(0,0,0)))$$),
          'a singular transform is refused rather than returning infinities');

-- make_hit normalises the transformed normal itself, so it takes the raw one.
-- If these two ever disagree in direction the renderer and every other caller
-- are shading different surfaces.
SELECT ok(bool_and(near(v3_len(tri_shading_normal(t, bc)
                              - v3_unit(tri_shading_normal_raw(t, bc))), 0.0, 1e-12)),
          'the raw shading normal points where the normalised one does')
FROM tri t, (VALUES (v3(0.2,0.3,0.5)), (v3(0.7,0.2,0.1))) AS q(bc)
WHERE t.na IS NOT NULL;

-- The claim that makes this feature worth having: a move is one row.  If
-- either of these changed, an animation would be paying to rebuild the
-- acceleration structure at every frame, which is the thing being avoided.
CREATE TEMP TABLE geom_before AS
SELECT (SELECT count(*) FROM tri) AS ntri,
       (SELECT md5(string_agg(tri_id || ':' || cl || ':' || ax || ',' || ay || ',' || az,
                              ',' ORDER BY tri_id)) FROM tri) AS trihash,
       (SELECT md5(string_agg(cl || ':' || lox || ',' || hiz, ',' ORDER BY cl))
          FROM bvh_node) AS bvhhash,
       (SELECT (mb.lo).y FROM mesh_box mb JOIN mesh m USING (mesh_id)
         WHERE m.name = 'ball') AS ball_lo_y;

SELECT mesh_place('ball', m34_place(1.0, 0.0, v3(0, 0.5, 0)));

SELECT ok((SELECT md5(string_agg(tri_id || ':' || cl || ':' || ax || ',' || ay || ',' || az,
                                 ',' ORDER BY tri_id)) FROM tri) = trihash
      AND (SELECT count(*) FROM tri) = ntri,
          'moving a mesh rewrites no triangle')
FROM geom_before;

SELECT ok((SELECT md5(string_agg(cl || ':' || lox || ',' || hiz, ',' ORDER BY cl))
             FROM bvh_node) = bvhhash,
          'moving a mesh rebuilds no BVH node')
FROM geom_before;

-- ... and the one thing it must change, or the mesh gets culled against where
-- it used to be and vanishes with nothing to say so.
SELECT ok(near((SELECT (mb.lo).y FROM mesh_box mb JOIN mesh m USING (mesh_id)
                 WHERE m.name = 'ball'), ball_lo_y + 0.5, 1e-12),
          'moving a mesh moves its world box, without a reindex')
FROM geom_before;

-- Against the ground truth: a mesh moved by transform must be in the same
-- place as a mesh whose vertices were built there.  Distances agree to about
-- one ULP, which is what says the transform is exact rather than merely close.
SELECT ok(near((scene_hit(v3(-1.15, 1.5, 6.0), v3(0,0,-1))).t, 5.2, 1e-9),
          'a translated mesh is hit where the translation says it is');

SELECT mesh_place('ball', m34_identity());

-- Non-uniform scale is the case that separates a correct normal from a
-- plausible one.  Under a scale of (1, 3, 1) the surface tilts one way and a
-- normal carried by the transform itself tilts the other; only the inverse
-- transpose stays perpendicular.  Checked against the transformed triangle's
-- own geometric normal, which is ground truth by construction.
SELECT ok(bool_and(near(abs(v3_dot(v3_unit(nt), v3_unit(ng))), 1.0, 1e-9)),
          'a normal under non-uniform scale rides the inverse transpose')
FROM (SELECT m34_scale(1.0, 3.0, 1.0, v3(0,0,0)) AS m) AS x,
     LATERAL (SELECT m34_inverse(x.m) AS im) AS y,
     (VALUES (v3(0,0,0), v3(1,0,0), v3(0,1,0)),
             (v3(1,2,3), v3(0,1,1), v3(2,0,1)),
             (v3(-1,0.5,2), v3(1,1,0), v3(0,2,1))) AS t(a, b, c),
     -- the object-space facet normal, put through the inverse transpose
     LATERAL (SELECT tri_normal(t.a, t.b, t.c)) AS o(n),
     LATERAL (SELECT v3((y.im).xx * (o.n).x + (y.im).yx * (o.n).y + (y.im).zx * (o.n).z,
                        (y.im).xy * (o.n).x + (y.im).yy * (o.n).y + (y.im).zy * (o.n).z,
                        (y.im).xz * (o.n).x + (y.im).yz * (o.n).y + (y.im).zz * (o.n).z))
       AS p(nt),
     -- and the facet normal of the triangle after it has actually been moved
     LATERAL (SELECT tri_normal(m34_point(x.m, (t.a).x, (t.a).y, (t.a).z),
                                m34_point(x.m, (t.b).x, (t.b).y, (t.b).z),
                                m34_point(x.m, (t.c).x, (t.c).y, (t.c).z))) AS g(ng);

-- Leaving the object-space direction unnormalised is what keeps `t` meaning
-- world distance on both sides of the transform.  Normalise it and a mesh
-- scaled by 2 reports half the distance to itself -- which would not look
-- wrong, it would just put every shadow and every glass thickness in the
-- wrong units.
SELECT mesh_place('ball', m34_scale(2.0, 2.0, 2.0, v3(0,0,0)));
SELECT scene_reindex();
SELECT ok(near((scene_hit(v3(-2.30, 2.0, 6.0), v3(0,0,-1))).t, 6.0 - (-0.4 + 2.0), 1e-6),
          'ray distance stays in world units through a scaled mesh');
SELECT mesh_place('ball', m34_identity());
SELECT scene_reindex();
DROP TABLE geom_before;

-- The above proves m34_inverse transposes correctly.  It does not prove the
-- *renderer* uses it, and that gap is not hypothetical: make_hit rebuilt to
-- carry the normal through mesh.xform instead of through the inverse passes
-- every other check in this file, because every mesh in the default scene is
-- at the identity where the two agree exactly.
--
-- So this fires a real ray at a real mesh whose transform tells the two
-- apart.  One triangle with corners at (0,0,0), (1,0,0) and (0,1,1) has an
-- object-space normal along (0,-1,1); scaled by three in y its surface tilts
-- to (0,-1,3) normalised, while the same normal pushed through the transform
-- would come back as (0,-3,1) normalised.  Those are 71 degrees apart, so a
-- renderer that confuses them is not subtly wrong.
SELECT scene_clear();
SELECT mesh_load_obj('tilt', 'chrome', E'v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 3\n');
SELECT scene_reindex();
SELECT mesh_place('tilt', m34_scale(1.0, 3.0, 1.0, v3(0,0,0)));

SELECT ok((q.h).mat <> 0
      AND near(((q.h).n).x, 0.0,               1e-9)
      AND near(((q.h).n).y, -1.0 / sqrt(10.0), 1e-9)
      AND near(((q.h).n).z,  3.0 / sqrt(10.0), 1e-9),
          'the tracer transforms normals by the inverse transpose')
FROM (SELECT scene_hit(v3(1.0/3.0, 1.0, 10.0), v3(0,0,-1))) AS q(h);

-- and the hit itself must be on the transformed surface, not the original
SELECT ok(near((scene_hit(v3(1.0/3.0, 1.0, 10.0), v3(0,0,-1))).t, 10.0 - 1.0/3.0, 1e-9),
          'a non-uniformly scaled surface is hit where the scale puts it');

-- Both checks above go through scene_hit(), which carries its own copy of the
-- transform.  The renderer's copy is spelled out inline over flat columns and
-- is the one that actually draws the picture, so it needs its own check --
-- normalising the object-space direction there breaks every distance in the
-- frame and passes everything else in this file.
--
-- The comparison is exact rather than approximate, which is available only
-- because the scale is 2.0: a power of two moves the exponent and leaves every
-- mantissa alone, so a sphere built at radius 2 and a sphere built at radius 1
-- and scaled are the same numbers, not merely close ones.  Any other factor
-- would need a tolerance and would test less.
SELECT scene_clear();
SELECT mesh_add_quad('ground', 'checker-tile', 40.0);
SELECT mesh_add_sphere('ball', 'checker-tile', 2.00, v3(0, 2.0, 0), 16);
SELECT scene_reindex();
SELECT render(48, 32, 1, 2);
CREATE TEMP TABLE scaled_baked AS SELECT * FROM img;

SELECT scene_clear();
SELECT mesh_add_quad('ground', 'checker-tile', 40.0);
SELECT mesh_add_sphere('ball', 'checker-tile', 1.00, v3(0, 1.0, 0), 16);
SELECT scene_reindex();
SELECT mesh_place('ball', m34_scale(2.0, 2.0, 2.0, v3(0,0,0)));
SELECT render(48, 32, 1, 2);

SELECT ok(count(*) = 0, 'the renderer draws a scaled mesh exactly as a built one')
FROM img i JOIN scaled_baked b USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (b.r, b.g, b.b);

DROP TABLE scaled_baked;
SELECT scene_clear();
SELECT scene_default();

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
--
-- The ordering is a property of any dielectric and holds whatever the indices
-- are.  The one-degree floor is not: it is a claim about the *shipped* glass
-- being dispersive enough to see, so it is deliberately coupled to
-- sql/04_scene.sql and has to move when that material is retuned.  At the
-- current spread of 0.060 this separation is 1.17 degrees; it was 2.61 before,
-- and the threshold was 1.5, which is how this check announced the change.
SELECT ok(red_out > green_out AND green_out > blue_out AND red_out - blue_out > 1.0,
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
\echo == inlining ==

-- The engine's whole strategy is that these functions are macro-expanded into
-- the queries that call them, and PostgreSQL abandons that silently when an
-- argument gets too big for a parameter the body names more than once.  There
-- is no plan difference and no row-count difference when it happens -- only a
-- slower clock -- so it is worth pinning down the two places where the failure
-- is cheaply visible.

-- The camera basis over constant arguments must still reduce to literal
-- vectors.  It did not for a long while: v3_unit over a whole vec3 names its
-- argument twenty-one times, which put cam_w over the threshold and left the
-- entire basis as live calls.
SELECT ok(plan_of('SELECT cam_w(cam_from(), cam_at())') NOT LIKE '%cam_%'
      AND plan_of('SELECT cam_u(cam_w(cam_from(), cam_at()))') NOT LIKE '%cam_%'
      AND plan_of('SELECT cam_v(cam_w(cam_from(), cam_at()),
                                cam_u(cam_w(cam_from(), cam_at())))')
            NOT LIKE '%cam_%',
          'the camera basis folds to literal vectors before execution');

-- And cam_dir must fold at the shape the renderer actually calls it, which is
-- now two things at once: device coordinates materialised by a LATERAL, and
-- the basis arriving from PL/pgSQL locals as Params.  Both matter.  Without
-- the `OFFSET 0` the subquery is pulled up, the arithmetic is spliced back
-- into the argument, and v3_unit stops inlining -- that is not hypothetical,
-- it is what this test caught once.  The Params are the newer half: the basis
-- used to be a foldable constant and is now per-render, and it is only
-- because a Param costs nothing to inline over that this still holds.
CREATE OR REPLACE FUNCTION cam_dir_plan() RETURNS text AS $$
DECLARE
  cu vec3; cv vec3; cw vec3; cth float8;
  r text; acc text := '';
BEGIN
  cw  := cam_w(cam_from(), cam_at());
  cu  := cam_u(cw);
  cv  := cam_v(cw, cu);
  cth := tan(radians(cam_fov()) / 2.0);
  FOR r IN EXECUTE
    'EXPLAIN (VERBOSE, COSTS OFF)
     SELECT cam_dir(t.nx, t.ny, 1.5, $1, $2, $3, $4)
     FROM generate_series(1,1) g,
          LATERAL (SELECT g / 10.0, g / 20.0 OFFSET 0) AS t(nx, ny)'
    USING cu, cv, cw, cth
  LOOP acc := acc || r || E'\n'; END LOOP;
  RETURN acc;
END $$ LANGUAGE plpgsql;

SELECT ok(cam_dir_plan() NOT LIKE '%cam_dir%'
      AND cam_dir_plan() NOT LIKE '%v3_unit%',
          'cam_dir inlines completely at the renderer''s call shape');

-- The slab and triangle tests are the hot path; if either stops inlining the
-- engine loses several times more than any tuning gains back.
SELECT ok(plan_of('SELECT box_hit(t.ox,t.oy,t.oz,t.ivx,t.ivy,t.ivz,
                                  t.lox,t.loy,t.loz,t.hix,t.hiy,t.hiz)
                   FROM (SELECT r.ox,r.oy,r.oz,r.ivx,r.ivy,r.ivz,
                                b.lox,b.loy,b.loz,b.hix,b.hiy,b.hiz
                         FROM (SELECT 0.0 ox,0.0 oy,0.0 oz,
                                      1.0 ivx,1.0 ivy,1.0 ivz) r,
                              mesh_box b) t')
            NOT LIKE '%box_hit%',
          'the slab test folds into its caller');

\echo
\echo == end to end ==

-- What the picture actually is.
--
-- Every other image assertion below is either a shape check or a comparison of
-- two renders made by the same code, and none of them says what belongs at a
-- given pixel.  The cost of that is exact and was measured rather than feared:
-- swapping the arguments of cam_u's cross product mirrors the entire frame left
-- to right, and the whole suite passes.  So does halving the exposure, and so
-- does anything else that is wrong everywhere at once, because "wrong
-- everywhere" is indistinguishable from "different" to a check that only
-- compares one render against another.
--
-- The hash is over `img` rather than over the encoded PNG on purpose.  The
-- encoder has its own section and its own vectors; folding it in here would
-- mean every change to a Huffman tree or a filter heuristic arrives looking
-- like a change to the renderer, which is the failure that makes golden tests
-- get deleted.  This one moves when the image moves.
--
-- Reproducibility is not assumed: both values hold across sessions, at 64 kB
-- work_mem, and with parallelism forced on.  They can be, because a render
-- reads temporary tables and PostgreSQL will not parallelise that, so the
-- order the per-pixel float8 sums accumulate in is fixed.
SELECT render(48, 32, 1, 3);
SELECT ok(md5(string_agg(r || ',' || g || ',' || b, ';' ORDER BY y, x))
          = '639c30aadec4eff915bfb48f62f38909',
          'a one-sample frame matches its recorded hash') FROM img;

-- The second render is not a bigger copy of the first, and the divisor is why.
-- `1/(aa*aa)` is the only place the sample count reaches shading, and at aa = 1
-- it is 1 whichever way it is spelled -- so `1/aa` renders the hash above
-- unchanged.  Measured: mutating it leaves the one-sample hash identical and
-- this one different.  Every render in this file was aa = 1 before this line,
-- which left the expression that turns samples into a pixel unwitnessed.
SELECT render(48, 32, 2, 3);
SELECT ok(md5(string_agg(r || ',' || g || ',' || b, ';' ORDER BY y, x))
          = '287fdd3fdb6e14059d52826bd4966bf8',
          'a four-sample frame matches its recorded hash') FROM img;

SELECT render(24, 16, 1, 3);
SELECT ok(count(*) = 24 * 16, 'render fills every pixel exactly once') FROM img;
SELECT ok(bool_and(r BETWEEN 0 AND 255 AND g BETWEEN 0 AND 255 AND b BETWEEN 0 AND 255),
          'all samples are within 8-bit range') FROM img;
SELECT ok(count(DISTINCT (r,g,b)) > 8, 'the render is not a flat fill') FROM img;
SELECT ok(length(p) = 8 + 25 + 12 + length(png_idat(p)) + 12,
          'PNG length is signature + IHDR + IDAT + IEND')
FROM (SELECT png_encode(24, 16, png_scanlines('img'))) AS q(p);

-- Filters are a claim about *predicting* bytes, never about changing them, so
-- every type has to reconstruct the identical image.  Forcing each in turn is
-- what makes this discriminating: the adaptive path picks whichever filter is
-- cheapest per row and can leave a broken one untouched for an entire render.
SELECT ok(bool_and(png_unfilter(png_scanlines('img', f), 24, 16)
                   = png_unfilter(png_scanlines('img', 0), 24, 16)),
          'all five filter types reconstruct the same pixels')
FROM generate_series(0, 4) AS f;

SELECT ok(png_unfilter(png_scanlines('img'), 24, 16)
          = png_unfilter(png_scanlines('img', 0), 24, 16)
          AND png_unfilter(png_scanlines('img', -2), 24, 16)
          = png_unfilter(png_scanlines('img', 0), 24, 16),
          'both filter-choosing modes reconstruct the same pixels');

-- The default measures rather than predicts, so it can never be beaten by
-- either of the candidates it chose between.
SELECT ok(length(deflate(png_scanlines('img'), 6))
          <= least(length(deflate(png_scanlines('img', 0), 6)),
                   length(deflate(png_scanlines('img', 1), 6))),
          'the chosen filter is no worse than either candidate');

SELECT ok(bool_and(ft BETWEEN 0 AND 4), 'every scanline carries a legal filter byte')
FROM generate_series(0, 15) AS y,
     LATERAL (SELECT get_byte(png_scanlines('img'), y * (24 * 3 + 1))) AS q(ft);

-- The per-row chooser (-2) has to actually choose: for every row, the filter it
-- marks must be the one with the smallest sum of absolute signed residuals.
--
-- The oracle is the forced-filter output itself, which is what keeps this from
-- being a copy of the implementation -- the costs below are summed from the
-- bytes png_scanlines(img, f) really emitted, not from a second evaluation of
-- the predictors.  Ties go to the lower filter number on both sides.
SELECT ok(bool_and(best.f = chosen.f),
          'each scanline is marked with the cheapest of the five filters')
FROM (SELECT DISTINCT ON (y) y, f
      FROM (SELECT y, f, sum(least(v, 256 - v)) AS c
            FROM generate_series(0, 4) AS f,
                 LATERAL (SELECT png_scanlines('img', f)) AS s(b),
                 generate_series(0, 15) AS y,
                 generate_series(0, 24 * 3 - 1) AS i,
                 LATERAL (SELECT get_byte(b, y * (24 * 3 + 1) + 1 + i)) AS q(v)
            GROUP BY y, f) AS cost
      ORDER BY y, c, f) AS best
     JOIN (SELECT y, get_byte(png_scanlines('img', -2), y * (24 * 3 + 1)) AS f
           FROM generate_series(0, 15) AS y) AS chosen USING (y);

-- IHDR is the one part of a PNG that says what the rest of it means, and until
-- there was a decoder here nothing read it back.  Colour type 2 is the claim
-- that a pixel is three bytes; the inflated length is what makes that claim
-- checkable rather than decorative.
SELECT ok(get_byte(p, 16) * 16777216 + get_byte(p, 17) * 65536
        + get_byte(p, 18) * 256 + get_byte(p, 19) = 24
      AND get_byte(p, 20) * 16777216 + get_byte(p, 21) * 65536
        + get_byte(p, 22) * 256 + get_byte(p, 23) = 16
      AND get_byte(p, 24) = 8      -- bits per sample
      AND get_byte(p, 25) = 2      -- truecolour: three samples, no alpha
      AND get_byte(p, 26) = 0      -- compression method: deflate
      AND get_byte(p, 27) = 0      -- filter method: the five adaptive filters
      AND get_byte(p, 28) = 0      -- not interlaced
      AND length(zlib_inflate(png_idat(p))) = 16 * (24 * 3 + 1),
          'IHDR describes the image that was actually written')
FROM (SELECT png_encode(24, 16, png_scanlines('img'))) AS q(p);

-- The whole loop, inside the database: pixels to PNG and back.  This is what
-- inflate buys even though nothing renders with it -- until it existed, a PNG
-- was write-only here and there was no way to ask whether one was right.
SELECT ok(png_unfilter(zlib_inflate(png_idat(p)), 24, 16)
          = (SELECT decode(string_agg(lpad(to_hex(r), 2, '0') || lpad(to_hex(g), 2, '0')
                                   || lpad(to_hex(b), 2, '0'), '' ORDER BY y, x), 'hex')
             FROM img),
          'a PNG decodes back to the exact pixels it was made from')
FROM (SELECT png_encode(24, 16, png_scanlines('img'))) AS q(p);

SELECT ok(raises($$SELECT png_idat('\x0011223344556677'::bytea)$$),
          'png_idat refuses something that is not a PNG');
SELECT ok(raises($$SELECT png_unfilter('\x0000'::bytea, 24, 16)$$),
          'png_unfilter refuses scanlines of the wrong length');

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

\echo
\echo == adaptive sampling ==

-- An adaptive frame is not an approximation of a uniform one, and this is the
-- check that says so.  Every pixel in it is bit-for-bit a pixel of one of two
-- renders that already exist: the coarse frame where nothing was refined, the
-- fine frame where something was.  That holds because a refined pixel throws
-- its coarse sample away and re-samples on exactly the grid a uniform render
-- would have used, so there is no third value anywhere in the image and no
-- tolerance anywhere in this file.
--
-- It is also the check that would catch the mistake worth worrying about.
-- Keeping the coarse sample instead of discarding it, or dividing by the wrong
-- count, produces a picture that looks entirely plausible -- slightly wrong
-- only at the pixels that were refined, which are the pixels a reader is least
-- able to eyeball.
SELECT render(48, 32, 1, 3);
CREATE TEMP TABLE aa_coarse AS SELECT * FROM img;
SELECT render(48, 32, 2, 3);
CREATE TEMP TABLE aa_fine AS SELECT * FROM img;
SELECT render(48, 32, 2, 3, 1.35, 0.01, false, cam_from(), cam_at(), cam_fov(), 16);

SELECT ok(count(*) = 0, 'every pixel of an adaptive frame comes from one of the two uniform ones')
FROM img i JOIN aa_coarse c USING (x, y) JOIN aa_fine f USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (c.r, c.g, c.b)
  AND (i.r, i.g, i.b) IS DISTINCT FROM (f.r, f.g, f.b);

-- ... and it has to have refined something, or the check above is satisfied by
-- a renderer that ignores the threshold entirely.
SELECT ok(count(*) > 0, 'an adaptive frame differs from the coarse one it began as')
FROM img i JOIN aa_coarse c USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (c.r, c.g, c.b);

-- The two ends of the threshold.  Above the largest contrast 8-bit channels
-- can hold, nothing is selected and the second pass never runs; the frame is
-- the one-sample frame exactly.
SELECT render(48, 32, 2, 3, 1.35, 0.01, false, cam_from(), cam_at(), cam_fov(), 255);
SELECT ok(count(*) = 0, 'a threshold no pair of pixels can exceed refines nothing')
FROM img i JOIN aa_coarse c USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (c.r, c.g, c.b);

-- Lowering it can only ever select more pixels, since the test is a strict
-- inequality against one number -- so the frame it produces must agree with
-- the fine render everywhere the stricter one did, and possibly further.
SELECT render(48, 32, 2, 3, 1.35, 0.01, false, cam_from(), cam_at(), cam_fov(), 64);
CREATE TEMP TABLE aa_loose AS SELECT * FROM img;
SELECT render(48, 32, 2, 3, 1.35, 0.01, false, cam_from(), cam_at(), cam_fov(), 4);
SELECT ok((SELECT count(*) FROM img i JOIN aa_fine f USING (x, y)
           WHERE (i.r, i.g, i.b) = (f.r, f.g, f.b))
       >= (SELECT count(*) FROM aa_loose l JOIN aa_fine f USING (x, y)
           WHERE (l.r, l.g, l.b) = (f.r, f.g, f.b)),
          'a lower threshold agrees with the fine render on no fewer pixels');

-- Refining a one-sample render to one sample is not a request that can mean
-- anything, and it costs a whole second pass to honour literally.
SELECT render(48, 32, 1, 3, 1.35, 0.01, false, cam_from(), cam_at(), cam_fov(), 1);
SELECT ok(count(*) = 0, 'a refinement rate equal to the base rate is not a refinement')
FROM img i JOIN aa_coarse c USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (c.r, c.g, c.b);

\echo
\echo == camera ==

-- A camera moved along its own view axis must change the picture.  This looks
-- like a strange thing to single out until you notice it is the one motion
-- that leaves cam_dir's output *identical*: the basis is built from
-- unit(from - at), so sliding the eye toward the target rescales that vector
-- and normalises back to the same w, u and v.  Only the ray origin differs.
--
-- So an implementation that threads the new camera into the direction and
-- leaves the origin reading the old constant renders this case bit-identical
-- while looking entirely correct from every other angle.  That is exactly the
-- bug this check was written for, and it is why moving the camera sideways
-- would not have caught it.
CREATE TEMP TABLE cam_far AS SELECT * FROM img WHERE false;
SELECT render(48, 32, 1, 3);
INSERT INTO cam_far SELECT * FROM img;

SELECT render(48, 32, 1, 3, 1.35, 0.01, false,
              v3((cam_at()).x + ((cam_from()).x - (cam_at()).x) * 0.5,
                 (cam_at()).y + ((cam_from()).y - (cam_at()).y) * 0.5,
                 (cam_at()).z + ((cam_from()).z - (cam_at()).z) * 0.5),
              cam_at(), cam_fov());
SELECT ok(count(*) > 0, 'dollying the camera along its view axis changes the frame')
FROM img i JOIN cam_far f USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (f.r, f.g, f.b);

-- ... and passing the defaults explicitly must change nothing at all.
SELECT render(48, 32, 1, 3, 1.35, 0.01, false, cam_from(), cam_at(), cam_fov());
SELECT ok(count(*) = 0, 'an explicit default camera renders the default frame')
FROM img i JOIN cam_far f USING (x, y)
WHERE (i.r, i.g, i.b) IS DISTINCT FROM (f.r, f.g, f.b);

-- A wider field of view must see more than a narrow one.  Checked on the sky:
-- the scene sits below the horizon line, so widening the lens can only add
-- background, never remove it.
SELECT render(48, 32, 1, 3, 1.35, 0.01, false, cam_from(), cam_at(), 20.0);
CREATE TEMP TABLE cam_narrow AS SELECT * FROM img;
SELECT render(48, 32, 1, 3, 1.35, 0.01, false, cam_from(), cam_at(), 80.0);
SELECT ok((SELECT count(*) FROM img WHERE r = g AND g = b AND r > 150)
        > (SELECT count(*) FROM cam_narrow WHERE r = g AND g = b AND r > 150),
          'a wider field of view puts more sky in the frame');


\echo == frames ==

-- The camera is a property of the view, so a degenerate one is refused where
-- it is written down rather than diagnosed later as a divide by zero.
SELECT ok(raises($$INSERT INTO frame (name, w, h, cam_from, cam_at)
                   VALUES ('degenerate', 8, 8, v3(1,1,1), v3(1,1,1))$$),
          'a frame whose camera sits on its own target is refused');
SELECT ok(raises($$INSERT INTO frame (name, w, h, cam_fov) VALUES ('wide', 8, 8, 200.0)$$),
          'a frame with a field of view past a half turn is refused');

-- A frame row is the description and the result together.
INSERT INTO frame (name, w, h, aa, maxdepth) VALUES ('t_frame', 48, 32, 1, 3);
SELECT render_frame('t_frame');
SELECT ok(substring(png from 1 for 8) = '\x89504e470d0a1a0a'::bytea
      AND length(png) > 100
      AND rendered_at IS NOT NULL
      AND elapsed_ms >= 0,
          'render_frame stores a PNG and its provenance on the row')
FROM frame WHERE name = 't_frame';

-- The kept PNG must be the same bytes the direct path produces, or the archive
-- is quietly a different picture from the one the renderer was asked for.
SELECT ok((SELECT png FROM frame WHERE name = 't_frame')
          = render_png(48, 32, 1, 3, 1.35),
          'a stored frame is byte-identical to rendering it directly');

-- Two frames differing only in camera must differ only as the camera does,
-- which is the whole basis of a camera move being a row rather than a feature.
INSERT INTO frame (name, w, h, aa, maxdepth, cam_from)
VALUES ('t_frame2', 48, 32, 1, 3, v3(-0.55, 2.35, -6.70));
SELECT render_frame('t_frame2');
SELECT ok((SELECT png FROM frame WHERE name = 't_frame')
       <> (SELECT png FROM frame WHERE name = 't_frame2'),
          'a frame rendered from the far side is a different picture');

SELECT ok(raises($$SELECT render_frame('no-such-frame')$$),
          'rendering a frame that does not exist is an error');

-- A refinement threshold is a setting of the view like the rest, so a frame
-- carrying one must produce what the same request produces by argument.  The
-- pair also pins the column against the argument order in render(): a refine
-- silently dropped on the way through leaves a frame that renders uniformly
-- and looks perfectly correct on its own.
INSERT INTO frame (name, w, h, aa, maxdepth, refine)
VALUES ('t_frame3', 48, 32, 2, 3, 16);
SELECT render_frame('t_frame3');
SELECT ok((SELECT png FROM frame WHERE name = 't_frame3')
          = render_png(48, 32, 2, 3, 1.35, cam_from(), cam_at(), cam_fov(), 16)
      AND (SELECT png FROM frame WHERE name = 't_frame3')
          <> render_png(48, 32, 2, 3, 1.35),
          'a frame that asks to be refined is refined, and differs from one that does not');

SELECT ok(raises($$INSERT INTO frame (name, w, h, refine) VALUES ('neg', 8, 8, -1)$$),
          'a frame with a negative refinement threshold is refused');

SELECT ok(raises($$INSERT INTO frame (name, w, h, delay_ms) VALUES ('back', 8, 8, -1)$$),
          'a frame that is shown for a negative time is refused');

DELETE FROM frame WHERE name LIKE 't_frame%';


\echo == the frame queue ==

-- The queue is the backlog, so an empty backlog has to be a value the driver
-- can loop on rather than an error it has to catch.
SELECT ok(render_next_frame() IS NULL,
          'the queue hands back nothing when every frame is rendered');

-- Frames come off in frame_id order, and a frame that has its bytes is no
-- longer in the queue at all -- which is the same clause that makes an
-- interrupted sequence resumable.
INSERT INTO frame (name, w, h, aa, maxdepth) VALUES ('t_q1', 24, 16, 1, 2);
INSERT INTO frame (name, w, h, aa, maxdepth) VALUES ('t_q2', 24, 16, 1, 2);

SELECT ok(render_next_frame()
          = (SELECT frame_id FROM frame WHERE name = 't_q1'),
          'the queue takes the oldest unrendered frame first');
SELECT ok(render_next_frame()
          = (SELECT frame_id FROM frame WHERE name = 't_q2'),
          'and then the next one');
SELECT ok(render_next_frame() IS NULL,
          'a frame that has been rendered is not offered again');

SELECT ok(count(*) = 2, 'both queued frames came out with their bytes')
FROM frame WHERE name LIKE 't_q%' AND png IS NOT NULL;

DELETE FROM frame WHERE name LIKE 't_q%';
