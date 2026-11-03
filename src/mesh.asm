; mesh.asm - greedy, multi-resolution chunk mesher.
;
; mesh_chunk(slot, scale) builds a chunk at full detail (scale 1) or as a
; coarser far-terrain mesh (scale 2 or 4: each cell stands for 2x2x2 or
; 4x4x4 nodes). Steps:
;   1. copy (or downsample) the chunk plus a one-cell border taken from the
;      four neighbours into a padded cell grid
;   2. for each face direction and slice, build a mask of visible faces
;      keyed by texture, light, part and liquid height
;   3. merge equal keys greedily into rectangles of up to 8x8 nodes (the
;      atlas repeats every texture 8x8, so a merged quad tiles correctly)
;
; Output buffers (16-byte vertices, see common.inc):
;   surf - faces open to the sky or near it, binned per face direction
;   deep - faces more than 12 nodes under the column top (drawn near only)
;   wat  - liquid faces (blended pass)
; The Xpress 1150 has no hardware vertex processing; fewer, larger quads
; are what makes long view distances affordable on it.

%include "common.inc"

global mesh_chunk, mesh_buf_surf, mesh_buf_deep, mesh_buf_wat
global mesh_set_leaves_opaque, mesh_flags, mesh_light_mode, light_curve
global mesh_fires, mesh_fire_n, mesh_beacons, mesh_beacon_n

extern world_find, chunk_blocks, chunk_hmap, chunk_info, block_flags
extern block_tiles, chunk_light, world_get, dimension

DEEP_DEPTH  equ 12
FAR_DARK    equ 6                   ; sky light under overhangs in coarse meshes
GRID_MAX    equ 18 * 18 * 258
MAX_MESH_FIRES equ 64
NETHER_LIGHT equ 8                  ; block light everything has in the nether

; face record
FR_SEL      equ 0
FR_SHADE    equ 1
FR_CORN     equ 2                   ; 4 corners x (x, y, z) bits
FR_N        equ 14                  ; normal axis (0 x, 1 y, 2 z)
FR_A        equ 15                  ; texture u axis
FR_B        equ 16                  ; texture v axis
FR_POS      equ 17                  ; 1 = faces +axis
FR_SIZE     equ 32

; mask key: bit 31 | tile (0-7) | sky (8-11) | block light (12-15) |
; part (16-17) | liquid height (18-21)
K_SKY       equ 8
K_BLK       equ 12
K_PART      equ 16
K_HEIGHT    equ 18
PART_SURF   equ 0
PART_DEEP   equ 1
PART_WAT    equ 2

section .rodata
; counter-clockwise from outside; order +X -X +Y -Y +Z -Z
faces:
    db 1, 204,  1,0,1,  1,0,0,  1,1,0,  1,1,1,  0, 2, 1, 1
    times FR_SIZE - 18 db 0
    db 1, 204,  0,0,0,  0,0,1,  0,1,1,  0,1,0,  0, 2, 1, 0
    times FR_SIZE - 18 db 0
    db 0, 255,  0,1,0,  0,1,1,  1,1,1,  1,1,0,  1, 2, 0, 1
    times FR_SIZE - 18 db 0
    db 2, 128,  0,0,0,  1,0,0,  1,0,1,  0,0,1,  1, 0, 2, 0
    times FR_SIZE - 18 db 0
    db 1, 170,  0,0,1,  1,0,1,  1,1,1,  0,1,1,  2, 0, 1, 1
    times FR_SIZE - 18 db 0
    db 1, 170,  1,0,0,  0,0,0,  0,1,0,  1,1,0,  2, 0, 1, 0
    times FR_SIZE - 18 db 0
; per corner: u and v at the far end of the rectangle?
corner_u:   db 0, 1, 1, 0
corner_v:   db 1, 1, 0, 0
; brightness of light levels 0-15 (Minecraft-like curve, small ambient)
light_curve: db 13, 17, 22, 27, 33, 40, 47, 56, 67, 79, 94, 111, 134, 163, 201, 255
; crossed quads (torches): 4 quads x 4 corners (x, y, z) in 1/16 node
; units, inset so the stick sits in the middle of the node
cross_quads:
    db 2,0,2,   14,0,14,  14,16,14,  2,16,2
    db 14,0,14, 2,0,2,    2,16,2,    14,16,14
    db 14,0,2,  2,0,14,   2,16,14,   14,16,2
    db 2,0,14,  14,0,2,   14,16,2,   2,16,14
; fences and gates: boxes x0 y0 z0 x1 y1 z1 in 1/8 nodes
fence_post: db 3,0,3, 5,8,5
fence_bars:                         ; two rails toward +x, -x, +z, -z
    db 5,3,3, 8,4,5,   5,6,3, 8,7,5
    db 0,3,3, 3,4,5,   0,6,3, 3,7,5
    db 3,3,5, 5,4,8,   3,6,5, 5,7,8
    db 3,3,0, 5,4,3,   3,6,0, 5,7,3
fence_dir:  db 1,0, -1,0, 0,1, 0,-1 ; neighbour offsets x, z (as bytes)
gate_x:     db 0,3,3, 1,8,5,   7,3,3, 8,8,5,   1,3,3, 7,4,5,   1,6,3, 7,7,5,   3,4,3, 5,6,5
gate_z:     db 3,3,0, 5,8,1,   3,3,7, 5,8,8,   3,3,1, 5,4,7,   3,6,1, 5,7,7,   3,4,3, 5,6,5
gate_ox:    db 0,3,3, 1,8,5,   7,3,3, 8,8,5,   0,3,5, 1,7,8,   7,3,5, 8,7,8
gate_oz:    db 3,3,0, 5,8,1,   3,3,7, 5,8,8,   5,3,0, 8,7,1,   5,3,7, 8,7,8
gate_n:     db 5, 5, 4, 4
bed_box:    db 0,0,0, 8,4,8         ; a bed half: a mattress half a node tall
align 8
gate_box:   dq gate_x, gate_z, gate_ox, gate_oz

