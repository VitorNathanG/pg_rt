-- ---------------------------------------------------------------------------
-- PNG encoder, written entirely in SQL.
--
-- The compression lives in 02_deflate.sql; this file is the container and the
-- one thing PNG adds on top of DEFLATE that actually matters for size: the
-- per-scanline filters.
-- ---------------------------------------------------------------------------

-- CRC-32 (IEEE 802.3, polynomial 0xEDB88320) ---------------------------------
--
-- The byte table is materialised once at install time by bit-twiddling in a
-- recursive CTE, then used by the byte-at-a-time update loop.

CREATE TABLE crc32_table (i int PRIMARY KEY, v bigint NOT NULL);

INSERT INTO crc32_table (i, v)
WITH RECURSIVE shift (i, k, c) AS (
    SELECT i, 0, i::bigint FROM generate_series(0, 255) AS g(i)
  UNION ALL
    SELECT i, k + 1,
           CASE WHEN c & 1 = 1 THEN (c >> 1) # 3988292384 ELSE c >> 1 END
    FROM shift WHERE k < 8
)
SELECT i, c FROM shift WHERE k = 8;

CREATE FUNCTION crc32(b bytea) RETURNS bigint AS $$
DECLARE
  tab bigint[];
  c   bigint := 4294967295;   -- 0xFFFFFFFF
  k   int;
  n   int := length(b);
BEGIN
  b := detoast(b);
  SELECT array_agg(t.v ORDER BY t.i) INTO tab FROM crc32_table t;
  FOR k IN 0 .. n - 1 LOOP
    c := (c >> 8) # tab[((c # get_byte(b, k)) & 255) + 1];
  END LOOP;
  RETURN c # 4294967295;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Chunk framing --------------------------------------------------------------

CREATE FUNCTION png_chunk(typ text, data bytea) RETURNS bytea AS $$
  SELECT be32(length(data)) || body || be32(crc32(body))
  FROM (SELECT convert_to(typ, 'SQL_ASCII') || data) AS q(body)
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Filters.
--
-- This is where PNG earns most of its compression, and it is worth being
-- precise about why, because the filters look like they are compressing and
-- they are not: each one is a *predictor*, and every one of them is lossless
-- and reversible on its own.  All they do is replace each byte with its
-- difference from a guess made out of neighbours already sent, which turns a
-- smooth gradient -- the thing a renderer produces most of -- from 200 distinct
-- byte values into a heap of zeroes and ones.  DEFLATE then has something
-- skewed enough to be worth Huffman coding.  That is why the two belong
-- together and why filtering was pointless while the blocks were stored: a
-- stored block copies its input, so making the input more compressible bought
-- exactly nothing.
--
--   0 None      raw
--   1 Sub       raw - left
--   2 Up        raw - above
--   3 Average   raw - floor((left + above) / 2)
--   4 Paeth     raw - whichever of left/above/upper-left is nearest their
--               linear estimate
--
-- The neighbours are the *unfiltered* bytes, which is the part that makes this
-- a set operation rather than a loop: every byte's five candidates depend only
-- on the original image, so all of them can be computed at once and the
-- decision made afterwards.  Only the decoder has to be sequential.
-- ---------------------------------------------------------------------------

