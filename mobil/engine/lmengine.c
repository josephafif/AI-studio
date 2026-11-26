/*
 * lmengine – liten inferensmotor för Lennart-modellerna (GPT, decoder-only) på telefonen.
 *
 * Läser en .lmod-fil (skapas av tools/exportera_mobil.py) med mmap, kör framåtpass med KV-cache
 * och samplar nästa token. Stöder båda varianterna i AI Control Center:
 *   - panelens GPT (Lennart, Lennart 2): bias i linjära lager, exakt GELU
 *   - Lennart 3-formatet (Lennart 3, 3.1): utan bias, GELU med tanh
 * Vikterna kan vara float32 eller int8 med en skalfaktor per rad. Beräkningen parallelliseras med OpenMP.
 *
 * Formatversion 2 (arkitektur 1) är LFM2 (Liquid AI): korta faltningar och grupperad attention (GQA) i
 * blandade lager, RMSNorm, SwiGLU och RoPE. Faltningslagrens indata sparas per position, precis som
 * attention-cachen, så att lm_rewind fungerar för utkast och ekodekodning.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__wasm__)
/* Webbversionen: modellen läses in i minnet med lm_load_mem (ingen filmappning i webbläsaren). */
#define EXPORT __attribute__((used, visibility("default")))
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define EXPORT __declspec(dllexport)
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define EXPORT __attribute__((visibility("default")))
#endif
#ifdef _OPENMP
#include <omp.h>
#endif
#define ALIGN 64

typedef struct {
    int quant;            /* 0 = float32, 1 = int8 */
    int rows, cols;
    const float *f;       /* float32-vikter */
    const int8_t *q;      /* int8-vikter */
    const float *scale;   /* skala per rad, eller per grupp om gs > 0 */
    int gs;               /* gruppstorlek (kvantläge 2: 64 vikter per skala), 0 = en skala per rad */
} Mat;

#define LM_GROUP 64

typedef struct {
    const float *ln1_w, *ln1_b, *ln2_w, *ln2_b;
    Mat qkv, proj, fc, out;
    const float *qkv_b, *proj_b, *fc_b, *out_b; /* NULL utan bias */
} Layer;

/* LFM2-lager: antingen attention eller kort faltning, alltid följt av SwiGLU. */
typedef struct {
    const float *norm1, *norm2;      /* operator_norm och ffn_norm (RMSNorm) */
    int attn, slot;                  /* attention eller faltning; plats i respektive cache */
    Mat q, k, v, o;                  /* attention */
    const float *qn, *kn;            /* RMSNorm per huvud för q och k */
    Mat in, out;                     /* faltning: in_proj [3d][d] och out_proj [d][d] */
    const float *convw;              /* faltningskärnan [d][L] */
    Mat w1, w3, w2;                  /* SwiGLU: w2(silu(w1 x) * w3 x) */
} LfmLayer;

#define LFM_CHUNK 32 /* tokens per bit när en lång prompt läses in */

typedef struct LM {
    int vocab, d, layers, heads, ctx, has_bias, gelu_tanh, quant;
    int arch;                 /* 0 = GPT (Lennart 1–3), 1 = LFM2 */
    int kv_heads, ffdim, conv_L; /* LFM2 */
    float rope_theta, eps;
    LfmLayer *F;
    float *ccache;            /* faltningarnas indata (B·x) [faltningslager][ctx][d] */
    float *rope_cos, *rope_sin, *ff2;
    void *map;
    size_t map_size;
    int owned; /* 1 = map är ett minnesblock från malloc (lm_load_mem), 0 = filmappning */
    Mat wte;
    const float *wpe, *lnf_w, *lnf_b;
    Layer *L;
    float *kcache, *vcache; /* [layers][ctx][d] */
    int pos;
    float *x, *h, *qkv, *att, *ff, *logits, *scores; /* arbetsminne för upp till ctx tokens */
} LM;

/* ---------------------------------------------------------------- inläsning */
static size_t take(size_t *off, size_t bytes) {
    size_t at = (*off + ALIGN - 1) / ALIGN * ALIGN;
    *off = at + bytes;
    return at;
}

static const float *take_f(LM *m, size_t *off, size_t n) {
    return (const float *)((const char *)m->map + take(off, n * sizeof(float)));
}

static Mat take_mat(LM *m, size_t *off, int rows, int cols) {
    Mat w = {m->quant ? 1 : 0, rows, cols, NULL, NULL, NULL, m->quant == 2 ? LM_GROUP : 0};
    if (m->quant) {
        w.q = (const int8_t *)((const char *)m->map + take(off, (size_t)rows * cols));
        w.scale = take_f(m, off, w.gs ? (size_t)rows * (cols / w.gs) : (size_t)rows);
    } else {
        w.f = take_f(m, off, (size_t)rows * cols);
    }
    return w;
}