section .bss
alignb 16
mesh_buf_surf:  resb MESH_SURF_CAP * VERT_SIZE
surf_bins:      resb MESH_SURF_CAP * VERT_SIZE    ; one MESH_BIN_CAP bin per face
mesh_buf_deep:  resb MESH_DEEP_CAP * VERT_SIZE
mesh_buf_wat:   resb MESH_WAT_CAP * VERT_SIZE
grid:           resb GRID_MAX + 64
lgrid:          resb GRID_MAX + 64      ; light bytes, same layout
alignb 16
coltop:         resd 18 * 18
mask:           resd 16 * 256
mesh_flags:     resb 256
flags_ready:    resd 1
mesh_light_mode: resd 1                 ; 0 combiner encoding, 1 plain
n_bin:          resd 6
n_deep:         resd 1
n_wat:          resd 1
m_miny8:        resd 1
; current chunk geometry
m_s:            resd 1              ; nodes per cell
m_n:            resd 1              ; cells per horizontal side
m_xs:           resd 1              ; grid stride for x (= cells high + 2)
m_zs:           resd 1              ; grid stride for z
m_cymax:        resd 1              ; highest cell row to mesh
m_deep:         resd 1              ; part-deep threshold in cells (or huge)
m_dim:          resd 3              ; cells along x, y, z
m_stride:       resd 3              ; grid stride along x, y, z
m_base:         resd 1              ; grid index of cell (0, 0, 0)
fill_lt:        resq 1              ; light of the chunk being copied
lt_col:         resq 1              ; &lgrid[column, -1]
has_cross:      resd 1              ; a torch, plant or fence was seen while filling
mesh_fires:     resd 3 * MAX_MESH_FIRES ; fire nodes seen while meshing (fire.asm
mesh_fire_n:    resd 1              ; takes them: fires loaded from a save burn on)
mesh_beacons:   resd 3 * MAX_MESH_FIRES ; beacons seen while meshing
mesh_beacon_n:  resd 1
m_wx:           resd 1              ; world x, z of the chunk being meshed
m_wz:           resd 1
fb_ox:          resd 1              ; fence box origin (1/8 nodes), light, texture
fb_oy:          resd 1
fb_oz:          resd 1
fb_light:       resd 1
fb_tu:          resd 1
fb_tv:          resd 1
; current face
f_rec:          resq 1
f_d:            resd 1
f_t:            resd 1
nb_blk:         resq 4              ; neighbour chunks -X +X -Z +Z
nb_hm:          resq 4
nb_lt:          resq 4
self_lt:        resq 1

section .text

; void mesh_set_leaves_opaque(int opaque) - rebuild mesh_flags
mesh_set_leaves_opaque:
    lea rsi, [block_flags]
    lea rdx, [mesh_flags]
    xor ecx, ecx
.c:
    mov al, [rsi + rcx]
    mov [rdx + rcx], al
    inc ecx
    cmp ecx, 256
    jb .c
    test edi, edi
    jz .done
    or byte [rdx + B_LEAVES], F_OPAQUE
    or byte [rdx + B_PINENEEDLES], F_OPAQUE
.done:
    mov dword [flags_ready], 1
    ret

; rax = blocks of chunk (edi, esi) or 0, rdx = its heightmap, r8 = light
nb_lookup:
    call world_find
    test eax, eax
    js .none
    mov edx, eax
    shl rax, 16
    lea r8, [chunk_light]
    add r8, rax
    lea rcx, [chunk_blocks]
    add rax, rcx
    shl rdx, 9
    lea rcx, [chunk_hmap]
    add rdx, rcx
    ret
.none:
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
    ret

; al = cell value of an s x s x s group of nodes in chunk rsi with its
; corner at node (edi x, edx y, ecx z); s = m_s
; Mostly empty -> air; otherwise the topmost solid node, or water when
; liquid outweighs solids.
downsample:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r8d, [m_s]
    xor r9d, r9d                    ; solids
    xor r10d, r10d                  ; liquids
    xor r11d, r11d                  ; topmost solid
    lea r14, [block_flags]
    lea r12d, [rdx + r8 - 1]        ; y from the top down
.y:
    xor r13d, r13d                  ; dz
.z:
    xor r15d, r15d                  ; dx
.x:
    lea eax, [rcx + r13]
    shl eax, 12
    lea ebx, [rdi + r15]
    shl ebx, 8
    or eax, ebx
    or eax, r12d
    movzx eax, byte [rsi + rax]
    test eax, eax
    jz .next
    test byte [r14 + rax], F_LIQUID
    jz .solid
    inc r10d
    jmp .next
.solid:
    inc r9d
    test r11d, r11d
    jnz .next
    mov r11d, eax
.next:
    inc r15d
    cmp r15d, r8d
    jb .x
    inc r13d
    cmp r13d, r8d
    jb .z
    dec r12d
    cmp r12d, edx
    jge .y
    ; s^3 / 2
    mov eax, r8d
    imul eax, r8d
    imul eax, r8d
    shr eax, 1
    lea ebx, [r9 + r10]
    cmp ebx, eax
    jb .air
    cmp r9d, r10d
    jb .water
    mov eax, r11d
    jmp .out
.water:
    mov eax, B_WATER
    jmp .out
