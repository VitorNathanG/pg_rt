-- ---------------------------------------------------------------------------
-- GIF, in SQL.
--
-- PNG and GIF ask for opposite things and it is worth being clear about the
-- difference before any of this, because it decides the whole shape of the
-- file.  PNG takes the pixels as they are and spends its effort on
-- *compression*: predict, then DEFLATE.  GIF has no such option -- it cannot
-- store a truecolour pixel at all -- so before anything is compressed the
-- image has to be thrown away and rebuilt out of 256 colours.  Most of what
-- follows is that: choosing the colours, and choosing which one each pixel
-- becomes.  LZW at the end is the smaller half.
--
-- The three pieces, and why each is set-based:
--
--   * **The palette is a table.**  Median cut splits a whole round of boxes per
--     query rather than one box per iteration, so choosing 256 colours is nine
--     window queries rather than 255 sequential scans.
--   * **Mapping a colour to a palette entry is a join.**  The nearest entry is
--     searched for once per distinct colour, kept, and every pixel wearing that
--     colour -- in this frame or a later one -- is then a hash probe.
--   * **The dither matrix is a table too.**  Ordered dithering is a join
--     against 64 rows.  Floyd-Steinberg is the better-looking algorithm and is
--     strictly sequential -- each pixel's error moves to neighbours that have
--     not been quantised yet -- so it is not available here at any price worth
--     paying.  Ordered dithering is also the right choice for an animation
--     whatever its merits on one frame: its pattern depends only on (x, y), so
--     it is identical from frame to frame and does not boil.  It is off by
--     default all the same, and the note above gif_indices says why.
--
-- LZW is a loop and cannot be anything else, for the same reason inflate is:
-- the dictionary at position i is built out of everything before it.
--
-- What a GIF costs against a PNG of the same frame, on the default scene at
-- 480x320: 41 kB against 80 kB, and 2.9 s to encode against 3.6 s.  Half the
-- size because a pixel is one byte rather than three, and the quantiser --
-- which sounds like the expensive part -- is cheaper than DEFLATE.  What is
-- given up is every colour past the 256th, which on this renderer's output
-- turns out to cost a mean of 1.3 levels a pixel.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The ordered dither matrix.
--
-- Built by the doubling that defines it rather than typed out, so the numbers
-- can be checked against the rule instead of against a printed table: each
-- cell of M(n) becomes a 2x2 block of M(2n) holding 4*v plus 0, 2, 3, 1 --
-- top-left, top-right, bottom-left, bottom-right.  Three doublings from a
-- single zero give the 8x8 matrix, values 0..63.
--
-- What it is for: a threshold that varies with position instead of a rounding
-- rule that does not.  Rounding every pixel of a smooth gradient to the same
-- nearest palette entry produces a visible band edge exactly where the
-- gradient crosses halfway between two entries; nudging each pixel by a
-- position-dependent fraction of the palette spacing first turns that edge
-- into a dot pattern, which the eye integrates back into the gradient.
-- ---------------------------------------------------------------------------
CREATE TABLE gif_bayer (x int, y int, t int, PRIMARY KEY (y, x));

INSERT INTO gif_bayer (x, y, t)
WITH RECURSIVE m (n, x, y, t) AS (
    SELECT 1, 0, 0, 0
  UNION ALL
    SELECT n * 2, x + n * q.dx, y + n * q.dy, t * 4 + q.a
    FROM m CROSS JOIN (VALUES (0,0,0), (1,0,2), (0,1,3), (1,1,1)) AS q(dx, dy, a)
    WHERE n < 8
)
SELECT x, y, t FROM m WHERE n = 8;

-- ---------------------------------------------------------------------------
-- The colour histogram.
--
-- Accumulated rather than computed in one pass, and that is the whole reason
-- it is a table with its own two functions instead of a subquery inside the
-- quantiser.  An animation has to be quantised against *one* palette -- a
-- palette chosen per frame shifts colours between frames and the result
-- crawls -- so the thing that has to see every frame at once is this, and it
-- is the only thing that does.  A frame is decoded, folded in here, and the
-- pixels are free to go; what survives is a row per distinct colour, which for
-- a rendered sequence is a few hundred thousand rows however long the
-- animation is.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_hist_reset() RETURNS void AS $$
BEGIN
  IF to_regclass('pg_temp.gif_hist') IS NOT NULL THEN
    DROP TABLE gif_hist;
  END IF;
  CREATE TEMP TABLE gif_hist (r int, g int, b int, n bigint,
                              PRIMARY KEY (r, g, b));