/* ---------------------------------------------------------------- filmappning (Linux/Android och Windows) */
static void *map_file(const char *path, size_t *size) {
#if defined(__wasm__)
    (void)path; (void)size;
    return NULL;
#elif defined(_WIN32)
    /* Sökvägen kommer som UTF-8 (Dart) – Windows vill ha UTF-16 för å, ä, ö i mappnamn. */
    wchar_t wpath[MAX_PATH * 2];
    if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH * 2)) return NULL;
    HANDLE f = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return NULL;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(f, &sz)) { CloseHandle(f); return NULL; }
    HANDLE mapping = CreateFileMappingW(f, NULL, PAGE_READONLY, 0, 0, NULL);
    CloseHandle(f);
    if (!mapping) return NULL;
    void *p = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(mapping); /* vyn håller mappningen vid liv */
    *size = (size_t)sz.QuadPart;
    return p;
#else
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    fstat(fd, &st);
    void *p = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;
    *size = (size_t)st.st_size;
    return p;
#endif
}

static void unmap_file(void *p, size_t size) {
#if defined(__wasm__)
    (void)p; (void)size;
#elif defined(_WIN32)
    (void)size;
    UnmapViewOfFile(p);
#else
    munmap(p, size);
#endif
}

EXPORT void lm_free(LM *m) {
    if (!m) return;
    if (m->map) {
        if (m->owned) free(m->map);
        else unmap_file(m->map, m->map_size);
    }
    free(m->L); free(m->F); free(m->ccache); free(m->rope_cos); free(m->rope_sin); free(m->ff2);
    free(m->kcache); free(m->vcache);
    free(m->x); free(m->h); free(m->qkv); free(m->att); free(m->ff); free(m->logits); free(m->scores);
    free(m);
}

static LM *load_from(void *map, size_t fsize, int owned, char *err, int errlen);
static LM *load_lfm(LM *m, const int32_t *hd, char *err, int errlen);

EXPORT LM *lm_load(const char *path, int nthreads, char *err, int errlen) {
#ifdef _OPENMP
    if (nthreads > 0) omp_set_num_threads(nthreads);
#else
    (void)nthreads;
#endif
    size_t fsize = 0;
    void *map = map_file(path, &fsize);
    if (!map) { snprintf(err, errlen, "kan inte öppna %s", path); return NULL; }
    return load_from(map, fsize, 0, err, errlen);
}

/* Läser en modell som redan ligger i minnet (webbversionen). [data] ska komma från malloc;
 * motorn tar över det och frigör det i lm_free, även om inläsningen misslyckas. */
EXPORT LM *lm_load_mem(void *data, size_t size, char *err, int errlen) {
    if (!data) { snprintf(err, errlen, "inget minne"); return NULL; }
    return load_from(data, size, 1, err, errlen);
}

static LM *load_from(void *map, size_t fsize, int owned, char *err, int errlen) {
    if (fsize < 64 || memcmp(map, "LMOD0001", 8) != 0) {
        if (owned) free(map); else unmap_file(map, fsize);
        snprintf(err, errlen, "inte en .lmod-fil");
        return NULL;
    }
    LM *m = calloc(1, sizeof(LM));
    m->map = map;
    m->map_size = fsize;
    m->owned = owned;
    const int32_t *hd = (const int32_t *)((const char *)map + 8);
    if (hd[0] == 2) return load_lfm(m, hd, err, errlen);
    /* hd[0]=version, vocab, d, layers, heads, ctx, has_bias, gelu_tanh, quant */
    m->vocab = hd[1]; m->d = hd[2]; m->layers = hd[3]; m->heads = hd[4]; m->ctx = hd[5];
    m->has_bias = hd[6]; m->gelu_tanh = hd[7]; m->quant = hd[8];
    int d = m->d;
    if (hd[0] != 1 || d <= 0 || m->heads <= 0 || d % m->heads || m->ctx <= 0 || m->vocab <= 0) {
        lm_free(m); snprintf(err, errlen, "ogiltigt huvud i .lmod"); return NULL;
    }
    size_t off = 64;
    m->wte = take_mat(m, &off, m->vocab, d);
    m->wpe = take_f(m, &off, (size_t)m->ctx * d);
    m->L = calloc(m->layers, sizeof(Layer));
    for (int l = 0; l < m->layers; l++) {
        Layer *y = &m->L[l];
        y->ln1_w = take_f(m, &off, d); y->ln1_b = take_f(m, &off, d);
        y->qkv = take_mat(m, &off, 3 * d, d); if (m->has_bias) y->qkv_b = take_f(m, &off, 3 * d);
        y->proj = take_mat(m, &off, d, d);   if (m->has_bias) y->proj_b = take_f(m, &off, d);
        y->ln2_w = take_f(m, &off, d); y->ln2_b = take_f(m, &off, d);
        y->fc = take_mat(m, &off, 4 * d, d); if (m->has_bias) y->fc_b = take_f(m, &off, 4 * d);
        y->out = take_mat(m, &off, d, 4 * d); if (m->has_bias) y->out_b = take_f(m, &off, d);
    }
    m->lnf_w = take_f(m, &off, d); m->lnf_b = take_f(m, &off, d);
    if (off > fsize) { lm_free(m); snprintf(err, errlen, "filen är för kort"); return NULL; }
    size_t T = m->ctx;
    m->kcache = calloc((size_t)m->layers * T * d, sizeof(float));
    m->vcache = calloc((size_t)m->layers * T * d, sizeof(float));
    m->x = malloc(T * d * sizeof(float));
    m->h = malloc(T * d * sizeof(float));
    m->qkv = malloc(T * 3 * d * sizeof(float));
    m->att = malloc(T * d * sizeof(float));
    m->ff = malloc(T * 4 * d * sizeof(float));
    m->logits = malloc((size_t)m->vocab * sizeof(float));
    m->scores = malloc(T * m->heads * T * sizeof(float));
    if (!m->kcache || !m->vcache || !m->x || !m->ff || !m->scores || !m->logits) {
        lm_free(m); snprintf(err, errlen, "för lite minne"); return NULL;
    }
    return m;
}

