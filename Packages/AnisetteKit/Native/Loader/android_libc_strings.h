#ifndef ANDROID_LIBC_STRINGS_H
#define ANDROID_LIBC_STRINGS_H

// Include after elf_loader_emulator.h (which supplies EmulatorVM and Unicorn types).
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <climits>
#include <limits>
#include <string>
#include <vector>

static constexpr uint64_t kAndroidStringBufferLimit = 64ULL * 1024 * 1024;

static inline bool android_string_fail(EmulatorVM *vm, const std::string &why) {
    if (vm && vm->uc) {
        vm->execution_error = why;
        uc_emu_stop(vm->uc);
    }
    return false;
}
static inline bool android_string_reg(EmulatorVM *vm, int reg, uint64_t &v) {
    if (!vm || !vm->uc || uc_reg_read(vm->uc, reg, &v) != UC_ERR_OK)
        return android_string_fail(vm, "android libc string: register read failed");
    return true;
}
static inline bool android_string_set(EmulatorVM *vm, uint64_t v) {
    if (uc_reg_write(vm->uc, UC_ARM64_REG_X0, &v) != UC_ERR_OK)
        return android_string_fail(vm, "android libc string: return register write failed");
    return true;
}
static inline bool android_string_read(EmulatorVM *vm, uint64_t addr, uint8_t *dst, size_t n) {
    if (!n) return true;
    if (!addr || addr > UINT64_MAX - n || uc_mem_read(vm->uc, addr, dst, n) != UC_ERR_OK)
        return android_string_fail(vm, "android libc string: invalid guest memory read");
    return true;
}
static inline bool android_string_write(EmulatorVM *vm, uint64_t addr, const uint8_t *src, size_t n) {
    if (!n) return true;
    if (!addr || addr > UINT64_MAX - n || uc_mem_write(vm->uc, addr, src, n) != UC_ERR_OK)
        return android_string_fail(vm, "android libc string: invalid guest memory write");
    return true;
}
static inline bool android_string_read_cstr(EmulatorVM *vm, uint64_t addr, std::string &out) {
    out.clear();
    for (uint64_t i=0; i<kAndroidStringBufferLimit; ++i) {
        uint8_t c;
        if (addr > UINT64_MAX-i) return android_string_fail(vm, "android libc string: pointer overflow");
        if (!android_string_read(vm, addr+i, &c, 1)) return false;
        if (!c) return true;
        out.push_back((char)c);
    }
    return android_string_fail(vm, "android libc string: unterminated/oversized guest string");
}
// Read at most n bytes: unlike strlen/cstr handling, bytes after n need not be readable.
static inline bool android_string_read_bounded(EmulatorVM *vm, uint64_t addr, uint64_t n, std::string &out) {
    out.clear();
    for (uint64_t i=0; i<std::min(n, kAndroidStringBufferLimit); ++i) {
        uint8_t c;
        if (addr > UINT64_MAX-i) return android_string_fail(vm, "android libc string: pointer overflow");
        if (!android_string_read(vm, addr+i, &c, 1)) return false;
        if (!c) return true;
        out.push_back((char)c);
    }
    if (n > kAndroidStringBufferLimit) return android_string_fail(vm, "android libc string: bounded scan limit exceeded");
    return true;
}
static inline bool dispatch_android_libc_string(EmulatorVM *vm, const std::string &name) {
    uint64_t a=0,b=0,c=0;
    if (!vm || !vm->uc) return android_string_fail(vm, "android libc string: invalid VM");
    auto reg = [&](int r,uint64_t &v){return android_string_reg(vm,r,v);};
    auto result = [&](uint64_t v){return android_string_set(vm,v);};
    std::string x,y;
    if (name=="atoi" || name=="atoll") {
        if (!reg(UC_ARM64_REG_X0,a) || !android_string_read_cstr(vm,a,x)) return true;
        const char *p=x.c_str(); while (std::isspace((unsigned char)*p)) ++p;
        bool neg=false; if (*p=='+'||*p=='-') {neg=*p++=='-';}
        uint64_t limit=neg ? (uint64_t)LLONG_MAX+1ULL : (uint64_t)LLONG_MAX, val=0;
        while (*p>='0'&&*p<='9') { unsigned d=(unsigned)(*p++-'0'); if(val>(limit-d)/10) val=limit; else val=val*10+d; }
        int64_t signedv=neg ? (val==(uint64_t)LLONG_MAX+1ULL ? LLONG_MIN : -(int64_t)val) : (int64_t)val;
        return result((uint64_t)(name=="atoi" ? (int64_t)(int32_t)signedv : signedv));
    }
    if (name=="memmove" || name=="memmem" || name=="__memchr_chk") {
        if (!reg(UC_ARM64_REG_X0,a)||!reg(UC_ARM64_REG_X1,b)||!reg(UC_ARM64_REG_X2,c)) return true;
        uint64_t n=name=="memmem" ? b : c;
        if (name=="__memchr_chk") { uint64_t bound=0; if(!reg(UC_ARM64_REG_X3,bound)) return true; if(n>bound) return android_string_fail(vm,"__memchr_chk: object-size bound exceeded"),true; }
        uint64_t m=0; if(name=="memmem" && !reg(UC_ARM64_REG_X3,m)) return true;
        if (name=="memmem" && !m) return result(a);
        if (name=="memmem" && m>n) return result(0);
        if (n>kAndroidStringBufferLimit || m>kAndroidStringBufferLimit) return android_string_fail(vm,"android libc string: buffer limit exceeded"),true;
        uint64_t source=name=="memmove" ? b : a;
        std::vector<uint8_t> src((size_t)n);
        if(!android_string_read(vm,source,src.data(),src.size())) return true;
        if(name=="memmove") { if(!android_string_write(vm,a,src.data(),src.size())) return true; return result(a); }
        if(name=="__memchr_chk") { uint64_t found=0; for(size_t i=0;i<src.size();++i) if(src[i]==(uint8_t)b){found=a+i;break;} return result(found); }
        // memmem(haystack, haystack_len, needle, needle_len)
        std::vector<uint8_t> needle((size_t)m); if(!android_string_read(vm,c,needle.data(),needle.size())) return true;
        uint64_t found=0; if(!m) found=a; else if(m<=n) { auto it=std::search(src.begin(),src.end(),needle.begin(),needle.end()); if(it!=src.end()) found=a+(uint64_t)(it-src.begin()); }
        return result(found);
    }
    if (name=="strnlen") {
        if(!reg(UC_ARM64_REG_X0,a)||!reg(UC_ARM64_REG_X1,b)) return true;
        uint64_t len=0;
        for(;len<std::min(b,kAndroidStringBufferLimit);++len) {
            uint8_t ch;
            if(a>UINT64_MAX-len) return android_string_fail(vm,"strnlen pointer overflow"),true;
            if(!android_string_read(vm,a+len,&ch,1)) return true;
            if(!ch) return result(len);
        }
        if(b>kAndroidStringBufferLimit) return android_string_fail(vm,"strnlen limit exceeded"),true;
        return result(len);
    }
    if (name=="strchr"||name=="strrchr"||name=="strstr"||name=="strcat"||name=="strncat"||name=="strcspn"||name=="strspn"||name=="strpbrk") {
        if(!reg(UC_ARM64_REG_X0,a)||!reg(UC_ARM64_REG_X1,b)) return true;
        if(!android_string_read_cstr(vm,a,x))return true;
        if(name=="strchr"||name=="strrchr") {
            uint8_t ch=(uint8_t)b; size_t found=std::string::npos;
            for(size_t i=0;i<=x.size();++i) if((uint8_t)(i<x.size()?x[i]:0)==ch){found=i;if(name=="strchr")break;}
            return result(found==std::string::npos?0:a+found);
        }
        if(name=="strncat") {
            if(!reg(UC_ARM64_REG_X2,c)) return true;
            if(c && !android_string_read_bounded(vm,b,c,y))return true;
        } else if(!android_string_read_cstr(vm,b,y)) return true;
        if(name=="strstr"){size_t p=x.find(y);return result(p==std::string::npos?0:a+p);}
        if(name=="strcspn"||name=="strspn"||name=="strpbrk") {
            size_t i=0; while(i<x.size() && (name=="strspn" ? y.find(x[i])!=std::string::npos : y.find(x[i])==std::string::npos)) ++i;
            if(name=="strpbrk")return result(i<x.size()?a+i:0); return result(i);
        }
        if(name=="strcat" && !reg(UC_ARM64_REG_X2,c))return true;
        size_t end=x.size(), ylen=y.size();
        if(end+ylen+1>kAndroidStringBufferLimit)return android_string_fail(vm,"concatenation limit exceeded"),true;
        std::vector<uint8_t> out; out.insert(out.end(),x.begin(),x.begin()+end);out.insert(out.end(),y.begin(),y.begin()+ylen);out.push_back(0);
        if(!android_string_write(vm,a,out.data(),out.size()))return true;return result(a);
    }
    return false;
}
#endif
