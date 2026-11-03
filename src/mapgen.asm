; mapgen.asm - Luanti mapgen v7 ported to x86-64 assembly.
;
; Follows luanti/src/mapgen/mapgen_v7.cpp with the default flags
; (mountains + ridges/rivers, no floatlands), the original heat/humidity
; biome generator (mg_biome.cpp), MapgenBasic::generateBiomes,
; CavesNoiseIntersection tunnels and simple tree decorations.
;
; Differences from Luanti, kept small on purpose:
;  * world height is clipped to y -64..191 (one 16x256x16 column per chunk)
;  * mountain 3D noise is sampled every 4 nodes in y and interpolated
;    (its y spread is 350 so this is visually identical, ~3x cheaper)
;  * biomes are a fixed built-in set modelled on Minetest Game's
;  * caverns (only below y -256) and dungeons are not generated
;
; Not reentrant: uses module globals. Only the world-gen thread calls it.

%include "common.inc"

global mapgen_chunk, mapgen_base_height, mapgen_flat, mapgen_finish
global mapgen_horizon_tile, nether_chunk, nether_finish
global np_terrain_base, np_terrain_alt, np_terrain_persist, np_height_select
global np_filler_depth, np_mount_height, np_ridge_uwater, np_mountain
global np_ridge, np_cave1, np_cave2

extern noise_fractal2d, noise_fractal2d_p, noise_fractal3d
extern block_flags, noise3d_value

; biome record
BI_HEAT     equ 0
BI_HUM      equ 4
BI_TOP      equ 8
BI_FILLER   equ 9
BI_STONE    equ 10
BI_DEPTH    equ 11
BI_TREE     equ 12
BI_SHORE    equ 13
BI_DENSITY  equ 14
BI_SIZE     equ 16
NUM_BIOMES  equ 8
BIOME_DESERT equ 5

T_NONE      equ 0
T_APPLE     equ 1
T_PINE      equ 2
T_JUNGLE    equ 3
T_CACTUS    equ 4

SNOWLINE    equ 110

; NOISEP offset, scale, spread x, y, z, seed, octaves, persist, lacunarity
%macro NOISEP 9
    dd %1, %2, %3, %4, %5
    dd %6, %7
    dd %8, %9
    dd NOISE_FLAG_DEFAULTS
%endmacro

%macro BIOME 9  ; heat hum top filler stone depth tree shore density
    dd %1, %2
    db %3, %4, %5, %6, %7, %8
    dw %9
%endmacro

section .data
align 16
; MapgenV7Params defaults (mapgen_v7.cpp)
np_terrain_base:    NOISEP 4.0,   70.0,  600.0,  600.0,  600.0,  82341, 5, 0.6,  2.0
np_terrain_alt:     NOISEP 4.0,   25.0,  600.0,  600.0,  600.0,  5934,  5, 0.6,  2.0
np_terrain_persist: NOISEP 0.6,   0.1,   2000.0, 2000.0, 2000.0, 539,   3, 0.6,  2.0
np_height_select:   NOISEP -8.0,  16.0,  500.0,  500.0,  500.0,  4213,  6, 0.7,  2.0
np_filler_depth:    NOISEP 0.0,   1.2,   150.0,  150.0,  150.0,  261,   3, 0.7,  2.0
np_mount_height:    NOISEP 256.0, 112.0, 1000.0, 1000.0, 1000.0, 72449, 3, 0.6,  2.0
np_ridge_uwater:    NOISEP 0.0,   1.0,   1000.0, 1000.0, 1000.0, 85039, 5, 0.6,  2.0
np_mountain:        NOISEP -0.6,  1.0,   250.0,  350.0,  250.0,  5333,  5, 0.63, 2.0
np_ridge:           NOISEP 0.0,   1.0,   100.0,  100.0,  100.0,  6467,  4, 0.75, 2.0
np_cave1:           NOISEP 0.0,   12.0,  61.0,   61.0,   61.0,   52534, 3, 0.5,  2.0
np_cave2:           NOISEP 0.0,   12.0,  67.0,   67.0,   67.0,   10325, 3, 0.5,  2.0
; BiomeParamsOriginal defaults (mg_biome.h)
np_heat:            NOISEP 50.0,  50.0,  1000.0, 1000.0, 1000.0, 5349,  3, 0.5,  2.0
np_heat_blend:      NOISEP 0.0,   1.5,   8.0,    8.0,    8.0,    13,    2, 1.0,  2.0
np_humidity:        NOISEP 50.0,  50.0,  1000.0, 1000.0, 1000.0, 842,   3, 0.5,  2.0
np_humidity_blend:  NOISEP 0.0,   1.5,   8.0,    8.0,    8.0,    90003, 2, 1.0,  2.0

section .rodata
align 16
f_absmask:  dd 0x7fffffff, 0, 0, 0
f_zero:     dd 0.0
f_one:      dd 1.0
f_big:      dd 1.0e30
f_mntlim:   dd 1.84             ; max of mountain noise (offset + amplitude sum)
f_seven:    dd 7.0
f_17:       dd 17.0
; the nether
f_nxz1:     dd 0.03125              ; big caverns: 1/32 across, 1/20 up
f_ny1:      dd 0.05
f_nxz2:     dd 0.1                  ; lumps: 1/10, 1/8
f_ny2:      dd 0.125
f_nfloor:   dd 24.0                 ; solid closes in below this y index
f_nroof:    dd 104.0                ; and above this one
f_nwall:    dd 0.08
f_nopen:    dd 0.1                  ; a bit more open than solid
f_nhalf:    dd 0.5
f_2_5:      dd 2.5
f_0_2:      dd 0.2
f_0_6:      dd 0.6
f_quarter:  dd 0.25
f_cavew:    dd 0.09             ; mgv7_cave_width
CAVE_LAVA   equ 10                  ; tunnels at y index 10 (y -54) and below: lava
f_river_hz: dd 0.05             ; river centre width for the horizon

align 16
; Minetest Game style climate points: heat, humidity, top, filler, stone,
; filler depth, tree, shore block, tree chance (/65536)
biomes:
    BIOME 0.0,  40.0, B_SNOWDIRT, B_DIRT,  B_STONE,  1, T_NONE,   B_GRAVEL, 0
    BIOME 25.0, 70.0, B_SNOWDIRT, B_DIRT,  B_STONE,  3, T_PINE,   B_SAND,   2000
    BIOME 45.0, 70.0, B_GRASS,    B_DIRT,  B_STONE,  3, T_PINE,   B_SAND,   2000
    BIOME 50.0, 35.0, B_GRASS,    B_DIRT,  B_STONE,  1, T_APPLE,  B_SAND,   90
    BIOME 60.0, 68.0, B_GRASS,    B_DIRT,  B_STONE,  3, T_APPLE,  B_SAND,   1800
    BIOME 92.0, 16.0, B_DSAND,    B_DSAND, B_DSTONE, 1, T_CACTUS, B_DSAND,  250
    BIOME 89.0, 42.0, B_DRYGRASS, B_DIRT,  B_STONE,  1, T_APPLE,  B_SAND,   150
    BIOME 86.0, 65.0, B_GRASS,    B_DIRT,  B_STONE,  3, T_JUNGLE, B_SAND,   3500

