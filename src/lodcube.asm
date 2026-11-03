; lodcube.asm - the near horizon rings as big textured cubes.
;
; Just outside the real chunks the far terrain is drawn as cubes 8 nodes
; wide, further out 16 wide (one per chunk), before the smooth shell takes
; over. Each column is the exact ground height plus the solid 8-node
; mountain levels above it, so overhangs and floating islands keep the air
; under them. Faces use the block atlas (grass, dirt, stone, snow, sand,
; water), walls appear wherever the neighbouring column (real, cube or
; smooth) is lower, so nothing is left open between the rings.
;
; Positions are in 1/8 nodes from the tile corner, like the smooth shell;
; texture coordinates are atlas texels at 16 px (the unit-2 texture matrix
; scales them), one 8 x 8 repeat per face: 16-node cubes show the
; textures at half resolution.

%include "common.inc"

global build_cubes, cz_buf, cz_n, cube_r1sq, cube_r2sq

extern hz_cols, hz_tops, hz_heights, cur_pcx, cur_pcz, spiral_r2
extern block_tiles

HZ_CELLS    equ 34
HZ_DATA     equ HZ_CELLS * HZ_CELLS
HZ_CMAXV    equ 65536               ; vertices per tile's cube mesh
SNOWLINE    equ 110
CLS_REAL    equ 0
CLS_CUBE8   equ 1
CLS_CUBE16  equ 2
CLS_SMOOTH  equ 3
MAXIV       equ 20                  ; solid intervals per column (17 at most)

section .rodata
align 4
dir_off:    dd 1, -1, HZ_CELLS, -HZ_CELLS   ; +x -x +z -z in the work grid

section .bss
alignb 16
cz_buf:     resb HZ_CMAXV * VERT_SIZE
cz_n:       resd 1
cube_r1sq:  resd 1                  ; chunk distance^2: 8-node cubes inside
cube_r2sq:  resd 1                  ; 16-node cubes inside, smooth beyond
cw_ground:  resd HZ_DATA            ; per cell: top solid node of the ground
cw_mask:    resd HZ_DATA            ; solid mountain levels above it
cw_far:     resd HZ_DATA            ; height the smooth shell uses
cw_top:     resb HZ_DATA            ; top block, bit 7 forest
cw_cls:     resb HZ_DATA            ; CLS_*
alignb 4
iv_a:       resd MAXIV * 2          ; this column: [bottom, top) node pairs
iv_b:       resd MAXIV * 2          ; the neighbour's
n_a:        resd 1
n_b:        resd 1
; the cell being meshed
c_w:        resd 1                  ; work index
c_sc:       resd 1                  ; 1 = 8-node cubes, 2 = 16-node cubes
c_x0:       resd 1                  ; box in 1/8 nodes
c_z0:       resd 1
c_x1:       resd 1
c_z1:       resd 1
c_tx1:      resd 1                  ; top/bottom face box (16-node: group)
c_tz1:      resd 1
c_block:    resd 1                  ; block of the interval being drawn
c_itop:     resd 1                  ; its top (nodes)
c_dir:      resd 1                  ; wall direction 0..3: +x -x +z -z
c_ui:       resd 1                  ; this interval index
c_cur:      resd 1
c_i:        resd 1                  ; cell in the tile, 0..31
c_j:        resd 1
; one quad: 4 x (x, y, z, u, v), colour
q_c:        resd 20
q_col:      resd 1

section .text

; eax = tiles of block edi: top | side << 8 | filler << 16
tiles_of:
    lea rax, [block_tiles]
    movzx ecx, byte [rax + rdi*4]
    movzx edx, byte [rax + rdi*4 + 1]
    shl edx, 8
    or ecx, edx
    ; what lies under the top: dirt under grass, sand under sand ...
    mov edx, 1                      ; dirt tile
    cmp edi, B_GRASS
    je .f
    cmp edi, B_SNOWDIRT
    je .f
    cmp edi, B_DRYGRASS
    je .f
    cmp edi, B_DIRT
    je .f
    movzx edx, byte [rax + rdi*4 + 1]
    cmp edi, B_SAND
    je .f
    cmp edi, B_DSAND
    je .f
    cmp edi, B_WATER
    je .f
    cmp edi, B_GRAVEL
    je .f
    xor edx, edx                    ; stone