.air:
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Fill one padded grid column (cell x edi, z esi in -1..n) from chunk rdx
; (0 = not loaded) at its cell column (ecx lx, r8d lz), heightmap r9,
; light [fill_lt].
; locals: [0] grid index of y = -1, [8] chunk, [16] hmap, [24] lx, [28] lz
fill_column:
    ENTER_FN 48
    mov [rsp + 32], edi
    mov [rsp + 36], esi
    mov [rsp + 8], rdx
    mov [rsp + 16], r9
    mov [rsp + 24], ecx
    mov [rsp + 28], r8d
    ; grid index of (x, -1, z)
    lea eax, [rsi + 1]
    imul eax, [m_zs]
    lea ecx, [rdi + 1]
    imul ecx, [m_xs]
    add eax, ecx
    mov [rsp], eax
    ; column top for lighting
    lea eax, [rsi + 1]
    mov ecx, [m_n]
    add ecx, 2
    imul eax, ecx
    lea eax, [rax + rdi + 1]
    mov r15d, eax                   ; coltop index
    lea rbx, [grid]
    mov eax, [rsp]
    add rbx, rax                    ; &grid[x, -1, z]
    mov byte [rbx], B_UNKNOWN       ; below the world: closed
    lea r14, [lgrid]
    add r14, rax                    ; &lgrid[x, -1, z]
    mov byte [r14], 0
    cmp qword [rsp + 8], 0
    jne .loaded
    ; not loaded: everything unknown (no faces against it)
    mov ecx, [m_cymax]
    add ecx, 2
    lea rdi, [rbx + 1]
    mov al, B_UNKNOWN
    rep stosb
    lea rax, [coltop]
    mov dword [rax + r15*4], 0
    LEAVE_FN
.loaded:
    mov [lt_col], r14
    ; column top: max heightmap over the s x s node columns, in cells
    xor r12d, r12d                  ; max
    xor r13d, r13d                  ; dz
.hz:
    xor r14d, r14d                  ; dx
.hx:
    mov eax, [rsp + 28]
    imul eax, [m_s]
    add eax, r13d
    shl eax, 4
    mov ecx, [rsp + 24]
    imul ecx, [m_s]
    add ecx, r14d
    add eax, ecx
    mov rdx, [rsp + 16]
    movzx eax, word [rdx + rax*2]
    cmp eax, r12d
    jbe .hn
    mov r12d, eax
.hn:
    inc r14d
    cmp r14d, [m_s]
    jb .hx
    inc r13d
    cmp r13d, [m_s]
    jb .hz
    mov eax, r12d
    add eax, [m_s]
    dec eax
    xor edx, edx
    div dword [m_s]
    lea rcx, [coltop]
    mov [rcx + r15*4], eax
    ; cells 0 .. cymax+1
    xor r12d, r12d                  ; cell y
.y:
    mov eax, [m_cymax]
    inc eax
    cmp r12d, eax
    ja .done
    mov eax, [m_s]
    imul eax, r12d                  ; node y
    cmp eax, WORLD_H
    jae .air
    cmp dword [m_s], 1
    jne .down
    mov ecx, [rsp + 28]
    shl ecx, 12
    mov edx, [rsp + 24]
    shl edx, 8
    or ecx, edx
    or ecx, eax
    mov rdx, [fill_lt]
    mov r8, [lt_col]
    mov dl, [rdx + rcx]
    mov [r8 + r12 + 1], dl
    mov rdx, [rsp + 8]
    movzx eax, byte [rdx + rcx]
    lea rdx, [mesh_flags]
    test byte [rdx + rax], F_CROSS | F_FENCE | F_HALF
    jz .beacon
    mov dword [has_cross], 1
    cmp eax, B_FIRE
    jne .put
    mov ecx, [mesh_fire_n]          ; note the fire (world position)
    cmp ecx, MAX_MESH_FIRES
    jae .put
    inc dword [mesh_fire_n]
    imul ecx, ecx, 12
    lea rdx, [mesh_fires]
    add rdx, rcx
    mov ecx, [rsp + 32]
    add ecx, [m_wx]
    mov [rdx], ecx
    lea ecx, [r12 + WORLD_YMIN]
    mov [rdx + 4], ecx
    mov ecx, [rsp + 36]
    add ecx, [m_wz]
    mov [rdx + 8], ecx
    jmp .put
.beacon:
    cmp eax, B_BEACON
    jne .put
    mov ecx, [mesh_beacon_n]        ; note the beacon (beacon.asm takes it)
    cmp ecx, MAX_MESH_FIRES
    jae .put
    inc dword [mesh_beacon_n]
    imul ecx, ecx, 12
    lea rdx, [mesh_beacons]
    add rdx, rcx
    mov ecx, [rsp + 32]
    add ecx, [m_wx]
    mov [rdx], ecx
    lea ecx, [r12 + WORLD_YMIN]
    mov [rdx + 4], ecx
    mov ecx, [rsp + 36]
    add ecx, [m_wz]
    mov [rdx + 8], ecx
    jmp .put
.down:
    mov edx, eax
    mov edi, [rsp + 24]
    imul edi, [m_s]
    mov ecx, [rsp + 28]
    imul ecx, [m_s]
    mov rsi, [rsp + 8]
    call downsample
    jmp .put
.air:
    mov r8, [lt_col]
    mov byte [r8 + r12 + 1], 15     ; open sky above the world
    xor eax, eax
.put:
    mov [rbx + r12 + 1], al
    inc r12d
    jmp .y
.done:
    LEAVE_FN

