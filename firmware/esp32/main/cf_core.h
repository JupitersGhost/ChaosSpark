#ifndef CF_CORE_H
#define CF_CORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define CF_WINDOW 8192u
#define CF_APT_WINDOW 512u
#define CF_SOURCES 6u
#define CF_AUX_ADC 5u
#define CF_IS_ADC(id) ((id)==0u || (id)==CF_AUX_ADC)
#define CF_RNG 1u
#define CF_TIMING 2u

typedef struct { uint64_t a[25]; size_t pos; } cf_sha3;
void cf_sha3_init(cf_sha3 *s);
void cf_sha3_add(cf_sha3 *s, const void *data, size_t n);
void cf_sha3_final(cf_sha3 *s, uint8_t out[64]);
bool cf_sha3_selftest(void);
uint32_t cf_crc32(const void *data, size_t n);
void cf_wipe(void *p, size_t n);

typedef struct {
    uint32_t n, lo, hi, rail, max_run;
    double mean, shannon, mcv_plugin, markov_lsb_128_plugin, chi_square_uniform, lsb_ones_fraction;
} cf_metrics;

typedef struct {
    uint16_t *hist; unsigned alphabet, id, rct_cutoff, apt_cutoff;
    uint32_t run, apt_n, apt_hits, clean_windows, block_rail;
    uint32_t previous, reference;
    bool have_previous, block_bad, active;
    uint64_t samples, failures, blocks_ok, blocks_rejected, last_us, last_failure_us;
    uint64_t pending_blocks, rct_failures, apt_failures, clip_warning_blocks;
    uint64_t metrics_end_us, metrics_windows, discontinuities;
    bool clip_warning, pending_clip_warning;
    unsigned block_faults, last_faults;
    cf_sha3 block, pending;
    unsigned n, rail, window_run;
    uint32_t lo, hi;
    uint64_t sum;
    uint32_t trans[2][2], bit_count[2];
    unsigned last_bit;
    bool have_bit;
    cf_metrics metrics;
} cf_source;
void cf_source_init(cf_source *s, unsigned id, uint16_t *hist, unsigned alphabet);
void cf_source_fail(cf_source *s, uint64_t now);
void cf_source_push(cf_source *s, uint32_t value, uint64_t now);
/* Full cycle count drives health checks and hashing; histogram is low 12 bits. */
void cf_source_push_cycles(cf_source *s, uint32_t cycles, uint64_t now);
void cf_source_gap(cf_source *s, uint64_t now);
cf_metrics cf_source_preview(const cf_source *s);
void cf_source_discard(cf_source *s);
uint64_t cf_source_max_age(unsigned id);
void cf_source_expire(cf_source *s, uint64_t now);
/* Private RAM state is NEVER serialized or reused as the public output. */
typedef struct {
    uint8_t state[64];
    uint64_t updates, absorbed[CF_SOURCES], last_absorbed_us[CF_SOURCES];
    unsigned ever_mask;
} cf_pool;
void cf_pool_init(cf_pool *p, const uint8_t session[16]);
/* Require fresh accepted input on every emission; retain prior mixed influence. */
bool cf_output(cf_source s[CF_SOURCES], cf_pool *pool,
               const uint8_t session[16], uint64_t seq,
               uint64_t now, uint8_t out[64], uint64_t used[CF_SOURCES]);
#endif
