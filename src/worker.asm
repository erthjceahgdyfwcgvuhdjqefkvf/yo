; worker.asm - world generation on a second CPU core.
;
; A raw clone() thread (no libc, no pthreads, so no glibc version
; requirements) runs two kinds of job:
;   chunk   - load it from the world's save folder or generate it, then
;             light it (light_chunk)
;   horizon - make the heights and colours of one far terrain tile
; The main thread queues jobs and collects finished ones once per frame.
; x86 stores are ordered, so writing a job's fields before its state (and
; the data before JOB_DONE) is enough; the worker sleeps on a futex when
; idle.

%include "common.inc"

global worker_start, worker_submit, worker_collect, worker_active
global worker_wait_idle, worker_set_seed, worker_submit_horizon

extern world_reserve, world_finish_slot, chunk_fill, chunk_path, light_chunk
extern mapgen_horizon_tile, hz_heights, hz_tops, hz_cols, horizon_finish, usleep
%ifdef VOXASM_WIN
extern win_thread_start, win_worker_wait, win_worker_wake
%endif

NUM_JOBS    equ 8
JOB_FREE    equ 0
JOB_QUEUED  equ 1
JOB_RUNNING equ 2
JOB_DONE    equ 3
J_STATE     equ 0
J_TYPE      equ 4                   ; 0 chunk, 1 horizon tile
J_CX        equ 8                   ; chunk or tile coordinates
J_CZ        equ 12
J_MAXY      equ 16
J_SLOT      equ 20
J_PATH      equ 32                  ; save file of the chunk ("" = none)
J_SIZE      equ 256
HZ_DATA     equ 34 * 34
RLE_MAX     equ 65536 * 2 + 16
LF_WORKER   equ 2

SYS_clone   equ 56
SYS_exit    equ 60
SYS_futex   equ 202
FUTEX_WAIT_PRIVATE equ 128
FUTEX_WAKE_PRIVATE equ 129
CLONE_FLAGS equ 0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x40000
STACK_SIZE  equ 262144

section .bss
alignb 64
jobs:          resb NUM_JOBS * J_SIZE
work_seq:      resd 1
worker_seed:   resd 1
worker_active: resd 1
alignb 16
worker_stack:  resb STACK_SIZE
worker_buf:    resb RLE_MAX         ; chunk file contents (worker only)

section .text

; int worker_start(int seed) - 1 if the thread is running
worker_start:
    mov [worker_seed], edi
%ifdef VOXASM_WIN
    sub rsp, 8
    lea rdi, [worker_entry]
    call win_thread_start           ; (winabi.asm)
    add rsp, 8
    test eax, eax
    jz .fail
    mov dword [worker_active], 1
    mov eax, 1
    ret
.fail:
%elifidn __OUTPUT_FORMAT__, elf64
    mov eax, SYS_clone
    mov edi, CLONE_FLAGS
    lea rsi, [worker_stack + STACK_SIZE]
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    syscall
    test rax, rax
    jz worker_entry                 ; child: fresh stack, never returns
    js .fail
    mov dword [worker_active], 1
    mov eax, 1
    ret
.fail:
%endif
    mov dword [worker_active], 0
    xor eax, eax
    ret

worker_entry:
    and rsp, -16
.loop:
    mov r12d, [work_seq]
    xor ebx, ebx                    ; found work
    lea r13, [jobs]
    xor r14d, r14d
.scan:
    cmp dword [r13 + J_STATE], JOB_QUEUED
    jne .skip
    mov dword [r13 + J_STATE], JOB_RUNNING
    cmp dword [r13 + J_TYPE], 0
    jne .horizon
    mov edi, [r13 + J_SLOT]
    mov esi, [r13 + J_CX]
    mov edx, [r13 + J_CZ]
    mov ecx, [worker_seed]
    lea r8, [r13 + J_PATH]
    lea r9, [worker_buf]
    call chunk_fill
    mov [r13 + J_MAXY], eax
    mov edi, [r13 + J_SLOT]
    mov esi, LF_WORKER
    call light_chunk
    jmp .done
.horizon:
    mov eax, [r13 + J_SLOT]
    imul ecx, eax, HZ_DATA * 2
    lea rdx, [hz_heights]
    add rcx, rdx
    imul r8d, eax, HZ_DATA
    lea rdx, [hz_tops]
    add r8, rdx
    imul r9d, eax, HZ_DATA * 8
    lea rdx, [hz_cols]
    add r9, rdx
    mov edi, [r13 + J_CX]
    mov esi, [r13 + J_CZ]
    mov edx, [worker_seed]
    call mapgen_horizon_tile
