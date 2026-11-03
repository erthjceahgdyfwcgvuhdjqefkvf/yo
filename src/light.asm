; light.asm - sunlight and block light, 0-15 per node like Minecraft.
;
; chunk_light holds one byte per node: low nibble = sky light, high nibble
; = block light (torches, burning furnaces). light_chunk recomputes a whole
; chunk:
;   1. sky light falls straight down each column at 15 until something
;      opaque (leaves take 1, water 2 per node), block light starts at
;      emitters
;   2. optionally, light from the four neighbouring chunks leaks in at the
;      borders
;   3. both spread by breadth-first search, losing 1 per node, through
;      everything that is not opaque
; Day and night are not baked in: the renderer scales sky light by the
; daylight factor when drawing, so the sun setting costs no re-meshing.
;
; Thread-safe per queue: the world-gen thread and the main thread each pass
; their own flag so they never share a BFS queue.

%include "common.inc"

global light_chunk, chunk_light, light_emit, light_get

extern chunk_blocks, chunk_info, block_flags, world_find

LQ_SIZE     equ 65536               ; BFS queue entries (u16 node index)
LF_NEIGHBOURS equ 1                 ; take light from loaded neighbours
LF_WORKER   equ 2                   ; caller is the world-gen thread

section .rodata
; light given off by each block
light_emit:
    times B_FURNACE_LIT db 0
    db 13                           ; burning furnace
    db 14                           ; torch
    times B_LAVA - B_TORCH - 1 db 0
    times 4 db 15                   ; lava, still and flowing
    db 0, 0                         ; obsidian, TNT
    db 15                           ; fire
    db 0                            ; netherrack
    db 11                           ; nether portal
    times B_BEACON - B_PORTAL - 1 db 0  ; slime block, stained glass
    db 15                           ; beacon
    times 256 - B_BEACON - 1 db 0

section .bss
alignb 4096
chunk_light:    resb NUM_SLOTS * CHUNK_VOX
alignb 16
q_main_sky:     resw LQ_SIZE
q_main_blk:     resw LQ_SIZE
q_work_sky:     resw LQ_SIZE
q_work_blk:     resw LQ_SIZE

section .text

; int light_get(int x, int y, int z) - light byte at a world position
; (sky 15 above the world, 0 below or when not loaded)
light_get:
    add esi, -WORLD_YMIN
    js .dark
    cmp esi, WORLD_H
    jae .sky
    mov r8d, edi
    mov r9d, edx
    mov r10d, esi
    sar edi, 4
    mov esi, edx
    sar esi, 4
    call world_find
    test eax, eax
    js .sky
    shl eax, 16
    and r9d, 15
    shl r9d, 12
    or eax, r9d
    and r8d, 15
    shl r8d, 8
    or eax, r8d
    or eax, r10d
    lea rcx, [chunk_light]
    movzx eax, byte [rcx + rax]
    ret
.dark:
    xor eax, eax
    ret
.sky:
    mov eax, 15
    ret

; BFS over one nibble.
; rdi blocks, rsi light, rdx queue, ecx head count (entries already queued
; from 0), r8d shift (0 = sky, 4 = block)
; Clobbers rax, rcx, rdx and r8-r11.
bfs:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                    ; blocks
    mov r13, rsi                    ; light
    mov r14, rdx                    ; queue
    mov r15d, ecx                   ; tail
    xor ebx, ebx                    ; head
    mov ecx, r8d                    ; shift stays in cl
    lea r11, [block_flags]
.pop:
    cmp ebx, r15d
    je .done
    mov eax, ebx
    and eax, LQ_SIZE - 1
    movzx r9d, word [r14 + rax*2]   ; node
    inc ebx
    movzx eax, byte [r13 + r9]
    shr eax, cl
    and eax, 15
    cmp eax, 1
    jbe .pop
    lea r10d, [rax - 1]             ; level for neighbours
; TRY offset - spread to node r9 + offset
%macro TRY 1
    lea edx, [r9 + %1]
    movzx eax, byte [r12 + rdx]
    test byte [r11 + rax], F_OPAQUE
    jnz %%skip
    movzx eax, byte [r13 + rdx]
    mov r8d, eax
    shr eax, cl
    and eax, 15
    cmp eax, r10d
    jae %%skip
    ; set the nibble to r10
    mov eax, 15
    shl eax, cl
    not eax
    and r8d, eax
    mov eax, r10d
    shl eax, cl
    or r8d, eax
    mov [r13 + rdx], r8b
    mov eax, r15d
    sub eax, ebx
    cmp eax, LQ_SIZE - 1
    jae %%skip
    mov eax, r15d
    and eax, LQ_SIZE - 1
    mov [r14 + rax*2], dx
    inc r15d