END $$ LANGUAGE plpgsql;

-- Fold one image's colours in.  `tbl` is anything shaped like `img`.
CREATE FUNCTION gif_hist_add(tbl text) RETURNS bigint AS $$
DECLARE added bigint;
BEGIN
  IF to_regclass('pg_temp.gif_hist') IS NULL THEN
    PERFORM gif_hist_reset();
  END IF;
  EXECUTE format($q$
    INSERT INTO gif_hist (r, g, b, n)
    SELECT r, g, b, count(*) FROM %1$s GROUP BY r, g, b
    ON CONFLICT (r, g, b) DO UPDATE SET n = gif_hist.n + EXCLUDED.n
  $q$, tbl::regclass);
  GET DIAGNOSTICS added = ROW_COUNT;
  RETURN added;
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Median cut.
--
-- One box holding every colour is split repeatedly until there are as many
-- boxes as the palette has entries; each box then contributes the mean of the
-- colours in it, weighted by how many pixels wore them.
--
-- ## A round at a time, not a box at a time
--
-- The textbook loop picks the single worst box, splits it, and repeats -- 255
-- iterations, each one a scan of the whole colour set to find one box.  That
-- is a sequential algorithm over a set, which is the shape this engine avoids
-- everywhere else.
--
-- What replaces it: every round splits *every* box it can, so a round is one
-- query and the count doubles.  Eight of those would be enough if boxes always
-- split -- and the first version of this did exactly that, and came back with
-- **207 colours out of a requested 256**.
--
-- The reason is worth keeping, because it is invisible in the output and
-- expensive.  A box holding one distinct colour cannot be cut, whatever its
-- population.  This renderer's images have several such colours -- one sky
-- tone alone wore 6% of a 240x160 frame -- and a colour that large is isolated
-- into its own box after three or four rounds, whereupon every remaining round
-- fails to split it and throws away the entries its subtree would have held.
-- Measured: 25 single-colour boxes, 34.7% of the pixels, 49 palette entries
-- spent on nothing.
--
-- So a round splits what it can *afford*, ranked: boxes that are splittable at
-- all, ordered by population times extent, taking as many as there is room
-- for.  That is the greedy algorithm's choice, made a whole round at a time
-- rather than one box at a time -- still one query per round, and now the last
-- round is a partial one that fills the palette exactly.  It converges in
-- eight or nine rounds instead of eight, and it uses every entry.
--
-- Ranking by population alone is what "median cut" classically means and it is
-- the wrong rank here for the same reason as above: it keeps choosing the box
-- around a dominant flat colour, which is the box least able to benefit.
-- Multiplying by the box's longest extent asks how many pixels are wrong and
-- by how much, together.
--
-- ## Where a box is cut
--
-- Along its longest axis, at the position that comes closest to halving the
-- population -- `abs(2 * run - tot)` minimised over the cut points that exist.
--
-- The obvious rule, "cut where the running count first passes half", is wrong
-- in a way that only shows up on lopsided boxes and then loses colours
-- silently.  A box holding one colour worn by 1 pixel and another worn by 100
-- has its median inside the second colour, so that rule puts both colours on
-- the same side and leaves the sibling empty -- two colours collapse into one
-- for no reason.  Minimising the imbalance over the cuts that are actually
-- available picks the only cut there is and keeps both.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_palette(p_colors int DEFAULT 256) RETURNS int AS $$
DECLARE
  target  int;
  boxes   int;
  live    int;
  nbox    int;
  room    int;
  entries int;
  mincode int;
  spread  float8;