; ore veins: block, veins per chunk, vein length, pad, lowest y index,
; y index range (y index = world y + 64)
ORE_SIZE    equ 12
; block, veins per chunk, steps per vein, replaces (0 = stone);
; first y index, y index range
ore_table:
    db B_COAL_ORE, 20, 10, 0
    dd 4, 180                       ; y -60 .. 120
    db B_IRON_ORE, 12, 7, 0
    dd 4, 120                       ; y -60 .. 60
    db B_GOLD_ORE, 3, 6, 0
    dd 4, 44                        ; y -60 .. -16
    db B_DIAMOND_ORE, 2, 5, 0
    dd 4, 16                        ; y -60 .. -44
    db B_CLAY, 10, 16, B_SAND
    dd 52, 14                       ; y -12 .. 1: sea and lake floors
    db 0

section .bss
alignb 16
mapgen_flat: resd 1                 ; 1 = flat world (set only while idle)
g_blocks:    resq 1
g_hmap:      resq 1
g_bx:        resd 1
g_bz:        resd 1
g_seed:      resd 1
nd_grid:     resd 5 * 5 * 33         ; nether density samples
nd_col:      resd 33
g_fx:        resd 1
g_fz:        resd 1
alignb 16
col_surface: resd 256
col_mnth:    resd 256
col_mlimit:  resd 256
col_absuw:   resd 256
col_filler:  resd 256
col_biome:   resb 256
mnt_cache:   resd 72
mnt_valid:   resb 72

section .text

; ---------------------------------------------------------------------------
; int mapgen_chunk(u8 *blocks, u16 *hmap, int cx, int cz, int seed)
mapgen_chunk:
    ENTER_FN 0
    cmp dword [mapgen_flat], 0
    jne flat_chunk
    mov [g_blocks], rdi
    mov [g_hmap], rsi
    shl edx, 4
    mov [g_bx], edx
    shl ecx, 4
    mov [g_bz], ecx
    mov [g_seed], r8d
    call mg_columns
    call mg_terrain
    call mg_biomes
    call mg_caves
    call mg_ores
    call mg_trees
    call mg_grass
    call mg_heightmap
    LEAVE_FN

; int mapgen_finish(u8 *blocks, u16 *hmap) - heightmap and max y of a chunk
; that was loaded from disk instead of generated
mapgen_finish:
    sub rsp, 8
    mov [g_blocks], rdi
    mov [g_hmap], rsi
    call mg_heightmap
    add rsp, 8
    ret

; Flat world for building: bedrock, two dirt layers and grass on the world
; floor (y -64..-61), nothing else. rdi blocks, rsi heightmap; returns max y.
flat_chunk:
    mov rdx, rsi
    xor eax, eax
    mov ecx, CHUNK_VOX
    rep stosb                       ; rdi: all air
    sub rdi, CHUNK_VOX
    xor ecx, ecx
.col:
    mov rax, rcx
    shl rax, 8
    mov byte [rdi + rax], B_BEDROCK
    mov byte [rdi + rax + 1], B_DIRT
    mov byte [rdi + rax + 2], B_DIRT
    mov byte [rdi + rax + 3], B_GRASS
    mov word [rdx + rcx*2], 4
    inc ecx
    cmp ecx, 256
    jb .col
    mov eax, 3
    LEAVE_FN

; int mapgen_base_height(int x, int z, int seed) - test helper
mapgen_base_height:
    sub rsp, 8
    mov [g_seed], edx
    cvtsi2ss xmm0, edi
    cvtsi2ss xmm1, esi
    call mg_surface_at
    cvttss2si eax, xmm0
    add rsp, 8
    ret

; F2 np - noise_fractal2d(np, [rsp], [rsp+4], g_seed)
%macro F2 1
    lea rdi, [%1]
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    mov esi, [g_seed]
    call noise_fractal2d
%endmacro

; F2P np, persist_mem - same with persistence override
%macro F2P 2
    lea rdi, [%1]
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, %2
    mov esi, [g_seed]
    call noise_fractal2d_p
%endmacro

; F3 np, yreg32 - noise_fractal3d(np, g_fx, (float)y, g_fz, g_seed)
%macro F3 2
    cvtsi2ss xmm1, %2
    movss xmm0, [g_fx]
    movss xmm2, [g_fz]
    lea rdi, [%1]
    mov esi, [g_seed]
    call noise_fractal3d
%endmacro

; float mg_surface_at(float x, float z) - MapgenV7::baseTerrainLevelAtPoint
mg_surface_at:
    sub rsp, 40
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    F2 np_terrain_persist
    movss [rsp + 8], xmm0
    F2P np_terrain_base, [rsp + 8]
    movss [rsp + 12], xmm0
    F2P np_terrain_alt, [rsp + 8]
    movss [rsp + 16], xmm0
    F2 np_height_select
    maxss xmm0, [f_zero]
    minss xmm0, [f_one]             ; hselect
    movss xmm1, [rsp + 16]          ; alt
    movss xmm2, [rsp + 12]          ; base
    comiss xmm1, xmm2
    ja .alt
    mulss xmm2, xmm0
    movss xmm3, [f_one]
    subss xmm3, xmm0
    mulss xmm1, xmm3
    addss xmm1, xmm2
.alt:
    movaps xmm0, xmm1
    add rsp, 40
    ret

; ---------------------------------------------------------------------------
; Per-column 2D noise: surface height, mountain height, river noise,
; filler depth and biome.
mg_columns:
    ENTER_FN 32
    xor r12d, r12d
.col:
    mov eax, r12d
    and eax, 15
    add eax, [g_bx]
    cvtsi2ss xmm0, eax
    movss [rsp], xmm0
    mov eax, r12d
    shr eax, 4
    add eax, [g_bz]
    cvtsi2ss xmm1, eax
    movss [rsp + 4], xmm1

    call mg_surface_at
    cvttss2si eax, xmm0
    lea rcx, [col_surface]
    mov [rcx + r12*4], eax

    F2 np_mount_height
    maxss xmm0, [f_one]
    lea rcx, [col_mnth]
    movss [rcx + r12*4], xmm0
    mulss xmm0, [f_mntlim]
    cvttss2si eax, xmm0
    lea rcx, [col_mlimit]
    mov [rcx + r12*4], eax

    F2 np_ridge_uwater
    andps xmm0, [f_absmask]
    addss xmm0, xmm0
    lea rcx, [col_absuw]
    movss [rcx + r12*4], xmm0

    F2 np_filler_depth
    lea rcx, [col_filler]
    movss [rcx + r12*4], xmm0

    F2 np_heat
    movss [rsp + 8], xmm0
    F2 np_heat_blend
    addss xmm0, [rsp + 8]
    movss [rsp + 8], xmm0
    F2 np_humidity
    movss [rsp + 12], xmm0
    F2 np_humidity_blend
    addss xmm0, [rsp + 12]          ; humidity
    movss xmm1, [rsp + 8]           ; heat

    ; nearest climate point
    movss xmm4, [f_big]
    xor eax, eax
    xor ecx, ecx
    lea rsi, [biomes]
