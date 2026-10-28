/*
 * Payload conversion: Foundation objects and XPC objects to the compact
 * JSON text analyticsd receives in a "send" message's "json" field, and
 * Foundation objects to XPC (for the management commands).
 *
 * Apple builds an nlohmann::json value (std::map backed, so object keys
 * come out in byte order) and calls dump(-1, ' ', false, strict).  This
 * writes the same text directly: compact separators, sorted keys,
 * nlohmann's string escaping and its number formatting.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#import "ca_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uuid/uuid.h>

/* Objects nested deeper than this below the top level are rejected. */
#define CA_MAX_DEPTH 11

/* --- buffer ------------------------------------------------------------- */

static void
buf_grow(ca_buf *b, size_t n)
{
	if (b->len + n + 1 <= b->cap)
		return;
	size_t cap = b->cap ? b->cap : 256;
	while (cap < b->len + n + 1)
		cap *= 2;
	char *p = realloc(b->ptr, cap);
	if (p == NULL)
		abort();
	b->ptr = p;
	b->cap = cap;
}

static void
buf_put(ca_buf *b, const char *s, size_t n)
{
	buf_grow(b, n);
	memcpy(b->ptr + b->len, s, n);
	b->len += n;
	b->ptr[b->len] = '\0';
}

static void
buf_putc(ca_buf *b, char c)
{
	buf_put(b, &c, 1);
}

static void
buf_puts(ca_buf *b, const char *s)
{
	buf_put(b, s, strlen(s));
}

void
ca_buf_free(ca_buf *b)
{
	free(b->ptr);
	b->ptr = NULL;
	b->len = b->cap = 0;
}

/* --- scalars ------------------------------------------------------------ */

/* Length of the UTF-8 sequence at s (0 if malformed), using the same
 * acceptance rules as nlohmann's decoder: no overlongs, no surrogates,
 * nothing above U+10FFFF. */
static size_t
utf8_seq(const unsigned char *s, size_t avail)
{
	unsigned char c = s[0];
	size_t n;
	unsigned char lo = 0x80, hi = 0xBF;

	if (c < 0x80)
		return 1;
	if (c >= 0xC2 && c <= 0xDF)
		n = 2;
	else if (c >= 0xE0 && c <= 0xEF) {
		n = 3;
		if (c == 0xE0)
			lo = 0xA0;
		else if (c == 0xED)
			hi = 0x9F;
	} else if (c >= 0xF0 && c <= 0xF4) {
		n = 4;
		if (c == 0xF0)
			lo = 0x90;
		else if (c == 0xF4)
			hi = 0x8F;
	} else
		return 0;
	if (avail < n)
		return 0;
	if (s[1] < lo || s[1] > hi)
		return 0;
	for (size_t i = 2; i < n; i++)
		if (s[i] < 0x80 || s[i] > 0xBF)
			return 0;
	return n;
}

static bool
put_string(ca_buf *b, const char *str, size_t len)
{
	const unsigned char *s = (const unsigned char *)str;
	size_t i = 0;

	buf_putc(b, '"');
	while (i < len) {
		unsigned char c = s[i];
		const char *esc = NULL;

		switch (c) {
		case '\b': esc = "\\b"; break;
		case '\t': esc = "\\t"; break;
		case '\n': esc = "\\n"; break;
		case '\f': esc = "\\f"; break;
		case '\r': esc = "\\r"; break;
		case '"':  esc = "\\\""; break;
		case '\\': esc = "\\\\"; break;
		}
		if (esc != NULL) {
			buf_puts(b, esc);
			i++;
		} else if (c < 0x20) {
			char u[8];
			snprintf(u, sizeof u, "\\u%04x", c);
			buf_puts(b, u);
			i++;
		} else {
			size_t n = utf8_seq(s + i, len - i);
			if (n == 0)
				return false;
			buf_put(b, (const char *)s + i, n);
			i += n;
		}
	}
	buf_putc(b, '"');
	return true;
}

static void
put_int(ca_buf *b, long long v)
{
	char t[24];
	snprintf(t, sizeof t, "%lld", v);
	buf_puts(b, t);
}

static void
put_uint(ca_buf *b, unsigned long long v)
{
	char t[24];
	snprintf(t, sizeof t, "%llu", v);
	buf_puts(b, t);
}

/* --- Grisu2 ------------------------------------------------------------
 *
 * Shortest-ish decimal digits for a double, after F. Loitsch, "Printing
 * Floating-Point Numbers Quickly and Accurately with Integers" (PLDI 2010),
 * the algorithm nlohmann::json's dump() uses.  All arithmetic is on
 * 64-bit "diy" floats (f * 2^e); a cached power of ten scales the value
 * so its exponent lands in [-60, -32], digits are generated from the
 * scaled upper boundary, and the last digit is nudged towards the exact
 * value.  The output always reads back as the same double and is the
 * shortest such string in nearly all cases. */

