; mobs.asm - pigs, cows and zombies.
;
; Pigs and cows spawn on grassy ground in daylight, wander, run when hit
; and drop raw meat. Zombies spawn in the dark (night, caves) unless the
; difficulty is Peaceful, walk at the player, hit for 1.5 hearts, burn in
; sunlight and drop rotten flesh. Mobs are not saved: they despawn far
; away and new ones spawn around the player.
;
; A mob is a box (half width, height) with gravity, collision against
; solid nodes, a jump up one node when walking into a wall, and floating
; in water. Models are boxes drawn with the inventory figure's code, lit by
; the light where the mob stands.

%include "common.inc"

global mobs, mob_count, mob_spawn, mob_update, mob_attack, mob_clear
global draw_mobs, crop_tick, game_rand, mob_spawning, mob_feed
global mob_pick, mob_blast, randf, mob_ray, mob_shot, draw_fireballs

extern pos, vel, syaw, cyaw, pitch, dt, sunlight, game_mode, set_difficulty
extern world_get, block_flags, light_get, light_curve, solid_at
extern player_damage, ent_spawn, inv, sel_slot, tool_of, tool_wear
extern cur_pcx, cur_pcz, target_hit, target, knock_x, knock_z
extern fig_parts, fig_tint, dimension, fire_set
extern world_find, world_set, chunk_hmap, chunk_blocks, wool_rgb
extern glPushMatrix, glPopMatrix, glTranslatef, glRotatef, glScalef
extern glEnable, glDisable

MAX_MOBS    equ 32
MOB_PIG     equ 1
MOB_COW     equ 2
MOB_ZOMBIE  equ 3
MOB_SHEEP   equ 4
MOB_WITHER  equ 5                   ; wither skeleton (the nether)
MOB_SLIME_L equ 6                   ; creative fun (spawn eggs only): slimes,
MOB_SLIME_M equ 7                   ; big, medium, small (each splits into
MOB_SLIME_S equ 8                   ; 2-4 of the next size)
MOB_GHAST   equ 9                   ; flies, shoots fireballs at other mobs
MOB_GIANT   equ 10                  ; a zombie 4 times the size
MAX_FIREBALLS equ 16
FB_USED     equ 0
FB_X        equ 4
FB_VX       equ 16
FB_AGE      equ 28
FB_SIZE     equ 32
NETHER_LIGHT equ 8
T_PICK      equ 1
T_AXE       equ 2
T_SHOVEL    equ 3
T_SWORD     equ 4
MAX_ANIMALS equ 8
MAX_ZOMBIES equ 6
GL_CULL_FACE equ 0x0B44
GL_TEXTURE_2D equ 0x0DE1
GL_ALPHA_TEST equ 0x0BC0

; mob record
MB_TYPE     equ 0
MB_X        equ 4                   ; feet, centre
MB_Y        equ 8
MB_Z        equ 12
MB_VY       equ 16
MB_KX       equ 20                  ; knockback, fading
MB_KZ       equ 24
MB_WX       equ 28                  ; where it wants to walk (nodes/s)
MB_WZ       equ 32
MB_YAW      equ 36                  ; degrees, 0 = facing +z
MB_HP       equ 40
MB_TIMER    equ 44                  ; wander: next decision; zombie: attack
MB_HURT     equ 48                  ; red flash left
MB_FLEE     equ 52                  ; running away left
MB_BURN     equ 56                  ; sunburn accumulator
MB_GROUND   equ 60
MB_TX       equ 64                  ; zombie: shade it walks to
MB_TZ       equ 68
MB_HASTGT   equ 72                  ; 1 = has a shade target
MB_LURED    equ 76                  ; animal following the player's food
MB_LOVE     equ 80                  ; seconds of love left (fed its food)
MB_BREEDCD  equ 84                  ; seconds before it can breed again
MB_AGE      equ 88                  ; < 0: a baby, seconds until grown
MB_COLOR    equ 92                  ; sheep: wool colour 0-15 (sheared: MB_BURN > 0)
MB_SIZE     equ 96

; type record: half width, height, speed, health, drop, most dropped
TY_HALF     equ 0
TY_HEIGHT   equ 4
TY_SPEED    equ 8
TY_HP       equ 12
TY_DROP     equ 16
TY_DROPMAX  equ 17
TY_SIZE     equ 20

section .rodata
align 4
types:
    times TY_SIZE db 0
    dd 0.45, 0.9, 1.4, 10           ; pig
    db I_PORK, 2, 0, 0
    dd 0.45, 1.4, 1.2, 10           ; cow
    db I_BEEF, 2, 0, 0
    dd 0.3, 1.9, 2.4, 20            ; zombie
    db I_FLESH, 2, 0, 0
    dd 0.45, 1.3, 1.2, 8            ; sheep
    db B_WOOL, 1, 0, 0
    dd 0.35, 2.4, 2.6, 20           ; wither skeleton
    db I_GUNPOWDER, 2, 0, 0
    dd 1.0, 2.0, 3.0, 16            ; big slime
    db 0, 0, 0, 0
    dd 0.5, 1.0, 3.5, 4             ; medium slime
    db 0, 0, 0, 0
    dd 0.25, 0.5, 4.0, 1            ; small slime
    db I_SLIMEBALL, 2, 0, 0
    dd 2.0, 5.5, 1.5, 10            ; ghast
    db I_GUNPOWDER, 2, 0, 0
    dd 1.2, 7.6, 1.2, 100           ; giant
    db I_FLESH, 4, 0, 0
; model scale per type (slimes and the giant reuse a model at another size)
mob_scale:  dd 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 2.0, 1.0, 0.5, 1.0, 4.0
f_zero:     dd 0.0
f_one:      dd 1.0
f_half:     dd 0.5
f_two:      dd 2.0
f_grav:     dd 26.0
f_maxfall:  dd -40.0
f_jump:     dd 7.6
f_float:    dd 2.0                  ; rising speed in water
f_floatacc: dd 14.0
f_edge:     dd 0.02
f_low:      dd 0.05
f_feet:     dd 0.001                ; lowest collision point above the feet
f_despawn:  dd 6400.0               ; 80 nodes squared
f_chase:    dd 576.0                ; zombies notice the player at 24 nodes
f_reach2:   dd 2.56                 ; zombie hits within 1.6 nodes
f_reachy:   dd 1.8
f_flee:     dd 1.8                  ; speed factor when running
f_fleet:    dd 4.0                  ; seconds
f_hurtt:    dd 0.5                  ; red flash, and a zombie staggers
f_knock:    dd 12.0                 ; a hit pushes a mob about 3 nodes
f_knockup:  dd 6.0
f_pknock:   dd 7.0                  ; player pushed back by a zombie hit
f_pknockup: dd 4.5
f_fade:     dd 4.0                  ; knockback fades at this rate
f_cool:     dd 1.0                  ; zombie attack interval
f_reach:    dd 3.5                  ; player's reach for hitting
f_sunburn:  dd 0.6
f_rad2deg:  dd 57.29578
f_2pi:      dd 6.2831853
f_inv65536: dd 0.0000152587890625
f_inv255:   dd 0.0039215686
f_inv16:    dd 0.0625
f_big:      dd 1.0e30
f_spawnmin: dd 16.0
f_spawnrng: dd 24.0
f_spawn_t:  dd 1.0                  ; seconds between spawn attempts
f_cropsamp: dd 3000.0               ; columns looked at per second
f_tiny:     dd 0.000001
f_lure2:    dd 100.0                ; lured from 10 nodes away
f_near2:    dd 4.0                  ; and stops 2 nodes from the player
f_ahead:    dd 0.9                  ; how far ahead a mob looks for water
f_below:    dd 0.5
f_below2:   dd 1.5
f_arrive:   dd 0.36
f_fenceh:   dd 0.3
f_stop2:    dd 1.0                  ; a chasing zombie stops 1 node away
f_turn:     dd 540.0                ; degrees a second a mob can turn
f_180:      dd 180.0
f_360:      dd 360.0
f_pause:    dd 1.0                  ; stands this long after meeting water
f_lavarate: dd 8.0                  ; damage a second in lava
f_hop:      dd 7.0                  ; slimes: jump speed, wait 0.6-2.0 s
f_hopmin:   dd 0.6
f_hopwait:  dd 1.4
f_gwander:  dd 3.0                  ; ghasts: a new way every 3-6 s
f_gfloat:   dd 6.0                  ; float this high over the ground
f_gclimb:   dd 0.8
f_gvmax:    dd 2.0
f_gshoot:   dd 3.0                  ; seconds between shots
f_gsight:   dd 1024.0               ; at mobs within 32 nodes
f_gmouth:   dd 0.6
f_gmid:     dd 3.0                  ; middle of the body over its feet
f_gmuzzle:  dd 2.6                  ; fireballs start this far out
f_fbspeed:  dd 10.0
f_fblife:   dd 8.0
f_fbr:      dd 2.5                  ; fireball blast radius
f_fbdmg:    dd 8.0
f_fbknock:  dd 9.0
f_shotknock: dd 3.0                 ; a bullet pushes a mob a little
f_fbspin:   dd 400.0
f_stretch:  dd 1.15
f_thin:     dd 0.93
f_squash:   dd 0.8
f_wide:     dd 1.1
f_squasht:  dd 0.25
f_blastr:   dd 8.0                  ; explosions reach this far (2 x power 4)
f_blastk:   dd 15.0                 ; knockback at the centre
f_blastup:  dd 8.0
f_blastd:   dd 28.0                 ; (impact^2 + impact) / 2 x 56
f_lovet:    dd 30.0                 ; in love this long after eating
f_breedcd:  dd 60.0
f_babyage:  dd -300.0               ; babies grow up in 5 minutes
f_feedgrow: dd 30.0                 ; feeding a baby: this much sooner
f_mate2:    dd 64.0                 ; looks for a partner within 8 nodes
f_meet2:    dd 1.44                 ; close enough: 1.2 nodes
f_inv32:    dd 0.03125
f_16:       dd 16.0
f_heart_y:  dd 0.35                 ; heart above the head
f_step:     dd 0.5                  ; looks this far ahead for a step up
f_up1:      dd 1.05
f_tall:     dd 1.5                  ; mobs closer than this in height can touch
f_eye:      dd 1.6
f_head:     dd 1.5
f_lift:     dd 0.4                  ; water test height
align 16
f_absmask:  dd 0x7fffffff, 0, 0, 0

; models in 1/16 nodes, feet at 0, facing +z (same boxes as the player
; figure): x0 y0 z0 x1 y1 z1 r g b
%macro FPART 9
    dd %1, %2, %3, %4, %5, %6
    db %7, %8, %9, 0
    dd 0
%endmacro
m_pig:
    FPART -5.0,  6.0, -8.0,  5.0, 14.0,  7.0, 240, 168, 168   ; body
    FPART -4.0,  7.0,  7.0,  4.0, 15.0, 14.0, 240, 168, 168   ; head
    FPART -2.0,  8.0, 14.0,  2.0, 11.0, 15.5, 222, 128, 136   ; snout
    FPART -3.5, 12.0, 14.0, -1.5, 13.5, 14.3,  30,  30,  30   ; eyes
    FPART  1.5, 12.0, 14.0,  3.5, 13.5, 14.3,  30,  30,  30
    FPART -5.0,  0.0,  3.0, -1.0,  6.0,  7.0, 226, 154, 154   ; legs
    FPART  1.0,  0.0,  3.0,  5.0,  6.0,  7.0, 226, 154, 154
    FPART -5.0,  0.0, -8.0, -1.0,  6.0, -4.0, 226, 154, 154
    FPART  1.0,  0.0, -8.0,  5.0,  6.0, -4.0, 226, 154, 154
M_PIG_N equ ($ - m_pig) / 32
m_cow:
    FPART -6.0, 10.0, -9.0,  6.0, 20.0,  9.0,  86,  58,  40   ; body
    FPART -6.2, 13.0, -4.0,  6.2, 18.0,  3.0, 232, 230, 224   ; white patch
    FPART -4.0, 14.0,  9.0,  4.0, 22.0, 15.0,  86,  58,  40   ; head
    FPART -3.0, 14.0, 15.0,  3.0, 18.0, 16.5, 214, 176, 150   ; muzzle
    FPART -6.0, 21.0, 11.0, -4.0, 23.0, 12.5, 220, 220, 210   ; horns
    FPART  4.0, 21.0, 11.0,  6.0, 23.0, 12.5, 220, 220, 210
    FPART -3.5, 19.0, 15.0, -1.5, 20.5, 15.3,  20,  20,  20   ; eyes
    FPART  1.5, 19.0, 15.0,  3.5, 20.5, 15.3,  20,  20,  20
    FPART -6.0,  0.0,  5.0, -2.0, 10.0,  9.0,  70,  48,  34   ; legs
    FPART  2.0,  0.0,  5.0,  6.0, 10.0,  9.0,  70,  48,  34
    FPART -6.0,  0.0, -9.0, -2.0, 10.0, -5.0,  70,  48,  34
    FPART  2.0,  0.0, -9.0,  6.0, 10.0, -5.0,  70,  48,  34
