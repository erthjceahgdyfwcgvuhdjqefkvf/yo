; boat.asm - boats: placed from the item, ridden with the movement keys.
;
; A boat floats with its bottom 0.3 under the water surface, falls on land
; and slides to a stop there. Right-click a boat to get in: forward / back
; move it the way the player looks (fast on water, slow on land), the
; sneak key gets out onto the nearest bank (or on top). Three quick hits
; break it and it drops as an item (creative: one hit, no drop). Boats are
; saved with the world (save.asm copies the array).

%include "common.inc"

global boats, riding, boat_clear, boat_place, boat_use, boat_attack
global boat_update, draw_boats

extern pos, yaw, pitch, syaw, cyaw, keys, dt, state, game_mode
extern bind_fwd, bind_back, bind_down
extern world_get, block_flags, solid_at, ent_spawn, target_hit, target
extern cur_pcx, cur_pcz, fig_parts, fig_tint, light_get, light_curve, sunlight
extern dimension
extern glPushMatrix, glPopMatrix, glTranslatef, glRotatef, glScalef
extern glEnable, glDisable

MAX_BOATS   equ 16
BT_USED     equ 0
BT_X        equ 4                   ; bottom, centre
BT_Y        equ 8
BT_Z        equ 12
BT_VX       equ 16
BT_VY       equ 20
BT_VZ       equ 24
BT_YAW      equ 28                  ; degrees, 0 = front toward +z
BT_DMG      equ 32                  ; hits taken (fades)
BT_HURT     equ 36                  ; red flash left
BT_SIZE     equ 48
GL_CULL_FACE equ 0x0B44
GL_TEXTURE_2D equ 0x0DE1
GL_ALPHA_TEST equ 0x0BC0

section .rodata
align 4
f_zero:     dd 0.0
f_one:      dd 1.0
f_half:     dd 0.5
f_eye:      dd 1.6
f_reach:    dd 5.0
f_step:     dd 0.1                  ; placing: steps along the view
f_sink:     dd 0.3                  ; how deep a boat sits in water
f_probe:    dd 0.25
f_float:    dd 3.0                  ; rising speed under water
f_settle:   dd 5.0
f_grav:     dd 26.0
f_maxfall:  dd -40.0
f_wacc:     dd 10.0                 ; acceleration on water, nodes/s^2
f_lacc:     dd 3.0                  ; on land
f_wmax:     dd 8.0                  ; top speed
f_lmax:     dd 2.0
f_wdrag:    dd 1.0
f_ldrag:    dd 6.0
f_half_w:   dd 0.6                  ; collision half width
f_pick_w:   dd 0.75                 ; for clicking it
f_height:   dd 0.6
f_low:      dd 0.1
f_mid:      dd 0.55
f_tiny:     dd 0.000001
f_hurt:     dd 0.4
f_decay:    dd 0.5                  ; hits forgotten per second
f_breaks:   dd 2.5                  ; the third hit breaks it
f_top:      dd 0.7                  ; getting out on top
f_out:      dd 1.3                  ; getting out onto the bank
f_x5:       dd 5.0
f_skin:     dd 0.01
f_void:     dd -100.0
f_180:      dd 180.0
f_rad2deg:  dd 57.29578
f_inv16:    dd 0.0625
exit_dirs:  dd 1.0, 0.0,  -1.0, 0.0,  0.0, 1.0,  0.0, -1.0

; model in 1/16 nodes, bottom at 0, front toward +z: x0 y0 z0 x1 y1 z1 r g b
%macro FPART 9
    dd %1, %2, %3, %4, %5, %6
    db %7, %8, %9, 0
    dd 0