typedef struct {
	uint64_t f;
	int e;
} diyfp;

/* 10^k = f * 2^e with f normalized (top bit set) and rounded to nearest,
 * for k = -348, -340, ..., 340.  Generated from exact integer arithmetic. */
static const struct {
	uint64_t f;
	int e;
	int k;
} cached_powers[] = {
	{ 0xFA8FD5A0081C0288ULL, -1220, -348 },
	{ 0xBAAEE17FA23EBF76ULL, -1193, -340 },
	{ 0x8B16FB203055AC76ULL, -1166, -332 },
	{ 0xCF42894A5DCE35EAULL, -1140, -324 },
	{ 0x9A6BB0AA55653B2DULL, -1113, -316 },
	{ 0xE61ACF033D1A45DFULL, -1087, -308 },
	{ 0xAB70FE17C79AC6CAULL, -1060, -300 },
	{ 0xFF77B1FCBEBCDC4FULL, -1034, -292 },
	{ 0xBE5691EF416BD60CULL, -1007, -284 },
	{ 0x8DD01FAD907FFC3CULL,  -980, -276 },
	{ 0xD3515C2831559A83ULL,  -954, -268 },
	{ 0x9D71AC8FADA6C9B5ULL,  -927, -260 },
	{ 0xEA9C227723EE8BCBULL,  -901, -252 },
	{ 0xAECC49914078536DULL,  -874, -244 },
	{ 0x823C12795DB6CE57ULL,  -847, -236 },
	{ 0xC21094364DFB5637ULL,  -821, -228 },
	{ 0x9096EA6F3848984FULL,  -794, -220 },
	{ 0xD77485CB25823AC7ULL,  -768, -212 },
	{ 0xA086CFCD97BF97F4ULL,  -741, -204 },
	{ 0xEF340A98172AACE5ULL,  -715, -196 },
	{ 0xB23867FB2A35B28EULL,  -688, -188 },
	{ 0x84C8D4DFD2C63F3BULL,  -661, -180 },
	{ 0xC5DD44271AD3CDBAULL,  -635, -172 },
	{ 0x936B9FCEBB25C996ULL,  -608, -164 },
	{ 0xDBAC6C247D62A584ULL,  -582, -156 },
	{ 0xA3AB66580D5FDAF6ULL,  -555, -148 },
	{ 0xF3E2F893DEC3F126ULL,  -529, -140 },
	{ 0xB5B5ADA8AAFF80B8ULL,  -502, -132 },
	{ 0x87625F056C7C4A8BULL,  -475, -124 },
	{ 0xC9BCFF6034C13053ULL,  -449, -116 },
	{ 0x964E858C91BA2655ULL,  -422, -108 },
	{ 0xDFF9772470297EBDULL,  -396, -100 },
	{ 0xA6DFBD9FB8E5B88FULL,  -369,  -92 },
	{ 0xF8A95FCF88747D94ULL,  -343,  -84 },
	{ 0xB94470938FA89BCFULL,  -316,  -76 },
	{ 0x8A08F0F8BF0F156BULL,  -289,  -68 },
	{ 0xCDB02555653131B6ULL,  -263,  -60 },
	{ 0x993FE2C6D07B7FACULL,  -236,  -52 },
	{ 0xE45C10C42A2B3B06ULL,  -210,  -44 },
	{ 0xAA242499697392D3ULL,  -183,  -36 },
	{ 0xFD87B5F28300CA0EULL,  -157,  -28 },
	{ 0xBCE5086492111AEBULL,  -130,  -20 },
	{ 0x8CBCCC096F5088CCULL,  -103,  -12 },
	{ 0xD1B71758E219652CULL,   -77,   -4 },
	{ 0x9C40000000000000ULL,   -50,    4 },
	{ 0xE8D4A51000000000ULL,   -24,   12 },
	{ 0xAD78EBC5AC620000ULL,     3,   20 },
	{ 0x813F3978F8940984ULL,    30,   28 },
	{ 0xC097CE7BC90715B3ULL,    56,   36 },
	{ 0x8F7E32CE7BEA5C70ULL,    83,   44 },
	{ 0xD5D238A4ABE98068ULL,   109,   52 },
	{ 0x9F4F2726179A2245ULL,   136,   60 },
	{ 0xED63A231D4C4FB27ULL,   162,   68 },
	{ 0xB0DE65388CC8ADA8ULL,   189,   76 },
	{ 0x83C7088E1AAB65DBULL,   216,   84 },
	{ 0xC45D1DF942711D9AULL,   242,   92 },
	{ 0x924D692CA61BE758ULL,   269,  100 },
	{ 0xDA01EE641A708DEAULL,   295,  108 },
	{ 0xA26DA3999AEF774AULL,   322,  116 },
	{ 0xF209787BB47D6B85ULL,   348,  124 },
	{ 0xB454E4A179DD1877ULL,   375,  132 },
	{ 0x865B86925B9BC5C2ULL,   402,  140 },
	{ 0xC83553C5C8965D3DULL,   428,  148 },
	{ 0x952AB45CFA97A0B3ULL,   455,  156 },
	{ 0xDE469FBD99A05FE3ULL,   481,  164 },
	{ 0xA59BC234DB398C25ULL,   508,  172 },
	{ 0xF6C69A72A3989F5CULL,   534,  180 },
	{ 0xB7DCBF5354E9BECEULL,   561,  188 },
	{ 0x88FCF317F22241E2ULL,   588,  196 },
	{ 0xCC20CE9BD35C78A5ULL,   614,  204 },
	{ 0x98165AF37B2153DFULL,   641,  212 },
	{ 0xE2A0B5DC971F303AULL,   667,  220 },
	{ 0xA8D9D1535CE3B396ULL,   694,  228 },
	{ 0xFB9B7CD9A4A7443CULL,   720,  236 },
	{ 0xBB764C4CA7A44410ULL,   747,  244 },
	{ 0x8BAB8EEFB6409C1AULL,   774,  252 },
	{ 0xD01FEF10A657842CULL,   800,  260 },
	{ 0x9B10A4E5E9913129ULL,   827,  268 },
	{ 0xE7109BFBA19C0C9DULL,   853,  276 },
	{ 0xAC2820D9623BF429ULL,   880,  284 },
	{ 0x80444B5E7AA7CF85ULL,   907,  292 },
	{ 0xBF21E44003ACDD2DULL,   933,  300 },
	{ 0x8E679C2F5E44FF8FULL,   960,  308 },
	{ 0xD433179D9C8CB841ULL,   986,  316 },
	{ 0x9E19DB92B4E31BA9ULL,  1013,  324 },
	{ 0xEB96BF6EBADF77D9ULL,  1039,  332 },
	{ 0xAF87023B9BF0EE6BULL,  1066,  340 },
};

