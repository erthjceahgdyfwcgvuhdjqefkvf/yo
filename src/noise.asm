; noise.asm - Luanti's value noise (src/noise.cpp) ported to x86-64.
;
; Same lattice hash, smoothstep easing, bilinear/trilinear interpolation and
; fractal octave sum as NoiseFractal2D / NoiseFractal3D, so the same seed
; gives the same terrain shapes as Luanti's v7 mapgen.
;
; Internal contract (relied on by noise_fractal*): noise2d_value and
; noise3d_value clobber only rax, rcx, rdx, r8-r11 and xmm0-xmm7.

%include "common.inc"

global noise2d, noise3d, noise2d_value, noise3d_value
global noise_fractal2d, noise_fractal2d_p, noise_fractal3d

NMX equ 1619
NMY equ 31337
NMZ equ 52591
NMS equ 1013

section .rodata
align 16
f_signmask:  dd 0x80000000, 0, 0, 0
f_absmask:   dd 0x7fffffff, 0, 0, 0
f_inv2_30:   dd 0x30800000          ; 2^-30
f_one:       dd 1.0
f_zero:      dd 0.0
f_six:       dd 6.0
f_fifteen:   dd 15.0
f_ten:       dd 10.0

section .text

; HASHF xmm, r32 - lattice value 1 - n/2^30 for a pre-summed hash input.
; clobbers eax, ecx
%macro HASHF 2
    mov eax, %2
    and eax, 0x7fffffff
    mov ecx, eax
    shr ecx, 13
    xor eax, ecx
    mov ecx, eax
    imul ecx, eax
    imul ecx, ecx, 60493
    add ecx, 19990303
    imul ecx, eax
    add ecx, 1376312589
    and ecx, 0x7fffffff
    cvtsi2ss %1, ecx
    mulss %1, [f_inv2_30]
    subss %1, [f_one]
    xorps %1, [f_signmask]
%endmacro

; FLOORI r32, xmm - Luanti's myfloor(): (x < 0 ? (int)x - 1 : (int)x)
%macro FLOORI 2
    cvttss2si %1, %2
    comiss %2, [f_zero]
    jae %%ok
    dec %1
%%ok:
%endmacro

; EASE xmm_t, tmp1, tmp2 - t*t*t*(t*(6t-15)+10)
%macro EASE 3
    movaps %2, %1
    mulss %2, [f_six]
    subss %2, [f_fifteen]
    mulss %2, %1
    addss %2, [f_ten]
    movaps %3, %1
    mulss %3, %1
    mulss %3, %1
    mulss %3, %2
    movaps %1, %3
%endmacro

; LERPH dst, off0, off1 - dst = lerp(H(base+off0), H(base+off1), xmm0)
; base hash sum in edx
%macro LERPH 3
    lea r11d, [rdx + %2]
    HASHF %1, r11d
    lea r11d, [rdx + %3]
    HASHF xmm7, r11d
    subss xmm7, %1
    mulss xmm7, xmm0
    addss %1, xmm7
%endmacro

; float noise2d(int x, int y, int seed)
noise2d:
    imul edi, edi, NMX
    imul esi, esi, NMY
    imul edx, edx, NMS
    add edi, esi
    add edi, edx
    HASHF xmm0, edi
    ret

; float noise3d(int x, int y, int z, int seed)
noise3d:
    imul edi, edi, NMX
    imul esi, esi, NMY
    imul edx, edx, NMZ
    imul ecx, ecx, NMS
    add edi, esi
    add edi, edx
    add edi, ecx
    HASHF xmm0, edi
    ret

; float noise2d_value(float x, float y, int seed, int eased)
noise2d_value:
    FLOORI r8d, xmm0
    FLOORI r9d, xmm1
    cvtsi2ss xmm2, r8d
    subss xmm0, xmm2
    cvtsi2ss xmm2, r9d
    subss xmm1, xmm2
    test esi, esi
    jz .noease
    EASE xmm0, xmm2, xmm3
    EASE xmm1, xmm2, xmm3
.noease:
    imul edx, r8d, NMX
    imul r9d, r9d, NMY
    add edx, r9d
    imul r10d, edi, NMS
    add edx, r10d
    HASHF xmm2, edx                 ; v00
    lea r11d, [rdx + NMX]
    HASHF xmm3, r11d                ; v10
    lea r11d, [rdx + NMY]
    HASHF xmm4, r11d                ; v01
    lea r11d, [rdx + NMX + NMY]
    HASHF xmm5, r11d                ; v11
    subss xmm3, xmm2
    mulss xmm3, xmm0
    addss xmm2, xmm3                ; u = lerp(v00, v10, x)
    subss xmm5, xmm4
    mulss xmm5, xmm0
    addss xmm4, xmm5                ; v = lerp(v01, v11, x)
    subss xmm4, xmm2
    mulss xmm4, xmm1
    addss xmm2, xmm4                ; lerp(u, v, y)
    movaps xmm0, xmm2
    ret

