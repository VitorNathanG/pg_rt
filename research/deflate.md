# Writing a compressor in PL/pgSQL

DEFLATE is a byte-at-a-time algorithm and PL/pgSQL is a slow interpreter, so
this had one interesting question — where do the bytes live — and a handful of
small ones about ratio. The small ones are here too, because two of them were
wrong for a while and neither announced itself.

## The accumulator decides everything

Every measurement below is on this machine, back-to-back; only the ratios
travel.

| what | how many | time |
|---|---|---|
| `get_byte` over a `bytea`, in a loop | 200 000 | 38 ms |
| `a[k] := v` on an `int[]` local | 200 000 | 14 ms |
| appending one past the end of an `int[]` | 500 000 | 34 ms |
| `b := set_byte(b, k, v)` on a `bytea` local | 100 000 | **397 ms** |
| a PL/pgSQL function call | 200 000 | 24 ms |
| `int[]` → `bytea` via `string_agg`/`decode` | 1 000 000 | 136 ms |

`set_byte` is the obvious way to fill a byte buffer and it is quadratic:
`bytea` is a flat value, so each call copies the whole thing. Six thousand
times slower per byte than the array, on a buffer of only 100 kB — and the
gap widens with the buffer, which is exactly backwards from what an image
encoder needs.

An `int[]` local is fast because PL/pgSQL keeps arrays as **expanded** datums:
a subscripted assignment mutates in place when the variable holds the only
reference, and growing past the end reallocates geometrically rather than per
element. So every buffer in `02_deflate.sql` is an `int[]` of byte values, and
`bytes_of()` converts it to `bytea` exactly once at the end. That conversion is
the one place a set-based expression beats a loop, and it is cheap.

The function-call number is why the bit packer is written out inline at each of
its uses instead of being a function. 120 ns is nothing until it happens once
per symbol and once per extra-bit field — tens of millions of times for one
frame — at which point it costs more than the loop it would be tidying.

The same number is why `inflate` spells its symbol decoder out three times. A
helper with `INOUT` bit-reader state would not be a function call at all but an
SPI round trip per symbol decoded, which is a different order of magnitude
again.

## The argument is a pointer, and `get_byte` follows it every time

This is the sharper half of the same problem, and it cost more than everything
else here put together.

A `bytea` large enough to matter is stored out of line, and what a function
receives is a pointer to it. `get_byte` resolves that pointer on every call —
fetching and reassembling the whole value — so a loop over a megabyte fetches a
megabyte a million times. It is silently quadratic and it is *correct*, which is
why it survives testing: the answers are right, they just never arrive.

Measured on 1 MB, the same bytes either way:

| | time |
|---|---|
| built inline, never stored | 150 ms |
| read from a table column | **110 818 ms** |

**741×**, and the ratio grows with the buffer. At 256 kB `crc32` was 173× and
`adler32` 241×; `crc32` has been in this repository since long before there was
a compressor, so this was latent rather than new.

Assigning to a local does **not** fix it — PL/pgSQL copies the pointer, not the
bytes. It takes an operation that constructs a new value:

| | 1 MB |
|---|---|
| `c := b` | 87 353 ms |
| `c := b \|\| ''::bytea` | 62 ms |
| `c := substring(b FROM 1)` | 62 ms |

So there is a `detoast()` and every function that reads a `bytea` argument more
than a few times calls it first.

### The set-based one needed a fence, and the obvious fence was the wrong one

`adler32` is the exception in the file: it reads its bytes with an aggregate
rather than a loop, so there is no local to assign to. The natural spelling —

```sql
FROM (SELECT detoast(b)) AS d(raw), ...
```

— is *slower than no fix at all*. The planner pulls a one-row subquery up into
its parent and substitutes the expression at every reference, so one detoast
becomes one per byte, each of them copying a megabyte.

`OFFSET 0` does not save it either. That blocks pull-up, not re-execution — the
same distinction this engine learned the hard way when a fenced `LATERAL`
landed under a join and ran once per row of it. Only `WITH ... AS MATERIALIZED`
governs *how many times* something is evaluated, and that is what `adler32`
uses.

The test for all of this is a `statement_timeout`, because correctness cannot
tell the two apart: 1.6 s against roughly two minutes on 512 kB, both returning
the same number.

## `<<` and `|` do not have C's precedence

This assembles a 32-bit big-endian field, and it is wrong:

```sql
get_byte(z, n - 4)::bigint << 24
| get_byte(z, n - 3)::bigint << 16
| get_byte(z, n - 2)::bigint << 8
| get_byte(z, n - 1)::bigint
```

PostgreSQL gives every operator it does not know a single precedence and
associates left, so that parses as `(((a << 24) | b) << 16) | c) << 8) | d`.
It returns a number, it returns it silently, and the only symptom was the
Adler-32 check failing on streams that had decoded perfectly.

