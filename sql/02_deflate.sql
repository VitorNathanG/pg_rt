-- ---------------------------------------------------------------------------
-- DEFLATE (RFC 1951), in both directions.
--
-- PostgreSQL exposes no zlib binding to SQL, so the codec is written out here:
-- LZ77 match finding, Huffman code construction, the bit stream, and inflate
-- to read all of it back.  Nothing in this file knows what a PNG is -- it is
-- the general format, and the container is built on top of it in 02_png.sql.
--
-- Inflate is here for its own sake as much as for symmetry.  Until it existed
-- nothing could read an image *into* the database: a PNG on disk was opaque,
-- and so a texture had nowhere to come from.  It is unused today.
--
-- ## The two measurements the whole file is shaped around
--
-- Both directions are byte-at-a-time loops, which in PL/pgSQL means that where
-- the bytes live decides everything, on both sides of the loop.
--
-- **Writing them.**  `bytea` is the obvious accumulator and it is quadratic:
-- `b := set_byte(b, k, v)` copies the whole value per call, and 100k writes
-- into a 100 kB buffer measured 397 ms.  An `int[]` local is held by PL/pgSQL
-- as an *expanded* datum, so subscripted assignment happens in place -- 200k
-- writes measured 14 ms, and appending one past the end grows geometrically
-- rather than copying (500k appends, 34 ms).  So every buffer here is an int[]
-- of byte values, converted to bytea exactly once at the end.  That conversion
-- is the one place a set-based expression beats a loop, and it is cheap: 1M
-- elements through string_agg/decode measured 136 ms.
--
-- **Reading them.**  The same shape, worse, and from the other direction: a
-- large bytea argument arrives as a pointer and `get_byte` resolves it on
-- every call.  1 MB read from a table measured 110 818 ms against 150 ms for
-- the same bytes built inline -- 741x -- so everything here calls `detoast`
-- first.  See the note on it below; it is the single most expensive thing in
-- this file to have got wrong.
-- ---------------------------------------------------------------------------

-- Big-endian 32-bit field, the width used by every PNG length and CRC and by
-- the zlib Adler trailer.
CREATE FUNCTION be32(v bigint) RETURNS bytea
  AS $$ SELECT decode(lpad(to_hex(v & 4294967295), 8, '0'), 'hex') $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Little-endian 16-bit field, used by DEFLATE stored-block headers.
CREATE FUNCTION le16(v int) RETURNS bytea
  AS $$ SELECT decode(lpad(to_hex((v & 255) * 256 + ((v >> 8) & 255)), 4, '0'), 'hex') $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- Pull a value into memory once, before anything reads it a byte at a time.
--
-- This is not a nicety, it is the difference between linear and quadratic.  A
-- `bytea` big enough to be interesting is stored out of line, and the argument
-- a function receives is a pointer to it rather than the bytes.  `get_byte`
-- resolves that pointer on every single call -- fetching, and reassembling,
-- the entire value -- so a loop over a megabyte fetches a megabyte a million
-- times.  Measured on 1 MB: 110 818 ms against 150 ms for the same bytes when
-- they had never been stored.  **741x**, and it gets worse with size.
--
-- Assigning to a local does not fix it; PL/pgSQL copies the pointer.  It takes
-- an operation that builds a *new* value, which is what substring does.
--
-- The rule this leaves is short: any function here that reads a bytea argument
-- more than a few times calls this first, and every one of them does.
-- ---------------------------------------------------------------------------
CREATE FUNCTION detoast(b bytea) RETURNS bytea
  AS $$ SELECT substring(b FROM 1) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- A byte buffer built as int[] becomes bytea here, and only here.
CREATE FUNCTION bytes_of(a int[], n int) RETURNS bytea AS $$
  SELECT coalesce(
           decode((SELECT string_agg(lpad(to_hex(a[i]), 2, '0'), '')
                   FROM generate_series(1, n) AS i), 'hex'),
           ''::bytea)
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

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

-- MATERIALIZED, and it has to be.  This is the only function here that reads
-- its bytes set-based rather than in a loop, so the detoast has to survive as
-- its own evaluation -- and a plain `(SELECT detoast(b)) AS d(raw)` does not.
-- The planner pulls a one-row subquery up into the parent and substitutes the
-- expression at every reference, which turns one detoast into one *per byte*:
-- measured slower than having no detoast at all.  `OFFSET 0` is not enough
-- either; it blocks pull-up but not re-execution.  Only materialising fixes
-- the count.
CREATE FUNCTION adler32(b bytea) RETURNS bigint AS $$
  WITH d AS MATERIALIZED (SELECT detoast(b) AS raw)
  SELECT (((1 + s1) % 65521)::bigint & 65535)
       | ((((n + s2) % 65521)::bigint & 65535) << 16)
  FROM d,
       (SELECT length(b)::bigint) AS q(n),
       LATERAL (
         SELECT coalesce(sum(byte), 0), coalesce(sum(byte * (n - j + 1)), 0)
         FROM generate_series(1, n) AS s(j),
              LATERAL (SELECT get_byte(d.raw, (j - 1)::int)::bigint) AS p(byte)
       ) AS a(s1, s2)
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- The RFC 1951 code tables.
--
-- A match is not written as (length, distance) but as a *code* plus a few
-- extra bits, because lengths cluster near 3 and distances spread over 32 kB:
-- code 257 means exactly 3, code 284 means "227 plus these five bits".  These
-- are the tables from section 3.2.5, built once at install time so that both
-- directions read the same numbers rather than two hand-typed copies.
-- ---------------------------------------------------------------------------