M_COW_N equ ($ - m_cow) / 32
m_zombie:
    FPART -4.0,  0.0, -2.0,  0.0, 12.0,  2.0,  58,  52, 118   ; legs
    FPART  0.0,  0.0, -2.0,  4.0, 12.0,  2.0,  58,  52, 118
    FPART -4.0, 12.0, -2.0,  4.0, 24.0,  2.0,  40, 128, 136   ; shirt
    FPART -8.0, 20.0, -2.0, -4.0, 24.0, 12.0,  92, 148,  82   ; arms, held out
    FPART  4.0, 20.0, -2.0,  8.0, 24.0, 12.0,  92, 148,  82
    FPART -4.0, 24.0, -4.0,  4.0, 32.0,  4.0,  92, 148,  82   ; head
    FPART -3.0, 28.0,  4.0, -1.0, 29.5,  4.3,  20,  30,  20   ; eyes
    FPART  1.0, 28.0,  4.0,  3.0, 29.5,  4.3,  20,  30,  20
    FPART -2.0, 25.5,  4.0,  2.0, 26.5,  4.3,  50,  80,  45   ; mouth
M_ZOMBIE_N equ ($ - m_zombie) / 32
m_sheep:                            ; what is not wool (and the shorn body)
    FPART -4.0,  7.0, -7.0,  4.0, 15.0,  6.0, 226, 186, 176   ; shorn body
    FPART -3.0, 12.0,  7.0,  3.0, 18.0, 13.0, 206, 184, 164   ; head
    FPART -2.5, 15.0, 13.0, -0.8, 16.5, 13.3,  30,  30,  30   ; eyes
    FPART  0.8, 15.0, 13.0,  2.5, 16.5, 13.3,  30,  30,  30
    FPART -4.5,  0.0,  3.0, -1.5,  7.0,  6.0, 206, 184, 164   ; legs
    FPART  1.5,  0.0,  3.0,  4.5,  7.0,  6.0, 206, 184, 164
    FPART -4.5,  0.0, -7.0, -1.5,  7.0, -4.0, 206, 184, 164
    FPART  1.5,  0.0, -7.0,  4.5,  7.0, -4.0, 206, 184, 164
M_SHEEP_N equ ($ - m_sheep) / 32
m_sheep_wool:                       ; drawn in the wool colour
    FPART -5.5,  6.0, -8.5,  5.5, 17.0,  7.5, 255, 255, 255   ; fleece
    FPART -3.4, 16.0,  6.5,  3.4, 18.6, 11.0, 255, 255, 255   ; on the head
    FPART -5.0,  4.0,  2.5, -1.0,  7.0,  6.5, 255, 255, 255   ; on the legs
    FPART  1.0,  4.0,  2.5,  5.0,  7.0,  6.5, 255, 255, 255
    FPART -5.0,  4.0, -7.5, -1.0,  7.0, -3.5, 255, 255, 255
    FPART  1.0,  4.0, -7.5,  5.0,  7.0, -3.5, 255, 255, 255
M_SHEEP_WOOL_N equ ($ - m_sheep_wool) / 32
m_wither:                           ; tall, thin, nearly black
    FPART -3.0,  0.0, -1.0, -1.0, 18.0,  1.0,  36,  36,  38   ; legs
    FPART  1.0,  0.0, -1.0,  3.0, 18.0,  1.0,  36,  36,  38
    FPART -4.0, 18.0, -1.5,  4.0, 30.0,  1.5,  44,  44,  46   ; ribs
    FPART -1.0, 18.0, -2.0,  1.0, 30.0,  2.0,  28,  28,  30   ; spine
    FPART -6.0, 27.0, -1.0, -4.0, 30.0, 12.0,  36,  36,  38   ; arms, held out
    FPART  4.0, 27.0, -1.0,  6.0, 30.0, 12.0,  36,  36,  38
    FPART -4.0, 30.0, -4.0,  4.0, 38.0,  4.0,  48,  48,  50   ; skull
    FPART -3.0, 33.0,  4.0, -1.0, 35.0,  4.3,  10,  10,  10   ; eyes
    FPART  1.0, 33.0,  4.0,  3.0, 35.0,  4.3,  10,  10,  10
    FPART -2.0, 31.0,  4.0,  2.0, 32.0,  4.3,  20,  20,  20   ; teeth
    FPART  5.0, 22.0, 10.0,  6.0, 34.0, 11.0, 130, 130, 136   ; a stone sword
M_WITHER_N equ ($ - m_wither) / 32
m_slime:                            ; a green cube with a face (1 node; scaled)
    FPART -8.0,  0.0, -8.0,  8.0, 16.0,  8.0, 112, 200,  92
    FPART -5.0,  9.0,  8.0, -2.0, 12.0,  8.4,  24,  56,  24   ; eyes
    FPART  2.0,  9.0,  8.0,  5.0, 12.0,  8.4,  24,  56,  24
    FPART -1.0,  4.0,  8.0,  1.0,  6.0,  8.4,  40,  90,  36   ; mouth
M_SLIME_N equ ($ - m_slime) / 32
m_ghast:                            ; a big white jelly, nine tentacles below
    FPART -32.0, 24.0, -32.0, 32.0, 88.0, 32.0, 240, 240, 240
    FPART -18.0, 58.0, 32.0, -8.0, 64.0, 32.6,  60,  60,  64  ; eyes
    FPART   8.0, 58.0, 32.0, 18.0, 64.0, 32.6,  60,  60,  64
    FPART -10.0, 40.0, 32.0, 10.0, 46.0, 32.6,  80,  70,  70  ; mouth
    FPART -22.5, 6.0, -22.5, -17.5, 24.0, -17.5, 226, 226, 226
    FPART -2.5, 12.0, -22.5, 2.5, 24.0, -17.5, 226, 226, 226
    FPART 17.5, 4.0, -22.5, 22.5, 24.0, -17.5, 226, 226, 226
    FPART -22.5, 10.0, -2.5, -17.5, 24.0, 2.5, 226, 226, 226
    FPART -2.5, 2.0, -2.5, 2.5, 24.0, 2.5, 226, 226, 226
    FPART 17.5, 8.0, -2.5, 22.5, 24.0, 2.5, 226, 226, 226
    FPART -22.5, 5.0, 17.5, -17.5, 24.0, 22.5, 226, 226, 226
    FPART -2.5, 11.0, 17.5, 2.5, 24.0, 22.5, 226, 226, 226
    FPART 17.5, 7.0, 17.5, 22.5, 24.0, 22.5, 226, 226, 226
M_GHAST_N equ ($ - m_ghast) / 32
m_ghast_mouth:                      ; open and glowing while it shoots
    FPART -12.0, 36.0, 32.0, 12.0, 48.0, 32.8, 200,  48,  32
m_fireball:
    FPART -4.0, -4.0, -4.0,  4.0,  4.0,  4.0, 255, 120,  24
    FPART -3.0, -5.0, -3.0,  3.0,  5.0,  3.0, 255, 200,  60
    FPART -5.0, -3.0, -3.0,  5.0,  3.0,  3.0, 255, 170,  40
M_FIREBALL_N equ ($ - m_fireball) / 32
m_heart:                            ; above a mob in love
    FPART -3.0,  1.0, -0.5, -0.5,  3.0,  0.5, 232,  44,  64
    FPART  0.5,  1.0, -0.5,  3.0,  3.0,  0.5, 232,  44,  64
    FPART -2.0, -1.0, -0.5,  2.0,  1.5,  0.5, 232,  44,  64
    FPART -1.0, -2.0, -0.5,  1.0, -0.5,  0.5, 232,  44,  64
M_HEART_N equ ($ - m_heart) / 32

section .data
align 8
models:     dq 0, m_pig, m_cow, m_zombie, m_sheep, m_wither
            dq m_slime, m_slime, m_slime, m_ghast, m_zombie
model_n:    dd 0, M_PIG_N, M_COW_N, M_ZOMBIE_N, M_SHEEP_N, M_WITHER_N
            dd M_SLIME_N, M_SLIME_N, M_SLIME_N, M_GHAST_N, M_ZOMBIE_N
rng:        dd 0x2545f491
mob_spawning: dd 1                  ; 0 = no natural spawning (tests)

section .bss
alignb 16
mobs:       resb MAX_MOBS * MB_SIZE
mob_count:  resd 1
spawn_t:    resd 1
p_dist:     resd 1                  ; scratch: player distance of this mob
p_dx:       resd 1
p_dz:       resd 1
ray_dir:    resd 2                  ; x, z of the last mob_pick ray
fireballs:  resb MAX_FIREBALLS * FB_SIZE

section .text

; eax = next pseudo-random 32-bit value
game_rand:
rand:
    mov eax, [rng]
    imul eax, eax, 1664525
    add eax, 1013904223
    mov [rng], eax
    ret

; xmm0 = random float in [0, 1)
randf:
    sub rsp, 8
    call rand
    shr eax, 16
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_inv65536]
    add rsp, 8
    ret

; void mob_clear(void)
mob_clear:
    mov dword [mob_count], 0
    lea rdi, [fireballs]
    xor eax, eax
    mov ecx, MAX_FIREBALLS * FB_SIZE / 4
    rep stosd
    ret

; rax = type record of mob rbx
%macro TYPEREC 0
    mov eax, [rbx + MB_TYPE]
    imul eax, eax, TY_SIZE
    lea rcx, [types]
    add rax, rcx
%endmacro

; floor of xmm float %2 into %1 (xmm7 scratch)
%macro FLOORF 2
    cvttss2si %1, %2
    cvtsi2ss xmm7, %1
    comiss xmm7, %2
    jbe %%ok
    dec %1
%%ok:
%endmacro

; int mob_spawn(int type, float x, y, z) - index, or -1 when full
mob_spawn:
    mov eax, [mob_count]
    cmp eax, MAX_MOBS
    jb .room
    mov eax, -1
    ret
.room:
    inc dword [mob_count]
    mov ecx, eax
    imul ecx, ecx, MB_SIZE
    lea rdx, [mobs]
    add rdx, rcx
    xorps xmm3, xmm3
    movups [rdx], xmm3
    movups [rdx + 16], xmm3
    movups [rdx + 32], xmm3
    movups [rdx + 48], xmm3
    movups [rdx + 64], xmm3
    movups [rdx + 80], xmm3
    mov [rdx + MB_TYPE], edi
    movss [rdx + MB_X], xmm0
    movss [rdx + MB_Y], xmm1
    movss [rdx + MB_Z], xmm2
    imul ecx, edi, TY_SIZE
    lea r8, [types]
    mov ecx, [r8 + rcx + TY_HP]
    mov [rdx + MB_HP], ecx
    ret

; eax = 1 if mob rbx's box with its feet at (xmm0, xmm1, xmm2) touches no
; solid node (corners at the bottom, middle and top)
; locals: [0] x, [4] y, [8] z, [12] half width, [16] height, [20] 3 heights
mob_free:
    push r12
    push r13
    sub rsp, 40
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    TYPEREC
    movss xmm3, [rax + TY_HALF]
    subss xmm3, [f_edge]
    movss [rsp + 12], xmm3
    movss xmm3, [rax + TY_HEIGHT]
    movss [rsp + 16], xmm3
    movss xmm3, [f_feet]            ; right at the feet: no sinking in
    movss [rsp + 20], xmm3
    movss xmm3, [rsp + 16]
    mulss xmm3, [f_half]
    movss [rsp + 24], xmm3
    movss xmm3, [rsp + 16]
    subss xmm3, [f_low]
    movss [rsp + 28], xmm3
    xor r12d, r12d                  ; height
.h:
    xor r13d, r13d                  ; corner
.c:
    movss xmm0, [rsp]
    test r13d, 1
    jz .xm
    addss xmm0, [rsp + 12]
    jmp .xd
.xm:
    subss xmm0, [rsp + 12]
.xd:
    movss xmm2, [rsp + 8]
    test r13d, 2
    jz .zm
    addss xmm2, [rsp + 12]
    jmp .zd
.zm:
    subss xmm2, [rsp + 12]
.zd:
    movss xmm1, [rsp + 4]
    addss xmm1, [rsp + 20 + r12*4]
    call solid_at
    jnz .blocked
    inc r13d
    cmp r13d, 4
    jb .c
    inc r12d
    cmp r12d, 3
    jb .h
    mov eax, 1
    jmp .out
.blocked:
    xor eax, eax
.out:
    add rsp, 40
    pop r13
    pop r12
    ret

