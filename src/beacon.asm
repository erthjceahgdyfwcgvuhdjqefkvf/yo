; beacon.asm - beacons: a light beam for builds (no powers).
;
; A beacon on top of a full 3x3 layer of iron, gold or diamond blocks (any
; mix; a bigger pyramid under that is fine) with nothing solid over it
; sends a beam up into the sky. Stained glass over it tints the beam from
; that height on: the first pane gives its colour, every pane after mixes
; half of its colour in. The mesher notes every beacon it sees in a loaded
; chunk; the list is checked again one beacon a frame, so building or
; breaking round one shows up within a moment.

%include "common.inc"

global beacon_clear, beacon_update, beacon_draw, beacons, beacon_count

extern dt, world_get, block_flags, wool_rgb, cur_pcx, cur_pcz, pos
extern mesh_beacons, mesh_beacon_n
extern glPushMatrix, glPopMatrix, glTranslatef, glRotatef, glBegin, glEnd
extern glVertex3f, glColor4f, glEnable, glDisable, glBlendFunc, glDepthMask

GL_QUADS        equ 7
GL_BLEND        equ 0x0BE2
GL_CULL_FACE    equ 0x0B44
GL_TEXTURE_2D   equ 0x0DE1
GL_ALPHA_TEST   equ 0x0BC0
GL_SRC_ALPHA    equ 0x0302
GL_ONE_MINUS_SRC_ALPHA equ 0x0303

MAX_BEACONS equ 32
MAX_SEGS    equ 5
BC_X        equ 0                   ; the beacon node (world coordinates)
BC_Y        equ 4
BC_Z        equ 8
BC_ON       equ 12                  ; 1 = the beam shines
BC_NSEG     equ 16
BC_SEG      equ 20                  ; MAX_SEGS x (u32 start y, u8 r, g, b, 0)
BC_SIZE     equ 64
BEAM_TOP    equ 320                 ; world y the beam is drawn up to
BEAM_RANGE  equ 320                 ; not drawn further away than this

section .rodata
align 4
f_inner:    dd 0.2                  ; half widths of the core and the glow
f_outer:    dd 0.3
f_ina:      dd 0.85                 ; their opacity
f_outa:     dd 0.25
f_inv255:   dd 0.0039215686
f_half:     dd 0.5
f_spin:     dd 40.0                 ; degrees a second
f_360:      dd 360.0
f_one:      dd 1.0
f_piece:    dd 16.0

section .bss
alignb 16
beacons:      resb MAX_BEACONS * BC_SIZE
beacon_count: resd 1
check_next:   resd 1                ; the beacon checked next frame
spin:         resd 1
b_y0:         resd 1                ; the column beam_box draws
b_y1:         resd 1
b_w:          resd 1

section .text

; void beacon_clear(void) - leaving a world or dimension
beacon_clear:
    mov dword [beacon_count], 0
    mov dword [mesh_beacon_n], 0
    mov dword [check_next], 0
    ret

; beacon_add(edi x, esi y, edx z) - into the list unless already there
beacon_add:
    lea rax, [beacons]
    xor ecx, ecx
.f:
    cmp ecx, [beacon_count]
    jae .new
    cmp [rax + BC_X], edi
    jne .n
    cmp [rax + BC_Y], esi
    jne .n
    cmp [rax + BC_Z], edx
    je .out
.n:
    add rax, BC_SIZE
    inc ecx
    jmp .f
.new:
    cmp ecx, MAX_BEACONS
    jae .out
    inc dword [beacon_count]
    mov [rax + BC_X], edi
    mov [rax + BC_Y], esi
    mov [rax + BC_Z], edx
    mov dword [rax + BC_ON], 0
    mov dword [rax + BC_NSEG], 0
.out:
    ret

; void beacon_update(void) - take the mesher's notes, check one beacon
beacon_update:
    ENTER_FN 0
.notes:
    mov eax, [mesh_beacon_n]
    test eax, eax
    jz .check
    dec eax
    mov [mesh_beacon_n], eax
    imul eax, eax, 12
    lea rcx, [mesh_beacons]
    mov edi, [rcx + rax]
    mov esi, [rcx + rax + 4]
    mov edx, [rcx + rax + 8]
    call beacon_add
    jmp .notes
.check:
    movss xmm0, [spin]
    movss xmm1, [dt]
    mulss xmm1, [f_spin]
    addss xmm0, xmm1
    comiss xmm0, [f_360]
    jb .sp
    subss xmm0, [f_360]
.sp:
    movss [spin], xmm0
    mov eax, [check_next]
    cmp eax, [beacon_count]
    jb .one
    xor eax, eax
    cmp eax, [beacon_count]
    je .out
.one:
    lea ecx, [rax + 1]
    mov [check_next], ecx
    imul eax, eax, BC_SIZE
    lea rbx, [beacons]
    add rbx, rax
    call beacon_check
.out:
    LEAVE_FN

