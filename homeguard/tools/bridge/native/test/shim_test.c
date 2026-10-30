#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
struct tag_client_connect_info { uint32_t id_type; char dev_id[0x1000]; };
void *_Z21NAT_CLIENT_ConnectDevRK24_tag_client_connect_infobi(const struct tag_client_connect_info *, _Bool, int);
extern char hg_last_dev_id[64];
int main(void) {
  static struct tag_client_connect_info info;
  strcpy(info.dev_id, "0123456789ABCDEF0123456789ABCDEF");
  void *r = _Z21NAT_CLIENT_ConnectDevRK24_tag_client_connect_infobi(&info, 1, 7);
  assert((intptr_t)r == 7);
  assert(strcmp(hg_last_dev_id, "NB8AF056T0D2") == 0);          /* swapped for the call */
  assert(strcmp(info.dev_id, "0123456789ABCDEF0123456789ABCDEF") == 0); /* restored after */
  strcpy(info.dev_id, "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
  _Z21NAT_CLIENT_ConnectDevRK24_tag_client_connect_infobi(&info, 0, 3);
  assert(strcmp(hg_last_dev_id, "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF") == 0); /* unknown: untouched */
  puts("hg_p2p_serial: ok");
  return 0;
}
