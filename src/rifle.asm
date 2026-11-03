; rifle.asm - the assault rifle (creative only).
;
; Hold the left button to fire 10 rounds a second, as far as 64 nodes:
; each bullet hits the first mob in the view before any block for an iron
; sword's damage (6) and pushes it a little. The view kicks up a little
; with every shot. Endless ammunition. In survival it does nothing.
;
; While it is held the first-person view shows it: a blocky right arm on
; the grip, the left arm under the handguard, the rifle built from boxes
; (rails, sights, curved magazine...), swaying as you walk, kicking back
; with a muzzle flash when it fires.

%include "common.inc"

global rifle_fire, draw_viewmodel, rifle_kick

extern pos, vel, yaw, pitch, syaw, cyaw, dt, game_mode, inv, sel_slot
extern lmb_down, on_ground, state, player_dead, win_w, win_h
extern world_raycast, world_get, block_flags, mob_ray, mob_shot, randf, light_get, light_curve
extern sunlight, dimension, fig_parts, fig_tint
extern glMatrixMode, glPushMatrix, glPopMatrix, glLoadIdentity, glFrustum
extern glTranslatef, glRotatef, glScalef, glEnable, glDisable, glClear

GL_PROJECTION equ 0x1701
GL_MODELVIEW equ 0x1700
GL_DEPTH_BUFFER_BIT equ 0x100
GL_DEPTH_TEST equ 0x0B71
GL_TEXTURE_2D equ 0x0DE1
GL_FOG      equ 0x0B60
GL_CULL_FACE equ 0x0B44
GL_ALPHA_TEST equ 0x0BC0
GL_BLEND    equ 0x0BE2
RIFLE_DAMAGE equ 6                  ; an iron sword's
NETHER_LIGHT equ 8

section .rodata
align 8
d_near:     dq 0.05
d_far:      dq 8.0
d_tan:      dq 0.7                  ; its own field of view (70 degrees)
d_zero:     dq 0.0
align 4
f_zero:     dd 0.0
f_one:      dd 1.0
f_half:     dd 0.5
f_eye:      dd 1.6
f_range:    dd 64.0
f_rate:     dd 0.1                  ; seconds between rounds
f_climb:    dd 0.012                ; view kick per round (radians)
f_jitter:   dd 0.008
f_pitchmin: dd -1.55
f_kickfade: dd 9.0
f_flash:    dd 0.05
f_gx:       dd 0.26                 ; where the rifle sits in view
f_gy:       dd -0.25
f_gz:       dd -0.72
f_gyaw:     dd 7.0
f_kickz:    dd 0.05
f_kickrot:  dd 4.0
f_scale:    dd 0.019
f_bobrate:  dd 1.6
f_bobamp:   dd 0.012
f_moving:   dd 0.25                 ; squared speed that counts as walking
; arms: where the hand holds, which way the arm runs (degrees)
f_rh_y:     dd -4.4
f_rh_z:     dd 8.2
f_ra_yaw:   dd 24.0
f_ra_tilt:  dd 30.0
f_lh_y:     dd -3.6
f_lh_z:     dd -8.0
f_la_yaw:   dd -40.0
f_la_tilt:  dd 62.0

%macro FPART 9
    dd %1, %2, %3, %4, %5, %6
    db %7, %8, %9, 0
    dd 0
