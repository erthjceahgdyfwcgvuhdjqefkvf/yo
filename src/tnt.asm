; tnt.asm - TNT and flint and steel.
;
; Right-clicking TNT with flint and steel lights it: the block turns into
; a falling, flashing box that explodes after 4 seconds, like Minecraft's
; (power 4). The explosion takes out a ragged ball of blocks about 4 nodes
; across the middle (not bedrock, obsidian or liquids; nothing at all when
; the TNT sits in water), drops a quarter of them as items, lights other
; TNT in reach on a short fuse and hurts and throws players and mobs
; within 8 nodes. Flint and steel lasts FLINT_USES lights.

%include "common.inc"

global tnt_clear, tnt_ignite, tnt_update, draw_tnt, flint_use, boom_t
global tnts, tnt_explode
extern portal_try, fire_set, portal_break

extern pos, vel, dt, game_mode, inv, sel_slot, target_hit, target
extern world_get, world_set, block_flags, solid_at, game_rand, randf
extern drop_block, pop_above, furnace_remove, player_damage, knock_x, knock_z
extern mob_blast, cur_pcx, cur_pcz, fig_parts, fig_tint, light_get
extern light_curve, sunlight
extern glPushMatrix, glPopMatrix, glTranslatef, glScalef, glEnable, glDisable

MAX_TNT     equ 32
TN_USED     equ 0
TN_X        equ 4                   ; bottom, centre
TN_Y        equ 8
TN_Z        equ 12
TN_VY       equ 16
TN_FUSE     equ 20                  ; seconds left
TN_SIZE     equ 32
BLAST_R     equ 4                   ; nodes looked at round the centre
GL_CULL_FACE equ 0x0B44
GL_TEXTURE_2D equ 0x0DE1
GL_ALPHA_TEST equ 0x0BC0

section .rodata
align 4
f_zero:     dd 0.0
f_half:     dd 0.5
f_one:      dd 1.0
f_fuse:     dd 4.0
f_chain:    dd 0.5                  ; TNT lit by a blast: 0.5-1.5 s
f_grav:     dd 26.0
f_maxfall:  dd -40.0
f_rmin:     dd 3.0                  ; blast radius 3.0-4.6, per node
f_rspan:    dd 1.6
f_reach:    dd 8.0
f_dmg:      dd 28.0                 ; (i^2 + i) / 2 x 56
f_knock:    dd 15.0
f_up:       dd 9.0
f_low:      dd 0.1
f_body:     dd 0.9                  ; the player's middle
f_boom:     dd 0.35                 ; white flash
f_flash:    dd 4.0                  ; flashes a second (x 2: on and off)
f_inv16:    dd 0.0625
f_grow:     dd 0.6                  ; swells in the last half second
f_8:        dd 8.0

; 1/16 nodes, bottom at 0, centred: red with a light band and a fuse
%macro FPART 9
    dd %1, %2, %3, %4, %5, %6
    db %7, %8, %9, 0
    dd 0
%endmacro
m_tnt:
    FPART -8.0,  0.0, -8.0,  8.0,  5.0,  8.0, 200,  44,  34
    FPART -8.0,  5.0, -8.0,  8.0, 11.0,  8.0, 232, 230, 220
    FPART -8.0, 11.0, -8.0,  8.0, 16.0,  8.0, 200,  44,  34
    FPART -1.0, 16.0, -1.0,  1.0, 18.0,  1.0,  60,  60,  60
M_TNT_N equ ($ - m_tnt) / 32
m_tnt_white:
    FPART -8.0,  0.0, -8.0,  8.0, 16.0,  8.0, 255, 255, 255
    FPART -1.0, 16.0, -1.0,  1.0, 18.0,  1.0, 255, 255, 255

section .bss
alignb 16
tnts:       resb MAX_TNT * TN_SIZE
boom_t:     resd 1                  ; white flash left after a blast nearby

section .text

; floor of xmm float %2 into %1 (xmm7 scratch)
%macro FLOORF 2
    cvttss2si %1, %2
    cvtsi2ss xmm7, %1
    comiss xmm7, %2
    jbe %%ok
    dec %1
