/* zf_tajweed.h: TajweedFormer V4 in the exact engine. API version 1.
 *
 * One header for the SDKs (Swift, Kotlin through JNI, WebAssembly): open the model folder, stream
 * audio through the exact engine, keep every head the network has, and score a recitation of a
 * known ayah against its expected tj3 sequence with the calibrated tajweed checks.
 *
 *   ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
 *   ZfTajweedModel *m = zf_tajweed_model_open("sdk/v4.0", &o, &err);   context NULL: the default
 *   ZfTajweedStream *s = zf_tajweed_stream_create(m, &err);
 *   zf_tajweed_stream_push_audio(s, samples, n);                         as audio arrives
 *   zf_tajweed_stream_finish(s);                                         end of the take
 *   ZfTajweedHeads h; zf_tajweed_stream_heads(s, &h);
 *   ZfTajweedConfig *c = zf_tajweed_config_create(m);
 *   zf_tajweed_config_set_remote(c, remote_json, len);                   portal block, optional
 *   ZfTajweedResult *r = zf_tajweed_score(m, c, &h, surah, ayah, &err);
 *   const char *json = zf_tajweed_result_json(r);                        or the typed accessors
 *
 * The model folder (sdk/v4.0):
 *   calibration.json          thresholds, presets, madd cuts (quranlab.tajweed-calibration/1)
 *   tokens.txt                tj3, 38 entries, blank 0
 *   expected_tj3.zfx          the expected sequence of every ayah (tools/zfexpected.py)
 *   <context>/                one folder per shipped context (c16_l64, c24_l72): model_engine2.onnx,
 *                             model_engine2.onnx.zfg, model_engine2.onnx.zfg.bin, frontend.zfw,
 *                             layers.zfw
 *
 * Exactness: the heads are the same bits, chunk by chunk, as ONNX Runtime's int8 reference on the
 * same graph (the engine's definition of exact). The scorer is double precision with fixed
 * summation order, so the same heads give the same verdicts on every platform.
 *
 * Threads: a model is immutable after open and may be shared by any number of threads. A stream,
 * a config and a result belong to one thread at a time. Only one stream may be live per process
 * (the engine's rule, zf/stream.h); scoring needs no stream and may run anywhere.
 *
 * Every function that returns a pointer returns NULL on failure and, when `error` is not NULL,
 * sets it to a static message. Every count-returning function returns -1 on failure.
 *
 * This header is frozen for API version 1: structs and enums are only ever appended to under a new
 * ZF_TAJWEED_API_VERSION, and the struct_size fields say which version a caller was built against.
 *
 * API version 2 (additive; every API 1 declaration unchanged): zf_tajweed_config_set_backend (which
 * calibration backend_overrides apply), the features "madd", "qalqalah" and "gemination" in
 * zf_tajweed_config_set_class_preset / _clear_class and under the remote block's "overrides" (a preset
 * only), and resolution exactly as the shared settings rules (zf_tajweed_config_json gives
 * its output layout, with "dropped" and "refused"). */
#ifndef ZF_TAJWEED_H
#define ZF_TAJWEED_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(ZF_TAJWEED_BUILD_DLL)
#define ZF_TAJWEED_API __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#define ZF_TAJWEED_API __attribute__((visibility("default")))
#else
#define ZF_TAJWEED_API
#endif

#define ZF_TAJWEED_API_VERSION 2
/* The vocabulary: tj3, 38 tokens, blank 0 (tokens.txt). */
#define ZF_TAJWEED_VOCAB 38
#define ZF_TAJWEED_BLANK 0

/* ---------------------------------------------------------------------------------------------
 * Names. Every name below is also accepted and returned as the string in calibration.json and in
 * the portal's tajweed block (calibration.json and the portal's tajweed block).
 * ------------------------------------------------------------------------------------------- */

/* Site classes: single-unit alternatives scored by CTC forward LLR. Indexes into
 * calibration.json's "classes", in this order. */
