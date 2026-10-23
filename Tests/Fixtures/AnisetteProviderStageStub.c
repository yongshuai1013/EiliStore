#include <stdlib.h>
#include <string.h>
#include "anisette_core.h"

static int mode = 0;
void anisette_stage_test_set_mode(int value) { mode = value; }

static int result(char **out, const char *json, int code, int nil_out) {
    if (nil_out) { *out = NULL; return code; }
    *out = (char *)malloc(strlen(json) + 1);
    strcpy(*out, json);
    return code;
}
void free_c_string(char *ptr) { free(ptr); }
void reset_anisette_vm_uc(void) {}

int32_t get_anisette_headers_uc(const char *l, const char *p, const uint8_t *i,
 const uint8_t *a, uint32_t n, char **out) {
    (void)l;(void)p;(void)i;(void)a;(void)n;
    if (mode == 1) return result(out, "", -2, 1);
    if (mode == 2) return result(out, "{bad", -5, 0);
    if (mode == 3) return result(out, "{\"error\":\"ADI-SECRET\"}", -12345, 0);
    if (mode == 4) return result(out, "{\"error\":\"loader detail SECRET /private/path\",\"diagnostic_phase\":\"loadLibrary\",\"native_code\":-42}", -2, 0);
    if (mode == 5) return result(out, "{\"X-Apple-I-MD\":\"synthetic-otp\",\"X-Apple-I-MD-M\":\"synthetic-machine\"}", -9, 0);
    if (mode == 6) return result(out, "{\"error\":\"synthetic error\"}", 0, 0);
    if (mode == 7) return result(out, "{\"error\":\"secret\",\"diagnostic_phase\":\"/private/path injected\",\"native_code\":true}", -3, 0);
    if (mode == 8) return result(out, "{\"error\":\"secret\",\"diagnostic_phase\":\"loadLibrary\",\"native_code\":1.5}", -3, 0);
    if (mode == 9) return result(out, "{}", 0, 0);
    return result(out, "{\"X-Apple-I-MD\":\"synthetic-otp\",\"X-Apple-I-MD-M\":\"synthetic-machine\"}", 0, 0);
}
int32_t start_provision_uc(const char *l, const char *p, const uint8_t *i,
 const uint8_t *s, uint32_t n, char **out) {
    (void)l;(void)p;(void)i;(void)s;(void)n;
    if (mode == 1) return result(out, "", -2, 1);
    if (mode == 2) return result(out, "{bad", -5, 0);
    if (mode >= 3) return get_anisette_headers_uc(l, p, i, s, n, out);
    return result(out, "{\"cpim_base64\":\"AQID\",\"session\":1234}", 0, 0);
}
int32_t end_provision_uc(const char *l, const char *p, const uint8_t *i,
 uint32_t session, const uint8_t *ptm, uint32_t pn, const uint8_t *tk,
 uint32_t tn, char **out) {
    (void)l;(void)p;(void)i;(void)session;(void)ptm;(void)pn;(void)tk;(void)tn;
    if (mode == 1) return result(out, "", -2, 1);
    if (mode == 2) return result(out, "{bad", -5, 0);
    if (mode >= 3) return get_anisette_headers_uc(l, p, i, ptm, pn, out);
    return result(out, "{\"adi_pb_base64\":\"BAUG\"}", 0, 0);
}
#ifdef __APPLE__
int32_t get_anisette_headers_c(const char *l,const char *p,const uint8_t *i,const uint8_t *a,uint32_t n,char **o) {(void)l;(void)p;(void)i;(void)a;(void)n; return result(o,"{\"X-Apple-I-MD\":\"synthetic-otp\",\"X-Apple-I-MD-M\":\"synthetic-machine\"}",0,0);}
int32_t start_provision_c(const char *l,const char *p,const uint8_t *i,const uint8_t *s,uint32_t n,char **o) {(void)l;(void)p;(void)i;(void)s;(void)n; return result(o,"{\"cpim_base64\":\"AQID\",\"session\":1234}",0,0);}
int32_t end_provision_c(const char *l,const char *p,const uint8_t *i,uint32_t session,const uint8_t *ptm,uint32_t pn,const uint8_t *tk,uint32_t tn,char **o) {(void)l;(void)p;(void)i;(void)session;(void)ptm;(void)pn;(void)tk;(void)tn; return result(o,"{\"adi_pb_base64\":\"BAUG\"}",0,0);}
#endif