; is_base(eax block) - ZF set (je) when it is iron, gold or diamond block
%macro IS_BASE 0
    cmp eax, B_IRONBLOCK
    je %%y
    cmp eax, B_GOLDBLOCK
    je %%y
    cmp eax, B_DIAMONDBLOCK
%%y:
%endmacro

; beacon_check - rbx beacon: still there? the base, the sky, the colours
; locals: [0] dx, [4] dz, [8] y, [12] colour (r, g, b, has colour)
beacon_check:
    ENTER_FN 16
    mov edi, [rbx + BC_X]
    mov esi, [rbx + BC_Y]
    mov edx, [rbx + BC_Z]
    call world_get
    cmp eax, B_BEACON
    jne .remove
    mov dword [rbx + BC_ON], 0
    ; the 3x3 layer under it
    mov dword [rsp], -1
.bx:
    mov dword [rsp + 4], -1
.bz:
    mov edi, [rbx + BC_X]
    add edi, [rsp]
    mov esi, [rbx + BC_Y]
    dec esi
    mov edx, [rbx + BC_Z]
    add edx, [rsp + 4]
    call world_get
    IS_BASE
    jne .out
    inc dword [rsp + 4]
    cmp dword [rsp + 4], 1
    jle .bz
    inc dword [rsp]
    cmp dword [rsp], 1
    jle .bx
    ; up the column: white until the first stained glass
    mov dword [rbx + BC_NSEG], 1
    mov eax, [rbx + BC_Y]
    inc eax
    mov [rbx + BC_SEG], eax
    mov dword [rbx + BC_SEG + 4], 0x00ffffff
    mov dword [rsp + 12], 0x00ffffff
    mov [rsp + 8], eax
.up:
    cmp dword [rsp + 8], WORLD_H + WORLD_YMIN
    jge .clear
    mov edi, [rbx + BC_X]
    mov esi, [rsp + 8]
    mov edx, [rbx + BC_Z]
    call world_get
    lea ecx, [rax - B_SGLASS]
    cmp ecx, 15
    jbe .glass
    lea rcx, [block_flags]
    test byte [rcx + rax], F_OPAQUE
    jnz .out                        ; no sky: no beam
    jmp .next
.glass:
    lea rdx, [wool_rgb]
    lea ecx, [rcx + rcx*2]
    add rdx, rcx
    ; the new colour: this pane's, or half the old one and half this
    xor r8d, r8d
.ch:
    movzx eax, byte [rdx + r8]
    test byte [rsp + 15], 1
    jz .first
    movzx ecx, byte [rsp + 12 + r8]
    add eax, ecx
    shr eax, 1
.first:
    mov [rsp + 12 + r8], al
    inc r8d
    cmp r8d, 3
    jb .ch
    mov byte [rsp + 15], 1
    ; a segment from here (or recolour the last one if it starts here)
    mov ecx, [rbx + BC_NSEG]
    dec ecx
    mov eax, [rsp + 8]
    cmp [rbx + BC_SEG + rcx*8], eax
    je .recolour
    inc ecx
    cmp ecx, MAX_SEGS
    jae .recolour_last
    mov [rbx + BC_SEG + rcx*8], eax
    inc dword [rbx + BC_NSEG]
.recolour:
    mov eax, [rsp + 12]
    and eax, 0x00ffffff
    mov [rbx + BC_SEG + rcx*8 + 4], eax
    jmp .next
.recolour_last:
    dec ecx
    jmp .recolour
.next:
    inc dword [rsp + 8]
    jmp .up
.clear:
    mov dword [rbx + BC_ON], 1
.out:
    LEAVE_FN
.remove:
    ; the last one takes its place
    mov eax, [beacon_count]
    dec eax
    mov [beacon_count], eax
    imul eax, eax, BC_SIZE
    lea rsi, [beacons]
    add rsi, rax
    mov rdi, rbx
    mov ecx, BC_SIZE / 8
    rep movsq
    jmp .out

; void beacon_draw(void) - the beams, in node units round the player's
; chunk (as the mobs): a bright core and a faint glow, turning slowly
; locals: [12] alpha, [16] segment,
;         [20] beacon, [24] r, [28] g, [32] b, [36] pass
beacon_draw:
    ENTER_FN 48
    cmp dword [beacon_count], 0
    je .out
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_BLEND
    call glEnable PLT
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc PLT
    xor edi, edi
    call glDepthMask PLT
    mov dword [rsp + 20], 0