%endmacro
vm_rifle:
    FPART -1.00, -2.60, 9.00, 1.00, 1.00, 17.00, 34, 34, 36
    FPART -1.10, -3.20, 16.00, 1.10, 1.40, 17.60, 18, 18, 18
    FPART -0.70, 0.00, 6.00, 0.70, 0.80, 9.00, 92, 94, 100
    FPART -1.20, -1.80, -2.00, 1.20, 0.60, 9.00, 34, 34, 36
    FPART -1.15, 0.60, -3.00, 1.15, 2.20, 8.50, 58, 60, 64
    FPART -0.80, 2.20, -11.50, 0.80, 2.60, 8.00, 34, 34, 36
    FPART -0.80, 2.60, -11.00, 0.80, 3.00, -10.50, 34, 34, 36
    FPART -0.80, 2.60, -10.00, 0.80, 3.00, -9.50, 34, 34, 36
    FPART -0.80, 2.60, -9.00, 0.80, 3.00, -8.50, 34, 34, 36
    FPART -0.80, 2.60, -8.00, 0.80, 3.00, -7.50, 34, 34, 36
    FPART -0.80, 2.60, -7.00, 0.80, 3.00, -6.50, 34, 34, 36
    FPART -0.80, 2.60, -6.00, 0.80, 3.00, -5.50, 34, 34, 36
    FPART -0.80, 2.60, -5.00, 0.80, 3.00, -4.50, 34, 34, 36
    FPART -0.80, 2.60, -4.00, 0.80, 3.00, -3.50, 34, 34, 36
    FPART -0.80, 2.60, -3.00, 0.80, 3.00, -2.50, 34, 34, 36
    FPART -0.80, 2.60, -2.00, 0.80, 3.00, -1.50, 34, 34, 36
    FPART -0.80, 2.60, -1.00, 0.80, 3.00, -0.50, 34, 34, 36
    FPART -0.80, 2.60, 0.00, 0.80, 3.00, 0.50, 34, 34, 36
    FPART -0.80, 2.60, 1.00, 0.80, 3.00, 1.50, 34, 34, 36
    FPART -0.80, 2.60, 2.00, 0.80, 3.00, 2.50, 34, 34, 36
    FPART -0.80, 2.60, 3.00, 0.80, 3.00, 3.50, 34, 34, 36
    FPART -0.80, 2.60, 4.00, 0.80, 3.00, 4.50, 34, 34, 36
    FPART -0.80, 2.60, 5.00, 0.80, 3.00, 5.50, 34, 34, 36
    FPART -0.80, 2.60, 6.00, 0.80, 3.00, 6.50, 34, 34, 36
    FPART -0.80, 2.60, 7.00, 0.80, 3.00, 7.50, 34, 34, 36
    FPART -0.70, 2.60, 6.50, 0.70, 4.00, 7.80, 34, 34, 36
    FPART -0.70, 4.00, 6.80, -0.40, 4.60, 7.60, 34, 34, 36
    FPART 0.40, 4.00, 6.80, 0.70, 4.60, 7.60, 34, 34, 36
    FPART -0.60, 0.60, -13.50, 0.60, 2.40, -12.00, 58, 60, 64
    FPART -0.15, 2.40, -13.00, 0.15, 4.40, -12.60, 34, 34, 36
    FPART -0.60, 3.00, -13.20, -0.40, 4.20, -12.40, 34, 34, 36
    FPART 0.40, 3.00, -13.20, 0.60, 4.20, -12.40, 34, 34, 36
    FPART -1.35, -1.40, -12.00, 1.35, 2.20, -3.00, 46, 48, 50
    FPART -1.45, -0.40, -11.00, -1.35, 1.00, -10.00, 18, 18, 18
    FPART 1.35, -0.40, -11.00, 1.45, 1.00, -10.00, 18, 18, 18
    FPART -1.45, -0.40, -9.00, -1.35, 1.00, -8.00, 18, 18, 18
    FPART 1.35, -0.40, -9.00, 1.45, 1.00, -8.00, 18, 18, 18
    FPART -1.45, -0.40, -7.00, -1.35, 1.00, -6.00, 18, 18, 18
    FPART 1.35, -0.40, -7.00, 1.45, 1.00, -6.00, 18, 18, 18
    FPART -1.45, -0.40, -5.00, -1.35, 1.00, -4.00, 18, 18, 18
    FPART 1.35, -0.40, -5.00, 1.45, 1.00, -4.00, 18, 18, 18
    FPART -0.35, 0.30, -20.00, 0.35, 1.00, -12.00, 92, 94, 100
    FPART -0.60, 0.00, -22.50, 0.60, 1.30, -20.00, 58, 60, 64
    FPART -0.65, 0.40, -22.00, -0.55, 0.90, -21.00, 18, 18, 18
    FPART 0.55, 0.40, -22.00, 0.65, 0.90, -21.00, 18, 18, 18
    FPART -1.25, -2.60, 0.80, 1.25, -1.80, 4.40, 34, 34, 36
    FPART -0.90, -5.50, 1.20, 0.90, -1.80, 4.00, 70, 64, 52
    FPART -0.90, -8.00, 0.40, 0.90, -5.50, 3.40, 70, 64, 52
    FPART -0.90, -10.00, -0.60, 0.90, -8.00, 2.60, 70, 64, 52
    FPART -1.00, -10.60, -0.80, 1.00, -10.00, 2.80, 34, 34, 36
    FPART -0.95, -6.00, 1.60, -0.90, -3.00, 3.60, 90, 82, 66
    FPART 0.90, -6.00, 1.60, 0.95, -3.00, 3.60, 90, 82, 66
    FPART -0.30, -3.00, 4.40, 0.30, -2.70, 7.00, 34, 34, 36
    FPART -0.30, -3.00, 4.40, 0.30, -1.80, 4.70, 34, 34, 36
    FPART -0.15, -2.70, 5.40, 0.15, -1.80, 5.80, 92, 94, 100
    FPART -0.90, -5.20, 7.20, 0.90, -1.80, 9.00, 34, 34, 36
    FPART -0.90, -7.00, 7.80, 0.90, -5.20, 9.80, 34, 34, 36
    FPART 1.15, 1.40, 6.50, 2.00, 2.00, 7.60, 58, 60, 64
    FPART 1.15, 0.80, 1.00, 1.25, 1.80, 4.50, 18, 18, 18
    FPART 1.15, 0.80, 5.00, 1.70, 1.60, 6.00, 58, 60, 64
    FPART 1.20, -1.00, 6.00, 1.45, -0.50, 7.20, 92, 94, 100