BEGIN
  IF to_regclass('pg_temp.gif_hist') IS NULL THEN
    RAISE EXCEPTION 'no colour histogram: call gif_hist_add() first';
  END IF;

  -- A GIF colour table holds a power of two of entries, so asking for 200 and
  -- asking for 256 are the same request; rounding here rather than at the
  -- encoder keeps the palette and the file agreeing about its own size.
  target := 1 << greatest(1, least(8,
              floor(log(2.0, greatest(p_colors, 2)::numeric))::int));

  IF to_regclass('pg_temp.gif_box') IS NOT NULL THEN
    DROP TABLE gif_box;
  END IF;
  CREATE TEMP TABLE gif_box AS
  SELECT (row_number() OVER ())::int AS k, 0 AS box, r, g, b, n FROM gif_hist;

  LOOP
    SELECT count(*)::int, count(*) FILTER (WHERE c > 1)::int, max(box) + 1
      INTO boxes, live, nbox
    FROM (SELECT box, count(*) AS c FROM gif_box GROUP BY box) AS q;

    room := target - boxes;
    EXIT WHEN room <= 0 OR live = 0;

    -- Only the rows that move are written: a box that keeps its lower half
    -- keeps its number, and the upper half of each box that splits takes a
    -- number from beyond the current end.  Nothing is renumbered, so the ids
    -- stay unique without a second pass over the table.
    UPDATE gif_box t SET box = p.nb
    FROM (
      SELECT k, box, rn,
             -- The chosen cut for this box, carried onto all of its rows.  A
             -- cut at the last row is not a cut, so those candidates order
             -- away; a box with one row has no others, and first_value falls
             -- back to that row -- which is then never split, because such a
             -- box is not eligible below.
             first_value(rn) OVER (
               PARTITION BY box
               ORDER BY CASE WHEN rn < cnt THEN abs(2 * run - tot) END
                        NULLS LAST, rn) AS cut
      FROM (
        SELECT k, box, ext,
               row_number() OVER w                  AS rn,
               count(*)     OVER (PARTITION BY box) AS cnt,
               sum(n)       OVER w                  AS run,
               sum(n)       OVER (PARTITION BY box) AS tot
        FROM (
          SELECT k, box, r, g, b, n, greatest(er, eg, eb) AS ext,
                 CASE WHEN er >= eg AND er >= eb THEN r
                      WHEN eg >= eb              THEN g
                      ELSE                            b END AS key
          FROM (
            SELECT k, box, r, g, b, n,
                   max(r) OVER p - min(r) OVER p AS er,
                   max(g) OVER p - min(g) OVER p AS eg,
                   max(b) OVER p - min(b) OVER p AS eb
            FROM gif_box
            WINDOW p AS (PARTITION BY box)
          ) AS extent
        ) AS axis
        WINDOW w AS (PARTITION BY box ORDER BY key, r, g, b
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
      ) AS running
    ) AS c
    JOIN (
      SELECT z.box, nbox + (row_number() OVER (ORDER BY z.box))::int AS nb
      FROM (
        SELECT box, sum(n) * greatest(max(r) - min(r),
                                      max(g) - min(g),
                                      max(b) - min(b)) AS pri
        FROM gif_box GROUP BY box HAVING count(*) > 1
        ORDER BY pri DESC, box
        LIMIT room
      ) AS z
    ) AS p ON p.box = c.box
    WHERE t.k = c.k AND c.rn > c.cut;
  END LOOP;

  -- Empty boxes leave gaps in the numbering; the palette is what is left,
  -- renumbered from zero.
  IF to_regclass('pg_temp.gif_pal') IS NOT NULL THEN
    DROP TABLE gif_pal;
  END IF;
  CREATE TEMP TABLE gif_pal AS
  SELECT (row_number() OVER (ORDER BY box) - 1)::int AS i,
         round(sum(r::float8 * n) / sum(n))::int AS r,
         round(sum(g::float8 * n) / sum(n))::int AS g,
         round(sum(b::float8 * n) / sum(n))::int AS b
  FROM gif_box GROUP BY box;
  ALTER TABLE gif_pal ADD PRIMARY KEY (i);

  SELECT count(*) INTO entries FROM gif_pal;
  mincode := greatest(2, ceil(log(2.0, greatest(entries, 2)::numeric))::int);

  -- ------------------------------------------------------------------------
  -- Where the answer to "which entry is nearest" gets kept.
  --
  -- Empty here, and filled by gif_indices for the colours it actually meets;
  -- see the note there for why it is a cache rather than a table computed up
  -- front, and for the coarse lookup cube that stood here first and was 49%
  -- wrong.
  -- ------------------------------------------------------------------------
  IF to_regclass('pg_temp.gif_map') IS NOT NULL THEN
    DROP TABLE gif_map;
  END IF;
  CREATE TEMP TABLE gif_map (r int, g int, b int, i int, PRIMARY KEY (r, g, b));

  -- How far to dither: half the mean distance from a palette entry to its
  -- nearest neighbour.  The point of the matrix is to reach across the gap
  -- between two entries and no further, and the gap is a property of this
  -- palette on this image -- a fixed number of levels would be invisible on a
  -- flat image and a rash on a busy one.  On this renderer's output that gap
  -- is small: a 256-entry palette fitted to one frame of the default scene has
  -- its entries a mean of 3.9 apart, because a render's gamut is a sliver of
  -- the colour cube rather than the whole of it.
  SELECT coalesce(avg(sqrt(nn2)) / 2.0, 0.0) INTO spread
  FROM (SELECT min((p.r - q.r) * (p.r - q.r)
                 + (p.g - q.g) * (p.g - q.g)
                 + (p.b - q.b) * (p.b - q.b)) AS nn2
        FROM gif_pal p JOIN gif_pal q ON q.i <> p.i
        GROUP BY p.i) AS s;

  IF to_regclass('pg_temp.gif_meta') IS NOT NULL THEN
    DROP TABLE gif_meta;
  END IF;
  CREATE TEMP TABLE gif_meta AS
  SELECT entries AS entries, mincode AS mincode, spread AS spread;

  RETURN entries;
END $$ LANGUAGE plpgsql;

-- One channel of one pixel, nudged by its cell of the dither matrix.  Clamped
-- after the nudge, so a pixel already at black or white cannot be pushed off
-- the end of the range and wrap.  A function rather than an expression written
-- out twice because it is written out twice, below, and the two copies have to
-- agree exactly or the cache is filled with answers to questions nobody asks.
CREATE FUNCTION gif_dither(v int, t int, amp float8) RETURNS int
  AS $$ SELECT least(255, greatest(0, (v + ((t + 0.5) / 64.0 - 0.5) * amp)::int)) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- An image as palette indices, row by row -- one byte per pixel, which is what
-- LZW is about to be handed.
--
-- ## Dithering is off by default, and that is a measurement
--
-- Everything about the dither matrix above is true and it earns nothing at 256
-- colours on this renderer's output.  Measured on the default scene at
-- 240x160, against the unquantised frame:
--
--   colours  spacing  dither  per-pixel err  err of 4x4 means  bytes
--   16       7.03     off     5.85           4.44              5 302
--   16                on      6.54           **4.16**          8 295
--   64       3.50     off     2.58           1.64             10 195
--   64                on      2.98           **1.60**         14 221
--   256      1.97     off     1.31           **0.68**         16 145
--   256                on     1.60           0.69             18 835
--
-- Per-pixel error rises with dithering by construction -- that is what
-- dithering does -- so the column that matters is the second, the error left
-- after a 4x4 average, which is a crude stand-in for an eye.  At 256 colours
-- even that goes the wrong way, and the file grows 17%.
--
-- The reason is that a palette fitted to a render is *finer than the render*.
-- 256 entries over this gamut sit a mean of 2 levels apart, and the picture
-- being quantised is already 8-bit: the sky here is a smooth gradient that the
-- tone curve had already flattened into 12 distinct colours with runs 7 pixels
-- tall, and the 256-colour GIF reproduces those 12 and those runs exactly.
-- There is no banding to break up, so dithering can only add noise that was
-- not in the picture.
--
-- Below about 64 colours that reverses completely, and more sharply than the
-- table suggests -- the numbers barely separate the 16-colour pair while the
-- images are not close, hard posterised contours against smooth gradients.
-- Which is a caution about the metric rather than about the dither: a 4x4 mean
-- is blind to whether error is spread out or organised into a contour, and a
-- contour is the thing the eye finds.
--
-- So: off unless the palette is being squeezed, on when it is.
--
-- ## The lookup is a cache, and the obvious alternative was measurably wrong
--
-- Dithering moves a pixel off its own colour, so the answer cannot be read out
-- of the histogram -- the perturbed colour is one nobody rendered.  The first
-- version of this answered it by coarsening the colour cube to 5 bits a
-- channel and solving it exhaustively: 32 768 cells against 256 entries, once
-- per animation, and a pixel afterwards is a hash probe.  That reasoning had a
-- hole in it, and the hole is worth keeping because it is the sort that never
-- surfaces as an error.
--
-- **A palette fitted to a render is far finer than the cube.**  Its entries
-- sit a mean of 3.9 apart on the default scene -- the gamut of a picture is a
-- sliver of the colour space, not the whole of it -- while a 5-bit cell is 8
-- levels wide.  So the cube was quantising *below* the palette's resolution:
-- the frame's 15 480 distinct colours fell into 1 034 cells, the cube picked a
-- different entry from the true nearest one for **49% of them**, and the entry
-- it picked was a mean of 3.3 away -- most of the spacing it was supposed to
-- be resolving.  It also swallowed the dither, which at this spacing is about
-- a level: the perturbation rarely crossed a cell boundary, so asking for half
-- strength and asking for none produced identical files.
--
-- What replaces it costs less.  A render has far fewer distinct colours than
-- the cube has cells, so the exact search over the colours that actually occur
-- -- 15 480 against 256, 743 ms -- is cheaper than 8.4 million cells and has
-- no rounding in it at all.  Answers are kept, so a second frame pays only for
-- the colours the first one did not have, which is what makes this affordable
-- over a sequence.
--
-- min() over the distance packed above the index is how "argmin" is spelled
-- with an aggregate; DISTINCT ON would sort every candidate pair instead of
-- hashing them into one group per colour.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_indices(tbl text, p_dither float8 DEFAULT 0.0) RETURNS bytea AS $$
DECLARE
  amp float8;
  out bytea;
BEGIN
  SELECT spread * p_dither INTO amp FROM gif_meta;
  IF amp IS NULL THEN
    RAISE EXCEPTION 'no palette: call gif_palette() first';
  END IF;

  EXECUTE format($q$
    INSERT INTO gif_map (r, g, b, i)
    SELECT d.r, d.g, d.b,
           (min(((d.r - p.r) * (d.r - p.r)
               + (d.g - p.g) * (d.g - p.g)
               + (d.b - p.b) * (d.b - p.b)) * 256 + p.i) %% 256)::int
    -- The cache is consulted *before* the cross join, not after.  Written the
    -- other way round the planner is free to pair every colour with all 256
    -- entries and then discard the ones it already knew, which is 256 times
    -- the probes and, on a sequence where most colours are already known,
    -- nearly all of the work.
    FROM (SELECT dd.r, dd.g, dd.b
          FROM (SELECT DISTINCT gif_dither(t.r, bm.t, $1) AS r,
                                gif_dither(t.g, bm.t, $1) AS g,
                                gif_dither(t.b, bm.t, $1) AS b
                FROM %1$s t
                     JOIN gif_bayer bm ON bm.x = t.x %% 8 AND bm.y = t.y %% 8) AS dd
          WHERE NOT EXISTS (SELECT 1 FROM gif_map m
                             WHERE m.r = dd.r AND m.g = dd.g AND m.b = dd.b)) AS d
         CROSS JOIN gif_pal p
    GROUP BY d.r, d.g, d.b
    ON CONFLICT (r, g, b) DO NOTHING
  $q$, tbl::regclass) USING amp;
  ANALYZE gif_map;

  EXECUTE format($q$
    SELECT coalesce(decode(string_agg(lpad(to_hex(m.i), 2, '0'), ''
                                      ORDER BY t.y, t.x), 'hex'), ''::bytea)
    FROM %1$s t
         JOIN gif_bayer bm ON bm.x = t.x %% 8 AND bm.y = t.y %% 8
         JOIN gif_map m ON m.r = gif_dither(t.r, bm.t, $1)
                       AND m.g = gif_dither(t.g, bm.t, $1)
                       AND m.b = gif_dither(t.b, bm.t, $1)
  $q$, tbl::regclass) INTO out USING amp;

  RETURN out;
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- LZW, as GIF spells it.
--
-- The dictionary starts holding every single-byte string and grows by one
-- entry per emitted code: whatever was just emitted, plus the byte that ended
-- it.  Codes are written LSB-first, the same bit order DEFLATE uses, at a
-- width that starts one bit above the pixel size and grows as the dictionary
-- does.
--
-- ## The one thing that has to be exactly right
--
-- When the code width grows.  Encoder and decoder never hold the same
-- dictionary at the same moment -- the decoder learns each entry one code
-- later than the encoder invents it -- so they cannot share a rule, and a rule
-- that is off by one produces a file that decodes into plausible garbage
-- rather than an error.
--
-- Here: the encoder widens once the next code it would assign no longer fits,
-- `next > 1 << bits`, *after* assigning.  A decoder widens when its own next
-- code reaches `1 << bits`, before reading.  Those are the same instant,
-- because the decoder's counter runs exactly one behind -- and they agree at
-- the very first code, where the counters are momentarily equal, only because
-- `clear + 2 < 2 * clear`.  That inequality is why the format forbids a
-- minimum code size below 2 even for a two-colour image.
--
-- ## The dictionary
--
-- Direct-indexed rather than hashed: the key (prefix, byte) is at most
-- 4096 * 256, so it is an array subscript and the lookup is one read.  What
-- that costs is a million-element array to clear every time the dictionary
-- fills, which is why entries carry a generation number instead -- bumping the
-- generation invalidates all of them at once and the array is allocated once.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_lzw(data bytea, mincode int) RETURNS bytea AS $$
DECLARE
  n      int := length(data);
  clearc int := 1 << mincode;
  eoic   int := (1 << mincode) + 1;
  nextc  int;
  bits   int;
  dict   int[];
  gen    int := 1;
  key    int; v int; pfx int; k int; i int;
  out    int[]; outn int := 0;
  bitbuf bigint := 0; bitcnt int := 0;
BEGIN
  IF mincode < 2 OR mincode > 8 THEN
    RAISE EXCEPTION 'LZW minimum code size % is outside 2..8', mincode;
  END IF;
  data := detoast(data);
  out  := array_fill(0, ARRAY[greatest(1024, n)]);

  nextc := clearc + 2;
  bits  := mincode + 1;

  -- Start with a clear code, as the format requires: a decoder is entitled to
  -- assume nothing about the dictionary until it has seen one.
  bitbuf := clearc::bigint;
  bitcnt := bits;

  IF n > 0 THEN
    dict := array_fill(0, ARRAY[1 << 20]);
    pfx  := get_byte(data, 0);

    FOR i IN 1 .. n - 1 LOOP
      k   := get_byte(data, i);
      key := pfx * 256 + k;
      v   := dict[key + 1];
      IF v >> 12 = gen THEN
        pfx := v & 4095;
      ELSE
        -- The bit packer is written out here rather than called, for the
        -- reason given in 02_deflate.sql: this runs once per emitted code and
        -- a PL/pgSQL call would cost more than the work it wraps.
        bitbuf := bitbuf | (pfx::bigint << bitcnt);
        bitcnt := bitcnt + bits;
        WHILE bitcnt >= 8 LOOP
          outn := outn + 1; out[outn] := (bitbuf & 255)::int;
          bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
        END LOOP;

        dict[key + 1] := gen * 4096 + nextc;
        nextc := nextc + 1;
        IF nextc > (1 << bits) AND bits < 12 THEN
          bits := bits + 1;
        END IF;

        -- Code 4095 is the last one there is.  Emitting a clear and starting
        -- over is not the only legal response -- an encoder may also stop
        -- adding entries and keep going with the dictionary it has -- but it
        -- is the one every decoder has to support, and on a long animation a
        -- stale dictionary compresses steadily worse.
        IF nextc = 4096 THEN
          bitbuf := bitbuf | (clearc::bigint << bitcnt);
          bitcnt := bitcnt + bits;
          WHILE bitcnt >= 8 LOOP
            outn := outn + 1; out[outn] := (bitbuf & 255)::int;
            bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
          END LOOP;
          gen   := gen + 1;
          nextc := clearc + 2;
          bits  := mincode + 1;
        END IF;

        pfx := k;
      END IF;
    END LOOP;

    bitbuf := bitbuf | (pfx::bigint << bitcnt);
    bitcnt := bitcnt + bits;
    WHILE bitcnt >= 8 LOOP
      outn := outn + 1; out[outn] := (bitbuf & 255)::int;
      bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
    END LOOP;
  END IF;

  bitbuf := bitbuf | (eoic::bigint << bitcnt);
  bitcnt := bitcnt + bits;
  WHILE bitcnt > 0 LOOP
    outn := outn + 1; out[outn] := (bitbuf & 255)::int;
    bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
  END LOOP;

  RETURN bytes_of(out, outn);
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- The same stream, read back.
--
-- Here for the reason inflate is: an encoder with no decoder is checked only
-- by the thing it was written against, and a round trip over random input
-- catches the width-growth mistakes that a single known vector can walk past.
-- It is also the only way to read a GIF someone else wrote.
--
-- A code names a string, and a string is stored as its last byte plus the code
-- of everything before it -- so reconstructing one walks a chain backwards and
-- comes out reversed, which is what the stack is for.
--
-- The case worth naming is a code one past the end of the dictionary.  It
-- looks like corruption and is not: the encoder can emit a code it has only
-- just invented, and the decoder, one entry behind, has not got it yet.  The
-- string in that case is always the previous one plus its own first byte, and
-- there is no other way it can arise.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_unlzw(data bytea, mincode int) RETURNS bytea AS $$
DECLARE
  n      int := length(data);
  clearc int := 1 << mincode;
  eoic   int := (1 << mincode) + 1;
  nextc  int;
  bits   int;
  pre    int[]; suf int[];
  stack  int[]; sp int;
  out    int[]; outn int := 0;
  bitbuf bigint := 0; bitcnt int := 0;
  p      int := 0;
  code   int; prev int := -1; fst int; pfst int := -1; t int;
BEGIN
  data := detoast(data);
  out  := array_fill(0, ARRAY[greatest(1024, n * 2)]);
  pre  := array_fill(0, ARRAY[4096]);
  suf  := array_fill(0, ARRAY[4096]);
  stack := array_fill(0, ARRAY[4096]);

  nextc := clearc + 2;
  bits  := mincode + 1;

  LOOP
    IF nextc >= (1 << bits) AND bits < 12 THEN
      bits := bits + 1;
    END IF;
    WHILE bitcnt < bits AND p < n LOOP
      bitbuf := bitbuf | (get_byte(data, p)::bigint << bitcnt);
      p := p + 1; bitcnt := bitcnt + 8;
    END LOOP;
    EXIT WHEN bitcnt < bits;
    code   := (bitbuf & ((1::bigint << bits) - 1))::int;
    bitbuf := bitbuf >> bits;
    bitcnt := bitcnt - bits;

    EXIT WHEN code = eoic;

    IF code = clearc THEN
      nextc := clearc + 2;
      bits  := mincode + 1;
      prev  := -1;
      CONTINUE;
    END IF;

    IF prev = -1 THEN
      IF code >= clearc THEN
        RAISE EXCEPTION 'LZW stream opens with code %, which names nothing', code;
      END IF;
      outn := outn + 1; out[outn] := code;
      prev := code; pfst := code;
      CONTINUE;
    END IF;

    sp := 0;
    IF code = nextc THEN
      -- The one-behind case: the string is the previous one with its own first
      -- byte appended.
      sp := sp + 1; stack[sp] := pfst;
      t  := prev;
    ELSIF code < nextc THEN
      t := code;
    ELSE
      RAISE EXCEPTION 'LZW code % is past the dictionary (% entries)', code, nextc;
    END IF;

    WHILE t >= clearc LOOP
      sp := sp + 1; stack[sp] := suf[t + 1];
      t  := pre[t + 1];
    END LOOP;
    fst := t;
    sp := sp + 1; stack[sp] := t;

    WHILE sp > 0 LOOP
      outn := outn + 1; out[outn] := stack[sp];
      sp := sp - 1;
    END LOOP;

    IF nextc < 4096 THEN
      pre[nextc + 1] := prev;
      suf[nextc + 1] := fst;
      nextc := nextc + 1;
    END IF;
    prev := code; pfst := fst;
  END LOOP;

  RETURN bytes_of(out, outn);
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Sub-block framing: GIF carries its payloads as a chain of runs of at most
-- 255 bytes, each behind its own length byte, ending with a zero length.  It
-- is the container's business rather than the codec's, which is why it is here
-- and not inside gif_lzw -- exactly as png_chunk sits outside deflate.
--
-- Unlike the codec this is a set operation: the split points are arithmetic on
-- the length, so every block can be cut at once.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_blocks(data bytea) RETURNS bytea AS $$
  WITH d AS MATERIALIZED (SELECT detoast(data) AS raw)
  SELECT coalesce(
           string_agg(set_byte('\x00'::bytea, 0, least(255, length(d.raw) - i))
                      || substring(d.raw FROM i + 1 FOR 255), '' ORDER BY i),
           ''::bytea) || '\x00'::bytea
  FROM d LEFT JOIN generate_series(0, length(data) - 1, 255) AS g(i) ON true
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- One frame's compressed data as the container wants it: the minimum code
-- size, then the blocks.  The code size is read from the palette rather than
-- passed in, so the byte in the file and the width the encoder used cannot
-- disagree.
--
-- PL/pgSQL rather than SQL only because `gif_meta` is a temp table that does
-- not exist when this file is loaded, and a SQL body is resolved then.
CREATE FUNCTION gif_image(indices bytea) RETURNS bytea AS $$
DECLARE mincode int;
BEGIN
  SELECT m.mincode INTO mincode FROM gif_meta m;
  IF mincode IS NULL THEN
    RAISE EXCEPTION 'no palette: call gif_palette() first';
  END IF;
  RETURN set_byte('\x00'::bytea, 0, mincode)
      || gif_blocks(gif_lzw(indices, mincode));
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- The container.
--
-- `images` are gif_image() payloads, one per frame; `delays` are hundredths of
-- a second, the only unit GIF has.  `p_loop` is how many times to repeat, 0
-- being forever.
--
-- Two details that are conventions rather than the specification:
--
--   * **Looping is a Netscape application extension.**  GIF89a has no field
--     for it.  Every reader supports the extension and none of them agree on
--     much else about it, so it is written the way the original was, byte for
--     byte, and only when there is more than one frame.
--   * **A delay below two hundredths is not honoured.**  Browsers clamp it,
--     historically to ten, so a "fast" animation asked for in single
--     hundredths comes out slower than one asked for in twos.
--
-- The disposal method is 1, leave the frame in place.  Every frame here is
-- opaque and covers the whole screen, so nothing needs restoring between them;
-- asking for a restore instead makes readers clear to the background first and
-- some of them show the flash.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_encode(w int, h int, images bytea[],
                           delays int[] DEFAULT NULL, p_loop int DEFAULT 0)
RETURNS bytea AS $$
DECLARE
  entries int;
  mincode int;
  gctn    int;
  gct     bytea;
  body    bytea;
  nf      int := coalesce(array_length(images, 1), 0);
BEGIN
  SELECT m.entries, m.mincode INTO entries, mincode FROM gif_meta m;
  IF entries IS NULL THEN
    RAISE EXCEPTION 'no palette: call gif_palette() first';
  END IF;
  IF nf = 0 THEN
    RAISE EXCEPTION 'a GIF needs at least one image';
  END IF;

  -- The colour table is a power of two long whether or not the palette filled
  -- it; the spare entries are black and nothing indexes them.
  gctn := 1 << mincode;
  SELECT string_agg(coalesce(decode(lpad(to_hex(p.r), 2, '0')
                                 || lpad(to_hex(p.g), 2, '0')
                                 || lpad(to_hex(p.b), 2, '0'), 'hex'),
                             '\x000000'::bytea), '' ORDER BY s.i)
    INTO gct
  FROM generate_series(0, gctn - 1) AS s(i) LEFT JOIN gif_pal p ON p.i = s.i;

  SELECT string_agg(
           -- Graphic Control Extension: four bytes of block, of which the only
           -- ones that matter here are the disposal method and the delay.
           '\x21f904'::bytea || '\x04'::bytea
             || le16(coalesce(delays[k], 0)) || '\x0000'::bytea
           -- Image Descriptor: the frame covers the whole screen, and uses the
           -- global colour table rather than one of its own.
           || '\x2c'::bytea || le16(0) || le16(0) || le16(w) || le16(h)
             || '\x00'::bytea
           || images[k], '' ORDER BY k)
    INTO body
  FROM generate_series(1, nf) AS g(k);

  RETURN convert_to('GIF89a', 'SQL_ASCII')
      -- Logical Screen Descriptor.  The packed byte says: a global colour
      -- table follows, of 2^(n+1) entries; the source had 8 bits a channel.
      || le16(w) || le16(h)
      || set_byte('\x00'::bytea, 0, 240 + mincode - 1) || '\x0000'::bytea
      || gct
      || CASE WHEN nf > 1
              THEN '\x21ff0b'::bytea || convert_to('NETSCAPE2.0', 'SQL_ASCII')
                   || '\x0301'::bytea || le16(p_loop) || '\x00'::bytea
              ELSE ''::bytea END
      || body
      || '\x3b'::bytea;
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- A single image, start to finish: a table shaped like `img` in, a GIF out.
--
-- Every palette here is built from this one image, which is what makes it the
-- wrong entry point for a sequence -- see frames_gif() in 07_frame.sql, which
-- accumulates one histogram across every frame before quantising any of them.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gif_of(tbl text, p_colors int DEFAULT 256,
                       p_dither float8 DEFAULT 0.0) RETURNS bytea AS $$
DECLARE w int; h int;
BEGIN
  EXECUTE format('SELECT max(x) + 1, max(y) + 1 FROM %s', tbl::regclass)
    INTO w, h;
  IF w IS NULL THEN
    RAISE EXCEPTION 'nothing to encode: % is empty', tbl;
  END IF;

  PERFORM gif_hist_reset();
  PERFORM gif_hist_add(tbl);
  PERFORM gif_palette(p_colors);

  RETURN gif_encode(w, h, ARRAY[gif_image(gif_indices(tbl, p_dither))]);
END $$ LANGUAGE plpgsql;