.b:
    mov eax, [rsp + 20]
    cmp eax, [beacon_count]
    jae .done
    imul eax, eax, BC_SIZE
    lea rbx, [beacons]
    add rbx, rax
    cmp dword [rbx + BC_ON], 0
    je .bnext
    ; far away: not drawn
    cvtsi2ss xmm0, dword [rbx + BC_X]
    subss xmm0, [pos]
    cvtsi2ss xmm1, dword [rbx + BC_Z]
    subss xmm1, [pos + 8]
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    mov eax, BEAM_RANGE * BEAM_RANGE
    cvtsi2ss xmm1, eax
    comiss xmm0, xmm1
    ja .bnext
    call glPushMatrix PLT
    mov eax, [cur_pcx]
    shl eax, 4
    mov ecx, [rbx + BC_X]
    sub ecx, eax
    cvtsi2ss xmm0, ecx
    addss xmm0, [f_half]
    mov eax, [cur_pcz]
    shl eax, 4
    mov ecx, [rbx + BC_Z]
    sub ecx, eax
    cvtsi2ss xmm2, ecx
    addss xmm2, [f_half]
    xorps xmm1, xmm1
    call glTranslatef PLT
    movss xmm0, [spin]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    mov dword [rsp + 36], 0
.pass:
    mov eax, [f_inner]
    mov ecx, [f_ina]
    cmp dword [rsp + 36], 0
    je .pw
    mov eax, [f_outer]
    mov ecx, [f_outa]
.pw:
    mov [b_w], eax
    mov [rsp + 12], ecx
    mov edi, GL_QUADS
    call glBegin PLT
    mov dword [rsp + 16], 0
.s:
    mov eax, [rsp + 16]
    cmp eax, [rbx + BC_NSEG]
    jae .s_done
    cvtsi2ss xmm0, dword [rbx + BC_SEG + rax*8]
    movss [b_y0], xmm0
    mov ecx, BEAM_TOP
    inc eax
    cmp eax, [rbx + BC_NSEG]
    jae .top
    mov ecx, [rbx + BC_SEG + rax*8]
.top:
    cvtsi2ss xmm0, ecx
    movss [b_y1], xmm0
    mov eax, [rsp + 16]
    lea r12, [rbx + BC_SEG + rax*8 + 4]
    xor ecx, ecx
.rgb:
    movzx edx, byte [r12 + rcx]
    cvtsi2ss xmm0, edx
    mulss xmm0, [f_inv255]
    movss [rsp + 24 + rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jb .rgb
    movss xmm0, [rsp + 24]
    movss xmm1, [rsp + 28]
    movss xmm2, [rsp + 32]
    movss xmm3, [rsp + 12]
    call glColor4f PLT
    call beam_box
    inc dword [rsp + 16]
    jmp .s
.s_done:
    call glEnd PLT
    inc dword [rsp + 36]
    cmp dword [rsp + 36], 2
    jb .pass
    call glPopMatrix PLT
.bnext:
    inc dword [rsp + 20]
    jmp .b
.done:
    mov edi, 1
    call glDepthMask PLT
    mov edi, GL_BLEND
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_ALPHA_TEST
    call glEnable PLT
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

; beam_box - the four sides of a square column, half width b_w from y
; b_y0 to b_y1 (inside glBegin), in pieces 16 nodes tall so the fog, worked
; out at the corners, fades it right
; locals: [0] side, [4] piece bottom, [8] piece top
beam_box:
    ENTER_FN 16
    movss xmm0, [b_y0]
    movss [rsp + 4], xmm0
.piece:
    movss xmm0, [rsp + 4]
    comiss xmm0, [b_y1]
    jae .out
    addss xmm0, [f_piece]
    minss xmm0, [b_y1]
    movss [rsp + 8], xmm0
    mov dword [rsp], 0
.side:
    mov eax, [rsp]
    call corner_xz
    movss xmm1, [rsp + 4]
    call glVertex3f PLT
    mov eax, [rsp]
    inc eax
    and eax, 3
    call corner_xz
    movss xmm1, [rsp + 4]
    call glVertex3f PLT
    mov eax, [rsp]
    inc eax
    and eax, 3
    call corner_xz
    movss xmm1, [rsp + 8]
    call glVertex3f PLT
    mov eax, [rsp]
    call corner_xz
    movss xmm1, [rsp + 8]
    call glVertex3f PLT
    inc dword [rsp]
    cmp dword [rsp], 4
    jb .side
    movss xmm0, [rsp + 8]
    movss [rsp + 4], xmm0
    jmp .piece
.out:
    LEAVE_FN

; corner_xz(eax corner 0-3) -> xmm0 x, xmm2 z: (-w,-w) (w,-w) (w,w) (-w,w)
corner_xz:
    movss xmm0, [b_w]
    movaps xmm2, xmm0
    xorps xmm3, xmm3
    subss xmm3, xmm0                ; -w
    test eax, eax
    jz .mm
    cmp eax, 1
    je .pm
    cmp eax, 2
    je .out                         ; (w, w)
    movaps xmm0, xmm3               ; 3: (-w, w)
    ret
.mm:
    movaps xmm0, xmm3
    movaps xmm2, xmm3
    ret
.pm:
    movaps xmm2, xmm3               ; (w, -w)
.out:
    ret

NOEXECSTACK
