-- ---------------------------------------------------------------------------
-- vec3: 3D vector algebra as a first-class PostgreSQL type.
--
-- Everything downstream (camera, intersections, shading) is written against
-- these operators, so the raytracer body reads like vector math rather than
-- like column arithmetic.
-- ---------------------------------------------------------------------------

CREATE TYPE vec3 AS (x float8, y float8, z float8);

CREATE FUNCTION v3(x float8, y float8, z float8) RETURNS vec3
  AS $$ SELECT ROW(x, y, z)::vec3 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Addition / subtraction ----------------------------------------------------

CREATE FUNCTION v3_add(a vec3, b vec3) RETURNS vec3
  AS $$ SELECT ROW(a.x + b.x, a.y + b.y, a.z + b.z)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION v3_sub(a vec3, b vec3) RETURNS vec3
  AS $$ SELECT ROW(a.x - b.x, a.y - b.y, a.z - b.z)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION v3_neg(a vec3) RETURNS vec3
  AS $$ SELECT ROW(-a.x, -a.y, -a.z)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR + (LEFTARG = vec3, RIGHTARG = vec3, FUNCTION = v3_add,
                   COMMUTATOR = +);
CREATE OPERATOR - (LEFTARG = vec3, RIGHTARG = vec3, FUNCTION = v3_sub);
CREATE OPERATOR - (RIGHTARG = vec3, FUNCTION = v3_neg);

-- Scaling and componentwise (Hadamard) product ------------------------------
--
-- The Hadamard product is how colour attenuation works: a red-tinted mirror
-- multiplies an incoming RGB triple channel by channel.

CREATE FUNCTION v3_scale(a vec3, s float8) RETURNS vec3
  AS $$ SELECT ROW(a.x * s, a.y * s, a.z * s)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION v3_scale(s float8, a vec3) RETURNS vec3
  AS $$ SELECT ROW(a.x * s, a.y * s, a.z * s)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION v3_mul(a vec3, b vec3) RETURNS vec3
  AS $$ SELECT ROW(a.x * b.x, a.y * b.y, a.z * b.z)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR * (LEFTARG = vec3, RIGHTARG = float8, FUNCTION = v3_scale);
CREATE OPERATOR * (LEFTARG = float8, RIGHTARG = vec3, FUNCTION = v3_scale);
CREATE OPERATOR * (LEFTARG = vec3, RIGHTARG = vec3, FUNCTION = v3_mul,
                   COMMUTATOR = *);

-- Products, length, normalisation -------------------------------------------

CREATE FUNCTION v3_dot(a vec3, b vec3) RETURNS float8
  AS $$ SELECT a.x * b.x + a.y * b.y + a.z * b.z $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION v3_cross(a vec3, b vec3) RETURNS vec3
  AS $$ SELECT ROW(a.y * b.z - a.z * b.y,
                   a.z * b.x - a.x * b.z,
                   a.x * b.y - a.y * b.x)::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR <*> (LEFTARG = vec3, RIGHTARG = vec3, FUNCTION = v3_dot,
                     COMMUTATOR = <*>);

CREATE FUNCTION v3_len(a vec3) RETURNS float8
  AS $$ SELECT sqrt(a.x * a.x + a.y * a.y + a.z * a.z) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Note the shape of this function, which the whole engine follows: a single
-- SELECT with *no FROM clause*.  PostgreSQL only inlines a SQL function whose
-- body has an empty range table, and inlining is the difference between
-- folding this into the caller's expression tree and paying a full function
-- invocation per vector.  The cost is recomputing the length three times;
-- that is far cheaper than the call it avoids.
CREATE FUNCTION v3_unit(a vec3) RETURNS vec3
  AS $$ SELECT ROW(a.x / nullif(sqrt(a.x * a.x + a.y * a.y + a.z * a.z), 0),
                   a.y / nullif(sqrt(a.x * a.x + a.y * a.y + a.z * a.z), 0),
                   a.z / nullif(sqrt(a.x * a.x + a.y * a.y + a.z * a.z), 0))::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Optics --------------------------------------------------------------------

-- Mirror reflection of incident direction d about unit normal n.
CREATE FUNCTION v3_reflect(d vec3, n vec3) RETURNS vec3
  AS $$ SELECT d - n * (2.0 * v3_dot(d, n)) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Snell refraction of unit incident d through unit normal n with relative
-- index eta = n_from / n_into.  NULL signals total internal reflection.
CREATE FUNCTION v3_refract(d vec3, n vec3, eta float8) RETURNS vec3
  AS $$
  SELECT CASE
    WHEN 1.0 - eta * eta * (1.0 - v3_dot(d, n) * v3_dot(d, n)) < 0.0 THEN NULL
    ELSE v3_unit(d * eta + n * (eta * (-v3_dot(d, n))
           - sqrt(1.0 - eta * eta * (1.0 - v3_dot(d, n) * v3_dot(d, n)))))
  END $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- power() raises "value out of range: underflow" rather than returning zero
-- when the result is subnormal, which a specular exponent in the hundreds hits
-- constantly: with an exponent of 420, any cosine below ~0.19 underflows.
-- Going through exp/ln lets the tail decay to zero the way shading expects.
CREATE FUNCTION pow_safe(b float8, e float8) RETURNS float8
  AS $$ SELECT CASE WHEN b <= 0.0 THEN 0.0
                    WHEN e * ln(b) < -700.0 THEN 0.0
                    ELSE exp(e * ln(b))
               END $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Schlick's approximation to the Fresnel reflectance.  cosi is the cosine of
-- the angle to the normal on the incident side; r0 the normal-incidence
-- reflectance.  Callers must pass the post-refraction cosine when the ray is
-- leaving the denser medium, which is where the grazing-angle mirror effect
-- on the inside of glass comes from.
CREATE FUNCTION fresnel_schlick(cosi float8, r0 float8) RETURNS float8
  AS $$ SELECT r0 + (1.0 - r0) * pow_safe(1.0 - cosi, 5.0) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Per-component clamp, used to keep radiance in [0,1] before quantisation.
CREATE FUNCTION v3_clamp01(a vec3) RETURNS vec3
  AS $$ SELECT ROW(least(greatest(a.x, 0.0), 1.0),
                   least(greatest(a.y, 0.0), 1.0),
                   least(greatest(a.z, 0.0), 1.0))::vec3 $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION v3_maxc(a vec3) RETURNS float8
  AS $$ SELECT greatest(a.x, a.y, a.z) $$
  LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Summing radiance contributions per pixel needs an aggregate over vec3.
CREATE AGGREGATE sum(vec3) (
  SFUNC = v3_add,
  STYPE = vec3,
  INITCOND = '(0,0,0)',
  COMBINEFUNC = v3_add,
  PARALLEL = SAFE
);