; ---------------------------------------------------------------------------
; emit_rect(edi a, esi b, edx w, ecx h, r8d key) for face f_rec at slice f_t
; locals: [0] start[3], [16] ext[3], [32] colour, [36] uspan, [40] vspan,
;         [44] tileU, [48] tileV, [52] height, [56] buffer ptr (8)
emit_rect:
    ENTER_FN 64
    mov r12, [f_rec]
    movzx eax, byte [r12 + FR_N]
    mov r9d, [f_t]
    mov [rsp + rax*4], r9d
    mov dword [rsp + 16 + rax*4], 1
    movzx eax, byte [r12 + FR_A]
    mov [rsp + rax*4], edi
    mov [rsp + 16 + rax*4], edx
    movzx eax, byte [r12 + FR_B]
    mov [rsp + rax*4], esi
    mov [rsp + 16 + rax*4], ecx
    ; texture spans in 1/16 node units, inset by one unit at each end
    imul edx, [m_s]
    shl edx, 4
    sub edx, 2
    mov [rsp + 36], edx
    imul ecx, [m_s]
    shl ecx, 4
    sub ecx, 2
    mov [rsp + 40], ecx
    mov eax, r8d
    and eax, 15
    shl eax, 7
    inc eax
    mov [rsp + 44], eax             ; tileU
    mov eax, r8d
    shr eax, 4
    and eax, 15
    shl eax, 7
    inc eax
    mov [rsp + 48], eax             ; tileV
    mov eax, r8d
    shr eax, K_HEIGHT
    and eax, 15
    mov [rsp + 52], eax
    ; colour from sky and block light
    mov eax, r8d
    shr eax, K_SKY
    and eax, 15
    mov ecx, r8d
    shr ecx, K_BLK
    and ecx, 15
    movzx edx, byte [r12 + FR_SHADE]
    call light_colour
    mov [rsp + 32], eax
    ; buffer by part
    mov eax, r8d
    shr eax, K_PART
    and eax, 3
    cmp eax, PART_DEEP
    je .deep
    ; surface and water: track the lowest y
    mov ecx, [rsp + 4]
    imul ecx, [m_s]
    add ecx, WORLD_YMIN
    shl ecx, 3
    cmp ecx, [m_miny8]
    jge .lowok
    mov [m_miny8], ecx
.lowok:
    cmp eax, PART_WAT
    je .water
    mov eax, [f_d]
    imul rax, rax, MESH_BIN_CAP * VERT_SIZE
    lea rdi, [surf_bins]
    add rdi, rax
    lea r10, [n_bin]
    mov eax, [f_d]
    lea r10, [r10 + rax*4]
    mov eax, MESH_BIN_CAP - 4
    jmp .buf
.deep:
    lea rdi, [mesh_buf_deep]
    lea r10, [n_deep]
    mov eax, MESH_DEEP_CAP - 4
    jmp .buf
.water:
    lea rdi, [mesh_buf_wat]
    lea r10, [n_wat]
    mov eax, MESH_WAT_CAP - 4
.buf:
    mov ecx, [r10]
    cmp ecx, eax
    ja .out
    lea eax, [rcx + 4]
    mov [r10], eax
    shl rcx, 4
    add rdi, rcx
    ; four corners
    xor r13d, r13d                  ; corner k
.corner:
    xor r14d, r14d                  ; axis
.axis:
    lea eax, [r13 + r13*2]
    add eax, r14d
    movzx ecx, byte [r12 + FR_CORN + rax]   ; bit
    mov eax, [rsp + 16 + r14*4]
    imul eax, ecx
    add eax, [rsp + r14*4]
    imul eax, [m_s]
    shl eax, 3                      ; 1/8 node units
    cmp r14d, 1
    jne .store
    add eax, WORLD_YMIN * 8
    test ecx, ecx
    jz .store
    mov edx, 8
    sub edx, [rsp + 52]             ; liquid surface lowered by (8 - h)/8
    imul edx, [m_s]
    sub eax, edx
.store:
    mov [rdi + r14*2], ax
    inc r14d
    cmp r14d, 3
    jb .axis
    mov word [rdi + 6], 0
    lea rax, [corner_u]
    movzx ecx, byte [rax + r13]
    imul ecx, [rsp + 36]
    add ecx, [rsp + 44]
    mov [rdi + 8], cx
    lea rax, [corner_v]
    movzx ecx, byte [rax + r13]
    imul ecx, [rsp + 40]
    add ecx, [rsp + 48]
    mov [rdi + 10], cx
    mov eax, [rsp + 32]
    mov [rdi + 12], eax
    add rdi, VERT_SIZE
    inc r13d
    cmp r13d, 4
    jb .corner
.out:
    LEAVE_FN

; emit_cross(lx edi, yi esi, lz edx, block ecx, light byte r8d) - four
; quads (two crossed planes, both sides) into the +Y bin, which is never
; culled by direction
emit_cross:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    shl r12d, 3                     ; x in 1/8 nodes
    lea r13d, [rsi + WORLD_YMIN]
    shl r13d, 3                     ; y
    mov r14d, edx
    shl r14d, 3                     ; z
    lea rax, [block_tiles]
    movzx r15d, byte [rax + rcx*4 + 1]   ; side tile
    mov eax, r8d
    and eax, 15
    mov ecx, r8d
    shr ecx, 4
    mov edx, 255
    call light_colour
    mov r11d, eax                   ; rgba
    mov eax, [n_bin + 8]
    cmp eax, MESH_BIN_CAP - 16
    ja .full
    lea rdi, [surf_bins]
    add rdi, 2 * MESH_BIN_CAP * VERT_SIZE
    shl rax, 4
    add rdi, rax
    add dword [n_bin + 8], 16
    lea rsi, [cross_quads]
    xor ebx, ebx                    ; vertex 0..15
.v:
    movzx eax, byte [rsi]
    shr eax, 1
    add eax, r12d
    mov [rdi], ax
    movzx eax, byte [rsi + 1]
    shr eax, 1
    add eax, r13d
    mov [rdi + 2], ax
    movzx eax, byte [rsi + 2]
    shr eax, 1
    add eax, r14d
    mov [rdi + 4], ax
    mov word [rdi + 6], 0
    mov eax, ebx
    and eax, 3
    lea rcx, [corner_u]
    movzx edx, byte [rcx + rax]
    imul edx, edx, 14
    mov ecx, r15d
    and ecx, 15
    shl ecx, 7
    lea edx, [rdx + rcx + 1]
    mov [rdi + 8], dx
    lea rcx, [corner_v]
    movzx edx, byte [rcx + rax]
    imul edx, edx, 14
    mov ecx, r15d
    shr ecx, 4
    shl ecx, 7
    lea edx, [rdx + rcx + 1]
    mov [rdi + 10], dx
    mov [rdi + 12], r11d
    add rdi, VERT_SIZE
    add rsi, 3
    inc ebx
    cmp ebx, 16
    jb .v