#define GRISU_ALPHA (-60)
#define GRISU_GAMMA (-32)

static diyfp
diy_normalize(diyfp x)
{
	while ((x.f >> 63) == 0) {
		x.f <<= 1;
		x.e--;
	}
	return x;
}

/* Product rounded to 64 bits. */
static diyfp
diy_mul(diyfp x, diyfp y)
{
	unsigned __int128 p = (unsigned __int128)x.f * y.f;
	p += (unsigned __int128)1 << 63;
	return (diyfp){ (uint64_t)(p >> 64), x.e + y.e + 64 };
}

/* Step the last digit down while that brings it closer to the exact
 * value and stays inside the boundaries. */
static void
grisu_round(char *dig, int len, uint64_t dist, uint64_t delta, uint64_t rest,
    uint64_t ten_k)
{
	while (rest < dist && delta - rest >= ten_k &&
	    (rest + ten_k < dist || dist - rest > rest + ten_k - dist)) {
		dig[len - 1]--;
		rest += ten_k;
	}
}

/* Digits of v (> 0, finite) into dig; returns the count and sets *dexp so
 * that v ~= digits * 10^*dexp. */
static int
grisu2(double v, char *dig, int *dexp)
{
	uint64_t bits;
	memcpy(&bits, &v, sizeof bits);
	uint64_t frac = bits & ((1ULL << 52) - 1);
	int biased = (int)(bits >> 52) & 0x7FF;

	diyfp w = biased == 0 ? (diyfp){ frac, 1 - 1075 }
			      : (diyfp){ frac | (1ULL << 52), biased - 1075 };
	bool closer = frac == 0 && biased > 1;	/* lower gap is half as wide */
	diyfp mp = diy_normalize((diyfp){ (w.f << 1) + 1, w.e - 1 });
	diyfp mm = closer ? (diyfp){ (w.f << 2) - 1, w.e - 2 }
			  : (diyfp){ (w.f << 1) - 1, w.e - 1 };
	mm.f <<= mm.e - mp.e;
	mm.e = mp.e;
	w = diy_normalize(w);

	/* First cached power that lifts the exponent to at least alpha. */
	size_t i = 0;
	while (cached_powers[i].e + mp.e + 64 < GRISU_ALPHA)
		i++;
	diyfp c = { cached_powers[i].f, cached_powers[i].e };
	int ck = cached_powers[i].k;	/* W = v * 10^ck */

	diyfp W = diy_mul(w, c);
	diyfp Mp = diy_mul(mp, c);
	diyfp Mm = diy_mul(mm, c);
	Mm.f++;			/* stay strictly inside the boundaries */
	Mp.f--;

	uint64_t delta = Mp.f - Mm.f;
	uint64_t dist = Mp.f - W.f;
	int shift = -Mp.e;
	uint64_t one = 1ULL << shift;
	uint32_t p1 = (uint32_t)(Mp.f >> shift);
	uint64_t p2 = Mp.f & (one - 1);

	/* Integral part: digits of p1, highest power of ten first. */
	uint32_t pow10 = 1;
	int kappa = 1;
	while (kappa < 10 && p1 >= pow10 * 10) {
		pow10 *= 10;
		kappa++;
	}
	int len = 0;
	while (kappa > 0) {
		dig[len++] = (char)('0' + p1 / pow10);
		p1 %= pow10;
		kappa--;
		uint64_t rest = ((uint64_t)p1 << shift) + p2;
		if (rest <= delta) {
			*dexp = kappa - ck;
			grisu_round(dig, len, dist, delta, rest, (uint64_t)pow10 << shift);
			return len;
		}
		pow10 /= 10;
	}

	/* Fractional part. */
	int m = 0;
	for (;;) {
		p2 *= 10;
		delta *= 10;
		dist *= 10;
		dig[len++] = (char)('0' + (p2 >> shift));
		p2 &= one - 1;
		m++;
		if (p2 <= delta) {
			*dexp = -m - ck;
			grisu_round(dig, len, dist, delta, p2, one);
			return len;
		}
	}
}

