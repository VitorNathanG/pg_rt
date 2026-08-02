# 256 colours, and the two ways of choosing them that were wrong

GIF cannot store a truecolour pixel, so before anything is compressed the image
has to be thrown away and rebuilt out of a palette. That is the whole of the
work; LZW at the end is the smaller half and the part with no decisions in it.

Both halves of the palette problem — *which* 256 colours, and *which one* each
pixel becomes — were first solved with the obvious set-based construction, and
both were measurably wrong in the same way: **invisibly**. A palette that wastes
a fifth of itself and a lookup that picks the wrong entry half the time both
produce a picture that looks entirely plausible next to the one it should have
been.

Timings are on the default 1118-triangle scene at 480×320, depth 5, one session.

## What it costs against PNG

| | bytes | encode |
|---|---|---|
| PNG | 80 287 | 2 761 ms |
| GIF, 256 colours | **41 363** | **1 687 ms** |

Half the size and two thirds of the time, which is not the trade anyone expects
from the older format. Both halves have the same cause: a GIF pixel is one byte
where a PNG pixel is three. LZW is a weaker compressor than DEFLATE and it is
being handed a third as much input, and it wins on both counts.

Where the time goes:

| stage | time | out |
|---|---|---|
| histogram | 52 ms | 15 480 distinct colours |
| median cut | 393 ms | 256 entries |
| index every pixel | 1 104 ms | 153 600 bytes |
| LZW | 71 ms | 40 402 bytes |
| container | 66 ms | 41 363 bytes |

**The quantiser is the expensive part and the compressor is not**, which is the
reverse of PNG, where DEFLATE is essentially the whole bill.

What 256 colours costs the picture: 40.5% of pixels come back exactly right,
the mean error is **1.33 of 255 levels** on the worst channel, and the worst
single pixel is 51 out. That worst figure is a specular highlight — the one
place a palette fitted by population has nothing to spend.

## Median cut wasted a fifth of the palette, silently

The textbook loop splits one box per iteration, choosing the worst by some
measure — 255 iterations, each a scan of the whole colour set. Splitting *every*
box each round instead makes a round one query and doubles the count, so eight
rounds land on 256.

They land on **207**.

A box holding a single distinct colour cannot be split, whatever its
population. This renderer produces several such colours: one sky tone alone wore
6% of a 240×160 frame. A colour that large is isolated into its own box within
three or four rounds, and every round after that fails to split it and throws
away the entries its subtree would have held. Measured: 25 single-colour boxes,
34.7% of the pixels, **49 palette entries spent on nothing**.

The fix keeps the round structure and adds a budget. Each round splits the boxes
that *can* be split, ranked, taking as many as there is room for — the greedy
algorithm's choice made a whole round at a time rather than one box at a time.
Still one query per round, nine rounds instead of eight, and the last one is a
partial round that fills the palette exactly.

Ranking matters and the classical rank is the wrong one here. "Median cut" means
choosing by population, which keeps selecting the box around a dominant flat
colour — the box least able to benefit, because its colours are all the same.
Population × longest extent asks how many pixels are wrong *and by how much*.

## The lookup cube was 49% wrong

Dithering moves a pixel off its own colour, so the nearest palette entry cannot
be read out of the histogram — the perturbed colour is one nobody rendered.
Asking per pixel is a cross join of the frame against the palette: 39 million
distance tests for a 480×320 frame, every frame.

So: coarsen the colour cube to 5 bits a channel and answer it exhaustively.
32 768 cells against 256 entries is 8.4 million tests, paid once for a whole
animation, and a pixel afterwards is a hash probe. The reasoning was that a
5-bit cell is 8 levels wide against a palette whose entries sit tens of levels
apart, so the rounding disappears under the thing it is serving.

**That last clause is false, and it is false in a way that is specific to
rendering.** A palette is fitted to the gamut of *this picture*, and a render's
gamut is a sliver of the colour space rather than the whole of it. 256 entries
over the default scene sit a mean of **3.9 apart**, minimum 1.0. The cube was
quantising an order of magnitude *below* the palette's own resolution:

| | |
|---|---|
| distinct colours in the frame | 15 480 |
| distinct cells they fall into | **1 034** |
| colours the cube sends to the wrong entry | **7 583 (49%)** |
| mean distance from the entry it should have picked | 3.3 |

3.3 against a spacing of 3.9 — the error introduced was most of the spacing it
existed to resolve. It also swallowed the dither whole: at that spacing the
perturbation is about one level, which rarely crosses a cell boundary, so asking
for half-strength dithering and asking for none produced **byte-identical
files**. That was the symptom that led here, and it is the only one there was.

What replaced it is both exact and cheaper, and the reason is the same fact from
the other side: a render has far fewer distinct colours than the cube has cells.
The exact search over the colours that actually occur — 15 480 against 256 — is
**743 ms**, against 8.4 million cells for a worse answer. Results are kept in a
table keyed on colour, so a second frame pays only for colours the first did not
have, which is what makes it affordable over a sequence.

Per-pixel error, same frame, same palette, no dither:

| lookup | mean error |
|---|---|
| 5-bit cube | 3.24 |
| exact, cached | **1.33** |

## Dithering is off by default

Everything about the ordered dither matrix is true and it earns nothing at 256
colours here. At 240×160, against the unquantised frame:

| colours | spacing | dither | per-pixel err | err of 4×4 means | bytes |
|---|---|---|---|---|---|
| 16 | 7.03 | off | 5.85 | 4.44 | 5 302 |
| 16 | | on | 6.54 | **4.16** | 8 295 |
| 64 | 3.50 | off | 2.58 | 1.64 | 10 195 |
| 64 | | on | 2.98 | **1.60** | 14 221 |
| 256 | 1.97 | off | 1.31 | **0.68** | 16 145 |
| 256 | | on | 1.60 | 0.69 | 18 835 |

Per-pixel error rises with dithering by construction — that is what dithering
is — so the column that decides it is the second, the error left after a 4×4
average, which is a crude stand-in for an eye. At 256 colours even that goes the
wrong way, and the file grows 17%.

**The palette is finer than the picture.** 256 entries over this gamut sit two
levels apart, and the image being quantised is already 8-bit. The sky is the
clearest case: it is a smooth gradient that the tone curve had already flattened
into **12 distinct colours in vertical runs 7 pixels tall**, and the 256-colour
GIF reproduces those 12 colours and those runs exactly. There is no banding to
break up, so dithering can only add noise that was never in the picture.

Below 64 colours that reverses, and far more sharply than the table shows — the
numbers barely separate the 16-colour pair while the images are not close at
all, hard posterised contours against smooth gradients. Which is a caution about
the metric rather than about the dither: **a 4×4 mean is blind to whether error
is spread out or organised into a contour**, and a contour is the thing the eye
finds. Any measurement of quantisation that averages over a neighbourhood has
this hole in it.

So the parameter stays and the default is off. It is the right tool for a
squeezed palette and dead weight on a full one.

## An animation is one palette, and that is what costs the second pass

Twenty-four frames at 640×400, the camera orbiting the default scene:

| | |
|---|---|
| 24 PNGs in `frame` | 2 488 412 bytes |
| one animated GIF | **1 193 494 bytes** |
| assembly | 38.4 s |

Assembly splits three ways: **15.9 s decoding** the stored PNGs back to pixels,
**1.7 s** choosing 256 colours out of the 125 814 the whole sequence contains,
and **20.8 s** indexing 24 frames against them.

The palette stage is the one that does not grow. It was 1.7 s over 51 442
colours at 320×200 and it is 1.7 s over 125 814 here, because median cut's cost
is set by the number of *distinct colours* and by the nine rounds it takes to
reach 256 — neither of which is the pixel count. Decoding and indexing are both
per pixel and both went up roughly fourfold, as they should.

The decode is the bill for `frame` storing the PNG rather than the pixels, and
it is the right side of that trade by a wide margin — seconds a frame against
minutes a frame to render, and the alternative is a sequence nobody has room
for. It is also why the raw bytes rather than the pixels are what is kept
between the two passes: same information, 460 kB a frame instead of 150 000
rows.

Two passes, because the palette has to be chosen over the whole animation before
any frame can be indexed against it. Quantising each frame on its own is cheaper
and looks worse in a way specific to animation: the palette shifts with the
content, so flat areas change colour slightly from frame to frame and the whole
image crawls. One palette holds still.

That is also the argument that settles ordered dithering over Floyd–Steinberg,
independently of how either looks on a still. Error diffusion is sequential —
each pixel's error moves to neighbours not yet quantised — so it is not
available here at any price worth paying, and an ordered matrix depends only on
(x, y), which means it is identical frame to frame and cannot boil.

## The one thing in LZW that has to be exactly right

When the code width grows. Encoder and decoder never hold the same dictionary at
the same moment — the decoder learns each entry one code *later* than the
encoder invents it — so they cannot share a rule, and a rule that is off by one
produces a file that decodes into plausible rubbish rather than failing.

The encoder widens once the next code it would assign no longer fits,
`next > 1 << bits`, *after* assigning. A decoder widens when its own next code
reaches `1 << bits`, *before* reading. Those are the same instant, because the
decoder's counter runs exactly one behind.

They also have to agree at the very first code, where the counters are
momentarily equal rather than one apart, and they do — but only because
`clear + 2 < 2 * clear`. That inequality is why the format forbids a minimum
code size below 2 even for a two-colour image, which otherwise reads as an
arbitrary rule.

The dictionary is direct-indexed rather than hashed: the key is
`(prefix, byte)`, at most 4096 × 256, so a lookup is one array read. The price
is a million-element array to clear each time the dictionary fills, which is why
entries carry a generation number instead — bumping it invalidates all of them
at once and the array is allocated once.

`gif_unlzw` exists for the reason `inflate` does. A round trip over input long
enough to fill and reset the dictionary is what catches width-growth mistakes; a
single known vector walks straight past them. The suite carries both — the
round trip, and one vector derived by hand from the format rather than from this
encoder, because two halves with the same author will agree on the same mistake.
