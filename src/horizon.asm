; horizon.asm - far terrain beyond the real chunks, Distant-Horizons style.
;
; Only the chunks within REAL CHUNKS of the player are the actual game.
; Out to HORIZON (32-64 chunks) the world is shown as a light shell built
; straight from the v7 noise: each 256x256 tile is a 32x32 grid of 8-node
; cells (16-node cells further away). Cell corners average the heights
; around them, so the far land is a smooth sloped surface, coloured by
; the top block (its side colour on cliffs), shaded by slope and jittered
; per cell. Skirts hang from tile edges to hide cracks between levels of
; detail.
; Nothing out there is stored as blocks, simulated or lit.
;
; Tile data comes from the world-gen thread (mapgen_horizon_tile); meshes
; are built here on the main thread. Cells over the real chunks are left
; out, and tiles along that edge are rebuilt as the player moves.

%include "common.inc"

global horizon_update, horizon_draw, horizon_reset, horizon_finish
global horizon_dist, hz_heights, hz_tops, hz_cols, horizon_tile_count, horizon_remesh
global horizon_cube_verts

extern set_horizon, set_range, cur_pcx, cur_pcz, spiral_r2, seed, threaded
extern dimension
extern worker_submit_horizon, mapgen_horizon_tile
extern vbo_ok, p_genbuf, p_bindbuf, p_bufdata, client_pointers, unbind_vbo
extern tint_begin, world_tex_end, frustum_box, stat_verts, world_tex_begin
extern build_cubes, cz_buf, cz_n, cube_r1sq, cube_r2sq
extern realloc
extern glPushMatrix, glPopMatrix, glTranslatef, glDrawArrays, glEnable
extern glDisable

HZ_SLOTS    equ 256                 ; 16 x 16 ring of tiles
HZ_MASK     equ 15
HZ_CELLS    equ 34                  ; 32 + a border cell each side
HZ_DATA     equ HZ_CELLS * HZ_CELLS
TILE_CHUNKS equ 16                  ; a tile is 16 x 16 chunks
HZ_MAXV     equ 32768               ; vertices per tile mesh
GL_QUADS    equ 0x0007
GL_CULL_FACE equ 0x0B44
GL_DEPTH_TEST equ 0x0B71
GL_ALPHA_TEST equ 0x0BC0
GL_BLEND    equ 0x0BE2
GL_ARRAY_BUFFER equ 0x8892
GL_STATIC_DRAW equ 0x88E4

HS_EMPTY    equ 0
HS_PENDING  equ 1
HS_READY    equ 2

section .rodata
align 4
hz_chunks:  dd 0, 32, 48, 64
f_tile8:    dd 2048.0               ; a tile in 1/8 node units
f_tile:     dd 256.0
f_ymin:     dd -64.0
f_yspan:    dd 256.0
forest_rgb: db 48, 106, 42

section .data
align 4
; filled once by horizon_reset: block id -> colours (r, g, b top; r, g, b side)
hz_pal_init: dd 0

section .bss
alignb 16
hz_heights: resw HZ_SLOTS * HZ_DATA
hz_tops:    resb HZ_SLOTS * HZ_DATA
hz_cols:    resq HZ_SLOTS * HZ_DATA     ; per cell: mountain level mask, ground
hz_state:   resb HZ_SLOTS
hz_meshed:  resb HZ_SLOTS
hz_lod:     resb HZ_SLOTS
alignb 4
hz_tx:      resd HZ_SLOTS
hz_tz:      resd HZ_SLOTS
hz_bpcx:    resd HZ_SLOTS           ; player chunk the mesh was built for
hz_bpcz:    resd HZ_SLOTS
; two meshes per tile: [slot] the smooth shell, [HZ_SLOTS + slot] the cubes
hz_nverts:  resd HZ_SLOTS * 2
hz_vbo:     resd HZ_SLOTS * 2
hz_cap:     resd HZ_SLOTS * 2
alignb 8
hz_ptr:     resq HZ_SLOTS * 2
pal:        resb 256 * 8            ; colours per top block
cell_top8:  resd 34 * 34            ; per mesh cell: top in 1/8 nodes
cell_col:   resb 34 * 34            ; top block (with forest bit)
cell_out:   resb 34 * 34            ; 1 = over the real chunks
alignb 4
corner8:    resd 33 * 33            ; per cell corner: height in 1/8 nodes
corner_sh:  resd 33 * 33            ; per cell corner: shade (256 = 1)
mix_rgb:    resb 4                  ; forest colour of the current cell
alignb 16
hz_buf:     resb HZ_MAXV * VERT_SIZE
hz_n:       resd 1
horizon_dist: resd 1                ; nodes, for fog (0 = off)
horizon_tile_count: resd 1          ; tiles drawn last frame
horizon_cube_verts: resd 1          ; cube-ring vertices drawn last frame
hz_r2:      resd 1                  ; chunks: smooth shell beyond, cubes inside
vbo_ready:  resd 1