; gravity (or floating in water), walking with collision, a jump when it
; walks into a wall, facing where it goes. rbx mob
; locals: [0] new coordinate, [4] blocked
mob_physics:
    ENTER_FN 16
    mov dword [rsp + 4], 0
    ; knockback fades
    movss xmm0, [f_one]
    movss xmm1, [f_fade]
    mulss xmm1, [dt]
    subss xmm0, xmm1
    maxss xmm0, [f_zero]
    movss xmm1, [rbx + MB_KX]
    mulss xmm1, xmm0
    movss [rbx + MB_KX], xmm1
    movss xmm1, [rbx + MB_KZ]
    mulss xmm1, xmm0
    movss [rbx + MB_KZ], xmm1
    ; in water it floats up, otherwise it falls
    movss xmm0, [rbx + MB_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + MB_Y]
    addss xmm0, [f_lift]
    FLOORF esi, xmm0
    movss xmm0, [rbx + MB_Z]
    FLOORF edx, xmm0
    call world_get
    lea rcx, [block_flags]
    movss xmm0, [rbx + MB_VY]
    movss xmm1, [dt]
    test byte [rcx + rax], F_LIQUID
    jz .fall
    mulss xmm1, [f_floatacc]
    addss xmm0, xmm1
    minss xmm0, [f_float]
    jmp .vy
.fall:
    mulss xmm1, [f_grav]
    subss xmm0, xmm1
    maxss xmm0, [f_maxfall]
.vy:
    movss [rbx + MB_VY], xmm0
    ; x
    movss xmm0, [rbx + MB_WX]
    addss xmm0, [rbx + MB_KX]
    mulss xmm0, [dt]
    addss xmm0, [rbx + MB_X]
    movss [rsp], xmm0
    movss xmm1, [rbx + MB_Y]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    test eax, eax
    jz .xb
    movss xmm0, [rsp]
    movss [rbx + MB_X], xmm0
    jmp .z
.xb:
    mov dword [rsp + 4], 1
.z:
    movss xmm2, [rbx + MB_WZ]
    addss xmm2, [rbx + MB_KZ]
    mulss xmm2, [dt]
    addss xmm2, [rbx + MB_Z]
    movss [rsp], xmm2
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    call mob_free
    test eax, eax
    jz .zb
    movss xmm0, [rsp]
    movss [rbx + MB_Z], xmm0
    jmp .jump
.zb:
    mov dword [rsp + 4], 1
.jump:
    ; walked into a wall while on the ground: jump up
    cmp dword [rsp + 4], 0
    je .y
    cmp dword [rbx + MB_GROUND], 0
    je .y
    call fence_ahead                ; fences and gates are not jumped
    test eax, eax
    jnz .stuck
    call step_clear                 ; nor walls it could not stand on
    test eax, eax
    jz .stuck
    mov eax, [f_jump]
    mov [rbx + MB_VY], eax
    jmp .y
.stuck:
    ; it cannot get up there: stop (no hopping in place against a wall)
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
.y:
    movss xmm1, [rbx + MB_VY]
    mulss xmm1, [dt]
    addss xmm1, [rbx + MB_Y]
    movss [rsp], xmm1
    movss xmm0, [rbx + MB_X]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    test eax, eax
    jz .yb
    ; standing still, gravity's first tiny step down is always free: only
    ; leave the ground when there is room to fall (no flicker in and out)
    cmp dword [rbx + MB_GROUND], 0
    je .yfall
    movss xmm0, [rbx + MB_VY]
    comiss xmm0, [f_zero]
    ja .yfall
    movss xmm1, [rbx + MB_Y]
    subss xmm1, [f_low]
    movss xmm0, [rbx + MB_X]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    test eax, eax
    jnz .yfall
    mov dword [rbx + MB_VY], 0
    jmp .face
.yfall:
    movss xmm0, [rsp]
    movss [rbx + MB_Y], xmm0
    mov dword [rbx + MB_GROUND], 0
    jmp .face
.yb:
    movss xmm0, [rbx + MB_VY]
    mov dword [rbx + MB_VY], 0
    comiss xmm0, [f_zero]
    jae .face                       ; hit a ceiling
    ; landed: stand on top of what is below - half a node up when that is
    ; the top of a fence (1.5 nodes tall), else on the node
    movss xmm0, [rsp]
    FLOORF eax, xmm0
    cvtsi2ss xmm1, eax
    addss xmm1, [f_half]
    movss [rsp + 8], xmm1
    movss xmm0, [rbx + MB_X]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    movss xmm0, [rsp + 8]
    test eax, eax
    jnz .landed
    addss xmm0, [f_half]
.landed:
    movss [rbx + MB_Y], xmm0
    mov dword [rbx + MB_GROUND], 1
.face:
    movss xmm0, [rbx + MB_WX]
    andps xmm0, [f_absmask]
    movss xmm1, [rbx + MB_WZ]
    andps xmm1, [f_absmask]
    addss xmm0, xmm1
    comiss xmm0, [f_edge]
    jbe .out
    fld dword [rbx + MB_WX]
    fld dword [rbx + MB_WZ]
    fpatan                          ; atan2(wx, wz)
    fmul dword [f_rad2deg]
    fstp dword [rsp + 8]
    ; turn toward it at a limited speed (no snapping back and forth)
    movss xmm0, [rsp + 8]
    subss xmm0, [rbx + MB_YAW]
    comiss xmm0, [f_180]
    jbe .w1
    subss xmm0, [f_360]
.w1:
    movss xmm1, [f_180]
    xorps xmm2, xmm2
    subss xmm2, xmm1
    comiss xmm0, xmm2
    jae .w2
    addss xmm0, [f_360]
.w2:
    movss xmm1, [f_turn]
    mulss xmm1, [dt]
    minss xmm0, xmm1
    xorps xmm2, xmm2
    subss xmm2, xmm1
    maxss xmm0, xmm2
    addss xmm0, [rbx + MB_YAW]
    comiss xmm0, [f_180]
    jbe .w3
    subss xmm0, [f_360]
.w3:
    movss xmm1, [f_180]
    xorps xmm2, xmm2
    subss xmm2, xmm1
    comiss xmm0, xmm2
    jae .w4
    addss xmm0, [f_360]
.w4:
    movss [rbx + MB_YAW], xmm0
.out:
    LEAVE_FN

; a zombie next to the player hits it once a second (rbx mob; p_dist,
; p_dx, p_dz set)
zombie_attack:
    sub rsp, 8
    movss xmm0, [p_dist]
    comiss xmm0, [f_reach2]
    ja .out
    movss xmm0, [pos + 4]
    subss xmm0, [rbx + MB_Y]
    andps xmm0, [f_absmask]
    comiss xmm0, [f_reachy]
    ja .out
    movss xmm0, [rbx + MB_TIMER]
    subss xmm0, [dt]
    movss [rbx + MB_TIMER], xmm0
    comiss xmm0, [f_zero]
    ja .out
    mov eax, [f_cool]
    mov [rbx + MB_TIMER], eax
    cmp dword [game_mode], 0
    jne .out                        ; creative players are not hurt
    mov edi, 3
    cmp dword [rbx + MB_TYPE], MOB_WITHER
    jne .hit
    mov edi, 5                      ; a wither skeleton's sword
.hit:
    call player_damage
    ; pushed away from the zombie
    movss xmm1, [p_dist]
    sqrtss xmm1, xmm1
    maxss xmm1, [f_low]
    movss xmm0, [p_dx]
    divss xmm0, xmm1
    mulss xmm0, [f_pknock]
    movss [knock_x], xmm0
    movss xmm0, [p_dz]
    divss xmm0, xmm1
    mulss xmm0, [f_pknock]
    movss [knock_z], xmm0
    mov eax, [f_pknockup]
    mov [vel + 4], eax
.out:
    add rsp, 8
    ret

; what a dead mob rbx leaves: its drop, 0..most (animals at least 1);
; a zombie sometimes (1 in 8) a carrot as well
mob_drops:
    push r12
    movss xmm0, [rbx + MB_AGE]
    comiss xmm0, [f_zero]
    jb .out                         ; babies drop nothing
    cmp dword [rbx + MB_TYPE], MOB_ZOMBIE
    jne .main
    call rand
    test eax, 0x70000
    jnz .main
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_half]
    movss xmm2, [rbx + MB_Z]
    xorps xmm3, xmm3
    movss xmm4, [f_two]
    xorps xmm5, xmm5
    mov edi, I_CARROT | (1 << 8)
    call ent_spawn
.main:
    ; a cow also leaves 0-2 leather
    cmp dword [rbx + MB_TYPE], MOB_COW
    jne .wool
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 3
    div ecx
    test edx, edx
    jz .wool
    lea edi, [rdx*8]
    shl edi, 5                      ; count << 8
    or edi, I_LEATHER
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_half]
    movss xmm2, [rbx + MB_Z]
    xorps xmm3, xmm3
    movss xmm4, [f_two]
    xorps xmm5, xmm5
    call ent_spawn
.wool:
    ; a shorn sheep leaves nothing; else wool in its colour
    cmp dword [rbx + MB_TYPE], MOB_SHEEP
    jne .type
    movss xmm0, [rbx + MB_BURN]
    comiss xmm0, [f_zero]
    ja .out
.type:
    cmp dword [rbx + MB_TYPE], MOB_WITHER
    jne .typed
    cmp dword [rbx + MB_COLOR], 0
    je .out                         ; not killed with an iron sword: nothing
.typed:
    TYPEREC
    movzx r12d, byte [rax + TY_DROP]
    cmp dword [rbx + MB_TYPE], MOB_SHEEP
    jne .drop
    add r12d, [rbx + MB_COLOR]
.drop:
    movzx ecx, byte [rax + TY_DROPMAX]
    inc ecx
    push rcx
    call rand
    pop rcx
    shr eax, 8
    xor edx, edx
    div ecx                         ; edx = 0 .. most
    cmp dword [rbx + MB_TYPE], MOB_ZOMBIE
    je .count
    test edx, edx
    jnz .count
    mov edx, 1
.count:
    test edx, edx
    jz .out
    shl edx, 8
    or r12d, edx
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_half]
    movss xmm2, [rbx + MB_Z]
    xorps xmm3, xmm3
    movss xmm4, [f_two]
    xorps xmm5, xmm5
    mov edi, r12d
    call ent_spawn
.out:
    pop r12
    ret

; block flags at (xmm0, xmm1, xmm2) -> eax
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

; eax = sky light at mob rbx's head
head_sky:
    sub rsp, 8
    movss xmm0, [rbx + MB_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + MB_Y]
    addss xmm0, [f_head]
    FLOORF esi, xmm0
    movss xmm0, [rbx + MB_Z]
    FLOORF edx, xmm0
    call light_get
    and eax, 15
    add rsp, 8
    ret

; eax = 1 if mob rbx going where it wants would step into water or off a
; ledge (more than one node down): it looks at the ground ahead of its
; middle and of both front corners. A mob already in water may go anywhere.
; locals: [0] dir x, [4] dir z, [8] half width, [12] probe
water_ahead:
    push r12
    sub rsp, 32
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_lift]
    movss xmm2, [rbx + MB_Z]
    call flags_at
    test eax, F_LIQUID
    jnz .no
    movss xmm0, [rbx + MB_WX]
    movss xmm1, [rbx + MB_WZ]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    comiss xmm2, [f_edge]
    jbe .no
    divss xmm0, xmm2
    movss [rsp], xmm0
    divss xmm1, xmm2
    movss [rsp + 4], xmm1
    TYPEREC
    movss xmm0, [rax + TY_HALF]
    movss [rsp + 8], xmm0
    mov r12d, -1                    ; side: -1, 0, +1
.side:
    ; probe = position + dir * 0.9 + side * half * (-dir z, dir x)
    cvtsi2ss xmm3, r12d
    mulss xmm3, [rsp + 8]
    movss xmm0, [rsp]
    mulss xmm0, [f_ahead]
    addss xmm0, [rbx + MB_X]
    movss xmm4, [rsp + 4]
    mulss xmm4, xmm3
    subss xmm0, xmm4
    movss xmm2, [rsp + 4]
    mulss xmm2, [f_ahead]
    addss xmm2, [rbx + MB_Z]
    movss xmm4, [rsp]
    mulss xmm4, xmm3
    addss xmm2, xmm4
    call probe_unsafe
    test eax, eax
    jnz .yes
    inc r12d
    cmp r12d, 1
    jle .side
.no:
    xor eax, eax
    add rsp, 32
    pop r12
    ret
.yes:
    mov eax, 1
    add rsp, 32
    pop r12
    ret

; eax = 1 if stepping onto column (xmm0, xmm2) from mob rbx's height is
; unsafe: water at its feet or below, or the ground more than one node down
; (or not within 4); a wall at its feet is for the physics (it jumps)
; locals: [0] x, [4] z, [8] node below
probe_unsafe:
    push r12
    sub rsp, 16
    movss [rsp], xmm0
    movss [rsp + 4], xmm2
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_lift]
    call flags_at
    test eax, F_LIQUID
    jnz .bad
    test eax, F_SOLID
    jnz .good
    mov r12d, 1                     ; nodes down from the feet
.down:
    movss xmm0, [rsp]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_lift]
    cvtsi2ss xmm3, r12d
    subss xmm1, xmm3
    movss xmm2, [rsp + 4]
    call flags_at
    test eax, F_LIQUID
    jnz .bad
    test eax, F_SOLID
    jnz .ground
    inc r12d
    cmp r12d, 4
    jbe .down