.f:
    shl edx, 16
    or ecx, edx
    mov eax, ecx
    ret

; colour dword for face shade edi (sky light, no block light)
shade_col:
    mov eax, edi
    imul eax, eax, 13
    shr eax, 8                      ; light curve at block light 0
    shl eax, 24
    mov ecx, edi
    shl ecx, 8
    or ecx, edi
    shl ecx, 8
    or ecx, edi
    or eax, ecx
    ret

; append q_c / q_col as a quad
emit_quad:
    mov eax, [cz_n]
    cmp eax, HZ_CMAXV - 4
    ja .full
    lea rdx, [cz_buf]
    shl rax, 4
    add rdx, rax
    lea r8, [q_c]
    mov r9d, [q_col]
    mov ecx, 4
.v:
    mov eax, [r8]
    mov [rdx], ax
    mov eax, [r8 + 4]
    mov [rdx + 2], ax
    mov eax, [r8 + 8]
    mov [rdx + 4], ax
    mov word [rdx + 6], 0
    mov eax, [r8 + 12]
    mov [rdx + 8], ax
    mov eax, [r8 + 16]
    mov [rdx + 10], ax
    mov [rdx + 12], r9d
    add r8, 20
    add rdx, VERT_SIZE
    dec ecx
    jnz .v
    add dword [cz_n], 4
.full:
    ret

; corner k: x, y, z, u, v
%macro QC 6
    mov dword [q_c + %1 * 20], %2
    mov dword [q_c + %1 * 20 + 4], %3
    mov dword [q_c + %1 * 20 + 8], %4
    mov dword [q_c + %1 * 20 + 12], %5
    mov dword [q_c + %1 * 20 + 16], %6
%endmacro

; eax = make_iv(edi ground, esi mask, rdx out) - solid intervals of a
; column: the ground from the bottom, then mountain levels, merged
make_iv:
    mov dword [rdx], WORLD_YMIN
    lea eax, [rdi + 1]
    mov [rdx + 4], eax
    mov r8d, 1
    xor ecx, ecx
.k:
    bt esi, ecx
    jnc .n
    lea r9d, [rcx*8 + WORLD_YMIN]   ; level bottom
    lea r10d, [r9 + 8]              ; and top
    lea r11, [rdx + r8*8 - 8]       ; last interval
    cmp r9d, [r11 + 4]
    jg .new
    cmp r10d, [r11 + 4]
    jle .n
    mov [r11 + 4], r10d
    jmp .n
.new:
    mov [rdx + r8*8], r9d
    mov [rdx + r8*8 + 4], r10d
    inc r8d
.n:
    inc ecx
    cmp ecx, 32
    jb .k
    mov eax, r8d
    ret

; block for interval c_ui's top surface: the column's top block, snow
; above the snow line (not in deserts) -> c_block
interval_block:
    mov eax, [c_w]
    lea rcx, [cw_top]
    movzx eax, byte [rcx + rax]
    and eax, 0x7f
    mov ecx, [c_itop]
    cmp ecx, SNOWLINE + 1
    jl .b
    cmp eax, B_DSAND
    je .b
    cmp eax, B_WATER
    je .b
    mov eax, B_SNOW
.b:
    mov [c_block], eax
    ret

; tu, tv of tile edi -> esi, edi
tile_uv:
    mov esi, edi
    and esi, 15
    shl esi, 7
    shr edi, 4
    shl edi, 7
    ret

; ---------------------------------------------------------------------------
; top and bottom faces of every interval of the cell (box c_x0..c_tx1)
cell_tops:
    push rbx
    push r12
    sub rsp, 8
    xor ebx, ebx
.iv:
    cmp ebx, [n_a]
    jae .out
    lea rdx, [iv_a]
    mov eax, [rdx + rbx*8 + 4]
    mov [c_itop], eax
    call interval_block
    mov edi, [c_block]
    call tiles_of
    movzx edi, al
    mov r12d, 255                   ; shade
    ; forest: from afar the canopy is what shows, a dark green
    test ebx, ebx
    jnz .lit
    mov eax, [c_w]
    lea rcx, [cw_top]
    test byte [rcx + rax], 0x80
    jz .lit
    cmp dword [c_block], B_SNOW
    je .lit
    cmp dword [c_block], B_DSAND
    je .lit
    mov edi, 2                      ; grass top tile
    mov r12d, 130