EXPORT void lm_info(LM *m, int32_t *out) {
    out[0] = m->vocab; out[1] = m->d; out[2] = m->layers; out[3] = m->heads; out[4] = m->ctx;
    out[5] = m->quant; out[6] = m->has_bias; out[7] = m->arch;
}

EXPORT void lm_reset(LM *m) { m->pos = 0; }
EXPORT int lm_pos(LM *m) { return m->pos; }
EXPORT float *lm_logits(LM *m) { return m->logits; }

/* Spolar tillbaka till en tidigare position. Cachen före pos är orörd, så flera utkast kan
 * dela samma inlästa prompt. Anroparen återställer själv logits för positionen. */
EXPORT int lm_rewind(LM *m, int pos) {
    if (pos < 0 || pos > m->pos) return -1;
    m->pos = pos;
    return 0;
}

/* log P(tok) enligt nuvarande logits (log-softmax, utan temperatur). */
EXPORT float lm_logprob(LM *m, int tok) {
    const float *lg = m->logits;
    float mx = -INFINITY;
    for (int i = 0; i < m->vocab; i++) if (lg[i] > mx) mx = lg[i];
    double sum = 0;
    for (int i = 0; i < m->vocab; i++) if (lg[i] > -INFINITY) sum += exp(lg[i] - mx);
    if (tok < 0 || tok >= m->vocab || !(lg[tok] > -INFINITY)) return -INFINITY;
    return (float)(lg[tok] - mx - log(sum));
}

/* ---------------------------------------------------------------- beräkning */
static void layernorm(float *o, const float *x, const float *w, const float *b, int d) {
    float mean = 0, var = 0;
    for (int i = 0; i < d; i++) mean += x[i];
    mean /= d;
    for (int i = 0; i < d; i++) { float t = x[i] - mean; var += t * t; }
    float inv = 1.0f / sqrtf(var / d + 1e-5f);
    for (int i = 0; i < d; i++) o[i] = (x[i] - mean) * inv * w[i] + b[i];
}