.full:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fbox(rdi -> x0 y0 z0 x1 y1 z1 bytes, 1/8 nodes in the node at fb_o*):
; six textured faces into the +Y bin (the planks texture, 2 texels per
; 1/8 node), lit by fb_light
; locals: [0] x, [4] y, [8] z of the corner
fbox:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rdi
    mov eax, [n_bin + 8]
    cmp eax, MESH_BIN_CAP - 24
    ja .out
    xor r13d, r13d                  ; face +X -X +Y -Y +Z -Z
.f:
    imul eax, r13d, FR_SIZE
    lea r14, [faces]
    add r14, rax
    mov eax, [fb_light]
    mov ecx, eax
    and eax, 15
    shr ecx, 4
    movzx edx, byte [r14 + 1]
    call light_colour
    mov r15d, eax
    mov eax, [n_bin + 8]
    lea rdi, [surf_bins + 2 * MESH_BIN_CAP * VERT_SIZE]
    shl rax, 4
    add rdi, rax
    add dword [n_bin + 8], 4
    xor ebx, ebx                    ; corner
.c:
    lea rax, [rbx + rbx*2]
    lea rsi, [r14 + 2 + rax]
%macro FBC 2                        ; axis byte, local
    movzx ecx, byte [rsi + %1]
    lea rdx, [rcx + rcx*2]
    movzx eax, byte [r12 + rdx + %1]
    mov [rsp + %2], eax
%endmacro
    FBC 0, 0
    FBC 1, 4
    FBC 2, 8
    mov eax, [rsp]
    add eax, [fb_ox]
    mov [rdi], ax
    mov eax, [rsp + 4]
    add eax, [fb_oy]
    mov [rdi + 2], ax
    mov eax, [rsp + 8]
    add eax, [fb_oz]
    mov [rdi + 4], ax
    mov word [rdi + 6], 0
    ; texture: x faces u = z, y faces u = x v = z, z faces u = x; walls
    ; v from the top of the node
    cmp r13d, 2
    jb .ux
    cmp r13d, 4
    jb .uy
    mov eax, [rsp]
    mov ecx, 8
    sub ecx, [rsp + 4]
    jmp .uv
.ux:
    mov eax, [rsp + 8]
    mov ecx, 8
    sub ecx, [rsp + 4]
    jmp .uv
.uy:
    mov eax, [rsp]
    mov ecx, [rsp + 8]
.uv:
    shl eax, 1
    add eax, [fb_tu]
    mov [rdi + 8], ax
    shl ecx, 1
    add ecx, [fb_tv]
    mov [rdi + 10], cx
    mov [rdi + 12], r15d
    add rdi, VERT_SIZE
    inc ebx
    cmp ebx, 4
    jb .c
    inc r13d
    cmp r13d, 6
    jb .f
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; emit_fence(lx edi, yi esi, lz edx, block ecx, light byte r8d): a fence
; post with rails toward fences, gates and solid blocks next to it, or a
; fence gate (closed across x or z, or open)
emit_fence:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [fb_light], r8d
    mov ebx, ecx
    mov eax, edi
    shl eax, 3
    mov [fb_ox], eax
    add edi, [m_wx]
    mov r12d, edi                   ; world x
    lea eax, [rsi + WORLD_YMIN]
    mov r13d, eax                   ; world y
    shl eax, 3
    mov [fb_oy], eax
    mov eax, edx
    shl eax, 3
    mov [fb_oz], eax
    add edx, [m_wz]
    mov r14d, edx                   ; world z
    lea rax, [block_tiles]
    movzx eax, byte [rax + rbx*4 + 1]
    mov ecx, eax
    and ecx, 15
    shl ecx, 7
    mov [fb_tu], ecx
    shr eax, 4
    shl eax, 7
    mov [fb_tv], eax
    cmp ebx, B_BED_FOOT
    jb .notbed
    cmp ebx, B_BED_HEAD
    ja .notbed
    lea rdi, [bed_box]
    call fbox
    jmp .out
.notbed:
    cmp ebx, B_FENCE
    jne .gate
    lea rdi, [fence_post]
    call fbox
    xor r15d, r15d                  ; direction
.dir:
    lea rax, [fence_dir]
    movsx edi, byte [rax + r15*2]
    add edi, r12d
    mov esi, r13d
    movsx edx, byte [rax + r15*2 + 1]
    add edx, r14d
    call world_get
    lea rcx, [block_flags]
    movzx eax, byte [rcx + rax]
    test eax, F_FENCE
    jnz .join
    and eax, F_SOLID | F_OPAQUE
    cmp eax, F_SOLID | F_OPAQUE
    jne .nojoin
.join:
    imul eax, r15d, 12
    lea rdi, [fence_bars]
    add rdi, rax
    push rdi
    sub rsp, 8
    call fbox
    add rsp, 8
    pop rdi
    add rdi, 6
    call fbox
.nojoin:
    inc r15d
    cmp r15d, 4
    jb .dir
    jmp .out
.gate:
    sub ebx, B_GATE_X
    lea rax, [gate_box]
    mov r12, [rax + rbx*8]
    lea rax, [gate_n]
    movzx r13d, byte [rax + rbx]
.g:
    mov rdi, r12
    call fbox
    add r12, 6
    dec r13d
    jnz .g
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = rgba for sky level eax, block level ecx, face shade edx (0-255)
; clobbers rcx, rdx, r9, r10
light_colour:
    cmp dword [dimension], 0
    je .lit
    mov r9d, NETHER_LIGHT           ; the nether: never quite dark
    cmp ecx, r9d
    cmovb ecx, r9d
.lit:
    lea r9, [light_curve]
    movzx eax, byte [r9 + rax]
    movzx ecx, byte [r9 + rcx]
    cmp dword [mesh_light_mode], 0
    jne .plain
    imul eax, edx
    shr eax, 8
    imul ecx, edx
    shr ecx, 8
    imul eax, eax, 0x010101
    shl ecx, 24
    or eax, ecx
    ret
.plain:
    cmp eax, ecx
    jae .m
    mov eax, ecx