.bad:
    mov eax, 1
    add rsp, 16
    pop r12
    ret
.ground:
    cmp r12d, 2                     ; same level, or one node down
    ja .bad
.good:
    xor eax, eax
    add rsp, 16
    pop r12
    ret

; eax = 1 if mob rbx could stand one node up, half a node ahead of it
step_clear:
    sub rsp, 8
    movss xmm0, [rbx + MB_WX]
    movss xmm2, [rbx + MB_WZ]
    movaps xmm3, xmm0
    mulss xmm3, xmm3
    movaps xmm4, xmm2
    mulss xmm4, xmm4
    addss xmm3, xmm4
    sqrtss xmm3, xmm3
    xor eax, eax
    comiss xmm3, [f_edge]
    jbe .out
    divss xmm0, xmm3
    mulss xmm0, [f_step]
    addss xmm0, [rbx + MB_X]
    divss xmm2, xmm3
    mulss xmm2, [f_step]
    addss xmm2, [rbx + MB_Z]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_up1]
    call mob_free
.out:
    add rsp, 8
    ret

; mobs do not stand inside each other: every touching pair is pushed
; apart along the line between them, each half the overlap, never into a
; wall. locals: [0] push x, [4] push z, [8] new x, [12] new z
mob_separate:
    ENTER_FN 16
    xor r12d, r12d                  ; i
.i:
    mov eax, r12d
    inc eax
    cmp eax, [mob_count]
    jae .out
    mov r13d, eax                   ; j
.j:
    cmp r13d, [mob_count]
    jae .inext
    imul eax, r12d, MB_SIZE
    lea r14, [mobs]
    add r14, rax
    imul eax, r13d, MB_SIZE
    lea r15, [mobs]
    add r15, rax
    movss xmm0, [r15 + MB_Y]
    subss xmm0, [r14 + MB_Y]
    andps xmm0, [f_absmask]
    comiss xmm0, [f_tall]
    jae .jnext
    ; touching distance: the two half widths
    mov rbx, r14
    TYPEREC
    movss xmm5, [rax + TY_HALF]
    mov rbx, r15
    TYPEREC
    addss xmm5, [rax + TY_HALF]
    movss xmm0, [r15 + MB_X]
    subss xmm0, [r14 + MB_X]
    movss xmm1, [r15 + MB_Z]
    subss xmm1, [r14 + MB_Z]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    addss xmm2, xmm3
    movaps xmm3, xmm5
    mulss xmm3, xmm3
    comiss xmm2, xmm3
    jae .jnext
    sqrtss xmm2, xmm2
    comiss xmm2, [f_edge]
    ja .apart
    movss xmm0, [f_one]             ; on top of each other: push along x
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm4, xmm4
    jmp .dir
.apart:
    movaps xmm4, xmm2
.dir:
    subss xmm5, xmm4                ; overlap
    mulss xmm5, [f_half]
    divss xmm0, xmm2
    mulss xmm0, xmm5
    movss [rsp], xmm0
    divss xmm1, xmm2
    mulss xmm1, xmm5
    movss [rsp + 4], xmm1
    ; j moves away from i
    mov rbx, r15
    movss xmm0, [rbx + MB_X]
    addss xmm0, [rsp]
    movss [rsp + 8], xmm0
    movss xmm2, [rbx + MB_Z]
    addss xmm2, [rsp + 4]
    movss [rsp + 12], xmm2
    movss xmm1, [rbx + MB_Y]
    call mob_free
    test eax, eax
    jz .moved_j
    movss xmm0, [rsp + 8]
    movss [rbx + MB_X], xmm0
    movss xmm0, [rsp + 12]
    movss [rbx + MB_Z], xmm0
.moved_j:
    ; and i away from j
    mov rbx, r14
    movss xmm0, [rbx + MB_X]
    subss xmm0, [rsp]
    movss [rsp + 8], xmm0
    movss xmm2, [rbx + MB_Z]
    subss xmm2, [rsp + 4]
    movss [rsp + 12], xmm2
    movss xmm1, [rbx + MB_Y]
    call mob_free
    test eax, eax
    jz .jnext
    movss xmm0, [rsp + 8]
    movss [rbx + MB_X], xmm0
    movss xmm0, [rsp + 12]
    movss [rbx + MB_Z], xmm0
.jnext:
    inc r13d
    jmp .j
.inext:
    inc r12d
    jmp .i
.out:
    LEAVE_FN

; eax = 1 if a fence or gate is right in front of mob rbx
fence_ahead:
    sub rsp, 8
    TYPEREC
    movss xmm3, [rax + TY_HALF]
    addss xmm3, [f_fenceh]
    movss xmm0, [rbx + MB_WX]
    movss xmm1, [rbx + MB_WZ]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm4, xmm1
    mulss xmm4, xmm4
    addss xmm2, xmm4
    sqrtss xmm2, xmm2
    xor eax, eax
    comiss xmm2, [f_edge]
    jbe .out
    divss xmm0, xmm2
    mulss xmm0, xmm3
    addss xmm0, [rbx + MB_X]
    divss xmm1, xmm2
    mulss xmm1, xmm3
    movaps xmm2, xmm1
    addss xmm2, [rbx + MB_Z]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_half]
    call flags_at
    and eax, F_FENCE
.out:
    add rsp, 8
    ret

; look up to 12 times for a shaded floor within 10 nodes of zombie rbx
; (sky light at head height below 15) and make it its target
; locals: [0] tries
find_shade:
    ENTER_FN 16
    mov dword [rsp], 12
.try:
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 21
    div ecx
    lea r12d, [rdx - 10]
    movss xmm0, [rbx + MB_X]
    FLOORF eax, xmm0
    add r12d, eax                   ; x
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 21
    div ecx
    lea r13d, [rdx - 10]
    movss xmm0, [rbx + MB_Z]
    FLOORF eax, xmm0
    add r13d, eax                   ; z
    movss xmm0, [rbx + MB_Y]
    FLOORF r14d, xmm0
    lea r15d, [r14 + 3]
    sub r14d, 4
.y:
    cmp r15d, r14d
    jl .next
    mov edi, r12d
    mov esi, r15d
    mov edx, r13d
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID
    jz .down
%macro FREEAT 1                     ; to .down unless y + %1 is open air
    mov edi, r12d
    lea esi, [r15 + %1]
    mov edx, r13d
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID | F_LIQUID
    jnz .down
%endmacro
    FREEAT 1
    FREEAT 2
    mov edi, r12d
    lea esi, [r15 + 2]
    mov edx, r13d
    call light_get
    and eax, 15
    cmp eax, 15
    jb .found
    jmp .next
.down:
    dec r15d
    jmp .y
.next:
    dec dword [rsp]
    jnz .try
    LEAVE_FN
.found:
    cvtsi2ss xmm0, r12d
    addss xmm0, [f_half]
    movss [rbx + MB_TX], xmm0
    cvtsi2ss xmm0, r13d
    addss xmm0, [f_half]
    movss [rbx + MB_TZ], xmm0
    mov dword [rbx + MB_HASTGT], 1
    LEAVE_FN

; find_mate - mob rbx (in love) walks to the nearest grown mob of its
; kind also in love within 8 nodes; when they meet, a baby is born
; between them and both rest. eax = 1 if it has a partner.
find_mate:
    push r12
    push r13
    sub rsp, 24
    mov r13d, -1                    ; best
    movss xmm7, [f_mate2]           ; its distance^2
    xor r12d, r12d
.m:
    cmp r12d, [mob_count]
    jae .picked
    mov eax, r12d
    imul eax, eax, MB_SIZE
    lea rcx, [mobs]
    add rcx, rax
    cmp rcx, rbx
    je .next
    mov eax, [rcx + MB_TYPE]
    cmp eax, [rbx + MB_TYPE]
    jne .next
    movss xmm0, [rcx + MB_LOVE]
    comiss xmm0, [f_zero]
    jbe .next
    movss xmm0, [rcx + MB_AGE]
    comiss xmm0, [f_zero]
    jb .next
    movss xmm0, [rcx + MB_X]
    subss xmm0, [rbx + MB_X]
    mulss xmm0, xmm0
    movss xmm1, [rcx + MB_Z]
    subss xmm1, [rbx + MB_Z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, xmm7
    jae .next
    movaps xmm7, xmm0
    mov r13d, r12d
.next:
    inc r12d
    jmp .m
.picked:
    xor eax, eax
    test r13d, r13d
    js .out
    mov eax, r13d
    imul eax, eax, MB_SIZE
    lea r12, [mobs]
    add r12, rax                    ; the partner
    comiss xmm7, [f_meet2]
    jb .born
    ; walk to it
    sqrtss xmm7, xmm7
    TYPEREC
    movss xmm3, [rax + TY_SPEED]
    movss xmm0, [r12 + MB_X]
    subss xmm0, [rbx + MB_X]
    divss xmm0, xmm7
    mulss xmm0, xmm3
    movss [rbx + MB_WX], xmm0
    movss xmm0, [r12 + MB_Z]
    subss xmm0, [rbx + MB_Z]
    divss xmm0, xmm7
    mulss xmm0, xmm3
    movss [rbx + MB_WZ], xmm0
    mov eax, 1
    jmp .out
.born:
    ; a baby between them; both rest a while
    mov dword [rbx + MB_LOVE], 0
    mov dword [r12 + MB_LOVE], 0
    mov eax, [f_breedcd]
    mov [rbx + MB_BREEDCD], eax
    mov [r12 + MB_BREEDCD], eax
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    movss xmm0, [rbx + MB_X]
    addss xmm0, [r12 + MB_X]
    mulss xmm0, [f_half]
    movss xmm1, [rbx + MB_Y]
    maxss xmm1, [r12 + MB_Y]
    movss xmm2, [rbx + MB_Z]
    addss xmm2, [r12 + MB_Z]
    mulss xmm2, [f_half]
    mov edi, [rbx + MB_TYPE]
    call mob_spawn
    test eax, eax
    js .full
    imul eax, eax, MB_SIZE
    lea rcx, [mobs]
    mov edx, [f_babyage]
    mov [rcx + rax + MB_AGE], edx
.full:
    mov eax, 1
.out:
    add rsp, 24
    pop r13
    pop r12
    ret

; one slab of the box test: box from xmm0 to xmm1 along an axis
%macro SLAB 2                       ; eye offset, direction offset
    movss xmm2, [rsp + %2]
    movaps xmm3, xmm2
    andps xmm3, [f_absmask]
    comiss xmm3, [f_tiny]
    ja %%div
    movss xmm3, [rsp + %1]
    comiss xmm3, xmm0
    jb .miss
    comiss xmm3, xmm1
    ja .miss
    jmp %%done
%%div:
    subss xmm0, [rsp + %1]
    divss xmm0, xmm2
    subss xmm1, [rsp + %1]
    divss xmm1, xmm2
    movaps xmm3, xmm0
    minss xmm0, xmm1
    maxss xmm1, xmm3
    maxss xmm6, xmm0
    minss xmm7, xmm1
    comiss xmm6, xmm7
    ja .miss
%%done:
%endmacro

; eax = index of the mob in the player's view ray within reach (before
; any block in the way), or -1; the ray direction is left in ray_dir
mob_pick:
    movss xmm0, [f_reach]
    mov eax, 1                      ; and no further than the block looked at
    jmp mob_ray_go
; int mob_ray(float reach) - the nearest mob in the view within reach
mob_ray:
    xor eax, eax
mob_ray_go:
    ENTER_FN 48
    movss [rsp + 40], xmm0
    mov [rsp + 44], eax
    fld dword [pitch]
    fsincos
    fstp dword [rsp]
    fstp dword [rsp + 4]
    movss xmm0, [syaw]
    mulss xmm0, [rsp]
    movss [rsp + 8], xmm0
    movss [ray_dir], xmm0
    xorps xmm0, xmm0
    subss xmm0, [rsp + 4]
    movss [rsp + 12], xmm0
    movss xmm1, [cyaw]
    mulss xmm1, [rsp]
    xorps xmm0, xmm0
    subss xmm0, xmm1
    movss [rsp + 16], xmm0
    movss [ray_dir + 4], xmm0
    movss xmm0, [pos]
    movss [rsp + 20], xmm0
    movss xmm0, [pos + 4]
    addss xmm0, [f_eye]
    movss [rsp + 24], xmm0
    movss xmm0, [pos + 8]
    movss [rsp + 28], xmm0
    ; a block in the way limits the reach (distance to its centre - 0.5)
    movss xmm0, [rsp + 40]
    cmp dword [rsp + 44], 0
    je .reach
    cmp dword [target_hit], 0
    je .reach
    cvtsi2ss xmm1, dword [target]
    addss xmm1, [f_half]
    subss xmm1, [rsp + 20]
    mulss xmm1, xmm1
    cvtsi2ss xmm2, dword [target + 4]
    addss xmm2, [f_half]
    subss xmm2, [rsp + 24]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    cvtsi2ss xmm2, dword [target + 8]
    addss xmm2, [f_half]
    subss xmm2, [rsp + 28]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    sqrtss xmm1, xmm1
    subss xmm1, [f_half]
    minss xmm0, xmm1
