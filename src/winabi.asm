; winabi.asm - the Windows (XP x64) side of the C library and OpenGL calls.
;
; The game is written for the System V calling convention (Linux): integer
; arguments in rdi, rsi, rdx, rcx, r8, r9, floats in xmm0-7 counted on
; their own. 64-bit Windows passes the first four arguments by position in
; rcx, rdx, r8, r9 / xmm0-3, the rest on the stack above 32 bytes of
; "shadow space", and wants the stack 16-byte aligned at every call.
;
; So every C library and OpenGL function the game calls is defined here
; under its usual name: it lines the stack up, moves the arguments to where
; Windows wants them and calls the real function. The real functions come
; from opengl32.dll and msvcrt.dll, loaded at startup (win_imports_init) -
; not linked by name, since this file uses those names itself. A few
; POSIX calls are rebuilt from Windows ones: clock_gettime, usleep, open
; (binary mode), opendir/readdir, and the GLX extension lookup, which
; returns little adapters for the Windows-convention entry points.
; write() goes only to the debugger (a window program has no terminal,
; and no log file is left next to the game).

%include "common.inc"

%ifdef VOXASM_WIN

global win_imports_init, win_thread_start, win_worker_wait, win_worker_wake
global wgl_create, wgl_make_current, wgl_delete

extern __imp_LoadLibraryA, __imp_GetProcAddress, __imp_ExitProcess
extern __imp_Sleep, __imp_QueryPerformanceCounter
extern __imp_QueryPerformanceFrequency, __imp_FindFirstFileA
extern __imp_FindNextFileA, __imp_FindClose, __imp_CreateThread
extern __imp_CreateEventA, __imp_SetEvent, __imp_WaitForSingleObject
extern __imp_MessageBoxA, __imp_OutputDebugStringA, __imp_GetSystemInfo

; ---------------------------------------------------------------------------
; the functions loaded from the two DLLs: a name list and a pointer table in
; the same order (FN name, dll: 0 opengl32, 1 msvcrt)
%macro FUNCS 0
    FN glAlphaFunc, 0
    FN glBegin, 0
    FN glBindTexture, 0
    FN glBlendFunc, 0
    FN glCallList, 0
    FN glClear, 0
    FN glClearColor, 0
    FN glCopyTexSubImage2D, 0
    FN glColor4f, 0
    FN glColor4ub, 0
    FN glColorPointer, 0
    FN glDepthFunc, 0
    FN glDepthMask, 0
    FN glDisable, 0
    FN glDisableClientState, 0
    FN glDrawArrays, 0
    FN glEnable, 0
    FN glEnableClientState, 0
    FN glEnd, 0
    FN glEndList, 0
    FN glFogf, 0
    FN glFogfv, 0
    FN glFogi, 0
    FN glFrustum, 0
    FN glGenLists, 0
    FN glGenTextures, 0
    FN glGetString, 0
    FN glHint, 0
    FN glLineWidth, 0
    FN glLoadIdentity, 0
    FN glMatrixMode, 0
    FN glNewList, 0
    FN glOrtho, 0
    FN glPopMatrix, 0
    FN glPushMatrix, 0
    FN glRotatef, 0
    FN glScalef, 0
    FN glShadeModel, 0
    FN glTexCoord2f, 0
    FN glTexCoordPointer, 0
    FN glTexEnvfv, 0
    FN glTexEnvi, 0
    FN glTexImage2D, 0
    FN glTexParameteri, 0
    FN glTranslatef, 0
    FN glVertex2f, 0
    FN glVertex3f, 0
    FN glVertexPointer, 0
    FN glViewport, 0
    FN wglGetProcAddress, 0
    FN wglCreateContext, 0
    FN wglMakeCurrent, 0
    FN wglDeleteContext, 0
    FN fclose, 1
    FN fflush, 1
    FN fopen, 1
    FN fprintf, 1
    FN fread, 1
    FN fscanf, 1
    FN fwrite, 1
    FN getenv, 1
    FN realloc, 1
    FN strcmp, 1
    FN strlen, 1
    FN strstr, 1
    FN strtol, 1
    FN time, 1
    FN exit, 1
    FN _snprintf, 1
    FN _mkdir, 1
    FN _open, 1
    FN _read, 1
    FN _close, 1
    FN _unlink, 1
    FN _rmdir, 1
%endmacro

