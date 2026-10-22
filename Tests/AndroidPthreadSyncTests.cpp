// Synthetic guest-only tests; no Apple library, account, or network access.
#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp"
#include "../Packages/AnisetteKit/Native/Loader/android_pthread_sync.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>

static int32_t invoke(EmulatorVM &vm, const char *name, uint64_t a, uint64_t b=0) {
    const uint64_t stub=vm.register_import(name); assert(stub);
    vm.execution_error.clear();
    return run_vm_procedure(&vm,stub,{a,b},100000,1000);
}
static void zero(EmulatorVM &vm,uint64_t p,size_t n) {
    std::vector<uint8_t> b(n); assert(uc_mem_write(vm.uc,p,b.data(),n)==UC_ERR_OK);
}
int main() {
    EmulatorVM vm; assert(vm.initialization_error==UC_ERR_OK);
    constexpr uint64_t p=0x48010000, r=0x48010100, attr=0x48010200;
    zero(vm,p,64); zero(vm,r,64); zero(vm,attr,8);
    uint8_t canary[64]; std::memset(canary,0x5c,sizeof(canary));
    assert(uc_mem_write(vm.uc,p,canary,sizeof(canary))==UC_ERR_OK);
    zero(vm,p,40); assert(uc_mem_write(vm.uc,p+40,canary,24)==UC_ERR_OK);
    assert(invoke(vm,"pthread_mutex_init",p,attr)==0);
    uint8_t after[24]; assert(uc_mem_read(vm.uc,p+40,after,sizeof(after))==UC_ERR_OK); assert(std::memcmp(after,canary,24)==0);
    assert(invoke(vm,"pthread_mutex_lock",p)==0);
    assert(invoke(vm,"pthread_mutex_trylock",p)==16);
    assert(invoke(vm,"pthread_mutex_lock",p)!=0 && !vm.execution_error.empty());
    assert(invoke(vm,"pthread_mutex_destroy",p)==16); assert(invoke(vm,"pthread_mutex_unlock",p)==0);
    assert(invoke(vm,"pthread_mutex_unlock",p)==1); assert(invoke(vm,"pthread_mutex_destroy",p)==0);
    assert(invoke(vm,"pthread_mutex_destroy",p)==22);
    assert(invoke(vm,"pthread_mutex_trylock",p)!=0 && !vm.execution_error.empty());
    vm.execution_error.clear(); assert(invoke(vm,"pthread_mutex_init",p,attr)==0);
    assert(invoke(vm,"pthread_mutex_lock",p)==0); assert(invoke(vm,"pthread_mutex_unlock",p)==0);
    // A static all-zero object can be destroyed without a prior map entry.
    assert(invoke(vm,"pthread_mutex_destroy",p+0x2000)==0);
    assert(invoke(vm,"pthread_mutex_destroy",p+0x2000)==22);
    assert(invoke(vm,"pthread_mutex_trylock",p+0x2000)!=0 && !vm.execution_error.empty());
    assert(invoke(vm,"pthread_mutex_trylock",p+0x2100)==0); assert(invoke(vm,"pthread_mutex_unlock",p+0x2100)==0);
    uint8_t junk=1; assert(uc_mem_write(vm.uc,p+0x2200,&junk,1)==UC_ERR_OK);
    assert(invoke(vm,"pthread_mutex_trylock",p+0x2200)!=0 && !vm.execution_error.empty());
    // Attr is read-only memory; an invalid non-default attr fails closed.
    vm.execution_error.clear(); junk=1; assert(uc_mem_write(vm.uc,attr,&junk,1)==UC_ERR_OK);
    assert(invoke(vm,"pthread_mutex_init",p+0x2300,attr)!=0 && !vm.execution_error.empty());
    vm.execution_error.clear(); zero(vm,attr,8);

    std::memset(canary,0x6d,sizeof(canary)); assert(uc_mem_write(vm.uc,r,canary,sizeof(canary))==UC_ERR_OK);
    zero(vm,r,56); assert(uc_mem_write(vm.uc,r+56,canary,8)==UC_ERR_OK);
    assert(invoke(vm,"pthread_rwlock_init",r,0)==0);
    uint8_t tail[8]; assert(uc_mem_read(vm.uc,r+56,tail,8)==UC_ERR_OK); assert(std::memcmp(tail,canary,8)==0);
    assert(invoke(vm,"pthread_rwlock_rdlock",r)==0); assert(invoke(vm,"pthread_rwlock_tryrdlock",r)==0);
    assert(invoke(vm,"pthread_rwlock_trywrlock",r)==16);
    assert(invoke(vm,"pthread_rwlock_wrlock",r)!=0 && !vm.execution_error.empty());
    assert(invoke(vm,"pthread_rwlock_destroy",r)==16);
    assert(invoke(vm,"pthread_rwlock_unlock",r)==0); assert(invoke(vm,"pthread_rwlock_unlock",r)==0);
    assert(invoke(vm,"pthread_rwlock_unlock",r)==1); assert(invoke(vm,"pthread_rwlock_trywrlock",r)==0);
    assert(invoke(vm,"pthread_rwlock_tryrdlock",r)==16); assert(invoke(vm,"pthread_rwlock_unlock",r)==0);
    assert(invoke(vm,"pthread_rwlock_destroy",r)==0); assert(invoke(vm,"pthread_rwlock_destroy",r)==22);
    assert(invoke(vm,"pthread_rwlock_tryrdlock",r)!=0 && !vm.execution_error.empty());
    assert(invoke(vm,"pthread_rwlock_destroy",r+0x4000)==0);

    // Invalid alignment, null, overflow, and mappings without the required permissions.
    const auto failed=[&](const char *fn,uint64_t a) { vm.execution_error.clear(); (void)invoke(vm,fn,a); assert(!vm.execution_error.empty()); };
    failed("pthread_mutex_trylock",0); failed("pthread_mutex_trylock",p+1); failed("pthread_mutex_trylock",UINT64_MAX-8);
    failed("pthread_rwlock_tryrdlock",p+1); failed("pthread_rwlock_tryrdlock",UINT64_MAX-8);
    failed("pthread_mutex_init",0x900000000ULL);
    assert(uc_mem_map(vm.uc,0x05000000,0x1000,UC_PROT_READ)==UC_ERR_OK);
    failed("pthread_mutex_init",0x05000000);
    assert(uc_mem_map(vm.uc,0x05001000,0x1000,UC_PROT_NONE)==UC_ERR_OK);
    failed("pthread_mutex_trylock",0x05001000);
    // Exact object ending on a mapped page boundary is valid; crossing into an unmapped page is not.
    assert(uc_mem_map(vm.uc,0x05100000,0x1000,UC_PROT_READ|UC_PROT_WRITE)==UC_ERR_OK);
    assert(invoke(vm,"pthread_mutex_init",0x05100000+0x1000-40,0)==0);

    // Reuse of an existing slot must work even at capacity (direct map population, no guest pages).
    constexpr uint64_t reuse_addr=0x48010400;
    for (uint64_t i=0;i<4096;++i) vm.guest_sync.mutexes.emplace(0x700000000ULL+i*4,AndroidGuestMutexState{});
    // Replace an existing key with a destroyed slot, preserving full capacity.
    vm.guest_sync.mutexes.erase(reuse_addr);
    vm.guest_sync.mutexes.emplace(reuse_addr,AndroidGuestMutexState{false,true});
    assert(invoke(vm,"pthread_mutex_init",reuse_addr,0)==0);

    // Host threads invoke serially; guest ownership remains VM-global, not host-thread-owned.
    EmulatorVM serial_vm;
    constexpr uint64_t serial=0x48010400; zero(serial_vm,serial,40);
    assert(invoke(serial_vm,"pthread_mutex_init",serial,0)==0);
    std::thread first([&]{ assert(invoke(serial_vm,"pthread_mutex_lock",serial)==0); }); first.join();
    std::thread second([&]{ assert(invoke(serial_vm,"pthread_mutex_trylock",serial)==16); }); second.join();
    assert(invoke(serial_vm,"pthread_mutex_unlock",serial)==0);
    EmulatorVM other; assert(invoke(other,"pthread_mutex_trylock",p+0x2100)==0);
    std::cout << "Android pthread sync tests passed\n";
}
