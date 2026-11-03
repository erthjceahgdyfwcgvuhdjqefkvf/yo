; liquid.asm - flowing water, following Luanti's liquid rules.
;
; Mapgen water is all sources and stays still until something changes next
; to it. Every world_set queues the changed node and its six neighbours;
; liquid_step re-evaluates queued nodes a few times per second:
;   * water above, or a source beside it -> flowing level 7
;   * flowing level L beside it, resting on something -> level L - 1
;   * two or more sources beside it and solid/source below -> new source
;   * nothing feeding it -> dries up
; Sources spread sideways even when falling; flowing water only spreads
; sideways once it rests on something, so it falls first and then fans out.
;
; Lava follows the same rules with 3 flowing levels (it runs 3 nodes from
; a source), never makes new sources and moves only every 4th step. Lava
; touching water hardens: a source to obsidian, flowing lava to cobblestone.

%include "common.inc"

global liquid_push, liquid_push_around, liquid_step, liquid_reset
global liquid_pending

extern world_get, world_set, block_flags

LQ_CAP      equ 65536               ; queued nodes (16 bytes each)
LQ_MASK     equ LQ_CAP - 1

section .bss
alignb 16
lq_buf:     resb LQ_CAP * 16
lq_head:    resd 1
lq_tail:    resd 1
lq_steps:   resd 1                  ; liquid_step calls (lava moves every 4th)

section .text

; void liquid_reset(void)
liquid_reset:
    mov dword [lq_head], 0
    mov dword [lq_tail], 0
    ret

; int liquid_pending(void)
liquid_pending:
    mov eax, [lq_tail]
    sub eax, [lq_head]
    ret

; void liquid_push(int x, int y, int z) - silently drops when full
liquid_push:
    mov eax, [lq_tail]
    mov ecx, eax
    sub ecx, [lq_head]
    cmp ecx, LQ_CAP - 1
    jae .full
    mov ecx, eax
    and ecx, LQ_MASK
    shl rcx, 4
    lea r8, [lq_buf]
    mov [r8 + rcx], edi
    mov [r8 + rcx + 4], esi
    mov [r8 + rcx + 8], edx
    inc eax
    mov [lq_tail], eax
.full:
    ret

; void liquid_push_around(int x, int y, int z)
liquid_push_around:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    call liquid_push
%macro LQPUSH 3
    lea edi, [rbx + %1]
    lea esi, [r12 + %2]
    lea edx, [r13 + %3]
    call liquid_push
%endmacro
    LQPUSH 1, 0, 0
    LQPUSH -1, 0, 0
    LQPUSH 0, 1, 0
    LQPUSH 0, -1, 0
    LQPUSH 0, 0, 1
    LQPUSH 0, 0, -1
    pop r13
    pop r12
    pop rbx
    ret

; int is_flowing(eax block) -> ZF clear when flowing water
%macro IS_FLOWING 1
    lea ecx, [%1 - B_WFLOW1]
    cmp ecx, B_WFLOW7 - B_WFLOW1
%endmacro

; int liquid_step(int max) - process up to max queued nodes (only those
; queued before this call, so water advances one node per step)
liquid_step:
    ENTER_FN 16
    inc dword [lq_steps]
    mov eax, [lq_tail]
    sub eax, [lq_head]
    cmp eax, edi
    jbe .n
    mov eax, edi
.n:
    mov ebx, eax
    mov [rsp], eax
    test ebx, ebx
    jz .done
.pop:
    mov eax, [lq_head]
    mov ecx, eax
    and ecx, LQ_MASK
    shl rcx, 4
    lea r8, [lq_buf]
    mov edi, [r8 + rcx]
    mov esi, [r8 + rcx + 4]
    mov edx, [r8 + rcx + 8]
    inc eax
    mov [lq_head], eax
    call liquid_update
    dec ebx
    jnz .pop
.done:
    mov eax, [rsp]
    LEAVE_FN

; liquid_update(x, y, z)
; r12 x, r13 y, r14 z, r15d current node, ebx best level
; locals: [0] sources beside, [4] node below
liquid_update:
    ENTER_FN 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call world_get
    mov r15d, eax
    test eax, eax
    jz .eval
    cmp eax, B_FIRE
    jne .notfire
    xor r15d, r15d                  ; fire is air to liquids: they wash it away
    jmp .eval
.notfire:
    lea ecx, [rax - B_LAVA]
    cmp ecx, B_LFLOW3 - B_LAVA
    jbe .lava_node
    IS_FLOWING eax
    ja .out                         ; solids, sources, unloaded: nothing to do
.eval:
    xor ebx, ebx
    mov dword [rsp], 0
    ; water above makes falling water
    mov edi, r12d
    lea esi, [r13 + 1]
    mov edx, r14d
    call world_get
    cmp eax, B_WATER
    je .above
    IS_FLOWING eax
    ja .side
.above:
    mov ebx, 7
.side:
%macro SIDE 2
    lea edi, [r12 + %1]
    mov esi, r13d
    lea edx, [r14 + %2]
    call side_level
    cmp eax, ebx
    jbe %%k
    mov ebx, eax
