#if defined(__arm64__)
.text
.align 2
.globl _KCObjCEvalSwiftCallArm64
_KCObjCEvalSwiftCallArm64:
    // x0=function, x1=self/metadata, x2=integer words[8],
    // x3=floating words[8], x4=returned integer words[3], x5=floats[4].
    // Native Swift instance/static functions receive self/metadata in x20.
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    ldp d0, d1, [x22, #0]
    ldp d2, d3, [x22, #16]
    ldp d4, d5, [x22, #32]
    ldp d6, d7, [x22, #48]
    ldp x0, x1, [x21, #0]
    ldp x2, x3, [x21, #16]
    ldp x4, x5, [x21, #32]
    ldp x6, x7, [x21, #48]
    blr x19
    stp x0, x1, [x23, #0]
    str x2, [x23, #16]
    stp d0, d1, [x24, #0]
    stp d2, d3, [x24, #16]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
#endif