.m:
    imul eax, edx
    shr eax, 8
    imul eax, eax, 0x010101
    or eax, 0xff000000
    ret

; liquid height (1-8) of the liquid cell at grid index eax: full when
; liquid sits on top, 7 for a source surface, the level for flowing water
liquid_h:
    lea rcx, [grid]
    movzx edx, byte [rcx + rax + 1]
    lea r8, [mesh_flags]
    test byte [r8 + rdx], F_LIQUID
    jnz .full
    movzx edx, byte [rcx + rax]
    cmp edx, B_WATER
    je .src
    cmp edx, B_LAVA
    je .src
    cmp edx, B_LAVA
    ja .lava
    sub edx, B_WFLOW1 - 1
    mov eax, edx
    ret
.lava:
    sub edx, B_LFLOW1 - 1           ; flowing lava 1-3: 2, 4, 6
    lea eax, [rdx + rdx]
    ret
.src:
    mov eax, 7
    ret
.full:
    mov eax, 8
    ret

; Mesh all slices of face f_d.
; locals: [0] N, [4] A, [8] B, [12] dN (grid), [16] dimN, [20] dimA,
;         [24] dimB, [28] strideA, [32] strideB, [36] t, [40] coord[3],
;         [52] sign, [56] slice grid base, [60] row grid base, [64] b,
;         [68] w, [72] h, [76] key
mesh_face:
    ENTER_FN 80
    mov r12, [f_rec]
    movzx eax, byte [r12 + FR_N]
    mov [rsp], eax
    movzx ecx, byte [r12 + FR_A]
    mov [rsp + 4], ecx
    movzx edx, byte [r12 + FR_B]
    mov [rsp + 8], edx
    lea r8, [m_dim]
    lea r9, [m_stride]
    mov r10d, [r9 + rax*4]
    mov dword [rsp + 52], 1
    cmp byte [r12 + FR_POS], 0
    jne .p
    neg r10d
    mov dword [rsp + 52], -1
.p:
    mov [rsp + 12], r10d
    mov r10d, [r8 + rax*4]
    mov [rsp + 16], r10d
    mov r10d, [r8 + rcx*4]
    mov [rsp + 20], r10d
    mov r10d, [r8 + rdx*4]
    mov [rsp + 24], r10d
    mov r10d, [r9 + rcx*4]
    mov [rsp + 28], r10d
    mov r10d, [r9 + rdx*4]
    mov [rsp + 32], r10d
    mov dword [rsp + 36], 0
.slice:
    mov eax, [rsp + 36]
    cmp eax, [rsp + 16]
    jge .done
    mov [f_t], eax
    ; slice base grid index
    mov ecx, [rsp]
    lea rdx, [m_stride]
    imul eax, [rdx + rcx*4]
    add eax, [m_base]
    mov [rsp + 56], eax

    ; ---- build the mask
    lea rbx, [mask]
    xor r15d, r15d                  ; b
.mb:
    cmp r15d, [rsp + 24]
    jge .greedy
    mov eax, r15d
    imul eax, [rsp + 32]
    add eax, [rsp + 56]
    mov [rsp + 60], eax
    xor r14d, r14d                  ; a
.ma:
    cmp r14d, [rsp + 20]
    jge .mbn
    mov r13d, r14d
    imul r13d, [rsp + 28]
    add r13d, [rsp + 60]            ; grid index of the cell
    xor eax, eax                    ; key 0 = no face
    lea r8, [grid]
    movzx ecx, byte [r8 + r13]
    test ecx, ecx
    jz .key
    mov edx, r13d
    add edx, [rsp + 12]
    movzx edx, byte [r8 + rdx]      ; neighbour
    lea r9, [mesh_flags]
    movzx r10d, byte [r9 + rdx]
    test r10d, F_OPAQUE
    jnz .key
    movzx r11d, byte [r9 + rcx]
    test r11d, F_CROSS | F_FENCE | F_HALF
    jnz .key
    test r11d, F_LIQUID
    jz .solid
    ; liquid: hidden against liquid of the same or greater height
    mov dword [rsp + 72], 8
    test r10d, F_LIQUID
    jz .liq_vis
    cmp dword [rsp], 1
    je .key                         ; liquid above/below liquid
    push rcx
    push rdx
    mov eax, r13d
    add eax, [rsp + 16 + 12]
    call liquid_h
    mov [rsp + 16 + 68], eax        ; neighbour height
    mov eax, r13d
    call liquid_h
    pop rdx
    pop rcx
    cmp [rsp + 68], eax
    jge .nokey
    mov [rsp + 72], eax
    jmp .liq_cls
.liq_vis:
    push rcx
    push rdx
    mov eax, r13d
    call liquid_h
    pop rdx
    pop rcx
    mov [rsp + 72], eax
.liq_cls:
    mov r11d, PART_WAT
    jmp .light
.solid:
    cmp ecx, edx
    jne .solid_vis
    test r11d, F_ALPHA
    jnz .nokey
.solid_vis:
    mov dword [rsp + 72], 8
    mov r11d, -1                    ; part decided by depth
    lea eax, [rcx - B_SGLASS]
    cmp eax, 15
    ja .light
    mov r11d, PART_WAT              ; stained glass: blended, like water
.light:
    ; neighbour cell coordinates -> y and column top
    mov eax, [rsp]
    mov edx, [rsp + 36]
    mov [rsp + 40 + rax*4], edx
    mov eax, [rsp + 4]
    mov [rsp + 40 + rax*4], r14d
    mov eax, [rsp + 8]
    mov [rsp + 40 + rax*4], r15d
    mov eax, [rsp]
    mov edx, [rsp + 52]
    add [rsp + 40 + rax*4], edx     ; step to the neighbour
    mov eax, [rsp + 48]             ; nz
    inc eax
    mov edx, [m_n]
    add edx, 2
    imul eax, edx
    add eax, [rsp + 40]             ; nx
    inc eax
    lea rdx, [coltop]
    mov edx, [rdx + rax*4]          ; column top (cells)
    mov eax, [rsp + 44]             ; ny
    ; light of the node the face looks into
    cmp dword [m_s], 1
    jne .far_light
    mov r9d, r13d
    add r9d, [rsp + 12]
    lea r10, [lgrid]
    movzx r9d, byte [r10 + r9]
    shl r9d, K_SKY                  ; sky and block nibbles in place
    jmp .dark
