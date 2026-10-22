#ifndef ANDROID_PTHREAD_SYNC_H
#define ANDROID_PTHREAD_SYNC_H

#include "elf_loader_emulator.h"
#include "android_pthread_sync_types.h"
#include <cstring>
#include <limits>

inline bool dispatch_android_pthread_sync(EmulatorVM *vm, const std::string &name) {
    const bool known = name == "pthread_mutex_init" || name == "pthread_mutex_destroy" || name == "pthread_mutex_lock" || name == "pthread_mutex_unlock" || name == "pthread_mutex_trylock" || name == "pthread_rwlock_init" || name == "pthread_rwlock_destroy" || name == "pthread_rwlock_rdlock" || name == "pthread_rwlock_wrlock" || name == "pthread_rwlock_unlock" || name == "pthread_rwlock_tryrdlock" || name == "pthread_rwlock_trywrlock";
    if (!known) return false;
    if (!vm || !vm->uc) return true;
    auto fail = [&](const char *why) { vm->execution_error = std::string("Android pthread sync: ") + why + " (" + name + ")"; uc_emu_stop(vm->uc); };
    uint64_t args[2]{};
    if (uc_reg_read(vm->uc, UC_ARM64_REG_X0, &args[0]) != UC_ERR_OK || uc_reg_read(vm->uc, UC_ARM64_REG_X1, &args[1]) != UC_ERR_OK) { fail("cannot read arguments"); return true; }
    const bool rw = name.find("rwlock") != std::string::npos;
    const bool init = name == (rw ? "pthread_rwlock_init" : "pthread_mutex_init");
    const bool destroy = name == (rw ? "pthread_rwlock_destroy" : "pthread_mutex_destroy");
    const size_t bytes = rw ? 56 : 40;
    const uint64_t address = args[0];
    auto validate = [&](uint64_t p, size_t n, uint32_t perms) {
        if (!p || p > UINT64_MAX - n) return false;
        uc_mem_region *regions = nullptr; uint32_t count = 0;
        if (uc_mem_regions(vm->uc, &regions, &count) != UC_ERR_OK) return false;
        uint64_t cursor = p, end = p + n; bool ok = true;
        while (cursor < end) {
            uint64_t next = cursor;
            for (uint32_t i=0; i<count; ++i) {
                if (regions[i].begin <= cursor && regions[i].end >= cursor && (regions[i].perms & perms) == perms) {
                    next = regions[i].end == UINT64_MAX ? end : regions[i].end + 1; break;
                }
            }
            if (next == cursor) { ok = false; break; }
            cursor = next < end ? next : end;
        }
        if (regions) uc_free(regions);
        return ok;
    };
    auto read = [&](uint64_t p, void *out, size_t n) { return validate(p,n,UC_PROT_READ) && uc_mem_read(vm->uc,p,out,n)==UC_ERR_OK; };
    auto write = [&](uint64_t p, const void *in, size_t n) { return validate(p,n,UC_PROT_READ|UC_PROT_WRITE) && uc_mem_write(vm->uc,p,in,n)==UC_ERR_OK; };
    auto result_out = [&](uint64_t value) { if (uc_reg_write(vm->uc,UC_ARM64_REG_X0,&value)!=UC_ERR_OK) fail("cannot write result"); };
    if (!address || address > UINT64_MAX-bytes || (address & 3)) { fail("invalid or unaligned object address"); return true; }
    if (init && args[1] && ((args[1]&7) || args[1]>UINT64_MAX-8 || !validate(args[1],8,UC_PROT_READ))) { fail("invalid attr mapping or alignment"); return true; }
    if (!validate(address, bytes, UC_PROT_READ | UC_PROT_WRITE)) { fail("object is not readable and writable"); return true; }
    uint8_t object[56]{};
    if (!read(address,object,bytes)) { fail("object is not readable"); return true; }
    if (init && args[1]) { uint8_t attr[8]; if (!read(args[1],attr,8)) { fail("unmapped attr"); return true; } for (uint8_t b:attr) if (b) { fail("unsupported non-default attr"); return true; } }
    bool zero = true; for (size_t i=0;i<bytes;++i) if(object[i]) { zero=false; break; }
    uint64_t result=0;
    {
        std::lock_guard<std::mutex> guard(vm->guest_sync.mutex);
        auto &ms=vm->guest_sync.mutexes; auto &rs=vm->guest_sync.rwlocks;
        if (rw ? ms.count(address)!=0 : rs.count(address)!=0) { result=16; }
        else if (init) {
            if (rw) { auto i=rs.find(address); if(i!=rs.end()&&!i->second.destroyed) result=16; else if(i==rs.end()&&rs.size()>=4096) result=11; else { std::memset(object,0,bytes); if(!write(address,object,bytes)){fail("object is not writable");return true;} rs[address]=AndroidGuestRWLockState{}; } }
            else { auto i=ms.find(address); if(i!=ms.end()&&!i->second.destroyed) result=16; else if(i==ms.end()&&ms.size()>=4096) result=11; else { std::memset(object,0,bytes); if(!write(address,object,bytes)){fail("object is not writable");return true;} ms[address]=AndroidGuestMutexState{}; } }
        } else if (destroy) {
            if (rw) { auto i=rs.find(address); if(i==rs.end()) { if(!zero){fail("unsupported nonzero rwlock");return true;} if(rs.size()>=4096){result=11;} else {rs[address]=AndroidGuestRWLockState{0,false,true}; std::memset(object,0xA5,bytes);if(!write(address,object,bytes)){fail("object is not writable");return true;}} } else if(i->second.destroyed) result=22; else if(i->second.writer||i->second.readers) result=16; else {i->second.destroyed=true;std::memset(object,0xA5,bytes);if(!write(address,object,bytes)){fail("object is not writable");return true;}} }
            else { auto i=ms.find(address); if(i==ms.end()) { if(!zero){fail("unsupported nonzero mutex");return true;} if(ms.size()>=4096){result=11;} else {ms[address]=AndroidGuestMutexState{false,true};std::memset(object,0xA5,bytes);if(!write(address,object,bytes)){fail("object is not writable");return true;}} } else if(i->second.destroyed) result=22; else if(i->second.held) result=16; else {i->second.destroyed=true;std::memset(object,0xA5,bytes);if(!write(address,object,bytes)){fail("object is not writable");return true;}} }
        } else if(rw) {
            auto i=rs.find(address);
            if(i==rs.end()) { if(!zero){fail("unsupported nonzero rwlock");return true;} if(rs.size()>=4096) result=11; else i=rs.emplace(address,AndroidGuestRWLockState{}).first; }
            if(!result) { auto &s=i->second; if(s.destroyed){fail("use after destroy");return true;} if(name=="pthread_rwlock_unlock"){if(s.writer)s.writer=false;else if(s.readers)--s.readers;else result=1;} else if(name=="pthread_rwlock_rdlock"||name=="pthread_rwlock_tryrdlock"){if(s.writer){if(name=="pthread_rwlock_tryrdlock")result=16;else{fail("blocking rwlock contention requires scheduler");return true;}}else if(s.readers==UINT32_MAX)result=11;else ++s.readers;} else if(s.writer||s.readers){if(name=="pthread_rwlock_trywrlock")result=16;else{fail("blocking rwlock contention requires scheduler");return true;}}else s.writer=true; }
        } else {
            auto i=ms.find(address);
            if(i==ms.end()){if(!zero){fail("unsupported nonzero mutex");return true;}if(ms.size()>=4096)result=11;else i=ms.emplace(address,AndroidGuestMutexState{}).first;}
            if(!result){auto &s=i->second;if(s.destroyed){fail("use after destroy");return true;}if(name=="pthread_mutex_unlock"){if(!s.held)result=1;else s.held=false;}else if(s.held){if(name=="pthread_mutex_trylock")result=16;else{fail("blocking mutex contention requires scheduler");return true;}}else s.held=true;}
        }
    }
    result_out(result); return true;
}
#endif