-- The Paeth predictor, in its cancelled form.  Written out, the three
-- distances are |p-a|, |p-b| and |p-c| for p = a + b - c, and every p drops
-- out: |p-a| = |b-c|, |p-b| = |a-c|, |p-c| = |a+b-2c|.
CREATE FUNCTION paeth(a int, b int, c int) RETURNS int AS $$
  SELECT CASE WHEN abs(b - c) <= abs(a - c) AND abs(b - c) <= abs(a + b - 2 * c) THEN a
              WHEN abs(a - c) <= abs(a + b - 2 * c) THEN b
              ELSE c END
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Assemble filtered scanlines from a pixel table shaped (x, y, r, g, b) with
-- 0-255 samples and dense, 0-based coordinates.
--
-- `p_filter` is 0-4 to force one filter on the whole image, -2 to choose per
-- scanline by the standard heuristic, and -1 -- the default -- to choose one
-- filter for the whole image by compressing both candidates and keeping the
-- smaller.
--
-- ## Why the default measures instead of predicting
--
-- Every PNG encoder picks per scanline using the same heuristic: take the
-- filter whose output has the smallest sum of absolute values read as signed
-- bytes, on the reasoning that DEFLATE spends fewer bits on residuals clustered
-- near zero.  That heuristic is available here as -2 and it is **never the best
-- choice on this renderer's output**, measured at four resolutions:
--
--   pixels        per-row   None     Sub      Up       Average  Paeth
--   240x160        26 421   30 863   25 064   29 958   31 099   27 485
--   480x320        87 859   94 700   81 685   99 439   97 069   89 453
--   960x540       175 684  167 680  165 546  197 970  207 680  186 273
--   1920x1080     492 812  428 710  465 980  544 180  590 770  515 987
--
-- Two things are wrong with predicting.  The heuristic measures residual
-- *magnitude* while DEFLATE pays for *repetition*, and it ranks accordingly
-- badly: at 480x320 it puts Paeth first and None last by a factor of 44, when
-- Sub is smallest and None beats three of the five.  And mixing filters between
-- rows costs more here than it can save, because this encoder emits one block
-- with one Huffman tree over the whole image, so every row a different filter
-- is chosen for widens the same symbol distribution.
--
-- No fixed filter wins either -- Sub below about a megapixel, None above it --
-- so the default does what the block chooser next door does and measures.  The
-- candidates are None and Sub because nothing else won any of the four.
--
-- The probe runs at level 1 rather than at the level the caller will use, and
-- the reason it can afford to is worth stating: at 960x540 the probe picks None
-- where level 6 would have picked Sub, and it costs 1.3%, because near the
-- crossover the two are nearly the same size.  Where the gap is large enough to
-- matter the probe is never in doubt.
--
-- Takes the table name as text rather than regclass: the renderer creates
-- `img` at runtime, and a regclass literal would have to resolve at parse
-- time, before the table exists.
--
-- Going via a hex string and one decode() is far cheaper than accumulating
-- bytea concatenations byte by byte, for the same reason 02_deflate.sql builds
-- its buffers as int[].
-- ---------------------------------------------------------------------------
CREATE FUNCTION png_scanlines(tbl text, p_filter int DEFAULT -1) RETURNS bytea AS $$
DECLARE
  raw    bytea;
  none   bytea;
  sub    bytea;
  stride int;
BEGIN
  EXECUTE format('SELECT (max(x) + 1) * 3 FROM %s', tbl::regclass) INTO stride;
  IF stride IS NULL THEN
    RETURN ''::bytea;
  END IF;

  IF p_filter = -1 THEN
    none := png_scanlines(tbl, 0);
    sub  := png_scanlines(tbl, 1);
    IF length(deflate(sub, 1)) <= length(deflate(none, 1)) THEN
      RETURN sub;
    END IF;
    RETURN none;
  END IF;

  EXECUTE format($q$
    WITH b AS (
      SELECT y, x * 3 + ch.c AS i,
             CASE ch.c WHEN 0 THEN r WHEN 1 THEN g ELSE b END AS v
      FROM %1$s CROSS JOIN generate_series(0, 2) AS ch(c)
    ),
    nb AS (
      SELECT y, i, v,
             CASE WHEN i < 3 THEN 0
                  ELSE lag(v, 3) OVER wo END AS la,
             coalesce(lag(v, %2$s) OVER wo, 0) AS up,
             CASE WHEN i < 3 THEN 0
                  ELSE coalesce(lag(v, %3$s) OVER wo, 0) END AS ul
      FROM b
      WINDOW wo AS (ORDER BY y, i)
    ),
    f AS (
      SELECT y, i, v,
             (v - la + 256) %% 256                    AS f1,
             (v - up + 256) %% 256                    AS f2,
             (v - ((la + up) / 2) + 256) %% 256       AS f3,
             (v - paeth(la, up, ul) + 256) %% 256     AS f4
      FROM nb
    ),
    row AS (
      SELECT y,
             sum(least(v,  256 - v ))::bigint AS c0,
             sum(least(f1, 256 - f1))::bigint AS c1,
             sum(least(f2, 256 - f2))::bigint AS c2,
             sum(least(f3, 256 - f3))::bigint AS c3,
             sum(least(f4, 256 - f4))::bigint AS c4,
             string_agg(lpad(to_hex(v),  2, '0'), '' ORDER BY i) AS s0,
             string_agg(lpad(to_hex(f1), 2, '0'), '' ORDER BY i) AS s1,
             string_agg(lpad(to_hex(f2), 2, '0'), '' ORDER BY i) AS s2,
             string_agg(lpad(to_hex(f3), 2, '0'), '' ORDER BY i) AS s3,
             string_agg(lpad(to_hex(f4), 2, '0'), '' ORDER BY i) AS s4
      FROM f GROUP BY y
    )
    SELECT decode(string_agg(
             CASE ft WHEN 0 THEN '00' || s0 WHEN 1 THEN '01' || s1
                     WHEN 2 THEN '02' || s2 WHEN 3 THEN '03' || s3
                     ELSE '04' || s4 END, '' ORDER BY y), 'hex')
    FROM row
         CROSS JOIN LATERAL (
           SELECT CASE
             WHEN %4$s >= 0                       THEN %4$s   -- forced
             WHEN c0 <= least(c1, c2, c3, c4)     THEN 0
             WHEN c1 <= least(c2, c3, c4)         THEN 1
             WHEN c2 <= least(c3, c4)             THEN 2
             WHEN c3 <= c4                        THEN 3
             ELSE                                      4 END) AS pick(ft)
  $q$, tbl::regclass, stride, stride + 3, p_filter) INTO raw;

  RETURN raw;