%endmacro
m_boat:
    FPART  -8.0,  0.0, -14.0,   8.0,  2.0,  14.0, 196, 156, 100   ; floor
    FPART -10.0,  0.0, -16.0,  -8.0,  8.0,  16.0, 160, 118,  70   ; sides
    FPART   8.0,  0.0, -16.0,  10.0,  8.0,  16.0, 160, 118,  70
    FPART  -8.0,  0.0,  14.0,   8.0,  7.0,  16.0, 150, 110,  64   ; bow
    FPART  -8.0,  0.0, -16.0,   8.0,  7.0, -14.0, 150, 110,  64   ; stern
    FPART  -8.0,  4.0,  -2.0,   8.0,  5.0,   2.0, 180, 140,  88   ; seat
    FPART -10.5,  2.0,  -6.0, -10.0,  3.0,   6.0, 120,  86,  50   ; rub rails
    FPART  10.0,  2.0,  -6.0,  10.5,  3.0,   6.0, 120,  86,  50
    FPART -17.0,  6.0,  -0.6, -10.0,  7.0,   0.6, 150, 112,  66   ; oars
    FPART  10.0,  6.0,  -0.6,  17.0,  7.0,   0.6, 150, 112,  66
    FPART -20.0,  5.0,  -1.5, -17.0,  6.5,   1.5, 150, 112,  66   ; blades
    FPART  17.0,  5.0,  -1.5,  20.0,  6.5,   1.5, 150, 112,  66
M_BOAT_N equ ($ - m_boat) / 32

section .bss
alignb 16
boats:      resb MAX_BOATS * BT_SIZE
riding:     resd 1                  ; boat index + 1 the player sits in, 0 = none
ray:        resd 8                  ; eye x, y, z, dir x, y, z, reach

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

; void boat_clear(void)
boat_clear:
    lea rdi, [boats]
    xor eax, eax
    mov ecx, MAX_BOATS * BT_SIZE / 4
    rep stosd
    mov dword [riding], 0
    ret

; flags of the node at (xmm0, xmm1, xmm2) -> eax
flags_at:
    sub rsp, 8
    FLOORF edi, xmm0
    FLOORF esi, xmm1
    FLOORF edx, xmm2
    call world_get
    lea rcx, [block_flags]
    movzx eax, byte [rcx + rax]
    add rsp, 8
    ret

; view_ray - the eye and the view direction into ray[], the reach limited
; by the block looked at (distance to its centre - 0.5)
view_ray:
    sub rsp, 24
    fld dword [pitch]
    fsincos
    fstp dword [rsp]                ; cos
    fstp dword [rsp + 4]            ; sin
    movss xmm0, [pos]
    movss [ray], xmm0
    movss xmm0, [pos + 4]
    addss xmm0, [f_eye]
    movss [ray + 4], xmm0
    movss xmm0, [pos + 8]
    movss [ray + 8], xmm0
    movss xmm0, [syaw]
    mulss xmm0, [rsp]
    movss [ray + 12], xmm0
    xorps xmm0, xmm0
    subss xmm0, [rsp + 4]
    movss [ray + 16], xmm0
    movss xmm1, [cyaw]
    mulss xmm1, [rsp]
    xorps xmm0, xmm0
    subss xmm0, xmm1
    movss [ray + 20], xmm0
    movss xmm0, [f_reach]
    cmp dword [target_hit], 0
    je .r
    xorps xmm1, xmm1
    xor ecx, ecx
.d:
    lea rax, [target]
    cvtsi2ss xmm2, dword [rax + rcx*4]
    addss xmm2, [f_half]
    lea rax, [ray]
    subss xmm2, [rax + rcx*4]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    inc ecx
    cmp ecx, 3
    jb .d
    sqrtss xmm1, xmm1
    subss xmm1, [f_half]
    minss xmm0, xmm1
.r:
    movss [ray + 24], xmm0
    add rsp, 24
    ret

; int boat_pick(void) - the nearest boat in the view (not the one ridden),
; or -1. locals: [0] box min x y z, [12] box max, [24] best t, [28] best
boat_pick:
    ENTER_FN 48
    mov dword [rsp + 28], -1
    cmp dword [dimension], 0
    jne .done
    call view_ray
    mov eax, [ray + 24]
    mov [rsp + 24], eax
    mov dword [rsp + 28], -1
    xor r12d, r12d
.b:
    cmp r12d, MAX_BOATS
    jae .done
    imul eax, r12d, BT_SIZE
    lea rbx, [boats]
    add rbx, rax
    cmp dword [rbx + BT_USED], 0
    je .next
    lea eax, [r12 + 1]
    cmp eax, [riding]
    je .next
    movss xmm0, [rbx + BT_X]
    subss xmm0, [f_pick_w]
    movss [rsp], xmm0
    movss xmm0, [rbx + BT_X]
    addss xmm0, [f_pick_w]
    movss [rsp + 12], xmm0
    movss xmm0, [rbx + BT_Y]
    movss [rsp + 4], xmm0
    addss xmm0, [f_height]
    movss [rsp + 16], xmm0
    movss xmm0, [rbx + BT_Z]
    subss xmm0, [f_pick_w]
    movss [rsp + 8], xmm0
    movss xmm0, [rbx + BT_Z]
    addss xmm0, [f_pick_w]
    movss [rsp + 20], xmm0
    ; slabs: xmm4 near, xmm5 far
    xorps xmm4, xmm4
    movss xmm5, [rsp + 24]
    xor ecx, ecx
