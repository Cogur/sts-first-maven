/* Stand-in for libNatClientSDK: records the device code it was given. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
struct tag_client_connect_info { uint32_t id_type; char dev_id[0x1000]; };
char hg_last_dev_id[64];
void *_Z21NAT_CLIENT_ConnectDevRK24_tag_client_connect_infobi(const struct tag_client_connect_info *info, _Bool f, int a) {
  strncpy(hg_last_dev_id, info->dev_id, sizeof hg_last_dev_id - 1);
  return (void *)(intptr_t)(f ? a : -a);
}