typedef enum {
  ZF_TJ_VOWEL_SUB = 0,      /* "vowel_sub": a / i / u swapped */
  ZF_TJ_VOWEL_DEL = 1,      /* "vowel_del": a short vowel dropped (sukun said) */
  ZF_TJ_VOWEL_INS = 2,      /* "vowel_ins": a short vowel added after a sakin letter */
  ZF_TJ_SHORT_TO_LONG = 3,  /* "short_to_long": a short vowel said long */
  ZF_TJ_LONG_TO_SHORT = 4,  /* "long_to_short": a long vowel said short */
  ZF_TJ_CONS_SUB = 5,       /* "cons_sub": a consonant swapped for a confusable one */
  ZF_TJ_CONS_DEL = 6,       /* "cons_del": a consonant dropped */
  ZF_TJ_INSERTION = 7,      /* "insertion": a unit added */
  ZF_TJ_CLASS_COUNT = 8
} ZfTajweedClass;

/* Checks the app or the portal turns on and off (the "checks" object). Each class belongs to one
 * check: letters = cons_sub, cons_del, insertion; vowels = vowel_sub, vowel_del, vowel_ins;
 * length = short_to_long, long_to_short. madd, gemination, qalqalah and lazim are their own. */
typedef enum {
  ZF_TJ_CHECK_LETTERS = 0,    /* "letters" */
  ZF_TJ_CHECK_VOWELS = 1,     /* "vowels" */
  ZF_TJ_CHECK_LENGTH = 2,     /* "length" */
  ZF_TJ_CHECK_MADD = 3,       /* "madd": madd counts from the timing head (fixed2, muttasil, free) */
  ZF_TJ_CHECK_GEMINATION = 4, /* "gemination": shadda held */
  ZF_TJ_CHECK_QALQALAH = 5,   /* "qalqalah": the release burst present */
  ZF_TJ_CHECK_LAZIM = 6,      /* "lazim": madd lazim counts */
  ZF_TJ_CHECK_COUNT = 7
} ZfTajweedCheck;

/* Presets: "strict", "balanced", "sensitive", "very_sensitive". */
typedef enum {
  ZF_TJ_PRESET_STRICT = 0,
  ZF_TJ_PRESET_BALANCED = 1,
  ZF_TJ_PRESET_SENSITIVE = 2,
  ZF_TJ_PRESET_VERY_SENSITIVE = 3,
  ZF_TJ_PRESET_COUNT = 4
} ZfTajweedPreset;

/* calibration.json's status of a class or check. OFF is reported only in a debug build whose app
 * turned it on explicitly; EXPERIMENTAL is off unless the app or the portal turns it on. */
typedef enum {
  ZF_TJ_STATUS_OFF = 0,
  ZF_TJ_STATUS_EXPERIMENTAL = 1,
  ZF_TJ_STATUS_VALIDATED = 2
} ZfTajweedStatus;

/* Where an effective setting came from. Precedence: app code > remote config > calibration. */
typedef enum {
  ZF_TJ_SOURCE_CALIBRATION = 0,
  ZF_TJ_SOURCE_REMOTE = 1,
  ZF_TJ_SOURCE_APP = 2
} ZfTajweedSource;

/* Madd classes of the expected table and calibration.json's "madd.cuts". */
typedef enum {
  ZF_TJ_MADD_NONE = 0,
  ZF_TJ_MADD_FIXED2 = 1,   /* "fixed2": tabee'i, badal, ewad, ... */
  ZF_TJ_MADD_MUTTASIL = 2, /* "muttasil" */
  ZF_TJ_MADD_FREE = 3,     /* "free": munfasil, aared, silah kubra */
  ZF_TJ_MADD_LAZIM = 4     /* "lazim" */
} ZfTajweedMaddClass;

/* Name <-> value. Unknown names give -1; out-of-range values give NULL. */
ZF_TAJWEED_API const char *zf_tajweed_class_name(int cls);
ZF_TAJWEED_API int zf_tajweed_class_from_name(const char *name);
ZF_TAJWEED_API const char *zf_tajweed_check_name(int check);
ZF_TAJWEED_API int zf_tajweed_check_from_name(const char *name);
ZF_TAJWEED_API const char *zf_tajweed_preset_name(int preset);
ZF_TAJWEED_API int zf_tajweed_preset_from_name(const char *name);
ZF_TAJWEED_API const char *zf_tajweed_madd_class_name(int madd_class);
/* The check a class belongs to. */
ZF_TAJWEED_API int zf_tajweed_class_check(int cls);
/* "1.0.0"-style version of this library (the engine's), and ZF_TAJWEED_API_VERSION as built. */
ZF_TAJWEED_API const char *zf_tajweed_version(void);
ZF_TAJWEED_API int zf_tajweed_api_version(void);