.far_light:
    mov r9d, 15 << K_SKY
    cmp eax, edx
    jge .dark
    mov r9d, FAR_DARK << K_SKY
.dark:
    cmp r11d, -1
    jne .have_part
    mov r11d, PART_SURF
    add eax, [m_deep]
    cmp eax, edx
    jge .have_part
    mov r11d, PART_DEEP
.have_part:
    ; tile
    lea rax, [block_tiles]
    lea rax, [rax + rcx*4]
    movzx edx, byte [r12 + FR_SEL]
    movzx eax, byte [rax + rdx]
    or eax, r9d
    shl r11d, K_PART
    or eax, r11d
    mov edx, [rsp + 72]
    shl edx, K_HEIGHT
    or eax, edx
    or eax, 0x80000000
    jmp .key
.nokey:
    xor eax, eax
.key:
    mov [rbx], eax
    add rbx, 4
    inc r14d
    jmp .ma
.mbn:
    inc r15d
    jmp .mb

    ; ---- greedy merge
.greedy:
    mov ebx, 8
    xor edx, edx
    mov eax, ebx
    div dword [m_s]
    mov ebx, eax                    ; max cells per side (8 nodes)
    xor r15d, r15d                  ; b
.gb:
    cmp r15d, [rsp + 24]
    jge .next_slice
    xor r14d, r14d                  ; a
.ga:
    cmp r14d, [rsp + 20]
    jge .gbn
    mov eax, r15d
    imul eax, [rsp + 20]
    add eax, r14d
    lea r13, [mask]
    lea r13, [r13 + rax*4]          ; &mask[b][a]
    mov eax, [r13]
    test eax, eax
    jz .gnext
    mov [rsp + 76], eax
    ; width
    mov ecx, 1
.w:
    cmp ecx, ebx
    jae .wdone
    lea edx, [r14 + rcx]
    cmp edx, [rsp + 20]
    jae .wdone
    cmp [r13 + rcx*4], eax
    jne .wdone
    inc ecx
    jmp .w
.wdone:
    mov [rsp + 68], ecx
    ; height
    mov r8d, 1
.h:
    cmp r8d, ebx
    jae .hdone
    lea edx, [r15 + r8]
    cmp edx, [rsp + 24]
    jae .hdone
    mov edx, r8d
    imul edx, [rsp + 20]
    lea r9, [r13 + rdx*4]           ; row start
    xor ecx, ecx
.hrow:
    cmp ecx, [rsp + 68]
    jae .hok
    cmp [r9 + rcx*4], eax
    jne .hdone
    inc ecx
    jmp .hrow
.hok:
    inc r8d
    jmp .h
.hdone:
    mov [rsp + 72], r8d
    ; clear the rectangle from the mask
    xor edx, edx
.cr:
    mov ecx, edx
    imul ecx, [rsp + 20]
    lea r9, [r13 + rcx*4]
    xor ecx, ecx
.cc:
    mov dword [r9 + rcx*4], 0
    inc ecx
    cmp ecx, [rsp + 68]
    jb .cc
    inc edx
    cmp edx, [rsp + 72]
    jb .cr
    mov edi, r14d
    mov esi, r15d
    mov edx, [rsp + 68]
    mov ecx, [rsp + 72]
    mov r8d, [rsp + 76]
    call emit_rect
.gnext:
    inc r14d
    jmp .ga
.gbn:
    inc r15d
    jmp .gb
.next_slice:
    inc dword [rsp + 36]
    jmp .slice
.done:
    LEAVE_FN

; ---------------------------------------------------------------------------
; void mesh_chunk(int slot, int scale)
; locals: [0] slot, [4] scale, [8] chunk blocks, [16] own heightmap
mesh_chunk:
    ENTER_FN 32
    mov [rsp], edi
    mov [rsp + 4], esi
    cmp dword [flags_ready], 0
    jne .fl
    xor edi, edi
    call mesh_set_leaves_opaque
.fl:
    mov esi, [rsp + 4]
    mov [m_s], esi
    mov eax, 16
    xor edx, edx
    div esi
    mov [m_n], eax
    mov [m_dim], eax
    mov [m_dim + 8], eax
    mov eax, WORLD_H
    xor edx, edx
    div esi
    add eax, 2
    mov [m_xs], eax                 ; x stride = cells high + 2
    mov ecx, [m_n]
    add ecx, 2
    imul ecx, eax
    mov [m_zs], ecx
    mov [m_stride], eax
    mov dword [m_stride + 4], 1
    mov [m_stride + 8], ecx
    add ecx, eax
    inc ecx
    mov [m_base], ecx               ; index of cell (0, 0, 0)
    mov dword [m_deep], 1000000
    cmp esi, 1
    jne .nodeep
    mov dword [m_deep], DEEP_DEPTH
