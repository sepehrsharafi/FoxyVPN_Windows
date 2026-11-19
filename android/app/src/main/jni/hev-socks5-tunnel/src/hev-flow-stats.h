/*
 ============================================================================
 Name        : hev-flow-stats.h
 Description : Per-connection byte counts for FoxyVPN's per-app usage
 ============================================================================

 FoxyVPN addition (not part of upstream hev-socks5-tunnel).

 Each TCP / UDP session gets a slot holding its addresses and the bytes moved
 since the last drain. The Android app drains the table from its own thread
 (JNI TProxyDrainFlows) and asks Android which app owns each connection. The
 data path only does an atomic add per read / write; nothing here can block or
 change how packets move. While nobody drains (the feature off, or Android < 10),
 hev_flow_stats_open returns 0 and every other call is a no-op.
 */

#ifndef __HEV_FLOW_STATS_H__
#define __HEV_FLOW_STATS_H__

#include <stdint.h>

#include <lwip/ip_addr.h>

/* Values of one drained record, 10 int64 each. */
#define HEV_FLOW_RECORD_LONGS 10

/* Returns a slot handle (> 0), or 0 when the table is off or full. */
int hev_flow_stats_open (int proto, const ip_addr_t *src, uint16_t sport,
                         const ip_addr_t *dst, uint16_t dport);

/* tx: app -> internet (upload), rx: internet -> app (download). */
void hev_flow_stats_add (int handle, uint64_t tx, uint64_t rx);

void hev_flow_stats_close (int handle);

/* hev (re)starts: every slot of an earlier run is closed. */
void hev_flow_stats_close_all (void);

/* Turns the table on or off (off also wakes a waiting drain). */
void hev_flow_stats_enable (int on);

/*
 * Waits up to wait_ms for a new connection (0 = do not wait), then copies one
 * record per slot with news into out (at most max_records) and frees the
 * slots that were closed. Returns the number of records.
 */
int hev_flow_stats_drain (int64_t *out, int max_records, int wait_ms);

int hev_flow_stats_capacity (void);

#endif /* __HEV_FLOW_STATS_H__ */