/* ---------------------------------------------------------------------------------------------
 * The model
 * ------------------------------------------------------------------------------------------- */

typedef struct ZfTajweedModel ZfTajweedModel;

typedef struct {
  size_t struct_size;   /* sizeof(ZfTajweedOpenOptions) as the caller was built */
  const char *context;  /* "c16_l64", "c24_l72", or NULL for calibration.json's default_context */
  int load_engine;      /* 1 (default): the exact engine for this context, so streams can be made.
                           0: calibration, tokens and the expected table only, for scoring heads
                           that came from elsewhere (the Neural Engine, an NPU, a server) */
  int threads;          /* engine threads; 0 = the fast cores */
  int sample_rate;      /* the rate audio is pushed at: 0 or 16000, or 8000 .. 48000 through the
                           engine's resampler */
  int batch;            /* engine chunks run together (stored audio); 0 or 1 for live audio */
} ZfTajweedOpenOptions;

/* context NULL, load_engine 1, threads 0, sample_rate 0, batch 1. */
ZF_TAJWEED_API ZfTajweedOpenOptions zf_tajweed_open_default_options(void);

/* `model_dir` is the model folder (sdk/v4.0). Reads and checks calibration.json (format, model_id,
 * the context present), tokens.txt (38 entries, sha256 against calibration's tokens_sha256 when
 * given), the expected table, and with load_engine the context's engine files. */
ZF_TAJWEED_API ZfTajweedModel *zf_tajweed_model_open(const char *model_dir,
                                                     const ZfTajweedOpenOptions *options,
                                                     const char **error);
ZF_TAJWEED_API void zf_tajweed_model_close(ZfTajweedModel *m);

ZF_TAJWEED_API const char *zf_tajweed_model_id(const ZfTajweedModel *m);       /* "v4.0" */
ZF_TAJWEED_API const char *zf_tajweed_model_context(const ZfTajweedModel *m);  /* "c16_l64" */
/* The contexts calibration.json describes, 0 .. n-1; NULL past the end. */
ZF_TAJWEED_API const char *zf_tajweed_model_context_at(const ZfTajweedModel *m, int index);
ZF_TAJWEED_API const char *zf_tajweed_model_default_context(const ZfTajweedModel *m);
/* Audio per engine chunk in ms (320 for c16, 480 for c24); 0 without the engine. */
ZF_TAJWEED_API int zf_tajweed_model_chunk_ms(const ZfTajweedModel *m);
/* tokens.txt's entry for `id` ("blank", "|", "b", "aa", ...), NULL out of range. */
ZF_TAJWEED_API const char *zf_tajweed_token_name(const ZfTajweedModel *m, int id);

/* The expected table: ayahs in a surah (0 for an unknown surah), and an ayah's expected tj3 sequence
 * (the continuing form; pausal alternatives are the scorer's business). `tokens` points into the
 * model and stays valid until it is closed. Returns the token count, or -1. */
ZF_TAJWEED_API int zf_tajweed_ayah_count(const ZfTajweedModel *m, int surah);
ZF_TAJWEED_API int zf_tajweed_expected_tokens(const ZfTajweedModel *m, int surah, int ayah,
                                              const int **tokens);
/* Word index of every expected token ([n], 0-based, word boundaries "|" belong to the word before),
 * and the number of words. Returns the token count, or -1. */
ZF_TAJWEED_API int zf_tajweed_expected_words(const ZfTajweedModel *m, int surah, int ayah,
                                             const int **word_of_token, int *n_words);

/* ---------------------------------------------------------------------------------------------
 * Heads: what the network says, kept whole for the take
 * ------------------------------------------------------------------------------------------- */

/* Every output of the network after its states (README_heads.txt), row major, frames first.
 * Two frame rates: n40 frames at 40 ms and n20 = 2 x n40 frames at 20 ms, aligned (20 ms frame
 * 2k and 2k + 1 lie in 40 ms frame k). A pointer is NULL when a source does not provide that head;
 * the scorer needs log_probs, inter1_log_probs, timing_log_probs, gem and attr_qalqalah, and skips
 * the checks whose head is missing. */