CREATE TABLE deflate_len (code int PRIMARY KEY, extra int NOT NULL, base int NOT NULL);
INSERT INTO deflate_len (code, extra, base) VALUES
  (257,0,3),(258,0,4),(259,0,5),(260,0,6),(261,0,7),(262,0,8),(263,0,9),(264,0,10),
  (265,1,11),(266,1,13),(267,1,15),(268,1,17),
  (269,2,19),(270,2,23),(271,2,27),(272,2,31),
  (273,3,35),(274,3,43),(275,3,51),(276,3,59),
  (277,4,67),(278,4,83),(279,4,99),(280,4,115),
  (281,5,131),(282,5,163),(283,5,195),(284,5,227),
  (285,0,258);

CREATE TABLE deflate_dist (code int PRIMARY KEY, extra int NOT NULL, base int NOT NULL);
INSERT INTO deflate_dist (code, extra, base) VALUES
  (0,0,1),(1,0,2),(2,0,3),(3,0,4),(4,1,5),(5,1,7),(6,2,9),(7,2,13),
  (8,3,17),(9,3,25),(10,4,33),(11,4,49),(12,5,65),(13,5,97),
  (14,6,129),(15,6,193),(16,7,257),(17,7,385),(18,8,513),(19,8,769),
  (20,9,1025),(21,9,1537),(22,10,2049),(23,10,3073),(24,11,4097),(25,11,6145),
  (26,12,8193),(27,12,12289),(28,13,16385),(29,13,24577);

-- The encoder needs those tables inverted: given a match length, which code?
-- 256 entries covers every legal length, so it is a plain lookup.  Length 258
-- is the exception in the standard and has to be the exception here: it falls
-- inside code 284's range but has its own zero-extra-bit code 285, which is
-- one bit cheaper for the commonest long match there is.
CREATE TABLE deflate_lcode (i int PRIMARY KEY, code int NOT NULL);
INSERT INTO deflate_lcode (i, code)
SELECT l - 3,
       CASE WHEN l = 258 THEN 285
            ELSE (SELECT max(code) FROM deflate_len WHERE base <= l AND code < 285) END
FROM generate_series(3, 258) AS g(l);

-- Distances run to 32768, and a 32768-entry array rebuilt per call would cost
-- more than the lookups save.  zlib's trick is that above 256 the code ranges
-- are all multiples of 128, so the top of the range can be folded: index by
-- the distance itself below 256 and by 256 + (distance >> 7) above.  512
-- entries, and slots 256 and 257 are unreachable by that formula -- they would
-- mean a distance under 256, which took the other branch.
CREATE TABLE deflate_dcode (i int PRIMARY KEY, code int NOT NULL);
INSERT INTO deflate_dcode (i, code)
SELECT i, (SELECT max(code) FROM deflate_dist WHERE base <= d + 1)
FROM generate_series(0, 511) AS g(i),
     LATERAL (SELECT CASE WHEN i < 256 THEN i ELSE (i - 256) << 7 END) AS q(d);

-- ---------------------------------------------------------------------------
-- Huffman codes.
--
-- Three of these are built per compressed block -- literals/lengths,
-- distances, and the little alphabet that describes the other two -- and none
-- has more than 286 symbols, so nothing in here is on a hot path.  It is the
-- one part of the codec that gets to be written for clarity.
-- ---------------------------------------------------------------------------

-- Optimal code lengths for a symbol's frequencies, capped at `maxbits`.
--
-- The textbook algorithm wants a priority queue; the standard trick avoids it.
-- Sort the leaves by weight once, and note that merged nodes come out in
-- ascending weight order too, so the two smallest live nodes are always at the
-- head of one queue or the other.  That makes the merge a linear scan over two
-- cursors and the sort a plain ORDER BY.
--
-- DEFLATE caps a code at 15 bits, and a natural Huffman tree exceeds that once
-- the frequencies get Fibonacci-shaped -- reachable in practice, not just in
-- theory, once a block has a few thousand symbols.  The repair here is the
-- crude one: halve every weight and rebuild.  It provably terminates, because
-- once every weight is 1 the tree is balanced and 286 symbols fit in 9 bits.
--
-- It also overshoots, and measuring that is what says the crudeness is
-- affordable: on 20 symbols with Fibonacci weights it turns a 19-deep tree into
-- a 10-deep one -- far under the 15 it had to reach -- for 46353 bits against
-- the unconstrained optimum's 46344.  0.02%.  The cost stays near nothing
-- because the codes that were too long belonged to the symbols that hardly
-- occur, which is the same property that made the tree deep in the first place.
CREATE FUNCTION huff_lengths(freq bigint[], maxbits int DEFAULT 15) RETURNS int[] AS $$
DECLARE
  n    int := array_length(freq, 1);
  f    bigint[] := freq;
  len  int[];
  ord  int[];          -- active symbols, ascending by weight
  na   int;
  w    bigint[];       -- node weights: 1..na leaves, na+1.. internal
  par  int[];
  ia   int;            -- cursor into the leaf queue
  ib   int;            -- cursor into the internal queue
  m    int;            -- last node created
  a    int; b int; k int; d int; maxd int;