section .text

; palette entry: block, top rgb, cliff rgb
%macro SETPAL 7
    lea rax, [pal + %1 * 8]
    mov byte [rax], %2
    mov byte [rax + 1], %3
    mov byte [rax + 2], %4
    mov byte [rax + 3], %5
    mov byte [rax + 4], %6
    mov byte [rax + 5], %7
%endmacro

; void horizon_reset(void) - forget every tile (new world or new range)
horizon_reset:
    lea rdi, [hz_state]
    xor eax, eax
    mov ecx, HZ_SLOTS * 3
    rep stosb
    cmp dword [hz_pal_init], 0
    jne .out
    mov dword [hz_pal_init], 1
    lea rdi, [pal]
    mov al, 120
    mov ecx, 256 * 8
    rep stosb
    SETPAL B_STONE,    128, 128, 128, 110, 110, 110
    SETPAL B_DIRT,     134,  96,  67, 120,  86,  60
    SETPAL B_GRASS,     90, 150,  60, 116, 108,  96
    SETPAL B_SAND,     219, 207, 163, 200, 188, 148
    SETPAL B_WATER,     40,  90, 200,  40,  90, 200
    SETPAL B_SNOWDIRT, 240, 245, 250, 150, 150, 156
    SETPAL B_DSAND,    210, 160, 110, 170, 100,  70
    SETPAL B_DRYGRASS, 170, 160,  80, 140, 120,  96
    SETPAL B_GRAVEL,   130, 125, 120, 115, 110, 105
    SETPAL B_SNOW,     240, 245, 250, 128, 128, 128
.out:
    ret

; void horizon_remesh(void) - keep the tiles, rebuild their meshes (the
; real-chunk radius changed)
horizon_remesh:
    lea rdi, [hz_meshed]
    xor eax, eax
    mov ecx, HZ_SLOTS
    rep stosb
    ret

; void horizon_finish(int slot, int tx, int tz) - a tile came back from
; the world-gen thread
horizon_finish:
    mov edi, edi
    lea rax, [hz_state]
    cmp byte [rax + rdi], HS_PENDING
    jne .out
    lea rcx, [hz_tx]
    cmp [rcx + rdi*4], esi
    jne .stale
    lea rcx, [hz_tz]
    cmp [rcx + rdi*4], edx
    jne .stale
    mov byte [rax + rdi], HS_READY
    lea rcx, [hz_meshed]
    mov byte [rcx + rdi], 0
    ret
.stale:
    mov byte [rax + rdi], HS_EMPTY
.out:
    ret

; eax = 1 if tile (edi, esi) has a chunk within the horizon radius,
; ecx = squared chunk distance of its nearest chunk
tile_in_range:
    mov eax, edi
    shl eax, 4                      ; first chunk x
    mov ecx, [cur_pcx]
    cmp ecx, eax
    jl .x0
    lea edx, [rax + TILE_CHUNKS - 1]
    cmp ecx, edx
    jle .xin
    mov eax, edx
    jmp .x0
.xin:
    mov eax, ecx
.x0:
    sub eax, [cur_pcx]
    imul eax, eax
    mov r8d, eax
    mov eax, esi
    shl eax, 4
    mov ecx, [cur_pcz]
    cmp ecx, eax
    jl .z0
    lea edx, [rax + TILE_CHUNKS - 1]
    cmp ecx, edx
    jle .zin
    mov eax, edx
    jmp .z0
.zin:
    mov eax, ecx
.z0:
    sub eax, [cur_pcz]
    imul eax, eax
    add r8d, eax
    mov ecx, r8d
    mov eax, [set_horizon]
    lea rdx, [hz_chunks]
    mov eax, [rdx + rax*4]
    imul eax, eax
    cmp ecx, eax
    setle al
    movzx eax, al
    ret

; ---------------------------------------------------------------------------
; mesh building

; append a vertex: eax x, ecx y, edx z (1/8 nodes), r9d colour
; (clobbers r8, r11)
hz_vert:
    mov r11d, [hz_n]
    shl r11d, 4
    lea r8, [hz_buf]
    add r8, r11
    mov [r8], ax
    mov [r8 + 2], cx
    mov [r8 + 4], dx
    mov word [r8 + 6], 0
    mov dword [r8 + 8], 0
    mov [r8 + 12], r9d
    inc dword [hz_n]
    ret

; eax = colour dword: rgb at r10 times shade ecx / 256 (clobbers ecx,
; edx, r11)
hz_colour:
    cmp ecx, 60
    jge .lo
    mov ecx, 60