typedef struct {
  int n40, n20;
  int vocab;                      /* 38 */
  const float *log_probs;         /* [n40, 38] final CTC, log-softmax */
  const float *inter1_log_probs;  /* [n40, 38] stack-1 InterCTC, log-softmax */
  const float *inter4_log_probs;  /* [n40, 38] stack-4 InterCTC, log-softmax (diagnostic) */
  const float *id_log_probs;      /* [n20, 38] identity CTC, log-softmax */
  const float *timing_log_probs;  /* [n20, 38] H-time chain, log-softmax; 0 = pause state */
  const float *gem;               /* [n20, 2] softmax: single, held */
  const float *attr_tafkheem;     /* [n20, 3] softmax: thin, heavy, low heavy */
  const float *attr_ghunna;       /* [n20, 5] softmax: none, plain, geminate, ikhfa, idgham */
  const float *attr_qalqalah;     /* [n20, 3] softmax: none, sughra, kubra */
  const float *attr_face;         /* [n20, 4] softmax: none, imala, tasheel, sakt */
  const float *boundary;          /* [n20] logit: a unit starts here */
  const float *conf;              /* [n20] logit: the frame's label is truthful */
} ZfTajweedHeads;

/* ---------------------------------------------------------------------------------------------
 * The stream: audio in, heads kept
 * ------------------------------------------------------------------------------------------- */

typedef struct ZfTajweedStream ZfTajweedStream;

/* Called after every engine chunk with that chunk's heads (n40 = 8 and n20 = 16 at c16; 12 and 24
 * at c24), valid only during the call. Optional. */
typedef void (*ZfTajweedChunkCallback)(void *user, const ZfTajweedHeads *chunk);

/* A stream over the model's engine (the model must have been opened with load_engine). */
ZF_TAJWEED_API ZfTajweedStream *zf_tajweed_stream_create(ZfTajweedModel *m, const char **error);
ZF_TAJWEED_API void zf_tajweed_stream_destroy(ZfTajweedStream *s);
ZF_TAJWEED_API void zf_tajweed_stream_set_callback(ZfTajweedStream *s, ZfTajweedChunkCallback cb,
                                                   void *user);
/* A new take: every cache and every kept head back to the start. */
ZF_TAJWEED_API void zf_tajweed_stream_reset(ZfTajweedStream *s);
/* Mono float samples in [-1, 1] at the open options' sample_rate. Returns the chunks run, or -1. */
ZF_TAJWEED_API int zf_tajweed_stream_push_audio(ZfTajweedStream *s, const float *samples, int n);
/* The end of the take: the 1.05 s flush the model is decoded with, and every chunk it completes.
 * Returns the chunks run, or -1. Reset before the next take. */
ZF_TAJWEED_API int zf_tajweed_stream_finish(ZfTajweedStream *s);
/* Every head of the take so far. The pointers stay valid until the next push, finish or reset. */
ZF_TAJWEED_API int zf_tajweed_stream_heads(const ZfTajweedStream *s, ZfTajweedHeads *out);
/* What the model heard: greedy CTC on log_probs, blanks and repeats removed (display only; make
 * decisions from the scorer). Writes at most `max` ids and returns how many there are in all. */
ZF_TAJWEED_API int zf_tajweed_stream_greedy(const ZfTajweedStream *s, int *ids, int max);
ZF_TAJWEED_API const char *zf_tajweed_stream_last_error(const ZfTajweedStream *s);

/* ---------------------------------------------------------------------------------------------
 * Configuration: calibration.json < portal (remote) < app code
 * ------------------------------------------------------------------------------------------- */

typedef struct ZfTajweedConfig ZfTajweedConfig;

/* A config holding the model's calibration defaults and no remote or app settings. */
ZF_TAJWEED_API ZfTajweedConfig *zf_tajweed_config_create(const ZfTajweedModel *m);
ZF_TAJWEED_API void zf_tajweed_config_destroy(ZfTajweedConfig *c);

