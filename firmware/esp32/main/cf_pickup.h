#ifndef CF_PICKUP_H
#define CF_PICKUP_H
#include "cf_core.h"
#define CF_LAGS 6u
#define CF_DWELL_BINS 8u
extern const unsigned cf_lags[CF_LAGS];
/* Aggregate measurements only. No individual samples or event times in report. */
typedef struct {
    uint32_t n, states[3], transitions[3][3], dwell[3][CF_DWELL_BINS];
    uint32_t longest_run[3], interval_n, scan_n[2], scan_rail[2];
    uint64_t end_us, interval_min_us, interval_max_us;
    double interval_mean_us, mean_abs_delta, state_markov128;
    double lag_correlation[CF_LAGS], scan_mean[2];
    bool lag_valid[CF_LAGS];
} cf_pickup_report;
typedef struct {
    cf_pickup_report current, last;
    uint16_t ring[32], previous;
    unsigned pos, have, state, run;
    uint64_t previous_us, interval_sum, abs_delta_sum, scan_sum[2];
    uint64_t x[CF_LAGS], y[CF_LAGS], xx[CF_LAGS], yy[CF_LAGS], xy[CF_LAGS];
    uint32_t pairs[CF_LAGS];
} cf_pickup;
void cf_pickup_push(cf_pickup *p, uint16_t value, uint64_t now, bool scanning);
#endif