.done:
    mov dword [r13 + J_STATE], JOB_DONE
    mov ebx, 1
.skip:
    add r13, J_SIZE
    inc r14d
    cmp r14d, NUM_JOBS
    jb .scan
    test ebx, ebx
    jnz .loop
%ifdef VOXASM_WIN
    call win_worker_wait            ; until woken (or a moment passes)
%elifidn __OUTPUT_FORMAT__, elf64
    mov eax, SYS_futex
    lea rdi, [work_seq]
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, r12d
    xor r10d, r10d
    syscall
%endif
    jmp .loop

; rbx = a free job, or 0
free_job:
    lea rbx, [jobs]
    xor ecx, ecx
.find:
    cmp dword [rbx + J_STATE], JOB_FREE
    je .got
    add rbx, J_SIZE
    inc ecx
    cmp ecx, NUM_JOBS
    jb .find
    xor ebx, ebx
.got:
    ret

; wake the worker after queueing
wake:
    lock inc dword [work_seq]
%ifdef VOXASM_WIN
    jmp win_worker_wake
%elifidn __OUTPUT_FORMAT__, elf64
    mov eax, SYS_futex
    lea rdi, [work_seq]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    xor r10d, r10d
    syscall
%endif
    ret

; int worker_submit_horizon(int slot, int tx, int tz) - 0 when full
worker_submit_horizon:
    push rbx
    call free_job
    test rbx, rbx
    jz .full
    mov dword [rbx + J_TYPE], 1
    mov [rbx + J_SLOT], edi
    mov [rbx + J_CX], esi
    mov [rbx + J_CZ], edx
    mov dword [rbx + J_STATE], JOB_QUEUED
    call wake
    mov eax, 1
    pop rbx
    ret
.full:
    xor eax, eax
    pop rbx
    ret

; int worker_submit(int cx, int cz) - queue a chunk; 0 when the queue is full
worker_submit:
    push rbx
    push r12
    push r13
    call free_job
    test rbx, rbx
    jz .full
    mov r12d, edi
    mov r13d, esi
    mov dword [rbx + J_TYPE], 0
    mov [rbx + J_CX], edi
    mov [rbx + J_CZ], esi
    lea rdx, [rbx + J_PATH]
    call chunk_path
    mov edi, r12d
    mov esi, r13d
    call world_reserve
    mov [rbx + J_SLOT], eax
    mov dword [rbx + J_STATE], JOB_QUEUED
    call wake
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.full:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; void worker_set_seed(int seed) - only while the worker is idle
worker_set_seed:
    mov [worker_seed], edi
    ret

; void worker_wait_idle(void) - wait for queued and running jobs, then drop
; their results (used when a world is closed)
worker_wait_idle:
    push rbx
.again:
    lea rbx, [jobs]
    xor ecx, ecx
.scan:
    mov eax, [rbx + J_STATE]
    cmp eax, JOB_QUEUED
    je .busy
    cmp eax, JOB_RUNNING
    je .busy
    add rbx, J_SIZE
    inc ecx
    cmp ecx, NUM_JOBS
    jb .scan
    lea rbx, [jobs]
    xor ecx, ecx
.free:
    mov dword [rbx + J_STATE], JOB_FREE
    add rbx, J_SIZE
    inc ecx
    cmp ecx, NUM_JOBS
    jb .free
    pop rbx
    ret
.busy:
    mov edi, 2000
    call usleep PLT
    jmp .again

; int worker_collect(void) - publish finished chunks, returns how many
worker_collect:
    push rbx
    push r12
    push r13
    lea rbx, [jobs]
    xor r12d, r12d
    xor r13d, r13d
.c:
    cmp dword [rbx + J_STATE], JOB_DONE
    jne .n
    cmp dword [rbx + J_TYPE], 0
    jne .hz
    mov edi, [rbx + J_SLOT]
    mov esi, [rbx + J_MAXY]
    call world_finish_slot
    jmp .freed
.hz:
    mov edi, [rbx + J_SLOT]
    mov esi, [rbx + J_CX]
    mov edx, [rbx + J_CZ]
    call horizon_finish
.freed:
    mov dword [rbx + J_STATE], JOB_FREE
    inc r13d
.n:
    add rbx, J_SIZE
    inc r12d
    cmp r12d, NUM_JOBS
    jb .c
    mov eax, r13d
    pop r13
    pop r12
    pop rbx
    ret

NOEXECSTACK