/* The portal's block: either the "tajweed" object itself or a whole /v1/config
 * document holding one. Replaces the previous remote layer; NULL or an absent block clears it.
 * Validation: preset one of the four; an override has exactly one of "preset" or
 * "threshold" (finite, -20..20); checks only known keys with boolean values; context only one the
 * calibration names; unknown keys dropped; an invalid field is dropped, never the whole block.
 * Returns the number of fields dropped (0 when everything was taken), or -1 when the text is not
 * JSON (the remote layer is then cleared). */
ZF_TAJWEED_API int zf_tajweed_config_set_remote(ZfTajweedConfig *c, const char *json, size_t len);

/* App code: each wins over remote and calibration. Passing NULL (or -1 for set_check) removes the
 * app's setting so the lower layers show through. Return 0, or -1 for an unknown name or a value
 * out of range (nothing changes). */
ZF_TAJWEED_API int zf_tajweed_config_set_preset(ZfTajweedConfig *c, const char *preset);
ZF_TAJWEED_API int zf_tajweed_config_set_class_preset(ZfTajweedConfig *c, const char *cls,
                                                      const char *preset);
ZF_TAJWEED_API int zf_tajweed_config_set_class_threshold(ZfTajweedConfig *c, const char *cls,
                                                         double threshold);
ZF_TAJWEED_API int zf_tajweed_config_clear_class(ZfTajweedConfig *c, const char *cls);
ZF_TAJWEED_API int zf_tajweed_config_set_check(ZfTajweedConfig *c, const char *check, int on);
ZF_TAJWEED_API int zf_tajweed_config_set_context(ZfTajweedConfig *c, const char *context);
/* Forget every app setting. */
ZF_TAJWEED_API void zf_tajweed_config_clear_app(ZfTajweedConfig *c);
/* 1 when the app is a debug build: only then can the app (never the portal) turn on a check or a
 * class whose calibration status is "off". Default 0. */
ZF_TAJWEED_API void zf_tajweed_config_set_debug_build(ZfTajweedConfig *c, int debug_build);

/* API 2. The heads' backend, for calibration.json's contexts[ctx].backend_overrides: "int8" (the exact
 * engine) or "fp32" (heads from the Neural Engine, an NPU or a server). NULL restores the default: "int8"
 * when the model was opened with the engine, "fp32" otherwise. Returns 0, or -1 for another name.
 * API 2 also lets zf_tajweed_config_set_class_preset and zf_tajweed_config_clear_class take "madd",
 * "qalqalah" and "gemination" (the preset picks madd's preset_cuts and their preset_tau);
 * zf_tajweed_config_set_class_threshold refuses those three. In the remote block, "v" must be 1 or the
 * whole block is ignored. */
ZF_TAJWEED_API int zf_tajweed_config_set_backend(ZfTajweedConfig *c, const char *backend);

/* The effective settings, resolved. */
typedef struct {
  int preset;                               /* ZF_TJ_PRESET_*: the global preset in force */
  int preset_source;                        /* ZF_TJ_SOURCE_* */
  int class_enabled[ZF_TJ_CLASS_COUNT];     /* 1 when the class is scored and can flag */
  int class_status[ZF_TJ_CLASS_COUNT];      /* ZF_TJ_STATUS_* from calibration */
  double class_threshold[ZF_TJ_CLASS_COUNT];/* the fused-LLR cut in force */
  int class_source[ZF_TJ_CLASS_COUNT];      /* where the threshold came from */
  int check_enabled[ZF_TJ_CHECK_COUNT];
  int check_status[ZF_TJ_CHECK_COUNT];
  int check_source[ZF_TJ_CHECK_COUNT];
  char context[16];                         /* the context asked for (app > remote > default); the
                                               scorer always uses its model's own context */
  int context_source;
} ZfTajweedEffective;
ZF_TAJWEED_API int zf_tajweed_config_effective(const ZfTajweedConfig *c, ZfTajweedEffective *out);
/* The same as JSON, with each value's source; valid until the config changes or is destroyed. */
ZF_TAJWEED_API const char *zf_tajweed_config_json(ZfTajweedConfig *c);

/* ---------------------------------------------------------------------------------------------
 * Scoring
 * ------------------------------------------------------------------------------------------- */