/* out[i][r] = in[i] · W[r] (+ bias[r]) för n rader in, parallellt över W:s rader. */
static void matmul(float *out, const float *in, int n, const Mat *W, const float *bias) {
    const int rows = W->rows, cols = W->cols;
    #pragma omp parallel
    {
        float *wrow = malloc(cols * sizeof(float));
        #pragma omp for schedule(static)
        for (int r = 0; r < rows; r++) {
            const float b = bias ? bias[r] : 0.0f;
            if (W->quant && W->gs) {
                /* Kvantläge 2: en skala per grupp om gs vikter. */
                const int8_t *q = W->q + (size_t)r * cols;
                const int gs = W->gs, ng = cols / gs;
                const float *sc = W->scale + (size_t)r * ng;
                if (n == 1) {
                    float acc = 0;
                    for (int g = 0; g < ng; g++) {
                        const int8_t *qg = q + (size_t)g * gs;
                        const float *xg = in + (size_t)g * gs;
                        float a = 0;
                        #pragma omp simd reduction(+:a)
                        for (int k = 0; k < gs; k++) a += (float)qg[k] * xg[k];
                        acc += a * sc[g];
                    }
                    out[r] = acc + b;
                    continue;
                }
                for (int g = 0; g < ng; g++) {
                    const float sg = sc[g];
                    #pragma omp simd
                    for (int k = 0; k < gs; k++) wrow[g * gs + k] = (float)q[g * gs + k] * sg;
                }
            } else if (W->quant) {
                const int8_t *q = W->q + (size_t)r * cols;
                const float s = W->scale[r];
                if (n == 1) {
                    float acc = 0;
                    #pragma omp simd reduction(+:acc)
                    for (int k = 0; k < cols; k++) acc += (float)q[k] * in[k];
                    out[r] = acc * s + b;
                    continue;
                }
                #pragma omp simd
                for (int k = 0; k < cols; k++) wrow[k] = (float)q[k] * s;
            } else {
                memcpy(wrow, W->f + (size_t)r * cols, cols * sizeof(float));
            }
            /* Fyra tokens åt gången: varje vikt läses en gång per fyra tokens i stället för en gång per token. */
            int i = 0;
            for (; i + 4 <= n; i += 4) {
                const float *x0 = in + (size_t)i * cols, *x1 = x0 + cols, *x2 = x1 + cols, *x3 = x2 + cols;
                float a0 = 0, a1 = 0, a2 = 0, a3 = 0;
                #pragma omp simd reduction(+:a0,a1,a2,a3)
                for (int k = 0; k < cols; k++) {
                    const float w = wrow[k];
                    a0 += w * x0[k]; a1 += w * x1[k]; a2 += w * x2[k]; a3 += w * x3[k];
                }
                out[(size_t)i * rows + r] = a0 + b;
                out[(size_t)(i + 1) * rows + r] = a1 + b;
                out[(size_t)(i + 2) * rows + r] = a2 + b;
                out[(size_t)(i + 3) * rows + r] = a3 + b;
            }
            for (; i + 2 <= n; i += 2) {
                const float *x0 = in + (size_t)i * cols, *x1 = x0 + cols;
                float a0 = 0, a1 = 0;
                #pragma omp simd reduction(+:a0,a1)
                for (int k = 0; k < cols; k++) { const float w = wrow[k]; a0 += w * x0[k]; a1 += w * x1[k]; }
                out[(size_t)i * rows + r] = a0 + b;
                out[(size_t)(i + 1) * rows + r] = a1 + b;
            }
            for (; i < n; i++) {
                const float *x = in + (size_t)i * cols;
                float acc = 0;
                #pragma omp simd reduction(+:acc)
                for (int k = 0; k < cols; k++) acc += wrow[k] * x[k];
                out[(size_t)i * rows + r] = acc + b;
            }
        }
        free(wrow);
    }
}

static float gelu(float x, int tanh_approx) {
    if (tanh_approx) return 0.5f * x * (1.0f + tanhf(0.7978845608f * (x + 0.044715f * x * x * x)));
    return 0.5f * x * (1.0f + erff(x * 0.70710678f));
}


/* ---------------------------------------------------------------- LFM2 (formatversion 2) */
/* hd: 2, vocab, d, lager, heads, ctx, kv-heads, ff, kvant, arkitektur (1), faltningslängd L,
 * lagertyper (bit l = attention), rope_theta (float), eps (float). Vikterna i ordning: inbäddning,
 * för varje lager norm1, norm2, (q, k, v, o, qnorm, knorm) eller (in, kärna [d][L], out), w1, w3, w2,
 * och sist slutnormen. Utmatningslagret delar vikter med inbäddningen. */