BEGIN
  LOOP
    len := array_fill(0, ARRAY[n]);

    SELECT array_agg(i ORDER BY f[i], i) INTO ord
      FROM generate_series(1, n) AS g(i) WHERE f[i] > 0;
    na := coalesce(array_length(ord, 1), 0);

    -- A tree needs two codes to be a tree.  Zero or one active symbol is a
    -- real case -- a block with no matches has an empty distance alphabet --
    -- and the cheapest legal answer is two one-bit codes on the lowest
    -- symbols, which costs two entries in the block header and nothing else.
    IF na < 2 THEN
      len[1] := 1;
      len[2] := 1;
      IF na = 1 AND ord[1] > 2 THEN
        len[ord[1]] := 1;
        len[2] := 0;
      END IF;
      RETURN len;
    END IF;

    w   := array_fill(0::bigint, ARRAY[2 * na - 1]);
    par := array_fill(0, ARRAY[2 * na - 1]);
    FOR k IN 1 .. na LOOP w[k] := f[ord[k]]; END LOOP;

    ia := 1;                  -- leaves ia..na are unmerged
    ib := na + 1;             -- internals ib..m are unmerged
    m  := na;
    WHILE (na - ia + 1) + (m - ib + 1) > 1 LOOP
      -- Two pulls of "smallest live node", preferring a leaf on a tie: that
      -- keeps leaves shallow, which is what the length cap cares about.
      IF ib > m OR (ia <= na AND w[ia] <= w[ib]) THEN a := ia; ia := ia + 1;
      ELSE a := ib; ib := ib + 1; END IF;
      IF ib > m OR (ia <= na AND w[ia] <= w[ib]) THEN b := ia; ia := ia + 1;
      ELSE b := ib; ib := ib + 1; END IF;

      m := m + 1;
      w[m] := w[a] + w[b];
      par[a] := m;
      par[b] := m;
    END LOOP;

    maxd := 0;
    FOR k IN 1 .. na LOOP
      d := 0;
      a := k;
      WHILE par[a] <> 0 LOOP d := d + 1; a := par[a]; END LOOP;
      len[ord[k]] := d;
      IF d > maxd THEN maxd := d; END IF;
    END LOOP;

    EXIT WHEN maxd <= maxbits;

    FOR k IN 1 .. n LOOP
      IF f[k] > 0 THEN f[k] := (f[k] + 1) >> 1; END IF;
    END LOOP;
  END LOOP;

  RETURN len;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- Canonical codes for a set of lengths, **already bit-reversed**.
--
-- The reversal is not a detail to be tidied away later.  DEFLATE packs its bit
-- stream least-significant-bit first, but a Huffman code is defined
-- most-significant-bit first, so every code has to go out backwards.  Doing it
-- at emit time would mean a fifteen-iteration loop per symbol written -- tens
-- of millions of them for one frame -- and doing it here means one per symbol
-- *defined*, of which there are at most 286.
CREATE FUNCTION huff_emit_codes(len int[]) RETURNS bigint[] AS $$
DECLARE
  n       int := array_length(len, 1);
  blcount int[] := array_fill(0, ARRAY[17]);   -- slot l+1 counts length l
  nextc   bigint[] := array_fill(0::bigint, ARRAY[16]);
  code    bigint[] := array_fill(0::bigint, ARRAY[n]);
  s int; l int; k int; c bigint; r bigint;
BEGIN
  FOR s IN 1 .. n LOOP
    IF len[s] > 0 THEN blcount[len[s] + 1] := blcount[len[s] + 1] + 1; END IF;
  END LOOP;

  c := 0;
  FOR l IN 1 .. 15 LOOP
    c := (c + blcount[l]) << 1;                -- blcount[l] is the count for l-1
    nextc[l] := c;
  END LOOP;

  FOR s IN 1 .. n LOOP
    l := len[s];
    IF l > 0 THEN
      c := nextc[l];
      nextc[l] := c + 1;
      r := 0;
      FOR k IN 1 .. l LOOP r := (r << 1) | (c & 1); c := c >> 1; END LOOP;
      code[s] := r;
    END IF;
  END LOOP;

  RETURN code;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- The decoder's view of the same tree, in the form RFC 1951 section 3.2.2
-- describes: how many codes exist at each length, and the symbols in canonical
-- order.  Walking those two arrays decodes a symbol in one pass over its bits
-- with no tree to store.
--
-- The tempting thought here -- a canonical Huffman table *is* a table, so
-- decoding a symbol ought to be a join on (length, code) -- turns out to be
-- right about the *construction* and wrong about the *use*.  Both arrays fall
-- straight out of an ORDER BY, which is why this function is four lines; but a
-- join per symbol decoded would be an SPI round trip per symbol, and there are
-- millions of them.
CREATE FUNCTION huff_decode_table(len int[], OUT cnt int[], OUT sym int[]) AS $$
BEGIN
  SELECT array_agg(coalesce(c, 0)::int ORDER BY l) INTO cnt
    FROM generate_series(1, 15) AS g(l)
    LEFT JOIN (SELECT len[i] AS ln, count(*) AS c
                 FROM generate_series(1, array_length(len, 1)) AS q(i)
                WHERE len[i] > 0 GROUP BY len[i]) AS t ON t.ln = g.l;

  SELECT array_agg(i - 1 ORDER BY len[i], i) INTO sym
    FROM generate_series(1, array_length(len, 1)) AS q(i) WHERE len[i] > 0;