.lo:
    xor eax, eax
    mov r11d, 2
.ch:
    movzx edx, byte [r10 + r11]
    imul edx, ecx
    shr edx, 8
    cmp edx, 255
    jbe .ok
    mov edx, 255
.ok:
    shl eax, 8
    or eax, edx
    dec r11d
    jns .ch
    or eax, 0xff000000
    ret

; build_tile(edi slot) - mesh the tile's cells into hz_buf and upload it
; locals: [0] lod (cells per mesh cell), [4] cells per side, [8] cell size
;         (1/8 nodes), [12] quad corners (48 bytes), [64] tile chunk x,
;         [68] tile chunk z, [72] slot, [76] i, [80] j
build_tile:
    ENTER_FN 96
    mov [rsp + 72], edi
    mov r12d, edi
    lea rax, [hz_tx]
    mov eax, [rax + r12*4]
    shl eax, 4
    mov [rsp + 64], eax
    lea rax, [hz_tz]
    mov eax, [rax + r12*4]
    shl eax, 4
    mov [rsp + 68], eax
    ; the smooth shell: 16-node cells (one per chunk); the cube rings
    ; inside it come from build_cubes
    mov eax, 2
    mov [rsp], eax
    lea rcx, [hz_lod]
    mov [rcx + r12], al
    mov ecx, 32
    xor edx, edx
    mov ebx, eax
    mov eax, ecx
    div ebx
    mov [rsp + 4], eax              ; mesh cells per side
    mov eax, ebx
    shl eax, 6                      ; 8 nodes * 8 per lod step
    mov [rsp + 8], eax

    ; ---- per mesh cell (with a border ring): top, colour, excluded
    lea r13, [hz_heights]
    imul eax, r12d, HZ_DATA * 2
    add r13, rax
    lea r14, [hz_tops]
    imul eax, r12d, HZ_DATA
    add r14, rax
    mov dword [rsp + 80], -1        ; j
.cj:
    mov eax, [rsp + 80]
    cmp eax, [rsp + 4]
    jg .cells_done
    mov dword [rsp + 76], -1        ; i
.ci:
    mov eax, [rsp + 76]
    cmp eax, [rsp + 4]
    jg .cj_next
    ; data cell of this mesh cell's corner (clamped to the border ring)
    mov ecx, [rsp + 76]
    imul ecx, ebx
    inc ecx
    mov edx, [rsp + 80]
    imul edx, ebx
    inc edx
    test ecx, ecx
    jns .c0
    xor ecx, ecx
.c0:
    cmp ecx, HZ_CELLS - 1
    jle .c1
    mov ecx, HZ_CELLS - 1
.c1:
    test edx, edx
    jns .c1b
    xor edx, edx
.c1b:
    cmp edx, HZ_CELLS - 1
    jle .c2
    mov edx, HZ_CELLS - 1
.c2:
    imul edx, edx, HZ_CELLS
    add edx, ecx                    ; data index
    movsx eax, word [r13 + rdx*2]
    movzx ecx, byte [r14 + rdx]
    ; with 2x2 cells take the highest of the four
    cmp ebx, 1
    je .one
    mov r8d, [rsp + 76]
    test r8d, r8d
    js .one
    cmp r8d, [rsp + 4]
    jge .one
    mov r8d, [rsp + 80]
    test r8d, r8d
    js .one
    cmp r8d, [rsp + 4]
    jge .one
%macro HIGHER 1
    movsx r8d, word [r13 + rdx*2 + %1 * 2]
    cmp r8d, eax
    jle %%k
    mov eax, r8d
    movzx ecx, byte [r14 + rdx + %1]
%%k:
%endmacro
    HIGHER 1
    HIGHER HZ_CELLS
    HIGHER HZ_CELLS + 1
.one:
    ; mesh cell index in the 34-wide work arrays
    mov edx, [rsp + 80]
    inc edx
    imul edx, edx, 34
    add edx, [rsp + 76]
    inc edx
    lea r8, [cell_col]
    mov [r8 + rdx], cl
    ; top in 1/8 nodes: water sits at 1 7/8
    mov r9d, 15
    mov r10d, ecx
    and r10d, 0x7f
    cmp r10d, B_WATER
    je .t8
    lea r9d, [rax + 1]
    shl r9d, 3
.t8:
    lea r8, [cell_top8]
    mov [r8 + rdx*4], r9d
    ; over the real chunks?
    mov eax, [rsp + 76]
    imul eax, [rsp + 8]
    mov ecx, [rsp + 8]
    shr ecx, 1
    add eax, ecx                    ; cell centre x in 1/8 nodes
    sar eax, 7                      ; -> chunk (128 per chunk)
    add eax, [rsp + 64]
    sub eax, [cur_pcx]
    imul eax, eax
    mov r8d, eax
    mov eax, [rsp + 80]
    imul eax, [rsp + 8]
    add eax, ecx
    sar eax, 7
    add eax, [rsp + 68]
    sub eax, [cur_pcz]
    imul eax, eax
    add eax, r8d
    xor ecx, ecx
    cmp eax, [cube_r2sq]            ; inside: real chunks or cubes
    ja .keep
    mov ecx, 1