static LM *load_lfm(LM *m, const int32_t *hd, char *err, int errlen) {
    m->arch = 1;
    m->vocab = hd[1]; m->d = hd[2]; m->layers = hd[3]; m->heads = hd[4]; m->ctx = hd[5];
    m->kv_heads = hd[6]; m->ffdim = hd[7]; m->quant = hd[8]; m->conv_L = hd[10];
    const uint32_t typer = (uint32_t)hd[11];
    memcpy(&m->rope_theta, &hd[12], 4);
    memcpy(&m->eps, &hd[13], 4);
    const int d = m->d, H = m->heads;
    if (hd[9] != 1 || d <= 0 || H <= 0 || d % H || m->kv_heads <= 0 || H % m->kv_heads || m->ctx <= 0 ||
        m->vocab <= 0 || m->ffdim <= 0 || m->conv_L < 1 || m->conv_L > 16 || m->layers <= 0 || m->layers > 32 ||
        (d / H) % 2 || !(m->eps > 0) || !(m->rope_theta > 0) || m->quant < 0 || m->quant > 2 ||
        (m->quant == 2 && (d % LM_GROUP || m->ffdim % LM_GROUP))) {
        lm_free(m); snprintf(err, errlen, "ogiltigt huvud i .lmod (LFM2)"); return NULL;
    }
    const int hdim = d / H, kvd = m->kv_heads * hdim, T = m->ctx, L = m->conv_L, h2 = hdim / 2;
    size_t off = 64;
    m->wte = take_mat(m, &off, m->vocab, d);
    m->F = calloc(m->layers, sizeof(LfmLayer));
    if (!m->F) { lm_free(m); snprintf(err, errlen, "för lite minne"); return NULL; }
    int na = 0, nc = 0;
    for (int l = 0; l < m->layers; l++) {
        LfmLayer *y = &m->F[l];
        y->attn = (typer >> l) & 1u;
        y->norm1 = take_f(m, &off, d);
        y->norm2 = take_f(m, &off, d);
        if (y->attn) {
            y->slot = na++;
            y->q = take_mat(m, &off, d, d); y->k = take_mat(m, &off, kvd, d);
            y->v = take_mat(m, &off, kvd, d); y->o = take_mat(m, &off, d, d);
            y->qn = take_f(m, &off, hdim); y->kn = take_f(m, &off, hdim);
        } else {
            y->slot = nc++;
            y->in = take_mat(m, &off, 3 * d, d);
            y->convw = take_f(m, &off, (size_t)d * L);
            y->out = take_mat(m, &off, d, d);
        }
        y->w1 = take_mat(m, &off, m->ffdim, d);
        y->w3 = take_mat(m, &off, m->ffdim, d);
        y->w2 = take_mat(m, &off, d, m->ffdim);
    }
    m->lnf_w = take_f(m, &off, d);
    if (off > m->map_size) { lm_free(m); snprintf(err, errlen, "filen är för kort"); return NULL; }
    const size_t C = LFM_CHUNK < T ? LFM_CHUNK : T;
    m->kcache = calloc((size_t)(na ? na : 1) * T * kvd, sizeof(float));
    m->vcache = calloc((size_t)(na ? na : 1) * T * kvd, sizeof(float));
    m->ccache = calloc((size_t)(nc ? nc : 1) * T * d, sizeof(float));
    m->x = malloc(C * d * sizeof(float));
    m->h = malloc(C * d * sizeof(float));
    m->att = malloc(C * d * sizeof(float));
    m->qkv = malloc(C * 3 * d * sizeof(float)); /* q + k + v ryms, liksom faltningens B, C, x */
    m->ff = malloc(C * m->ffdim * sizeof(float));
    m->ff2 = malloc(C * m->ffdim * sizeof(float));
    m->logits = malloc((size_t)m->vocab * sizeof(float));
    m->scores = malloc(C * H * (size_t)T * sizeof(float));
    m->rope_cos = malloc((size_t)T * h2 * sizeof(float));
    m->rope_sin = malloc((size_t)T * h2 * sizeof(float));
    if (!m->kcache || !m->vcache || !m->ccache || !m->x || !m->h || !m->att || !m->qkv || !m->ff || !m->ff2 ||
        !m->logits || !m->scores || !m->rope_cos || !m->rope_sin) {
        lm_free(m); snprintf(err, errlen, "för lite minne"); return NULL;
    }
    /* RoPE som i referensen: frekvenserna i float32, vinkeln pos · frekvens i float32. */
    for (int i = 0; i < h2; i++) {
        const float inv = 1.0f / powf(m->rope_theta, (float)(2 * i) / (float)hdim);
        for (int p = 0; p < T; p++) {
            const float a = (float)p * inv;
            m->rope_cos[(size_t)p * h2 + i] = (float)cos((double)a);
            m->rope_sin[(size_t)p * h2 + i] = (float)sin((double)a);
        }
    }
    return m;
}

static void rmsnorm(float *o, const float *x, const float *w, int n, float eps) {
    float ss = 0;
    for (int i = 0; i < n; i++) ss += x[i] * x[i];
    const float inv = 1.0f / sqrtf(ss / n + eps);
    for (int i = 0; i < n; i++) o[i] = w[i] * (x[i] * inv);
}

/* RoPE med rotate_half: första och andra halvan av huvudet bildar paren. */
static void rope(float *v, const float *c, const float *s, int hd) {
    const int h2 = hd / 2;
    for (int i = 0; i < h2; i++) {
        const float a = v[i], b = v[i + h2];
        v[i] = a * c[i] - b * s[i];
        v[i + h2] = b * c[i] + a * s[i];
    }
}

static float silu(float x) { return x / (1.0f + expf(-x)); }

