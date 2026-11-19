/*
 ============================================================================
 Name        : hev-flow-stats.c
 Description : Per-connection byte counts for FoxyVPN's per-app usage
 ============================================================================

 FoxyVPN addition (not part of upstream hev-socks5-tunnel); see the header.

 Threads: open / add / close run on hev's own thread, drain runs on a thread of
 the app. The table layout is guarded by a mutex that is held only for a few
 field writes on hev's side; the byte counters are plain atomics.
 */

#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

#include "hev-flow-stats.h"

#define FLOW_MAX 2048

typedef struct _HevFlow HevFlow;

struct _HevFlow
{
    uint64_t seq; /* 0 = free */
    uint64_t tx;  /* atomic: bytes since the last drain */
    uint64_t rx;  /* atomic */
    uint8_t proto;
    uint8_t family;
    uint8_t closed;
    uint8_t announced;
    uint16_t sport;
    uint16_t dport;
    uint8_t src[16];
    uint8_t dst[16];
};

static HevFlow flows[FLOW_MAX];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int enabled;
static int pending;
static int used;
static int hint;
static int high; /* every used slot is below this index */
static uint64_t next_seq = 1;

static int
copy_addr (uint8_t *out, const ip_addr_t *addr)
{
    memset (out, 0, 16);
    if (IP_IS_V6 (addr)) {
        memcpy (out, ip_2_ip6 (addr)->addr, 16);
        return 6;
    }
    memcpy (out, &ip_2_ip4 (addr)->addr, 4);
    return 4;
}

int
hev_flow_stats_open (int proto, const ip_addr_t *src, uint16_t sport,
                     const ip_addr_t *dst, uint16_t dport)
{
    int i, n, handle = 0;

    if (!__atomic_load_n (&enabled, __ATOMIC_RELAXED) || !src || !dst)
        return 0;

    pthread_mutex_lock (&lock);
    if (!enabled || used >= FLOW_MAX)
        goto exit;

    for (n = 0; n < FLOW_MAX; n++) {
        i = (hint + n) % FLOW_MAX;
        if (flows[i].seq == 0)
            break;
    }
    if (n == FLOW_MAX)
        goto exit;

    HevFlow *f = &flows[i];
    f->seq = next_seq++;
    __atomic_store_n (&f->tx, 0, __ATOMIC_RELAXED);
    __atomic_store_n (&f->rx, 0, __ATOMIC_RELAXED);
    f->proto = (uint8_t)proto;
    f->family = (uint8_t)copy_addr (f->src, src);
    copy_addr (f->dst, dst);
    f->sport = sport;
    f->dport = dport;
    f->closed = 0;
    f->announced = 0;

    used++;
    hint = (i + 1) % FLOW_MAX;
    if (i + 1 > high)
        high = i + 1;
    pending = 1;
    handle = i + 1;
    pthread_cond_signal (&cond);
exit:
    pthread_mutex_unlock (&lock);
    return handle;
}

void
hev_flow_stats_add (int handle, uint64_t tx, uint64_t rx)
{
    HevFlow *f;

    if (handle <= 0 || handle > FLOW_MAX)
        return;

    f = &flows[handle - 1];
    if (tx)
        __atomic_fetch_add (&f->tx, tx, __ATOMIC_RELAXED);
    if (rx)
        __atomic_fetch_add (&f->rx, rx, __ATOMIC_RELAXED);
}

void
hev_flow_stats_close (int handle)
{
    if (handle <= 0 || handle > FLOW_MAX)
        return;

    pthread_mutex_lock (&lock);
    if (flows[handle - 1].seq)
        flows[handle - 1].closed = 1;
    pthread_mutex_unlock (&lock);
}

void
hev_flow_stats_close_all (void)
{
    int i;

    pthread_mutex_lock (&lock);
    for (i = 0; i < high; i++)
        if (flows[i].seq)
            flows[i].closed = 1;
    pthread_mutex_unlock (&lock);
}

void
hev_flow_stats_enable (int on)
{
    pthread_mutex_lock (&lock);
    __atomic_store_n (&enabled, on ? 1 : 0, __ATOMIC_RELAXED);
    pthread_cond_broadcast (&cond);
    pthread_mutex_unlock (&lock);
}

static void
put_addr (int64_t *out, const uint8_t *b)
{
    uint64_t hi = 0, lo = 0;
    int i;

    for (i = 0; i < 8; i++) {
        hi = (hi << 8) | b[i];
        lo = (lo << 8) | b[8 + i];
    }
    out[0] = (int64_t)hi;
    out[1] = (int64_t)lo;
}

int
hev_flow_stats_drain (int64_t *out, int max_records, int wait_ms)
{
    int i, count = 0;

    pthread_mutex_lock (&lock);

    if (wait_ms > 0 && !pending && enabled) {
        struct timespec ts;

        clock_gettime (CLOCK_REALTIME, &ts);
        ts.tv_sec += wait_ms / 1000;
        ts.tv_nsec += (long)(wait_ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000L;
        }
        while (!pending && enabled) {
            if (pthread_cond_timedwait (&cond, &lock, &ts) == ETIMEDOUT)
                break;
        }
    }
    pending = 0;

    for (i = 0; i < high && count < max_records; i++) {
        HevFlow *f = &flows[i];
        uint64_t tx, rx;
        int is_new;

        if (!f->seq)
            continue;

        tx = __atomic_exchange_n (&f->tx, 0, __ATOMIC_RELAXED);
        rx = __atomic_exchange_n (&f->rx, 0, __ATOMIC_RELAXED);
        is_new = !f->announced;
        if (!is_new && !tx && !rx && !f->closed)
            continue;

        int64_t *r = out + (int64_t)count * HEV_FLOW_RECORD_LONGS;
        r[0] = (int64_t)f->seq;
        r[1] = (int64_t)f->proto | ((int64_t)f->family << 8) |
               ((int64_t)(f->closed ? 1 : 0) << 16) |
               ((int64_t)is_new << 17);
        r[2] = f->sport;
        r[3] = f->dport;
        put_addr (r + 4, f->src);
        put_addr (r + 6, f->dst);
        r[8] = (int64_t)tx;
        r[9] = (int64_t)rx;
        count++;

        f->announced = 1;
        if (f->closed) {
            f->seq = 0;
            used--;
        }
    }

    /* Slots that did not fit stay for the next drain. */
    if (count >= max_records)
        pending = 1;

    while (high > 0 && flows[high - 1].seq == 0)
        high--;
    if (hint >= high && used == 0)
        hint = 0;

    pthread_mutex_unlock (&lock);
    return count;
}

int
hev_flow_stats_capacity (void)
{
    return FLOW_MAX;
}
