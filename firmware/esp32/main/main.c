/* ChaosSpark Chaosfield 1.3.0. Raw observations never enter an output record. */
#include "cf_core.h"
#include "cf_pickup.h"
#include "cf_schedule.h"
#include "cf_pair.h"
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/event_groups.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_cpu.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "nvs_flash.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"

#if !CONFIG_IDF_TARGET_ESP32
#error "This firmware requires the classic ESP32 target."
#endif
#if CONFIG_BTDM_CTRL_MODEM_SLEEP
#error "Disable BT modem sleep for the BLE-backed RNG availability policy."
#endif
#if CONFIG_PM_ENABLE || CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ != 240
#error "Cycle-duration sampling requires fixed 240 MHz (power management disabled)."
#endif
#define VERSION "1.3.0"
#define RF_ON BIT0
#define BLE_ON BIT1
#define WIFI_ERROR BIT2
#define BLE_ERROR BIT3
#define WIFI_AWAKE BIT4
#define WIFI_SCANNING BIT5
#define OUTPUT_INTERVAL_US 500000ULL
#define STATUS_INTERVAL_US 5000000ULL
static cf_source sources[CF_SOURCES];
static uint16_t adc_hist[4096], aux_hist[4096], timing_hist[4096], byte_hist[CF_SOURCES][256];
static cf_pool private_pool;
static cf_source pool_measure;
static cf_pickup pickup, aux_pickup;
static cf_pair pair;
static uint16_t pool_hist[256];
static adc_oneshot_unit_handle_t adc;
static EventGroupHandle_t radio_state;
static QueueHandle_t observations, tx_queue, acquisition;
static TaskHandle_t sampler_handle;
static esp_timer_handle_t sample_timer;
static esp_err_t adc_init_result, aux_init_result;
static cf_schedule schedule;
static portMUX_TYPE sampler_lock=portMUX_INITIALIZER_UNLOCKED;

static uint8_t session[16];
static char session_hex[33], device_hex[13];
static portMUX_TYPE radio_lock=portMUX_INITIALIZER_UNLOCKED;
static uint64_t radio_drops, wifi_scans, wifi_errors, ble_errors;
static const char *names[CF_SOURCES]={"pickup_adc12","esp_rng_byte","adc_duration_cycles","wifi_rssi_offset128","ble_rssi_offset128","aux_gpio35_adc12"};

