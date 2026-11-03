; fire.asm - fire from flint and steel.
;
; Each fire node is kept in a list (fires seen while meshing a loaded chunk
; join it, so fire from a save keeps burning). About once a second a fire
; may spread into each burnable block next to it (wood, leaves, wool,
; plants, beds...), which becomes fire in turn, and lights TNT; after a few
; seconds it goes out, leaving the burnt blocks gone. Fire on netherrack
; burns forever. Water flowing in puts fire out (liquid.asm).

%include "common.inc"

global fire_clear, fire_add, fire_set, fire_update, flammable, fires, fire_count

extern dt, world_get, world_set, randf, game_rand, tnt_ignite
extern mesh_fires, mesh_fire_n

MAX_FIRES   equ 256
FI_X        equ 0
FI_Y        equ 4
FI_Z        equ 8
FI_TICK     equ 12                  ; seconds to its next turn
FI_LIFE     equ 16                  ; turns left before it goes out
FI_SIZE     equ 32

section .rodata
align 4
f_tick:     dd 0.7                  ; a turn every 0.7-1.5 s
f_tickr:    dd 0.8
f_fuse:     dd 4.0                  ; TNT lit by fire
; the six neighbours
fire_dirs:  db 1,0,0, -1,0,0, 0,1,0, 0,-1,0, 0,0,1, 0,0,-1

section .bss
alignb 16
fires:      resb MAX_FIRES * FI_SIZE
fire_count: resd 1

section .text

; void fire_clear(void)
fire_clear:
    mov dword [fire_count], 0
    mov dword [mesh_fire_n], 0
    ret

; int flammable(int block) - 1 if fire spreads into it
flammable:
    xor eax, eax
    cmp edi, B_LOG
    je .yes
    cmp edi, B_LEAVES
    je .yes
    cmp edi, B_PLANKS
    je .yes
    cmp edi, B_PINENEEDLES
    je .yes
    cmp edi, B_PINELOG
    je .yes
    cmp edi, B_CRAFTTABLE
    je .yes
    cmp edi, B_COALBLOCK
    je .yes
    cmp edi, B_DYEMAKER
    je .yes
    lea ecx, [rdi - B_TALLGRASS]    ; tall grass, wheat, carrots, fences, gates
    cmp ecx, B_GATEOPEN_Z - B_TALLGRASS
    jbe .yes
    lea ecx, [rdi - B_WOOL]
    cmp ecx, 15
    jbe .yes
    lea ecx, [rdi - B_FLOWER_Y]     ; flowers, beds
    cmp ecx, B_BED_HEAD - B_FLOWER_Y
    jbe .yes
    ret
.yes:
    mov eax, 1
    ret

; int fire_add(int x, int y, int z) - keep track of a fire node (once);
; 0 when the list is full
fire_add:
    lea r8, [fires]
    xor ecx, ecx
.f:
    cmp ecx, [fire_count]
    jae .new
    cmp [r8 + FI_X], edi
    jne .n
    cmp [r8 + FI_Y], esi
    jne .n
    cmp [r8 + FI_Z], edx
    je .have
.n:
    add r8, FI_SIZE
    inc ecx
    jmp .f
.have:
    mov eax, 1
    ret
.new:
    xor eax, eax
    cmp ecx, MAX_FIRES
    jae .out
    inc dword [fire_count]
    mov [r8 + FI_X], edi
    mov [r8 + FI_Y], esi
    mov [r8 + FI_Z], edx
    push r8
    call game_rand
    pop r8
    mov ecx, eax
    shr ecx, 8
    and ecx, 3
    add ecx, 3                      ; 3-6 turns
    mov [r8 + FI_LIFE], ecx
    shr eax, 16
    and eax, 255
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_tickr]
    mov eax, 256
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
    addss xmm0, [f_tick]
    movss [r8 + FI_TICK], xmm0
    mov eax, 1
.out:
    ret

