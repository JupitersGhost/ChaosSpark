#include "cf_core.h"
#include <assert.h>
#include <math.h>
#include <string.h>

static const uint64_t rc[24] = {
0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL};
static const unsigned rho[25] = {0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14};
static uint64_t rol(uint64_t x, unsigned n) { return n ? (x << n) | (x >> (64-n)) : x; }
static void permute(uint64_t a[25]) {
    uint64_t c[5], d[5], b[25];
    for (unsigned r=0;r<24;r++) {
        for(unsigned x=0;x<5;x++) c[x]=a[x]^a[x+5]^a[x+10]^a[x+15]^a[x+20];
        for(unsigned x=0;x<5;x++) d[x]=c[(x+4)%5]^rol(c[(x+1)%5],1);
        for(unsigned y=0;y<5;y++) for(unsigned x=0;x<5;x++) a[x+5*y]^=d[x];
        for(unsigned y=0;y<5;y++) for(unsigned x=0;x<5;x++) b[y+5*((2*x+3*y)%5)]=rol(a[x+5*y],rho[x+5*y]);
        for(unsigned y=0;y<5;y++) for(unsigned x=0;x<5;x++) a[x+5*y]=b[x+5*y]^((~b[(x+1)%5+5*y])&b[(x+2)%5+5*y]);
        a[0]^=rc[r];
    }
}
void cf_wipe(void *p, size_t n) { volatile uint8_t *v=p; while(n--) *v++=0; }
void cf_sha3_init(cf_sha3 *s) { memset(s,0,sizeof(*s)); }
void cf_sha3_add(cf_sha3 *s, const void *data, size_t n) {
    const uint8_t *p=data;
    while(n--) {
        s->a[s->pos/8]^=(uint64_t)*p++ << (8*(s->pos%8));
        if(++s->pos==72) { permute(s->a); s->pos=0; }
    }
}
void cf_sha3_final(cf_sha3 *s, uint8_t out[64]) {
    s->a[s->pos/8]^=(uint64_t)0x06 << (8*(s->pos%8));
    s->a[8]^=0x8000000000000000ULL;
    permute(s->a);
    for(unsigned i=0;i<64;i++) out[i]=(uint8_t)(s->a[i/8]>>(8*(i%8)));
    cf_wipe(s,sizeof(*s));
}
bool cf_sha3_selftest(void) {
    static const uint8_t expected[64]={
    0xb7,0x51,0x85,0x0b,0x1a,0x57,0x16,0x8a,0x56,0x93,0xcd,0x92,0x4b,0x6b,0x09,0x6e,
    0x08,0xf6,0x21,0x82,0x74,0x44,0xf7,0x0d,0x88,0x4f,0x5d,0x02,0x40,0xd2,0x71,0x2e,
    0x10,0xe1,0x16,0xe9,0x19,0x2a,0xf3,0xc9,0x1a,0x7e,0xc5,0x76,0x47,0xe3,0x93,0x40,
    0x57,0x34,0x0b,0x4c,0xf4,0x08,0xd5,0xa5,0x65,0x92,0xf8,0x27,0x4e,0xec,0x53,0xf0};
    cf_sha3 s; uint8_t out[64]; cf_sha3_init(&s); cf_sha3_add(&s,"abc",3); cf_sha3_final(&s,out);
    bool ok=memcmp(out,expected,64)==0; cf_wipe(out,sizeof(out)); return ok;
}
uint32_t cf_crc32(const void *data, size_t n) {
    uint32_t c=0xffffffffu; const uint8_t *p=data;
    while(n--) { c^=*p++; for(unsigned i=0;i<8;i++) c=(c>>1)^(0xedb88320u & (0u-(c&1u))); }
    return ~c;
}
static void inc(uint64_t *n) { if(*n != UINT64_MAX) ++*n; }
static void u64(cf_sha3 *h, uint64_t v) {
    uint8_t b[8]; for(unsigned i=0;i<8;i++) b[i]=(uint8_t)(v>>(8*i)); cf_sha3_add(h,b,8);
}
static void clear_metrics(cf_source *s);
static void block_init(cf_source *s) {
    cf_sha3_init(&s->block); cf_sha3_add(&s->block,"CF1.2/source/512/u32le",sizeof("CF1.2/source/512/u32le")-1); u64(&s->block,s->id);
}
void cf_source_discard(cf_source *s) {
    cf_wipe(&s->pending,sizeof(s->pending)); cf_sha3_init(&s->pending);
    cf_sha3_add(&s->pending,"CF1/pending",11); u64(&s->pending,s->id); s->pending_blocks=0;
    s->pending_clip_warning=false;
}
void cf_source_init(cf_source *s, unsigned id, uint16_t *hist, unsigned alphabet) {
    assert(id < CF_SOURCES && (alphabet==256 || alphabet==4096));
    memset(s,0,sizeof(*s)); s->id=id; s->hist=hist; s->alphabet=alphabet; s->lo=UINT32_MAX;
    memset(hist,0,alphabet*sizeof(*hist));
    /* Engineering cutoffs, NOT calibrated SP800-90B entropy claims. */
    s->rct_cutoff=(id==CF_RNG)?6:64;
    s->apt_cutoff=(id==CF_RNG)?32:480;
    block_init(s); cf_source_discard(s);
}
static void reject(cf_source *s, uint64_t now, unsigned reason) {
    if(!(s->block_faults&reason)) {
        if(reason==1) inc(&s->rct_failures);
        if(reason==2) inc(&s->apt_failures);
    }
    s->block_faults|=reason; s->last_faults=s->block_faults;
    if(!s->block_bad) inc(&s->failures);
    s->block_bad=true; s->active=false; s->clean_windows=0; s->last_failure_us=now;
    cf_source_discard(s);
}
void cf_source_fail(cf_source *s, uint64_t now) { reject(s,now,8); }
uint64_t cf_source_max_age(unsigned id) { return (id==3 || id==4)?45000000ULL:2000000ULL; }
void cf_source_expire(cf_source *s, uint64_t now) {
    if(s->last_us && (now<s->last_us || now-s->last_us>cf_source_max_age(s->id))) {
        if(s->active || s->apt_n || s->clean_windows || s->pending_blocks) {
            reject(s,now,16);
            s->apt_n=0; s->apt_hits=0; s->block_bad=false; s->block_faults=0;
            s->block_rail=0; s->have_previous=false; s->run=0; block_init(s); clear_metrics(s);
        }
    }
}
cf_metrics cf_source_preview(const cf_source *s) {
    if(!s->n) return (cf_metrics){0};
    double h=0, square_sum=0; unsigned maximum=0;
    for(unsigned i=0;i<s->alphabet;i++) if(s->hist[i]) {
        double p=(double)s->hist[i]/s->n; h-=p*log2(p);
        square_sum+=(double)s->hist[i]*s->hist[i];
        if(s->hist[i]>maximum) maximum=s->hist[i];
    }
    /* Empirical most-likely 128-bit path in a first-order LSB model.
       Diagnostic only: not the full 90B Markov estimator or a lower bound. */
    double dp[2], next[2], p[2][2];
    for(unsigned a=0;a<2;a++) {
        dp[a]=(double)s->bit_count[a]/s->n;
        double total=(double)s->trans[a][0]+s->trans[a][1];
        for(unsigned b=0;b<2;b++) p[a][b]=total?s->trans[a][b]/total:0;
    }
    for(unsigned i=1;i<128;i++) {
        for(unsigned b=0;b<2;b++) next[b]=fmax(dp[0]*p[0][b],dp[1]*p[1][b]);
        dp[0]=next[0]; dp[1]=next[1];
    }
    double path=fmax(dp[0],dp[1]);
    return (cf_metrics){.n=s->n,.lo=s->lo,.hi=s->hi,.rail=s->rail,.max_run=s->window_run,
        .mean=(double)s->sum/s->n,.shannon=h,.mcv_plugin=-log2((double)maximum/s->n),
        .markov_lsb_128_plugin=path>0?-log2(path)/128.0:0,
        .chi_square_uniform=square_sum*s->alphabet/s->n-s->n,
        .lsb_ones_fraction=(double)s->bit_count[1]/s->n};
}
static void clear_metrics(cf_source *s) {
    memset(s->hist,0,s->alphabet*sizeof(*s->hist)); memset(s->trans,0,sizeof(s->trans));
    memset(s->bit_count,0,sizeof(s->bit_count));
    s->n=0; s->lo=UINT32_MAX; s->hi=0; s->rail=0; s->sum=0; s->window_run=0; s->have_bit=false;
}
static void finish_metrics(cf_source *s) {
    s->metrics=cf_source_preview(s);
    clear_metrics(s);
}
void cf_source_gap(cf_source *s, uint64_t now) {
    reject(s,now,32); inc(&s->discontinuities);
    s->apt_n=0; s->apt_hits=0; s->block_bad=false; s->block_faults=0;
    s->block_rail=0; s->have_previous=false; s->run=0;
    block_init(s); clear_metrics(s);
}
static void push_raw(cf_source *s, uint32_t value, unsigned symbol, uint64_t now) {
    cf_source_expire(s,now);
    s->last_us=now; inc(&s->samples);
    s->run=(s->have_previous && value==s->previous)?(s->run<UINT32_MAX?s->run+1:s->run):1;
    s->previous=value; s->have_previous=true;
    if(s->run>=s->rct_cutoff) reject(s,now,1);
    if(!s->apt_n) { s->reference=value; s->apt_hits=0; }
    if(value==s->reference) s->apt_hits++;
    if(s->apt_hits>=s->apt_cutoff) reject(s,now,2);
    s->apt_n++;
    bool rail=(CF_IS_ADC(s->id) && (value<=8 || value>=4087));
    s->block_rail+=rail; s->rail+=rail;
    s->hist[symbol]++; s->n++; s->sum+=value;
    if(value<s->lo) s->lo=value;
    if(value>s->hi) s->hi=value;
    if(s->run>s->window_run) s->window_run=s->run;
    unsigned bit=value&1u; s->bit_count[bit]++;
    if(s->have_bit) s->trans[s->last_bit][bit]++;
    s->last_bit=bit; s->have_bit=true;
    uint8_t b[4];
    for(unsigned i=0;i<4;i++) b[i]=(uint8_t)(value>>(8*i));
    cf_sha3_add(&s->block,b,4);
    if(s->apt_n==CF_APT_WINDOW) {
        /* Clipping is an acquisition warning, never an entropy credit.
           RCT/APT/driver faults still quarantine this source only. */
        s->clip_warning=(CF_IS_ADC(s->id) && s->block_rail*100 >= CF_APT_WINDOW*80);
        if(s->clip_warning) inc(&s->clip_warning_blocks);
        uint8_t digest[64]; cf_sha3_final(&s->block,digest);
        if(!s->block_bad) {
            inc(&s->blocks_ok);
            if(s->clean_windows>=2) {
                cf_sha3_add(&s->pending,digest,64); inc(&s->pending_blocks);
                s->pending_clip_warning|=s->clip_warning;
            }
            else { s->clean_windows++; if(s->clean_windows==2) s->active=true; }
        } else inc(&s->blocks_rejected);
        cf_wipe(digest,sizeof(digest)); s->apt_n=0; s->block_rail=0; s->block_bad=false; s->block_faults=0; block_init(s);
    }
    if(s->n==CF_WINDOW) {
        finish_metrics(s); s->metrics_end_us=now; inc(&s->metrics_windows);
    }
}
void cf_source_push(cf_source *s, uint32_t value, uint64_t now) {
    if(value>=s->alphabet) { reject(s,now,64); return; }
    push_raw(s,value,value,now);
}
void cf_source_push_cycles(cf_source *s, uint32_t cycles, uint64_t now) {
    assert(s->id==CF_TIMING && s->alphabet==4096);
    push_raw(s,cycles,cycles&4095u,now);
}
void cf_pool_init(cf_pool *p, const uint8_t session[16]) {
    memset(p,0,sizeof(*p));
    cf_sha3 h; cf_sha3_init(&h);
    cf_sha3_add(&h,"CF1.2/pool/init",sizeof("CF1.2/pool/init")-1); cf_sha3_add(&h,session,16);
    cf_sha3_final(&h,p->state);
}
bool cf_output(cf_source s[CF_SOURCES], cf_pool *pool, const uint8_t session[16], uint64_t seq,
               uint64_t now, uint8_t out[64], uint64_t used[CF_SOURCES]) {
    memset(used,0,sizeof(uint64_t)*CF_SOURCES);
    bool ready=false;
    for(unsigned i=0;i<CF_SOURCES;i++) {
        cf_source_expire(&s[i],now);
        if(!s[i].active || !s[i].last_us) cf_source_discard(&s[i]);
        if(s[i].active && s[i].pending_blocks) ready=true;
    }
    if(!ready) { memset(out,0,64); return false; }
    assert(pool->updates<UINT64_MAX);
    cf_sha3 h; cf_sha3_init(&h);
    static const char absorb[]="CF1.2/pool/absorb/SHA3-512";
    cf_sha3_add(&h,absorb,sizeof(absorb)-1);
    cf_sha3_add(&h,pool->state,64); cf_sha3_add(&h,session,16);
    u64(&h,seq); u64(&h,now); u64(&h,pool->updates);
    for(unsigned i=0;i<CF_SOURCES;i++) if(s[i].active && s[i].pending_blocks) {
        uint8_t digest[64]; used[i]=s[i].pending_blocks;
        u64(&h,i); u64(&h,used[i]); cf_sha3_final(&s[i].pending,digest);
        cf_sha3_add(&h,digest,64); cf_wipe(digest,sizeof(digest)); cf_source_discard(&s[i]);
        pool->absorbed[i]=UINT64_MAX-pool->absorbed[i]<used[i]?UINT64_MAX:pool->absorbed[i]+used[i];
        pool->last_absorbed_us[i]=now; pool->ever_mask|=1u<<i;
    }
    uint8_t mixed[64]; cf_sha3_final(&h,mixed);
    /* Separate domains prevent the transmitted block becoming the next state. */
    cf_sha3_init(&h); cf_sha3_add(&h,"CF1.2/pool/output",sizeof("CF1.2/pool/output")-1);
    cf_sha3_add(&h,mixed,64); u64(&h,seq); cf_sha3_final(&h,out);
    cf_sha3_init(&h); cf_sha3_add(&h,"CF1.2/pool/ratchet",sizeof("CF1.2/pool/ratchet")-1);
    cf_sha3_add(&h,mixed,64); u64(&h,seq); cf_sha3_final(&h,pool->state);
    cf_wipe(mixed,sizeof(mixed)); pool->updates++;
    return true;
}
