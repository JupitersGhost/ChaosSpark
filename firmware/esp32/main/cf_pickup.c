#include "cf_pickup.h"
#include <assert.h>
#include <math.h>
#include <string.h>
const unsigned cf_lags[CF_LAGS]={1,2,4,8,16,32};
static void finish_run(cf_pickup *p) {
    unsigned b=0, n=p->run;
    while(n>1 && b<CF_DWELL_BINS-1) { n>>=1; b++; }
    p->current.dwell[p->state][b]++;
    if(p->run>p->current.longest_run[p->state]) p->current.longest_run[p->state]=p->run;
}
void cf_pickup_push(cf_pickup *p, uint16_t value, uint64_t now, bool scanning) {
    assert(value<4096);
    cf_pickup_report *r=&p->current;
    unsigned state=value<=8?0:(value>=4087?2:1);
    if(r->n) {
        r->transitions[p->state][state]++;
        if(state==p->state) p->run++;
        else { finish_run(p); p->run=1; }
        uint64_t dt=now>=p->previous_us?now-p->previous_us:0;
        if(!r->interval_n || dt<r->interval_min_us) r->interval_min_us=dt;
        if(dt>r->interval_max_us) r->interval_max_us=dt;
        p->interval_sum+=dt; r->interval_n++;
        p->abs_delta_sum+=value>p->previous?value-p->previous:p->previous-value;
    } else p->run=1;
    p->state=state; p->previous=value; p->previous_us=now;
    r->states[state]++; r->scan_n[scanning]++; p->scan_sum[scanning]+=value;
    if(state!=1) r->scan_rail[scanning]++;
    for(unsigned k=0;k<CF_LAGS;k++) if(p->have>=cf_lags[k]) {
        uint64_t x=p->ring[(p->pos+32-cf_lags[k])%32], y=value;
        p->x[k]+=x; p->y[k]+=y; p->xx[k]+=x*x; p->yy[k]+=y*y; p->xy[k]+=x*y; p->pairs[k]++;
    }
    p->ring[p->pos]=value; p->pos=(p->pos+1)%32;
    if(p->have<32) p->have++;
    if(++r->n!=CF_WINDOW) return;
    finish_run(p); r->end_us=now;
    r->interval_mean_us=(double)p->interval_sum/r->interval_n;
    r->mean_abs_delta=(double)p->abs_delta_sum/r->interval_n;
    for(unsigned k=0;k<CF_LAGS;k++) {
        double n=p->pairs[k], x=p->x[k], y=p->y[k];
        double vx=n*p->xx[k]-x*x, vy=n*p->yy[k]-y*y;
        r->lag_valid[k]=vx>0 && vy>0;
        if(r->lag_valid[k]) r->lag_correlation[k]=fmax(-1,fmin(1,(n*p->xy[k]-x*y)/sqrt(vx*vy)));
    }
    double dp[3], next[3], prob[3][3];
    for(unsigned a=0;a<3;a++) {
        dp[a]=(double)r->states[a]/r->n;
        double total=r->transitions[a][0]+r->transitions[a][1]+r->transitions[a][2];
        for(unsigned b=0;b<3;b++) prob[a][b]=total?r->transitions[a][b]/total:0;
    }
    for(unsigned i=1;i<128;i++) {
        for(unsigned b=0;b<3;b++) {
            next[b]=0;
            for(unsigned a=0;a<3;a++) next[b]=fmax(next[b],dp[a]*prob[a][b]);
        }
        memcpy(dp,next,sizeof(dp));
    }
    double path=fmax(dp[0],fmax(dp[1],dp[2]));
    r->state_markov128=path>0?-log2(path)/128:0;
    for(unsigned i=0;i<2;i++) if(r->scan_n[i]) r->scan_mean[i]=(double)p->scan_sum[i]/r->scan_n[i];
    /* Copy aggregates before erasing the raw ring and working accumulators. */
    p->last=*r;
    cf_wipe(p,offsetof(cf_pickup,last));
    cf_wipe((uint8_t *)p+offsetof(cf_pickup,ring),sizeof(*p)-offsetof(cf_pickup,ring));
}