.s:
    lea rax, [ray]
    movss xmm3, [rax + 12 + rcx*4]  ; d
    movaps xmm6, xmm3
    andps xmm6, [rel absmask]
    comiss xmm6, [f_tiny]
    jae .dok
    movss xmm3, [f_tiny]
.dok:
    movss xmm0, [rsp + rcx*4]
    subss xmm0, [rax + rcx*4]
    divss xmm0, xmm3                ; t1
    movss xmm1, [rsp + 12 + rcx*4]
    subss xmm1, [rax + rcx*4]
    divss xmm1, xmm3                ; t2
    movaps xmm2, xmm0
    minss xmm2, xmm1
    maxss xmm0, xmm1
    maxss xmm4, xmm2
    minss xmm5, xmm0
    inc ecx
    cmp ecx, 3
    jb .s
    comiss xmm4, xmm5
    ja .next
    movss [rsp + 24], xmm4
    mov [rsp + 28], r12d
.next:
    inc r12d
    jmp .b
.done:
    mov eax, [rsp + 28]
    LEAVE_FN

; int boat_use(void) - right click on a boat: get in. 1 if one was there
boat_use:
    sub rsp, 8
    call boat_pick
    test eax, eax
    js .no
    inc eax
    mov [riding], eax
    call seat
    mov eax, 1
    add rsp, 8
    ret
.no:
    xor eax, eax
    add rsp, 8
    ret

; seat - the player sits in the boat ridden, feet on its floor
seat:
    mov eax, [riding]
    test eax, eax
    jz .out
    dec eax
    imul eax, eax, BT_SIZE
    lea rcx, [boats]
    add rcx, rax
    mov eax, [rcx + BT_X]
    mov [pos], eax
    mov eax, [rcx + BT_Y]
    mov [pos + 4], eax
    mov eax, [rcx + BT_Z]
    mov [pos + 8], eax
.out:
    ret

; int boat_attack(void) - a click on a boat: it rocks; the third hit in a
; short while breaks it (creative: the first) and it drops as an item.
; 1 if a boat was hit.
boat_attack:
    ENTER_FN 0
    call boat_pick
    test eax, eax
    js .no
    imul eax, eax, BT_SIZE
    lea rbx, [boats]
    add rbx, rax
    mov eax, [f_hurt]
    mov [rbx + BT_HURT], eax
    movss xmm0, [rbx + BT_DMG]
    addss xmm0, [f_one]
    movss [rbx + BT_DMG], xmm0
    cmp dword [game_mode], 0
    jne .gone                       ; creative: gone at once, no item
    comiss xmm0, [f_breaks]
    jb .hit
    movss xmm0, [rbx + BT_X]
    movss xmm1, [rbx + BT_Y]
    addss xmm1, [f_half]
    movss xmm2, [rbx + BT_Z]
    xorps xmm3, xmm3
    movss xmm4, [f_x5]
    xorps xmm5, xmm5
    mov edi, I_BOAT | (1 << 8)
    call ent_spawn
.gone:
    mov dword [rbx + BT_USED], 0
.hit:
    mov eax, 1
    LEAVE_FN
.no:
    xor eax, eax
    LEAVE_FN

; int boat_place(void) - put a boat where the player looks: on the first
; water along the view, else in front of the block looked at. 1 if placed.
; locals: [0] point x y z, [12] previous point, [24] steps
boat_place:
    ENTER_FN 32
    cmp dword [dimension], 0
    jne .no
    ; a free boat
    xor r12d, r12d
.free:
    imul eax, r12d, BT_SIZE
    lea rbx, [boats]
    add rbx, rax
    cmp dword [rbx + BT_USED], 0
    je .got
    inc r12d
    cmp r12d, MAX_BOATS
    jb .free
    jmp .no