/* nlohmann::detail::to_chars: Grisu2 digits laid out by format_buffer()
 * with min_exp -4 and max_exp 15.  Non-finite values dump as null. */
static void
put_double(ca_buf *b, double v)
{
	char out[64], *p = out;
	char dig[20];
	int k, dexp;

	if (!isfinite(v)) {
		buf_puts(b, "null");
		return;
	}
	if (signbit(v)) {
		*p++ = '-';
		v = -v;
	}
	if (v == 0) {
		strcpy(p, "0.0");
		buf_puts(b, out);
		return;
	}
	k = grisu2(v, dig, &dexp);

	int n = k + dexp;	/* value = 0.DIGITS * 10^n */
	if (k <= n && n <= 15) {
		memcpy(p, dig, k);
		memset(p + k, '0', n - k);
		p += n;
		*p++ = '.';
		*p++ = '0';
	} else if (0 < n && n <= 15) {
		memcpy(p, dig, n);
		p += n;
		*p++ = '.';
		memcpy(p, dig + n, k - n);
		p += k - n;
	} else if (-4 < n && n <= 0) {
		*p++ = '0';
		*p++ = '.';
		memset(p, '0', -n);
		p += -n;
		memcpy(p, dig, k);
		p += k;
	} else {
		*p++ = dig[0];
		if (k > 1) {
			*p++ = '.';
			memcpy(p, dig + 1, k - 1);
			p += k - 1;
		}
		int e = n - 1;
		*p++ = 'e';
		*p++ = e < 0 ? '-' : '+';
		if (e < 0)
			e = -e;
		if (e < 10) {
			*p++ = '0';
			*p++ = (char)('0' + e);
		} else if (e < 100) {
			*p++ = (char)('0' + e / 10);
			*p++ = (char)('0' + e % 10);
		} else {
			*p++ = (char)('0' + e / 100);
			*p++ = (char)('0' + e / 10 % 10);
			*p++ = (char)('0' + e % 10);
		}
	}
	*p = '\0';
	buf_puts(b, out);
}

static void
put_hex(ca_buf *b, const void *data, size_t len)
{
	static const char digits[] = "0123456789abcdef";
	const unsigned char *d = data;

	buf_putc(b, '"');
	for (size_t i = 0; i < len; i++) {
		buf_putc(b, digits[d[i] >> 4]);
		buf_putc(b, digits[d[i] & 0xF]);
	}
	buf_putc(b, '"');
}

/* An object member; `k` is first so key_cmp sorts both these and plain
 * key arrays.  The dictionary being written keeps `v` alive. */
struct kv {
	const char *k;
	__unsafe_unretained id v;
};

/* std::less<std::string>: bytewise, shorter prefix first. */
static int
key_cmp(const void *a, const void *b)
{
	const char *x = *(const char *const *)a, *y = *(const char *const *)b;
	return strcmp(x, y);
}

/* --- Foundation --------------------------------------------------------- */

