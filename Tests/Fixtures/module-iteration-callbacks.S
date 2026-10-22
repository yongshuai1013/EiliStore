// Self-authored synthetic ARM64 test code only. No Apple binary input.
// wrapper(x0=callback, x1=context, x2=dl_iterate_phdr import).
.text
.global synthetic_iteration_wrapper
.global synthetic_iteration_callback
.type synthetic_iteration_wrapper,%function
synthetic_iteration_wrapper:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x16, x2
    blr x16
    ldp x29, x30, [sp], #16
    ret
.size synthetic_iteration_wrapper, .-synthetic_iteration_wrapper

// Context layout is mirrored by AndroidModuleIterationTests.cpp.
.type synthetic_iteration_callback,%function
synthetic_iteration_callback:
    stp x19, x20, [sp, #-32]!
    stp x21, x30, [sp, #16]
    mov x19, x2
    ldr x9, [x19]
    add x9, x9, #1
    str x9, [x19]
    str x0, [x19, #8]
    str x1, [x19, #16]
    str x2, [x19, #24]
    ldr x0, [x0, #8]             // dlpi_name
    ldr x16, [x19, #32]          // strlen guest import
    blr x16
    str x0, [x19, #48]
    ldr x9, [x19, #72]           // optional nested iteration import
    cbz x9, .Lresult
    ldr x10, [x19, #88]          // prevent recursive nesting beyond one level
    cbnz x10, .Lresult
    mov x10, #1
    str x10, [x19, #88]
    ldr x0, [x19, #80]           // callback
    mov x1, x19
    blr x9
    str x0, [x19, #104]
    str xzr, [x19, #88]
.Lresult:
    ldr w0, [x19, #56]           // configured int return value
    ldr x9, [x19, #64]           // optional garbage in upper 32 bits
    orr x0, x0, x9, lsl #32
    ldp x21, x30, [sp, #16]
    ldp x19, x20, [sp], #32
    ret
.size synthetic_iteration_callback, .-synthetic_iteration_callback