.bl:
    movaps xmm2, xmm1
    subss xmm2, [rsi + BI_HEAT]
    mulss xmm2, xmm2
    movaps xmm3, xmm0
    subss xmm3, [rsi + BI_HUM]
    mulss xmm3, xmm3
    addss xmm2, xmm3
    comiss xmm2, xmm4
    jae .bn
    movaps xmm4, xmm2
    mov eax, ecx
.bn:
    add rsi, BI_SIZE
    inc ecx
    cmp ecx, NUM_BIOMES
    jb .bl
    lea rcx, [col_biome]
    mov [rcx + r12], al

    inc r12d
    cmp r12d, 256
    jb .col
    LEAVE_FN

; ---------------------------------------------------------------------------
; xmm0 = mountain noise sample k (y = 4k - 64), cached per column
mg_msample:
    lea rax, [mnt_valid]
    cmp byte [rax + rdi], 0
    je .calc
    lea rax, [mnt_cache]
    movss xmm0, [rax + rdi*4]
    ret
.calc:
    push rdi
    lea eax, [rdi*4 + WORLD_YMIN]
    F3 np_mountain, eax
    pop rdi
    lea rax, [mnt_valid]
    mov byte [rax + rdi], 1
    lea rax, [mnt_cache]
    movss [rax + rdi*4], xmm0
    ret

; Column fill: MapgenV7::generateTerrain
mg_terrain:
    ENTER_FN 32
    xor r12d, r12d
.col:
    mov eax, r12d
    and eax, 15
    add eax, [g_bx]
    cvtsi2ss xmm0, eax
    movss [g_fx], xmm0
    mov eax, r12d
    shr eax, 4
    add eax, [g_bz]
    cvtsi2ss xmm0, eax
    movss [g_fz], xmm0
    lea rcx, [col_absuw]
    movss xmm0, [rcx + r12*4]
    movss [rsp + 8], xmm0
    lea rcx, [col_mnth]
    movss xmm0, [rcx + r12*4]
    movss [rsp + 12], xmm0
    lea rcx, [col_mlimit]
    mov eax, [rcx + r12*4]
    mov [rsp + 16], eax
    lea rcx, [col_surface]
    mov r14d, [rcx + r12*4]
    mov r13, r12
    shl r13, 8
    add r13, [g_blocks]
    ; invalidate mountain cache
    lea rdi, [mnt_valid]
    xor eax, eax
    mov ecx, 72
    rep stosb

    xor r15d, r15d                  ; y index
.y:
    lea ebx, [r15 + WORLD_YMIN]     ; world y
    ; --- river channel (getRiverChannelFromMap)
    movss xmm0, [rsp + 8]
    comiss xmm0, [f_0_2]
    ja .noriver
    F3 np_ridge, ebx
    lea eax, [rbx - WATER_LEVEL]
    cvtsi2ss xmm1, eax              ; altitude
    movaps xmm2, xmm1
    maxss xmm2, [f_zero]
    mulss xmm0, xmm2
    divss xmm0, [f_seven]           ; nridge
    movaps xmm3, xmm1
    addss xmm3, [f_17]
    divss xmm3, [f_2_5]             ; height_mod
    movss xmm4, [f_0_2]
    subss xmm4, [rsp + 8]           ; width_mod
    mulss xmm4, xmm3
    addss xmm0, xmm4
    comiss xmm0, [f_0_6]
    jae .river
.noriver:
    cmp ebx, r14d
    jle .stone
    ; --- mountain (getMountainTerrainFromMap)
    cmp ebx, [rsp + 16]
    jg .nomount
    mov edi, r15d
    shr edi, 2
    call mg_msample
    movss [rsp + 20], xmm0
    test r15d, 3
    jz .m0
    mov edi, r15d
    shr edi, 2
    inc edi
    call mg_msample
    subss xmm0, [rsp + 20]
    mov eax, r15d
    and eax, 3
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_quarter]
    mulss xmm0, xmm1
    addss xmm0, [rsp + 20]
    jmp .m1
.m0:
    movss xmm0, [rsp + 20]
.m1:
    cvtsi2ss xmm1, ebx
    divss xmm1, [rsp + 12]
    subss xmm0, xmm1
    comiss xmm0, [f_zero]
    jae .stone
.nomount:
.river:
    cmp ebx, WATER_LEVEL
    jle .water
    mov byte [r13 + r15], B_AIR
    jmp .next
.water:
    mov byte [r13 + r15], B_WATER
    jmp .next
.stone:
    mov byte [r13 + r15], B_STONE
.next:
    inc r15d
    cmp r15d, WORLD_H
    jb .y
    inc r12d
    cmp r12d, 256
    jb .col
    LEAVE_FN

; ---------------------------------------------------------------------------
; Biome surface: MapgenBasic::generateBiomes (top / filler / biome stone)
; Locals: [rsp] top, [rsp+1] filler, [rsp+2] stone, [rsp+4] base_filler
mg_biomes:
    ENTER_FN 16
    xor r12d, r12d
.col:
    lea rcx, [col_biome]
    movzx eax, byte [rcx + r12]
    shl eax, 4
    lea r14, [biomes]
    add r14, rax                    ; biome record
    mov al, [r14 + BI_STONE]
    mov [rsp + 2], al
    lea rcx, [col_filler]
    movss xmm5, [rcx + r12*4]       ; filler depth noise
    mov r13, r12
    shl r13, 8
    add r13, [g_blocks]
    mov ebx, 1                      ; bit0 air_above, bit1 water_above
    xor r15d, r15d                  ; nplaced
    mov edi, 255                    ; y index
    mov edx, 255
    call .variant
.y:
    movzx eax, byte [r13 + rdi]
    cmp al, B_STONE
    jne .notstone
    test ebx, ebx
    jz .nosurf
    mov edx, edi
    call .variant
.nosurf:
    mov al, B_STONE
    test edi, edi
    jz .below_ok
    mov al, [r13 + rdi - 1]
.below_ok:
    cmp al, B_AIR
    je .unsupp
    cmp al, B_WATER
    jne .supp
.unsupp:
    mov r15d, 0xffff
.supp:
    cmp r15d, 1
    jae .notop
    mov al, [rsp]
    mov [r13 + rdi], al
    inc r15d
    jmp .placed