.keep:
    lea r8, [cell_out]
    mov [r8 + rdx], cl
    inc dword [rsp + 76]
    jmp .ci
.cj_next:
    inc dword [rsp + 80]
    jmp .cj
.cells_done:

    ; ---- corner heights: the four cells around each corner averaged;
    ; corners touching water sit at the water surface so shores meet it
    mov ebx, [rsp + 4]              ; mesh cells per side (n)
    xor r15d, r15d                  ; corner j
.hj:
    xor r14d, r14d                  ; corner i
.hi:
    imul edx, r15d, 34
    add edx, r14d                   ; work index of cell (i - 1, j - 1)
    lea r8, [cell_top8]
    lea r9, [cell_col]
    xor eax, eax
    xor r10d, r10d                  ; 1 = touches water
%macro CSUM 1
    add eax, [r8 + rdx*4 + %1 * 4]
    movzx ecx, byte [r9 + rdx + %1]
    and ecx, 0x7f
    cmp ecx, B_WATER
    jne %%d
    mov r10d, 1
%%d:
%endmacro
    CSUM 0
    CSUM 1
    CSUM 34
    CSUM 35
    sar eax, 2
    test r10d, r10d
    jz .hset
    mov eax, 15
.hset:
    imul edx, r15d, 33
    add edx, r14d
    lea r8, [corner8]
    mov [r8 + rdx*4], eax
    inc r14d
    cmp r14d, ebx
    jle .hi
    inc r15d
    cmp r15d, ebx
    jle .hj

    ; ---- corner shade from the slope: lit from +x +z, steep is darker
    ; (sx, sz: rise per run, 256 = 45 degrees)
    xor r15d, r15d
.sj:
    xor r14d, r14d
.si:
    lea r8, [corner8]
    ; x slope between corners i - 1 and i + 1 (clamped to the tile)
    lea eax, [r14 - 1]
    test eax, eax
    jns .sx0
    xor eax, eax
.sx0:
    lea ecx, [r14 + 1]
    cmp ecx, ebx
    jle .sx1
    mov ecx, ebx
.sx1:
    mov r9d, ecx
    sub r9d, eax
    imul r9d, [rsp + 8]             ; run in 1/8 nodes
    imul edx, r15d, 33
    add eax, edx
    add ecx, edx
    mov eax, [r8 + rax*4]
    mov r10d, [r8 + rcx*4]
    sub r10d, eax
    shl r10d, 8
    mov eax, r10d
    cdq
    idiv r9d
    mov r12d, eax                   ; sx
    ; z slope between corners j - 1 and j + 1
    lea eax, [r15 - 1]
    test eax, eax
    jns .sz0
    xor eax, eax
.sz0:
    lea ecx, [r15 + 1]
    cmp ecx, ebx
    jle .sz1
    mov ecx, ebx
.sz1:
    mov r9d, ecx
    sub r9d, eax
    imul r9d, [rsp + 8]
    imul eax, eax, 33
    add eax, r14d
    imul ecx, ecx, 33
    add ecx, r14d
    mov eax, [r8 + rax*4]
    mov r10d, [r8 + rcx*4]
    sub r10d, eax
    shl r10d, 8
    mov eax, r10d
    cdq
    idiv r9d
    mov r13d, eax                   ; sz
%macro CLAMP512 1
    cmp %1, 512
    jle %%a
    mov %1, 512
%%a:
    cmp %1, -512
    jge %%b
    mov %1, -512
%%b:
%endmacro
    CLAMP512 r12d
    CLAMP512 r13d
    ; shade = 240 - (3 sx + 2 sz) / 16 - (|sx| + |sz|) / 32
    lea eax, [r12 + r12*2]
    lea eax, [rax + r13*2]
    sar eax, 4
    mov ecx, 240
    sub ecx, eax
    mov eax, r12d
    cdq
    xor eax, edx
    sub eax, edx
    mov r10d, eax
    mov eax, r13d
    cdq
    xor eax, edx
    sub eax, edx
    add eax, r10d
    sar eax, 5
    sub ecx, eax
    imul edx, r15d, 33
    add edx, r14d
    lea r8, [corner_sh]
    mov [r8 + rdx*4], ecx
    inc r14d
    cmp r14d, ebx
    jle .si
    inc r15d
    cmp r15d, ebx
    jle .sj

    ; ---- one sloped quad per cell, skirts hanging from the tile edges and
    ; from the edge of the real chunks to hide cracks
    ; locals: [12] j, [16] i, [20] corner index, [24] jitter, [28] skirt
    ; colour, [32] colour pointer, [40] work index, [48] z0, [52] z1
    mov dword [hz_n], 0
    mov ebx, [rsp + 8]              ; cell size in 1/8 nodes
    xor r15d, r15d                  ; j
