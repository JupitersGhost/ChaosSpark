#ifndef CF_SCHEDULE_H
#define CF_SCHEDULE_H
#include <stdbool.h>
#include <stdint.h>
#define CF_SAMPLE_US 1000ULL
typedef struct { uint64_t next_us, skipped_slots, max_lateness_us; } cf_schedule;
/* Fixed phase: one observation at most for the latest elapsed slot. No replay
   or synthetic catch-up observations after delayed timer notifications. */
static inline bool cf_schedule_take(cf_schedule *s, uint64_t now) {
    if(now<s->next_us) return false;
    uint64_t late=now-s->next_us, skipped=late/CF_SAMPLE_US;
    if(late>s->max_lateness_us) s->max_lateness_us=late;
    s->skipped_slots+=skipped;
    s->next_us+=(skipped+1)*CF_SAMPLE_US;
    return true;
}
#endif