typedef struct {
    uint64_t captured, first_us, last_us, skipped_slots, max_lateness_us;
    uint64_t queue_drops, adc_errors, timing_invalid, rng_unavailable;
    uint64_t aux_adc_errors;
} sampler_counters;
typedef struct { unsigned id; uint16_t value; uint64_t when; } observation;
typedef struct {
    bool active, sampling, quarantined, clipped;
    uint64_t samples, age_us, failures, good, rejected, last_failure_us;
    unsigned partial_n, last_faults, startup_remaining;
    uint64_t rct_failures, apt_failures, clip_warnings, metrics_end_us, contributed;
    uint64_t absorbed, last_absorbed_us, discontinuities;
    unsigned current_faults;
    cf_metrics m, preview;
} source_status;
typedef struct {
    bool status, clipped, aux_clipped; uint64_t seq, now, used[CF_SOURCES]; uint8_t digest[64];
    source_status src[CF_SOURCES]; cf_metrics pool;
    cf_pickup_report pickup, aux_pickup;
    cf_pair_report pair;
    unsigned pool_partial;
    uint64_t pool_windows, pool_end_us, output_bytes, last_output_us;
    uint64_t adc_errors, deadline_misses, tx_drops, rf_drops, scans, scan_errors, bt_errors, suppressed;
    unsigned heap, min_heap, rf_flags, ever_mask;
    uint64_t pool_updates, acquisition_stale, acquisition_max_age_us;
    sampler_counters acquisition_stats;
} message;
static sampler_counters sampler_counts;
static void incr(uint64_t *v) { if(*v!=UINT64_MAX) ++*v; }
static void hex(char *dst, const uint8_t *src, size_t n) {
    static const char digits[]="0123456789abcdef";
    for(size_t i=0;i<n;i++) { dst[2*i]=digits[src[i]>>4]; dst[2*i+1]=digits[src[i]&15]; }
    dst[2*n]=0;
}
static void submit_observation(unsigned id, int rssi) {
    if(rssi < -127 || rssi > 20) return;
    observation o={.id=id,.value=(uint16_t)(rssi+128),.when=(uint64_t)esp_timer_get_time()};
    if(xQueueSend(observations,&o,0)!=pdTRUE) {
        portENTER_CRITICAL(&radio_lock); incr(&radio_drops); portEXIT_CRITICAL(&radio_lock);
    }
}
static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if(id==WIFI_EVENT_STA_START) xEventGroupSetBits(radio_state,RF_ON);
    if(id==WIFI_EVENT_STA_STOP) xEventGroupClearBits(radio_state,RF_ON);
}
static void wifi_task(void *unused) {
    (void)unused;
    /* Passive scan only: no association, SSID credentials or network sender. */
    wifi_scan_config_t cfg={.show_hidden=true,.scan_type=WIFI_SCAN_TYPE_PASSIVE,
                            .scan_time={.passive=120}};
    static wifi_ap_record_t aps[64];
    for(;;) {
        xEventGroupSetBits(radio_state,WIFI_SCANNING);
        esp_err_t err=esp_wifi_scan_start(&cfg,true);
        xEventGroupClearBits(radio_state,WIFI_SCANNING);
        uint16_t count=64;
        if(err==ESP_OK) err=esp_wifi_scan_get_ap_records(&count,aps);
        portENTER_CRITICAL(&radio_lock);
        if(err==ESP_OK) incr(&wifi_scans); else incr(&wifi_errors);
        portEXIT_CRITICAL(&radio_lock);
        if(err==ESP_OK) {
            xEventGroupClearBits(radio_state,WIFI_ERROR);
            for(unsigned i=0;i<count;i++) submit_observation(3,aps[i].rssi);
        } else xEventGroupSetBits(radio_state,WIFI_ERROR);
        esp_wifi_clear_ap_list(); cf_wipe(aps,sizeof(aps));
        vTaskDelay(pdMS_TO_TICKS(30000));
    }
}
static void ble_error(void) {
    xEventGroupSetBits(radio_state,BLE_ERROR); xEventGroupClearBits(radio_state,BLE_ON);
    portENTER_CRITICAL(&radio_lock); incr(&ble_errors); portEXIT_CRITICAL(&radio_lock);
}
static void ble_event(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *p) {
    if(event==ESP_GAP_BLE_SCAN_PARAM_SET_COMPLETE_EVT) {
        if(p->scan_param_cmpl.status!=ESP_BT_STATUS_SUCCESS || esp_ble_gap_start_scanning(0)!=ESP_OK) ble_error();
    } else if(event==ESP_GAP_BLE_SCAN_START_COMPLETE_EVT) {
        if(p->scan_start_cmpl.status==ESP_BT_STATUS_SUCCESS) {
            xEventGroupSetBits(radio_state,BLE_ON); xEventGroupClearBits(radio_state,BLE_ERROR);
        } else ble_error();
    } else if(event==ESP_GAP_BLE_SCAN_RESULT_EVT && p->scan_rst.search_evt==ESP_GAP_SEARCH_INQ_RES_EVT) {
        submit_observation(4,p->scan_rst.rssi);
    } else if(event==ESP_GAP_BLE_SCAN_STOP_COMPLETE_EVT) xEventGroupClearBits(radio_state,BLE_ON);
}
/* Optional acquisition drivers fail locally. Infrastructure (queues, UART,
   SHA3 self-test) remains mandatory. No automatic NVS erase. */
#define TRY_SOURCE(call) do { esp_err_t e=(call); if(e!=ESP_OK) return e; } while(0)
static esp_err_t wifi_init_source(void) {
    TRY_SOURCE(esp_netif_init()); TRY_SOURCE(esp_event_loop_create_default());
    esp_netif_config_t netif_cfg=ESP_NETIF_DEFAULT_WIFI_STA();
    esp_netif_t *netif=esp_netif_new(&netif_cfg);
    if(!netif) return ESP_ERR_NO_MEM;
    TRY_SOURCE(esp_netif_attach_wifi_station(netif));
    TRY_SOURCE(esp_wifi_set_default_wifi_sta_handlers());
    wifi_init_config_t cfg=WIFI_INIT_CONFIG_DEFAULT();
    TRY_SOURCE(esp_wifi_init(&cfg));
    TRY_SOURCE(esp_event_handler_register(WIFI_EVENT,ESP_EVENT_ANY_ID,wifi_event,NULL));
    TRY_SOURCE(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    TRY_SOURCE(esp_wifi_set_mode(WIFI_MODE_STA));
    TRY_SOURCE(esp_wifi_start()); TRY_SOURCE(esp_wifi_set_ps(WIFI_PS_NONE));
    EventBits_t bits=xEventGroupWaitBits(radio_state,RF_ON,pdFALSE,pdTRUE,pdMS_TO_TICKS(5000));
    if(!(bits&RF_ON)) return ESP_ERR_TIMEOUT;
    xEventGroupSetBits(radio_state,WIFI_AWAKE);
    if(xTaskCreate(wifi_task,"cf_wifi",4096,NULL,3,NULL)!=pdPASS) return ESP_ERR_NO_MEM;
    return ESP_OK;
}
static esp_err_t ble_init_source(void) {
    /* Use RF-backed RNG; do not enable the conflicting SAR bootloader noise source. */
    TRY_SOURCE(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));
    esp_bt_controller_config_t bt=BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    TRY_SOURCE(esp_bt_controller_init(&bt));
    TRY_SOURCE(esp_bt_controller_enable(ESP_BT_MODE_BLE));
    TRY_SOURCE(esp_bluedroid_init()); TRY_SOURCE(esp_bluedroid_enable());
    TRY_SOURCE(esp_ble_gap_register_callback(ble_event));
    static esp_ble_scan_params_t scan={.scan_type=BLE_SCAN_TYPE_PASSIVE,.own_addr_type=BLE_ADDR_TYPE_PUBLIC,
        .scan_filter_policy=BLE_SCAN_FILTER_ALLOW_ALL,.scan_interval=160,.scan_window=48,
        .scan_duplicate=BLE_SCAN_DUPLICATE_DISABLE};
    TRY_SOURCE(esp_ble_gap_set_scan_params(&scan));
    return ESP_OK;
}
static void radios_init(void) {
    esp_err_t nvs=nvs_flash_init();
    if(nvs!=ESP_OK || wifi_init_source()!=ESP_OK) {
        xEventGroupSetBits(radio_state,WIFI_ERROR);
        portENTER_CRITICAL(&radio_lock); incr(&wifi_errors); portEXIT_CRITICAL(&radio_lock);
    }
    if(ble_init_source()!=ESP_OK) ble_error();
}
/* Exactly one task owns stdout. Each line is an envelope with CRC over the
   exact UTF-8 bytes between body: and ,crc32. CRC is not authentication. */