.qj:
    cmp r15d, [rsp + 4]
    jge .quads_done
    xor r14d, r14d                  ; i
.qi:
    cmp r14d, [rsp + 4]
    jge .qj_next
    lea edx, [r15 + 1]
    imul edx, edx, 34
    lea edx, [rdx + r14 + 1]
    mov [rsp + 40], edx
    lea rax, [cell_out]
    cmp byte [rax + rdx], 0
    jne .qi_next
    cmp dword [hz_n], HZ_MAXV - 20
    ja .quads_done
    imul eax, r15d, 33
    add eax, r14d
    mov [rsp + 20], eax
    ; colour: top block, its side colour on cliffs, leaves over forest
    lea rax, [cell_col]
    movzx edi, byte [rax + rdx]
    mov esi, edi
    and esi, 0x7f
    lea r10, [pal]
    lea r10, [r10 + rsi*8]
    cmp esi, B_WATER
    je .col
    mov eax, [rsp + 20]
    lea r8, [corner8]
    mov ecx, [r8 + rax*4]           ; lowest corner
    mov edx, ecx                    ; highest corner
%macro MINMAX 1
    mov r9d, [r8 + rax*4 + %1 * 4]
    cmp r9d, ecx
    cmovl ecx, r9d
    cmp r9d, edx
    cmovg edx, r9d
%endmacro
    MINMAX 1
    MINMAX 33
    MINMAX 34
    sub edx, ecx
    add edx, edx
    lea eax, [rbx + rbx*2]
    cmp edx, eax                    ; steeper than 1.5 nodes per node
    jbe .notcliff
    add r10, 3
    jmp .col
.notcliff:
    test edi, 0x80
    jz .col
    ; forest: leaves mixed with the ground showing between the trees
    lea rax, [forest_rgb]
    lea r11, [mix_rgb]
    xor ecx, ecx
.mix:
    movzx edx, byte [rax + rcx]
    imul edx, edx, 160
    movzx r9d, byte [r10 + rcx]
    imul r9d, r9d, 96
    add edx, r9d
    shr edx, 8
    mov [r11 + rcx], dl
    inc ecx
    cmp ecx, 3
    jb .mix
    mov r10, r11
.col:
    mov [rsp + 32], r10
    ; brightness jitter from the world position of the cell
    mov eax, r14d
    imul eax, [rsp]
    mov ecx, [rsp + 64]
    lea eax, [rax + rcx*2]
    imul eax, eax, 73856093
    mov ecx, r15d
    imul ecx, [rsp]
    mov edx, [rsp + 68]
    lea ecx, [rcx + rdx*2]
    imul ecx, ecx, 19349663
    xor eax, ecx
    imul eax, eax, 83492791
    shr eax, 27
    sub eax, 16
    cmp esi, B_WATER
    jne .jit
    sar eax, 1                      ; calmer on water
.jit:
    mov [rsp + 24], eax
    mov ecx, 150
    add ecx, eax
    call hz_colour
    mov [rsp + 28], eax
    ; corners
    mov r12d, r14d
    imul r12d, ebx                  ; x0
    lea r13d, [r12 + rbx]           ; x1
    mov eax, r15d
    imul eax, ebx
    mov [rsp + 48], eax             ; z0
    add eax, ebx
    mov [rsp + 52], eax             ; z1
%macro TOPV 3                       ; corner offset, x, z
    mov eax, [rsp + 20]
    add eax, %1
    lea r8, [corner_sh]
    mov ecx, [r8 + rax*4]
    add ecx, [rsp + 24]
    mov r10, [rsp + 32]
    call hz_colour
    mov r9d, eax
    mov eax, [rsp + 20]
    add eax, %1
    lea r8, [corner8]
    mov ecx, [r8 + rax*4]
    mov eax, %2
    mov edx, %3
    call hz_vert
%endmacro
    TOPV 0, r12d, [rsp + 48]
    TOPV 33, r12d, [rsp + 52]
    TOPV 34, r13d, [rsp + 52]
    TOPV 1, r13d, [rsp + 48]
%macro SKV 4                        ; corner offset, x, z, drop
    mov eax, [rsp + 20]
    add eax, %1
    lea r8, [corner8]
    mov ecx, [r8 + rax*4]
    sub ecx, %4
    mov eax, %2
    mov edx, %3
    mov r9d, [rsp + 28]
    call hz_vert