%%k:
%endmacro
    SIDE 1, 0
    SIDE -1, 0
    SIDE 0, 1
    SIDE 0, -1
    ; renewable source: two sources beside, resting on solid or source
    mov edi, r12d
    lea esi, [r13 - 1]
    mov edx, r14d
    call world_get
    cmp dword [rsp], 2
    jb .flow
    cmp eax, B_WATER
    je .source
    lea rcx, [block_flags]
    test byte [rcx + rax], F_SOLID
    jz .flow
.source:
    mov ecx, B_WATER
    jmp .apply
.flow:
    xor ecx, ecx
    test ebx, ebx
    jz .try_lava
    lea ecx, [rbx + B_WFLOW1 - 1]
.apply:
    cmp ecx, r15d
    je .out
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call world_set
.out:
    LEAVE_FN
.try_lava:
    ; no water feeds it: drying water goes, air may take lava
    test r15d, r15d
    jnz .apply
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call lava_level
    test eax, eax
    jz .out
    lea ecx, [rax + B_LFLOW1 - 1]
    jmp .lava_apply
.lava_node:
    ; lava touching water hardens
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call touches_water
    test eax, eax
    jz .lava_flow
    mov ecx, B_OBSIDIAN
    cmp r15d, B_LAVA
    je .apply
    mov ecx, B_COBBLE
    jmp .apply
.lava_flow:
    cmp r15d, B_LAVA
    je .out
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call lava_level
    xor ecx, ecx
    test eax, eax
    jz .lava_apply
    lea ecx, [rax + B_LFLOW1 - 1]
.lava_apply:
    cmp ecx, r15d
    je .out
    ; lava moves on every 4th step only: until then look again each step
    test dword [lq_steps], 3
    jz .apply
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call liquid_push
    jmp .out

; int is_lava(eax block) -> ZF/CF: jbe taken when lava (still or flowing)
%macro IS_LAVA 1
    lea ecx, [%1 - B_LAVA]
    cmp ecx, B_LFLOW3 - B_LAVA
%endmacro

; int touches_water(int x, int y, int z) - water (still or flowing) on
; any of the six sides
touches_water:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
%macro WET 3
    lea edi, [r12 + %1]
    lea esi, [r13 + %2]
    lea edx, [r14 + %3]
    call world_get
    cmp eax, B_WATER
    je .yes
    IS_FLOWING eax
    jbe .yes
%endmacro
    WET 1, 0, 0
    WET -1, 0, 0
    WET 0, 1, 0
    WET 0, -1, 0
    WET 0, 0, 1
    WET 0, 0, -1
    xor eax, eax
    jmp .ret
.yes:
    mov eax, 1
.ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; int lava_level(int x, int y, int z) - flowing lava level (0-3) that feeds
; this node: 3 from lava above or a source beside, L - 1 from flowing lava
; L beside that rests on something
lava_level:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    xor ebx, ebx
    lea esi, [r13 + 1]
    call world_get
    IS_LAVA eax
    ja .sides
    mov ebx, 3
.sides:
%macro LSIDE 2
    lea edi, [r12 + %1]
    mov esi, r13d
    lea edx, [r14 + %2]
    call lava_side
    cmp eax, ebx
    jbe %%k
    mov ebx, eax
%%k:
%endmacro
    LSIDE 1, 0
    LSIDE -1, 0
    LSIDE 0, 1
    LSIDE 0, -1
    mov eax, ebx
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; level the lava at (edi, esi, edx) feeds sideways (0 if none)
lava_side:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call world_get
    cmp eax, B_LAVA
    jne .notsrc
    mov eax, 3
    jmp .ret
.notsrc:
    lea ebx, [rax - B_LFLOW1]       ; level - 1
    cmp ebx, B_LFLOW3 - B_LFLOW1
    ja .none
    test ebx, ebx
    jz .none
    ; flowing lava spreads sideways only when it rests on something
    mov edi, r12d
    lea esi, [r13 - 1]
    mov edx, r14d
    call world_get
    test eax, eax
    jz .none
    IS_LAVA eax
    jbe .none
    mov eax, ebx
    jmp .ret
.none:
    xor eax, eax
.ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Level a horizontal neighbour feeds into this node (0 if none).
; Called from liquid_update: edi/esi/edx = neighbour position. Counts
; sources into the caller's [rsp] local (at [rsp + 8] here).
side_level:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call world_get
    cmp eax, B_WATER
    jne .notsrc
    inc dword [rsp + 48]            ; caller's source counter
    mov eax, 7
    jmp .ret
.notsrc:
    IS_FLOWING eax
    ja .none
    lea ebx, [rax - B_WFLOW1]       ; level - 1
    test ebx, ebx
    jz .none
    ; flowing water only spreads sideways when it rests on something
    mov edi, r12d
    lea esi, [r13 - 1]
    mov edx, r14d
    call world_get
    test eax, eax
    jz .none
    IS_FLOWING eax
    jbe .none
    mov eax, ebx
    jmp .ret
.none:
    xor eax, eax
.ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

NOEXECSTACK