%%ok:
%endmacro

; void tnt_clear(void)
tnt_clear:
    lea rdi, [tnts]
    xor eax, eax
    mov ecx, MAX_TNT * TN_SIZE / 4
    rep stosd
    mov dword [boom_t], 0
    ret

; void tnt_ignite(int x, int y, int z, float fuse) - lit TNT in node
; (x, y, z) (the caller has taken the block away)
tnt_ignite:
    lea rax, [tnts]
    xor ecx, ecx
.f:
    cmp dword [rax + TN_USED], 0
    je .got
    add rax, TN_SIZE
    inc ecx
    cmp ecx, MAX_TNT
    jb .f
    ret                             ; too many: this one fizzles
.got:
    mov dword [rax + TN_USED], 1
    cvtsi2ss xmm1, edi
    addss xmm1, [f_half]
    movss [rax + TN_X], xmm1
    cvtsi2ss xmm1, esi
    movss [rax + TN_Y], xmm1
    cvtsi2ss xmm1, edx
    addss xmm1, [f_half]
    movss [rax + TN_Z], xmm1
    mov dword [rax + TN_VY], 0
    movss [rax + TN_FUSE], xmm0
    ret

; int flint_use(void) - right click with flint and steel: lights TNT
; looked at. 1 if it did.
flint_use:
    ENTER_FN 0
    mov eax, [sel_slot]
    lea rbx, [inv]
    lea rbx, [rbx + rax*4]
    cmp byte [rbx], I_FLINTSTEEL
    jne .no
    cmp dword [target_hit], 0
    je .no
    mov edi, [target]
    mov esi, [target + 4]
    mov edx, [target + 8]
    call world_get
    cmp eax, B_TNT
    jne .fire
    mov edi, [target]
    mov esi, [target + 4]
    mov edx, [target + 8]
    xor ecx, ecx
    call world_set
    mov edi, [target]
    mov esi, [target + 4]
    mov edx, [target + 8]
    movss xmm0, [f_fuse]
    call tnt_ignite
    jmp .wear
.fire:
    ; fire in the free cell on the face looked at; inside an obsidian
    ; frame it opens a nether portal instead
    mov edi, [target + 12]
    mov esi, [target + 16]
    mov edx, [target + 20]
    call world_get
    test eax, eax
    jnz .yes                        ; nothing to light
    mov edi, [target + 12]
    mov esi, [target + 16]
    mov edx, [target + 20]
    call portal_try
    test eax, eax
    jnz .wear
    mov edi, [target + 12]
    mov esi, [target + 16]
    mov edx, [target + 20]
    call fire_set
.wear:
    ; one use worn (survival)
    cmp dword [game_mode], 0
    jne .yes
    movzx eax, word [rbx + 2]
    inc eax
    cmp eax, FLINT_USES
    jae .broken
    mov [rbx + 2], ax
    jmp .yes
.broken:
    mov dword [rbx], 0
.yes:
    mov eax, 1
    LEAVE_FN
.no:
    xor eax, eax
    LEAVE_FN

; void tnt_update(void) - lit TNT falls, counts down and goes off
tnt_update:
    ENTER_FN 16
    movss xmm0, [boom_t]
    subss xmm0, [dt]
    maxss xmm0, [f_zero]
    movss [boom_t], xmm0
    xor r12d, r12d
.t:
    cmp r12d, MAX_TNT
    jae .out
    mov eax, r12d
    shl eax, 5
    lea rbx, [tnts]
    add rbx, rax
    cmp dword [rbx + TN_USED], 0
    je .next
    ; fall onto whatever is under the middle
    movss xmm0, [rbx + TN_VY]
    movss xmm1, [f_grav]
    mulss xmm1, [dt]
    subss xmm0, xmm1
    maxss xmm0, [f_maxfall]
    movss [rbx + TN_VY], xmm0
    mulss xmm0, [dt]
    addss xmm0, [rbx + TN_Y]
    movss [rsp], xmm0
    movss xmm1, xmm0
    movss xmm0, [rbx + TN_X]
    movss xmm2, [rbx + TN_Z]
    call solid_at
    jz .fall
    mov dword [rbx + TN_VY], 0      ; landed: on top of that node
    movss xmm0, [rsp]
    FLOORF eax, xmm0
    inc eax
    cvtsi2ss xmm0, eax
    movss [rbx + TN_Y], xmm0
    jmp .fuse
