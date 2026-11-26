/*
 * lmengine – liten inferensmotor för Lennart-modellerna (GPT, decoder-only) på telefonen.
 *
 * Läser en .lmod-fil (skapas av tools/exportera_mobil.py) med mmap, kör framåtpass med KV-cache
 * och samplar nästa token. Stöder båda varianterna i AI Control Center:
 *   - panelens GPT (Lennart, Lennart 2): bias i linjära lager, exakt GELU
 *   - Lennart 3-formatet (Lennart 3, 3.1): utan bias, GELU med tanh
 * Vikterna kan vara float32 eller int8 med en skalfaktor per rad. Beräkningen parallelliseras med OpenMP.
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
    int quant;            /* 0 = float32, 1 = int8 + skala per rad */
    int rows, cols;
    const float *f;       /* float32-vikter */
    const int8_t *q;      /* int8-vikter */
    const float *scale;   /* skala per rad */
} Mat;

typedef struct {
    const float *ln1_w, *ln1_b, *ln2_w, *ln2_b;
    Mat qkv, proj, fc, out;
    const float *qkv_b, *proj_b, *fc_b, *out_b; /* NULL utan bias */
} Layer;

typedef struct LM {
    int vocab, d, layers, heads, ctx, has_bias, gelu_tanh, quant;
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
    Mat w = {m->quant, rows, cols, NULL, NULL, NULL};
    if (m->quant) {
        w.q = (const int8_t *)((const char *)m->map + take(off, (size_t)rows * cols));
        w.scale = take_f(m, off, rows);
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
    free(m->L); free(m->kcache); free(m->vcache);
    free(m->x); free(m->h); free(m->qkv); free(m->att); free(m->ff); free(m->logits); free(m->scores);
    free(m);
}

static LM *load_from(void *map, size_t fsize, int owned, char *err, int errlen);

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
    /* hd[0]=version, vocab, d, layers, heads, ctx, has_bias, gelu_tanh, quant */
    m->vocab = hd[1]; m->d = hd[2]; m->layers = hd[3]; m->heads = hd[4]; m->ctx = hd[5];
    m->has_bias = hd[6]; m->gelu_tanh = hd[7]; m->quant = hd[8];
    int d = m->d;
    if (hd[0] != 1 || d <= 0 || d % m->heads || m->ctx <= 0 || m->vocab <= 0) {
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
    out[5] = m->quant; out[6] = m->has_bias;
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
            if (W->quant) {
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

/* Matar in n tokens efter det som redan finns i cachen. Returnerar 0, eller -1 om kontexten tar slut. */
EXPORT int lm_eval(LM *m, const int32_t *toks, int n) {
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