.lit:
    call tile_uv
    mov eax, [c_itop]
    shl eax, 3                      ; y in 1/8 nodes
    cmp dword [c_block], B_WATER
    jne .y
    mov eax, WATER_LEVEL * 8 + 7    ; water surface sits 1/8 low
.y:
    mov r8d, [c_x0]
    mov r9d, [c_z0]
    mov r10d, [c_tx1]
    mov r11d, [c_tz1]
    lea ecx, [rsi + 128]
    lea edx, [rdi + 128]
    QC 0, r8d, eax, r9d, esi, edi
    QC 1, r8d, eax, r11d, esi, edx
    QC 2, r10d, eax, r11d, ecx, edx
    QC 3, r10d, eax, r9d, ecx, edi
    mov edi, r12d
    call shade_col
    mov [q_col], eax
    call emit_quad
    ; underside of a floating or overhanging interval
    lea rdx, [iv_a]
    mov eax, [rdx + rbx*8]
    cmp eax, WORLD_YMIN
    jle .next
    shl eax, 3
    xor esi, esi                    ; stone tile 0
    xor edi, edi
    mov r8d, [c_x0]
    mov r9d, [c_z0]
    mov r10d, [c_tx1]
    mov r11d, [c_tz1]
    QC 0, r8d, eax, r9d, 0, 0
    QC 1, r10d, eax, r9d, 128, 0
    QC 2, r10d, eax, r11d, 128, 128
    QC 3, r8d, eax, r11d, 0, 128
    mov edi, 128
    call shade_col
    mov [q_col], eax
    call emit_quad
.next:
    inc ebx
    jmp .iv
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; one wall quad of direction c_dir from y edi up to esi (nodes), tile edx
wall_quad:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14d, edx
    mov r12d, edi
    shl r12d, 3                     ; ya in 1/8 nodes
    mov r13d, esi
    shl r13d, 3                     ; yb
    mov eax, esi
    sub eax, edi
    shl eax, 4                      ; texels at 16 px per node
    cmp dword [c_sc], 2
    jne .v1
    shr eax, 1
.v1:
    mov r15d, eax
    mov edi, r14d
    call tile_uv                    ; esi tu, edi tv (top of the wall)
    lea ebx, [rdi + r15]            ; v at the bottom
    mov eax, 128
    cmp dword [c_sc], 2
    jne .h1
    mov eax, 64                     ; a 16-node cube's wall per 8-node cell
.h1:
    lea ecx, [rsi + rax]
    mov r8d, [c_x0]
    mov r9d, [c_z0]
    mov r10d, [c_x1]
    mov r11d, [c_z1]
    mov eax, [c_dir]
    cmp eax, 1
    je .nx
    cmp eax, 2
    je .pz
    cmp eax, 3
    je .nz
    QC 0, r10d, r12d, r11d, esi, ebx
    QC 1, r10d, r12d, r9d, ecx, ebx
    QC 2, r10d, r13d, r9d, ecx, edi
    QC 3, r10d, r13d, r11d, esi, edi
    mov edx, 204
    jmp .emit
.nx:
    QC 0, r8d, r12d, r9d, esi, ebx
    QC 1, r8d, r12d, r11d, ecx, ebx
    QC 2, r8d, r13d, r11d, ecx, edi
    QC 3, r8d, r13d, r9d, esi, edi
    mov edx, 204
    jmp .emit
.pz:
    QC 0, r8d, r12d, r11d, esi, ebx
    QC 1, r10d, r12d, r11d, ecx, ebx
    QC 2, r10d, r13d, r11d, ecx, edi
    QC 3, r8d, r13d, r11d, esi, edi
    mov edx, 170
    jmp .emit
.nz:
    QC 0, r10d, r12d, r9d, esi, ebx
    QC 1, r8d, r12d, r9d, ecx, ebx
    QC 2, r8d, r13d, r9d, ecx, edi
    QC 3, r10d, r13d, r9d, esi, edi
    mov edx, 170
.emit:
    mov edi, edx
    call shade_col
    mov [q_col], eax
    call emit_quad
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; the visible part y edi .. esi of a wall of the interval topped at c_itop:
; the top block's side strip, then its filler, then stone, cut into pieces
; no taller than one texture repeat block (8 nodes x scale)
wall_piece:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                   ; bottom
    mov r13d, esi                   ; top of what is left
    mov edi, [c_block]
    call tiles_of
    mov r14d, eax
    mov r15d, [c_sc]
