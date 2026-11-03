; bucket.asm - buckets of water, lava and milk.
;
; An empty bucket right-clicked at a cow (a grown one) fills with milk;
; otherwise it takes the first still water or lava along the view (flowing
; liquid cannot be picked up). A full bucket pours its source into the
; free cell in front of the block looked at and is empty again. Milk is
; drunk: 1 heart back. Creative keeps full buckets full.

%include "common.inc"

global bucket_use

extern pos, pitch, syaw, cyaw, inv, sel_slot, game_mode, hp, target_hit
extern target, world_get, world_set, block_flags, mob_pick, mobs
extern inv_add_slot, throw_item, dimension

MB_TYPE     equ 0                   ; mobs.asm record
MB_AGE      equ 88
MB_SIZE     equ 96
MOB_COW     equ 2
MAX_HP      equ 20
MILK_HEAL   equ 2

section .rodata
align 4
f_eye:      dd 1.6
f_step:     dd 0.1

section .text

; floor of xmm float %2 into %1 (xmm7 scratch)
%macro FLOORF 2
    cvttss2si %1, %2
    cvtsi2ss xmm7, %1
    comiss xmm7, %2
    jbe %%ok
    dec %1
%%ok:
%endmacro

; fill(edi item) - one empty bucket from the held stack becomes item
; (the last one in the hand is swapped; otherwise the full bucket goes in
; the inventory, or is thrown when that is full)
; rbx -> the held slot
fill:
    sub rsp, 8
    cmp byte [rbx + 1], 1
    ja .more
    or edi, 1 << 8
    mov [rbx], edi
    add rsp, 8
    ret
.more:
    dec byte [rbx + 1]
    or edi, 1 << 8
    call inv_add_slot
    test eax, eax
    jz .out
    mov edi, eax
    call throw_item
.out:
    add rsp, 8
    ret

; int bucket_use(void) - right click with a bucket; 1 if it was one
; locals: [0] point x y z, [12] direction, [24] steps
bucket_use:
    ENTER_FN 32
    mov eax, [sel_slot]
    lea rbx, [inv]
    lea rbx, [rbx + rax*4]
    movzx eax, byte [rbx]
    cmp eax, I_BUCKET
    je .empty
    cmp eax, I_WATERBUCKET
    je .pour
    cmp eax, I_LAVABUCKET
    je .pour
    cmp eax, I_MILK
    je .milk
    xor eax, eax
    LEAVE_FN

.milk:
    cmp dword [game_mode], 0
    jne .yes
    mov eax, [hp]
    add eax, MILK_HEAL
    mov ecx, MAX_HP
    cmp eax, ecx
    cmova eax, ecx
    mov [hp], eax
    mov dword [rbx], I_BUCKET | (1 << 8)
    jmp .yes

.pour:
    mov r12d, B_WATER
    cmp eax, I_WATERBUCKET
    je .p
    mov r12d, B_LAVA
.p:
    cmp dword [target_hit], 0
    je .yes
    ; into the cell before the block: air, liquid or a plant
    mov edi, [target + 12]
    mov esi, [target + 16]
    mov edx, [target + 20]
    call world_get
    test eax, eax
    jz .put
    lea rcx, [block_flags]
    test byte [rcx + rax], F_LIQUID | F_CROSS
    jz .yes
.put:
    cmp r12d, B_WATER
    jne .pourit
    cmp dword [dimension], 0
    jne .poured                     ; water boils away in the nether
.pourit:
    mov edi, [target + 12]
    mov esi, [target + 16]
    mov edx, [target + 20]
    mov ecx, r12d
    call world_set
.poured:
    cmp dword [game_mode], 0
    jne .yes
    mov dword [rbx], I_BUCKET | (1 << 8)
    jmp .yes

.empty:
    ; a grown cow in front: milk
    call mob_pick
    test eax, eax
    js .liquid
    imul eax, eax, MB_SIZE
    lea rcx, [mobs]
    add rcx, rax
    cmp dword [rcx + MB_TYPE], MOB_COW
    jne .liquid
    cmp dword [rcx + MB_AGE], 0
    jl .liquid                      ; (a float: negative = a calf)
    mov edi, I_MILK
    call fill
    jmp .yes
.liquid:
    ; the first liquid along the view, before anything solid
    fld dword [pitch]
    fsincos
    fstp dword [rsp + 24]           ; cos
    fstp dword [rsp + 28]           ; sin
    movss xmm0, [syaw]
    mulss xmm0, [rsp + 24]
    mulss xmm0, [f_step]
    movss [rsp + 12], xmm0
    xorps xmm0, xmm0
    subss xmm0, [rsp + 28]
    mulss xmm0, [f_step]
    movss [rsp + 16], xmm0
    movss xmm0, [cyaw]
    mulss xmm0, [rsp + 24]
    mulss xmm0, [f_step]
    xorps xmm1, xmm1
    subss xmm1, xmm0
    movss [rsp + 20], xmm1
    mov eax, [pos]
    mov [rsp], eax
    movss xmm0, [pos + 4]
    addss xmm0, [f_eye]
    movss [rsp + 4], xmm0
    mov eax, [pos + 8]
    mov [rsp + 8], eax
    mov r13d, 50                    ; 5 nodes
.walk:
    movss xmm0, [rsp]
    addss xmm0, [rsp + 12]
    movss [rsp], xmm0
    movss xmm0, [rsp + 4]
    addss xmm0, [rsp + 16]
    movss [rsp + 4], xmm0
    movss xmm0, [rsp + 8]
    addss xmm0, [rsp + 20]
    movss [rsp + 8], xmm0
    movss xmm0, [rsp]
    FLOORF r12d, xmm0
    movss xmm0, [rsp + 4]
    FLOORF r14d, xmm0
    movss xmm0, [rsp + 8]
    FLOORF r15d, xmm0
    mov edi, r12d
    mov esi, r14d
    mov edx, r15d
    call world_get
    lea rcx, [block_flags]
    test byte [rcx + rax], F_LIQUID
    jnz .wet
    test byte [rcx + rax], F_SOLID
    jnz .yes
    dec r13d
    jnz .walk
    jmp .yes
.wet:
    mov r13d, I_WATERBUCKET
    cmp eax, B_WATER
    je .take
    mov r13d, I_LAVABUCKET
    cmp eax, B_LAVA
    jne .yes                        ; flowing: nothing to take
.take:
    mov edi, r12d
    mov esi, r14d
    mov edx, r15d
    xor ecx, ecx
    call world_set
    mov edi, r13d
    call fill
.yes:
    mov eax, 1
    LEAVE_FN

NOEXECSTACK