%endmacro
%macro SKIRT 6                      ; corner a, xa, za, corner b, xb, zb
    SKV %1, %2, %3, 0
    SKV %4, %5, %6, 0
    SKV %4, %5, %6, 256
    SKV %1, %2, %3, 256
%endmacro
    mov edx, [rsp + 40]
    lea rsi, [cell_out]
    test r14d, r14d
    jz .skx0
    cmp byte [rsi + rdx - 1], 0
    je .nox0
.skx0:
    SKIRT 0, r12d, [rsp + 48], 33, r12d, [rsp + 52]
.nox0:
    mov edx, [rsp + 40]
    lea rsi, [cell_out]
    lea eax, [r14 + 1]
    cmp eax, [rsp + 4]
    je .skx1
    cmp byte [rsi + rdx + 1], 0
    je .nox1
.skx1:
    SKIRT 1, r13d, [rsp + 48], 34, r13d, [rsp + 52]
.nox1:
    mov edx, [rsp + 40]
    lea rsi, [cell_out]
    test r15d, r15d
    jz .skz0
    cmp byte [rsi + rdx - 34], 0
    je .noz0
.skz0:
    SKIRT 0, r12d, [rsp + 48], 1, r13d, [rsp + 48]
.noz0:
    mov edx, [rsp + 40]
    lea rsi, [cell_out]
    lea eax, [r15 + 1]
    cmp eax, [rsp + 4]
    je .skz1
    cmp byte [rsi + rdx + 34], 0
    je .qi_next
.skz1:
    SKIRT 33, r12d, [rsp + 52], 34, r13d, [rsp + 52]
.qi_next:
    inc r14d
    jmp .qi
.qj_next:
    inc r15d
    jmp .qj
.quads_done:
    ; ---- upload the smooth shell, then build and upload the cubes
    mov r12d, [rsp + 72]
    mov edi, r12d
    lea rsi, [hz_buf]
    mov edx, [hz_n]
    call hz_upload
    mov edi, r12d
    mov esi, [rsp + 64]
    mov edx, [rsp + 68]
    call build_cubes
    lea edi, [r12 + HZ_SLOTS]
    lea rsi, [cz_buf]
    mov edx, [cz_n]
    call hz_upload
.built:
    lea rax, [hz_meshed]
    mov byte [rax + r12], 1
    mov eax, [cur_pcx]
    lea rcx, [hz_bpcx]
    mov [rcx + r12*4], eax
    mov eax, [cur_pcz]
    lea rcx, [hz_bpcz]
    mov [rcx + r12*4], eax
    LEAVE_FN

; hz_upload(edi mesh index, rsi vertices, edx count) - into its VBO, or a
; client-memory copy without VBOs
hz_upload:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r15, rsi
    mov ebx, edx
    lea rcx, [hz_nverts]
    mov [rcx + r12*4], edx
    cmp dword [vbo_ok], 0
    je .client
    lea rcx, [hz_vbo]
    mov esi, [rcx + r12*4]
    mov edi, GL_ARRAY_BUFFER
    call [p_bindbuf]
    mov edi, GL_ARRAY_BUFFER
    mov esi, ebx
    shl rsi, 4
    mov rdx, r15
    mov ecx, GL_STATIC_DRAW
    call [p_bufdata]
    call unbind_vbo
    jmp .out
.client:
    mov r13d, ebx
    shl r13d, 4
    lea rax, [hz_cap]
    cmp [rax + r12*4], r13d
    jae .copy
    lea rax, [hz_ptr]
    mov rdi, [rax + r12*8]
    lea esi, [r13 + 4096]
    mov r14d, esi
    call realloc PLT
    test rax, rax
    jnz .got
    lea rcx, [hz_nverts]
    mov dword [rcx + r12*4], 0
    jmp .out
.got:
    lea rcx, [hz_ptr]
    mov [rcx + r12*8], rax
    lea rcx, [hz_cap]
    mov [rcx + r12*4], r14d
.copy:
    lea rax, [hz_ptr]
    mov rdi, [rax + r12*8]
    mov rsi, r15
    mov ecx, r13d
    rep movsb
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; void horizon_update(void) - request missing tiles, (re)build meshes
; locals: [0] tile radius, [4] player tile x, [8] player tile z, [12] tx,
;         [16] tz, [20] builds this frame, [24] near box
horizon_update:
    ENTER_FN 32
    cmp dword [dimension], 0        ; no far terrain in the nether
    je .ow
    mov dword [horizon_dist], 0
    jmp .out