typedef struct ZfTajweedResult ZfTajweedResult;

/* One scored site: the expected unit at `pos`, the best single-unit alternative of its class, and
 * the per-head and fused LLRs (log P(alternative) - log P(expected), full-sequence CTC forward).
 * fused = a * llr_final + (1 - a) * llr_inter1, `a` from calibration's fusion. flagged = enabled
 * and fused > threshold. */
typedef struct {
  int cls;              /* ZF_TJ_* class */
  int status;           /* ZF_TJ_STATUS_* */
  int pos;              /* index into the expected tokens (an insertion: the unit it follows,
                           -1 at the start) */
  int word;             /* 0-based word of the ayah */
  int expected;         /* tj3 id expected at pos; -1 for an insertion */
  int alt;              /* tj3 id of the best alternative; -1 for a deletion */
  double llr_final;
  double llr_inter1;
  double llr;           /* fused */
  double threshold;     /* in force for this class */
  int flagged;
  int frame_lo, frame_hi; /* 40 ms frames the expected unit holds on the best path; -1 unknown */
} ZfTajweedSite;

/* One madd long vowel, counted from the timing head. */
typedef struct {
  int pos, word;
  int token;            /* aa, ii or uu */
  int madd_class;       /* ZF_TJ_MADD_* */
  int status;
  double ratio;         /* held frames / the take's median short-vowel frames */
  int count;            /* verdict count: 2, 4 or 6 from calibration's cuts */
  double display_count; /* the smooth display count (never for verdicts) */
  int allowed_lo, allowed_hi; /* counts the rule allows */
  int flagged;          /* count outside [allowed_lo, allowed_hi] and the check enabled */
  int frame_lo, frame_hi; /* 20 ms frames */
} ZfTajweedMadd;

/* A letter feature: qalqalah (mean P(burst) after the letter) or gemination (mean P(held) over the
 * letter). flagged = the feature is missing (score below threshold) and the check enabled. */
typedef struct {
  int pos, word;
  int token;
  int status;
  double score;
  double threshold;
  int flagged;
  int frame_lo, frame_hi; /* 20 ms frames read */
} ZfTajweedLetter;

typedef struct {
  int n_sites, n_flagged;
  int n_madd, n_madd_flagged;
  int n_qalqalah, n_qalqalah_flagged;
  int n_gemination, n_gemination_flagged;
  double short_vowel_frames; /* the madd unit: median short-vowel frames, 0 when too few */
  int madd_unit_ok;          /* enough short vowels (calibration's min_short_vowels) for counts */
} ZfTajweedSummary;

/* Score a take of surah:ayah (the whole ayah) with the config in force. The heads may come from
 * zf_tajweed_stream_heads or any other source with the same layout. */
ZF_TAJWEED_API ZfTajweedResult *zf_tajweed_score(const ZfTajweedModel *m, const ZfTajweedConfig *c,
                                                 const ZfTajweedHeads *heads, int surah, int ayah,
                                                 const char **error);
ZF_TAJWEED_API void zf_tajweed_result_free(ZfTajweedResult *r);

/* Arrays owned by the result, valid until it is freed. Each returns its count. */
ZF_TAJWEED_API int zf_tajweed_result_sites(const ZfTajweedResult *r, const ZfTajweedSite **sites);
ZF_TAJWEED_API int zf_tajweed_result_madd(const ZfTajweedResult *r, const ZfTajweedMadd **madd);
ZF_TAJWEED_API int zf_tajweed_result_qalqalah(const ZfTajweedResult *r, const ZfTajweedLetter **q);
ZF_TAJWEED_API int zf_tajweed_result_gemination(const ZfTajweedResult *r, const ZfTajweedLetter **g);
ZF_TAJWEED_API int zf_tajweed_result_summary(const ZfTajweedResult *r, ZfTajweedSummary *out);
/* The whole result as JSON (UTF-8, the reference scorer's verdict layout: "sites", "madd",
 * "qalqalah", "gemination", "summary", with class, check and token names spelled out), valid until
 * the result is freed. */
ZF_TAJWEED_API const char *zf_tajweed_result_json(ZfTajweedResult *r);

#ifdef __cplusplus
}
#endif
#endif /* ZF_TAJWEED_H */