.reach:
    movss [rsp + 32], xmm0
    mov dword [rsp + 36], -1
    xor r12d, r12d
.m:
    cmp r12d, [mob_count]
    jae .picked
    mov eax, r12d
    imul eax, eax, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    TYPEREC
    mov r13, rax
    xorps xmm6, xmm6
    movss xmm7, [rsp + 32]
    movss xmm0, [rbx + MB_X]
    subss xmm0, [r13 + TY_HALF]
    movss xmm1, [rbx + MB_X]
    addss xmm1, [r13 + TY_HALF]
    SLAB 20, 8
    movss xmm0, [rbx + MB_Y]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [r13 + TY_HEIGHT]
    SLAB 24, 12
    movss xmm0, [rbx + MB_Z]
    subss xmm0, [r13 + TY_HALF]
    movss xmm1, [rbx + MB_Z]
    addss xmm1, [r13 + TY_HALF]
    SLAB 28, 16
    movss [rsp + 32], xmm6
    mov [rsp + 36], r12d
.miss:
    inc r12d
    jmp .m
.picked:
    mov eax, [rsp + 36]
    LEAVE_FN

; int mob_feed(void) - right click on a mob with:
;   wheat (cows, sheep) or a carrot (pigs): a grown one falls in love
;     (unless it bred lately), a baby grows up sooner
;   shears on a sheep with wool: 1-3 wool of its colour; it grows back
;   a dye on a sheep: its wool takes that colour
; One item is used up in survival (not shears). 1 if something happened.
mob_feed:
    ENTER_FN 16
    mov eax, [sel_slot]
    lea rcx, [inv]
    movzx r12d, byte [rcx + rax*4]
    cmp r12d, I_SHEARS
    je .shear
    lea eax, [r12 - I_DYE]
    cmp eax, 15
    jbe .dye
    cmp r12d, I_WHEAT
    je .food
    cmp r12d, I_CARROT
    jne .no
.food:
    call mob_pick
    test eax, eax
    js .no
    imul eax, eax, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    mov eax, [rbx + MB_TYPE]
    cmp r12d, I_CARROT
    je .pigfood
    cmp eax, MOB_COW
    je .eats
    cmp eax, MOB_SHEEP
    je .eats
    jmp .no
.pigfood:
    cmp eax, MOB_PIG
    jne .no
.eats:
    movss xmm0, [rbx + MB_AGE]
    comiss xmm0, [f_zero]
    jae .adult
    addss xmm0, [f_feedgrow]
    minss xmm0, [f_zero]
    movss [rbx + MB_AGE], xmm0
    jmp .used
.adult:
    movss xmm0, [rbx + MB_LOVE]
    comiss xmm0, [f_zero]
    ja .no
    movss xmm0, [rbx + MB_BREEDCD]
    comiss xmm0, [f_zero]
    ja .no
    mov eax, [f_lovet]
    mov [rbx + MB_LOVE], eax
.used:
    cmp dword [game_mode], 0
    jne .fed
    mov eax, [sel_slot]
    lea rcx, [inv]
    lea rcx, [rcx + rax*4]
    dec byte [rcx + 1]
    jnz .fed
    mov dword [rcx], 0
.fed:
    mov eax, 1
    LEAVE_FN
.shear:
    call sheep_picked
    test eax, eax
    jz .no
    movss xmm0, [rbx + MB_BURN]
    comiss xmm0, [f_zero]
    ja .no                          ; already shorn
    movss xmm0, [rbx + MB_AGE]
    comiss xmm0, [f_zero]
    jb .no                          ; lambs keep their wool
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 3
    div ecx
    lea edi, [rdx + 1]              ; 1-3 wool
    shl edi, 8
    add edi, B_WOOL
    add edi, [rbx + MB_COLOR]
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    addss xmm1, [f_one]
    movss xmm2, [rbx + MB_Z]
    xorps xmm3, xmm3
    movss xmm4, [f_two]
    xorps xmm5, xmm5
    call ent_spawn
    call rand                       ; grows back in 60-120 s
    shr eax, 8
    xor edx, edx
    mov ecx, 61
    div ecx
    add edx, 60
    cvtsi2ss xmm0, edx
    movss [rbx + MB_BURN], xmm0
    mov eax, 1
    LEAVE_FN
.dye:
    call sheep_picked
    test eax, eax
    jz .no
    lea eax, [r12 - I_DYE]
    cmp eax, [rbx + MB_COLOR]
    je .no                          ; already that colour
    mov [rbx + MB_COLOR], eax
    jmp .used
.no:
    xor eax, eax
    LEAVE_FN

; eax = 1 with rbx = the sheep in the view ray, else 0
sheep_picked:
    sub rsp, 8
    call mob_pick
    test eax, eax
    js .none
    imul eax, eax, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    xor eax, eax
    cmp dword [rbx + MB_TYPE], MOB_SHEEP
    jne .out
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    add rsp, 8
    ret

; eax = 0 when mob rbx is gone (dead or too far), 1 to keep it
; locals: [0] speed, [4] angle, [8] cos, [12] sin
mob_think:
    ENTER_FN 32
    movss xmm0, [pos]
    subss xmm0, [rbx + MB_X]
    movss [p_dx], xmm0
    movss xmm1, [pos + 8]
    subss xmm1, [rbx + MB_Z]
    movss [p_dz], xmm1
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss [p_dist], xmm0
    comiss xmm0, [f_despawn]
    ja .gone
%macro COUNTDOWN 1
    movss xmm0, [rbx + %1]
    subss xmm0, [dt]
    maxss xmm0, [f_zero]
    movss [rbx + %1], xmm0
%endmacro
    COUNTDOWN MB_HURT
    COUNTDOWN MB_FLEE
    TYPEREC
    movss xmm0, [rax + TY_SPEED]
    movss [rsp], xmm0
    mov eax, [rbx + MB_TYPE]
    cmp eax, MOB_GHAST
    je .ghast
    lea ecx, [rax - MOB_SLIME_L]
    cmp ecx, MOB_SLIME_S - MOB_SLIME_L
    jbe .slime
    cmp eax, MOB_ZOMBIE
    je .hostile
    cmp eax, MOB_GIANT
    je .hostile
    cmp eax, MOB_WITHER
    jne .animal
.hostile:
    ; just hit: stagger back instead of walking on
    movss xmm0, [rbx + MB_HURT]
    comiss xmm0, [f_zero]
    ja .stagger
    ; creative players are left alone
    cmp dword [game_mode], 0
    jne .zday
    movss xmm0, [p_dist]
    comiss xmm0, [f_chase]
    ja .zday
    ; walk straight at the player, stopping 1 node short (no overshooting
    ; back and forth)
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    comiss xmm0, [f_stop2]
    jbe .bite
    sqrtss xmm1, xmm0
    maxss xmm1, [f_low]
    movss xmm2, [p_dx]
    divss xmm2, xmm1
    mulss xmm2, [rsp]
    movss [rbx + MB_WX], xmm2
    movss xmm2, [p_dz]
    divss xmm2, xmm1
    mulss xmm2, [rsp]
    movss [rbx + MB_WZ], xmm2
.bite:
    call zombie_attack
    jmp .move_direct                ; a chase ignores the sun and water
.stagger:
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    jmp .move_direct
.zday:
    ; by day a zombie under the open sky walks to shade and stays there
    cmp dword [rbx + MB_TYPE], MOB_WITHER
    je .night                       ; (no sun in the nether)
    movss xmm0, [sunlight]
    comiss xmm0, [f_sunburn]
    jbe .night
    call head_sky
    cmp eax, 15
    je .sunny
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    mov dword [rbx + MB_HASTGT], 0
    jmp .move_direct
.sunny:
    cmp dword [rbx + MB_HASTGT], 0
    jne .toshade
    call find_shade
    cmp dword [rbx + MB_HASTGT], 0
    je .wander
.toshade:
    movss xmm2, [rbx + MB_TX]
    subss xmm2, [rbx + MB_X]
    movss xmm3, [rbx + MB_TZ]
    subss xmm3, [rbx + MB_Z]
    movaps xmm0, xmm2
    mulss xmm0, xmm0
    movaps xmm1, xmm3
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [f_arrive]
    ja .goshade
    mov dword [rbx + MB_HASTGT], 0  ; there but still sunny: look again
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    jmp .move_direct
.goshade:
    sqrtss xmm1, xmm0
    divss xmm2, xmm1
    mulss xmm2, [rsp]
    movss [rbx + MB_WX], xmm2
    divss xmm3, xmm1
    mulss xmm3, [rsp]
    movss [rbx + MB_WZ], xmm3
    jmp .move
.night:
    mov dword [rbx + MB_HASTGT], 0
    jmp .wander
.slime:
    ; sit a moment, then hop a random way; in the air it keeps going
    cmp dword [rbx + MB_GROUND], 0
    je .move_direct
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    movss xmm0, [rbx + MB_TIMER]
    subss xmm0, [dt]
    movss [rbx + MB_TIMER], xmm0
    comiss xmm0, [f_zero]
    ja .move_direct
    call randf
    mulss xmm0, [f_hopwait]
    addss xmm0, [f_hopmin]
    movss [rbx + MB_TIMER], xmm0
    call randf
    mulss xmm0, [f_2pi]
    movss [rsp + 4], xmm0
    fld dword [rsp + 4]
    fsincos
    fstp dword [rsp + 8]
    fstp dword [rsp + 12]
    movss xmm0, [rsp + 12]
    mulss xmm0, [rsp]
    movss [rbx + MB_WX], xmm0
    movss xmm0, [rsp + 8]
    mulss xmm0, [rsp]
    movss [rbx + MB_WZ], xmm0
    mov eax, [f_hop]
    mov [rbx + MB_VY], eax
    mov dword [rbx + MB_GROUND], 0
    jmp .move_direct

.ghast:
    call ghast_think
    jmp .notlava                    ; (fire and lava do not hurt it)

.animal:
    ; babies grow up
    movss xmm0, [rbx + MB_AGE]
    comiss xmm0, [f_zero]
    jae .grown
    addss xmm0, [dt]
    minss xmm0, [f_zero]
    movss [rbx + MB_AGE], xmm0
.grown:
    COUNTDOWN MB_BREEDCD
    COUNTDOWN MB_LOVE
    COUNTDOWN MB_BURN               ; a shorn sheep's wool grows back
    mov dword [rbx + MB_LURED], 0
    movss xmm0, [rbx + MB_FLEE]
    comiss xmm0, [f_zero]
    ja .flee
    ; in love: walk to a partner in love nearby; meeting makes a baby
    movss xmm0, [rbx + MB_LOVE]
    comiss xmm0, [f_zero]
    jbe .nolove
    call find_mate
    test eax, eax
    jnz .move_direct
.nolove:
    ; the player holding its favourite food (pig: carrot, cow: wheat)
    ; within 10 nodes: it follows, even into water
    mov eax, [sel_slot]
    lea rcx, [inv]
    movzx eax, byte [rcx + rax*4]
    mov ecx, I_CARROT
    cmp dword [rbx + MB_TYPE], MOB_PIG
    je .lureitem
    mov ecx, I_WHEAT
.lureitem:
    cmp eax, ecx
    jne .wander
    movss xmm0, [p_dist]
    comiss xmm0, [f_lure2]
    ja .wander
    mov dword [rbx + MB_LURED], 1
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    comiss xmm0, [f_near2]
    jbe .move_direct
    sqrtss xmm1, xmm0
    movss xmm2, [p_dx]
    divss xmm2, xmm1
    mulss xmm2, [rsp]
    movss [rbx + MB_WX], xmm2
    movss xmm2, [p_dz]
    divss xmm2, xmm1
    mulss xmm2, [rsp]
    movss [rbx + MB_WZ], xmm2
    jmp .move_direct
.flee:
    ; hurt: run from the player
    movss xmm0, [p_dist]
    sqrtss xmm1, xmm0
    maxss xmm1, [f_low]
    movss xmm3, [rsp]
    mulss xmm3, [f_flee]
    xorps xmm2, xmm2
    subss xmm2, [p_dx]
    divss xmm2, xmm1
    mulss xmm2, xmm3
    movss [rbx + MB_WX], xmm2
    xorps xmm2, xmm2
    subss xmm2, [p_dz]
    divss xmm2, xmm1
    mulss xmm2, xmm3
    movss [rbx + MB_WZ], xmm2
    jmp .move