.ow:
    mov eax, [set_horizon]
    lea rcx, [hz_chunks]
    mov eax, [rcx + rax*4]
    mov ecx, eax
    shl ecx, 4
    mov [horizon_dist], ecx
    test eax, eax
    jz .out
    ; rings (chunks): 8-node cubes to real + 5, 16-node cubes to real + 12,
    ; then the smooth shell
    mov ecx, [set_range]
    lea edx, [rcx + 12]
    cmp edx, eax
    cmovg edx, eax
    mov [hz_r2], edx
    imul edx, edx
    mov [cube_r2sq], edx
    lea edx, [rcx + 5]
    cmp edx, [hz_r2]
    cmovg edx, [hz_r2]
    imul edx, edx
    mov [cube_r1sq], edx
    shr eax, 4
    inc eax
    mov [rsp], eax
    cmp dword [vbo_ready], 0
    jne .vb
    cmp dword [vbo_ok], 0
    je .vb
    mov dword [vbo_ready], 1
    mov edi, HZ_SLOTS * 2
    lea rsi, [hz_vbo]
    call [p_genbuf]
.vb:
    mov eax, [cur_pcx]
    sar eax, 4
    mov [rsp + 4], eax
    mov eax, [cur_pcz]
    sar eax, 4
    mov [rsp + 8], eax
    mov dword [rsp + 20], 0
    mov eax, [rsp + 8]
    sub eax, [rsp]
    mov [rsp + 16], eax
.tz:
    mov eax, [rsp + 8]
    add eax, [rsp]
    cmp [rsp + 16], eax
    jg .out
    mov eax, [rsp + 4]
    sub eax, [rsp]
    mov [rsp + 12], eax
.tx:
    mov eax, [rsp + 4]
    add eax, [rsp]
    cmp [rsp + 12], eax
    jg .tz_next
    mov edi, [rsp + 12]
    mov esi, [rsp + 16]
    call tile_in_range
    test eax, eax
    jz .tx_next
    ; slot of this tile
    mov ebx, [rsp + 16]
    and ebx, HZ_MASK
    shl ebx, 4
    mov eax, [rsp + 12]
    and eax, HZ_MASK
    or ebx, eax
    lea rax, [hz_state]
    movzx ecx, byte [rax + rbx]
    lea rdx, [hz_tx]
    lea r8, [hz_tz]
    cmp ecx, HS_EMPTY
    je .request
    mov r9d, [rsp + 12]
    cmp [rdx + rbx*4], r9d
    jne .other
    mov r9d, [rsp + 16]
    cmp [r8 + rbx*4], r9d
    jne .other
    cmp ecx, HS_READY
    jne .tx_next                    ; still being made
    ; ready: mesh when new, or when the player moved and the real chunks'
    ; edge or the cube rings may cross it
    cmp dword [rsp + 20], 2
    jae .tx_next
    lea rax, [hz_meshed]
    cmp byte [rax + rbx], 0
    je .build
    lea rax, [hz_bpcx]
    mov ecx, [cur_pcx]
    sub ecx, [rax + rbx*4]
    mov edx, ecx
    neg edx
    cmovs edx, ecx
    lea rax, [hz_bpcz]
    mov ecx, [cur_pcz]
    sub ecx, [rax + rbx*4]
    mov r8d, ecx
    neg r8d
    cmovs r8d, ecx
    cmp r8d, edx
    cmovl r8d, edx                  ; chunks moved (larger axis)
    test r8d, r8d
    jz .tx_next
; jump to %1 if the tile overlaps the box of ecx chunks round the player
%macro INBOX 1
    mov r9d, ecx
    mov r10d, ecx
    neg r10d
    mov eax, [rsp + 12]
    shl eax, 4
    sub eax, [cur_pcx]
    lea edx, [rax + TILE_CHUNKS]
    cmp edx, r10d
    jl %%no
    cmp eax, r9d
    jg %%no
    mov eax, [rsp + 16]
    shl eax, 4
    sub eax, [cur_pcz]
    lea edx, [rax + TILE_CHUNKS]
    cmp edx, r10d
    jl %%no
    cmp eax, r9d
    jg %%no
    jmp %1
%%no:
%endmacro
    ; next to the real chunks: every chunk step (no gaps at their edge)
    mov ecx, [set_range]
    add ecx, 2
    INBOX .build
    ; the cube rings: every second step
    cmp r8d, 2
    jb .tx_next
    mov ecx, [hz_r2]
    add ecx, 2
    INBOX .build
    jmp .tx_next
.build:
    mov edi, ebx
    call build_tile
    inc dword [rsp + 20]
    jmp .tx_next
.other:
    cmp ecx, HS_PENDING
    je .tx_next                     ; the old tile is still being made