/* Matar in n tokens i bitar om LFM_CHUNK. Med all != NULL skrivs logits för varje position dit. */
static int eval_lfm(LM *m, const int32_t *toks, int n, float *all) {
    const int d = m->d, H = m->heads, KV = m->kv_heads, hd = d / H, kvd = KV * hd, T = m->ctx;
    const int L = m->conv_L, F = m->ffdim, V = m->vocab, grp = H / KV, h2 = hd / 2;
    const float inv_sqrt = 1.0f / sqrtf((float)hd);
    if (n <= 0 || m->pos + n > T) return -1;
    for (int i = 0; i < n; i++) if (toks[i] < 0 || toks[i] >= V) return -2;
    const int CH = LFM_CHUNK < T ? LFM_CHUNK : T;
    float *x = m->x, *h = m->h;
    int c = 0;
    for (int start = 0; start < n; start += CH) {
        c = n - start < CH ? n - start : CH;
        const int p0 = m->pos;
        for (int i = 0; i < c; i++) {
            const int t = toks[start + i];
            float *xi = x + (size_t)i * d;
            if (m->wte.quant && m->wte.gs) {
                const int8_t *q = m->wte.q + (size_t)t * d;
                const float *sc = m->wte.scale + (size_t)t * (d / m->wte.gs);
                for (int k = 0; k < d; k++) xi[k] = q[k] * sc[k / m->wte.gs];
            } else if (m->wte.quant) {
                const int8_t *q = m->wte.q + (size_t)t * d;
                const float sc = m->wte.scale[t];
                for (int k = 0; k < d; k++) xi[k] = q[k] * sc;
            } else {
                memcpy(xi, m->wte.f + (size_t)t * d, d * sizeof(float));
            }
        }
        for (int l = 0; l < m->layers; l++) {
            const LfmLayer *y = &m->F[l];
            for (int i = 0; i < c; i++) rmsnorm(h + (size_t)i * d, x + (size_t)i * d, y->norm1, d, m->eps);
            if (y->attn) {
                float *K = m->kcache + (size_t)y->slot * T * kvd, *Vc = m->vcache + (size_t)y->slot * T * kvd;
                float *q = m->qkv, *kb = q + (size_t)c * d, *vb = kb + (size_t)c * kvd;
                matmul(q, h, c, &y->q, NULL);
                matmul(kb, h, c, &y->k, NULL);
                matmul(vb, h, c, &y->v, NULL);
                for (int i = 0; i < c; i++) {
                    const int pos = p0 + i;
                    const float *cs = m->rope_cos + (size_t)pos * h2, *sn = m->rope_sin + (size_t)pos * h2;
                    for (int a = 0; a < H; a++) {
                        float *v = q + (size_t)i * d + a * hd;
                        rmsnorm(v, v, y->qn, hd, m->eps);
                        rope(v, cs, sn, hd);
                    }
                    for (int a = 0; a < KV; a++) {
                        float *v = kb + (size_t)i * kvd + a * hd;
                        rmsnorm(v, v, y->kn, hd, m->eps);
                        rope(v, cs, sn, hd);
                    }
                    memcpy(K + (size_t)pos * kvd, kb + (size_t)i * kvd, kvd * sizeof(float));
                    memcpy(Vc + (size_t)pos * kvd, vb + (size_t)i * kvd, kvd * sizeof(float));
                }
                #pragma omp parallel for collapse(2) schedule(dynamic)
                for (int i = 0; i < c; i++) {
                    for (int a = 0; a < H; a++) {
                        const float *qv = q + (size_t)i * d + a * hd;
                        const int kvh = a / grp, last = p0 + i;
                        float *sc = m->scores + ((size_t)i * H + a) * T;
                        float mx = -1e30f;
                        for (int j = 0; j <= last; j++) {
                            const float *kv = K + (size_t)j * kvd + kvh * hd;
                            float s = 0;
                            #pragma omp simd reduction(+:s)
                            for (int e = 0; e < hd; e++) s += qv[e] * kv[e];
                            s *= inv_sqrt;
                            sc[j] = s;
                            if (s > mx) mx = s;
                        }
                        float sum = 0;
                        for (int j = 0; j <= last; j++) { sc[j] = expf(sc[j] - mx); sum += sc[j]; }
                        float *o = m->att + (size_t)i * d + a * hd;
                        for (int e = 0; e < hd; e++) o[e] = 0;
                        for (int j = 0; j <= last; j++) {
                            const float pj = sc[j] / sum;
                            const float *vv = Vc + (size_t)j * kvd + kvh * hd;
                            for (int e = 0; e < hd; e++) o[e] += pj * vv[e];
                        }
                    }
                }
                matmul(h, m->att, c, &y->o, NULL);
            } else {
                /* Kort faltning: in_proj ger B, C och x; B·x faltas kausalt och multipliceras med C. */
                float *Cc = m->ccache + (size_t)y->slot * T * d, *bcx = m->qkv;
                matmul(bcx, h, c, &y->in, NULL);
                for (int i = 0; i < c; i++) {
                    const float *B = bcx + (size_t)i * 3 * d, *X = B + 2 * d;
                    float *dst = Cc + (size_t)(p0 + i) * d;
                    for (int k = 0; k < d; k++) dst[k] = B[k] * X[k];
                }
                for (int i = 0; i < c; i++) {
                    const int pos = p0 + i;
                    const float *Cg = bcx + (size_t)i * 3 * d + d;
                    float *o = m->att + (size_t)i * d;
                    for (int k = 0; k < d; k++) {
                        float s = 0;
                        for (int t = 0; t < L; t++) {
                            const int pp = pos - (L - 1) + t;
                            if (pp >= 0) s += y->convw[(size_t)k * L + t] * Cc[(size_t)pp * d + k];
                        }
                        o[k] = Cg[k] * s;
                    }
                }
                matmul(h, m->att, c, &y->out, NULL);
            }
            for (size_t k = 0; k < (size_t)c * d; k++) x[k] += h[k];
            for (int i = 0; i < c; i++) rmsnorm(h + (size_t)i * d, x + (size_t)i * d, y->norm2, d, m->eps);
            matmul(m->ff, h, c, &y->w1, NULL);
            matmul(m->ff2, h, c, &y->w3, NULL);
            for (size_t k = 0; k < (size_t)c * F; k++) m->ff[k] = silu(m->ff[k]) * m->ff2[k];
            matmul(h, m->ff, c, &y->w2, NULL);
            for (size_t k = 0; k < (size_t)c * d; k++) x[k] += h[k];
        }
        m->pos = p0 + c;
        if (all) {
            for (int i = 0; i < c; i++) rmsnorm(h + (size_t)i * d, x + (size_t)i * d, m->lnf_w, d, m->eps);
            matmul(all + (size_t)start * V, h, c, &m->wte, NULL);
        }
    }
    if (all) {
        memcpy(m->logits, all + (size_t)(n - 1) * V, (size_t)V * sizeof(float));
    } else {
        rmsnorm(h, x + (size_t)(c - 1) * d, m->lnf_w, d, m->eps);
        matmul(m->logits, h, 1, &m->wte, NULL); /* delade vikter med inbäddningen */
    }
    return 0;
}