VM_RIFLE_N equ ($ - vm_rifle) / 32
vm_arm:
    FPART -2.20, -2.20, -2.40, 2.20, 2.20, 3.00, 214, 168, 128
    FPART -2.00, -2.00, 3.00, 2.00, 2.00, 4.20, 160, 72, 34
    FPART -2.00, -2.00, 4.20, 2.00, 2.00, 24.00, 196, 92, 44
    FPART -2.25, -0.40, -1.60, -2.20, 1.60, 1.60, 196, 150, 112
VM_ARM_N equ ($ - vm_arm) / 32
vm_flash:
    FPART -1.40, -0.20, -25.50, 1.40, 1.60, -22.60, 255, 236, 140
    FPART -0.50, -1.40, -27.00, 0.50, 2.80, -22.60, 255, 170, 50
    FPART -2.60, 0.40, -24.50, 2.60, 1.00, -22.60, 255, 200, 80
VM_FLASH_N equ ($ - vm_flash) / 32


section .bss
alignb 4
shot_cool:  resd 1
rifle_kick: resd 1                  ; 1 right after a shot, fading
flash_t:    resd 1
bob_t:      resd 1
ray_out:    resd 6
ray:        resd 3                  ; direction
origin:     resd 3                  ; where the current cast starts

section .text

; void rifle_fire(void) - every frame the rifle is held (playing)
; locals: [0] cos pitch, [4] sin pitch, [8] block distance
rifle_fire:
    ENTER_FN 16
    movss xmm0, [shot_cool]
    subss xmm0, [dt]
    maxss xmm0, [f_zero]
    movss [shot_cool], xmm0
    cmp dword [game_mode], 0
    je .out                         ; creative only
    cmp dword [lmb_down], 0
    je .out
    comiss xmm0, [f_zero]
    ja .out
    mov eax, [f_rate]
    mov [shot_cool], eax
    mov eax, [f_one]
    mov [rifle_kick], eax
    mov eax, [f_flash]
    mov [flash_t], eax
    ; how far the first solid block is along the view (through fire,
    ; plants, torches)
    fld dword [pitch]
    fsincos
    fstp dword [rsp]
    fstp dword [rsp + 4]
    movss xmm0, [syaw]
    mulss xmm0, [rsp]
    movss [ray], xmm0
    xorps xmm0, xmm0
    subss xmm0, [rsp + 4]
    movss [ray + 4], xmm0
    xorps xmm0, xmm0
    movss xmm1, [cyaw]
    mulss xmm1, [rsp]
    subss xmm0, xmm1
    movss [ray + 8], xmm0
    mov eax, [pos]
    mov [origin], eax
    movss xmm0, [pos + 4]
    addss xmm0, [f_eye]
    movss [origin + 4], xmm0
    mov eax, [pos + 8]
    mov [origin + 8], eax
    mov dword [rsp + 8], 0          ; travelled
    mov r12d, 16                    ; casts at most
