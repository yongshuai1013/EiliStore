#include "../Packages/AnisetteKit/Native/Loader/elf_loader_emulator.h"
#include "../Packages/AnisetteKit/Native/Loader/android_libc_strings.h"
#include <cassert>
#include <cstring>
#include <iostream>

static void put(EmulatorVM &vm, uint64_t addr, const char *s) {
    assert(uc_mem_write(vm.uc, addr, s, std::strlen(s)+1) == UC_ERR_OK);
}
static uint64_t call(EmulatorVM &vm, const char *name, uint64_t a, uint64_t b=0, uint64_t c=0, uint64_t d=0) {
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X0, &a) == UC_ERR_OK);
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X1, &b) == UC_ERR_OK);
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X2, &c) == UC_ERR_OK);
    assert(uc_reg_write(vm.uc, UC_ARM64_REG_X3, &d) == UC_ERR_OK);
    assert(dispatch_android_libc_string(&vm, name));
    uint64_t result=0;
    assert(uc_reg_read(vm.uc, UC_ARM64_REG_X0, &result) == UC_ERR_OK);
    return result;
}
int main() {
    EmulatorVM vm;
    assert(vm.initialization_error == UC_ERR_OK);
    constexpr uint64_t base=0x48010000;
    put(vm,base,"hello world"); put(vm,base+0x100,"world");
    assert(call(vm,"strnlen",base,5)==5);
    assert(call(vm,"strnlen",base,UINT64_MAX)==11);
    assert(call(vm,"strchr",base,'w')==base+6);
    assert(call(vm,"strchr",base,0)==base+11);
    assert(call(vm,"strchr",base,'z')==0);
    assert(call(vm,"strrchr",base,'l')==base+9);
    assert(call(vm,"strstr",base,base+0x100)==base+6);
    assert(call(vm,"strcspn",base,base+0x100)==2);
    assert(call(vm,"strspn",base,base+0x100)==0);
    assert(call(vm,"strpbrk",base,base+0x100)==base+2);
    put(vm,base+0x200,"!");
    assert(call(vm,"strcat",base,base+0x200)==base);
    char actual[32]{}; assert(uc_mem_read(vm.uc,base,actual,13)==UC_ERR_OK);
    assert(std::strcmp(actual,"hello world!")==0);
    put(vm,base+0x300,"  -42tail"); assert(call(vm,"atoi",base+0x300)==(uint64_t)-42);
    assert(call(vm,"atoll",base+0x300)==(uint64_t)-42);

    // memmove uses dest=x0, src=x1, n=x2 and must handle overlap.
    const char source[]="abcdef"; assert(uc_mem_write(vm.uc,base+0x400,source,sizeof(source))==UC_ERR_OK);
    assert(call(vm,"memmove",base+0x401,base+0x400,5)==base+0x401);
    char moved[7]{}; assert(uc_mem_read(vm.uc,base+0x400,moved,7)==UC_ERR_OK);
    assert(std::strcmp(moved,"aabcde")==0);
    assert(call(vm,"memmem",base+0x400,6,base+0x402,3)==base+0x402);
    assert(call(vm,"memmem",base+0x400,6,base+0x500,0)==base+0x400);
    put(vm,base+0x500,"zzz");
    assert(call(vm,"memmem",base+0x400,6,base+0x500,3)==0);
    assert(call(vm,"memmem",base+0x400,2,base+0x402,3)==0);

    assert(call(vm,"__memchr_chk",base+0x400,'c',6,6)==base+0x403);
    vm.execution_error.clear();
    (void)call(vm,"__memchr_chk",base+0x400,'c',6,5);
    assert(!vm.execution_error.empty());
    vm.execution_error.clear();

    // Source occupies exactly n readable bytes with no NUL; strncat must not probe beyond n.
    const char bounded[]={'X','Y'};
    assert(uc_mem_write(vm.uc,base+0x600,bounded,sizeof(bounded))==UC_ERR_OK);
    put(vm,base+0x610,"Q");
    assert(call(vm,"strncat",base+0x610,base+0x600,2)==base+0x610);
    char joined[4]{}; assert(uc_mem_read(vm.uc,base+0x610,joined,sizeof(joined))==UC_ERR_OK);
    assert(std::strcmp(joined,"QXY")==0);
    // n=0 must not read source at all.
    put(vm,base+0x620,"R");
    assert(call(vm,"strncat",base+0x620,0x900000000ULL,0)==base+0x620);
    char unchanged[2]{}; assert(uc_mem_read(vm.uc,base+0x620,unchanged,sizeof(unchanged))==UC_ERR_OK);
    assert(std::strcmp(unchanged,"R")==0);

    // Bad guest read must stop rather than return a fabricated successful result.
    vm.execution_error.clear();
    uint64_t bad=0x900000000ULL, dest=base+0x700, one=1;
    assert(uc_reg_write(vm.uc,UC_ARM64_REG_X0,&dest)==UC_ERR_OK);
    assert(uc_reg_write(vm.uc,UC_ARM64_REG_X1,&bad)==UC_ERR_OK);
    assert(uc_reg_write(vm.uc,UC_ARM64_REG_X2,&one)==UC_ERR_OK);
    assert(dispatch_android_libc_string(&vm,"memmove"));
    assert(!vm.execution_error.empty());
    assert(!dispatch_android_libc_string(&vm,"not-a-string-import"));
    std::cout << "Android libc string tests passed\n";
}