/* Matar in n tokens efter det som redan finns i cachen. Returnerar 0, eller -1 om kontexten tar slut. */
EXPORT int lm_eval(LM *m, const int32_t *toks, int n) {
    if (m->arch == 1) return eval_lfm(m, toks, n, NULL);
    const int d = m->d, H = m->heads, hd = d / H, T = m->ctx, p0 = m->pos;
    if (n <= 0 || p0 + n > T) return -1;
    for (int i = 0; i < n; i++) {
        int t = toks[i];
        if (t < 0 || t >= m->vocab) return -2;
        float *x = m->x + (size_t)i * d;
        const float *pe = m->wpe + (size_t)(p0 + i) * d;
        if (m->wte.quant) {
            const int8_t *q = m->wte.q + (size_t)t * d;
            float s = m->wte.scale[t];
            for (int k = 0; k < d; k++) x[k] = q[k] * s + pe[k];
        } else {
            const float *e = m->wte.f + (size_t)t * d;
            for (int k = 0; k < d; k++) x[k] = e[k] + pe[k];
        }
    }
    const float inv_sqrt = 1.0f / sqrtf((float)hd);
    for (int l = 0; l < m->layers; l++) {
        Layer *y = &m->L[l];
        float *K = m->kcache + (size_t)l * T * d, *V = m->vcache + (size_t)l * T * d;
        for (int i = 0; i < n; i++) layernorm(m->h + (size_t)i * d, m->x + (size_t)i * d, y->ln1_w, y->ln1_b, d);
        matmul(m->qkv, m->h, n, &y->qkv, y->qkv_b);
        for (int i = 0; i < n; i++) {
            memcpy(K + (size_t)(p0 + i) * d, m->qkv + (size_t)i * 3 * d + d, d * sizeof(float));
            memcpy(V + (size_t)(p0 + i) * d, m->qkv + (size_t)i * 3 * d + 2 * d, d * sizeof(float));
        }
        #pragma omp parallel for collapse(2) schedule(dynamic)
        for (int i = 0; i < n; i++) {
            for (int h = 0; h < H; h++) {
                const float *q = m->qkv + (size_t)i * 3 * d + h * hd;
                float *sc = m->scores + ((size_t)i * H + h) * T;
                const int last = p0 + i;
                float mx = -1e30f;
                for (int j = 0; j <= last; j++) {
                    const float *k = K + (size_t)j * d + h * hd;
                    float s = 0;
                    #pragma omp simd reduction(+:s)
                    for (int c = 0; c < hd; c++) s += q[c] * k[c];
                    s *= inv_sqrt;
                    sc[j] = s;
                    if (s > mx) mx = s;
                }
                float sum = 0;
                for (int j = 0; j <= last; j++) { sc[j] = expf(sc[j] - mx); sum += sc[j]; }
                float *o = m->att + (size_t)i * d + h * hd;
                for (int c = 0; c < hd; c++) o[c] = 0;
                for (int j = 0; j <= last; j++) {
                    const float p = sc[j] / sum;
                    const float *v = V + (size_t)j * d + h * hd;
                    for (int c = 0; c < hd; c++) o[c] += p * v[c];
                }
            }
        }
        matmul(m->h, m->att, n, &y->proj, y->proj_b);
        for (size_t k = 0; k < (size_t)n * d; k++) m->x[k] += m->h[k];
        for (int i = 0; i < n; i++) layernorm(m->h + (size_t)i * d, m->x + (size_t)i * d, y->ln2_w, y->ln2_b, d);
        matmul(m->ff, m->h, n, &y->fc, y->fc_b);
        for (size_t k = 0; k < (size_t)n * 4 * d; k++) m->ff[k] = gelu(m->ff[k], m->gelu_tanh);
        matmul(m->h, m->ff, n, &y->out, y->out_b);
        for (size_t k = 0; k < (size_t)n * d; k++) m->x[k] += m->h[k];
    }
    layernorm(m->h, m->x + (size_t)(n - 1) * d, m->lnf_w, m->lnf_b, d);
    matmul(m->logits, m->h, 1, &m->wte, NULL); /* delade vikter med inbäddningen */
    m->pos = p0 + n;
    return 0;
}