.fall:
    mov eax, [rsp]
    mov [rbx + TN_Y], eax
.fuse:
    movss xmm0, [rbx + TN_FUSE]
    subss xmm0, [dt]
    movss [rbx + TN_FUSE], xmm0
    comiss xmm0, [f_zero]
    ja .next
    mov dword [rbx + TN_USED], 0
    movss xmm0, [rbx + TN_X]
    movss xmm1, [rbx + TN_Y]
    addss xmm1, [f_half]
    movss xmm2, [rbx + TN_Z]
    call tnt_explode
.next:
    inc r12d
    jmp .t
.out:
    LEAVE_FN

; void tnt_explode(float x, y, z) - power 4 at that point
; locals: [0] x, [4] y, [8] z, [12] dx, [16] dy, [20] dz, [24] node x,
;         [28] node y, [32] node z, [36] in water, [40] scratch
tnt_explode:
    ENTER_FN 48
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    ; under water nothing breaks
    FLOORF edi, xmm0
    FLOORF esi, xmm1
    FLOORF edx, xmm2
    call world_get
    lea rcx, [block_flags]
    movzx eax, byte [rcx + rax]
    and eax, F_LIQUID
    mov [rsp + 36], eax
    jnz .entities
    mov dword [rsp + 16], -BLAST_R
.dy:
    mov dword [rsp + 20], -BLAST_R
.dz:
    mov dword [rsp + 12], -BLAST_R
.dx:
    ; node and the distance from its middle to the centre
    xorps xmm3, xmm3
    xor ecx, ecx
.ax:
    lea rax, [rsp]
    movss xmm0, [rax + rcx*4]
    FLOORF edx, xmm0
    add edx, [rsp + 12 + rcx*4]
    mov [rsp + 24 + rcx*4], edx
    cvtsi2ss xmm1, edx
    addss xmm1, [f_half]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    addss xmm3, xmm1
    inc ecx
    cmp ecx, 3
    jb .ax
    movss [rsp + 40], xmm3
    call randf
    mulss xmm0, [f_rspan]
    addss xmm0, [f_rmin]
    mulss xmm0, xmm0
    comiss xmm0, [rsp + 40]
    jb .ndx                         ; outside this node's radius
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    call world_get
    mov ebx, eax
    test ebx, ebx
    jz .ndx
    cmp ebx, B_BEDROCK
    je .ndx
    cmp ebx, B_OBSIDIAN
    je .ndx
    cmp ebx, B_UNKNOWN
    je .ndx
    lea rcx, [block_flags]
    test byte [rcx + rbx], F_LIQUID
    jnz .ndx
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    xor ecx, ecx
    call world_set
    cmp ebx, B_TNT
    jne .notnt
    call randf                      ; more TNT: lit, on a short fuse
    addss xmm0, [f_chain]
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    call tnt_ignite
    jmp .ndx
.notnt:
    cmp ebx, B_FURNACE
    je .furnace
    cmp ebx, B_FURNACE_LIT
    jne .drop
.furnace:
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    call furnace_remove
.drop:
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    call pop_above                  ; a torch or plant on it falls off
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    call portal_break
    call game_rand
    test eax, 0x300
    jnz .ndx                        ; a quarter of the blocks drop
    mov edi, ebx
    mov esi, [rsp + 24]
    mov edx, [rsp + 28]
    mov ecx, [rsp + 32]
    call drop_block
.ndx:
    inc dword [rsp + 12]
    cmp dword [rsp + 12], BLAST_R
    jle .dx
    inc dword [rsp + 20]
    cmp dword [rsp + 20], BLAST_R
    jle .dz
    inc dword [rsp + 16]
    cmp dword [rsp + 16], BLAST_R
    jle .dy