.loop:
    cmp r13d, r12d
    jle .out
    mov eax, [c_itop]
    sub eax, r13d                   ; depth below the surface
    cmp eax, r15d
    jge .b2
    mov ebx, [c_itop]
    sub ebx, r15d
    mov ecx, r14d
    shr ecx, 8
    and ecx, 0xff                   ; side tile
    jmp .cut
.b2:
    lea ecx, [r15*4]
    cmp eax, ecx
    jge .b3
    mov ebx, [c_itop]
    sub ebx, ecx
    mov ecx, r14d
    shr ecx, 16
    and ecx, 0xff                   ; filler tile
    jmp .cut
.b3:
    mov ebx, WORLD_YMIN - 1000
    xor ecx, ecx                    ; stone
.cut:
    mov eax, r13d
    mov edx, r15d
    shl edx, 3
    sub eax, edx
    cmp ebx, eax
    cmovl ebx, eax
    cmp ebx, r12d
    cmovl ebx, r12d
    mov edi, ebx
    mov esi, r13d
    mov edx, ecx
    call wall_quad
    mov r13d, ebx
    jmp .loop
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; walls of the cell toward c_dir: where this column is solid and the
; neighbour's (real, cube or smooth) is not
cell_walls:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, [c_dir]
    lea rcx, [dir_off]
    mov edx, [c_w]
    add edx, [rcx + rax*4]
    mov r12d, edx                   ; neighbour
    lea rcx, [cw_cls]
    movzx r13d, byte [rcx + r12]
    ; nothing between two cells of one 16-node cube
    cmp dword [c_sc], 2
    jne .nb
    cmp r13d, CLS_CUBE16
    jne .nb
    mov eax, [c_dir]
    mov ecx, [c_i]
    cmp eax, 2
    jb .xi
    mov ecx, [c_j]
.xi:
    and ecx, 1                      ; 1 = far half of the group
    and eax, 1                      ; 1 = negative direction
    cmp eax, ecx
    je .out                         ; +dir from the near half, -dir from the far half
.nb:
    cmp r13d, CLS_SMOOTH
    jne .cubeiv
    mov dword [iv_b], WORLD_YMIN
    lea rcx, [cw_far]
    mov eax, [rcx + r12*4]
    inc eax
    mov [iv_b + 4], eax
    mov dword [n_b], 1
    jmp .sub
.cubeiv:
    lea rcx, [cw_ground]
    mov edi, [rcx + r12*4]
    lea rcx, [cw_mask]
    mov esi, [rcx + r12*4]
    lea rdx, [iv_b]
    call make_iv
    mov [n_b], eax
.sub:
    xor ebx, ebx                    ; our interval
.a:
    cmp ebx, [n_a]
    jae .out
    lea r11, [iv_a]
    mov eax, [r11 + rbx*8 + 4]
    mov [c_itop], eax
    call interval_block
    lea r11, [iv_a]
    mov r14d, [r11 + rbx*8]        ; lowest y not yet covered
    lea r11, [iv_a]
    mov r15d, [r11 + rbx*8 + 4]
    xor r12d, r12d                  ; their interval
.b:
    cmp r12d, [n_b]
    jae .rest
    lea r11, [iv_b]
    mov eax, [r11 + r12*8 + 4]
    cmp eax, r14d
    jle .bn                         ; theirs ends below
    lea r11, [iv_b]
    mov ecx, [r11 + r12*8]
    cmp ecx, r15d
    jge .rest                       ; theirs starts above ours
    cmp ecx, r14d
    jle .covered
    push rax
    push rcx
    mov edi, r14d
    mov esi, ecx
    call wall_piece
    pop rcx
    pop rax
.covered:
    cmp eax, r14d
    cmovg r14d, eax
    cmp r14d, r15d
    jge .an
.bn:
    inc r12d
    jmp .b
.rest:
    cmp r14d, r15d
    jge .an
    mov edi, r14d
    mov esi, r15d
    call wall_piece
