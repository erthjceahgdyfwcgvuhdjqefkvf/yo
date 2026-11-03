; font.asm - 5x7 bitmap font: texture builder and text drawing.
;
; The font texture is 128x64 RGBA: 16 x 6 cells of 8x8 for ASCII 32..127,
; white where a glyph pixel is set, transparent elsewhere. Text is drawn
; as one textured quad per character in the current colour; the caller
; binds the font texture and keeps the texture matrix at identity.

%include "common.inc"

global font_build, font_rgba, text_draw, text_width

extern glBegin, glEnd, glTexCoord2f, glVertex2f

FONT_W      equ 128
FONT_H      equ 64
GL_QUADS    equ 0x0007

section .rodata
%include "font_data.inc"
align 4
f_six:      dd 6.0
f_eight:    dd 8.0
f_inv128:   dd 0.0078125
f_inv64:    dd 0.015625

section .bss
alignb 16
font_rgba:  resb FONT_W * FONT_H * 4

section .text

; void font_build(void)
font_build:
    push rbx
    lea rsi, [font_glyphs]
    lea rdi, [font_rgba]
    xor ecx, ecx                    ; glyph 0..95
.glyph:
    mov eax, ecx
    and eax, 15
    shl eax, 3                      ; cell x
    mov edx, ecx
    shr edx, 4
    shl edx, 3                      ; cell y
    xor r8d, r8d                    ; row
.row:
    lea r9, [rsi + rcx*8]
    movzx r9d, byte [r9 + r8]
    xor r10d, r10d                  ; column 0..7
.col:
    lea r11d, [rdx + r8]            ; pixel y
    shl r11d, 7                     ; * 128
    add r11d, eax
    add r11d, r10d                  ; pixel index
    mov dword [rdi + r11*4], 0
    cmp r10d, 5
    jae .px_done
    mov ebx, 4
    sub ebx, r10d
    bt r9d, ebx
    jnc .px_done
    mov dword [rdi + r11*4], 0xffffffff
.px_done:
    inc r10d
    cmp r10d, 8
    jb .col
    inc r8d
    cmp r8d, 8
    jb .row
    inc ecx
    cmp ecx, 96
    jb .glyph
    pop rbx
    ret

; float text_width(const char *s, float scale)
text_width:
    xor eax, eax
.len:
    cmp byte [rdi + rax], 0
    je .done
    inc eax
    jmp .len
.done:
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_six]
    mulss xmm0, xmm1
    ret

; void text_draw(float x, float y, float scale, const char *s)
; locals: [0] x, [4] y, [8] cell w, [12] cell h, [16] u0, [20] v0, [24] u1, [28] v1
text_draw:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movaps xmm3, xmm2
    mulss xmm3, [f_six]
    movss [rsp + 8], xmm3
    mulss xmm2, [f_eight]
    movss [rsp + 12], xmm2
    mov r12, rdi
    mov edi, GL_QUADS
    call glBegin PLT
.ch:
    movzx eax, byte [r12]
    test eax, eax
    jz .end
    sub eax, 32
    cmp eax, 95
    jbe .ok
    mov eax, '?' - 32
.ok:
    mov ecx, eax
    and ecx, 15
    shl ecx, 3
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_inv128]
    movss [rsp + 16], xmm0
    add ecx, 6
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_inv128]
    movss [rsp + 24], xmm0
    shr eax, 4
    shl eax, 3
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_inv64]
    movss [rsp + 20], xmm0
    add eax, 8
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_inv64]
    movss [rsp + 28], xmm0
%macro GVERT 3                      ; u, v, corner (0 tl, 1 tr, 2 br, 3 bl)
    movss xmm0, [rsp + %1]
    movss xmm1, [rsp + %2]
    call glTexCoord2f PLT
    movss xmm0, [rsp]
%if %3 == 1 || %3 == 2
    addss xmm0, [rsp + 8]
%endif
    movss xmm1, [rsp + 4]
%if %3 >= 2
    addss xmm1, [rsp + 12]
%endif
    call glVertex2f PLT
%endmacro
    GVERT 16, 20, 0
    GVERT 24, 20, 1
    GVERT 24, 28, 2
    GVERT 16, 28, 3
    movss xmm0, [rsp]
    addss xmm0, [rsp + 8]
    movss [rsp], xmm0
    inc r12
    jmp .ch
.end:
    call glEnd PLT
    LEAVE_FN

NOEXECSTACK