static void
ns_raise(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
ns_raise(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *reason = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	[NSException raise:NSInvalidArgumentException format:@"%@", reason];
}

static void
check_finite(double v, bool is_float)
{
	if (isnan(v))
		ns_raise(is_float ? @"Invalid number value (NaN) in JSON conversion"
				  : @"Invalid number value (NaN) in JSON write");
	if (isinf(v))
		ns_raise(is_float ? @"Invalid number value (infinite) in JSON conversion"
				  : @"Invalid number value (infinite) in JSON write");
}

/* The NSNumber kinds Apple's converter accepts, keyed on objCType. */
typedef enum { NUM_INT, NUM_UINT, NUM_DOUBLE, NUM_FLOAT, NUM_BAD } num_kind;

static num_kind
number_kind(NSNumber *n)
{
	switch (*[n objCType]) {
	case 'c': case 'i': case 'l': case 'q':
	case 'B': case 'C': case 'H':
		return NUM_INT;
	case 'I': case 'L': case 'Q': case 'S':
		return NUM_UINT;
	case 'd':
		return NUM_DOUBLE;
	case 'f':
		return NUM_FLOAT;
	default:	/* includes 's', which Apple rejects too */
		return NUM_BAD;
	}
}

static bool
is_cfbool(id obj)
{
	return CFGetTypeID((__bridge CFTypeRef)obj) == CFBooleanGetTypeID();
}

static const char *
ns_utf8(NSString *s, NSString *what)
{
	const char *u = [s UTF8String];
	if (u == NULL)
		ns_raise(@"Invalid non-UTF8 character(s) in %@", what);
	return u;
}

/* indent < 0: compact, with Apple's depth limit (makeJsonFromNSObject).
 * indent >= 0: nlohmann's pretty layout for an already-parsed value, which
 * has no depth limit. */
static void
newline(ca_buf *b, int indent, unsigned level)
{
	buf_putc(b, '\n');
	for (unsigned i = 0; i < (unsigned)indent * level; i++)
		buf_putc(b, ' ');
}

static void
ns_to_json(id obj, unsigned depth, int indent, ca_buf *b)
{
	if (indent < 0 && depth >= CA_MAX_DEPTH)
		ns_raise(@"Object exceeded the max depth");

	if ([obj isKindOfClass:[NSString class]]) {
		if (indent >= 0) {
			/* Parsed JSON strings may hold U+0000; keep every byte. */
			NSData *d = [obj dataUsingEncoding:NSUTF8StringEncoding];
			if (d == nil || !put_string(b, [d bytes], [d length]))
				ns_raise(@"Invalid non-UTF8 character(s) in string value");
			return;
		}
		const char *u = ns_utf8(obj, @"string value");
		if (!put_string(b, u, strlen(u)))
			ns_raise(@"Invalid non-UTF8 character(s) in string value");
	} else if ([obj isKindOfClass:[NSNumber class]]) {
		if (is_cfbool(obj)) {
			buf_puts(b, [obj boolValue] ? "true" : "false");
			return;
		}
		switch (number_kind(obj)) {
		case NUM_INT:
			put_int(b, [obj longLongValue]);
			break;
		case NUM_UINT:
			put_uint(b, [obj unsignedLongLongValue]);
			break;
		case NUM_DOUBLE: {
			double d = [obj doubleValue];
			if (indent < 0)
				check_finite(d, false);
			put_double(b, d);	/* nlohmann dumps non-finite as null */
			break;
		}
		case NUM_FLOAT: {
			float f = [obj floatValue];
			if (indent < 0)
				check_finite(f, true);
			put_double(b, (double)f);
			break;
		}
		case NUM_BAD:
			ns_raise(@"Invalid number type in JSON write (%c)", *[obj objCType]);
		}
	} else if ([obj isKindOfClass:[NSDictionary class]]) {
		NSDictionary *d = obj;
		NSUInteger n = [d count], i = 0;
		struct kv *kvs = calloc(n ? n : 1, sizeof *kvs);

		@try {
			for (id key in d) {
				if (![key isKindOfClass:[NSString class]])
					ns_raise(@"Invalid (non-string) key in JSON dictionary");
				kvs[i].k = ns_utf8(key, @"dictionary key");
				kvs[i++].v = d[key];
			}
			qsort(kvs, n, sizeof *kvs, key_cmp);
			buf_putc(b, '{');
			for (i = 0; i < n; i++) {
				if (i)
					buf_putc(b, ',');
				if (indent >= 0)
					newline(b, indent, depth + 1);
				if (!put_string(b, kvs[i].k, strlen(kvs[i].k)))
					ns_raise(@"Invalid non-UTF8 character(s) in dictionary key");
				buf_puts(b, indent >= 0 ? ": " : ":");
				ns_to_json(kvs[i].v, depth + 1, indent, b);
			}
			if (indent >= 0 && n != 0)
				newline(b, indent, depth);
			buf_putc(b, '}');
		} @finally {
			free(kvs);
		}
	} else if ([obj isKindOfClass:[NSArray class]]) {
		bool first = true;
		buf_putc(b, '[');
		for (id el in (NSArray *)obj) {
			if (!first)
				buf_putc(b, ',');
			first = false;
			if (indent >= 0)
				newline(b, indent, depth + 1);
			ns_to_json(el, depth + 1, indent, b);
		}
		if (indent >= 0 && !first)
			newline(b, indent, depth);
		buf_putc(b, ']');
	} else if ([obj isKindOfClass:[NSData class]]) {
		put_hex(b, [obj bytes], [obj length]);
	} else if ([obj isKindOfClass:[NSNull class]]) {
		buf_puts(b, "null");
	} else {
		ns_raise(@"Invalid type in JSON write (%@)", [obj class]);
	}
}

bool
ca_json_from_ns(id obj, ca_buf *out)
{
	out->len = 0;
	ns_to_json(obj, 0, -1, out);
	return true;
}

bool
ca_json_pretty_from_ns(id obj, int indent, ca_buf *out)
{
	out->len = 0;
	ns_to_json(obj, 0, indent, out);
	return true;
}

/* --- parsing ------------------------------------------------------------ */

/* A strict RFC 8259 parser with nlohmann's typing: integers that fit
 * int64 (negative) or uint64 (non-negative) stay integers, everything
 * else numeric is a double; duplicate object keys keep the last value.
 * Values become Foundation objects whose NSNumber objCType preserves that
 * typing, so ns_to_json() writes them back the way nlohmann would. */

typedef struct {
	const char *p, *end;
} lexer;

static void
skip_ws(lexer *lx)
{
	while (lx->p < lx->end && (*lx->p == ' ' || *lx->p == '\t' ||
	    *lx->p == '\n' || *lx->p == '\r'))
		lx->p++;
}

static bool
lit(lexer *lx, const char *word)
{
	size_t n = strlen(word);
	if ((size_t)(lx->end - lx->p) < n || memcmp(lx->p, word, n) != 0)
		return false;
	lx->p += n;
	return true;
}

static int
hex4(lexer *lx)
{
	int v = 0;
	if (lx->end - lx->p < 4)
		return -1;
	for (int i = 0; i < 4; i++) {
		char c = *lx->p++;
		v <<= 4;
		if (c >= '0' && c <= '9')
			v |= c - '0';
		else if (c >= 'a' && c <= 'f')
			v |= c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			v |= c - 'A' + 10;
		else
			return -1;
	}
	return v;
}

static void
put_utf8(ca_buf *b, uint32_t cp)
{
	char u[4];
	size_t n;
	if (cp < 0x80) {
		u[0] = (char)cp;
		n = 1;
	} else if (cp < 0x800) {
		u[0] = (char)(0xC0 | cp >> 6);
		u[1] = (char)(0x80 | (cp & 0x3F));
		n = 2;
	} else if (cp < 0x10000) {
		u[0] = (char)(0xE0 | cp >> 12);
		u[1] = (char)(0x80 | (cp >> 6 & 0x3F));
		u[2] = (char)(0x80 | (cp & 0x3F));
		n = 3;
	} else {
		u[0] = (char)(0xF0 | cp >> 18);
		u[1] = (char)(0x80 | (cp >> 12 & 0x3F));
		u[2] = (char)(0x80 | (cp >> 6 & 0x3F));
		u[3] = (char)(0x80 | (cp & 0x3F));
		n = 4;
	}
	buf_put(b, u, n);
}

/* Parses a string body (after the opening quote) into b. */
static bool
parse_string(lexer *lx, ca_buf *b)
{
	b->len = 0;
	buf_grow(b, 0);
	b->ptr[0] = '\0';
	while (lx->p < lx->end) {
		unsigned char c = (unsigned char)*lx->p;
		if (c == '"') {
			lx->p++;
			return true;
		}
		if (c < 0x20)
			return false;
		if (c != '\\') {
			size_t n = utf8_seq((const unsigned char *)lx->p, (size_t)(lx->end - lx->p));
			if (n == 0)
				return false;
			buf_put(b, lx->p, n);
			lx->p += n;
			continue;
		}
		if (++lx->p >= lx->end)
			return false;
		switch (*lx->p++) {
		case '"':  buf_putc(b, '"'); break;
		case '\\': buf_putc(b, '\\'); break;
		case '/':  buf_putc(b, '/'); break;
		case 'b':  buf_putc(b, '\b'); break;
		case 'f':  buf_putc(b, '\f'); break;
		case 'n':  buf_putc(b, '\n'); break;
		case 'r':  buf_putc(b, '\r'); break;
		case 't':  buf_putc(b, '\t'); break;
		case 'u': {
			int hi = hex4(lx);
			uint32_t cp;
			if (hi < 0 || (hi >= 0xDC00 && hi <= 0xDFFF))
				return false;
			cp = (uint32_t)hi;
			if (hi >= 0xD800 && hi <= 0xDBFF) {
				if (!lit(lx, "\\u"))
					return false;
				int lo = hex4(lx);
				if (lo < 0xDC00 || lo > 0xDFFF)
					return false;
				cp = 0x10000 + (((uint32_t)hi - 0xD800) << 10) + ((uint32_t)lo - 0xDC00);
			}
			put_utf8(b, cp);
			break;
		}
		default:
			return false;
		}
	}
	return false;
}

static NSString *
string_from_buf(const ca_buf *b)
{
	return [[NSString alloc] initWithBytes:b->ptr length:b->len encoding:NSUTF8StringEncoding];
}

static NSNumber *
parse_number(lexer *lx)
{
	const char *s = lx->p;
	bool is_float = false;

	if (lx->p < lx->end && *lx->p == '-')
		lx->p++;
	if (lx->p >= lx->end)
		return nil;
	if (*lx->p == '0')
		lx->p++;
	else if (*lx->p >= '1' && *lx->p <= '9')
		while (lx->p < lx->end && *lx->p >= '0' && *lx->p <= '9')
			lx->p++;
	else
		return nil;
	if (lx->p < lx->end && *lx->p == '.') {
		is_float = true;
		if (++lx->p >= lx->end || *lx->p < '0' || *lx->p > '9')
			return nil;
		while (lx->p < lx->end && *lx->p >= '0' && *lx->p <= '9')
			lx->p++;
	}
	if (lx->p < lx->end && (*lx->p == 'e' || *lx->p == 'E')) {
		is_float = true;
		lx->p++;
		if (lx->p < lx->end && (*lx->p == '+' || *lx->p == '-'))
			lx->p++;
		if (lx->p >= lx->end || *lx->p < '0' || *lx->p > '9')
			return nil;
		while (lx->p < lx->end && *lx->p >= '0' && *lx->p <= '9')
			lx->p++;
	}

	char tmp[512];
	size_t n = (size_t)(lx->p - s);
	char *num = n < sizeof tmp ? tmp : malloc(n + 1);
	memcpy(num, s, n);
	num[n] = '\0';

	NSNumber *r = nil;
	if (!is_float) {
		errno = 0;
		if (*num == '-') {
			long long v = strtoll(num, NULL, 10);
			if (errno == 0)
				r = @(v);
		} else {
			unsigned long long v = strtoull(num, NULL, 10);
			if (errno == 0)
				r = v > INT64_MAX ? @(v) : @((long long)v);
		}
	}
	if (r == nil)
		r = @(strtod(num, NULL));
	if (num != tmp)
		free(num);
	return r;
}

/* Immutable, built the way makeNSObjectFromJson builds it. */
static NSDictionary *
frozen_dict(NSDictionary *d)
{
	NSUInteger n = [d count];
	__unsafe_unretained id keys[n ? n : 1], vals[n ? n : 1];
	[d getObjects:vals andKeys:keys count:n];
	return [NSDictionary dictionaryWithObjects:vals forKeys:keys count:n];
}

static id
parse_value(lexer *lx, ca_buf *sb)
{
	skip_ws(lx);
	if (lx->p >= lx->end)
		return nil;

	switch (*lx->p) {
	case '{': {
		NSMutableDictionary *d = [NSMutableDictionary dictionary];
		lx->p++;
		skip_ws(lx);
		if (lx->p < lx->end && *lx->p == '}') {
			lx->p++;
			return frozen_dict(d);
		}
		for (;;) {
			skip_ws(lx);
			if (lx->p >= lx->end || *lx->p++ != '"' || !parse_string(lx, sb))
				return nil;
			NSString *key = string_from_buf(sb);
			skip_ws(lx);
			if (lx->p >= lx->end || *lx->p++ != ':')
				return nil;
			id v = parse_value(lx, sb);
			if (v == nil)
				return nil;
			d[key] = v;
			skip_ws(lx);
			if (lx->p >= lx->end)
				return nil;
			if (*lx->p == ',') {
				lx->p++;
				continue;
			}
			if (*lx->p++ != '}')
				return nil;
			return frozen_dict(d);
		}
	}
	case '[': {
		NSMutableArray *a = [NSMutableArray array];
		lx->p++;
		skip_ws(lx);
		if (lx->p < lx->end && *lx->p == ']') {
			lx->p++;
			return [NSArray arrayWithArray:a];
		}
		for (;;) {
			id v = parse_value(lx, sb);
			if (v == nil)
				return nil;
			[a addObject:v];
			skip_ws(lx);
			if (lx->p >= lx->end)
				return nil;
			if (*lx->p == ',') {
				lx->p++;
				continue;
			}
			if (*lx->p++ != ']')
				return nil;
			return [NSArray arrayWithArray:a];
		}
	}
	case '"':
		lx->p++;
		return parse_string(lx, sb) ? string_from_buf(sb) : nil;
	case 't':
		return lit(lx, "true") ? (__bridge id)kCFBooleanTrue : nil;
	case 'f':
		return lit(lx, "false") ? (__bridge id)kCFBooleanFalse : nil;
	case 'n':
		return lit(lx, "null") ? [NSNull null] : nil;
	default:
		return parse_number(lx);
	}
}

id
ca_ns_from_json(const char *text, size_t len)
{
	lexer lx = { text, text + len };
	ca_buf sb = {0};
	id v = parse_value(&lx, &sb);
	ca_buf_free(&sb);
	skip_ws(&lx);
	return lx.p == lx.end ? v : nil;
}

static xpc_object_t
ca_xpc_from_ns_depth(id obj, unsigned depth)
{
	if (depth >= CA_MAX_DEPTH)
		ns_raise(@"Object exceeded the max depth");

	if ([obj isKindOfClass:[NSString class]])
		return xpc_string_create(ns_utf8(obj, @"string value"));
	if ([obj isKindOfClass:[NSNumber class]]) {
		if (is_cfbool(obj))
			return xpc_bool_create([obj boolValue]);
		switch (number_kind(obj)) {
		case NUM_INT:
			return xpc_int64_create([obj longLongValue]);
		case NUM_UINT:
			return xpc_uint64_create([obj unsignedLongLongValue]);
		case NUM_DOUBLE: {
			double d = [obj doubleValue];
			check_finite(d, false);
			return xpc_double_create(d);
		}
		case NUM_FLOAT: {
			float f = [obj floatValue];
			check_finite(f, true);
			return xpc_double_create(f);
		}
		case NUM_BAD:
			ns_raise(@"Invalid number type in JSON write (%c)", *[obj objCType]);
		}
	}
	if ([obj isKindOfClass:[NSDictionary class]]) {
		xpc_object_t d = xpc_dictionary_create_empty();
		[(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
			(void)stop;
			if (![key isKindOfClass:[NSString class]])
				ns_raise(@"Invalid (non-string) key in JSON dictionary");
			xpc_dictionary_set_value(d, ns_utf8(key, @"dictionary key"),
			    ca_xpc_from_ns_depth(val, depth + 1));
		}];
		return d;
	}
	if ([obj isKindOfClass:[NSArray class]]) {
		xpc_object_t a = xpc_array_create_empty();
		for (id el in (NSArray *)obj)
			xpc_array_append_value(a, ca_xpc_from_ns_depth(el, depth + 1));
		return a;
	}
	if ([obj isKindOfClass:[NSData class]])
		return xpc_data_create([obj bytes], [obj length]);
	if ([obj isKindOfClass:[NSNull class]])
		return xpc_null_create();
	ns_raise(@"Invalid type in JSON write (%@)", [obj class]);
	return nil;
}

xpc_object_t
ca_xpc_from_ns(id obj)
{
	return ca_xpc_from_ns_depth(obj, 0);
}

/* --- XPC ---------------------------------------------------------------- */

static bool
xpc_to_json(xpc_object_t o, ca_buf *b, char **err)
{
	xpc_type_t t = xpc_get_type(o);

	if (t == XPC_TYPE_DICTIONARY) {
		size_t n = xpc_dictionary_get_count(o);
		__block size_t i = 0;
		const char **keys = calloc(n ? n : 1, sizeof *keys);
		xpc_dictionary_apply(o, ^bool(const char *key, xpc_object_t v) {
			(void)v;
			keys[i++] = key;
			return true;
		});
		qsort(keys, n, sizeof *keys, key_cmp);
		buf_putc(b, '{');
		for (i = 0; i < n; i++) {
			if (i)
				buf_putc(b, ',');
			if (!put_string(b, keys[i], strlen(keys[i]))) {
				asprintf(err, "[json.exception.type_error.316] invalid UTF-8 byte");
				free(keys);
				return false;
			}
			buf_putc(b, ':');
			if (!xpc_to_json(xpc_dictionary_get_value(o, keys[i]), b, err)) {
				free(keys);
				return false;
			}
		}
		buf_putc(b, '}');
		free(keys);
	} else if (t == XPC_TYPE_STRING) {
		if (!put_string(b, xpc_string_get_string_ptr(o), xpc_string_get_length(o))) {
			asprintf(err, "[json.exception.type_error.316] invalid UTF-8 byte");
			return false;
		}
	} else if (t == XPC_TYPE_INT64) {
		put_int(b, xpc_int64_get_value(o));
	} else if (t == XPC_TYPE_ARRAY) {
		size_t n = xpc_array_get_count(o);
		buf_putc(b, '[');
		for (size_t i = 0; i < n; i++) {
			if (i)
				buf_putc(b, ',');
			if (!xpc_to_json(xpc_array_get_value(o, i), b, err))
				return false;
		}
		buf_putc(b, ']');
	} else if (t == XPC_TYPE_DATA) {
		put_hex(b, xpc_data_get_bytes_ptr(o), xpc_data_get_length(o));
	} else if (t == XPC_TYPE_BOOL) {
		buf_puts(b, xpc_bool_get_value(o) ? "true" : "false");
	} else if (t == XPC_TYPE_UINT64) {
		put_uint(b, xpc_uint64_get_value(o));
	} else if (t == XPC_TYPE_NULL) {
		buf_puts(b, "null");
	} else if (t == XPC_TYPE_DOUBLE) {
		put_double(b, xpc_double_get_value(o));
	} else if (t == XPC_TYPE_UUID) {
		uuid_string_t s;
		uuid_unparse_lower(xpc_uuid_get_bytes(o), s);
		put_string(b, s, strlen(s));
	} else {
		asprintf(err, "XPC type (%s) cannot be converted and is invalid",
		    xpc_type_get_name(t));
		return false;
	}
	return true;
}

bool
ca_json_from_xpc(xpc_object_t obj, ca_buf *out, char **err)
{
	out->len = 0;
	*err = NULL;
	return xpc_to_json(obj, out, err);
}