section .rodata
s_opengl32: db "opengl32.dll", 0
s_msvcrt:   db "msvcrt.dll", 0
dll_names:  dq s_opengl32, s_msvcrt
%macro FN 2
%defstr fn_name %1
fname_%1:   db fn_name, 0
%endmacro
    FUNCS
align 8
%unmacro FN 2
%macro FN 2
    dq fname_%1, %2
%endmacro
fn_list:
    FUNCS
    dq 0, 0
s_missing:  db "VoxASM: a function missing from opengl32.dll or msvcrt.dll", 0
s_title:    db "VoxASM", 0
s_star:     db "\*", 0
s_xdg_data: db "XDG_DATA_HOME", 0
s_xdg_conf: db "XDG_CONFIG_HOME", 0
s_home:     db "HOME", 0
s_appdata:  db "APPDATA", 0
s_profile:  db "USERPROFILE", 0
s_glx_swap: db "glXSwapIntervalMESA", 0
s_wgl_swap: db "wglSwapIntervalEXT", 0
align 8
d_1e9:      dq 1000000000.0

section .bss
alignb 8
dll_handles: resq 2
%unmacro FN 2
%macro FN 2
p_%1:       resq 1
%endmacro
fn_ptrs:
    FUNCS
qpc_freq:   resq 1
find_handle: resq 1
find_first: resd 1                  ; the data from FindFirstFileA not read yet
alignb 8
find_data:  resb 320                ; WIN32_FIND_DATAA
find_path:  resb 520
work_event: resq 1
NUM_THUNKS  equ 16
THUNK_SIZE  equ 64
thunk_ptr:  resq NUM_THUNKS
thunk_n:    resd 1
fmt_buf:    resb 1024

section .text

; ---------------------------------------------------------------------------
; a call into Windows from System V code: line the stack up, leave the
; shadow space, move the four integer arguments (floats in xmm0-3 stay put)
%macro WIN_ENTER 1                  ; extra stack bytes beyond the shadow space
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32 + %1
%endmacro
%macro WIN_LEAVE 0
    mov rsp, rbp
    pop rbp
    ret
%endmacro
%macro INT4 0                       ; rdi rsi rdx rcx -> rcx rdx r8 r9
    mov r9, rcx
    mov r8, rdx
    mov rdx, rsi
    mov rcx, rdi
%endmacro

; all-integer (or all-float) functions with up to 4 arguments
%macro WRAP 1
global %1
%1:
    WIN_ENTER 0
    INT4
    call [rel p_%1]
    WIN_LEAVE
%endmacro
; an enum then a float: (edi, xmm0) -> (ecx, xmm1)
%macro WRAP_EF 1
global %1
%1:
    WIN_ENTER 0
    mov ecx, edi
    movaps xmm1, xmm0
    call [rel p_%1]
    WIN_LEAVE
%endmacro
; printf-style: up to 6 register arguments and 10 more from the stack
%macro WRAP_VAR 2                   ; name, real function
global %1
%1:
    WIN_ENTER 96
    mov [rsp + 32], r8
    mov [rsp + 40], r9
%assign k 0
%rep 10
    mov rax, [rbp + 16 + k * 8]
    mov [rsp + 48 + k * 8], rax
%assign k k + 1
%endrep
    INT4
    call [rel p_%2]
    WIN_LEAVE
%endmacro

    WRAP glBegin
    WRAP glBindTexture
    WRAP glBlendFunc
    WRAP glCallList
    WRAP glClear
    WRAP glClearColor
    WRAP glColor4f
    WRAP glColor4ub
    WRAP glColorPointer
    WRAP glDepthFunc
    WRAP glDepthMask
    WRAP glDisable
    WRAP glDisableClientState
    WRAP glDrawArrays
    WRAP glEnable
    WRAP glEnableClientState
    WRAP glEnd
    WRAP glEndList
    WRAP glFogfv
    WRAP glFogi
    WRAP glGenLists
    WRAP glGenTextures
    WRAP glGetString
    WRAP glHint
    WRAP glLineWidth
    WRAP glLoadIdentity
    WRAP glMatrixMode
    WRAP glNewList
    WRAP glPopMatrix
    WRAP glPushMatrix
    WRAP glRotatef
    WRAP glScalef
    WRAP glShadeModel
    WRAP glTexCoord2f
    WRAP glTexCoordPointer
    WRAP glTexEnvfv
    WRAP glTexEnvi
    WRAP glTexParameteri
    WRAP glTranslatef
    WRAP glVertex2f
    WRAP glVertex3f
    WRAP glVertexPointer
    WRAP glViewport
    WRAP_EF glAlphaFunc
    WRAP_EF glFogf
    WRAP fclose
    WRAP fflush
    WRAP fopen
    WRAP fread
    WRAP fwrite
    WRAP realloc
    WRAP strcmp
    WRAP strlen
    WRAP strstr
    WRAP strtol
    WRAP time
    WRAP exit
    WRAP_VAR snprintf, _snprintf
    WRAP_VAR fprintf, fprintf
    WRAP_VAR fscanf, fscanf