.notop:
    cmp r15d, [rsp + 4]
    jae .bstone
    mov al, [rsp + 1]
    mov [r13 + rdi], al
    inc r15d
    jmp .placed
.bstone:
    mov al, [rsp + 2]
    mov [r13 + rdi], al
    mov r15d, 0xffff
.placed:
    xor ebx, ebx
    jmp .ynext
.notstone:
    cmp al, B_WATER
    jne .notwater
    xor r15d, r15d
    mov ebx, 2
    jmp .ynext
.notwater:
    cmp al, B_AIR
    jne .other
    xor r15d, r15d
    mov ebx, 1
    jmp .ynext
.other:
    mov r15d, 0xffff
    xor ebx, ebx
.ynext:
    dec edi
    jns .y
    inc r12d
    cmp r12d, 256
    jb .col
    LEAVE_FN

; edx = y index of the surface: pick shore / snowcap / normal variant.
; Called with one extra return address on the stack, so locals are +8.
.variant:
    lea eax, [rdx + WORLD_YMIN]
    cmp eax, WATER_LEVEL + 2
    jg .v_notshore
    mov al, [r14 + BI_SHORE]
    mov [rsp + 8], al
    mov [rsp + 9], al
    mov eax, 3
    jmp .v_depth
.v_notshore:
    cmp eax, SNOWLINE
    jl .v_normal
    lea rcx, [biomes + BIOME_DESERT * BI_SIZE]
    cmp r14, rcx
    je .v_normal
    mov byte [rsp + 8], B_SNOW
    mov al, [r14 + BI_FILLER]
    mov [rsp + 9], al
    movzx eax, byte [r14 + BI_DEPTH]
    jmp .v_depth
.v_normal:
    mov al, [r14 + BI_TOP]
    mov [rsp + 8], al
    mov al, [r14 + BI_FILLER]
    mov [rsp + 9], al
    movzx eax, byte [r14 + BI_DEPTH]
.v_depth:
    inc eax                         ; depth_top (1) + depth_filler
    cvtsi2ss xmm0, eax
    addss xmm0, xmm5
    maxss xmm0, [f_zero]
    cvttss2si eax, xmm0
    mov [rsp + 12], eax
    ret

; ---------------------------------------------------------------------------
; contour(v) = |v| >= 1 ? 0 : 1 - |v|   (in/out xmm0)
mg_contour:
    andps xmm0, [f_absmask]
    movss xmm1, [f_one]
    subss xmm1, xmm0
    maxss xmm1, [f_zero]
    movaps xmm0, xmm1
    ret

; Tunnels: CavesNoiseIntersection::generateCaves
; ebx bit0 column_is_open, bit1 is_under_tunnel, bit2 is_top_filler_above
mg_caves:
    ENTER_FN 32
    xor r12d, r12d
.col:
    mov eax, r12d
    and eax, 15
    add eax, [g_bx]
    cvtsi2ss xmm0, eax
    movss [g_fx], xmm0
    mov eax, r12d
    shr eax, 4
    add eax, [g_bz]
    cvtsi2ss xmm0, eax
    movss [g_fz], xmm0
    lea rcx, [col_biome]
    movzx eax, byte [rcx + r12]
    shl eax, 4
    lea r14, [biomes]
    add r14, rax
    movzx eax, byte [r14 + BI_DEPTH]
    inc eax
    mov [rsp + 4], eax              ; base_filler
    mov dword [rsp + 8], 0          ; nplaced
    mov r13, r12
    shl r13, 8
    add r13, [g_blocks]
    xor ebx, ebx
    mov r15d, 255
.y:
    movzx eax, byte [r13 + r15]
    cmp al, B_AIR
    je .open
    cmp al, B_WATER
    jne .ground
.open:
    or ebx, 1
    and ebx, ~4
    jmp .ynext
.ground:
    lea rcx, [block_flags]
    test byte [rcx + rax], F_GROUND
    jz .notunnel
    cmp r15d, 255
    je .test
    cmp byte [r13 + r15 + 1], B_WATER   ; don't open caves under the sea
    je .notunnel
.test:
    lea eax, [r15 + WORLD_YMIN]
    F3 np_cave1, eax
    call mg_contour
    comiss xmm0, [f_cavew]
    jbe .notunnel
    movss [rsp + 12], xmm0
    lea eax, [r15 + WORLD_YMIN]
    F3 np_cave2, eax
    call mg_contour
    mulss xmm0, [rsp + 12]
    comiss xmm0, [f_cavew]
    jbe .notunnel
    mov byte [r13 + r15], B_AIR
    cmp r15d, CAVE_LAVA
    ja .carved
    mov byte [r13 + r15], B_LAVA    ; deep tunnels are flooded with lava
.carved:
    or ebx, 2
    test ebx, 4
    jz .ynext
    mov al, [r14 + BI_STONE]
    mov [r13 + r15 + 1], al
    and ebx, ~4
    jmp .ynext
.notunnel:
    movzx eax, byte [r13 + r15]
    mov ecx, ebx
    and ecx, 3
    cmp ecx, 3
    jne .plain
    cmp al, [r14 + BI_STONE]
    je .floor
    cmp al, [r14 + BI_FILLER]
    jne .plain
.floor:
    ; tunnel entrance floor: biome top then filler
    mov ecx, [rsp + 8]
    test ecx, ecx
    jnz .f_filler
    mov al, [r14 + BI_TOP]
    mov [r13 + r15], al
    jmp .f_placed
.f_filler:
    cmp ecx, [rsp + 4]
    jae .f_stop
    mov al, [r14 + BI_FILLER]
    mov [r13 + r15], al
.f_placed:
    or ebx, 4
    inc dword [rsp + 8]
    jmp .ynext
.f_stop:
    and ebx, ~3
    jmp .ynext
.plain:
    cmp al, [r14 + BI_TOP]
    je .tf
    cmp al, [r14 + BI_FILLER]
    jne .notf
.tf:
    or ebx, 4
.notf:
    and ebx, ~1
.ynext:
    dec r15d
    jnz .y                          ; y index 0 stays solid floor
    inc r12d
    cmp r12d, 256
    jb .col
    LEAVE_FN

; ---------------------------------------------------------------------------
; Tall grass (where wheat seeds come from) on about 1 in 8 grass tops,
; flowers (for dyes) on a few of the others
mg_grass:
    push rbx
    push r12
    push r13
    xor r12d, r12d                  ; column
.col:
    mov r13, r12
    shl r13, 8
    add r13, [g_blocks]
    mov ebx, 254
.y:
    movzx eax, byte [r13 + rbx]
    test eax, eax
    jnz .top
    dec ebx
    jnz .y
    jmp .next
.top:
    cmp eax, B_GRASS
    je .grassy
    cmp eax, B_DRYGRASS
    jne .next