## The block chooser has to cost the whole block

Each block is costed three ways before anything is emitted — stored, fixed
Huffman, dynamic Huffman — and the cheapest wins. The cost of a Huffman block
is the header plus `Σ freq × code length` plus the **extra bits** that follow
each length and distance code.

Those extra bits were left out at first, on the reasoning that they are the
same count whichever tree is used and therefore cancel. They do cancel between
fixed and dynamic. They do not cancel against stored, which has no codes at
all — and stored is the candidate that wins precisely when the others are
marginal.

Measured on 70 kB of md5 output: the file came back **70 078 bytes** where a
stored block would have been 70 010. Random data throws up a handful of
accidental three-byte matches, and each one made the estimate fall by the 13
extra distance bits it was not counting while the real output rose. A block
that should have been stored was Huffman coded and came out larger than its
input, which is the one thing the chooser exists to prevent.

It is now a test: incompressible input must never exceed `n + 5 × blocks`.

## Length-limiting by halving overshoots, and it does not matter

DEFLATE caps a code at 15 bits. A natural Huffman tree goes deeper as soon as
the frequencies are Fibonacci-shaped, which a few thousand symbols reach in
practice. The repair here is the crude one — halve every weight and rebuild —
rather than an algorithm that redistributes exactly.

On 20 symbols with Fibonacci weights it turns a 19-deep tree into a **10**-deep
one, far below the 15 it had to reach. The cost of that overshoot:

| | total bits |
|---|---|
| unconstrained optimum (19 bits deep) | 46 344 |
| halved to ≤ 15 (10 bits deep) | 46 353 |

**0.02%.** The codes that were too long belong to the symbols that hardly
occur — that is *why* the tree was deep — so shortening them costs almost
nothing. It also terminates for a reason worth stating: once every weight is 1
the tree is balanced, and 286 symbols fit in 9 bits.

A side effect is that the 15 in `huff_lengths(freq, 15)` cannot be tested by
changing it to 16. The overshoot jumps clean past 16, so no input distinguishes
them.

## Filters are not compression, and that is why they were pointless before

Each PNG filter replaces a byte with its difference from a prediction made out
of neighbours the decoder already has. Every one is reversible and none makes
the data smaller. What they do is change its *shape*: a smooth gradient stops
being 200 distinct byte values and becomes a heap of zeroes and ones, which is
something a Huffman tree can exploit and a stored block cannot. Filtering was
correctly absent while the blocks were stored — it would have cost a pass and
saved nothing.

The encoding side is a set operation and the decoding side cannot be. Every
byte's five candidates depend only on the *original* image, so all of them are
computed in one pass over `img` with window functions reaching left and up. A
decoder has to reconstruct byte *i* before it can predict byte *i+1*, so
`png_unfilter` is a loop.

## The standard filter heuristic is wrong here, at every size

Every PNG encoder chooses a filter per scanline by the same rule: take the one
whose output has the smallest sum of absolute values read as signed bytes.
Measured against actually compressing each option, on the default scene:

| pixels | per-row | None | Sub | Up | Average | Paeth |
|---|---|---|---|---|---|---|
| 240×160 | 26 421 | 30 863 | **25 064** | 29 958 | 31 099 | 27 485 |
| 480×320 | 87 859 | 94 700 | **81 685** | 99 439 | 97 069 | 89 453 |
| 960×540 | 175 684 | 167 680 | **165 546** | 197 970 | 207 680 | 186 273 |
| 1920×1080 | 492 812 | **428 710** | 465 980 | 544 180 | 590 770 | 515 987 |

The per-row heuristic is beaten by a fixed filter at all four, by 5–13%.

Two things are wrong with it. The first is that it measures residual
*magnitude* while DEFLATE pays for *repetition*, and it ranks accordingly
badly — its own ordering against reality at 480×320:

| filter | heuristic cost | rank | actual bytes |
|---|---|---|---|
| Paeth | 749 907 | 1st | 89 453 |
| Sub | 829 079 | 2nd | **81 685** |
| Average | 1 436 584 | 3rd | 97 069 |
| Up | 2 042 283 | 4th | 99 439 |
| None | 36 834 288 | last, by 44× | 94 700 |

It puts Paeth first and None dead last; Sub is smallest and None beats three of
the five. Sub wins because a horizontal run of identical pixels becomes a run
of exact zeroes, which LZ77 collapses; Paeth wins the *magnitude* contest with
residuals that are small but all different, which is the one thing that does
not help.

The second is specific to this encoder and would not apply to zlib: **one block,
one Huffman tree, over the whole image.** Every row given a different filter
widens the same symbol distribution, so per-row optimality is bought with a
cost that lands somewhere else entirely. A streaming encoder that rebuilds its
tree periodically does not pay that.

### So the default measures