; int fire_set(int x, int y, int z) - set a node on fire (1 if it is)
fire_set:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    call fire_add
    test eax, eax
    jz .out
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    mov ecx, B_FIRE
    call world_set
    mov eax, 1
.out:
    pop r13
    pop r12
    pop rbx
    ret

; void fire_update(void) - every fire takes its turn: spread, burn out
; locals: [0] neighbour, [4] on netherrack
fire_update:
    ENTER_FN 16
    ; fires the mesher found in loaded chunks
.notes:
    mov eax, [mesh_fire_n]
    test eax, eax
    jz .list
    dec eax
    mov [mesh_fire_n], eax
    imul eax, eax, 12
    lea rcx, [mesh_fires]
    mov edi, [rcx + rax]
    mov esi, [rcx + rax + 4]
    mov edx, [rcx + rax + 8]
    call fire_add
    jmp .notes
.list:
    xor r12d, r12d
.f:
    cmp r12d, [fire_count]
    jae .out
    mov eax, r12d
    shl eax, 5
    lea rbx, [fires]
    add rbx, rax
    ; gone (dug, washed away, burnt over)?
    mov edi, [rbx + FI_X]
    mov esi, [rbx + FI_Y]
    mov edx, [rbx + FI_Z]
    call world_get
    cmp eax, B_FIRE
    jne .drop
    movss xmm0, [rbx + FI_TICK]
    subss xmm0, [dt]
    movss [rbx + FI_TICK], xmm0
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    ja .next
    call randf
    mulss xmm0, [f_tickr]
    addss xmm0, [f_tick]
    movss [rbx + FI_TICK], xmm0
    ; spread: each burnable neighbour catches 1 time in 3, TNT is lit
    xor r13d, r13d
.nb:
    lea rax, [fire_dirs]
    lea rax, [rax + r13*2]
    add rax, r13                    ; 3 bytes a direction
    movsx r14d, byte [rax]
    add r14d, [rbx + FI_X]
    movsx r15d, byte [rax + 1]
    add r15d, [rbx + FI_Y]
    movsx eax, byte [rax + 2]
    add eax, [rbx + FI_Z]
    mov [rsp], eax
    mov edi, r14d
    mov esi, r15d
    mov edx, eax
    call world_get
    cmp eax, B_TNT
    jne .burn
    mov edi, r14d
    mov esi, r15d
    mov edx, [rsp]
    xor ecx, ecx
    call world_set
    mov edi, r14d
    mov esi, r15d
    mov edx, [rsp]
    movss xmm0, [f_fuse]
    call tnt_ignite
    jmp .nbn
.burn:
    mov edi, eax
    call flammable
    test eax, eax
    jz .nbn
    call game_rand
    shr eax, 8
    xor edx, edx
    mov ecx, 3
    div ecx
    test edx, edx
    jnz .nbn
    mov edi, r14d
    mov esi, r15d
    mov edx, [rsp]
    call fire_set
    ; the list may have moved on: rbx is still this fire (appended after)
.nbn:
    inc r13d
    cmp r13d, 6
    jb .nb
    ; burn down, unless on netherrack
    mov edi, [rbx + FI_X]
    mov esi, [rbx + FI_Y]
    dec esi
    mov edx, [rbx + FI_Z]
    call world_get
    cmp eax, B_NETHERRACK
    je .next
    dec dword [rbx + FI_LIFE]
    jg .next
    mov edi, [rbx + FI_X]
    mov esi, [rbx + FI_Y]
    mov edx, [rbx + FI_Z]
    xor ecx, ecx
    call world_set
.drop:
    ; the last fire takes this place
    mov eax, [fire_count]
    dec eax
    mov [fire_count], eax
    shl eax, 5
    lea rcx, [fires]
    add rcx, rax
    movups xmm0, [rcx]
    movups [rbx], xmm0
    movups xmm0, [rcx + 16]
    movups [rbx + 16], xmm0
    jmp .f
.next:
    inc r12d
    jmp .f
.out:
    LEAVE_FN

NOEXECSTACK