.grassy:
    mov edi, r12d
    and edi, 15
    add edi, [g_bx]
    mov esi, r12d
    shr esi, 4
    add esi, [g_bz]
    mov edx, [g_seed]
    add edx, 7331
    call mg_thash
    test eax, 0x700
    jz .tall
    ; flowers, about 1 in 40 of the rest: yellow or red
    mov ecx, eax
    shr ecx, 12
    and ecx, 63
    cmp ecx, 1
    ja .next
    mov dl, B_FLOWER_Y
    test ecx, ecx
    jz .flower
    mov dl, B_FLOWER_R
.flower:
    mov [r13 + rbx + 1], dl
    jmp .next
.tall:
    mov byte [r13 + rbx + 1], B_TALLGRASS
.next:
    inc r12d
    cmp r12d, 256
    jb .col
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; u32 mg_thash(int x, int z, int seed)
mg_thash:
    imul edi, edi, 0x27d4eb2d
    imul esi, esi, 0x165667b1
    imul edx, edx, -0x61c88647
    mov eax, edi
    xor eax, esi
    xor eax, edx
    mov ecx, eax
    shr ecx, 16
    xor eax, ecx
    imul eax, eax, -0x7a143595
    mov ecx, eax
    shr ecx, 13
    xor eax, ecx
    imul eax, eax, -0x3d4d51cb
    mov ecx, eax
    shr ecx, 16
    xor eax, ecx
    ret

; mg_put(lx edi, yi esi, lz edx, block ecx, mode r8d)
; mode 0: only into air, mode 1: into air or leaves (trunks)
mg_put:
    cmp edi, 15
    ja .out
    cmp edx, 15
    ja .out
    cmp esi, 255
    ja .out
    mov eax, edx
    shl eax, 12
    shl edi, 8
    or eax, edi
    or eax, esi
    mov r9, [g_blocks]
    movzx r10d, byte [r9 + rax]
    test r10d, r10d
    jz .put
    test r8d, r8d
    jz .out
    cmp r10d, B_LEAVES
    je .put
    cmp r10d, B_PINENEEDLES
    jne .out
.put:
    mov [r9 + rax], cl
.out:
    ret

; mg_layer(lx edi, yi esi, lz edx, radius ecx, block r8d, diamond r9d)
; disc of leaves; square layers drop their corners
mg_layer:
    ENTER_FN 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov [rsp], r8d
    mov [rsp + 4], r9d
    mov ebx, ecx
    neg ebx                         ; dz
.dz:
    mov r11d, r15d
    neg r11d                        ; dx (mg_put keeps r11)
.dx:
    mov eax, r11d
    cdq
    xor eax, edx
    sub eax, edx                    ; |dx|
    mov ecx, ebx
    mov edx, ecx
    sar edx, 31
    xor ecx, edx
    sub ecx, edx                    ; |dz|
    cmp dword [rsp + 4], 0
    je .square
    add eax, ecx
    cmp eax, r15d
    jg .skip
    jmp .place
.square:
    test r15d, r15d
    jz .place
    cmp eax, r15d
    jne .place
    cmp ecx, r15d
    je .skip
.place:
    lea edi, [r12 + r11]
    mov esi, r13d
    lea edx, [r14 + rbx]
    mov ecx, [rsp]
    xor r8d, r8d
    call mg_put
.skip:
    inc r11d
    cmp r11d, r15d
    jle .dx
    inc ebx
    cmp ebx, r15d
    jle .dz
    LEAVE_FN

; Decorations: one tree per chosen column, kept 2 nodes inside the chunk
mg_trees:
    ENTER_FN 32
    mov r12d, 2                     ; lz
.lz:
    mov r13d, 2                     ; lx
.lx:
    mov edi, r13d
    add edi, [g_bx]
    mov esi, r12d
    add esi, [g_bz]
    mov edx, [g_seed]
    call mg_thash
    mov [rsp], eax
    mov ecx, r12d
    shl ecx, 4
    or ecx, r13d
    lea rdx, [col_biome]
    movzx edx, byte [rdx + rcx]
    shl edx, 4
    lea r14, [biomes]
    add r14, rdx
    movzx edx, byte [r14 + BI_TREE]
    test edx, edx
    jz .next
    movzx edx, word [r14 + BI_DENSITY]
    movzx eax, ax
    cmp eax, edx
    jae .next
    ; find ground
    shl ecx, 8
    mov rbx, [g_blocks]
    add rbx, rcx                    ; column
    mov r15d, 250
.scan:
    movzx eax, byte [rbx + r15]
    test eax, eax
    jnz .found
    dec r15d
    jnz .scan
    jmp .next
.found:
    cmp r15d, 230
    ja .next
    movzx ecx, byte [r14 + BI_TREE]
    cmp ecx, T_CACTUS
    je .cactus
    cmp al, [r14 + BI_TOP]
    jne .next
    mov eax, [rsp]
    shr eax, 16
    cmp ecx, T_PINE
    je .pine
    cmp ecx, T_JUNGLE
    je .jungle
    ; apple tree: trunk 4-6, round crown
    xor edx, edx
    mov ecx, 3
    div ecx
    lea eax, [rdx + 4]
    mov [rsp + 4], eax
    mov dword [rsp + 8], B_LOG
    call .trunk
    mov ebx, -2
.al:
    mov ecx, 2
    cmp ebx, 1
    jne .alr
    mov ecx, 1
.alr:
    mov edi, r13d
    mov esi, r15d
    add esi, [rsp + 4]
    add esi, ebx
    mov edx, r12d
    mov r8d, B_LEAVES
    xor r9d, r9d
    call mg_layer
    inc ebx
    cmp ebx, 1
    jle .al
    jmp .next
.pine:
    ; pine: trunk 6-9, needle cone
    xor edx, edx
    mov ecx, 4
    div ecx
    lea eax, [rdx + 6]
    mov [rsp + 4], eax
    mov dword [rsp + 8], B_PINELOG
    call .trunk
    mov edi, r13d
    mov esi, r15d
    add esi, [rsp + 4]
    inc esi
    mov edx, r12d
    xor ecx, ecx
    mov r8d, B_PINENEEDLES
    mov r9d, 1
    call mg_layer                   ; tip
    xor ebx, ebx                    ; layer k
.pl:
    mov ecx, 1
    test ebx, 1
    jnz .plr
    mov ecx, ebx
    shr ecx, 1
    inc ecx
    cmp ecx, 2
    jbe .plr
    mov ecx, 2
.plr:
    mov edi, r13d
    mov esi, r15d
    add esi, [rsp + 4]
    sub esi, ebx
    mov edx, r12d
    mov r8d, B_PINENEEDLES
    mov r9d, 1
    call mg_layer
    inc ebx
    mov eax, [rsp + 4]
    sub eax, 2
    cmp ebx, eax
    jl .pl
    jmp .next