.wander:
    movss xmm0, [rbx + MB_TIMER]
    subss xmm0, [dt]
    movss [rbx + MB_TIMER], xmm0
    comiss xmm0, [f_zero]
    ja .move
    ; decide again in 2..4 s: stand a quarter of the time, else walk
    call randf
    mulss xmm0, [f_two]
    addss xmm0, [f_two]
    movss [rbx + MB_TIMER], xmm0
    call rand
    test eax, 0x30000
    jnz .walkdir
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    jmp .move
.walkdir:
    call randf
    mulss xmm0, [f_2pi]
    movss [rsp + 4], xmm0
    fld dword [rsp + 4]
    fsincos
    fstp dword [rsp + 8]
    fstp dword [rsp + 12]
    movss xmm0, [rsp + 12]
    mulss xmm0, [rsp]
    movss [rbx + MB_WX], xmm0
    movss xmm0, [rsp + 8]
    mulss xmm0, [rsp]
    movss [rbx + MB_WZ], xmm0
.move:
    ; never walk into water or off a ledge: stop, decide again
    call water_ahead
    test eax, eax
    jz .move_direct
    mov dword [rbx + MB_WX], 0
    mov dword [rbx + MB_WZ], 0
    mov eax, [f_pause]              ; stand a moment, then decide again
    mov [rbx + MB_TIMER], eax
    mov dword [rbx + MB_HASTGT], 0
.move_direct:
    call mob_physics
    ; zombies burn under the open sky by day
    cmp dword [rbx + MB_TYPE], MOB_ZOMBIE
    jne .alive
    movss xmm0, [sunlight]
    comiss xmm0, [f_sunburn]
    jbe .alive
    movss xmm0, [rbx + MB_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + MB_Y]
    addss xmm0, [f_head]
    FLOORF esi, xmm0
    movss xmm0, [rbx + MB_Z]
    FLOORF edx, xmm0
    call light_get
    and eax, 15
    cmp eax, 15
    jne .alive
    movss xmm0, [rbx + MB_BURN]
    addss xmm0, [dt]
    movss [rbx + MB_BURN], xmm0
    comiss xmm0, [f_one]
    jb .alive
    subss xmm0, [f_one]
    movss [rbx + MB_BURN], xmm0
    sub dword [rbx + MB_HP], 2
    mov eax, [f_hurtt]
    mov [rbx + MB_HURT], eax
.alive:
    ; in lava: about 8 damage a second
    movss xmm0, [rbx + MB_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + MB_Y]
    addss xmm0, [f_lift]
    FLOORF esi, xmm0
    movss xmm0, [rbx + MB_Z]
    FLOORF edx, xmm0
    call world_get
    cmp eax, B_FIRE
    je .burning
    lea ecx, [rax - B_LAVA]
    cmp ecx, B_LFLOW3 - B_LAVA
    ja .notlava
.burning:
    call randf
    movss xmm1, [dt]
    mulss xmm1, [f_lavarate]
    comiss xmm0, xmm1
    jae .notlava
    dec dword [rbx + MB_HP]
    mov eax, [f_hurtt]
    mov [rbx + MB_HURT], eax
.notlava:
    cmp dword [rbx + MB_HP], 0
    jg .keep
    call slime_split
    call mob_drops
.gone:
    xor eax, eax
    LEAVE_FN
.keep:
    mov eax, 1
    LEAVE_FN

; try to start one mob of kind edi (0 animal, 1 zombie) somewhere 16..40
; nodes from the player, on the highest free floor in that column within
; 16 above to 24 below the player's feet
; locals: [0] angle, [4] cos, [8] sin, [12] lowest y
spawn_try:
    ENTER_FN 32
    mov r14d, edi
    call randf
    mulss xmm0, [f_2pi]
    movss [rsp], xmm0
    fld dword [rsp]
    fsincos
    fstp dword [rsp + 4]
    fstp dword [rsp + 8]
    call randf
    mulss xmm0, [f_spawnrng]
    addss xmm0, [f_spawnmin]
    movaps xmm1, xmm0
    mulss xmm0, [rsp + 8]
    addss xmm0, [pos]
    FLOORF r12d, xmm0               ; x
    mulss xmm1, [rsp + 4]
    addss xmm1, [pos + 8]
    FLOORF r13d, xmm1               ; z
    movss xmm0, [pos + 4]
    FLOORF r15d, xmm0
    lea eax, [r15 - 24]
    mov [rsp + 12], eax
    add r15d, 16
.y:
    cmp r15d, [rsp + 12]
    jl .out
    mov edi, r12d
    mov esi, r15d
    mov edx, r13d
    call world_get
    cmp eax, B_UNKNOWN
    je .out                         ; not loaded
    mov ebx, eax
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID
    jz .next
%macro AIRAT 1                      ; jump to .next unless y + %1 is open air
    mov edi, r12d
    lea esi, [r15 + %1]
    mov edx, r13d
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID | F_LIQUID
    jnz .next
%endmacro
    AIRAT 1
    AIRAT 2
    jmp .found
.next:
    dec r15d
    jmp .y
.found:
    mov edi, r12d
    lea esi, [r15 + 1]
    mov edx, r13d
    call light_get
    mov ecx, eax
    and eax, 15                     ; sky
    shr ecx, 4                      ; block
    test r14d, r14d
    jnz .zombie
    ; animals: grassy ground under the sky
    cmp ebx, B_GRASS
    je .grassy
    cmp ebx, B_SNOWDIRT
    je .grassy
    cmp ebx, B_DRYGRASS
    jne .out
.grassy:
    cmp eax, 9
    jb .out
    ; a pig, a cow or a sheep, a third each
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 3
    div ecx
    mov edi, MOB_PIG
    test edx, edx
    jz .put
    mov edi, MOB_COW
    cmp edx, 1
    je .put
    mov edi, MOB_SHEEP
    jmp .put
.zombie:
    ; dark: block light and daylit sky light both 7 or less
    cmp ecx, 7
    ja .out
    cvtsi2ss xmm0, eax
    mulss xmm0, [sunlight]
    cvttss2si eax, xmm0
    cmp eax, 7
    ja .out
    mov edi, MOB_ZOMBIE
    cmp dword [dimension], 0
    je .put
    mov edi, MOB_WITHER             ; the nether has its own
.put:
    cvtsi2ss xmm0, r12d
    addss xmm0, [f_half]
    lea eax, [r15 + 1]
    cvtsi2ss xmm1, eax
    cvtsi2ss xmm2, r13d
    addss xmm2, [f_half]
    call mob_spawn
.out:
    LEAVE_FN

; void mob_update(void) - spawn, move, fight, despawn
mob_update:
    ENTER_FN 16
    movss xmm0, [spawn_t]
    addss xmm0, [dt]
    movss [spawn_t], xmm0
    comiss xmm0, [f_spawn_t]
    jb .mobs
    mov dword [spawn_t], 0
    cmp dword [mob_spawning], 0
    je .mobs
    ; how many of each there are
    xor r12d, r12d                  ; animals
    xor r13d, r13d                  ; zombies
    xor ecx, ecx
.cnt:
    cmp ecx, [mob_count]
    jae .counted
    mov eax, ecx
    imul eax, eax, MB_SIZE
    lea rdx, [mobs]
    cmp dword [rdx + rax + MB_TYPE], MOB_ZOMBIE
    je .cz
    cmp dword [rdx + rax + MB_TYPE], MOB_WITHER
    je .cz
    inc r12d
    jmp .cn
.cz:
    inc r13d
.cn:
    inc ecx
    jmp .cnt
.counted:
    cmp r12d, MAX_ANIMALS
    jae .hostile
    xor edi, edi
    call spawn_try
    xor edi, edi
    call spawn_try
.hostile:
    cmp dword [set_difficulty], 0
    je .mobs
    cmp r13d, MAX_ZOMBIES
    jae .mobs
    mov edi, 1
    call spawn_try
    mov edi, 1
    call spawn_try
.mobs:
    xor r12d, r12d
.m:
    cmp r12d, [mob_count]
    jae .out
    mov eax, r12d
    imul eax, eax, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    ; Peaceful: no zombies or wither skeletons
    cmp dword [rbx + MB_TYPE], MOB_ZOMBIE
    je .peace
    cmp dword [rbx + MB_TYPE], MOB_WITHER
    jne .think
.peace:
    cmp dword [set_difficulty], 0
    je .remove
.think:
    call mob_think
    test eax, eax
    jz .remove
    inc r12d
    jmp .m
.remove:
    ; the last mob takes this place
    mov eax, [mob_count]
    dec eax
    mov [mob_count], eax
    imul eax, eax, MB_SIZE
    lea rcx, [mobs]
    add rcx, rax
    movups xmm0, [rcx]
    movups [rbx], xmm0
    movups xmm0, [rcx + 16]
    movups [rbx + 16], xmm0
    movups xmm0, [rcx + 32]
    movups [rbx + 32], xmm0
    movups xmm0, [rcx + 48]
    movups [rbx + 48], xmm0
    movups xmm0, [rcx + 64]
    movups [rbx + 64], xmm0
    movups xmm0, [rcx + 80]
    movups [rbx + 80], xmm0
    jmp .m
.out:
    call mob_separate
    call fireball_update
    LEAVE_FN

; void mob_blast(float x, y, z) - an explosion there: every mob within 8
; nodes takes (i^2 + i) / 2 x 56 + 1 damage, i = 1 - distance / 8, and is
; thrown away from it (Minecraft's TNT, power 4)
; locals: [0] x, [4] y, [8] z, [12] impact, [16] dx, [20] dz, [24] dist
mob_blast:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    xor r12d, r12d
.m:
    cmp r12d, [mob_count]
    jae .out
    imul eax, r12d, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    TYPEREC
    movss xmm0, [rbx + MB_X]
    subss xmm0, [rsp]
    movss [rsp + 16], xmm0
    movss xmm1, [rax + TY_HEIGHT]
    mulss xmm1, [f_half]
    addss xmm1, [rbx + MB_Y]
    subss xmm1, [rsp + 4]
    movss xmm2, [rbx + MB_Z]
    subss xmm2, [rsp + 8]
    movss [rsp + 20], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp + 24], xmm0
    comiss xmm0, [f_blastr]
    jae .next
    divss xmm0, [f_blastr]
    movss xmm1, [f_one]
    subss xmm1, xmm0                ; impact
    movss [rsp + 12], xmm1
    movaps xmm0, xmm1
    mulss xmm0, xmm1
    addss xmm0, xmm1
    mulss xmm0, [f_blastd]
    cvttss2si eax, xmm0
    inc eax
    sub [rbx + MB_HP], eax
    mov eax, [f_hurtt]
    mov [rbx + MB_HURT], eax
    mov eax, [f_fleet]
    mov [rbx + MB_FLEE], eax
    ; thrown away from the centre
    movss xmm2, [rsp + 24]
    maxss xmm2, [f_low]
    movss xmm3, [rsp + 12]
    mulss xmm3, [f_blastk]
    divss xmm3, xmm2
    movss xmm0, [rsp + 16]
    mulss xmm0, xmm3
    movss [rbx + MB_KX], xmm0
    movss xmm0, [rsp + 20]
    mulss xmm0, xmm3
    movss [rbx + MB_KZ], xmm0
    movss xmm0, [rsp + 12]
    mulss xmm0, [f_blastup]
    movss [rbx + MB_VY], xmm0
    mov dword [rbx + MB_GROUND], 0
.next:
    inc r12d
    jmp .m
.out:
    LEAVE_FN

; int mob_attack(void) - a click: hit the nearest mob in the view ray
; (before any block in the way) with the held item. 1 if one was hit.
mob_attack:
    ENTER_FN 48
    call mob_pick
    mov r12d, eax
    xor eax, eax
    test r12d, r12d
    js .out
    imul eax, r12d, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    ; damage by the held item: sword 3 + tier, axe 2 + tier, pickaxe
    ; 1 + tier, shovel the tier, anything else 1
    mov eax, [sel_slot]
    lea rcx, [inv]
    movzx edi, byte [rcx + rax*4]
    call tool_of                    ; ecx kind, eax tier
    mov r13d, ecx
    ; a wither skeleton remembers if this hit was an iron or diamond sword
    xor edx, edx
    cmp ecx, T_SWORD
    jne .ws
    cmp eax, 3
    setae dl
.ws:
    cmp dword [rbx + MB_TYPE], MOB_WITHER
    jne .notw
    mov [rbx + MB_COLOR], edx
.notw:
    mov edx, 1
    cmp ecx, T_SWORD
    jne .d1
    lea edx, [rax + 3]
.d1:
    cmp ecx, T_AXE
    jne .d2
    lea edx, [rax + 2]
.d2:
    cmp ecx, T_PICK
    jne .d3
    lea edx, [rax + 1]
.d3:
    cmp ecx, T_SHOVEL
    jne .d4
    mov edx, eax
.d4:
    sub [rbx + MB_HP], edx
    mov eax, [f_hurtt]
    mov [rbx + MB_HURT], eax
    ; knocked back along the view, a little up; animals run
    movss xmm0, [ray_dir]
    movss xmm1, [ray_dir + 4]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    maxss xmm2, [f_low]
    divss xmm0, xmm2
    mulss xmm0, [f_knock]
    movss [rbx + MB_KX], xmm0
    divss xmm1, xmm2
    mulss xmm1, [f_knock]
    movss [rbx + MB_KZ], xmm1
    mov eax, [f_knockup]
    mov [rbx + MB_VY], eax
    mov dword [rbx + MB_GROUND], 0
    mov eax, [f_fleet]
    mov [rbx + MB_FLEE], eax
    ; tools wear in survival
    test r13d, r13d
    jz .hit
    cmp dword [game_mode], 0
    jne .hit
    mov edi, [sel_slot]
    call tool_wear
