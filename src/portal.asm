; portal.asm - nether portals.
;
; An obsidian frame (any size from 2 x 3 to 21 x 21 inside, corners not
; needed) lit with flint and steel fills with portal. Standing in it for
; 3 seconds (creative: 1) takes the player to the other dimension, to
; x / 8, z / 8 in the nether (x 8 on the way back), next to a portal there
; within 16 nodes, or to a new one built on an obsidian platform. Breaking
; the frame (or anything next to the portal) takes the portal away.

%include "common.inc"

global portal_try, portal_break, portal_update, portal_t, portal_need, portal_link

extern pos, dt, game_mode, riding, dimension, world_get, world_set
extern block_flags, save_all, save_meta, dim_enter

MAX_SIDE    equ 21                  ; largest inside of a frame
FLOOD_MAX   equ 1024

section .rodata
align 4
f_half:     dd 0.5
f_one:      dd 1.0
f_need:     dd 3.0                  ; seconds in the portal (survival)
f_needc:    dd 1.0                  ; creative
f_15:       dd 1.5
nb6:        db 1,0,0, -1,0,0, 0,1,0, 0,-1,0, 0,0,1, 0,0,-1
; where else to try building, nearest first (x, z)
near_spots: db 3,0, -3,0, 0,3, 0,-3, 3,3, -3,3, 3,-3, -3,-3
            db 6,0, -6,0, 0,6, 0,-6, 6,6, -6,6, 6,-6, -6,-6
            db 9,0, -9,0, 0,9, 0,-9
NEAR_SPOTS equ ($ - near_spots) / 2

section .bss
alignb 16
portal_t:   resd 1                  ; seconds stood in a portal
portal_need: resd 1                 ; seconds it takes (for the screen tint)
portal_link: resd 5                 ; overworld x, z and nether x, z of the last
                                    ; trip in, valid (saved with the world)
flood:      resd 3 * FLOOD_MAX

section .text