.jungle:
    xor edx, edx
    mov ecx, 4
    div ecx
    lea eax, [rdx + 8]
    mov [rsp + 4], eax
    mov dword [rsp + 8], B_LOG
    call .trunk
    mov ebx, -2
.jl:
    mov eax, ebx
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, 3
    sub ecx, eax                    ; radius 1,2,3,2,1
    mov edi, r13d
    mov esi, r15d
    add esi, [rsp + 4]
    add esi, ebx
    mov edx, r12d
    mov r8d, B_LEAVES
    xor r9d, r9d
    call mg_layer
    inc ebx
    cmp ebx, 2
    jle .jl
    jmp .next
.cactus:
    cmp al, B_DSAND
    jne .next
    mov eax, [rsp]
    shr eax, 16
    xor edx, edx
    mov ecx, 3
    div ecx
    lea eax, [rdx + 2]
    mov [rsp + 4], eax
    mov dword [rsp + 8], B_CACTUS
    call .trunk
.next:
    inc r13d
    cmp r13d, 13
    jbe .lx
    inc r12d
    cmp r12d, 13
    jbe .lz
    LEAVE_FN

; trunk of height [rsp+4] (caller's locals, +8 here) and block [rsp+8]
.trunk:
    push rbx
    mov ebx, 1
.tl:
    mov edi, r13d
    lea esi, [r15 + rbx]
    mov edx, r12d
    mov ecx, [rsp + 24]
    mov r8d, 1
    call mg_put
    inc ebx
    cmp ebx, [rsp + 20]
    jle .tl
    pop rbx
    ret

; ---------------------------------------------------------------------------
; Far terrain for the horizon: surface height and top block of each 8x8
; node cell of a 256x256 tile, 34 x 34 cells (one extra all round so the
; mesh can build walls at the tile edges). No caves, trees or ores: only
; what can be seen from far away.
; void mapgen_horizon_tile(int tx, int tz, int seed, s16 *heights,
;                          u8 *tops, u64 *cols)
; heights: top of the solid stack standing on the ground (floating parts
; left out); tops: block id, bit 7 = forest; cols: u32 mask of solid
; mountain levels above the ground (bit k = y -64 + 8k .. +8), then s16
; ground height (top solid node without mountains).
; locals: [0] fx, [4] fz, [8] mount height, [12] heat, [16] top, [20] cell,
;         [24] base x, [28] base z, [32] heights, [40] tops, [48] mask,
;         [52] ground, [56] cols, [64] level centre y
HZ_CELLS    equ 34
mapgen_horizon_tile:
    ENTER_FN 80
    shl edi, 8
    mov [rsp + 24], edi
    shl esi, 8
    mov [rsp + 28], esi
    mov [g_seed], edx
    mov [rsp + 32], rcx
    mov [rsp + 40], r8
    mov [rsp + 56], r9
    cmp dword [mapgen_flat], 0
    je .natural
    ; flat world: the same grass floor all the way out
    xor eax, eax
.flat:
    mov rsi, [rsp + 32]
    mov word [rsi + rax*2], WORLD_YMIN + 3
    mov rsi, [rsp + 40]
    mov byte [rsi + rax], B_GRASS
    mov rsi, [rsp + 56]
    mov dword [rsi + rax*8], 0
    mov dword [rsi + rax*8 + 4], WORLD_YMIN + 3
    inc eax
    cmp eax, HZ_CELLS * HZ_CELLS
    jb .flat
    LEAVE_FN
.natural:
    mov dword [rsp + 20], 0
.cell:
    ; centre of cell (i, j), i and j from -1
    mov eax, [rsp + 20]
    xor edx, edx
    mov ecx, HZ_CELLS
    div ecx                         ; eax = j + 1, edx = i + 1
    lea edx, [rdx*8 - 4]
    add edx, [rsp + 24]
    cvtsi2ss xmm0, edx
    movss [rsp], xmm0
    movss [g_fx], xmm0
    lea eax, [rax*8 - 4]
    add eax, [rsp + 28]
    cvtsi2ss xmm1, eax
    movss [rsp + 4], xmm1
    movss [g_fz], xmm1
    call mg_surface_at
    cvttss2si eax, xmm0
    mov [rsp + 16], eax
    ; rivers cut down to the water
    F2 np_ridge_uwater
    andps xmm0, [f_absmask]
    addss xmm0, xmm0
    comiss xmm0, [f_river_hz]
    ja .noriver
    cmp dword [rsp + 16], 30
    jg .noriver
    mov dword [rsp + 16], -2
.noriver:
    mov eax, [rsp + 16]
    mov [rsp + 52], eax             ; ground
    mov dword [rsp + 48], 0
    ; mountains: every 8-node level above the ground whose centre has
    ; positive density (Luanti: mountain noise - y / mountain height >= 0)
    F2 np_mount_height
    maxss xmm0, [f_one]
    movss [rsp + 8], xmm0
    mulss xmm0, [f_mntlim]
    cvttss2si ebx, xmm0             ; nothing above this y
    mov r12d, [rsp + 16]
    add r12d, 1 - WORLD_YMIN
    sar r12d, 3                     ; level holding the first node above ground
    test r12d, r12d
    jns .lev
    xor r12d, r12d
.lev:
    cmp r12d, 31
    ja .levdone
    lea eax, [r12*8 + WORLD_YMIN + 4]
    cmp eax, ebx
    jg .levdone
    cmp eax, [rsp + 16]
    jle .levnext
    mov [rsp + 64], eax
    F3 np_mountain, eax
    cvtsi2ss xmm1, dword [rsp + 64]
    divss xmm1, [rsp + 8]
    subss xmm0, xmm1
    comiss xmm0, [f_zero]
    jb .levnext
    bts dword [rsp + 48], r12d
.levnext:
    inc r12d
    jmp .lev
.levdone:
    ; height for the far terrain: the stack connected to the ground
    mov eax, [rsp + 16]
.stack:
    lea ecx, [rax + 1 - WORLD_YMIN]
    sar ecx, 3
    cmp ecx, 31
    ja .stacked
    bt dword [rsp + 48], ecx
    jnc .stacked
    lea eax, [rcx*8 + WORLD_YMIN + 7]
    jmp .stack
.stacked:
    mov [rsp + 16], eax
    ; biome
    F2 np_heat
    movss [rsp + 12], xmm0
    F2 np_heat_blend
    addss xmm0, [rsp + 12]
    movss [rsp + 12], xmm0
    F2 np_humidity
    movss [rsp + 8], xmm0
    F2 np_humidity_blend
    addss xmm0, [rsp + 8]
    movss xmm1, [rsp + 12]
    movss xmm4, [f_big]
    xor eax, eax
    xor ecx, ecx
    lea rsi, [biomes]
.bl:
    movaps xmm2, xmm1
    subss xmm2, [rsi + BI_HEAT]
    mulss xmm2, xmm2
    movaps xmm3, xmm0
    subss xmm3, [rsi + BI_HUM]
    mulss xmm3, xmm3
    addss xmm2, xmm3
    comiss xmm2, xmm4
    jae .bn
    movaps xmm4, xmm2
    mov eax, ecx
.bn:
    add rsi, BI_SIZE
    inc ecx
    cmp ecx, NUM_BIOMES
    jb .bl
    shl eax, 4
    lea r14, [biomes]
    add r14, rax
    ; top block
    mov eax, [rsp + 16]
    cmp eax, WATER_LEVEL
    jge .land
    mov ecx, B_WATER
    jmp .store
.land:
    cmp eax, WATER_LEVEL + 2
    jg .notshore
    movzx ecx, byte [r14 + BI_SHORE]
    jmp .store
.notshore:
    cmp eax, SNOWLINE
    jl .normal
    lea rdx, [biomes + BIOME_DESERT * BI_SIZE]
    cmp r14, rdx
    je .normal
    mov ecx, B_SNOW
    jmp .store
.normal:
    movzx ecx, byte [r14 + BI_TOP]
    cmp word [r14 + BI_DENSITY], 1000
    jb .store
    or ecx, 0x80                    ; forest canopy
.store:
    mov edx, [rsp + 20]
    mov rsi, [rsp + 40]
    mov [rsi + rdx], cl
    mov rsi, [rsp + 32]
    mov [rsi + rdx*2], ax
    mov rsi, [rsp + 56]
    mov ecx, [rsp + 48]
    mov [rsi + rdx*8], ecx
    mov ecx, [rsp + 52]
    mov [rsi + rdx*8 + 4], ecx
    inc dword [rsp + 20]
    cmp dword [rsp + 20], HZ_CELLS * HZ_CELLS
    jb .cell
    LEAVE_FN

; ---------------------------------------------------------------------------
; Bedrock floor (solid at the bottom, ragged above) and ore veins that
; replace stone (clay replaces sand under shallow water). locals: [0] lx, [4] y index, [8] lz, [12] rng, [16] steps
mg_ores:
    ENTER_FN 32
    xor r12d, r12d
.bcol:
    mov r13, r12
    shl r13, 8
    add r13, [g_blocks]
    mov byte [r13], B_BEDROCK
    mov edi, r12d
    and edi, 15
    add edi, [g_bx]
    mov esi, r12d
    shr esi, 4
    add esi, [g_bz]
    mov edx, [g_seed]
    add edx, 991
    call mg_thash
    test eax, 1
    jz .b2
    mov byte [r13 + 1], B_BEDROCK
.b2:
    test eax, 6
    jnz .bn
    mov byte [r13 + 2], B_BEDROCK
.bn:
    inc r12d
    cmp r12d, 256
    jb .bcol

    lea rbx, [ore_table]
.ore:
    movzx eax, byte [rbx]
    test eax, eax
    jz .done
    movzx r15d, byte [rbx + 3]      ; the block it replaces
    test r15d, r15d
    jnz .wherein
    mov r15d, B_STONE
.wherein:
    xor r14d, r14d                  ; vein number
.vein:
    movzx eax, byte [rbx + 1]
    cmp r14d, eax
    jae .next_ore
    imul edi, r14d, 31
    add edi, [g_bx]
    movzx eax, byte [rbx]
    imul eax, eax, 7
    add edi, eax
    imul esi, r14d, -17
    add esi, [g_bz]
    movzx edx, byte [rbx]
    imul edx, edx, 1013
    add edx, [g_seed]
    call mg_thash
    mov [rsp + 12], eax
    mov ecx, eax
    and ecx, 15
    mov [rsp], ecx
    mov ecx, eax
    shr ecx, 4
    and ecx, 15
    mov [rsp + 8], ecx
    shr eax, 8
    and eax, 0xffff
    xor edx, edx
    div dword [rbx + 8]
    add edx, [rbx + 4]
    mov [rsp + 4], edx
    movzx eax, byte [rbx + 2]
    mov [rsp + 16], eax
.step:
    ; place if inside the chunk and on the block it replaces
    mov eax, [rsp]
    cmp eax, 15
    ja .move
    mov ecx, [rsp + 8]
    cmp ecx, 15
    ja .move
    mov edx, [rsp + 4]
    cmp edx, 3
    jb .move
    cmp edx, 255
    ja .move
    ; veins in other blocks than stone stay inside their depth range
    cmp r15d, B_STONE
    je .inrange
    mov r9d, edx
    sub r9d, [rbx + 4]
    cmp r9d, [rbx + 8]
    jae .move
.inrange:
    shl ecx, 12
    shl eax, 8
    or eax, ecx
    or eax, edx
    mov r8, [g_blocks]
    cmp [r8 + rax], r15b
    jne .move
    mov cl, [rbx]
    mov [r8 + rax], cl
.move:
    mov eax, [rsp + 12]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [rsp + 12], eax
    shr eax, 16
    xor edx, edx
    mov ecx, 6
    div ecx
    cmp edx, 0
    jne .m1
    inc dword [rsp]
.m1:
    cmp edx, 1
    jne .m2
    dec dword [rsp]
.m2:
    cmp edx, 2
    jne .m3
    inc dword [rsp + 4]
.m3:
    cmp edx, 3
    jne .m4
    dec dword [rsp + 4]
.m4:
    cmp edx, 4
    jne .m5
    inc dword [rsp + 8]
.m5:
    cmp edx, 5
    jne .m6
    dec dword [rsp + 8]
.m6:
    dec dword [rsp + 16]
    jnz .step
    inc r14d
    jmp .vein
.next_ore:
    add rbx, ORE_SIZE
    jmp .ore
.done:
    LEAVE_FN

; ---------------------------------------------------------------------------
; Heightmap (top opaque node + 1) and highest non-air node of the chunk.
mg_heightmap:
    xor r8d, r8d                    ; max y
    xor ecx, ecx                    ; column
    mov r9, [g_blocks]
    mov r10, [g_hmap]
    lea r11, [block_flags]
.col:
    mov rsi, rcx
    shl rsi, 8
    add rsi, r9
    mov edx, 255
    xor edi, edi                    ; found non-air yet
.y:
    movzx eax, byte [rsi + rdx]
    test eax, eax
    jz .air
    test edi, edi
    jnz .chk
    mov edi, 1
    cmp edx, r8d
    jbe .chk
    mov r8d, edx
.chk:
    test byte [r11 + rax], F_OPAQUE
    jz .air
    lea eax, [rdx + 1]
    mov [r10 + rcx*2], ax
    jmp .colnext
.air:
    dec edx
    jns .y
    mov word [r10 + rcx*2], 0
.colnext:
    inc ecx
    cmp ecx, 256
    jb .col
    mov eax, r8d
    ret

; ---------------------------------------------------------------------------
; The nether: netherrack with big rounded caverns between a bedrock floor
; (y -64) and a bedrock roof (y 63), a lava sea below y -32, nothing above
; the roof. Density is 3D noise sampled every 4 nodes and blended between.
; The heightmap is all 0 (no sky: every face counts as near the surface).

; int nether_chunk(u8 *blocks, u16 *hmap, int cx, int cz, int seed)
; locals: [0] first noise, [8] fx, [12] fz, [16] column, [20] x, [24] z
nether_chunk:
    ENTER_FN 32
    mov [g_blocks], rdi
    mov [g_hmap], rsi
    shl edx, 4
    mov [g_bx], edx
    shl ecx, 4
    mov [g_bz], ecx
    mov [g_seed], r8d
    xor eax, eax
    mov ecx, CHUNK_VOX
    rep stosb                       ; all air
    ; density on the 5 x 5 x 33 grid
    xor r12d, r12d                  ; ix
.gx:
    xor r13d, r13d                  ; iz
.gz:
    xor r14d, r14d                  ; iy
.gy:
%macro NETHER_NOISE 3               ; xz scale, y scale, seed offset -> xmm0
    lea eax, [r12*4]
    add eax, [g_bx]
    cvtsi2ss xmm0, eax
    mulss xmm0, [%1]
    lea eax, [r14*4]
    cvtsi2ss xmm1, eax
    mulss xmm1, [%2]
    lea eax, [r13*4]
    add eax, [g_bz]
    cvtsi2ss xmm2, eax
    mulss xmm2, [%1]
    mov edi, [g_seed]
    add edi, %3
    mov esi, 1
    call noise3d_value
%endmacro
    NETHER_NOISE f_nxz1, f_ny1, 1011
    movss [rsp], xmm0
    NETHER_NOISE f_nxz2, f_ny2, 2022
    mulss xmm0, [f_nhalf]
    addss xmm0, [rsp]
    ; closing in toward the floor and the roof
    lea eax, [r14*4]
    cvtsi2ss xmm1, eax
    movss xmm2, [f_nfloor]
    subss xmm2, xmm1
    maxss xmm2, [f_zero]
    mulss xmm2, [f_nwall]
    addss xmm0, xmm2
    movaps xmm2, xmm1
    subss xmm2, [f_nroof]
    maxss xmm2, [f_zero]
    mulss xmm2, [f_nwall]
    addss xmm0, xmm2
    subss xmm0, [f_nopen]
    imul eax, r12d, 5
    add eax, r13d
    imul eax, eax, 33
    add eax, r14d
    lea rcx, [nd_grid]
    movss [rcx + rax*4], xmm0
    inc r14d
    cmp r14d, 33
    jb .gy
    inc r13d
    cmp r13d, 5
    jb .gz
    inc r12d
    cmp r12d, 5
    jb .gx

    ; columns
    xor r15d, r15d                  ; column (lz << 4 | lx)
.col:
    mov eax, r15d
    and eax, 15
    mov [rsp + 20], eax
    mov ecx, eax
    and ecx, 3
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_quarter]
    movss [rsp + 8], xmm0           ; fx
    shr eax, 2
    mov r12d, eax                   ; ix
    mov eax, r15d
    shr eax, 4
    mov [rsp + 24], eax
    mov ecx, eax
    and ecx, 3
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_quarter]
    movss [rsp + 12], xmm0          ; fz
    shr eax, 2
    mov r13d, eax                   ; iz
    ; the 33 samples of this column, blended across x and z
    imul eax, r12d, 5
    add eax, r13d
    imul eax, eax, 33
    lea r8, [nd_grid]
    lea r8, [r8 + rax*4]            ; g00
    lea r9, [r8 + 5 * 33 * 4]       ; g10 (ix + 1)
    lea r10, [r8 + 33 * 4]          ; g01 (iz + 1)
    lea r11, [r9 + 33 * 4]          ; g11
    xor ecx, ecx