END $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- The dynamic-block header.
--
-- A dynamic block ships its own code lengths, and DEFLATE compresses even
-- those: the length list is run-length coded (16 = "repeat that again 3-6
-- times", 17 and 18 = runs of zero) and the result is itself Huffman coded
-- with a third alphabet of 19 symbols, whose lengths go out as bare 3-bit
-- fields in a fixed, frequency-ordered permutation.
--
-- Returned as a bit list rather than bytes because the caller is mid-stream
-- and not on a byte boundary -- and because its *length* is the whole reason
-- to compute it early.  A dynamic block is only worth emitting if the header
-- costs less than the tighter codes save, so sum(bw) is the number the block
-- chooser needs before it commits to anything.
-- ---------------------------------------------------------------------------
CREATE FUNCTION deflate_dyn_header(litlen int[], distlen int[],
                                   OUT bv bigint[], OUT bw int[]) AS $$
DECLARE
  -- Section 3.2.7's permutation: the lengths most likely to be zero come last,
  -- so HCLEN can drop them off the end.
  perm  int[] := ARRAY[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
  hlit  int; hdist int; hclen int;
  lens  int[];
  total int;
  rsym  int[] := '{}';       -- the run-length coded length list
  rext  bigint[] := '{}';
  rbits int[] := '{}';
  nr    int := 0;
  clf   bigint[] := array_fill(0::bigint, ARRAY[19]);
  cllen int[]; clcode bigint[];
  i int; k int; r int; cur int; run int; nb int := 0;
BEGIN
  hlit := 286;
  WHILE hlit > 257 AND litlen[hlit] = 0 LOOP hlit := hlit - 1; END LOOP;
  hdist := 30;
  WHILE hdist > 1 AND distlen[hdist] = 0 LOOP hdist := hdist - 1; END LOOP;

  lens  := litlen[1:hlit] || distlen[1:hdist];
  total := hlit + hdist;

  i := 1;
  WHILE i <= total LOOP
    cur := lens[i];
    run := 1;
    WHILE i + run <= total AND lens[i + run] = cur LOOP run := run + 1; END LOOP;

    IF cur = 0 THEN
      WHILE run >= 11 LOOP
        r := least(run, 138);
        nr := nr + 1; rsym[nr] := 18; rext[nr] := r - 11; rbits[nr] := 7;
        run := run - r; i := i + r;
      END LOOP;
      WHILE run >= 3 LOOP
        r := least(run, 10);
        nr := nr + 1; rsym[nr] := 17; rext[nr] := r - 3; rbits[nr] := 3;
        run := run - r; i := i + r;
      END LOOP;
    ELSE
      nr := nr + 1; rsym[nr] := cur; rext[nr] := 0; rbits[nr] := 0;
      run := run - 1; i := i + 1;
      WHILE run >= 3 LOOP
        r := least(run, 6);
        nr := nr + 1; rsym[nr] := 16; rext[nr] := r - 3; rbits[nr] := 2;
        run := run - r; i := i + r;
      END LOOP;
    END IF;

    WHILE run > 0 LOOP
      nr := nr + 1; rsym[nr] := cur; rext[nr] := 0; rbits[nr] := 0;
      run := run - 1; i := i + 1;
    END LOOP;
  END LOOP;

  FOR k IN 1 .. nr LOOP clf[rsym[k] + 1] := clf[rsym[k] + 1] + 1; END LOOP;
  cllen  := huff_lengths(clf, 7);
  clcode := huff_emit_codes(cllen);

  hclen := 19;
  WHILE hclen > 4 AND cllen[perm[hclen] + 1] = 0 LOOP hclen := hclen - 1; END LOOP;

  bv := array_fill(0::bigint, ARRAY[3 + hclen + 2 * nr]);
  bw := array_fill(0, ARRAY[3 + hclen + 2 * nr]);

  nb := nb + 1; bv[nb] := hlit - 257;  bw[nb] := 5;
  nb := nb + 1; bv[nb] := hdist - 1;   bw[nb] := 5;
  nb := nb + 1; bv[nb] := hclen - 4;   bw[nb] := 4;
  FOR k IN 1 .. hclen LOOP
    nb := nb + 1; bv[nb] := cllen[perm[k] + 1]; bw[nb] := 3;
  END LOOP;
  FOR k IN 1 .. nr LOOP
    nb := nb + 1; bv[nb] := clcode[rsym[k] + 1]; bw[nb] := cllen[rsym[k] + 1];
    IF rbits[k] > 0 THEN
      nb := nb + 1; bv[nb] := rext[k]; bw[nb] := rbits[k];
    END IF;
  END LOOP;

  bv := bv[1:nb];
  bw := bw[1:nb];
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- deflate: a complete DEFLATE stream.
--
-- `level` sets how hard the match finder looks and nothing else; every level
-- produces a stream any decoder reads.  0 skips matching entirely and emits
-- stored blocks, which is what `zlib_stored` was.
--
-- The block type is chosen by measuring rather than by rule.  All three
-- candidates -- stored, fixed Huffman, dynamic Huffman -- are costed in bits
-- before a single one is written, and the cheapest wins.  The cost has to be
-- the whole cost, extra bits included; see the note at the comparison for what
-- it cost to leave them out.
--
-- One block covers the whole input.  Splitting it would let the trees adapt to
-- a picture whose top and bottom differ, which is a refinement rather than a
-- correctness matter, and it costs the match finder its window across the cut.
-- ---------------------------------------------------------------------------
CREATE FUNCTION deflate(raw bytea, level int DEFAULT 6) RETURNS bytea AS $$
DECLARE
  n      int := length(raw);
  -- How far down a hash chain to walk, and the match length at which to stop
  -- looking.  This is the whole of `level`.
  maxchain int := (ARRAY[0,4,8,16,32,64,128,256,512,1024])[least(greatest(level,0),9) + 1];
  nicelen  int := (ARRAY[0,8,16,32,64,96,128,192,258,258])[least(greatest(level,0),9) + 1];

  lcodeof int[]; dcodeof int[];
  lbase int[]; lext int[]; dbase int[]; dext int[];

  head int[]; prev int[];
  h int; p int; j int; k int; q int;
  bestl int; bestd int; l int; mlen int; chain int;

  tsym int[]; tdst int[]; nt int := 0;
  lfreq bigint[] := array_fill(0::bigint, ARRAY[286]);
  dfreq bigint[] := array_fill(0::bigint, ARRAY[30]);

  litlen int[]; distlen int[]; litcode bigint[]; distcode bigint[];
  hv bigint[]; hw int[];
  dyncost bigint := 0; fixcost bigint := 0; extracost bigint := 0; storedcost bigint;
  usedyn boolean;
  fixlit int[]; fixdist int[];

  out int[]; outn int := 0;
  bitbuf bigint := 0; bitcnt int := 0;
  bv bigint; bw int;
  c int; s int; e int;
  pos int; chunk int; final int;
BEGIN
  raw := detoast(raw);
  IF n = 0 THEN
    -- A final fixed-Huffman block whose only symbol is end-of-block: three
    -- bits of block header and the seven-bit code 0000000, padded to two
    -- bytes.  A stored block would say the same thing in five.
    RETURN '\x0300'::bytea;
  END IF;

  ------------------------------------------------------------------ stored --
  IF level <= 0 THEN
    out := array_fill(0, ARRAY[n + 5 * (n / 65535 + 1)]);
    pos := 0;
    LOOP
      chunk := least(65535, n - pos);
      final := CASE WHEN pos + chunk >= n THEN 1 ELSE 0 END;
      outn := outn + 1; out[outn] := final;
      outn := outn + 1; out[outn] := chunk & 255;
      outn := outn + 1; out[outn] := (chunk >> 8) & 255;
      outn := outn + 1; out[outn] := (~chunk) & 255;
      outn := outn + 1; out[outn] := ((~chunk) >> 8) & 255;
      FOR k IN 1 .. chunk LOOP
        outn := outn + 1; out[outn] := get_byte(raw, pos + k - 1);
      END LOOP;
      pos := pos + chunk;
      EXIT WHEN pos >= n;
    END LOOP;
    RETURN bytes_of(out, outn);
  END IF;

  SELECT array_agg(code ORDER BY i) INTO lcodeof FROM deflate_lcode;
  SELECT array_agg(code ORDER BY i) INTO dcodeof FROM deflate_dcode;
  SELECT array_agg(base ORDER BY code), array_agg(extra ORDER BY code)
    INTO lbase, lext FROM deflate_len;
  SELECT array_agg(base ORDER BY code), array_agg(extra ORDER BY code)
    INTO dbase, dext FROM deflate_dist;

  ------------------------------------------------------------------- LZ77 --
  --
  -- The classic hash chain: `head` is the most recent position whose next
  -- three bytes hashed to h, and `prev` links back through the older ones, so
  -- following the chain visits candidate matches newest-first -- which is also
  -- cheapest-first, because a nearer match takes a shorter distance code.
  --
  -- The chain walk is the hot loop of the whole encoder, and the thing that
  -- makes it affordable is the one-byte pre-check: a candidate can only beat
  -- the incumbent if it matches at the position where the incumbent *ends*, so
  -- comparing that single byte first rejects nearly every candidate for the
  -- price of two array reads instead of a comparison loop.
  head := array_fill(0, ARRAY[65536]);
  prev := array_fill(0, ARRAY[n]);
  tsym := array_fill(0, ARRAY[n]);
  tdst := array_fill(0, ARRAY[n]);

  h := 0;
  IF n >= 1 THEN h := get_byte(raw, 0); END IF;
  IF n >= 2 THEN h := ((h << 6) # get_byte(raw, 1)) & 65535; END IF;
  IF n >= 3 THEN h := ((h << 6) # get_byte(raw, 2)) & 65535; END IF;

  p := 1;
  WHILE p <= n LOOP
    mlen  := 1;
    bestl := 2;
    bestd := 0;

    IF p + 2 <= n THEN
      j := head[h + 1];
      chain := 0;
      -- `p + bestl <= n` is the pre-check's own bound as much as a guard: it
      -- looks at the byte one past where the incumbent match ends, so once the
      -- incumbent runs to the last byte of the input there is nothing left to
      -- beat it with and nothing left to read.
      WHILE j > 0 AND p - j <= 32768 AND chain < maxchain AND p + bestl <= n LOOP
        IF get_byte(raw, j + bestl - 1) = get_byte(raw, p + bestl - 1) THEN
          l := 0;
          WHILE l < 258 AND p + l <= n
                AND get_byte(raw, j + l - 1) = get_byte(raw, p + l - 1) LOOP
            l := l + 1;
          END LOOP;
          IF l > bestl THEN
            bestl := l;
            bestd := p - j;
            EXIT WHEN l >= nicelen;
          END IF;
        END IF;
        j := prev[j];
        chain := chain + 1;
      END LOOP;
      -- `bestl >= 3` is redundant as the code stands -- bestl starts at 2 and
      -- only moves on `l > bestl` -- and it is written anyway because what
      -- happens if it ever stops being redundant is not a worse ratio.  `mlen`
      -- is how far the loop advances as well as the match length, so a
      -- two-byte match would emit one literal and step over two bytes, and the
      -- image would come back one byte short with nothing raising anything.
      IF bestd > 0 AND bestl >= 3 THEN mlen := bestl; END IF;
    END IF;

    nt := nt + 1;
    IF mlen >= 3 THEN
      tsym[nt] := bestl;
      tdst[nt] := bestd;
      c := lcodeof[bestl - 2];                 -- table is 0-based on len-3
      lfreq[c + 1] := lfreq[c + 1] + 1;
      q := bestd - 1;
      c := dcodeof[CASE WHEN q < 256 THEN q ELSE 256 + (q >> 7) END + 1];
      dfreq[c + 1] := dfreq[c + 1] + 1;
    ELSE
      s := get_byte(raw, p - 1);
      tsym[nt] := s;
      tdst[nt] := 0;
      lfreq[s + 1] := lfreq[s + 1] + 1;
    END IF;

    -- Every position the match covered still has to enter the chain, or the
    -- bytes inside a long match become invisible to everything after it.
    FOR k IN 1 .. mlen LOOP
      q := p + k - 1;
      IF q + 2 <= n THEN
        prev[q] := head[h + 1];
        head[h + 1] := q;
      END IF;
      IF q + 3 <= n THEN h := ((h << 6) # get_byte(raw, q + 2)) & 65535; END IF;
    END LOOP;
    p := p + mlen;
  END LOOP;

  lfreq[257] := 1;                             -- the end-of-block symbol, 256

  ------------------------------------------------------- choose the block --
  litlen  := huff_lengths(lfreq, 15);
  distlen := huff_lengths(dfreq, 15);
  SELECT hdr.bv, hdr.bw INTO hv, hw FROM deflate_dyn_header(litlen, distlen) AS hdr;

  fixlit  := array_fill(8, ARRAY[144]) || array_fill(9, ARRAY[112])
          || array_fill(7, ARRAY[24])  || array_fill(8, ARRAY[8]);
  fixdist := array_fill(5, ARRAY[32]);

  SELECT coalesce(sum(w), 0) INTO dyncost FROM unnest(hw) AS u(w);
  FOR k IN 1 .. 286 LOOP
    dyncost := dyncost + lfreq[k] * litlen[k];
    fixcost := fixcost + lfreq[k] * fixlit[k];
  END LOOP;
  FOR k IN 1 .. 30 LOOP
    dyncost := dyncost + dfreq[k] * distlen[k];
    fixcost := fixcost + dfreq[k] * fixdist[k];
  END LOOP;

  -- The extra bits that follow a length or distance code are the same count
  -- whatever tree is used, so they cancel between fixed and dynamic -- but not
  -- against stored, which has no codes at all.  Leaving them out cost 68 bytes
  -- on 70 kB of random input: the handful of accidental three-byte matches
  -- made the estimate fall by the 13 extra bits it was not counting while the
  -- real output rose, and a block that should have been stored came out
  -- Huffman coded and larger.
  FOR k IN 1 .. 29 LOOP
    extracost := extracost + lfreq[k + 257] * lext[k];
  END LOOP;
  FOR k IN 1 .. 30 LOOP
    extracost := extracost + dfreq[k] * dext[k];
  END LOOP;
  dyncost := dyncost + extracost;
  fixcost := fixcost + extracost;

  -- A stored block cannot be beaten on incompressible input, and saying so in
  -- bits is the only way to know which case we are in.
  storedcost := 8::bigint * (n + 5 * (n / 65535 + 1));
  IF storedcost < least(dyncost, fixcost) + 3 THEN
    RETURN deflate(raw, 0);
  END IF;

  usedyn := dyncost <= fixcost;
  IF NOT usedyn THEN
    litlen  := fixlit;
    distlen := fixdist;
  END IF;
  litcode  := huff_emit_codes(litlen);
  distcode := huff_emit_codes(distlen);

  ------------------------------------------------------------------- emit --
  --
  -- The bit packer is written out inline at every use rather than called,
  -- which is the one place readability is traded away on purpose.  It runs
  -- once per symbol and once per extra-bit field -- tens of millions of times
  -- for a single frame -- and a PL/pgSQL call, at ~120 ns measured, would cost
  -- more than everything else in this loop put together.
  out := array_fill(0, ARRAY[greatest(1024, n / 2)]);

  bitbuf := CASE WHEN usedyn THEN 5 ELSE 3 END;   -- BFINAL=1, BTYPE=10 or 01
  bitcnt := 3;

  IF usedyn THEN
    FOR k IN 1 .. array_length(hv, 1) LOOP
      bitbuf := bitbuf | (hv[k] << bitcnt);
      bitcnt := bitcnt + hw[k];
      WHILE bitcnt >= 8 LOOP
        outn := outn + 1; out[outn] := (bitbuf & 255)::int;
        bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
      END LOOP;
    END LOOP;
  END IF;

  FOR k IN 1 .. nt LOOP
    IF tdst[k] = 0 THEN
      s := tsym[k];
      bitbuf := bitbuf | (litcode[s + 1] << bitcnt);
      bitcnt := bitcnt + litlen[s + 1];
      WHILE bitcnt >= 8 LOOP
        outn := outn + 1; out[outn] := (bitbuf & 255)::int;
        bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
      END LOOP;
    ELSE
      l := tsym[k];
      c := lcodeof[l - 2];
      bitbuf := bitbuf | (litcode[c + 1] << bitcnt);
      bitcnt := bitcnt + litlen[c + 1];
      e := lext[c - 256];
      IF e > 0 THEN
        bitbuf := bitbuf | ((l - lbase[c - 256])::bigint << bitcnt);
        bitcnt := bitcnt + e;
      END IF;
      WHILE bitcnt >= 8 LOOP
        outn := outn + 1; out[outn] := (bitbuf & 255)::int;
        bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
      END LOOP;

      q := tdst[k] - 1;
      c := dcodeof[CASE WHEN q < 256 THEN q ELSE 256 + (q >> 7) END + 1];
      bitbuf := bitbuf | (distcode[c + 1] << bitcnt);
      bitcnt := bitcnt + distlen[c + 1];
      e := dext[c + 1];
      IF e > 0 THEN
        bitbuf := bitbuf | ((tdst[k] - dbase[c + 1])::bigint << bitcnt);
        bitcnt := bitcnt + e;
      END IF;
      WHILE bitcnt >= 8 LOOP
        outn := outn + 1; out[outn] := (bitbuf & 255)::int;
        bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
      END LOOP;
    END IF;
  END LOOP;

  bitbuf := bitbuf | (litcode[257] << bitcnt);   -- end of block
  bitcnt := bitcnt + litlen[257];
  WHILE bitcnt > 0 LOOP
    outn := outn + 1; out[outn] := (bitbuf & 255)::int;
    bitbuf := bitbuf >> 8; bitcnt := bitcnt - 8;
  END LOOP;

  RETURN bytes_of(out, outn);
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- inflate: the same stream, read back.
--
-- Decoding is table-driven where encoding needs a search, so this is the
-- easier direction -- but it is also the strictly sequential one, and not by
-- accident.  A back-reference points into the output *being produced*, so
-- position i can depend on position i-1, and no amount of restructuring makes
-- that a set operation.  It is a loop, and it is meant to be: this runs once
-- per image loaded, not once per ray.
--
-- The symbol decoder is written out three times rather than factored into a
-- function for the reason given at the emitter: it runs per symbol, and a
-- PL/pgSQL call per symbol would dominate the cost of the thing it is helping.
-- ---------------------------------------------------------------------------
CREATE FUNCTION inflate(comp bytea) RETURNS bytea AS $$
DECLARE
  n    int := length(comp);
  bp   int := 0;              -- next unread byte
  bbuf bigint := 0;           -- bits pulled but not consumed, LSB first
  bcnt int := 0;

  out  int[] := '{}';
  op   int := 0;

  lbase int[]; lext int[]; dbase int[]; dext int[];
  fixlit int[]; fixdist int[];

  lcnt int[]; lsym int[]; dcnt int[]; dsym int[];
  ccnt int[]; csym int[];

  bfinal int; btype int;
  hlit int; hdist int; hclen int;
  perm int[] := ARRAY[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
  cl int[]; alllen int[];
  hcode int; first int; idx int; ln int; cnt int; sym int;
  i int; k int; r int; v int; d int; len int; dist int; src int;
BEGIN
  comp := detoast(comp);
  SELECT array_agg(base ORDER BY code), array_agg(extra ORDER BY code)
    INTO lbase, lext FROM deflate_len;
  SELECT array_agg(base ORDER BY code), array_agg(extra ORDER BY code)
    INTO dbase, dext FROM deflate_dist;

  LOOP
    WHILE bcnt < 3 LOOP
      bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
    END LOOP;
    bfinal := (bbuf & 1)::int; bbuf := bbuf >> 1; bcnt := bcnt - 1;
    btype  := (bbuf & 3)::int; bbuf := bbuf >> 2; bcnt := bcnt - 2;

    IF btype = 0 THEN
      -- A stored block restarts on a byte boundary, so whatever is left in the
      -- bit buffer is padding and goes on the floor.
      bp   := bp - (bcnt >> 3);
      bbuf := 0; bcnt := 0;
      len  := get_byte(comp, bp) + get_byte(comp, bp + 1) * 256;
      IF (get_byte(comp, bp + 2) + get_byte(comp, bp + 3) * 256) <> (~len & 65535) THEN
        RAISE EXCEPTION 'stored block LEN/NLEN mismatch';
      END IF;
      bp := bp + 4;
      FOR k IN 1 .. len LOOP
        op := op + 1; out[op] := get_byte(comp, bp); bp := bp + 1;
      END LOOP;

    ELSIF btype = 3 THEN
      RAISE EXCEPTION 'reserved DEFLATE block type';

    ELSE
      IF btype = 1 THEN
        fixlit  := array_fill(8, ARRAY[144]) || array_fill(9, ARRAY[112])
                || array_fill(7, ARRAY[24])  || array_fill(8, ARRAY[8]);
        fixdist := array_fill(5, ARRAY[32]);
        SELECT t.cnt, t.sym INTO lcnt, lsym FROM huff_decode_table(fixlit) AS t;
        SELECT t.cnt, t.sym INTO dcnt, dsym FROM huff_decode_table(fixdist) AS t;
      ELSE
        WHILE bcnt < 14 LOOP
          bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
        END LOOP;
        hlit  := (bbuf & 31)::int + 257; bbuf := bbuf >> 5; bcnt := bcnt - 5;
        hdist := (bbuf & 31)::int + 1;   bbuf := bbuf >> 5; bcnt := bcnt - 5;
        hclen := (bbuf & 15)::int + 4;   bbuf := bbuf >> 4; bcnt := bcnt - 4;

        cl := array_fill(0, ARRAY[19]);
        FOR k IN 1 .. hclen LOOP
          WHILE bcnt < 3 LOOP
            bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
          END LOOP;
          cl[perm[k] + 1] := (bbuf & 7)::int; bbuf := bbuf >> 3; bcnt := bcnt - 3;
        END LOOP;
        SELECT t.cnt, t.sym INTO ccnt, csym FROM huff_decode_table(cl) AS t;

        alllen := array_fill(0, ARRAY[hlit + hdist]);
        i := 1;
        WHILE i <= hlit + hdist LOOP
          hcode := 0; first := 0; idx := 0; ln := 1;
          LOOP
            IF bcnt = 0 THEN
              bbuf := get_byte(comp, bp); bp := bp + 1; bcnt := 8;
            END IF;
            hcode := hcode | (bbuf & 1)::int; bbuf := bbuf >> 1; bcnt := bcnt - 1;
            cnt := ccnt[ln];
            EXIT WHEN hcode - first < cnt;
            idx := idx + cnt; first := (first + cnt) << 1; hcode := hcode << 1; ln := ln + 1;
            IF ln > 15 THEN RAISE EXCEPTION 'bad code-length code'; END IF;
          END LOOP;
          sym := csym[idx + hcode - first + 1];

          IF sym < 16 THEN
            alllen[i] := sym; i := i + 1;
          ELSE
            IF sym = 16 THEN
              WHILE bcnt < 2 LOOP
                bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
              END LOOP;
              r := (bbuf & 3)::int + 3; bbuf := bbuf >> 2; bcnt := bcnt - 2;
              v := alllen[i - 1];
            ELSIF sym = 17 THEN
              WHILE bcnt < 3 LOOP
                bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
              END LOOP;
              r := (bbuf & 7)::int + 3; bbuf := bbuf >> 3; bcnt := bcnt - 3;
              v := 0;
            ELSE
              WHILE bcnt < 7 LOOP
                bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
              END LOOP;
              r := (bbuf & 127)::int + 11; bbuf := bbuf >> 7; bcnt := bcnt - 7;
              v := 0;
            END IF;
            FOR k IN 1 .. r LOOP alllen[i] := v; i := i + 1; END LOOP;
          END IF;
        END LOOP;

        SELECT t.cnt, t.sym INTO lcnt, lsym
          FROM huff_decode_table(alllen[1:hlit]) AS t;
        SELECT t.cnt, t.sym INTO dcnt, dsym
          FROM huff_decode_table(alllen[hlit + 1 : hlit + hdist]) AS t;
      END IF;

      LOOP
        hcode := 0; first := 0; idx := 0; ln := 1;
        LOOP
          IF bcnt = 0 THEN
            bbuf := get_byte(comp, bp); bp := bp + 1; bcnt := 8;
          END IF;
          hcode := hcode | (bbuf & 1)::int; bbuf := bbuf >> 1; bcnt := bcnt - 1;
          cnt := lcnt[ln];
          EXIT WHEN hcode - first < cnt;
          idx := idx + cnt; first := (first + cnt) << 1; hcode := hcode << 1; ln := ln + 1;
          IF ln > 15 THEN RAISE EXCEPTION 'bad literal/length code'; END IF;
        END LOOP;
        sym := lsym[idx + hcode - first + 1];

        EXIT WHEN sym = 256;

        IF sym < 256 THEN
          op := op + 1; out[op] := sym;
        ELSE
          IF sym > 285 THEN RAISE EXCEPTION 'length code % out of range', sym; END IF;
          d := lext[sym - 256];
          len := lbase[sym - 256];
          IF d > 0 THEN
            WHILE bcnt < d LOOP
              bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
            END LOOP;
            len := len + (bbuf & ((1::bigint << d) - 1))::int;
            bbuf := bbuf >> d; bcnt := bcnt - d;
          END IF;

          hcode := 0; first := 0; idx := 0; ln := 1;
          LOOP
            IF bcnt = 0 THEN
              bbuf := get_byte(comp, bp); bp := bp + 1; bcnt := 8;
            END IF;
            hcode := hcode | (bbuf & 1)::int; bbuf := bbuf >> 1; bcnt := bcnt - 1;
            cnt := dcnt[ln];
            EXIT WHEN hcode - first < cnt;
            idx := idx + cnt; first := (first + cnt) << 1; hcode := hcode << 1; ln := ln + 1;
            IF ln > 15 THEN RAISE EXCEPTION 'bad distance code'; END IF;
          END LOOP;
          sym := dsym[idx + hcode - first + 1];

          d := dext[sym + 1];
          dist := dbase[sym + 1];
          IF d > 0 THEN
            WHILE bcnt < d LOOP
              bbuf := bbuf | (get_byte(comp, bp)::bigint << bcnt); bp := bp + 1; bcnt := bcnt + 8;
            END LOOP;
            dist := dist + (bbuf & ((1::bigint << d) - 1))::int;
            bbuf := bbuf >> d; bcnt := bcnt - d;
          END IF;

          IF dist > op THEN RAISE EXCEPTION 'distance % before start of output', dist; END IF;

          -- Copying one byte at a time is required, not lazy: an overlapping
          -- copy is how DEFLATE spells a run, and dist = 1 with len = 200
          -- means "repeat that byte 200 times".
          src := op - dist + 1;
          FOR k IN 1 .. len LOOP
            op := op + 1; out[op] := out[src]; src := src + 1;
          END LOOP;
        END IF;
      END LOOP;
    END IF;

    EXIT WHEN bfinal = 1;
  END LOOP;

  RETURN bytes_of(out, op);
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;

-- zlib framing (RFC 1950) -----------------------------------------------------
--
-- Two header bytes and an Adler-32 trailer around a DEFLATE stream.  CMF 0x78
-- is "deflate, 32K window"; the FLG byte carries an advisory compression level
-- and a check value chosen so the pair is a multiple of 31.

CREATE FUNCTION zlib_deflate(raw bytea, level int DEFAULT 6) RETURNS bytea
  AS $$ SELECT '\x7801'::bytea || deflate(raw, level) || be32(adler32(raw)) $$
  LANGUAGE sql STABLE PARALLEL SAFE;

-- Uncompressed, as a named thing rather than a magic argument: a stored block
-- is a legal DEFLATE block, so this is still a stream any decoder reads.
CREATE FUNCTION zlib_stored(raw bytea) RETURNS bytea
  AS $$ SELECT zlib_deflate(raw, 0) $$
  LANGUAGE sql STABLE PARALLEL SAFE;

CREATE FUNCTION zlib_inflate(z bytea) RETURNS bytea AS $$
DECLARE raw bytea;
BEGIN
  z := detoast(z);
  IF length(z) < 6 THEN
    RAISE EXCEPTION 'zlib stream too short';
  END IF;
  IF (get_byte(z, 0) & 15) <> 8 THEN
    RAISE EXCEPTION 'not a deflate stream (CM = %)', get_byte(z, 0) & 15;
  END IF;
  IF (get_byte(z, 0) * 256 + get_byte(z, 1)) % 31 <> 0 THEN
    RAISE EXCEPTION 'zlib header check failed';
  END IF;
  IF (get_byte(z, 1) & 32) <> 0 THEN
    RAISE EXCEPTION 'preset dictionaries are not supported';
  END IF;

  raw := inflate(substring(z FROM 3 FOR length(z) - 6));

  -- The trailer is the only end-to-end check there is, and it is worth taking:
  -- a Huffman stream decodes into *something* for almost any corruption.
  --
  -- Every parenthesis below is load-bearing.  `<<` and `|` are not built-in
  -- operators with C's precedence -- PostgreSQL puts every operator it does
  -- not know at one level and associates left -- so the unbracketed spelling
  -- of this expression means (((a << 24) | b) << 16) | ... and quietly
  -- returns a different number.
  IF adler32(raw) <> ((get_byte(z, length(z) - 4)::bigint << 24)
                    | (get_byte(z, length(z) - 3)::bigint << 16)
                    | (get_byte(z, length(z) - 2)::bigint << 8)
                    |  get_byte(z, length(z) - 1)::bigint) THEN
    RAISE EXCEPTION 'Adler-32 mismatch: the stream decoded, but not to what was compressed';
  END IF;
  RETURN raw;
END $$ LANGUAGE plpgsql STABLE PARALLEL SAFE;
