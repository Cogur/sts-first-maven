/*
 * hg_p2p_serial: makes TVT's Linux NET_SDK log in by cloud serial (P2P 2.0).
 *
 * For NET_SDK_LoginEx(..., NET_SDK_CONNECT_NAT20, serial) libdvrnetsdk.so
 * passes upper-case MD5(serial) to libNatClientSDK as the device code, but
 * TVT's P2P servers know recorders by the plain serial, so every lookup
 * fails ("device not online", SDK error 8). This library sits in front of
 * NAT_CLIENT_ConnectDev, swaps a known MD5 back to its serial for the
 * duration of the call and forwards everything else untouched.
 *
 * Mapping comes from HG_P2P_SERIAL_MAP="<MD5HEX>=<SERIAL>[,...]", which the
 * bridge sets before loading this library (dlopen RTLD_GLOBAL, ahead of
 * libdvrnetsdk.so). HG_P2P_DEBUG=1 logs each call to stderr.
 *
 * Struct layout and the root cause were documented by the Argus-Community
 * project (native/p2pserial); this is an independent implementation.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEV_ID_LEN 0x1000
#define MAX_MAP 64

struct tag_client_connect_info {
  uint32_t id_type; /* 0 = by device code */
  char dev_id[DEV_ID_LEN];
};

typedef void *(*connect_fn)(const struct tag_client_connect_info *, _Bool, int);

static struct {
  char md5[33];
  char serial[64];
} g_map[MAX_MAP];
static int g_count;
static int g_debug;

__attribute__((constructor)) static void hg_init(void) {
  const char *dbg = getenv("HG_P2P_DEBUG");
  g_debug = dbg && dbg[0] == '1';
  const char *env = getenv("HG_P2P_SERIAL_MAP");
  if (!env) return;
  char buf[MAX_MAP * 100];
  strncpy(buf, env, sizeof buf - 1);
  buf[sizeof buf - 1] = 0;
  for (char *save = NULL, *item = strtok_r(buf, ",", &save); item && g_count < MAX_MAP;
       item = strtok_r(NULL, ",", &save)) {
    char *eq = strchr(item, '=');
    if (!eq || eq - item != 32 || strlen(eq + 1) == 0 || strlen(eq + 1) >= sizeof g_map[0].serial) continue;
    memcpy(g_map[g_count].md5, item, 32);
    g_map[g_count].md5[32] = 0;
    strcpy(g_map[g_count].serial, eq + 1);
    g_count++;
  }
}

/* NAT_CLIENT_ConnectDev(const _tag_client_connect_info&, bool, int) */
void *_Z21NAT_CLIENT_ConnectDevRK24_tag_client_connect_infobi(const struct tag_client_connect_info *info,
                                                             _Bool flag, int arg) {
  static connect_fn real;
  if (!real) real = (connect_fn)dlsym(RTLD_NEXT, "_Z21NAT_CLIENT_ConnectDevRK24_tag_client_connect_infobi");
  if (!real) {
    fprintf(stderr, "hg_p2p_serial: vendor NAT_CLIENT_ConnectDev not found\n");
    return NULL;
  }
  struct tag_client_connect_info *mut = (struct tag_client_connect_info *)info;
  for (int i = 0; i < g_count; i++) {
    if (strncmp(mut->dev_id, g_map[i].md5, 33) == 0) {
      char saved[33];
      memcpy(saved, mut->dev_id, sizeof saved);
      memset(mut->dev_id, 0, sizeof saved);
      strcpy(mut->dev_id, g_map[i].serial);
      if (g_debug) fprintf(stderr, "hg_p2p_serial: device code %.4s... -> plain serial\n", saved);
      void *r = real(info, flag, arg);
      memset(mut->dev_id, 0, sizeof saved);
      memcpy(mut->dev_id, saved, sizeof saved);
      return r;
    }
  }
  if (g_debug) fprintf(stderr, "hg_p2p_serial: device code passed through unchanged\n");
  return real(info, flag, arg);
}
