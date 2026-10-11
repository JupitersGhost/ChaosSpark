#ifndef CF_PAIR_H
#define CF_PAIR_H
#include "cf_core.h"
#define CF_PAIR_LAGS 7u
extern const int cf_pair_lags[CF_PAIR_LAGS];
typedef struct {
    uint32_t n;
    uint64_t end_us, max_skew_us;
    double mean_skew_us, correlation[CF_PAIR_LAGS];
    bool valid[CF_PAIR_LAGS];
} cf_pair_report;
typedef struct {
    cf_pair_report last;
    uint16_t a[32], b[32];
    unsigned n, pos;
    uint64_t skew_sum, skew_max;
    uint64_t x[CF_PAIR_LAGS], y[CF_PAIR_LAGS];
    uint64_t xx[CF_PAIR_LAGS], yy[CF_PAIR_LAGS], xy[CF_PAIR_LAGS];
    uint32_t pairs[CF_PAIR_LAGS];
} cf_pair;
/* Signed lag: GPIO35[n] versus GPIO34[n-lag]. Diagnostic, not independence. */
void cf_pair_push(cf_pair *p, uint16_t a, uint16_t b, uint64_t ta, uint64_t tb);
void cf_pair_gap(cf_pair *p);
#endif