.cs:
    movss xmm0, [r8 + rcx*4]
    movss xmm1, [r9 + rcx*4]
    subss xmm1, xmm0
    mulss xmm1, [rsp + 8]
    addss xmm0, xmm1                ; along x at z0
    movss xmm2, [r10 + rcx*4]
    movss xmm3, [r11 + rcx*4]
    subss xmm3, xmm2
    mulss xmm3, [rsp + 8]
    addss xmm2, xmm3                ; along x at z1
    subss xmm2, xmm0
    mulss xmm2, [rsp + 12]
    addss xmm0, xmm2
    lea rax, [nd_col]
    movss [rax + rcx*4], xmm0
    inc ecx
    cmp ecx, 33
    jb .cs
    ; the nodes, y index 0..127
    mov rbx, r15
    shl rbx, 8
    add rbx, [g_blocks]
    xor r14d, r14d                  ; y
.y:
    ; bedrock: the floor and the roof, ragged on their inner 3 nodes
    mov eax, r14d
    cmp eax, 64
    jb .low
    mov eax, 127
    sub eax, r14d                   ; distance from the roof
.low:
    cmp eax, 3
    ja .dens
    test eax, eax
    jz .bedrock
    mov ecx, [rsp + 20]
    add ecx, [g_bx]
    imul ecx, ecx, 73856093
    mov edx, [rsp + 24]
    add edx, [g_bz]
    imul edx, edx, 83492791
    xor ecx, edx
    imul edx, r14d, 19349663
    xor ecx, edx
    shr ecx, 13
    and ecx, 3
    cmp ecx, eax
    jb .dens
