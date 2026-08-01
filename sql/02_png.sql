-- ---------------------------------------------------------------------------
-- PNG encoder, written entirely in SQL.
--
-- PostgreSQL exposes no zlib binding to SQL, so the whole container format is
-- built from scratch: CRC-32 for the chunk trailers, Adler-32 for the zlib
-- trailer, and a DEFLATE stream made of *stored* (uncompressed) blocks.  A
-- stored block is a legal DEFLATE block, so the output is a fully conformant
-- PNG -- it is simply about as large as the raw pixel data.
-- ---------------------------------------------------------------------------

-- Big-endian 32-bit field, the width used by every PNG length and CRC.
CREATE FUNCTION be32(v bigint) RETURNS bytea
  AS $$ SELECT decode(lpad(to_hex(v & 4294967295), 8, '0'), 'hex') $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Little-endian 16-bit field, used by DEFLATE stored-block headers.
CREATE FUNCTION le16(v int) RETURNS bytea
  AS $$ SELECT decode(lpad(to_hex((v & 255) * 256 + ((v >> 8) & 255)), 4, '0'), 'hex') $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

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
  SELECT array_agg(t.v ORDER BY t.i) INTO tab FROM crc32_table t;
  FOR k IN 0 .. n - 1 LOOP
    c := (c >> 8) # tab[((c # get_byte(b, k)) & 255) + 1];
  END LOOP;
  RETURN c # 4294967295;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Adler-32 -------------------------------------------------------------------
--
-- Adler-32 is a running sum plus a running sum of that sum, so it closes into
-- a form with no loop at all:
--
--   a = 1 + SUM b[j]
--   b = n + SUM b[j] * (n - j + 1)
--
-- Both sums stay well inside int8 for any image we would render here, so the
-- modulo can be deferred to the very end.

CREATE FUNCTION adler32(b bytea) RETURNS bigint AS $$
  SELECT (((1 + s1) % 65521)::bigint & 65535)
       | ((((n + s2) % 65521)::bigint & 65535) << 16)
  FROM (SELECT length(b)::bigint) AS q(n),
       LATERAL (
         SELECT coalesce(sum(byte), 0), coalesce(sum(byte * (n - j + 1)), 0)
         FROM generate_series(1, n) AS s(j),
              LATERAL (SELECT get_byte(b, (j - 1)::int)::bigint) AS p(byte)
       ) AS a(s1, s2)
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- zlib stream with stored DEFLATE blocks --------------------------------------

CREATE FUNCTION zlib_stored(raw bytea) RETURNS bytea AS $$
DECLARE
  out   bytea := '\x7801';    -- CMF=0x78 (deflate, 32K window), FLG=0x01
  n     int   := length(raw);
  pos   int   := 0;
  chunk int;
  final int;
BEGIN
  -- DEFLATE stored blocks carry a 16-bit length, so 65535 bytes at a time.
  LOOP
    chunk := least(65535, n - pos);
    final := CASE WHEN pos + chunk >= n THEN 1 ELSE 0 END;
    out := out || set_byte('\x00'::bytea, 0, final)
               || le16(chunk) || le16(~chunk & 65535)
               || substring(raw FROM pos + 1 FOR chunk);
    pos := pos + chunk;
    EXIT WHEN pos >= n;
  END LOOP;
  RETURN out || be32(adler32(raw));
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- Chunk framing --------------------------------------------------------------

CREATE FUNCTION png_chunk(typ text, data bytea) RETURNS bytea AS $$
  SELECT be32(length(data)) || body || be32(crc32(body))
  FROM (SELECT convert_to(typ, 'SQL_ASCII') || data) AS q(body)
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- png_encode: an 8-bit truecolour PNG.
--
-- `scanlines` is the raw filtered image data: h rows of (1 filter byte +
-- 3*w sample bytes).  Every scanline uses filter type 0 (None); filters only
-- earn their keep when the DEFLATE stage can exploit them, which stored
-- blocks cannot.
-- ---------------------------------------------------------------------------

CREATE FUNCTION png_encode(w int, h int, scanlines bytea) RETURNS bytea AS $$
  SELECT '\x89504e470d0a1a0a'::bytea
      || png_chunk('IHDR', be32(w) || be32(h) || '\x0802000000'::bytea)
      || png_chunk('IDAT', zlib_stored(scanlines))
      || png_chunk('IEND', ''::bytea)
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- Assemble scanlines from a pixel table shaped (x, y, r, g, b) with 0-255
-- samples.  Going via a hex string and one decode() is far cheaper than
-- accumulating bytea concatenations byte by byte.
-- Takes the table name as text rather than regclass: the renderer creates
-- `img` at runtime, and a regclass literal would have to resolve at parse
-- time, before the table exists.
CREATE FUNCTION png_scanlines(tbl text) RETURNS bytea AS $$
DECLARE raw bytea;
BEGIN
  EXECUTE format($q$
    SELECT decode(string_agg(line, '' ORDER BY y), 'hex')
    FROM (
      SELECT y, '00' || string_agg(lpad(to_hex(r), 2, '0')
                                || lpad(to_hex(g), 2, '0')
                                || lpad(to_hex(b), 2, '0'), '' ORDER BY x)
      FROM %s GROUP BY y
    ) AS rows (y, line)
  $q$, tbl::regclass) INTO raw;
  RETURN raw;
END $$ LANGUAGE plpgsql STABLE;