.hit:
    mov eax, 1
.out:
    LEAVE_FN

; void draw_mobs(void) - in node units relative to the player chunk, after
; the dropped items; lit like them, red while hurt
draw_mobs:
    ENTER_FN 16
    cmp dword [mob_count], 0
    je .out
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    xor r12d, r12d
.m:
    cmp r12d, [mob_count]
    jae .done
    mov eax, r12d
    imul eax, eax, MB_SIZE
    lea rbx, [mobs]
    add rbx, rax
    ; brightness from the light where it stands (0..256)
    movss xmm0, [rbx + MB_X]
    FLOORF edi, xmm0
    movss xmm0, [rbx + MB_Y]
    addss xmm0, [f_half]
    FLOORF esi, xmm0
    movss xmm0, [rbx + MB_Z]
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
    cmp dword [dimension], 0
    je .bright
    lea rdx, [light_curve]
    movzx ecx, byte [rdx + NETHER_LIGHT]
    cmp eax, ecx
    cmovl eax, ecx
.bright:
    inc eax                         ; 0..256
    mov [fig_tint], eax
    mov [fig_tint + 4], eax
    mov [fig_tint + 8], eax
    movss xmm0, [rbx + MB_HURT]
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
    movss xmm0, [rbx + MB_X]
    subss xmm0, xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm2, [rbx + MB_Z]
    subss xmm2, xmm1
    movss xmm1, [rbx + MB_Y]
    call glTranslatef PLT
    movss xmm0, [rbx + MB_YAW]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [f_inv16]           ; babies are half size
    movss xmm1, [rbx + MB_AGE]
    comiss xmm1, [f_zero]
    jae .scale
    movss xmm0, [f_inv32]
.scale:
    mov eax, [rbx + MB_TYPE]
    lea rcx, [mob_scale]
    mulss xmm0, [rcx + rax*4]
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    ; slimes stretch going up and squash before a hop
    lea ecx, [rax - MOB_SLIME_L]
    cmp ecx, MOB_SLIME_S - MOB_SLIME_L
    ja .noflex
    cmp dword [rbx + MB_GROUND], 0
    jne .sit
    mulss xmm1, [f_stretch]
    mulss xmm0, [f_thin]
    mulss xmm2, [f_thin]
    jmp .noflex
.sit:
    movss xmm3, [rbx + MB_TIMER]
    comiss xmm3, [f_squasht]
    ja .noflex
    mulss xmm1, [f_squash]
    mulss xmm0, [f_wide]
    mulss xmm2, [f_wide]
.noflex:
    call glScalef PLT
    mov eax, [rbx + MB_TYPE]
    lea rcx, [models]
    mov rdi, [rcx + rax*8]
    lea rcx, [model_n]
    mov esi, [rcx + rax*4]
    call fig_parts
    ; a ghast shooting opens its mouth
    cmp dword [rbx + MB_TYPE], MOB_GHAST
    jne .notghast
    movss xmm0, [rbx + MB_TX]
    comiss xmm0, [f_zero]
    jbe .notghast
    push qword [fig_tint]
    push qword [fig_tint + 8]
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
    lea rdi, [m_ghast_mouth]
    mov esi, 1
    call fig_parts
    pop qword [fig_tint + 8]
    pop qword [fig_tint]
.notghast:
    ; a sheep's fleece, in its wool colour (unless shorn)
    cmp dword [rbx + MB_TYPE], MOB_SHEEP
    jne .notsheep
    movss xmm0, [rbx + MB_BURN]
    comiss xmm0, [f_zero]
    ja .notsheep
    mov eax, [rbx + MB_COLOR]
    imul eax, eax, 3
    lea rcx, [wool_rgb]
    add rcx, rax
%macro WTINT 1
    movzx eax, byte [rcx + %1]
    imul eax, [fig_tint + %1 * 4]
    shr eax, 8
    mov [fig_tint + %1 * 4], eax
%endmacro
    push qword [fig_tint]
    push qword [fig_tint + 8]
    WTINT 0
    WTINT 1
    WTINT 2
    lea rdi, [m_sheep_wool]
    mov esi, M_SHEEP_WOOL_N
    call fig_parts
    pop qword [fig_tint + 8]
    pop qword [fig_tint]
.notsheep:
    ; a heart over a mob in love
    movss xmm0, [rbx + MB_LOVE]
    comiss xmm0, [f_zero]
    jbe .noheart
    TYPEREC
    movss xmm1, [rax + TY_HEIGHT]
    addss xmm1, [f_heart_y]
    mulss xmm1, [f_16]
    xorps xmm0, xmm0
    xorps xmm2, xmm2
    call glTranslatef PLT
    lea rdi, [m_heart]
    mov esi, M_HEART_N
    call fig_parts
.noheart:
    call glPopMatrix PLT
    inc r12d
    jmp .m
.done:
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

; void crop_tick(void) - crops grow near the player: random columns of
; the chunks within 4 of the player (about 3000 a second); a growing crop
; on top of one moves up a stage 1 time in 6
; locals: [0] columns left
crop_tick:
    ENTER_FN 16
    movss xmm0, [dt]
    mulss xmm0, [f_cropsamp]
    cvttss2si eax, xmm0
    cmp eax, 300
    jle .n
    mov eax, 300
.n:
    test eax, eax
    jle .out
    mov [rsp], eax
.s:
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 81
    div ecx                         ; edx 0..80: chunk offset
    mov eax, edx
    xor edx, edx
    mov ecx, 9
    div ecx
    lea r12d, [rdx - 4]
    add r12d, [cur_pcx]             ; chunk x
    lea r13d, [rax - 4]
    add r13d, [cur_pcz]             ; chunk z
    mov edi, r12d
    mov esi, r13d
    call world_find
    test eax, eax
    js .next
    mov r14d, eax                   ; slot
    call rand
    shr eax, 8
    movzx r15d, al                  ; column
    mov eax, r14d
    shl eax, 8
    add eax, r15d
    lea rcx, [chunk_hmap]
    movzx ebx, word [rcx + rax*2]   ; y index of the node on top
    cmp ebx, 255
    ja .next
    mov eax, r14d
    shl rax, 16
    mov ecx, r15d
    shl ecx, 8
    add eax, ecx
    add eax, ebx
    lea rcx, [chunk_blocks]
    movzx eax, byte [rcx + rax]
    lea ecx, [rax - B_WHEAT0]
    cmp ecx, B_WHEAT7 - B_WHEAT0
    jb .grows
    lea ecx, [rax - B_CARROT0]
    cmp ecx, B_CARROT3 - B_CARROT0
    jae .next
.grows:
    push rax
    sub rsp, 8
    call rand
    shr eax, 8
    xor edx, edx
    mov ecx, 6
    div ecx
    add rsp, 8
    pop rcx
    test edx, edx
    jnz .next
    inc ecx                         ; next stage
    mov edi, r12d
    shl edi, 4
    mov eax, r15d
    and eax, 15
    add edi, eax
    lea esi, [rbx + WORLD_YMIN]
    mov edx, r13d
    shl edx, 4
    mov eax, r15d
    shr eax, 4
    add edx, eax
    call world_set
.next:
    dec dword [rsp]
    jnz .s
.out:
    LEAVE_FN

; ---------------------------------------------------------------------------
; creative fun: slimes split, ghasts fly and shoot, fireballs

; slime_split - a dead big or medium slime (rbx) leaves 2-4 of the next
; size round where it was
slime_split:
    push r12
    push r13
    sub rsp, 8
    mov r13d, [rbx + MB_TYPE]
    cmp r13d, MOB_SLIME_L
    je .split
    cmp r13d, MOB_SLIME_M
    jne .out
.split:
    inc r13d                        ; the next size down
    call rand
    shr eax, 8
    and eax, 3
    cmp eax, 2
    jae .n
    add eax, 2
.n:
    mov r12d, eax                   ; 2-4 (3 counted as 2 or 3: close enough)
.one:
    call randf
    subss xmm0, [f_half]
    addss xmm0, [rbx + MB_X]
    movss [rsp], xmm0
    call randf
    subss xmm0, [f_half]
    addss xmm0, [rbx + MB_Z]
    movaps xmm2, xmm0
    movss xmm0, [rsp]
    movss xmm1, [rbx + MB_Y]
    mov edi, r13d
    call mob_spawn
    dec r12d
    jnz .one
.out:
    add rsp, 8
    pop r13
    pop r12
    ret

; ghast_think - rbx ghast: drift, keep a height over the ground, shoot at
; the nearest other mob
; locals: [0] scratch, [4] angle, [8] cos, [12] sin, [16] best d2,
;         [20] target, [24] dx, [28] dy, [32] dz
ghast_think:
    ENTER_FN 48
    ; a new way to drift now and then
    movss xmm0, [rbx + MB_TIMER]
    subss xmm0, [dt]
    movss [rbx + MB_TIMER], xmm0
    comiss xmm0, [f_zero]
    ja .alt
    call randf
    mulss xmm0, [f_gwander]
    addss xmm0, [f_gwander]
    movss [rbx + MB_TIMER], xmm0
    call randf
    mulss xmm0, [f_2pi]
    movss [rsp + 4], xmm0
    fld dword [rsp + 4]
    fsincos
    fstp dword [rsp + 8]
    fstp dword [rsp + 12]
    TYPEREC
    movss xmm1, [rax + TY_SPEED]
    movss xmm0, [rsp + 12]
    mulss xmm0, xmm1
    movss [rbx + MB_WX], xmm0
    movss xmm0, [rsp + 8]
    mulss xmm0, xmm1
    movss [rbx + MB_WZ], xmm0
.alt:
    ; the ground below (24 nodes at most): float 6 over it, else sink
    movss xmm0, [rbx + MB_Y]
    FLOORF r12d, xmm0
    xor r13d, r13d
.down:
    movss xmm0, [rbx + MB_X]
    FLOORF edi, xmm0
    mov esi, r12d
    sub esi, r13d
    movss xmm0, [rbx + MB_Z]
    FLOORF edx, xmm0
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID | F_LIQUID
    jnz .ground
    inc r13d
    cmp r13d, 24
    jb .down
    movss xmm0, [rbx + MB_Y]
    subss xmm0, [f_one]
    jmp .goal
.ground:
    mov eax, r12d
    sub eax, r13d
    inc eax
    cvtsi2ss xmm0, eax
    addss xmm0, [f_gfloat]
.goal:
    subss xmm0, [rbx + MB_Y]
    mulss xmm0, [f_gclimb]
    minss xmm0, [f_gvmax]
    xorps xmm1, xmm1
    subss xmm1, [f_gvmax]
    maxss xmm0, xmm1
    movss [rbx + MB_VY], xmm0
    ; stuck in something (an egg used next to a wall): rise out of it
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    test eax, eax
    jnz .free
    movss xmm0, [rbx + MB_Y]
    movss xmm1, [f_gvmax]
    mulss xmm1, [dt]
    addss xmm0, xmm1
    movss [rbx + MB_Y], xmm0
    jmp .shoot
.free:
    ; move x, z, y; turn back from what is in the way
    movss xmm0, [rbx + MB_WX]
    mulss xmm0, [dt]
    addss xmm0, [rbx + MB_X]
    movss [rsp], xmm0
    movss xmm1, [rbx + MB_Y]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    test eax, eax
    jz .xback
    mov eax, [rsp]
    mov [rbx + MB_X], eax
    jmp .gz
.xback:
    xorps xmm0, xmm0
    subss xmm0, [rbx + MB_WX]
    movss [rbx + MB_WX], xmm0
.gz:
    movss xmm2, [rbx + MB_WZ]
    mulss xmm2, [dt]
    addss xmm2, [rbx + MB_Z]
    movss [rsp], xmm2
    movss xmm0, [rbx + MB_X]
    movss xmm1, [rbx + MB_Y]
    call mob_free
    test eax, eax
    jz .zback
    mov eax, [rsp]
    mov [rbx + MB_Z], eax
    jmp .gy
.zback:
    xorps xmm0, xmm0
    subss xmm0, [rbx + MB_WZ]
    movss [rbx + MB_WZ], xmm0
.gy:
    movss xmm1, [rbx + MB_VY]
    mulss xmm1, [dt]
    addss xmm1, [rbx + MB_Y]
    movss [rsp], xmm1
    movss xmm0, [rbx + MB_X]
    movss xmm2, [rbx + MB_Z]
    call mob_free
    test eax, eax
    jz .shoot
    mov eax, [rsp]
    mov [rbx + MB_Y], eax