.an:
    inc ebx
    jmp .a
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; build_cubes(edi slot) - the tile's cube rings into cz_buf (cz_n vertices)
; locals: [0] tile chunk x, [4] tile chunk z
build_cubes:
    ENTER_FN 16
    mov r12d, edi
    imul eax, r12d, HZ_DATA * 8
    lea r13, [hz_cols]
    add r13, rax
    imul eax, r12d, HZ_DATA
    lea r14, [hz_tops]
    add r14, rax
    imul eax, r12d, HZ_DATA * 2
    lea rbx, [hz_heights]
    add rbx, rax
    mov [rsp], esi
    mov [rsp + 4], edx

    ; ---- every work cell: its column and which ring it is in
    xor r15d, r15d
.fa:
    mov r8d, [r13 + r15*8]          ; mountain mask
    movsx r9d, word [r13 + r15*8 + 4] ; ground
    movzx r10d, byte [r14 + r15]
    movsx r11d, word [rbx + r15*2]  ; height of the smooth shell
    mov eax, r10d
    and eax, 0x7f
    cmp eax, B_WATER
    jne .fa1
    mov r9d, WATER_LEVEL            ; water: solid up to its surface
    mov r11d, WATER_LEVEL
    xor r8d, r8d
.fa1:
    lea rax, [cw_mask]
    mov [rax + r15*4], r8d
    lea rax, [cw_ground]
    mov [rax + r15*4], r9d
    lea rax, [cw_far]
    mov [rax + r15*4], r11d
    lea rax, [cw_top]
    mov [rax + r15], r10b
    mov eax, r15d
    xor edx, edx
    mov ecx, HZ_CELLS
    div ecx                         ; eax = j + 1, edx = i + 1
    lea ecx, [rdx*8 - 4]            ; cell centre x (nodes)
    sar ecx, 4
    add ecx, [rsp]
    sub ecx, [cur_pcx]
    imul ecx, ecx
    lea eax, [rax*8 - 4]
    sar eax, 4
    add eax, [rsp + 4]
    sub eax, [cur_pcz]
    imul eax, eax
    add eax, ecx
    xor ecx, ecx
    cmp eax, [spiral_r2]
    jbe .cls
    mov ecx, CLS_CUBE8
    cmp eax, [cube_r1sq]
    jbe .cls
    mov ecx, CLS_CUBE16
    cmp eax, [cube_r2sq]
    jbe .cls
    mov ecx, CLS_SMOOTH
.cls:
    lea rax, [cw_cls]
    mov [rax + r15], cl
    inc r15d
    cmp r15d, HZ_DATA
    jb .fa

    ; ---- 16-node cubes: one column per chunk, averaged from its 4 cells
    xor r15d, r15d                  ; group
.gb:
    mov eax, r15d
    and eax, 15
    lea eax, [rax*2 + 1]
    mov ecx, r15d
    shr ecx, 4
    lea ecx, [rcx*2 + 1]
    imul ecx, ecx, HZ_CELLS
    add ecx, eax                    ; work index of the group's first cell
    lea rdx, [cw_cls]
    cmp byte [rdx + rcx], CLS_CUBE16
    jne .gn
    ; mostly water: the whole cube is water; otherwise its water cells
    ; take a land block so no water shows on a raised column
    lea rdx, [cw_top]
    xor r8d, r8d                    ; water cells
    xor r9d, r9d                    ; a land top
%macro WCNT 1
    movzx eax, byte [rdx + rcx + %1]
    mov esi, eax
    and esi, 0x7f
    cmp esi, B_WATER
    jne %%land
    inc r8d
    jmp %%d
%%land:
    mov r9d, eax
%%d:
%endmacro
    WCNT 0
    WCNT 1
    WCNT HZ_CELLS
    WCNT HZ_CELLS + 1
    test r8d, r8d
    jz .avg
    cmp r8d, 2
    jb .landtop
    lea rdx, [cw_top]
    mov byte [rdx + rcx], B_WATER
    mov byte [rdx + rcx + 1], B_WATER
    mov byte [rdx + rcx + HZ_CELLS], B_WATER
    mov byte [rdx + rcx + HZ_CELLS + 1], B_WATER
%macro SETD4 2                      ; dword array, value
    lea rdx, [%1]
    mov dword [rdx + rcx*4], %2
    mov dword [rdx + rcx*4 + 4], %2
    mov dword [rdx + rcx*4 + HZ_CELLS * 4], %2
    mov dword [rdx + rcx*4 + HZ_CELLS * 4 + 4], %2