; glFrustum / glOrtho: six doubles in xmm0-5 -> xmm0-3 and two on the stack
%macro WRAP_D6 1
global %1
%1:
    WIN_ENTER 16
    movsd [rsp + 32], xmm4
    movsd [rsp + 40], xmm5
    call [rel p_%1]
    WIN_LEAVE
%endmacro
    WRAP_D6 glFrustum
    WRAP_D6 glOrtho

; glTexImage2D: nine integers, the last three on the caller's stack
global glTexImage2D
glTexImage2D:
    WIN_ENTER 48
    mov [rsp + 32], r8
    mov [rsp + 40], r9
    mov rax, [rbp + 16]
    mov [rsp + 48], rax
    mov rax, [rbp + 24]
    mov [rsp + 56], rax
    mov rax, [rbp + 32]
    mov [rsp + 64], rax
    INT4
    call [rel p_glTexImage2D]
    WIN_LEAVE

; glCopyTexSubImage2D: eight integers, the last two on the caller's stack
global glCopyTexSubImage2D
glCopyTexSubImage2D:
    WIN_ENTER 32
    mov [rsp + 32], r8
    mov [rsp + 40], r9
    mov rax, [rbp + 16]
    mov [rsp + 48], rax
    mov rax, [rbp + 24]
    mov [rsp + 56], rax
    INT4
    call [rel p_glCopyTexSubImage2D]
    WIN_LEAVE

; mkdir(path, mode): Windows has no modes
global mkdir
mkdir:
    WIN_ENTER 0
    mov rcx, rdi
    call [rel p__mkdir]
    WIN_LEAVE

; open(path, flags): always binary (no newline translation)
global open
open:
    WIN_ENTER 0
    mov rcx, rdi
    mov edx, esi
    or edx, 0x8000                  ; _O_BINARY
    call [rel p__open]
    WIN_LEAVE

global read
read:
    WIN_ENTER 0
    INT4
    call [rel p__read]
    WIN_LEAVE

global close
close:
    WIN_ENTER 0
    mov ecx, edi
    call [rel p__close]
    WIN_LEAVE

global unlink
unlink:
    WIN_ENTER 0
    mov rcx, rdi
    call [rel p__unlink]
    WIN_LEAVE

global rmdir
rmdir:
    WIN_ENTER 0
    mov rcx, rdi
    call [rel p__rmdir]
    WIN_LEAVE

; getenv: the Linux places the game looks for map to Windows ones -
; XDG_DATA_HOME and XDG_CONFIG_HOME to %APPDATA%, HOME to %USERPROFILE%
global getenv
getenv:
    WIN_ENTER 16
    mov [rsp + 32], rdi
    lea rsi, [s_xdg_data]
    call streq
    jz .appdata
    mov rdi, [rsp + 32]
    lea rsi, [s_xdg_conf]
    call streq
    jz .appdata
    mov rdi, [rsp + 32]
    lea rsi, [s_home]
    call streq
    jz .profile
    mov rcx, [rsp + 32]
    jmp .get
.appdata:
    lea rcx, [s_appdata]
    jmp .get
.profile:
    lea rcx, [s_profile]
.get:
    call [rel p_getenv]
    WIN_LEAVE

; ZF set if the strings at rdi and rsi are equal (rax, rcx clobbered)
streq:
    xor ecx, ecx