.bedrock:
    mov byte [rbx + r14], B_BEDROCK
    jmp .ynext
.dens:
    mov eax, r14d
    shr eax, 2
    mov ecx, r14d
    and ecx, 3
    cvtsi2ss xmm1, ecx
    mulss xmm1, [f_quarter]
    lea rcx, [nd_col]
    movss xmm0, [rcx + rax*4]
    movss xmm2, [rcx + rax*4 + 4]
    subss xmm2, xmm0
    mulss xmm2, xmm1
    addss xmm0, xmm2
    comiss xmm0, [f_zero]
    jbe .open
    mov byte [rbx + r14], B_NETHERRACK
    jmp .ynext
.open:
    cmp r14d, NETHER_SEA
    jae .ynext
    mov byte [rbx + r14], B_LAVA
.ynext:
    inc r14d
    cmp r14d, 128
    jb .y
    inc r15d
    cmp r15d, 256
    jb .col
    mov rdi, [g_blocks]
    mov rsi, [g_hmap]
    call nether_finish
    LEAVE_FN

; int nether_finish(u8 *blocks, u16 *hmap) - after loading a nether chunk:
; the highest y index in use, and the heightmap all 0
nether_finish:
    sub rsp, 8
    mov [g_blocks], rdi
    mov [g_hmap], rsi
    call mg_heightmap
    mov rdi, [g_hmap]
    mov ecx, 256
    push rax
    xor eax, eax
    rep stosw
    pop rax
    add rsp, 8
    ret

NOEXECSTACK
