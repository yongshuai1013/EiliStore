// Self-authored ARM64 guest callback loop; assembled for aarch64-linux-gnu.
// Entry: x0=callback, x1=userdata, x2=entry array, x3=count.
// struct prefix = {u64 addr, u64 name, u64 phdr, u16 phnum, u8 pad[6]}.
.text
.global synthetic_module_iteration
.type synthetic_module_iteration,%function
synthetic_module_iteration:
    stp x19, x20, [sp, #-64]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    str x30, [sp, #48]
    mov x19, x0                 // callback
    mov x20, x1                 // userdata
    mov x21, x2                 // entries
    mov x22, x3                 // count
    mov x23, #0                 // index
.Lloop:
    cmp x23, x22
    b.hs .Ldone_zero
    add x0, x21, x23, lsl #5   // &entries[index]
    mov x1, #32
    mov x2, x20
    blr x19
    cbnz w0, .Ldone             // callback ABI returns int; ignore X0's high bits
    add x23, x23, #1
    b .Lloop
.Ldone_zero:
    mov x0, #0
.Ldone:
    ldr x30, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x19, x20, [sp], #64
    ret
.size synthetic_module_iteration, .-synthetic_module_iteration