No fixed filter wins either — Sub below about a megapixel, None above it, and
the crossover is a property of the content rather than of the size. So the
default compresses both and keeps the smaller, which is what the block chooser
in the same codec already does. Nothing else is a candidate: Up, Average and
Paeth lost all four.

The probe runs at level 1, not at the level the caller asked for, and it is
allowed to be wrong. At 960×540 it picks None where level 6 would have picked
Sub — and that costs **1.3%**, because near the crossover the two are nearly
the same size. Where the gap is worth having, the probe is never in doubt.
Being approximately right is cheap; being exactly right would cost two more
full compressions.

Result at 480×320: **461 223 bytes stored → 81 748**, 5.64×, and 7.0% better
than the heuristic every other encoder uses. The whole encode is about 1.5 s
against roughly 150 s to trace the frame.

At 1920×1080 the probe picks None, which is the answer the table above says it
should: **6 222 418 → 428 773**, 14.5×. Encoding costs 14 s there against 193 s
to trace, and about 4 s of that is the probe — paid to save 8%, which is the
difference between None and Sub at that size.

### The disk saving is much smaller than the byte saving, and that is not a disappointment

`frame.png` is a `bytea` column, so PostgreSQL was already compressing it:

| full HD frame | length | `pg_column_size` |
|---|---|---|
| stored DEFLATE blocks | 6 222 418 | 957 543 |
| really compressed | 428 773 | 428 773 |

TOAST ran pglz over the old PNGs and got 6.5× out of them, because a stored
DEFLATE block is just the pixels with a header every 65535 bytes. So on disk
the change is 2.23×, not 14.5×. The 14.5× is what leaves the database — the
`bytea` a client receives, the file written out, the frame sent anywhere — and
that was always the number that mattered. It is worth knowing which one is
which before quoting either.

The per-row heuristic is still there, as filter `-2`, because it is what the
format is designed around and because the measurement above is a statement
about *this renderer's images* rather than about PNG.

## What the levels buy

`level` sets how far down a hash chain the match finder walks and the match
length at which it stops looking, and nothing else; every level emits a stream
any decoder reads. On a 480×320 frame of the default scene:

| level | bytes | time |
|---|---|---|
| stored | 461 160 | 0.07 s |
| 1 | 96 527 | 0.24 s |
| 6 | 87 859 | 0.68 s |
| 9 | 85 288 | 2.52 s |

Level 9 buys 2.9% for 3.7× the time. Level 6 is the default.

Those are compression alone, on already-filtered scanlines; what a whole frame
costs is in the filter section above.

## Against zlib

Sixteen buffers chosen for the branches they reach, compressed here and by
zlib at level 6, both as raw DEFLATE:

| | bytes | ours | zlib |
|---|---|---|---|
| 1000 × `a` | 1 000 | **10** | 11 |
| prose × 50 | 2 250 | **65** | 66 |
| 5000 zero bytes | 5 000 | **21** | 22 |
| md5 output | 3 000 | 3 005 | 3 005 |
| md5 output | 70 000 | **70 010** | 70 025 |
| skewed alphabet | 20 000 | 5 117 | **4 991** |
| quadratic gradient | 40 000 | **1 126** | 1 128 |
| Fibonacci-shaped | 256 240 | **581** | 588 |

Within a couple of percent throughout, slightly under on most. The wins are not
a better matcher — zlib's is far better — but the block chooser: it costs all
three candidates exactly, over the whole input, where a streaming encoder has
to commit to a block before it has seen the end of it. The one clear loss, the
skewed alphabet at 2.5%, is the other side of the same coin: one tree for the
whole stream cannot adapt where zlib's periodic flushes can.

Every one of these round-trips through zlib's inflate, and every zlib stream
round-trips through ours. That matters more than the sizes. A compressor and a
decompressor written by the same author agree happily on a mirrored bit order
or a mis-numbered code table, and the only way to find out is to hand the bytes
to something that has never heard of this repository.

## Inflate is a loop and always will be

A back-reference points into the output *being produced*: `dist = 1, len = 200`
means "repeat that byte 200 times", so position *i* can depend on position
*i−1*. No restructuring makes that a set operation, and the recursive-CTE
sketch that suggested itself early cannot express it — a recursive term cannot
index arbitrary earlier rows of its own output.

That is fine, and it is worth being clear about why rather than apologising for
it. Inflate runs once per image *loaded*, not once per ray. Nothing in the
renderer calls it. It exists so that a PNG can come *in* — which is what a
texture would need — and, immediately and less speculatively, so that the test
suite can ask whether a PNG is correct instead of only how long it is.

The one piece of it that *is* a table is the one the shape suggests: a
canonical Huffman decoder needs the symbols in canonical order and a count per
code length, and both fall straight out of an `ORDER BY`. Building the table is
four lines of SQL. Using it is a loop, because a join per symbol decoded would
be an SPI round trip per symbol.