.shoot:
    ; face the way it drifts (or its target, below)
    fld dword [rbx + MB_WX]
    fld dword [rbx + MB_WZ]
    fpatan
    fmul dword [f_rad2deg]
    fstp dword [rbx + MB_YAW]
    COUNTDOWN MB_TX                 ; mouth open
    COUNTDOWN MB_BURN               ; until the next shot
    ; the nearest other mob within 32 nodes
    mov eax, [f_gsight]
    mov [rsp + 16], eax
    mov dword [rsp + 20], -1
    xor ecx, ecx
.t:
    cmp ecx, [mob_count]
    jae .picked
    imul eax, ecx, MB_SIZE
    lea rdx, [mobs]
    add rdx, rax
    cmp dword [rdx + MB_TYPE], MOB_GHAST
    je .tn
    movss xmm0, [rdx + MB_X]
    subss xmm0, [rbx + MB_X]
    mulss xmm0, xmm0
    movss xmm1, [rdx + MB_Z]
    subss xmm1, [rbx + MB_Z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rdx + MB_Y]
    subss xmm1, [rbx + MB_Y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [rsp + 16]
    jae .tn
    movss [rsp + 16], xmm0
    mov [rsp + 20], ecx
.tn:
    inc ecx
    jmp .t
.picked:
    mov ecx, [rsp + 20]
    test ecx, ecx
    js .out
    imul eax, ecx, MB_SIZE
    lea rdx, [mobs]
    add rdx, rax
    ; aim from the middle of the body at the middle of the target
    movss xmm0, [rdx + MB_X]
    subss xmm0, [rbx + MB_X]
    movss [rsp + 24], xmm0
    mov eax, [rdx + MB_TYPE]
    imul eax, eax, TY_SIZE
    lea rcx, [types]
    movss xmm1, [rcx + rax + TY_HEIGHT]
    mulss xmm1, [f_half]
    addss xmm1, [rdx + MB_Y]
    subss xmm1, [rbx + MB_Y]
    subss xmm1, [f_gmid]
    movss [rsp + 28], xmm1
    movss xmm2, [rdx + MB_Z]
    subss xmm2, [rbx + MB_Z]
    movss [rsp + 32], xmm2
    fld dword [rsp + 24]
    fld dword [rsp + 32]
    fpatan
    fmul dword [f_rad2deg]
    fstp dword [rbx + MB_YAW]
    movss xmm0, [rbx + MB_BURN]
    comiss xmm0, [f_zero]
    ja .out
    call randf
    addss xmm0, [f_gshoot]
    movss [rbx + MB_BURN], xmm0
    mov eax, [f_gmouth]
    mov [rbx + MB_TX], eax
    ; unit direction
    movss xmm0, [rsp + 24]
    mulss xmm0, xmm0
    movss xmm1, [rsp + 28]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rsp + 32]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    maxss xmm0, [f_low]
    movss xmm6, [f_one]
    divss xmm6, xmm0
    movss xmm3, [rsp + 24]
    mulss xmm3, xmm6
    movss xmm4, [rsp + 28]
    mulss xmm4, xmm6
    movss xmm5, [rsp + 32]
    mulss xmm5, xmm6
    ; from just outside its face
    movss xmm0, xmm3
    mulss xmm0, [f_gmuzzle]
    addss xmm0, [rbx + MB_X]
    movss xmm1, xmm4
    mulss xmm1, [f_gmuzzle]
    addss xmm1, [rbx + MB_Y]
    addss xmm1, [f_gmid]
    movss xmm2, xmm5
    mulss xmm2, [f_gmuzzle]
    addss xmm2, [rbx + MB_Z]
    mulss xmm3, [f_fbspeed]
    mulss xmm4, [f_fbspeed]
    mulss xmm5, [f_fbspeed]
    call fireball_spawn
.out:
    LEAVE_FN

; fireball_spawn(xmm0..2 position, xmm3..5 velocity)
fireball_spawn:
    lea rax, [fireballs]
    xor ecx, ecx
.f:
    cmp dword [rax + FB_USED], 0
    je .got
    add rax, FB_SIZE
    inc ecx
    cmp ecx, MAX_FIREBALLS
    jb .f
    ret
.got:
    mov dword [rax + FB_USED], 1
    movss [rax + FB_X], xmm0
    movss [rax + FB_X + 4], xmm1
    movss [rax + FB_X + 8], xmm2
    movss [rax + FB_VX], xmm3
    movss [rax + FB_VX + 4], xmm4
    movss [rax + FB_VX + 8], xmm5
    mov dword [rax + FB_AGE], 0
    ret

; fireball_update - fly; hitting a block or a mob (or a player in
; survival) they burst: damage and a push within 2.5 nodes, fire left in
; the air there
; r12 index, r13 record; locals: [0] new x y z
fireball_update:
    ENTER_FN 16
    xor r12d, r12d
.f:
    cmp r12d, MAX_FIREBALLS
    jae .out
    mov eax, r12d
    shl eax, 5
    lea r13, [fireballs]
    add r13, rax
    cmp dword [r13 + FB_USED], 0
    je .next
    movss xmm0, [r13 + FB_AGE]
    addss xmm0, [dt]
    movss [r13 + FB_AGE], xmm0
    comiss xmm0, [f_fblife]
    jae .gone
    xor ecx, ecx
.mv:
    movss xmm0, [r13 + FB_VX + rcx*4]
    mulss xmm0, [dt]
    addss xmm0, [r13 + FB_X + rcx*4]
    movss [rsp + rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jb .mv
    ; a block?
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, [rsp + 8]
    call solid_at
    jnz .burst
    ; a mob (not a ghast)?
    xor ecx, ecx
.m:
    cmp ecx, [mob_count]
    jae .player
    imul eax, ecx, MB_SIZE
    lea rdx, [mobs]
    add rdx, rax
    cmp dword [rdx + MB_TYPE], MOB_GHAST
    je .mn
    mov eax, [rdx + MB_TYPE]
    imul eax, eax, TY_SIZE
    lea r8, [types]
    add r8, rax
    movss xmm0, [rsp]
    subss xmm0, [rdx + MB_X]
    andps xmm0, [f_absmask]
    comiss xmm0, [r8 + TY_HALF]
    ja .mn
    movss xmm0, [rsp + 8]
    subss xmm0, [rdx + MB_Z]
    andps xmm0, [f_absmask]
    comiss xmm0, [r8 + TY_HALF]
    ja .mn
    movss xmm0, [rsp + 4]
    subss xmm0, [rdx + MB_Y]
    comiss xmm0, [f_zero]
    jb .mn
    comiss xmm0, [r8 + TY_HEIGHT]
    jbe .burst
.mn:
    inc ecx
    jmp .m
.player:
    cmp dword [game_mode], 0
    jne .fly
    movss xmm0, [rsp]
    subss xmm0, [pos]
    andps xmm0, [f_absmask]
    comiss xmm0, [f_half]
    ja .fly
    movss xmm0, [rsp + 8]
    subss xmm0, [pos + 8]
    andps xmm0, [f_absmask]
    comiss xmm0, [f_half]
    ja .fly
    movss xmm0, [rsp + 4]
    subss xmm0, [pos + 4]
    comiss xmm0, [f_zero]
    jb .fly
    comiss xmm0, [f_eye]
    jbe .burst
.fly:
    mov eax, [rsp]
    mov [r13 + FB_X], eax
    mov eax, [rsp + 4]
    mov [r13 + FB_X + 4], eax
    mov eax, [rsp + 8]
    mov [r13 + FB_X + 8], eax
    jmp .next
.burst:
    ; burst where it was (still in the open)
    movss xmm0, [r13 + FB_X]
    movss xmm1, [r13 + FB_X + 4]
    movss xmm2, [r13 + FB_X + 8]
    call fireball_burst
.gone:
    mov dword [r13 + FB_USED], 0
.next:
    inc r12d
    jmp .f
.out:
    LEAVE_FN

; fireball_burst(xmm0..2) - damage and push mobs (not ghasts) and a player
; in survival within 2.5 nodes; fire in the node if it is air
; locals: [0] x, [4] y, [8] z, [12] impact, [16] dx, [20] dz, [24] dist
fireball_burst:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    xor r14d, r14d
.m:
    cmp r14d, [mob_count]
    jae .player
    imul eax, r14d, MB_SIZE
    lea r15, [mobs]
    add r15, rax
    cmp dword [r15 + MB_TYPE], MOB_GHAST
    je .mn
    movss xmm0, [r15 + MB_X]
    subss xmm0, [rsp]
    movss [rsp + 16], xmm0
    movss xmm1, [r15 + MB_Y]
    addss xmm1, [f_half]
    subss xmm1, [rsp + 4]
    movss xmm2, [r15 + MB_Z]
    subss xmm2, [rsp + 8]
    movss [rsp + 20], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp + 24], xmm0
    comiss xmm0, [f_fbr]
    jae .mn
    divss xmm0, [f_fbr]
    movss xmm1, [f_one]
    subss xmm1, xmm0
    movss [rsp + 12], xmm1
    mulss xmm1, [f_fbdmg]
    cvttss2si eax, xmm1
    inc eax
    sub [r15 + MB_HP], eax
    mov eax, [f_hurtt]
    mov [r15 + MB_HURT], eax
    mov eax, [f_fleet]
    mov [r15 + MB_FLEE], eax
    movss xmm2, [rsp + 24]
    maxss xmm2, [f_low]
    movss xmm3, [rsp + 12]
    mulss xmm3, [f_fbknock]
    divss xmm3, xmm2
    movss xmm0, [rsp + 16]
    mulss xmm0, xmm3
    movss [r15 + MB_KX], xmm0
    movss xmm0, [rsp + 20]
    mulss xmm0, xmm3
    movss [r15 + MB_KZ], xmm0
    mov eax, [f_knockup]
    mov [r15 + MB_VY], eax
    mov dword [r15 + MB_GROUND], 0
.mn:
    inc r14d
    jmp .m
.player:
    cmp dword [game_mode], 0
    jne .fire
    movss xmm0, [pos]
    subss xmm0, [rsp]
    mulss xmm0, xmm0
    movss xmm1, [pos + 4]
    addss xmm1, [f_one]
    subss xmm1, [rsp + 4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [pos + 8]
    subss xmm1, [rsp + 8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [f_fbr]
    jae .fire
    divss xmm0, [f_fbr]
    movss xmm1, [f_one]
    subss xmm1, xmm0
    mulss xmm1, [f_fbdmg]
    cvttss2si edi, xmm1
    inc edi
    call player_damage
.fire:
    movss xmm0, [rsp]
    FLOORF r12d, xmm0
    movss xmm0, [rsp + 4]
    FLOORF r13d, xmm0
    movss xmm0, [rsp + 8]
    FLOORF r14d, xmm0
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call world_get
    test eax, eax
    jnz .out
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call fire_set
.out:
    LEAVE_FN

; void mob_shot(int mob, int damage) - a bullet along the last mob_ray
mob_shot:
    imul edi, edi, MB_SIZE
    lea rax, [mobs]
    add rax, rdi
    sub [rax + MB_HP], esi
    mov ecx, [f_hurtt]
    mov [rax + MB_HURT], ecx
    mov ecx, [f_fleet]
    mov [rax + MB_FLEE], ecx
    cmp dword [rax + MB_TYPE], MOB_WITHER
    jne .push
    mov dword [rax + MB_COLOR], 0   ; (no gunpowder for bullets)
.push:
    cmp dword [rax + MB_TYPE], MOB_GHAST
    je .out                         ; too big to push
    movss xmm0, [ray_dir]
    mulss xmm0, [f_shotknock]
    addss xmm0, [rax + MB_KX]
    movss [rax + MB_KX], xmm0
    movss xmm0, [ray_dir + 4]
    mulss xmm0, [f_shotknock]
    addss xmm0, [rax + MB_KZ]
    movss [rax + MB_KZ], xmm0
.out:
    ret

; void draw_fireballs(void) - spinning balls of fire, full bright
draw_fireballs:
    ENTER_FN 16
    lea rax, [fireballs]
    xor ecx, ecx
.any:
    cmp dword [rax + FB_USED], 0
    jne .some
    add rax, FB_SIZE
    inc ecx
    cmp ecx, MAX_FIREBALLS
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
.f:
    cmp r12d, MAX_FIREBALLS
    jae .done
    mov eax, r12d
    shl eax, 5
    lea rbx, [fireballs]
    add rbx, rax
    cmp dword [rbx + FB_USED], 0
    je .next
    call glPushMatrix PLT
    mov eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm0, [rbx + FB_X]
    subss xmm0, xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm2, [rbx + FB_X + 8]
    subss xmm2, xmm1
    movss xmm1, [rbx + FB_X + 4]
    call glTranslatef PLT
    movss xmm0, [rbx + FB_AGE]
    mulss xmm0, [f_fbspin]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [f_inv16]
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    call glScalef PLT
    lea rdi, [m_fireball]
    mov esi, M_FIREBALL_N
    call fig_parts
    call glPopMatrix PLT
.next:
    inc r12d
    jmp .f
.done:
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

NOEXECSTACK