END $$ LANGUAGE plpgsql STABLE;

-- The inverse, and the only part of filtering that has to be a loop: every
-- predictor reads bytes that were themselves just reconstructed, so byte i
-- cannot be computed before byte i-1.
CREATE FUNCTION png_unfilter(scanlines bytea, w int, h int) RETURNS bytea AS $$
DECLARE
  stride int := w * 3;
  out int[];
  y int; i int; ft int; base int; obase int;
  x int; la int; up int; ul int;
BEGIN
  scanlines := detoast(scanlines);
  IF length(scanlines) <> h * (stride + 1) THEN
    RAISE EXCEPTION 'scanlines are % bytes, expected % for %x%',
                    length(scanlines), h * (stride + 1), w, h;
  END IF;
  out := array_fill(0, ARRAY[h * stride]);

  FOR y IN 0 .. h - 1 LOOP
    base  := y * (stride + 1);
    obase := y * stride;
    ft    := get_byte(scanlines, base);
    IF ft > 4 THEN
      RAISE EXCEPTION 'scanline % has filter type %', y, ft;
    END IF;
    FOR i IN 0 .. stride - 1 LOOP
      x  := get_byte(scanlines, base + 1 + i);
      la := CASE WHEN i >= 3 THEN out[obase + i - 2] ELSE 0 END;
      up := CASE WHEN y > 0 THEN out[obase - stride + i + 1] ELSE 0 END;
      ul := CASE WHEN i >= 3 AND y > 0 THEN out[obase - stride + i - 2] ELSE 0 END;
      out[obase + i + 1] := (x + CASE ft
                                   WHEN 0 THEN 0
                                   WHEN 1 THEN la
                                   WHEN 2 THEN up
                                   WHEN 3 THEN (la + up) / 2
                                   ELSE paeth(la, up, ul) END) & 255;
    END LOOP;
  END LOOP;

  RETURN bytes_of(out, h * stride);
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- png_encode: an 8-bit truecolour PNG.
--
-- `scanlines` is the filtered image data: h rows of (1 filter byte + 3*w
-- sample bytes), which is what png_scanlines returns.
-- ---------------------------------------------------------------------------

CREATE FUNCTION png_encode(w int, h int, scanlines bytea, level int DEFAULT 6)
RETURNS bytea AS $$
  SELECT '\x89504e470d0a1a0a'::bytea
      || png_chunk('IHDR', be32(w) || be32(h) || '\x0802000000'::bytea)
      || png_chunk('IDAT', zlib_deflate(scanlines, level))
      || png_chunk('IEND', ''::bytea)
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Reading one back.
--
-- png_idat walks the chunk list and returns the concatenated IDAT payload,
-- which is a zlib stream.  A PNG is allowed to split IDAT across any number of
-- chunks at any offset -- the split is a framing convenience and carries no
-- meaning -- so joining them before inflating is not an optimisation, it is
-- the specification.
--
--   png_unfilter(zlib_inflate(png_idat(p)), w, h)   -- back to raw pixels
-- ---------------------------------------------------------------------------
CREATE FUNCTION png_idat(png bytea) RETURNS bytea AS $$
DECLARE
  n   int := length(png);
  p   int := 8;                 -- past the signature
  len int;
  typ text;
  acc bytea := ''::bytea;
BEGIN
  png := detoast(png);
  IF n < 8 OR substring(png FROM 1 FOR 8) <> '\x89504e470d0a1a0a'::bytea THEN
    RAISE EXCEPTION 'not a PNG';
  END IF;
  WHILE p + 8 <= n LOOP
    len := (get_byte(png, p)     << 24) | (get_byte(png, p + 1) << 16)
         | (get_byte(png, p + 2) <<  8) |  get_byte(png, p + 3);
    typ := convert_from(substring(png FROM p + 5 FOR 4), 'SQL_ASCII');
    IF typ = 'IDAT' THEN
      acc := acc || substring(png FROM p + 9 FOR len);
    ELSIF typ = 'IEND' THEN
      EXIT;
    END IF;
    p := p + 12 + len;          -- length, type, data, CRC
  END LOOP;
  RETURN acc;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;