; --- frame test helpers: the cell at offset a along the axis, height yy
; (r12 x, r13 z, r14 axis dx, r15 axis dz of the caller's frame)
%macro CELL 2                       ; a, yy -> edi, esi, edx
    mov eax, %1
    imul eax, r14d
    lea edi, [r12 + rax]
    mov esi, %2
    mov eax, %1
    imul eax, r15d
    lea edx, [r13 + rax]
%endmacro

; ZF set (je) when the block in eax lets a portal in: air or fire
%macro OPENB 0
    test eax, eax
    jz %%y
    cmp eax, B_FIRE
%%y:
%endmacro

; int portal_try(int x, int y, int z) - (x, y, z) is inside an obsidian
; frame: fill the frame with portal. 1 if it did.
; locals: [0] y, [4] axis, [8] y0, [12] y1, [16] a0, [20] a1, [24] a, [28] yy
portal_try:
    ENTER_FN 32
    mov r12d, edi
    mov [rsp], esi
    mov r13d, edx
    mov dword [rsp + 4], 0
.axis:
    mov r14d, 1                     ; along x
    xor r15d, r15d
    cmp dword [rsp + 4], 0
    je .ax
    xor r14d, r14d                  ; along z
    mov r15d, 1
.ax:
    ; down to the bottom of the frame
    mov ebx, [rsp]
    xor ecx, ecx
.down:
    CELL 0, ebx
    dec esi
    push rcx
    sub rsp, 8
    call world_get
    add rsp, 8
    pop rcx
    OPENB
    jne .bottom
    dec ebx
    inc ecx
    cmp ecx, MAX_SIDE
    jb .down
    jmp .next_axis
.bottom:
    cmp eax, B_OBSIDIAN
    jne .next_axis
    mov [rsp + 8], ebx              ; y0
    ; to the left and the right along the bottom row
    mov dword [rsp + 16], 0
.left:
    mov eax, [rsp + 16]
    dec eax
    mov [rsp + 24], eax
    CELL [rsp + 24], [rsp + 8]
    call world_get
    OPENB
    jne .lend
    dec dword [rsp + 16]
    cmp dword [rsp + 16], -MAX_SIDE
    jg .left
    jmp .next_axis
.lend:
    cmp eax, B_OBSIDIAN
    jne .next_axis
    mov dword [rsp + 20], 0
.right:
    mov eax, [rsp + 20]
    inc eax
    mov [rsp + 24], eax
    CELL [rsp + 24], [rsp + 8]
    call world_get
    OPENB
    jne .rend
    inc dword [rsp + 20]
    cmp dword [rsp + 20], MAX_SIDE
    jl .right
    jmp .next_axis
.rend:
    cmp eax, B_OBSIDIAN
    jne .next_axis
    mov eax, [rsp + 20]
    sub eax, [rsp + 16]
    inc eax                         ; width
    cmp eax, 2
    jb .next_axis
    cmp eax, MAX_SIDE
    ja .next_axis
    ; up the left column to the top of the frame
    mov eax, [rsp + 8]
    mov [rsp + 12], eax
.up:
    mov eax, [rsp + 12]
    inc eax
    mov [rsp + 28], eax
    CELL [rsp + 16], [rsp + 28]
    call world_get
    OPENB
    jne .uend
    inc dword [rsp + 12]
    mov eax, [rsp + 12]
    sub eax, [rsp + 8]
    cmp eax, MAX_SIDE
    jl .up
    jmp .next_axis
.uend:
    cmp eax, B_OBSIDIAN
    jne .next_axis
    mov eax, [rsp + 12]
    sub eax, [rsp + 8]
    inc eax                         ; height
    cmp eax, 3
    jb .next_axis
    mov eax, [rsp]
    cmp eax, [rsp + 12]
    jg .next_axis                   ; the lit cell is above this frame
    ; every cell inside open, the four sides obsidian
    mov eax, [rsp + 8]
    dec eax
    mov [rsp + 28], eax             ; yy from y0 - 1 to y1 + 1
.vy:
    mov eax, [rsp + 16]
    dec eax
    mov [rsp + 24], eax             ; a from a0 - 1 to a1 + 1
.va:
    CELL [rsp + 24], [rsp + 28]
    call world_get
    ; which part of the frame?
    xor ecx, ecx                    ; edges crossed
    mov edx, [rsp + 28]
    cmp edx, [rsp + 8]
    jl .ve1
    cmp edx, [rsp + 12]
    jle .ve2
.ve1:
    inc ecx
.ve2:
    mov edx, [rsp + 24]
    cmp edx, [rsp + 16]
    jl .ve3
    cmp edx, [rsp + 20]
    jle .ve4
.ve3:
    add ecx, 2
.ve4:
    cmp ecx, 3
    je .vnext                       ; a corner: anything
    test ecx, ecx
    jnz .vframe
    OPENB
    jne .next_axis
    jmp .vnext
.vframe:
    cmp eax, B_OBSIDIAN
    jne .next_axis
.vnext:
    inc dword [rsp + 24]
    mov eax, [rsp + 20]
    inc eax
    cmp [rsp + 24], eax
    jle .va
    inc dword [rsp + 28]
    mov eax, [rsp + 12]
    inc eax
    cmp [rsp + 28], eax
    jle .vy
    ; fill it
    mov eax, [rsp + 8]
    mov [rsp + 28], eax
.fy:
    mov eax, [rsp + 16]
    mov [rsp + 24], eax
.fa:
    CELL [rsp + 24], [rsp + 28]
    mov ecx, B_PORTAL
    call world_set
    inc dword [rsp + 24]
    mov eax, [rsp + 20]
    cmp [rsp + 24], eax
    jle .fa
    inc dword [rsp + 28]
    mov eax, [rsp + 12]
    cmp [rsp + 28], eax
    jle .fy
    mov eax, 1
    LEAVE_FN
.next_axis:
    inc dword [rsp + 4]
    cmp dword [rsp + 4], 2
    jb .axis
    xor eax, eax
    LEAVE_FN

; void portal_break(int x, int y, int z) - the node at (x, y, z) changed:
; portal next to it goes, and all the portal joined to that
portal_break:
    ENTER_FN 16
    xor r12d, r12d                  ; stack size
%macro FPUSH 0                      ; edi, esi, edx
    cmp r12d, FLOOD_MAX
    jae %%full
    imul eax, r12d, 12
    lea rcx, [flood]
    mov [rcx + rax], edi
    mov [rcx + rax + 4], esi
    mov [rcx + rax + 8], edx
    inc r12d
%%full:
%endmacro
    mov r13d, edi
    mov r14d, esi
    mov r15d, edx
    xor ebx, ebx
.seed:
    imul eax, ebx, 3
    lea rcx, [nb6]
    movsx edi, byte [rcx + rax]
    add edi, r13d
    movsx esi, byte [rcx + rax + 1]
    add esi, r14d
    movsx edx, byte [rcx + rax + 2]
    add edx, r15d
    FPUSH
    inc ebx
    cmp ebx, 6
    jb .seed
.pop:
    test r12d, r12d
    jz .out
    dec r12d
    imul eax, r12d, 12
    lea rcx, [flood]
    mov r13d, [rcx + rax]
    mov r14d, [rcx + rax + 4]
    mov r15d, [rcx + rax + 8]
    mov edi, r13d
    mov esi, r14d
    mov edx, r15d
    call world_get
    cmp eax, B_PORTAL
    jne .pop
    mov edi, r13d
    mov esi, r14d
    mov edx, r15d
    xor ecx, ecx
    call world_set
    xor ebx, ebx
.spread:
    imul eax, ebx, 3
    lea rcx, [nb6]
    movsx edi, byte [rcx + rax]
    add edi, r13d
    movsx esi, byte [rcx + rax + 1]
    add esi, r14d
    movsx edx, byte [rcx + rax + 2]
    add edx, r15d
    FPUSH
    inc ebx
    cmp ebx, 6
    jb .spread
    jmp .pop
.out:
    LEAVE_FN

; floor of xmm float %2 into %1 (xmm7 scratch)
%macro FLOORF 2
    cvttss2si %1, %2
    cvtsi2ss xmm7, %1
    comiss xmm7, %2
    jbe %%ok
    dec %1
%%ok:
%endmacro

; void portal_update(void) - standing in a portal long enough travels
portal_update:
    ENTER_FN 0
    mov eax, [f_need]
    cmp dword [game_mode], 0
    je .n
    mov eax, [f_needc]
.n:
    mov [portal_need], eax
    cmp dword [riding], 0
    jne .outside
    movss xmm0, [pos]
    FLOORF edi, xmm0
    movss xmm0, [pos + 4]
    addss xmm0, [f_half]
    FLOORF esi, xmm0
    movss xmm0, [pos + 8]
    FLOORF edx, xmm0
    call world_get
    cmp eax, B_PORTAL
    jne .outside
    movss xmm0, [portal_t]
    addss xmm0, [dt]
    movss [portal_t], xmm0
    comiss xmm0, [portal_need]
    jb .out
    mov dword [portal_t], 0
    call portal_travel
    jmp .out
.outside:
    mov dword [portal_t], 0
.out:
    LEAVE_FN

; portal_travel - to the other dimension
; locals: [0] target x, [4] target z, [8] best d2, [12] px, [16] py, [20] pz
portal_travel:
    ENTER_FN 32
    movss xmm0, [pos]
    FLOORF r12d, xmm0
    movss xmm0, [pos + 8]
    FLOORF r13d, xmm0
    cmp dword [dimension], 0
    jne .to_over
    mov [portal_link], r12d         ; remember the overworld portal
    mov [portal_link + 4], r13d
    sar r12d, 3                     ; to the nether: an eighth of the way
    sar r13d, 3
    jmp .go
.to_over:
    ; back through the portal we came out of: to the portal we went in by
    cmp dword [portal_link + 16], 0
    je .scale
    mov eax, r12d
    sub eax, [portal_link + 8]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, 16
    ja .scale
    mov eax, r13d
    sub eax, [portal_link + 12]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, 16
    ja .scale
    mov r12d, [portal_link]
    mov r13d, [portal_link + 4]
    jmp .go
.scale:
    shl r12d, 3
    add r12d, 4
    shl r13d, 3
    add r13d, 4
.go:
    mov [rsp], r12d
    mov [rsp + 4], r13d
    call save_all                   ; this dimension's changes
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [dimension]
    xor edx, 1
    call dim_enter                  ; empty world, chunks round the target
    ; a portal within 16 nodes (the nearest column, its lowest node)?
    mov dword [rsp + 8], 0x7fffffff
    mov r14d, -16                   ; dz
.sz:
    mov r15d, -16                   ; dx
.sx:
    mov ebx, WORLD_YMIN             ; y
.sy:
    lea edi, [r12 + r15]
    mov esi, ebx
    lea edx, [r13 + r14]
    call world_get
    cmp eax, B_PORTAL
    je .hit
    inc ebx
    cmp ebx, WORLD_YMIN + WORLD_H
    jl .sy
    jmp .snext
.hit:
    mov eax, r15d
    imul eax, eax
    mov ecx, r14d
    imul ecx, ecx
    add eax, ecx
    cmp eax, [rsp + 8]
    jae .snext
    mov [rsp + 8], eax
    lea eax, [r12 + r15]
    mov [rsp + 12], eax
    mov [rsp + 16], ebx
    lea eax, [r13 + r14]
    mov [rsp + 20], eax
.snext:
    inc r15d
    cmp r15d, 16
    jle .sx
    inc r14d
    cmp r14d, 16
    jle .sz
    cmp dword [rsp + 8], 0x7fffffff
    je .build
    ; next to the portal found: in front of its face
    mov edi, [rsp + 12]
    inc edi
    mov esi, [rsp + 16]
    mov edx, [rsp + 20]
    call world_get
    mov r14d, 0                     ; step along z out of the face
    mov r15d, 1
    cmp eax, B_PORTAL
    je .face
    mov edi, [rsp + 12]
    dec edi
    mov esi, [rsp + 16]
    mov edx, [rsp + 20]
    call world_get
    cmp eax, B_PORTAL
    je .face
    mov r14d, 1                     ; the portal runs along z: step along x
    xor r15d, r15d
.face:
    ; the side whose feet and head cells are free
    mov ebx, 1
.side:
    mov eax, ebx
    imul eax, r14d
    mov edi, [rsp + 12]
    add edi, eax
    mov esi, [rsp + 16]
    mov eax, ebx
    imul eax, r15d
    mov edx, [rsp + 20]
    add edx, eax
    push rdi
    push rdx
    call world_get
    pop rdx
    pop rdi
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID
    jz .stand
    neg ebx
    cmp ebx, 1
    jne .side
.stand:
    mov eax, ebx
    imul eax, r14d
    add eax, [rsp + 12]
    cvtsi2ss xmm0, eax
    addss xmm0, [f_half]
    movss [pos], xmm0
    cvtsi2ss xmm0, dword [rsp + 16]
    movss [pos + 4], xmm0
    mov eax, ebx
    imul eax, r15d
    add eax, [rsp + 20]
    cvtsi2ss xmm0, eax
    addss xmm0, [f_half]
    movss [pos + 8], xmm0
    jmp .done
.build:
    call find_floor                 ; ebx = feet y for the new portal
    test eax, eax
    jnz .place
    ; no room right there: look round about, nearest first
    xor r15d, r15d
.near:
    lea rax, [near_spots]
    movsx ecx, byte [rax + r15*2]
    mov r12d, [rsp]
    add r12d, ecx
    movsx ecx, byte [rax + r15*2 + 1]
    mov r13d, [rsp + 4]
    add r13d, ecx
    push r15
    sub rsp, 8
    call find_floor
    add rsp, 8
    pop r15
    test eax, eax
    jnz .place
    inc r15d
    cmp r15d, NEAR_SPOTS
    jb .near
    mov r12d, [rsp]                 ; nowhere: carve one out at the target
    mov r13d, [rsp + 4]
    xor ebx, ebx
.place:
    mov edi, r12d
    mov esi, ebx
    mov edx, r13d
    call build_portal
    cvtsi2ss xmm0, r12d
    addss xmm0, [f_one]
    movss [pos], xmm0
    cvtsi2ss xmm0, ebx
    movss [pos + 4], xmm0
    cvtsi2ss xmm0, r13d
    addss xmm0, [f_15]
    movss [pos + 8], xmm0
.done:
    cmp dword [dimension], 0
    je .saved
    movss xmm0, [pos]               ; where we came out in the nether
    FLOORF eax, xmm0
    mov [portal_link + 8], eax
    movss xmm0, [pos + 8]
    FLOORF eax, xmm0
    mov [portal_link + 12], eax
    mov dword [portal_link + 16], 1
.saved:
    call save_meta
    LEAVE_FN

; find_floor - feet height for a new portal at column (r12, r13) -> ebx,
; eax 1 if there is room. Nether: the lowest place above the lava sea with
; ground under 4 free nodes. Overworld: on top of the highest block.
find_floor:
    sub rsp, 8
    cmp dword [dimension], 0
    je .over
    mov ebx, WORLD_YMIN + NETHER_SEA + 1
.ny:
    mov edi, r12d
    lea esi, [rbx - 1]
    mov edx, r13d
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID
    jz .nnext
    xor r14d, r14d
.free:
    mov edi, r12d
    lea esi, [rbx + r14]
    mov edx, r13d
    call world_get
    test eax, eax
    jnz .nnext
    inc r14d
    cmp r14d, 4
    jb .free
    mov eax, 1
    jmp .out
.nnext:
    inc ebx
    cmp ebx, WORLD_YMIN + NETHER_TOP - 6
    jl .ny
    xor eax, eax                    ; no room in this column
    jmp .out
.over:
    mov ebx, WORLD_YMIN + WORLD_H - 1
.oy:
    mov edi, r12d
    mov esi, ebx
    mov edx, r13d
    call world_get
    test eax, eax
    jnz .top
    dec ebx
    cmp ebx, WORLD_YMIN
    jg .oy
.top:
    inc ebx
    mov eax, 1
.out:
    add rsp, 8
    ret

; build_portal(x, y, z) - a lit 2 x 3 portal across x at (x..x+1, y..y+2,
; z) in an obsidian frame, on a 4 x 3 obsidian platform with room around
; locals: [0] x, [4] y, [8] z
build_portal:
    ENTER_FN 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov r12d, -1                    ; a
.a:
    mov r13d, -1                    ; y offset
.y:
    mov r14d, -1                    ; z offset
.z:
    xor ecx, ecx                    ; air
    cmp r13d, -1
    je .obs                         ; the platform
    test r14d, r14d
    jnz .set
    cmp r12d, -1                    ; the frame: sides and top
    je .obs
    cmp r12d, 2
    je .obs
    cmp r13d, 3
    je .obs
    mov ecx, B_PORTAL
    jmp .set
.obs:
    mov ecx, B_OBSIDIAN
.set:
    mov edi, [rsp]
    add edi, r12d
    mov esi, [rsp + 4]
    add esi, r13d
    mov edx, [rsp + 8]
    add edx, r14d
    call world_set
    inc r14d
    cmp r14d, 1
    jle .z
    inc r13d
    cmp r13d, 3
    jle .y
    inc r12d
    cmp r12d, 2
    jle .a
    LEAVE_FN

NOEXECSTACK