.entities:
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, [rsp + 8]
    call mob_blast
    ; the player: hurt by how close, thrown away
    movss xmm0, [pos]
    subss xmm0, [rsp]
    movss [rsp + 12], xmm0
    movss xmm1, [pos + 4]
    addss xmm1, [f_body]
    subss xmm1, [rsp + 4]
    movss xmm2, [pos + 8]
    subss xmm2, [rsp + 8]
    movss [rsp + 20], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp + 40], xmm0
    comiss xmm0, [f_reach]
    jae .out
    mov eax, [f_boom]
    mov [boom_t], eax
    divss xmm0, [f_reach]
    movss xmm1, [f_one]
    subss xmm1, xmm0                ; impact
    movss [rsp + 16], xmm1
    ; thrown (creative too)
    movss xmm2, [rsp + 40]
    maxss xmm2, [f_low]
    movss xmm3, xmm1
    mulss xmm3, [f_knock]
    divss xmm3, xmm2
    movss xmm0, [rsp + 12]
    mulss xmm0, xmm3
    addss xmm0, [knock_x]
    movss [knock_x], xmm0
    movss xmm0, [rsp + 20]
    mulss xmm0, xmm3
    addss xmm0, [knock_z]
    movss [knock_z], xmm0
    movss xmm0, [rsp + 16]
    mulss xmm0, [f_up]
    maxss xmm0, [vel + 4]
    movss [vel + 4], xmm0
    movss xmm1, [rsp + 16]
    movaps xmm0, xmm1
    mulss xmm0, xmm1
    addss xmm0, xmm1
    mulss xmm0, [f_dmg]
    cvttss2si edi, xmm0
    inc edi
    call player_damage              ; (nothing in creative)
.out:
    LEAVE_FN

; void draw_tnt(void) - lit TNT, flashing white, swelling at the end
draw_tnt:
    ENTER_FN 16
    lea rax, [tnts]
    xor ecx, ecx
.any:
    cmp dword [rax + TN_USED], 0
    jne .some
    add rax, TN_SIZE
    inc ecx
    cmp ecx, MAX_TNT
    jb .any
    jmp .out
.some:
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    xor r12d, r12d
.t:
    cmp r12d, MAX_TNT
    jae .done
    mov eax, r12d
    shl eax, 5
    lea rbx, [tnts]
    add rbx, rax
    cmp dword [rbx + TN_USED], 0
    je .next
    movss xmm0, [rbx + TN_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + TN_Y]
    addss xmm0, [f_half]
    FLOORF esi, xmm0
    movss xmm0, [rbx + TN_Z]
    FLOORF edx, xmm0
    call light_get
    mov ecx, eax
    and eax, 15
    shr ecx, 4
    lea rdx, [light_curve]
    movzx eax, byte [rdx + rax]
    movzx ecx, byte [rdx + rcx]
    cvtsi2ss xmm0, eax
    mulss xmm0, [sunlight]
    cvttss2si eax, xmm0
    cmp eax, ecx
    cmovl eax, ecx
    inc eax
    mov [fig_tint], eax
    mov [fig_tint + 4], eax
    mov [fig_tint + 8], eax
    call glPushMatrix PLT
    mov eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm0, [rbx + TN_X]
    subss xmm0, xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm2, [rbx + TN_Z]
    subss xmm2, xmm1
    movss xmm1, [rbx + TN_Y]
    call glTranslatef PLT
    ; swell in the last half second
    movss xmm0, [f_half]
    subss xmm0, [rbx + TN_FUSE]
    maxss xmm0, [f_zero]
    mulss xmm0, [f_grow]
    addss xmm0, [f_one]
    mulss xmm0, [f_inv16]
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    call glScalef PLT
    ; white every other quarter second
    movss xmm0, [rbx + TN_FUSE]
    mulss xmm0, [f_flash]
    cvttss2si eax, xmm0
    lea rdi, [m_tnt]
    mov esi, M_TNT_N
    test eax, 1
    jz .draw
    lea rdi, [m_tnt_white]
    mov esi, 2
.draw:
    call fig_parts
    call glPopMatrix PLT
.next:
    inc r12d
    jmp .t
.done:
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

NOEXECSTACK