.request:
    mov eax, [rsp + 12]
    mov [rdx + rbx*4], eax
    mov eax, [rsp + 16]
    mov [r8 + rbx*4], eax
    lea rax, [hz_meshed]
    mov byte [rax + rbx], 0
    cmp dword [threaded], 0
    je .sync
    mov edi, ebx
    mov esi, [rsp + 12]
    mov edx, [rsp + 16]
    call worker_submit_horizon
    test eax, eax
    jz .out                         ; queue full: next frame
    lea rax, [hz_state]
    mov byte [rax + rbx], HS_PENDING
    jmp .tx_next
.sync:
    ; no second core: one tile per frame on this thread
    cmp dword [rsp + 20], 0
    jne .tx_next
    mov edi, [rsp + 12]
    mov esi, [rsp + 16]
    mov edx, [seed]
    imul eax, ebx, HZ_DATA * 2
    lea rcx, [hz_heights]
    add rcx, rax
    imul eax, ebx, HZ_DATA
    lea r8, [hz_tops]
    add r8, rax
    imul eax, ebx, HZ_DATA * 8
    lea r9, [hz_cols]
    add r9, rax
    call mapgen_horizon_tile
    lea rax, [hz_state]
    mov byte [rax + rbx], HS_READY
    inc dword [rsp + 20]
.tx_next:
    inc dword [rsp + 12]
    jmp .tx
.tz_next:
    inc dword [rsp + 16]
    jmp .tz
.out:
    LEAVE_FN

; void horizon_draw(void) - after the real chunks: the cube rings with the
; block textures and world lighting, then the smooth shell tinted by daylight
horizon_draw:
    ENTER_FN 16
    mov dword [horizon_tile_count], 0
    mov dword [horizon_cube_verts], 0
    cmp dword [set_horizon], 0
    je .out
    cmp dword [dimension], 0
    jne .out
    call world_tex_begin
    mov edi, GL_DEPTH_TEST
    call glEnable PLT
    mov edi, GL_CULL_FACE
    call glEnable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, HZ_SLOTS               ; cube meshes
    call draw_part
    call unbind_vbo
    call world_tex_end
    call tint_begin
    mov edi, GL_CULL_FACE           ; skirts are seen from both sides
    call glDisable PLT
    xor edi, edi                    ; smooth shell
    call draw_part
    call unbind_vbo
    call world_tex_end
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

; draw_part(edi 0 = smooth shells, HZ_SLOTS = cubes): every ready tile in
; range and on screen
; locals: [0] part
draw_part:
    ENTER_FN 16
    mov [rsp], edi
    xor ebx, ebx
.t:
    lea rax, [hz_state]
    cmp byte [rax + rbx], HS_READY
    jne .next
    lea rax, [hz_meshed]
    cmp byte [rax + rbx], 0
    je .next
    mov r15d, ebx
    add r15d, [rsp]                 ; mesh index
    lea rax, [hz_nverts]
    mov r12d, [rax + r15*4]
    test r12d, r12d
    jz .next
    lea rax, [hz_tx]
    mov edi, [rax + rbx*4]
    lea rax, [hz_tz]
    mov esi, [rax + rbx*4]
    mov r13d, edi
    mov r14d, esi
    call tile_in_range
    test eax, eax
    jz .next
    ; on screen? tile box in nodes relative to the player chunk origin
    mov eax, r13d
    shl eax, 4
    sub eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [f_ymin]
    mov eax, r14d
    shl eax, 4
    sub eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm2, eax
    movss xmm3, [f_tile]
    movss xmm4, [f_yspan]
    movss xmm5, [f_tile]
    call frustum_box
    test eax, eax
    jz .next
    call glPushMatrix PLT
    mov eax, r13d
    shl eax, 4
    sub eax, [cur_pcx]
    shl eax, 7                      ; chunks -> 1/8 nodes
    cvtsi2ss xmm0, eax
    xorps xmm1, xmm1
    mov eax, r14d
    shl eax, 4
    sub eax, [cur_pcz]
    shl eax, 7
    cvtsi2ss xmm2, eax
    call glTranslatef PLT
    cmp dword [vbo_ok], 0
    je .va
    lea rax, [hz_vbo]
    mov esi, [rax + r15*4]
    mov edi, GL_ARRAY_BUFFER
    call [p_bindbuf]
    xor edi, edi
    call client_pointers
    jmp .draw
.va:
    lea rax, [hz_ptr]
    mov rdi, [rax + r15*8]
    test rdi, rdi
    jz .popm
    call client_pointers
.draw:
    mov edi, GL_QUADS
    xor esi, esi
    mov edx, r12d
    call glDrawArrays PLT
    add [stat_verts], r12d
    cmp dword [rsp], 0
    je .shell
    add [horizon_cube_verts], r12d
    jmp .popm
.shell:
    inc dword [horizon_tile_count]
.popm:
    call glPopMatrix PLT
.next:
    inc ebx
    cmp ebx, HZ_SLOTS
    jb .t
    LEAVE_FN

NOEXECSTACK