static char body[16384];
static size_t body_n;
static void append(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void append(const char *fmt, ...) {
    va_list ap; va_start(ap,fmt); int n=vsnprintf(body+body_n,sizeof(body)-body_n,fmt,ap); va_end(ap);
    if(n<0 || (size_t)n>=sizeof(body)-body_n) abort();
    body_n+=(size_t)n;
}
static void metrics(const cf_metrics *m) {
    if(!m->n) { append("null"); return; }
    append("{\"n\":%"PRIu32",\"min\":%"PRIu32",\"max\":%"PRIu32",\"mean\":%.5f,"
           "\"rail_fraction\":%.6f,\"max_run\":%"PRIu32",\"shannon_bits_per_symbol\":%.6f,"
           "\"mcv_plugin_bits_per_symbol\":%.6f,\"markov_lsb128_plugin_bits_per_bit\":%.6f,\"chi_square_uniform\":%.5f,\"lsb_ones_fraction\":%.6f}",
           m->n,m->lo,m->hi,m->mean,(double)m->rail/m->n,m->max_run,m->shannon,m->mcv_plugin,m->markov_lsb_128_plugin,m->chi_square_uniform,m->lsb_ones_fraction);
}
static void pickup_metrics(const cf_pickup_report *p) {
    if(!p->n) { append("null"); return; }
    append("{\"n\":%"PRIu32",\"window_end_us\":%"PRIu64",\"state_order\":[\"low\",\"interior\",\"high\"],"
           "\"low_fraction\":%.6f,\"high_fraction\":%.6f,\"mean_abs_delta_codes\":%.5f,"
           "\"interval_us\":{\"min\":%"PRIu64",\"mean\":%.3f,\"max\":%"PRIu64"},"
           "\"state_markov128_plugin_bits_per_symbol\":%.6f,\"transition_counts\":[",
           p->n,p->end_us,(double)p->states[0]/p->n,(double)p->states[2]/p->n,p->mean_abs_delta,
           p->interval_min_us,p->interval_mean_us,p->interval_max_us,p->state_markov128);
    for(unsigned a=0;a<3;a++) append("%s[%"PRIu32",%"PRIu32",%"PRIu32"]",a?",":"",p->transitions[a][0],p->transitions[a][1],p->transitions[a][2]);
    append("],\"dwell_bin_lower_samples\":[1,2,4,8,16,32,64,128],\"dwell_counts\":[");
    for(unsigned a=0;a<3;a++) {
        append("%s[",a?",":"");
        for(unsigned b=0;b<CF_DWELL_BINS;b++) append("%s%"PRIu32,b?",":"",p->dwell[a][b]);
        append("]");
    }
    append("],\"dwell_boundary_runs_censored\":true,\"longest_run_samples\":[%"PRIu32",%"PRIu32",%"PRIu32"],\"lag_correlations\":[",
           p->longest_run[0],p->longest_run[1],p->longest_run[2]);
    for(unsigned k=0;k<CF_LAGS;k++) {
        append("%s{\"lag_samples\":%u,\"pearson_r\":",k?",":"",cf_lags[k]);
        if(p->lag_valid[k]) append("%.6f",p->lag_correlation[k]); else append("null");
        append("}");
    }
    append("],\"wifi_scan_groups\":[");
    for(unsigned i=0;i<2;i++) {
        append("%s{\"scanning\":%s,\"n\":%"PRIu32",\"rail_fraction\":",i?",":"",i?"true":"false",p->scan_n[i]);
        if(p->scan_n[i]) append("%.6f,\"mean_code\":%.5f",(double)p->scan_rail[i]/p->scan_n[i],p->scan_mean[i]);
        else append("null,\"mean_code\":null");
        append("}");
    }
    append("]}");
}
static void pair_metrics(const cf_pair_report *p) {
    if(!p->n) { append("null"); return; }
    append("{\"n\":%"PRIu32",\"window_end_us\":%"PRIu64","
           "\"sequential\":true,\"mean_skew_us\":%.3f,\"max_skew_us\":%"PRIu64","
           "\"lag_definition\":\"gpio35[n] vs gpio34[n-lag]\",\"correlations\":[",
           p->n,p->end_us,p->mean_skew_us,p->max_skew_us);
    for(unsigned k=0;k<CF_PAIR_LAGS;k++) {
        append("%s{\"lag_samples\":%d,\"pearson_r\":",k?",":"",cf_pair_lags[k]);
        if(p->valid[k]) append("%.6f",p->correlation[k]); else append("null");
        append("}");
    }
    append("]}");
}
static unsigned contributors(const uint64_t used[CF_SOURCES]) {
    unsigned n=0; for(unsigned i=0;i<CF_SOURCES;i++) n+=used[i]!=0; return n;
}
static void tx_task(void *unused) {
    (void)unused; static message msg;
    for(;;) {
        if(xQueueReceive(tx_queue,&msg,portMAX_DELAY)!=pdTRUE) continue;
        body_n=0;
        append("{\"protocol\":\"chaos-spark-chaosfield/1\",\"firmware\":\""VERSION"\",\"type\":\"%s\","
               "\"device\":\"%s\",\"session\":\"%s\",\"seq\":%"PRIu64",\"uptime_us\":%"PRIu64,
               msg.status?"status":"conditioned",device_hex,session_hex,msg.seq,msg.now);
        append(",\"source_count\":6,\"mix_policy\":\"private-state-fresh-input\",\"credited_entropy_bits\":0,"
               "\"qualification\":\"unqualified\",\"pool_updates\":%"PRIu64",\"pool_ever_source_mask\":%u",
               msg.pool_updates,msg.ever_mask);
        if(!msg.status) {
            char digest_hex[129]; hex(digest_hex,msg.digest,64);
            append(",\"algorithm\":\"SHA3-512\",\"contributor_count\":%u,\"rng_included\":%s,"
                   "\"pickup_clip_warning\":%s,\"aux_clip_warning\":%s,\"pool_state\":\"streaming\","
                   "\"source_blocks\":[%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64"],\"conditioned_hex\":\"%s\"}",
                   contributors(msg.used),msg.used[CF_RNG]?"true":"false",msg.clipped?"true":"false",msg.aux_clipped?"true":"false",
                   msg.used[0],msg.used[1],msg.used[2],msg.used[3],msg.used[4],msg.used[5],digest_hex);
            cf_wipe(digest_hex,sizeof(digest_hex));
        } else {
            append(",\"health_profile\":\"engineering-v1.3-unqualified\",\"raw_export\":false,"
                   "\"metrics_window_symbols\":8192,\"apt_window_symbols\":512,\"startup_clean_windows\":2,"
                   "\"rng_rct_cutoff\":6,\"rng_apt_cutoff\":32,\"sensor_rct_cutoff\":64,\"sensor_apt_cutoff\":480,"
                   "\"adc_clip_warning_fraction\":0.8,\"rf_flags\":%u,\"free_heap\":%u,\"minimum_free_heap\":%u,"
                   "\"adc_errors\":%"PRIu64",\"aux_adc_errors\":%"PRIu64",\"missed_sample_slots\":%"PRIu64",\"tx_drops\":%"PRIu64","
                   "\"radio_queue_drops\":%"PRIu64",\"wifi_scans\":%"PRIu64",\"wifi_errors\":%"PRIu64","
                   "\"ble_errors\":%"PRIu64",\"suppressed_outputs\":%"PRIu64,
                   msg.rf_flags,msg.heap,msg.min_heap,msg.adc_errors,msg.acquisition_stats.aux_adc_errors,msg.deadline_misses,msg.tx_drops,msg.rf_drops,
                   msg.scans,msg.scan_errors,msg.bt_errors,msg.suppressed);
            const sampler_counters *a=&msg.acquisition_stats;
            append(",\"acquisition\":{\"target_hz\":1000,\"cpu_mhz\":240,\"core\":1,\"queue_capacity\":64,"
                   "\"captured\":%"PRIu64",\"first_us\":%"PRIu64",\"last_us\":%"PRIu64","
                   "\"skipped_slots\":%"PRIu64",\"max_lateness_us\":%"PRIu64",\"queue_drops\":%"PRIu64","
                   "\"stale_discarded\":%"PRIu64",\"max_processing_age_us\":%"PRIu64","
                   "\"timing_invalid\":%"PRIu64",\"rng_unavailable\":%"PRIu64"},\"sources\":[",
                   a->captured,a->first_us,a->last_us,a->skipped_slots,a->max_lateness_us,a->queue_drops,
                   msg.acquisition_stale,msg.acquisition_max_age_us,a->timing_invalid,a->rng_unavailable);
            for(unsigned i=0;i<CF_SOURCES;i++) {
                source_status *s=&msg.src[i];
                const char *state=s->quarantined?"quarantined":(!s->sampling?(s->samples?"stale":"waiting_for_samples"):(s->active?"ready":"warming_up"));
                append("%s{\"name\":\"%s\",\"symbol_bits\":%u,\"raw_symbol_bits\":%u,\"metric_view\":\"%s\","
                       "\"active\":%s,\"samples\":%"PRIu64",\"age_us\":%"PRIu64","
                       "\"failed_blocks\":%"PRIu64",\"last_failure_us\":%"PRIu64","
                       "\"good_blocks\":%"PRIu64",\"rejected_blocks\":%"PRIu64",\"partial_metrics_symbols\":%u,\"last_window\":",
                       i?",":"",names[i],(CF_IS_ADC(i) || i==CF_TIMING)?12:8,i==CF_TIMING?32:(CF_IS_ADC(i)?12:8),
                       i==CF_TIMING?"cycles_lsb12":"whole_symbol",s->active?"true":"false",s->samples,s->age_us,
                       s->failures,s->last_failure_us,s->good,s->rejected,s->partial_n);
                metrics(&s->m); append(",\"partial_window_provisional\":"); metrics(&s->preview);
                append(",\"state\":\"%s\",\"sampling\":%s,\"clip_warning\":%s,\"entropy_qualified\":false,"
                       "\"startup_clean_samples_remaining\":%u,\"included_last_output\":%s,"
                       "\"contributed_blocks\":%"PRIu64",\"absorbed_blocks\":%"PRIu64","
                       "\"last_absorbed_us\":%"PRIu64",\"discontinuities\":%"PRIu64","
                       "\"last_window_end_us\":%"PRIu64",\"last_fault_mask\":%u,\"current_fault_mask\":%u,"
                       "\"rct_failed_blocks\":%"PRIu64",\"apt_failed_blocks\":%"PRIu64",\"clip_warning_blocks\":%"PRIu64"}",
                       state,s->sampling?"true":"false",s->clipped?"true":"false",s->startup_remaining,
                       msg.used[i]?"true":"false",s->contributed,s->absorbed,s->last_absorbed_us,s->discontinuities,
                       s->metrics_end_us,s->last_faults,s->current_faults,s->rct_failures,s->apt_failures,s->clip_warnings);
            }
            append("],\"pickup_diagnostics_last_window\":"); pickup_metrics(&msg.pickup);
            append(",\"aux_gpio35\":{\"gpio\":35,\"adc_unit\":1,\"adc_channel\":7,"
                   "\"mode\":\"generic_optional_adc\",\"pickup_presence\":\"unknown\","
                   "\"auto_detection\":false,\"diagnostics_last_window\":");
            pickup_metrics(&msg.aux_pickup); append("}");
            append(",\"adc_pair_last_window\":"); pair_metrics(&msg.pair);
            append(",\"conditioned_output_last_window\":"); metrics(&msg.pool);
            append(",\"conditioned_output_progress\":{\"partial_bytes\":%u,\"target_bytes\":8192,\"completed_windows\":%"PRIu64","
                   "\"last_window_end_us\":%"PRIu64",\"total_queued_bytes\":%"PRIu64"},\"last_output_us\":%"PRIu64","
                   "\"last_output_source_blocks\":[%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64"],\"pool_state\":\"%s\"}",
                   msg.pool_partial,msg.pool_windows,msg.pool_end_us,msg.output_bytes,msg.last_output_us,
                   msg.used[0],msg.used[1],msg.used[2],msg.used[3],msg.used[4],msg.used[5],
                   !msg.last_output_us || msg.now-msg.last_output_us>2000000ULL?"waiting_for_fresh_input":"streaming");
        }
        uint32_t crc=cf_crc32(body,body_n);
        printf("{\"body\":%s,\"crc32\":\"%08"PRIx32"\"}\n",body,crc);
        fflush(stdout); cf_wipe(&msg,sizeof(msg)); cf_wipe(body,body_n);
    }
}
/* Only this task touches ADC hardware. Raw records stay in bounded device RAM. */
typedef struct {
    uint64_t seq, when;
    uint32_t cycles, rng_word;
    uint16_t adc_value, aux_value;
    uint64_t aux_when;
    bool adc_ok, aux_ok, timing_ok, rng_ok, scanning;
} capture;
static void sample_tick(void *unused) {
    (void)unused;
    xTaskNotifyGive(sampler_handle);
}
static void sample_task(void *unused) {
    (void)unused;
    uint64_t seq=0;
    for(;;) {
        ulTaskNotifyTake(pdTRUE,portMAX_DELAY);
        uint64_t now=(uint64_t)esp_timer_get_time();
        if(!cf_schedule_take(&schedule,now)) continue;
        capture c={.seq=seq++};
        EventBits_t flags=xEventGroupGetBits(radio_state);
        c.scanning=(flags&WIFI_SCANNING)!=0;
        int value=0, discarded=0;
        /* Discard the first conversion after switching channels. This reduces
           mux carryover but does not fix an electrically floating input.
           Only the retained GPIO34 conversion contributes timing data. */
        esp_err_t settle=adc_init_result==ESP_OK?
            adc_oneshot_read(adc,ADC_CHANNEL_6,&discarded):adc_init_result;
        uint64_t before=(uint64_t)esp_timer_get_time();
        uint32_t c0=esp_cpu_get_cycle_count();
        esp_err_t err=settle==ESP_OK?adc_oneshot_read(adc,ADC_CHANNEL_6,&value):settle;
        uint32_t c1=esp_cpu_get_cycle_count();
        c.when=(uint64_t)esp_timer_get_time();
        c.adc_ok=err==ESP_OK && value>=0 && value<4096;
        c.adc_value=c.adc_ok?(uint16_t)value:0;
        /* Unsigned subtraction handles one wrap. The wall-time limit excludes
           ambiguity (32-bit counter wraps after ~17.9 s at fixed 240 MHz). */
        c.timing_ok=c.adc_ok && c.when>=before && c.when-before<1000000ULL;
        c.cycles=c1-c0;
        flags=xEventGroupGetBits(radio_state);
        c.rng_ok=((flags&(RF_ON|WIFI_AWAKE))==(RF_ON|WIFI_AWAKE)) || (flags&BLE_ON);
        if(c.rng_ok) c.rng_word=esp_random();
        settle=aux_init_result==ESP_OK?
            adc_oneshot_read(adc,ADC_CHANNEL_7,&discarded):aux_init_result;
        value=0;
        err=settle==ESP_OK?adc_oneshot_read(adc,ADC_CHANNEL_7,&value):settle;
        c.aux_when=(uint64_t)esp_timer_get_time();
        c.aux_ok=err==ESP_OK && value>=0 && value<4096;
        c.aux_value=c.aux_ok?(uint16_t)value:0;
        bool sent=xQueueSend(acquisition,&c,0)==pdTRUE;
        portENTER_CRITICAL(&sampler_lock);
        incr(&sampler_counts.captured);
        if(!sampler_counts.first_us) sampler_counts.first_us=c.when;
        sampler_counts.last_us=c.when;
        sampler_counts.skipped_slots=schedule.skipped_slots;
        sampler_counts.max_lateness_us=schedule.max_lateness_us;
        if(!sent) incr(&sampler_counts.queue_drops);
        if(!c.adc_ok) incr(&sampler_counts.adc_errors);
        if(!c.aux_ok) incr(&sampler_counts.aux_adc_errors);
        if(c.adc_ok && !c.timing_ok) incr(&sampler_counts.timing_invalid);
        if(!c.rng_ok) incr(&sampler_counts.rng_unavailable);
        portEXIT_CRITICAL(&sampler_lock);
        cf_wipe(&c,sizeof(c));
    }
}
static void pickup_discontinuity(void) {
    cf_pickup_report last=pickup.last;
    cf_wipe(&pickup,sizeof(pickup)); pickup.last=last;
}
static void aux_discontinuity(void) {
    cf_pickup_report last=aux_pickup.last;
    cf_wipe(&aux_pickup,sizeof(aux_pickup)); aux_pickup.last=last;
}
static void fast_discontinuity(uint64_t now) {
    for(unsigned i=0;i<3;i++) cf_source_gap(&sources[i],now);
    pickup_discontinuity();
    cf_source_gap(&sources[CF_AUX_ADC],now); aux_discontinuity();
    cf_pair_gap(&pair);
}
static void process_task(void *unused) {
    (void)unused;
    uint64_t now=(uint64_t)esp_timer_get_time(), next_out=now+OUTPUT_INTERVAL_US, next_status=now+STATUS_INTERVAL_US;
    uint64_t seq=0, tx_drops=0, suppressed=0, last_output_us=0, output_bytes=0;
    uint64_t last_used[CF_SOURCES]={0}, contributed[CF_SOURCES]={0};
    uint64_t expected_capture=0, acquisition_stale=0, acquisition_max_age_us=0;
    bool last_clipped=false;
    static message msg;
    for(;;) {
        capture c;
        for(unsigned batch=0;batch<16;batch++) {
            if(xQueueReceive(acquisition,&c,batch?0:pdMS_TO_TICKS(1))!=pdTRUE) break;
            now=(uint64_t)esp_timer_get_time();
            if(c.seq!=expected_capture) fast_discontinuity(now);
            expected_capture=c.seq+1;
            uint64_t age=now>=c.when?now-c.when:UINT64_MAX;
            if(age>acquisition_max_age_us) acquisition_max_age_us=age;
            if(age>100000ULL) {
                incr(&acquisition_stale); fast_discontinuity(now);
                cf_wipe(&c,sizeof(c)); continue;
            }
            if(c.adc_ok) {
                cf_source_push(&sources[0],c.adc_value,c.when);
                cf_pickup_push(&pickup,c.adc_value,c.when,c.scanning);
                if(c.timing_ok) cf_source_push_cycles(&sources[2],c.cycles,c.when);
                else { cf_source_gap(&sources[2],c.when); cf_source_fail(&sources[2],c.when); }
            } else {
                cf_source_gap(&sources[0],c.when); cf_source_fail(&sources[0],c.when);
                cf_source_gap(&sources[2],c.when); cf_source_fail(&sources[2],c.when);
                pickup_discontinuity();
            }
            if(c.aux_ok) {
                cf_source_push(&sources[CF_AUX_ADC],c.aux_value,c.aux_when);
                cf_pickup_push(&aux_pickup,c.aux_value,c.aux_when,c.scanning);
            } else {
                cf_source_gap(&sources[CF_AUX_ADC],c.aux_when);
                cf_source_fail(&sources[CF_AUX_ADC],c.aux_when);
                aux_discontinuity();
            }
            if(c.adc_ok && c.aux_ok)
                cf_pair_push(&pair,c.adc_value,c.aux_value,c.when,c.aux_when);
            else cf_pair_gap(&pair);
            if(c.rng_ok) {
                for(unsigned b=0;b<4;b++) cf_source_push(&sources[CF_RNG],(uint8_t)(c.rng_word>>(8*b)),c.when);
            } else { cf_source_gap(&sources[CF_RNG],c.when); cf_source_fail(&sources[CF_RNG],c.when); }
            cf_wipe(&c,sizeof(c));
        }
        now=(uint64_t)esp_timer_get_time();
        EventBits_t flags=xEventGroupGetBits(radio_state);
        if((flags&WIFI_ERROR) || !(flags&RF_ON)) cf_source_fail(&sources[3],now);
        if((flags&BLE_ERROR) || !(flags&BLE_ON)) cf_source_fail(&sources[4],now);
        observation o;
        for(unsigned i=0;i<16 && xQueueReceive(observations,&o,0)==pdTRUE;i++) {
            bool available=(o.id==3 && (flags&RF_ON) && !(flags&WIFI_ERROR)) ||
                           (o.id==4 && (flags&BLE_ON) && !(flags&BLE_ERROR));
            uint64_t observed_now=(uint64_t)esp_timer_get_time();
            if(available && observed_now>=o.when && observed_now-o.when<=cf_source_max_age(o.id))
                cf_source_push(&sources[o.id],o.value,o.when);
            cf_wipe(&o,sizeof(o));
        }
        now=(uint64_t)esp_timer_get_time();
        if(now>=next_out) {
            next_out=now+OUTPUT_INTERVAL_US; memset(&msg,0,sizeof(msg));
            msg.now=now; msg.seq=seq;
            bool pending_clipped=sources[0].pending_clip_warning;
            bool aux_clipped=sources[CF_AUX_ADC].pending_clip_warning;
            if(cf_output(sources,&private_pool,session,seq,now,msg.digest,msg.used)) {
                msg.clipped=msg.used[0] && pending_clipped;
                msg.aux_clipped=msg.used[CF_AUX_ADC] && aux_clipped;
                msg.ever_mask=private_pool.ever_mask; msg.pool_updates=private_pool.updates;
                if(seq==UINT64_MAX) abort();
                seq++;
                if(xQueueSend(tx_queue,&msg,0)!=pdTRUE) incr(&tx_drops);
                else {
                    for(unsigned i=0;i<64;i++) cf_source_push(&pool_measure,msg.digest[i],now);
                    output_bytes+=64; last_output_us=now; last_clipped=msg.clipped;
                    memcpy(last_used,msg.used,sizeof(last_used));
                    for(unsigned i=0;i<CF_SOURCES;i++) contributed[i]+=msg.used[i];
                }
            } else incr(&suppressed);
            cf_wipe(&msg,sizeof(msg));
        }
        if(now>=next_status) {
            next_status=now+STATUS_INTERVAL_US; memset(&msg,0,sizeof(msg));
            msg.status=true; msg.seq=seq;
            portENTER_CRITICAL(&sampler_lock); msg.acquisition_stats=sampler_counts; portEXIT_CRITICAL(&sampler_lock);
            now=(uint64_t)esp_timer_get_time(); msg.now=now;
            msg.adc_errors=msg.acquisition_stats.adc_errors; msg.deadline_misses=msg.acquisition_stats.skipped_slots;
            msg.acquisition_stale=acquisition_stale; msg.acquisition_max_age_us=acquisition_max_age_us;
            msg.tx_drops=tx_drops; msg.suppressed=suppressed;
            msg.heap=esp_get_free_heap_size(); msg.min_heap=esp_get_minimum_free_heap_size();
            msg.rf_flags=flags; msg.pool=pool_measure.metrics;
            msg.aux_pickup=aux_pickup.last; msg.pair=pair.last;
            msg.pickup=pickup.last; msg.pool_partial=pool_measure.n; msg.pool_windows=pool_measure.metrics_windows;
            msg.pool_end_us=pool_measure.metrics_end_us; msg.output_bytes=output_bytes;
            msg.last_output_us=last_output_us; memcpy(msg.used,last_used,sizeof(last_used)); msg.clipped=last_clipped;
            msg.ever_mask=private_pool.ever_mask; msg.pool_updates=private_pool.updates;
            portENTER_CRITICAL(&radio_lock);
            msg.rf_drops=radio_drops; msg.scans=wifi_scans; msg.scan_errors=wifi_errors; msg.bt_errors=ble_errors;
            portEXIT_CRITICAL(&radio_lock);
            for(unsigned i=0;i<CF_SOURCES;i++) {
                cf_source *s=&sources[i]; source_status *d=&msg.src[i];
                cf_source_expire(s,now);
                d->age_us=s->last_us && now>=s->last_us?now-s->last_us:UINT64_MAX;
                d->sampling=s->last_us && d->age_us<=cf_source_max_age(i);
                d->active=s->active && d->sampling; d->quarantined=s->block_bad;
                d->clipped=s->clip_warning;
                d->startup_remaining=s->clean_windows>=2?0:
                    (2-s->clean_windows)*CF_APT_WINDOW-(s->block_bad?0:s->apt_n);
                d->contributed=contributed[i]; d->metrics_end_us=s->metrics_end_us;
                d->absorbed=private_pool.absorbed[i]; d->last_absorbed_us=private_pool.last_absorbed_us[i];
                d->discontinuities=s->discontinuities; d->current_faults=s->block_faults;
                d->samples=s->samples; d->failures=s->failures; d->last_failure_us=s->last_failure_us;
                d->last_faults=s->last_faults; d->rct_failures=s->rct_failures; d->apt_failures=s->apt_failures; d->clip_warnings=s->clip_warning_blocks;
                d->good=s->blocks_ok; d->rejected=s->blocks_rejected; d->partial_n=s->n; d->m=s->metrics;
                if(s->n>=64) d->preview=cf_source_preview(s);
            }
            if(xQueueSend(tx_queue,&msg,0)!=pdTRUE) incr(&tx_drops);
            cf_wipe(&msg,sizeof(msg));
        }
    }
}
void app_main(void) {
    if(!cf_sha3_selftest()) abort();
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0,256,4096,0,NULL,0));
    uart_vfs_dev_use_driver(UART_NUM_0);
    observations=xQueueCreate(64,sizeof(observation)); tx_queue=xQueueCreate(8,sizeof(message));
    acquisition=xQueueCreate(64,sizeof(capture));
    radio_state=xEventGroupCreate(); if(!observations || !tx_queue || !acquisition || !radio_state) abort();
    for(unsigned i=0;i<CF_SOURCES;i++) {
        uint16_t *hist=i==0?adc_hist:(i==CF_AUX_ADC?aux_hist:(i==CF_TIMING?timing_hist:byte_hist[i]));
        cf_source_init(&sources[i],i,hist,(CF_IS_ADC(i) || i==CF_TIMING)?4096:256);
    }
    cf_source_init(&pool_measure,CF_RNG,pool_hist,256);
    radios_init(); esp_fill_random(session,sizeof(session)); hex(session_hex,session,16);
    cf_pool_init(&private_pool,session);
    uint8_t mac[6]; ESP_ERROR_CHECK(esp_read_mac(mac,ESP_MAC_WIFI_STA)); hex(device_hex,mac,6);
    adc_oneshot_unit_init_cfg_t unit={.unit_id=ADC_UNIT_1,.ulp_mode=ADC_ULP_MODE_DISABLE};
    adc_init_result=adc_oneshot_new_unit(&unit,&adc);
    adc_oneshot_chan_cfg_t channel={.atten=ADC_ATTEN_DB_12,.bitwidth=ADC_BITWIDTH_12};
    /* A shared unit failure affects both; channel setup errors remain local. */
    aux_init_result=adc_init_result;
    if(adc_init_result==ESP_OK) adc_init_result=adc_oneshot_config_channel(adc,ADC_CHANNEL_6,&channel);
    if(aux_init_result==ESP_OK) aux_init_result=adc_oneshot_config_channel(adc,ADC_CHANNEL_7,&channel);
    if(xTaskCreatePinnedToCore(tx_task,"cf_tx",8192,NULL,2,NULL,0)!=pdPASS) abort();
    if(xTaskCreatePinnedToCore(process_task,"cf_process",8192,NULL,3,NULL,1)!=pdPASS) abort();
    if(xTaskCreatePinnedToCore(sample_task,"cf_sample",4096,NULL,6,&sampler_handle,1)!=pdPASS) abort();
    const esp_timer_create_args_t timer_args={.callback=sample_tick,.name="cf_sample_tick",.skip_unhandled_events=true};
    ESP_ERROR_CHECK(esp_timer_create(&timer_args,&sample_timer));
    schedule.next_us=(uint64_t)esp_timer_get_time()+CF_SAMPLE_US;
    ESP_ERROR_CHECK(esp_timer_start_periodic(sample_timer,CF_SAMPLE_US));
}