; float noise3d_value(float x, float y, float z, int seed, int eased)
noise3d_value:
    FLOORI r8d, xmm0
    FLOORI r9d, xmm1
    FLOORI r10d, xmm2
    cvtsi2ss xmm3, r8d
    subss xmm0, xmm3
    cvtsi2ss xmm3, r9d
    subss xmm1, xmm3
    cvtsi2ss xmm3, r10d
    subss xmm2, xmm3
    test esi, esi
    jz .noease
    EASE xmm0, xmm3, xmm4
    EASE xmm1, xmm3, xmm4
    EASE xmm2, xmm3, xmm4
.noease:
    imul edx, r8d, NMX
    imul r9d, r9d, NMY
    add edx, r9d
    imul r10d, r10d, NMZ
    add edx, r10d
    imul r9d, edi, NMS
    add edx, r9d
    LERPH xmm3, 0, NMX
    LERPH xmm4, NMY, NMX + NMY
    subss xmm4, xmm3
    mulss xmm4, xmm1
    addss xmm3, xmm4                ; u
    LERPH xmm4, NMZ, NMX + NMZ
    LERPH xmm5, NMY + NMZ, NMX + NMY + NMZ
    subss xmm5, xmm4
    mulss xmm5, xmm1
    addss xmm4, xmm5                ; v
    subss xmm4, xmm3
    mulss xmm4, xmm2
    addss xmm3, xmm4
    movaps xmm0, xmm3
    ret

; float noise_fractal2d(const NoiseParams *np, float x, float y, int seed)
noise_fractal2d:
    movss xmm2, [rdi + NP_PERSIST]
    ; fall through
; float noise_fractal2d_p(const NoiseParams *np, float x, float y, int seed,
;                         float persist)  - per-point persistence override
noise_fractal2d_p:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    divss xmm0, [r12 + NP_SPREADX]
    divss xmm1, [r12 + NP_SPREADY]
    movaps xmm8, xmm0               ; x
    movaps xmm9, xmm1               ; y
    movaps xmm10, xmm2              ; persistence
    add esi, [r12 + NP_SEED]
    mov r13d, esi                   ; seed + octave
    xorps xmm11, xmm11              ; a
    movss xmm12, [f_one]            ; f
    movss xmm13, [f_one]            ; g
    mov r14d, [r12 + NP_FLAGS]
    mov ebx, [r12 + NP_OCTAVES]
    test ebx, ebx
    jz .done
.oct:
    movaps xmm0, xmm8
    mulss xmm0, xmm12
    movaps xmm1, xmm9
    mulss xmm1, xmm12
    mov edi, r13d
    mov esi, r14d
    and esi, NOISE_FLAG_DEFAULTS | NOISE_FLAG_EASED
    call noise2d_value
    test r14d, NOISE_FLAG_ABSVALUE
    jz .noabs
    andps xmm0, [f_absmask]
.noabs:
    mulss xmm0, xmm13
    addss xmm11, xmm0
    mulss xmm12, [r12 + NP_LACUNARITY]
    mulss xmm13, xmm10
    inc r13d
    dec ebx
    jnz .oct
.done:
    mulss xmm11, [r12 + NP_SCALE]
    movss xmm0, [r12 + NP_OFFSET]
    addss xmm0, xmm11
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; float noise_fractal3d(const NoiseParams *np, float x, float y, float z, int seed)
noise_fractal3d:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    divss xmm0, [r12 + NP_SPREADX]
    divss xmm1, [r12 + NP_SPREADY]
    divss xmm2, [r12 + NP_SPREADZ]
    movaps xmm8, xmm0
    movaps xmm9, xmm1
    movaps xmm14, xmm2
    add esi, [r12 + NP_SEED]
    mov r13d, esi
    xorps xmm11, xmm11
    movss xmm12, [f_one]
    movss xmm13, [f_one]
    mov r14d, [r12 + NP_FLAGS]
    mov ebx, [r12 + NP_OCTAVES]
    test ebx, ebx
    jz .done
.oct:
    movaps xmm0, xmm8
    mulss xmm0, xmm12
    movaps xmm1, xmm9
    mulss xmm1, xmm12
    movaps xmm2, xmm14
    mulss xmm2, xmm12
    mov edi, r13d
    mov esi, r14d
    and esi, NOISE_FLAG_EASED
    call noise3d_value
    test r14d, NOISE_FLAG_ABSVALUE
    jz .noabs
    andps xmm0, [f_absmask]
.noabs:
    mulss xmm0, xmm13
    addss xmm11, xmm0
    mulss xmm12, [r12 + NP_LACUNARITY]
    mulss xmm13, [r12 + NP_PERSIST]
    inc r13d
    dec ebx
    jnz .oct
.done:
    mulss xmm11, [r12 + NP_SCALE]
    movss xmm0, [r12 + NP_OFFSET]
    addss xmm0, xmm11
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

NOEXECSTACK