/* Som lm_eval, men skriver logits för varje inmatad position till out[n][vocab].
 * Används för att kontrollera flera föreslagna tokens i ett enda pass: vikterna läses en gång
 * för alla n tokens, vilket är det som kostar på en telefon. */
EXPORT int lm_eval_all(LM *m, const int32_t *toks, int n, float *out) {
    if (m->arch == 1) return eval_lfm(m, toks, n, out);
    const int rc = lm_eval(m, toks, n);
    if (rc != 0) return rc;
    const int d = m->d;
    for (int i = 0; i < n; i++) layernorm(m->h + (size_t)i * d, m->x + (size_t)i * d, m->lnf_w, m->lnf_b, d);
    matmul(out, m->h, n, &m->wte, NULL);
    memcpy(m->logits, out + (size_t)(n - 1) * m->vocab, (size_t)m->vocab * sizeof(float));
    return 0;
}

/* ---------------------------------------------------------------- sampling */
static uint64_t xorshift(uint64_t *s) {
    uint64_t x = *s ? *s : 0x9E3779B97F4A7C15ULL;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return *s = x;
}

static int cmp_desc(const void *a, const void *b) {
    float fa = *(const float *)a, fb = *(const float *)b;
    return (fa < fb) - (fa > fb);
}

/* Väljer nästa token ur senaste logits. temperature <= 0 ger det mest sannolika. */
EXPORT int lm_sample(LM *m, float temperature, int top_k, const int32_t *banned, int nbanned, uint64_t *rng) {
    const int V = m->vocab;
    float *lg = m->logits;
    for (int i = 0; i < nbanned; i++)
        if (banned[i] >= 0 && banned[i] < V) lg[banned[i]] = -INFINITY;
    int best = 0;
    for (int i = 1; i < V; i++) if (lg[i] > lg[best]) best = i;
    if (temperature <= 1e-6f) return best;
    float cutoff = -INFINITY;
    if (top_k > 0 && top_k < V) {
        float *tmp = malloc(V * sizeof(float));
        memcpy(tmp, lg, V * sizeof(float));
        qsort(tmp, V, sizeof(float), cmp_desc);
        cutoff = tmp[top_k - 1];
        free(tmp);
    }
    double sum = 0;
    const float mx = lg[best];
    for (int i = 0; i < V; i++) sum += (lg[i] >= cutoff && lg[i] > -INFINITY) ? exp((lg[i] - mx) / temperature) : 0.0;
    double r = (double)(xorshift(rng) >> 11) / 9007199254740992.0 * sum;
    for (int i = 0; i < V; i++) {
        if (lg[i] < cutoff || lg[i] == -INFINITY) continue;
        r -= exp((lg[i] - mx) / temperature);
        if (r <= 0) return i;
    }
    return best;
}