%%skip:
%endmacro
    ; +x: lx < 15
    mov eax, r9d
    shr eax, 8
    and eax, 15
    cmp eax, 15
    je .nx
    TRY 256
.nx:
    mov eax, r9d
    shr eax, 8
    and eax, 15
    test eax, eax
    jz .pz
    TRY -256
.pz:
    mov eax, r9d
    shr eax, 12
    cmp eax, 15
    je .nz
    TRY 4096
.nz:
    mov eax, r9d
    shr eax, 12
    test eax, eax
    jz .py
    TRY -4096
.py:
    mov eax, r9d
    and eax, 255
    cmp eax, 255
    je .ny
    TRY 1
.ny:
    mov eax, r9d
    and eax, 255
    test eax, eax
    jz .pop
    TRY -1
    jmp .pop
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; void light_chunk(int slot, int flags)
; locals: [0] slot, [4] flags, [8] blocks, [16] light, [24] sky queue,
;         [32] block queue, [40] sky tail, [44] block tail, [48] neighbour
;         light pointer, [56] side
light_chunk:
    ENTER_FN 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov eax, edi
    shl rax, 16
    lea rcx, [chunk_blocks]
    add rcx, rax
    mov [rsp + 8], rcx
    lea rcx, [chunk_light]
    add rcx, rax
    mov [rsp + 16], rcx
    lea rax, [q_main_sky]
    lea rcx, [q_main_blk]
    test esi, LF_WORKER
    jz .q
    lea rax, [q_work_sky]
    lea rcx, [q_work_blk]
.q:
    mov [rsp + 24], rax
    mov [rsp + 32], rcx
    xor eax, eax
    mov [rsp + 40], eax
    mov [rsp + 44], eax

    ; ---- 1. columns of sunlight, emitters
    mov r12, [rsp + 8]              ; blocks
    mov r13, [rsp + 16]             ; light
    lea r14, [block_flags]
    lea r15, [light_emit]
    xor ebx, ebx                    ; column
.col:
    mov r8d, 15                     ; sky level falling down
    mov r9d, ebx
    shl r9d, 8
    add r9d, 255                    ; node index, top of column
.down:
    movzx eax, byte [r12 + r9]
    movzx ecx, byte [r14 + rax]
    test ecx, F_OPAQUE
    jz .clear
    xor r8d, r8d
    jmp .store
.clear:
    test ecx, F_LIQUID
    jz .notliq
    sub r8d, 2
    jns .store
    xor r8d, r8d
    jmp .store
.notliq:
    test ecx, F_ALPHA               ; leaves (glass too: close enough)
    jz .store
    test r8d, r8d
    jz .store
    dec r8d
.store:
    movzx ecx, byte [r15 + rax]     ; emitted block light
    shl ecx, 4
    or ecx, r8d
    mov [r13 + r9], cl
    test cl, 0xf0
    jz .noemit
    mov rdx, [rsp + 32]
    mov eax, [rsp + 44]
    mov [rdx + rax*2], r9w
    inc dword [rsp + 44]
.noemit:
    test r9d, 255
    jz .coldone
    dec r9d
    jmp .down
.coldone:
    inc ebx
    cmp ebx, 256
    jb .col

    ; ---- seeds for sideways sunlight: lit nodes next to darker clear ones
    xor r9d, r9d                    ; node
.seed:
    movzx eax, byte [r13 + r9]
    and eax, 15
    cmp eax, 2
    jb .seed_next
    lea r10d, [rax - 1]
    ; a clear side neighbour inside the chunk that is darker by 2+
    mov eax, r9d
    shr eax, 8
    and eax, 15
    cmp eax, 15
    je .s1
    lea edx, [r9 + 256]
    call .is_darker
    jc .push_seed
.s1:
    mov eax, r9d
    shr eax, 8
    and eax, 15
    test eax, eax
    jz .s2
    lea edx, [r9 - 256]
    call .is_darker
    jc .push_seed
.s2:
    mov eax, r9d
    shr eax, 12
    cmp eax, 15
    je .s3
    lea edx, [r9 + 4096]
    call .is_darker
    jc .push_seed
.s3:
    mov eax, r9d
    shr eax, 12
    test eax, eax
    jz .seed_next
    lea edx, [r9 - 4096]
    call .is_darker
    jc .push_seed
    jmp .seed_next
.push_seed:
    mov rdx, [rsp + 24]
    mov eax, [rsp + 40]
    cmp eax, LQ_SIZE - 1
    jae .seed_next
    mov [rdx + rax*2], r9w
    inc dword [rsp + 40]
