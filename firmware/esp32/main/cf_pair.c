#include "cf_pair.h"
#include <assert.h>
#include <math.h>
const int cf_pair_lags[CF_PAIR_LAGS]={-16,-8,-1,0,1,8,16};
void cf_pair_gap(cf_pair *p) {
    cf_pair_report last=p->last;
    cf_wipe(p,sizeof(*p)); p->last=last;
}
void cf_pair_push(cf_pair *p, uint16_t a, uint16_t b, uint64_t ta, uint64_t tb) {
    assert(a<4096 && b<4096 && tb>=ta);
    uint64_t skew=tb-ta;
    p->skew_sum+=skew;
    if(skew>p->skew_max) p->skew_max=skew;
    p->a[p->pos]=a; p->b[p->pos]=b;
    for(unsigned k=0;k<CF_PAIR_LAGS;k++) {
        int lag=cf_pair_lags[k];
        unsigned offset=(unsigned)(lag<0?-lag:lag);
        if(p->n<offset) continue;
        unsigned old=(p->pos+32-offset)%32;
        uint64_t x=lag>=0?p->a[old]:a;
        uint64_t y=lag>=0?b:p->b[old];
        p->x[k]+=x; p->y[k]+=y; p->xx[k]+=x*x;
        p->yy[k]+=y*y; p->xy[k]+=x*y; p->pairs[k]++;
    }
    p->pos=(p->pos+1)%32;
    if(++p->n!=CF_WINDOW) return;
    cf_pair_report r={.n=p->n,.end_us=tb,.max_skew_us=p->skew_max,
                      .mean_skew_us=(double)p->skew_sum/p->n};
    for(unsigned k=0;k<CF_PAIR_LAGS;k++) {
        double n=p->pairs[k];
        double vx=n*p->xx[k]-(double)p->x[k]*p->x[k];
        double vy=n*p->yy[k]-(double)p->y[k]*p->y[k];
        r.valid[k]=n>1 && vx>0 && vy>0;
        if(r.valid[k]) r.correlation[k]=fmax(-1,fmin(1,
            (n*p->xy[k]-(double)p->x[k]*p->y[k])/sqrt(vx*vy)));
    }
    cf_wipe(p,sizeof(*p)); p->last=r;
}
