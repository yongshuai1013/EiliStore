#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <idevice.h>

static int parse_remote, parse_lockdown, free_remote, free_lockdown;
static int tunnel_calls, provider_calls, pair_setup_calls;
static int rsd_calls[5], ordinary_calls[5];
static int adapter_close_calls, adapter_free_calls, handshake_free_calls, provider_free_calls, error_free_calls;
static int tunnel_pair_flag, tunnel_port;
static int logger_init_calls;
static int tunnel_callback_present, tunnel_context_present;
static int mode; /* 1 parsing failure; 2 tunnel failure; 3 service failure; 4 provider failure */
static IdeviceFfiError synthetic_error = { 73, 9, "SYNTHETIC_RUST_ERROR_SENTINEL" };
void transport_reset(void) { memset(rsd_calls,0,sizeof(rsd_calls)); memset(ordinary_calls,0,sizeof(ordinary_calls)); parse_remote=parse_lockdown=free_remote=free_lockdown=tunnel_calls=provider_calls=pair_setup_calls=adapter_close_calls=adapter_free_calls=handshake_free_calls=provider_free_calls=error_free_calls=tunnel_pair_flag=tunnel_port=0; mode=0; }
void transport_set_mode(int m) { mode=m; }
int transport_count(int which) { switch(which) { case 0:return parse_remote; case 1:return parse_lockdown; case 2:return free_remote; case 3:return free_lockdown; case 4:return tunnel_calls; case 5:return provider_calls; case 6:return pair_setup_calls; case 7:return adapter_close_calls; case 8:return adapter_free_calls; case 9:return handshake_free_calls; case 10:return provider_free_calls; case 11:return error_free_calls; case 12:return tunnel_pair_flag; case 13:return tunnel_port; case 14:return logger_init_calls; case 15:return tunnel_callback_present; case 16:return tunnel_context_present; default: if(which>=20 && which<25)return rsd_calls[which-20]; if(which>=30 && which<35)return ordinary_calls[which-30]; return -1; } }
enum IdeviceLoggerError idevice_init_logger(enum IdeviceLogLevel a, enum IdeviceLogLevel b, char *c) { (void)a;(void)b;(void)c; logger_init_calls++; return getenv("TEST_LOGGER_FAILURE") ? FileError : Success; }
struct IdeviceFfiError *rp_pairing_file_from_bytes(const uint8_t *d, uintptr_t n, struct RpPairingFileHandle **out) { (void)d;(void)n; parse_remote++; if(mode==1)return &synthetic_error; *out=(void*)0x101; return NULL; }
void rp_pairing_file_free(struct RpPairingFileHandle *p) { (void)p; free_remote++; }
struct IdeviceFfiError *idevice_pairing_file_from_bytes(const uint8_t *d, uintptr_t n, struct IdevicePairingFile **out) { (void)d;(void)n; parse_lockdown++; if(mode==1)return &synthetic_error; *out=(void*)0x102; return NULL; }
void idevice_pairing_file_free(struct IdevicePairingFile *p) { (void)p; free_lockdown++; }
struct IdeviceFfiError *tunnel_create_rppairing_with_options(const idevice_sockaddr *a, idevice_socklen_t n, const char *h, struct RpPairingFileHandle *p, bool pair, const char *(*cb)(void *), void *ctx, struct AdapterHandle **outa, struct RsdHandshakeHandle **outh) { (void)n;(void)h;(void)p;tunnel_calls++; tunnel_pair_flag=pair; tunnel_callback_present=cb!=NULL; tunnel_context_present=ctx!=NULL; tunnel_port=ntohs(((const struct sockaddr_in*)a)->sin_port); if(pair)pair_setup_calls++; if(mode==2)return &synthetic_error; *outa=(void*)0x103; *outh=(void*)0x104; return NULL; }
struct IdeviceFfiError *idevice_tcp_provider_new(const idevice_sockaddr *a, struct IdevicePairingFile *p, const char *l, struct IdeviceProviderHandle **out) { (void)a;(void)p;(void)l;provider_calls++; if(mode==4)return &synthetic_error; *out=(void*)0x105; return NULL; }
void idevice_provider_free(struct IdeviceProviderHandle *p) { (void)p;provider_free_calls++; }
struct IdeviceFfiError *adapter_close(struct AdapterHandle *p) { (void)p;adapter_close_calls++; return NULL; }
void adapter_free(struct AdapterHandle *p) { (void)p;adapter_free_calls++; }
void rsd_handshake_free(struct RsdHandshakeHandle *p) { (void)p;handshake_free_calls++; }
void idevice_error_free(struct IdeviceFfiError *e) { if(e==&synthetic_error) { error_free_calls++; if(mode==1) mode=0; } }
#define SERVICE(N, TYPE, IDX) \
struct IdeviceFfiError *N##_client_connect_rsd(struct AdapterHandle *a, struct RsdHandshakeHandle *h, struct TYPE **out) { (void)a;(void)h;rsd_calls[IDX]++; if(mode==3)return &synthetic_error; *out=(void*)(uintptr_t)(0x200+IDX); return NULL; } \
struct IdeviceFfiError *N##_client_connect(struct IdeviceProviderHandle *p, struct TYPE **out) { (void)p;ordinary_calls[IDX]++; if(mode==3)return &synthetic_error; *out=(void*)(uintptr_t)(0x200+IDX); return NULL; }
SERVICE(afc, AfcClientHandle, 0)
struct IdeviceFfiError *installation_proxy_connect_rsd(struct AdapterHandle*a,struct RsdHandshakeHandle*h,struct InstallationProxyClientHandle**o){(void)a;(void)h;rsd_calls[1]++;if(mode==3)return &synthetic_error;*o=(void*)0x201;return NULL;}
struct IdeviceFfiError *installation_proxy_connect(struct IdeviceProviderHandle*p,struct InstallationProxyClientHandle**o){(void)p;ordinary_calls[1]++;if(mode==3)return &synthetic_error;*o=(void*)0x201;return NULL;}
struct IdeviceFfiError *misagent_connect_rsd(struct AdapterHandle*a,struct RsdHandshakeHandle*h,struct MisagentClientHandle**o){(void)a;(void)h;rsd_calls[2]++;if(mode==3)return &synthetic_error;*o=(void*)0x202;return NULL;}
struct IdeviceFfiError *misagent_connect(struct IdeviceProviderHandle*p,struct MisagentClientHandle**o){(void)p;ordinary_calls[2]++;if(mode==3)return &synthetic_error;*o=(void*)0x202;return NULL;}
struct IdeviceFfiError *heartbeat_connect_rsd(struct AdapterHandle*a,struct RsdHandshakeHandle*h,struct HeartbeatClientHandle**o){(void)a;(void)h;rsd_calls[3]++;if(mode==3)return &synthetic_error;*o=(void*)0x203;return NULL;}
struct IdeviceFfiError *heartbeat_connect(struct IdeviceProviderHandle*p,struct HeartbeatClientHandle**o){(void)p;ordinary_calls[3]++;if(mode==3)return &synthetic_error;*o=(void*)0x203;return NULL;}
struct IdeviceFfiError *lockdownd_connect_rsd(struct AdapterHandle*a,struct RsdHandshakeHandle*h,struct LockdowndClientHandle**o){(void)a;(void)h;rsd_calls[4]++;if(mode==3)return &synthetic_error;*o=(void*)0x204;return NULL;}
struct IdeviceFfiError *lockdownd_connect(struct IdeviceProviderHandle*p,struct LockdowndClientHandle**o){(void)p;ordinary_calls[4]++;if(mode==3)return &synthetic_error;*o=(void*)0x204;return NULL;}