.nodeep:
    mov eax, [rsp]
    shl rax, CI_SHIFT
    lea rbx, [chunk_info]
    add rbx, rax
    mov eax, [rbx + CI_MAXY]
    xor edx, edx
    div dword [rsp + 4]
    mov [m_cymax], eax
    inc eax
    mov [m_dim + 4], eax
    mov eax, [rsp]
    shl rax, 16
    lea rcx, [chunk_blocks]
    add rax, rcx
    mov [rsp + 8], rax
    mov eax, [rsp]
    shl rax, 9
    lea rcx, [chunk_hmap]
    add rax, rcx
    mov [rsp + 16], rax
    mov eax, [rsp]
    shl rax, 16
    lea rcx, [chunk_light]
    add rax, rcx
    mov [self_lt], rax
    mov r12d, [rbx + CI_CX]
    mov r13d, [rbx + CI_CZ]
    mov eax, r12d
    shl eax, 4
    mov [m_wx], eax
    mov eax, r13d
    shl eax, 4
    mov [m_wz], eax
    lea edi, [r12 - 1]
    mov esi, r13d
    call nb_lookup
    mov [nb_blk], rax
    mov [nb_hm], rdx
    mov [nb_lt], r8
    lea edi, [r12 + 1]
    mov esi, r13d
    call nb_lookup
    mov [nb_blk + 8], rax
    mov [nb_hm + 8], rdx
    mov [nb_lt + 8], r8
    mov edi, r12d
    lea esi, [r13 - 1]
    call nb_lookup
    mov [nb_blk + 16], rax
    mov [nb_hm + 16], rdx
    mov [nb_lt + 16], r8
    mov edi, r12d
    lea esi, [r13 + 1]
    call nb_lookup
    mov [nb_blk + 24], rax
    mov [nb_hm + 24], rdx
    mov [nb_lt + 24], r8

    ; ---- padded grid: own cells, then the four borders
    mov dword [has_cross], 0
    xor r14d, r14d                  ; z
.oz:
    xor r15d, r15d                  ; x
.ox:
    mov rax, [self_lt]
    mov [fill_lt], rax
    mov edi, r15d
    mov esi, r14d
    mov rdx, [rsp + 8]
    mov ecx, r15d
    mov r8d, r14d
    mov r9, [rsp + 16]
    call fill_column
    inc r15d
    cmp r15d, [m_n]
    jb .ox
    inc r14d
    cmp r14d, [m_n]
    jb .oz
    xor r14d, r14d
.border:
    mov r15d, [m_n]
    dec r15d                        ; last cell index
    ; -X side: neighbour's last column
    mov rax, [nb_lt]
    mov [fill_lt], rax
    mov edi, -1
    mov esi, r14d
    mov rdx, [nb_blk]
    mov ecx, r15d
    mov r8d, r14d
    mov r9, [nb_hm]
    call fill_column
    ; +X side
    mov rax, [nb_lt + 8]
    mov [fill_lt], rax
    mov edi, [m_n]
    mov esi, r14d
    mov rdx, [nb_blk + 8]
    xor ecx, ecx
    mov r8d, r14d
    mov r9, [nb_hm + 8]
    call fill_column
    ; -Z side
    mov rax, [nb_lt + 16]
    mov [fill_lt], rax
    mov edi, r14d
    mov esi, -1
    mov rdx, [nb_blk + 16]
    mov ecx, r14d
    mov r8d, r15d
    mov r9, [nb_hm + 16]
    call fill_column
    ; +Z side
    mov rax, [nb_lt + 24]
    mov [fill_lt], rax
    mov edi, r14d
    mov esi, [m_n]
    mov rdx, [nb_blk + 24]
    mov ecx, r14d
    xor r8d, r8d
    mov r9, [nb_hm + 24]
    call fill_column
    inc r14d
    cmp r14d, [m_n]
    jb .border

    ; ---- faces
    xor eax, eax
    mov [n_deep], eax
    mov [n_wat], eax
    lea rdi, [n_bin]
    mov ecx, 6
    rep stosd
    mov eax, [rbx + CI_MAXY]
    add eax, WORLD_YMIN
    shl eax, 3
    mov [m_miny8], eax              ; no faces: top of the chunk
    xor r12d, r12d
.face:
    mov [f_d], r12d
    mov eax, r12d
    shl eax, 5
    lea rcx, [faces]
    add rcx, rax
    mov [f_rec], rcx
    call mesh_face
    inc r12d
    cmp r12d, 6
    jb .face

    ; ---- torches and other crossed-quad blocks (full detail only)
    cmp dword [m_s], 1
    jne .nocross
    cmp dword [has_cross], 0
    je .nocross
    xor r12d, r12d                  ; column
.xc:
    mov r13, r12
    shl r13, 8
    add r13, [rsp + 8]
    xor r14d, r14d                  ; y
.xy:
    cmp r14d, [m_cymax]
    ja .xcn
    movzx ecx, byte [r13 + r14]
    lea rax, [mesh_flags]
    test byte [rax + rcx], F_CROSS | F_FENCE | F_HALF
    jz .xyn
    mov edi, r12d
    and edi, 15
    mov esi, r14d
    mov edx, r12d
    shr edx, 4
    mov rax, [self_lt]
    mov r8, r12
    shl r8, 8
    add r8, r14
    movzx r8d, byte [rax + r8]
    lea rax, [mesh_flags]
    test byte [rax + rcx], F_FENCE | F_HALF
    jz .xcross
    call emit_fence
    jmp .xyn
.xcross:
    call emit_cross
.xyn:
    inc r14d
    jmp .xy
.xcn:
    inc r12d
    cmp r12d, 256
    jb .xc
.nocross:

    ; ---- concatenate the face bins: +X -X +Y -Y +Z -Z
    lea rdi, [mesh_buf_surf]
    xor r12d, r12d
    xor r13d, r13d                  ; total
.cat:
    lea rax, [n_bin]
    mov ecx, [rax + r12*4]
    mov [rbx + CI_FACECNT + r12*4], ecx
    add r13d, ecx
    mov eax, r12d
    imul rax, rax, MESH_BIN_CAP * VERT_SIZE
    lea rsi, [surf_bins]
    add rsi, rax
    shl ecx, 4
    rep movsb
    inc r12d
    cmp r12d, 6
    jb .cat
    mov [rbx + CI_NSURF], r13d
    mov eax, [n_deep]
    mov [rbx + CI_NDEEP], eax
    mov eax, [n_wat]
    mov [rbx + CI_NWAT], eax
    mov eax, [m_miny8]
    sar eax, 3
    mov [rbx + CI_MINY], eax
    mov eax, [rsp + 4]
    mov [rbx + CI_SCALE], al
    LEAVE_FN

NOEXECSTACK