.seed_next:
    inc r9d
    cmp r9d, CHUNK_VOX
    jb .seed
    jmp .borders

; CF set if node edx is clear and its sky light is below r10d
; (called with one return address on the stack; uses rax only)
.is_darker:
    movzx eax, byte [r12 + rdx]
    test byte [r14 + rax], F_OPAQUE
    jnz .nd
    movzx eax, byte [r13 + rdx]
    and eax, 15
    cmp eax, r10d                   ; CF = below
    ret
.nd:
    clc
    ret

    ; ---- 2. light from the neighbours
.borders:
    test dword [rsp + 4], LF_NEIGHBOURS
    jz .spread
    mov r15d, [rsp]
    shl r15d, CI_SHIFT
    lea rax, [chunk_info]
    mov edi, [rax + r15 + CI_CX]
    mov esi, [rax + r15 + CI_CZ]
    mov [rsp + 56], edi
    mov [rsp + 60], esi
    ; side 0: -X (own lx 0 <- neighbour lx 15)
    mov edi, [rsp + 56]
    dec edi
    mov esi, [rsp + 60]
    xor ecx, ecx                    ; own node of (lx 0, lz 0)
    mov r8d, 15 << 8                ; neighbour's matching node
    mov r9d, 4096                   ; step along the side (z)
    call .side
    ; side 1: +X
    mov edi, [rsp + 56]
    inc edi
    mov esi, [rsp + 60]
    mov ecx, 15 << 8
    xor r8d, r8d
    mov r9d, 4096
    call .side
    ; side 2: -Z
    mov edi, [rsp + 56]
    mov esi, [rsp + 60]
    dec esi
    xor ecx, ecx
    mov r8d, 15 << 12
    mov r9d, 256
    call .side
    ; side 3: +Z
    mov edi, [rsp + 56]
    mov esi, [rsp + 60]
    inc esi
    mov ecx, 15 << 12
    xor r8d, r8d
    mov r9d, 256
    call .side
    jmp .spread

; one side: neighbour chunk (edi, esi); own start ecx, neighbour start r8d,
; step r9d. Called with a return address on the stack: locals at +8.
.side:
    push rcx
    push r8
    push r9
    call world_find                 ; clobbers rax, rcx, rdx
    pop r9
    pop r8
    pop rcx
    test eax, eax
    js .side_out
    shl rax, 16
    lea rdx, [chunk_light]
    add rdx, rax                    ; neighbour light
    mov r10d, 16                    ; nodes along the side
.side_row:
    xor r11d, r11d                  ; y
.side_y:
    lea eax, [r8 + r11]
    movzx esi, byte [rdx + rax]     ; neighbour light byte
    lea edi, [rcx + r11]            ; own node
    movzx eax, byte [r12 + rdi]
    test byte [r14 + rax], F_OPAQUE
    jnz .side_next
    ; sky
    mov eax, esi
    and eax, 15
    cmp eax, 2
    jb .side_blk
    dec eax
    movzx ebx, byte [r13 + rdi]
    mov r15d, ebx
    and r15d, 15
    cmp r15d, eax
    jae .side_blk
    and ebx, 0xf0
    or ebx, eax
    mov [r13 + rdi], bl
    mov rax, [rsp + 8 + 24]
    mov r15d, [rsp + 8 + 40]
    cmp r15d, LQ_SIZE - 1
    jae .side_blk
    mov [rax + r15*2], di
    inc dword [rsp + 8 + 40]
.side_blk:
    mov eax, esi
    shr eax, 4
    cmp eax, 2
    jb .side_next
    dec eax
    movzx ebx, byte [r13 + rdi]
    mov r15d, ebx
    shr r15d, 4
    cmp r15d, eax
    jae .side_next
    and ebx, 0x0f
    shl eax, 4
    or ebx, eax
    mov [r13 + rdi], bl
    mov rax, [rsp + 8 + 32]
    mov r15d, [rsp + 8 + 44]
    cmp r15d, LQ_SIZE - 1
    jae .side_next
    mov [rax + r15*2], di
    inc dword [rsp + 8 + 44]
.side_next:
    inc r11d
    cmp r11d, 256
    jb .side_y
    add ecx, r9d
    add r8d, r9d
    dec r10d
    jnz .side_row
.side_out:
    ret

    ; ---- 3. spread
.spread:
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + 24]
    mov ecx, [rsp + 40]
    xor r8d, r8d
    call bfs
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + 32]
    mov ecx, [rsp + 44]
    mov r8d, 4
    call bfs
    LEAVE_FN

NOEXECSTACK