.got:
    call view_ray
    mov eax, [ray]
    mov [rsp], eax
    mov [rsp + 12], eax
    mov eax, [ray + 4]
    mov [rsp + 4], eax
    mov [rsp + 16], eax
    mov eax, [ray + 8]
    mov [rsp + 8], eax
    mov [rsp + 20], eax
    mov dword [rsp + 24], 50        ; 5 nodes
.walk:
    ; previous = point, point += dir * step
    xor ecx, ecx
.adv:
    movss xmm0, [rsp + rcx*4]
    movss [rsp + 12 + rcx*4], xmm0
    lea rax, [ray]
    movss xmm1, [rax + 12 + rcx*4]
    mulss xmm1, [f_step]
    addss xmm0, xmm1
    movss [rsp + rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jb .adv
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, [rsp + 8]
    call flags_at
    test eax, F_LIQUID
    jnz .water
    test eax, F_SOLID
    jnz .solid
    dec dword [rsp + 24]
    jnz .walk
    jmp .no
.water:
    ; in that node, half way up: it floats to the top
    movss xmm0, [rsp + 4]
    FLOORF eax, xmm0
    cvtsi2ss xmm0, eax
    addss xmm0, [f_half]
    movss [rsp + 4], xmm0
    jmp .put
.solid:
    ; the free point before the block, on the floor of its node
    movss xmm0, [rsp + 16]
    FLOORF eax, xmm0
    cvtsi2ss xmm0, eax
    movss [rsp + 4], xmm0
    mov eax, [rsp + 12]
    mov [rsp], eax
    mov eax, [rsp + 20]
    mov [rsp + 8], eax
.put:
    mov rdi, rbx
    xor eax, eax
    mov ecx, BT_SIZE / 4
    rep stosd
    mov dword [rbx + BT_USED], 1
    mov eax, [rsp]
    mov [rbx + BT_X], eax
    mov eax, [rsp + 4]
    mov [rbx + BT_Y], eax
    mov eax, [rsp + 8]
    mov [rbx + BT_Z], eax
    call look_yaw
    movss [rbx + BT_YAW], xmm0
    mov eax, 1
    LEAVE_FN
.no:
    xor eax, eax
    LEAVE_FN

; look_yaw -> xmm0: the model yaw (degrees) facing the way the player looks
look_yaw:
    movss xmm0, [f_180]
    movss xmm1, [yaw]
    mulss xmm1, [f_rad2deg]
    subss xmm0, xmm1
    ret

; is the boat box at (xmm0 x, xmm1 y, xmm2 z) against a solid node? -> eax
; (corners at two heights). locals: [0] x [4] y [8] z [12] corner [16] height
boat_blocked:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    xor r12d, r12d                  ; corner 0-3
.c:
    xor r13d, r13d                  ; height 0-1
.h:
    movss xmm0, [rsp]
    movss xmm3, [f_half_w]
    test r12d, 1
    jz .cx
    xorps xmm4, xmm4
    subss xmm4, xmm3
    movaps xmm3, xmm4
.cx:
    addss xmm0, xmm3
    movss xmm2, [rsp + 8]
    movss xmm3, [f_half_w]
    test r12d, 2
    jz .cz
    xorps xmm4, xmm4
    subss xmm4, xmm3
    movaps xmm3, xmm4
.cz:
    addss xmm2, xmm3
    movss xmm1, [rsp + 4]
    addss xmm1, [f_low]
    test r13d, r13d
    jz .cy
    movss xmm1, [rsp + 4]
    addss xmm1, [f_mid]
.cy:
    call solid_at
    jnz .yes
    inc r13d
    cmp r13d, 2
    jb .h
    inc r12d
    cmp r12d, 4
    jb .c
    xor eax, eax
    LEAVE_FN
.yes:
    mov eax, 1
    LEAVE_FN

; is a solid node under the boat bottom at height xmm1 (centre or a
; corner)? -> eax. locals as boat_blocked
boat_floor:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    xor r12d, r12d
.c:
    movss xmm0, [rsp]
    movss xmm3, [f_half_w]
    test r12d, 1
    jz .cx
    xorps xmm4, xmm4
    subss xmm4, xmm3
    movaps xmm3, xmm4
.cx:
    addss xmm0, xmm3
    movss xmm2, [rsp + 8]
    movss xmm3, [f_half_w]
    test r12d, 2
    jz .cz
    xorps xmm4, xmm4
    subss xmm4, xmm3
    movaps xmm3, xmm4
.cz:
    addss xmm2, xmm3
    movss xmm1, [rsp + 4]
    call solid_at
    jnz .yes
    inc r12d
    cmp r12d, 4
    jb .c
    xor eax, eax
    LEAVE_FN
.yes:
    mov eax, 1
    LEAVE_FN

; get_out - out of the boat ridden: onto a free spot with ground under it
; beside the boat (the bank), else on top of the boat
; locals: [0] boat ptr, [8] side, [12] x, [16] z, [20] feet node y
get_out:
    ENTER_FN 32
    mov eax, [riding]
    dec eax
    imul eax, eax, BT_SIZE
    lea rbx, [boats]
    add rbx, rax
    mov dword [riding], 0
    xor r12d, r12d                  ; side
.side:
    lea rax, [exit_dirs]
    movss xmm0, [rax + r12*8]
    mulss xmm0, [f_out]
    addss xmm0, [rbx + BT_X]
    movss [rsp + 12], xmm0
    movss xmm0, [rax + r12*8 + 4]
    mulss xmm0, [f_out]
    addss xmm0, [rbx + BT_Z]
    movss [rsp + 16], xmm0
    movss xmm0, [rbx + BT_Y]
    addss xmm0, [f_half]
    FLOORF eax, xmm0
    mov [rsp + 20], eax
    xor r13d, r13d                  ; that height, then one up
.up:
    ; feet and head free, not water, ground below
    mov eax, [rsp + 20]
    add eax, r13d
    mov r14d, eax
    mov r15d, 0                     ; node offset -1, 0, 1
.ok:
    movss xmm0, [rsp + 12]
    lea eax, [r14 + r15 - 1]
    cvtsi2ss xmm1, eax
    addss xmm1, [f_half]
    movss xmm2, [rsp + 16]
    call flags_at
    cmp r15d, 0
    jne .free
    test eax, F_SOLID               ; below: ground
    jz .nexth
    jmp .okn
.free:
    test eax, F_SOLID | F_LIQUID
    jnz .nexth
.okn:
    inc r15d
    cmp r15d, 3
    jb .ok
    mov eax, [rsp + 12]
    mov [pos], eax
    cvtsi2ss xmm0, r14d
    movss [pos + 4], xmm0
    mov eax, [rsp + 16]
    mov [pos + 8], eax
    jmp .out
.nexth:
    inc r13d
    cmp r13d, 2
    jb .up
    inc r12d
    cmp r12d, 4
    jb .side
    ; nowhere: on top
    mov eax, [rbx + BT_X]
    mov [pos], eax
    movss xmm0, [rbx + BT_Y]
    addss xmm0, [f_top]
    movss [pos + 4], xmm0
    mov eax, [rbx + BT_Z]
    mov [pos + 8], eax
.out:
    LEAVE_FN

; void boat_update(void) - every boat: steering (ridden), floating or
; falling, sliding, hits fading; the player moves with the boat ridden
; locals: [0] in water, [4] ridden, [8] new y, [12] new x/z
boat_update:
    ENTER_FN 16
    cmp dword [dimension], 0        ; boats stay in the overworld
    jne .out
    xor r12d, r12d
.b:
    cmp r12d, MAX_BOATS
    jae .done
    imul eax, r12d, BT_SIZE
    lea rbx, [boats]
    add rbx, rax
    cmp dword [rbx + BT_USED], 0
    je .next
    ; water at the waterline?
    movss xmm0, [rbx + BT_X]
    movss xmm1, [rbx + BT_Y]
    addss xmm1, [f_probe]
    movss xmm2, [rbx + BT_Z]
    call flags_at
    and eax, F_LIQUID
    mov [rsp], eax
    ; ridden while playing: steer, or get out
    xor eax, eax
    lea ecx, [r12 + 1]
    cmp ecx, [riding]
    jne .notr
    inc eax
.notr:
    mov [rsp + 4], eax
    test eax, eax
    jz .drag
    cmp dword [state], GS_GAME
    jne .drag
    lea r13, [keys]
    mov eax, [bind_down]
    cmp byte [r13 + rax], 0
    je .steer
    call get_out
    mov dword [rsp + 4], 0
    jmp .drag
.steer:
    call look_yaw
    movss [rbx + BT_YAW], xmm0
    mov eax, [bind_fwd]
    movzx eax, byte [r13 + rax]
    mov ecx, [bind_back]
    movzx ecx, byte [r13 + rcx]
    sub eax, ecx
    cvtsi2ss xmm0, eax
    movss xmm1, [f_lacc]
    cmp dword [rsp], 0
    je .acc
    movss xmm1, [f_wacc]
.acc:
    mulss xmm0, xmm1
    mulss xmm0, [dt]                ; speed gained this frame
    movss xmm1, [syaw]
    mulss xmm1, xmm0
    addss xmm1, [rbx + BT_VX]
    movss [rbx + BT_VX], xmm1
    movss xmm1, [cyaw]
    mulss xmm1, xmm0
    movss xmm2, [rbx + BT_VZ]
    subss xmm2, xmm1
    movss [rbx + BT_VZ], xmm2
.drag:
    ; drag, and the top speed
    movss xmm0, [f_ldrag]
    movss xmm3, [f_lmax]
    cmp dword [rsp], 0
    je .dr
    movss xmm0, [f_wdrag]
    movss xmm3, [f_wmax]
.dr:
    mulss xmm0, [dt]
    movss xmm1, [f_one]
    subss xmm1, xmm0
    maxss xmm1, [f_zero]
    movss xmm0, [rbx + BT_VX]
    mulss xmm0, xmm1
    movss xmm2, [rbx + BT_VZ]
    mulss xmm2, xmm1
    movaps xmm4, xmm0
    mulss xmm4, xmm4
    movaps xmm5, xmm2
    mulss xmm5, xmm5
    addss xmm4, xmm5
    sqrtss xmm4, xmm4
    comiss xmm4, xmm3
    jbe .speedok
    divss xmm3, xmm4
    mulss xmm0, xmm3
    mulss xmm2, xmm3
.speedok:
    movss [rbx + BT_VX], xmm0
    movss [rbx + BT_VZ], xmm2

    ; up and down
    cmp dword [rsp], 0
    je .air
    movss xmm0, [rbx + BT_X]
    movss xmm1, [rbx + BT_Y]
    addss xmm1, [f_probe]
    addss xmm1, [f_one]
    movss xmm2, [rbx + BT_Z]
    call flags_at
    test eax, F_LIQUID
    jz .surface
    mov eax, [f_float]              ; under water: up
    mov [rbx + BT_VY], eax
    jmp .rise
.surface:
    ; settle with the bottom f_sink under the top of this water node
    movss xmm0, [rbx + BT_Y]
    addss xmm0, [f_probe]
    FLOORF eax, xmm0
    inc eax
    cvtsi2ss xmm0, eax
    subss xmm0, [f_sink]
    subss xmm0, [rbx + BT_Y]
    mulss xmm0, [f_settle]
    movss [rbx + BT_VY], xmm0
.rise:
    movss xmm1, [rbx + BT_VY]
    mulss xmm1, [dt]
    addss xmm1, [rbx + BT_Y]
    movss [rsp + 8], xmm1
    ; no rising into a block
    movss xmm0, [rbx + BT_VY]
    comiss xmm0, [f_zero]
    jbe .sety
    movss xmm0, [rbx + BT_X]
    addss xmm1, [f_height]
    movss xmm2, [rbx + BT_Z]
    call solid_at
    jz .sety
    mov dword [rbx + BT_VY], 0
    jmp .horiz
.air:
    movss xmm0, [rbx + BT_VY]
    movss xmm1, [f_grav]
    mulss xmm1, [dt]
    subss xmm0, xmm1
    maxss xmm0, [f_maxfall]
    movss [rbx + BT_VY], xmm0
    mulss xmm0, [dt]
    addss xmm0, [rbx + BT_Y]
    movss [rsp + 8], xmm0
    movss xmm0, [rbx + BT_X]
    movss xmm1, [rsp + 8]
    movss xmm2, [rbx + BT_Z]
    call boat_floor
    test eax, eax
    jz .sety
    ; landed: on top of that node (unless that is inside something)
    mov dword [rbx + BT_VY], 0
    movss xmm0, [rsp + 8]
    FLOORF eax, xmm0
    inc eax
    cvtsi2ss xmm1, eax
    movss [rsp + 8], xmm1
    addss xmm1, [f_skin]
    movss xmm0, [rbx + BT_X]
    movss xmm2, [rbx + BT_Z]
    call boat_floor
    test eax, eax
    jz .sety
    jmp .horiz
.sety:
    mov eax, [rsp + 8]
    mov [rbx + BT_Y], eax
.horiz:
    ; x, then z: a block in the way stops that direction
    movss xmm0, [rbx + BT_VX]
    mulss xmm0, [dt]
    addss xmm0, [rbx + BT_X]
    movss [rsp + 12], xmm0
    movss xmm1, [rbx + BT_Y]
    movss xmm2, [rbx + BT_Z]
    call boat_blocked
    test eax, eax
    jz .xok
    mov dword [rbx + BT_VX], 0
    jmp .z
.xok:
    mov eax, [rsp + 12]
    mov [rbx + BT_X], eax
.z:
    movss xmm2, [rbx + BT_VZ]
    mulss xmm2, [dt]
    addss xmm2, [rbx + BT_Z]
    movss [rsp + 12], xmm2
    movss xmm0, [rbx + BT_X]
    movss xmm1, [rbx + BT_Y]
    call boat_blocked
    test eax, eax
    jz .zok
    mov dword [rbx + BT_VZ], 0
    jmp .fade
.zok:
    mov eax, [rsp + 12]
    mov [rbx + BT_Z], eax
.fade:
    movss xmm0, [rbx + BT_HURT]
    subss xmm0, [dt]
    maxss xmm0, [f_zero]
    movss [rbx + BT_HURT], xmm0
    movss xmm1, [f_decay]
    mulss xmm1, [dt]
    movss xmm0, [rbx + BT_DMG]
    subss xmm0, xmm1
    maxss xmm0, [f_zero]
    movss [rbx + BT_DMG], xmm0
    ; fell out of the world
    movss xmm0, [rbx + BT_Y]
    comiss xmm0, [f_void]
    jae .seat
    mov dword [rbx + BT_USED], 0
    cmp dword [rsp + 4], 0
    je .next
    mov dword [riding], 0
    jmp .next
.seat:
    cmp dword [rsp + 4], 0
    je .next
    call seat
.next:
    inc r12d
    jmp .b
.done:
    ; a boat broken under the player: out of it
    mov eax, [riding]
    test eax, eax
    jz .out
    dec eax
    imul eax, eax, BT_SIZE
    lea rcx, [boats]
    cmp dword [rcx + rax + BT_USED], 0
    jne .out
    mov dword [riding], 0
.out:
    LEAVE_FN

; void draw_boats(void) - like draw_mobs: node units relative to the player
; chunk, lit by the light where the boat is, red while hit
draw_boats:
    ENTER_FN 16
    cmp dword [dimension], 0
    jne .out
    lea rax, [boats]
    xor ecx, ecx
.any:
    cmp dword [rax + BT_USED], 0
    jne .some
    add rax, BT_SIZE
    inc ecx
    cmp ecx, MAX_BOATS
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
.b:
    cmp r12d, MAX_BOATS
    jae .done
    imul eax, r12d, BT_SIZE
    lea rbx, [boats]
    add rbx, rax
    cmp dword [rbx + BT_USED], 0
    je .next
    movss xmm0, [rbx + BT_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + BT_Y]
    addss xmm0, [f_half]
    FLOORF esi, xmm0
    movss xmm0, [rbx + BT_Z]
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
    movss xmm0, [rbx + BT_HURT]
    comiss xmm0, [f_zero]
    jbe .lit
    mov dword [fig_tint], 256
    shr eax, 2
    mov [fig_tint + 4], eax
    mov [fig_tint + 8], eax
.lit:
    call glPushMatrix PLT
    mov eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm0, [rbx + BT_X]
    subss xmm0, xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm2, [rbx + BT_Z]
    subss xmm2, xmm1
    movss xmm1, [rbx + BT_Y]
    call glTranslatef PLT
    movss xmm0, [rbx + BT_YAW]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [f_inv16]
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    call glScalef PLT
    lea rdi, [m_boat]
    mov esi, M_BOAT_N
    call fig_parts
    call glPopMatrix PLT
.next:
    inc r12d
    jmp .b
.done:
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

section .rodata
align 16
absmask:    dd 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff

NOEXECSTACK