.c:
    mov al, [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .out
    inc rcx
    test al, al
    jnz .c
.out:
    ret

; printf(fmt, ...): formatted into a buffer, then write(1, ...)
global printf
printf:
    WIN_ENTER 96
    mov [rsp + 32], rdx             ; (format arguments 2, 3 ...)
    mov [rsp + 40], rcx
    mov [rsp + 48], r8
    mov [rsp + 56], r9
%assign k 0
%rep 6
    mov rax, [rbp + 16 + k * 8]
    mov [rsp + 64 + k * 8], rax
%assign k k + 1
%endrep
    mov r9, rsi                     ; argument 1
    mov r8, rdi                     ; the format
    mov edx, 1023
    lea rcx, [fmt_buf]
    call [rel p__snprintf]
    test eax, eax
    jle .out
    mov edi, 1
    lea rsi, [fmt_buf]
    mov edx, eax
    call write
.out:
    WIN_LEAVE

; write(fd, buf, n): only to the debugger (WINEDEBUG=+debugstr); no log
; file is kept next to the game
global write
write:
    WIN_ENTER 16
    mov [rsp + 40], rdx
    mov rcx, rsi
    call [rel __imp_OutputDebugStringA]
    mov rax, [rsp + 40]
    WIN_LEAVE

; usleep(microseconds)
global usleep
usleep:
    WIN_ENTER 0
    mov eax, edi
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov ecx, eax
    call [rel __imp_Sleep]
    xor eax, eax
    WIN_LEAVE

; clock_gettime(id, struct timespec *): the performance counter
global clock_gettime
clock_gettime:
    WIN_ENTER 16
    mov [rsp + 40], rsi
    cmp qword [qpc_freq], 0
    jne .f
    lea rcx, [qpc_freq]
    call [rel __imp_QueryPerformanceFrequency]
.f:
    lea rcx, [rsp + 32]
    call [rel __imp_QueryPerformanceCounter]
    mov rax, [rsp + 32]
    xor edx, edx
    div qword [qpc_freq]            ; rax seconds, rdx remainder ticks
    mov rcx, [rsp + 40]
    mov [rcx], rax
    cvtsi2sd xmm0, rdx
    mulsd xmm0, [d_1e9]
    cvtsi2sd xmm1, qword [qpc_freq]
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    mov [rcx + 8], rax
    xor eax, eax
    WIN_LEAVE

; opendir(path) / readdir(dir) / closedir(dir) on FindFirstFile: one open
; folder at a time (all the game needs); readdir returns the
; WIN32_FIND_DATAA, whose name is at offset 44 (save.asm D_NAME)
global opendir
opendir:
    WIN_ENTER 0
    lea rdx, [find_path]
    xor ecx, ecx
.cp:
    mov al, [rdi + rcx]
    test al, al
    jz .end
    mov [rdx + rcx], al
    inc ecx
    cmp ecx, 500
    jb .cp
.end:
    mov eax, [s_star]
    mov [rdx + rcx], eax            ; "\*", 0
    lea rcx, [find_path]
    lea rdx, [find_data]
    call [rel __imp_FindFirstFileA]
    cmp rax, -1
    je .no
    mov [find_handle], rax
    mov dword [find_first], 1
    lea rax, [find_handle]
    WIN_LEAVE
.no:
    xor eax, eax
    WIN_LEAVE

global readdir
readdir:
    WIN_ENTER 0
    cmp dword [find_first], 0
    je .next
    mov dword [find_first], 0
    lea rax, [find_data]
    WIN_LEAVE
.next:
    mov rcx, [find_handle]
    lea rdx, [find_data]
    call [rel __imp_FindNextFileA]
    test eax, eax
    jz .none
    lea rax, [find_data]
    WIN_LEAVE
.none:
    xor eax, eax
    WIN_LEAVE

global closedir
closedir:
    WIN_ENTER 0
    mov rcx, [find_handle]
    call [rel __imp_FindClose]
    xor eax, eax
    WIN_LEAVE

; ---------------------------------------------------------------------------
; glXGetProcAddressARB(name): an extension entry point from the driver
; (wglGetProcAddress), wrapped in an adapter so the game can call it the
; System V way. The swap interval is wglSwapIntervalEXT on Windows.
global glXGetProcAddressARB
glXGetProcAddressARB:
    WIN_ENTER 16
    mov [rsp + 32], rdi
    lea rsi, [s_glx_swap]
    call streq
    jnz .name
    lea rcx, [s_wgl_swap]
    jmp .look
.name:
    mov rax, [rsp + 32]
    cmp word [rax], 'gl'
    jne .none
    cmp byte [rax + 2], 'X'         ; other GLX names: nothing on Windows
    je .none
    mov rcx, rax
.look:
    call [rel p_wglGetProcAddress]
    cmp rax, 3
    jbe .none                       ; (some drivers return 1, 2 or 3 for none)
    cmp rax, -1
    je .none
    mov ecx, [thunk_n]
    cmp ecx, NUM_THUNKS
    jae .none
    inc dword [thunk_n]
    lea rdx, [thunk_ptr]
    mov [rdx + rcx*8], rax
    lea rdx, [thunks]
    imul ecx, ecx, THUNK_SIZE
    lea rax, [rdx + rcx]
    WIN_LEAVE
.none:
    xor eax, eax
    WIN_LEAVE

; the adapters: up to four integer arguments, one per 64 bytes
align 64
thunks:
%assign k 0
%rep NUM_THUNKS
    WIN_ENTER 0
    INT4
    call [rel thunk_ptr + k * 8]
    WIN_LEAVE
    align 64
%assign k k + 1
%endrep

; ---------------------------------------------------------------------------
; for win32.asm (Windows convention in and out, through the loaded table)
wgl_create:
    jmp [rel p_wglCreateContext]
wgl_make_current:
    jmp [rel p_wglMakeCurrent]
wgl_delete:
    jmp [rel p_wglDeleteContext]

; void win_imports_init(void) - load opengl32 and msvcrt and find every
; function; a message box and exit if something is missing
win_imports_init:
    push rbx
    push r12
    WIN_ENTER 0
    xor ebx, ebx
.dll:
    lea rax, [dll_names]
    mov rcx, [rax + rbx*8]
    call [rel __imp_LoadLibraryA]
    test rax, rax
    jz .fail
    lea rcx, [dll_handles]
    mov [rcx + rbx*8], rax
    inc ebx
    cmp ebx, 2
    jb .dll
    lea r12, [fn_list]
    lea rbx, [fn_ptrs]
.fn:
    mov rdx, [r12]
    test rdx, rdx
    jz .done
    mov rax, [r12 + 8]
    lea rcx, [dll_handles]
    mov rcx, [rcx + rax*8]
    call [rel __imp_GetProcAddress]
    test rax, rax
    jz .missing
    mov [rbx], rax
    add r12, 16
    add rbx, 8
    jmp .fn
.done:
    mov rsp, rbp
    pop rbp
    pop r12
    pop rbx
    ret
.missing:
    xor ecx, ecx                    ; name the function
    mov rdx, [r12]
    lea r8, [s_missing]
    jmp .box
.fail:
    xor ecx, ecx
    lea rdx, [s_missing]
    lea r8, [s_title]
.box:
    mov r9d, 0x10                   ; MB_ICONERROR
    call [rel __imp_MessageBoxA]
    mov ecx, 1
    call [rel __imp_ExitProcess]

; ---------------------------------------------------------------------------
; the world-gen thread

; int win_thread_start(void (*entry)(void)) - 1 if it is running; 0 on a
; single-core CPU (then the world is made in slices between frames, which
; keeps the frame rate steady instead of sharing the one core)
win_thread_start:
    WIN_ENTER 64
    mov [thread_entry], rdi
    lea rcx, [rsp + 32]             ; SYSTEM_INFO
    call [rel __imp_GetSystemInfo]
    cmp dword [rsp + 32 + 32], 1    ; dwNumberOfProcessors
    jbe .no
    xor ecx, ecx                    ; auto-reset event, not signalled
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [rel __imp_CreateEventA]
    mov [work_event], rax
    test rax, rax
    jz .no
    xor ecx, ecx
    mov edx, 1 << 20                ; 1 MB of stack
    lea r8, [thread_start]
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    call [rel __imp_CreateThread]
    test rax, rax
    jz .no
    mov eax, 1
    WIN_LEAVE
.no:
    xor eax, eax
    WIN_LEAVE

; the thread starts here (Windows convention); the worker never returns
thread_start:
    sub rsp, 40
    call [rel thread_entry]
    xor eax, eax
    add rsp, 40
    ret

; worker idle: wait to be woken, at most 50 ms
win_worker_wait:
    WIN_ENTER 0
    mov rcx, [work_event]
    mov edx, 50
    call [rel __imp_WaitForSingleObject]
    WIN_LEAVE

; work queued: wake the worker
win_worker_wake:
    WIN_ENTER 0
    mov rcx, [work_event]
    call [rel __imp_SetEvent]
    WIN_LEAVE

section .bss
thread_entry: resq 1

%endif

NOEXECSTACK