.cast:
    movss xmm0, [origin]
    movss xmm1, [origin + 4]
    movss xmm2, [origin + 8]
    movss xmm3, [ray]
    movss xmm4, [ray + 4]
    movss xmm5, [ray + 8]
    movss xmm6, [f_range]
    subss xmm6, [rsp + 8]
    lea rdi, [ray_out]
    call world_raycast
    test eax, eax
    jz .clear
    ; the distance to it from this cast's origin
    xorps xmm0, xmm0
    xor ecx, ecx
.d:
    lea rax, [ray_out]
    cvtsi2ss xmm1, dword [rax + rcx*4]
    addss xmm1, [f_half]
    lea rax, [origin]
    subss xmm1, [rax + rcx*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc ecx
    cmp ecx, 3
    jb .d
    sqrtss xmm0, xmm0
    subss xmm0, [f_half]
    maxss xmm0, [f_zero]
    movss [rsp + 12], xmm0
    mov edi, [ray_out]
    mov esi, [ray_out + 4]
    mov edx, [ray_out + 8]
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID
    jz .through
    movss xmm0, [rsp + 8]
    addss xmm0, [rsp + 12]
    jmp .far
.through:
    ; on past it
    movss xmm0, [rsp + 12]
    addss xmm0, [f_one]
    movss xmm1, [rsp + 8]
    addss xmm1, xmm0
    movss [rsp + 8], xmm1
    comiss xmm1, [f_range]
    jae .clear
    xor ecx, ecx
.adv:
    lea rax, [ray]
    movss xmm1, [rax + rcx*4]
    mulss xmm1, xmm0
    lea rax, [origin]
    addss xmm1, [rax + rcx*4]
    movss [rax + rcx*4], xmm1
    inc ecx
    cmp ecx, 3
    jb .adv
    dec r12d
    jnz .cast
.clear:
    movss xmm0, [f_range]
.far:
    ; the first mob before it takes the round
    call mob_ray
    test eax, eax
    js .recoil
    mov edi, eax
    mov esi, RIFLE_DAMAGE
    call mob_shot
.recoil:
    movss xmm0, [pitch]
    subss xmm0, [f_climb]
    maxss xmm0, [f_pitchmin]
    movss [pitch], xmm0
    call randf
    subss xmm0, [f_half]
    mulss xmm0, [f_jitter]
    addss xmm0, [yaw]
    movss [yaw], xmm0
.out:
    LEAVE_FN

; void draw_viewmodel(void) - after the world: the rifle in the hands
; when it is held. locals: [0] light, [8] bob x, [12] bob y
draw_viewmodel:
    ENTER_FN 32
    ; the kick and the flash fade (also when not firing)
    movss xmm0, [f_kickfade]
    mulss xmm0, [dt]
    movss xmm1, [rifle_kick]
    subss xmm1, xmm0
    maxss xmm1, [f_zero]
    movss [rifle_kick], xmm1
    movss xmm0, [flash_t]
    subss xmm0, [dt]
    maxss xmm0, [f_zero]
    movss [flash_t], xmm0
    cmp dword [player_dead], 0
    jne .out
    mov eax, [sel_slot]
    lea rcx, [inv]
    cmp byte [rcx + rax*4], I_RIFLE
    jne .out
    ; sway while walking
    movss xmm0, [vel]
    mulss xmm0, xmm0
    movss xmm1, [vel + 8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [f_moving]
    jbe .still
    cmp dword [on_ground], 0
    je .still
    sqrtss xmm0, xmm0
    mulss xmm0, [f_bobrate]
    mulss xmm0, [dt]
    addss xmm0, [bob_t]
    movss [bob_t], xmm0
.still:
    fld dword [bob_t]
    fsincos
    fstp dword [rsp + 12]           ; cos
    fstp dword [rsp + 8]            ; sin
    movss xmm0, [rsp + 8]
    mulss xmm0, [f_bobamp]
    movss [rsp + 8], xmm0
    movss xmm0, [rsp + 12]
    andps xmm0, [rel absmask]
    mulss xmm0, [f_bobamp]
    xorps xmm1, xmm1
    subss xmm1, xmm0
    movss [rsp + 12], xmm1
    ; lit like the place the player stands
    movss xmm0, [pos]
    cvttss2si edi, xmm0
    movss xmm0, [pos + 4]
    addss xmm0, [f_eye]
    cvttss2si esi, xmm0
    movss xmm0, [pos + 8]
    cvttss2si edx, xmm0
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
    cmp dword [dimension], 0
    je .lit
    movzx ecx, byte [rdx + NETHER_LIGHT]
    cmp eax, ecx
    cmovl eax, ecx
.lit:
    inc eax
    mov [rsp], eax
    ; its own projection, in front of everything
    mov edi, GL_DEPTH_BUFFER_BIT
    call glClear PLT
    mov edi, GL_PROJECTION
    call glMatrixMode PLT
    call glPushMatrix PLT
    call glLoadIdentity PLT
    movsd xmm3, [d_tan]
    mulsd xmm3, [d_near]            ; top
    cvtsi2sd xmm1, dword [win_w]
    mov eax, [win_h]
    test eax, eax
    jnz .h
    inc eax
.h:
    cvtsi2sd xmm2, eax
    divsd xmm1, xmm2
    mulsd xmm1, xmm3                ; right
    movsd xmm0, [d_zero]
    subsd xmm0, xmm1
    movsd xmm2, [d_zero]
    subsd xmm2, xmm3
    movsd xmm4, [d_near]
    movsd xmm5, [d_far]
    call glFrustum PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    call glPushMatrix PLT
    call glLoadIdentity PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, GL_FOG
    call glDisable PLT
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_BLEND
    call glDisable PLT
    mov edi, GL_DEPTH_TEST
    call glEnable PLT
    ; place it: right of centre, low, pointing a little in; the kick
    ; pushes it back and up
    movss xmm0, [f_gx]
    addss xmm0, [rsp + 8]
    movss xmm1, [f_gy]
    addss xmm1, [rsp + 12]
    movss xmm2, [rifle_kick]
    mulss xmm2, [f_kickz]
    addss xmm2, [f_gz]
    call glTranslatef PLT
    movss xmm0, [f_gyaw]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [rifle_kick]
    mulss xmm0, [f_kickrot]
    movss xmm1, [f_one]
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [f_scale]
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    call glScalef PLT
    mov eax, [rsp]
    mov [fig_tint], eax
    mov [fig_tint + 4], eax
    mov [fig_tint + 8], eax
    lea rdi, [vm_rifle]
    mov esi, VM_RIFLE_N
    call fig_parts
    ; the right arm from the grip, the left from under the handguard
    call glPushMatrix PLT
    xorps xmm0, xmm0
    movss xmm1, [f_rh_y]
    movss xmm2, [f_rh_z]
    call glTranslatef PLT
    movss xmm0, [f_ra_yaw]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [f_ra_tilt]
    movss xmm1, [f_one]
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glRotatef PLT
    lea rdi, [vm_arm]
    mov esi, VM_ARM_N
    call fig_parts
    call glPopMatrix PLT
    call glPushMatrix PLT
    xorps xmm0, xmm0
    movss xmm1, [f_lh_y]
    movss xmm2, [f_lh_z]
    call glTranslatef PLT
    movss xmm0, [f_la_yaw]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [f_la_tilt]
    movss xmm1, [f_one]
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glRotatef PLT
    lea rdi, [vm_arm]
    mov esi, VM_ARM_N
    call fig_parts
    call glPopMatrix PLT
    ; the muzzle flash, full bright
    movss xmm0, [flash_t]
    comiss xmm0, [f_zero]
    jbe .noflash
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
    lea rdi, [vm_flash]
    mov esi, VM_FLASH_N
    call fig_parts
.noflash:
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
    call glPopMatrix PLT
    mov edi, GL_PROJECTION
    call glMatrixMode PLT
    call glPopMatrix PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

section .rodata
align 16
absmask:    dd 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff

NOEXECSTACK