%endmacro
    SETD4 cw_ground, WATER_LEVEL
    SETD4 cw_far, WATER_LEVEL
    SETD4 cw_mask, 0
    jmp .gn
.landtop:
%macro LANDTOP 1
    movzx eax, byte [rdx + rcx + %1]
    and eax, 0x7f
    cmp eax, B_WATER
    jne %%k
    mov [rdx + rcx + %1], r9b
%%k:
%endmacro
    LANDTOP 0
    LANDTOP 1
    LANDTOP HZ_CELLS
    LANDTOP HZ_CELLS + 1
.avg:
%macro AVG4 1
    lea rdx, [%1]
    mov eax, [rdx + rcx*4]
    add eax, [rdx + rcx*4 + 4]
    add eax, [rdx + rcx*4 + HZ_CELLS * 4]
    add eax, [rdx + rcx*4 + HZ_CELLS * 4 + 4]
    add eax, 2
    sar eax, 2
    mov [rdx + rcx*4], eax
    mov [rdx + rcx*4 + 4], eax
    mov [rdx + rcx*4 + HZ_CELLS * 4], eax
    mov [rdx + rcx*4 + HZ_CELLS * 4 + 4], eax
%endmacro
    AVG4 cw_ground
    AVG4 cw_far
    ; a level is solid where at least 2 of the 4 cells have it
    lea rdx, [cw_mask]
    mov r8d, [rdx + rcx*4]
    mov r9d, [rdx + rcx*4 + 4]
    mov r10d, [rdx + rcx*4 + HZ_CELLS * 4]
    mov r11d, [rdx + rcx*4 + HZ_CELLS * 4 + 4]
    mov eax, r9d
    or eax, r10d
    or eax, r11d
    and eax, r8d
    mov esi, r10d
    or esi, r11d
    and esi, r9d
    or eax, esi
    mov esi, r10d
    and esi, r11d
    or eax, esi
    mov [rdx + rcx*4], eax
    mov [rdx + rcx*4 + 4], eax
    mov [rdx + rcx*4 + HZ_CELLS * 4], eax
    mov [rdx + rcx*4 + HZ_CELLS * 4 + 4], eax
.gn:
    inc r15d
    cmp r15d, 256
    jb .gb

    ; ---- faces
    mov dword [cz_n], 0
    xor r15d, r15d                  ; j
.ej:
    xor r14d, r14d                  ; i
.ei:
    lea eax, [r15 + 1]
    imul eax, eax, HZ_CELLS
    lea eax, [rax + r14 + 1]
    mov [c_w], eax
    lea rcx, [cw_cls]
    movzx ecx, byte [rcx + rax]
    cmp ecx, CLS_CUBE8
    jb .en
    cmp ecx, CLS_CUBE16
    ja .en
    mov [c_sc], ecx
    cmp dword [cz_n], HZ_CMAXV - 512
    ja .done
    mov [c_i], r14d
    mov [c_j], r15d
    mov eax, r14d
    shl eax, 6
    mov [c_x0], eax
    add eax, 64
    mov [c_x1], eax
    mov [c_tx1], eax
    mov eax, r15d
    shl eax, 6
    mov [c_z0], eax
    add eax, 64
    mov [c_z1], eax
    mov [c_tz1], eax
    mov eax, [c_w]
    lea rcx, [cw_ground]
    mov edi, [rcx + rax*4]
    lea rcx, [cw_mask]
    mov esi, [rcx + rax*4]
    lea rdx, [iv_a]
    call make_iv
    mov [n_a], eax
    ; tops: every 8-node cube; a 16-node cube once, from its first cell
    cmp dword [c_sc], CLS_CUBE8
    je .tops
    test r14d, 1
    jnz .walls
    test r15d, 1
    jnz .walls
    add dword [c_tx1], 64
    add dword [c_tz1], 64
.tops:
    call cell_tops
.walls:
    mov dword [c_dir], 0
    call cell_walls
    mov dword [c_dir], 1
    call cell_walls
    mov dword [c_dir], 2
    call cell_walls
    mov dword [c_dir], 3
    call cell_walls
.en:
    inc r14d
    cmp r14d, 32
    jb .ei
    inc r15d
    cmp r15d, 32
    jb .ej
.done:
    LEAVE_FN

NOEXECSTACK
