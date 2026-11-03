; win32.asm - the Windows (XP x64) window: a borderless window covering
; the screen with an OpenGL context, the message loop, mouse capture for
; looking around, and keys turned into the X11 keysyms the game uses (so
; the key bindings and their names are the same as on Linux).
;
; The game calls in here the System V way (main.asm); everything here
; calls Windows the Windows way. The window procedure is called by
; Windows, so it keeps the registers Windows expects kept (rbx, rbp, rdi,
; rsi, r12-r15, xmm6-15) before calling into the game.

%include "common.inc"

%ifdef VOXASM_WIN

global start, init_window, poll_events, swap_buffers, close_window
global plat_warp, plat_grab, plat_release

extern main, win_imports_init, wgl_create, wgl_make_current, wgl_delete
extern ev_key_down, ev_key_up, ev_button_down, ev_button_up, ev_motion
extern ev_resize, ev_close, ev_focus_out, write
extern win_w, win_h, grabbed, mouse_x, mouse_y

extern __imp_GetModuleHandleA, __imp_ExitProcess
extern __imp_RegisterClassExA, __imp_CreateWindowExA, __imp_DefWindowProcA
extern __imp_PeekMessageA, __imp_DispatchMessageA, __imp_GetDC
extern __imp_ReleaseDC, __imp_DestroyWindow, __imp_ShowWindow
extern __imp_SetForegroundWindow, __imp_SetFocus, __imp_LoadCursorA
extern __imp_SetCursor, __imp_SetCursorPos, __imp_ClientToScreen
extern __imp_ClipCursor, __imp_GetWindowRect, __imp_SetCapture
extern __imp_ReleaseCapture, __imp_GetSystemMetrics, __imp_MessageBoxA
extern __imp_ChoosePixelFormat, __imp_SetPixelFormat, __imp_SwapBuffers

WM_SIZE         equ 0x0005
WM_KILLFOCUS    equ 0x0008
WM_CLOSE        equ 0x0010
WM_QUIT         equ 0x0012
WM_ERASEBKGND   equ 0x0014
WM_SETCURSOR    equ 0x0020
WM_KEYDOWN      equ 0x0100
WM_KEYUP        equ 0x0101
WM_SYSKEYDOWN   equ 0x0104
WM_SYSKEYUP     equ 0x0105
WM_SYSCOMMAND   equ 0x0112
WM_MOUSEMOVE    equ 0x0200
WM_LBUTTONDOWN  equ 0x0201
WM_LBUTTONUP    equ 0x0202
WM_RBUTTONDOWN  equ 0x0204
WM_RBUTTONUP    equ 0x0205
WM_MBUTTONDOWN  equ 0x0207
WM_MBUTTONUP    equ 0x0208
WM_MOUSEWHEEL   equ 0x020A
SC_KEYMENU      equ 0xF100
HTCLIENT        equ 1
VK_F4           equ 0x73
WS_POPUP_VISIBLE equ 0x90000000
WS_EX_APPWINDOW equ 0x00040000
CS_OWNDC        equ 0x0020
IDC_ARROW       equ 32512

section .rodata
s_class:    db "VoxASMWindow", 0
s_title:    db "VoxASM", 0
s_noctx:    db "VoxASM could not start OpenGL. Install the graphics driver "
            db "(ATI Catalyst for Windows XP x64) and try again.", 0
s_prog:     db "voxasm.exe", 0
s_t_start:  db "VoxASM for Windows starting", 10, 0
s_t_window: db "making the window", 10, 0
s_t_gl:     db "window and OpenGL ready", 10, 0
align 8
argv:       dq s_prog, 0

; virtual key -> X11 keysym (0 = not used), for keys 0x00-0xDF
vk_map:
    dw 0, 0, 0, 0, 0, 0, 0, 0                               ; 00
    dw 0xff08, 0xff09, 0, 0, 0, 0xff0d, 0, 0                ; 08 backspace tab . enter
    dw 0xffe1, 0xffe3, 0xffe9, 0xff13, 0xffe5, 0, 0, 0      ; 10 shift ctrl alt pause caps
    dw 0, 0, 0, 0xff1b, 0, 0, 0, 0                          ; 18 escape
    dw ' ', 0xff55, 0xff56, 0xff57, 0xff50, 0xff51, 0xff52, 0xff53 ; 20 space pgup pgdn end home arrows
    dw 0xff54, 0, 0, 0, 0, 0xff63, 0xffff, 0                ; 28 down . insert delete
    dw '0', '1', '2', '3', '4', '5', '6', '7'               ; 30
    dw '8', '9', 0, 0, 0, 0, 0, 0
    dw 0, 'a', 'b', 'c', 'd', 'e', 'f', 'g'                 ; 40
    dw 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o'
    dw 'p', 'q', 'r', 's', 't', 'u', 'v', 'w'               ; 50
    dw 'x', 'y', 'z', 0, 0, 0, 0, 0
    dw 0xffb0, 0xffb1, 0xffb2, 0xffb3, 0xffb4, 0xffb5, 0xffb6, 0xffb7 ; 60 keypad
    dw 0xffb8, 0xffb9, 0xffaa, 0xffab, 0, 0xffad, 0xffae, 0xffaf
    dw 0xffbe, 0xffbf, 0xffc0, 0xffc1, 0xffc2, 0xffc3, 0xffc4, 0xffc5 ; 70 F1-F8
    dw 0xffc6, 0xffc7, 0xffc8, 0xffc9, 0, 0, 0, 0           ; 78 F9-F12
    times 0x20 dw 0                                         ; 80-9F
    times 0x1A dw 0                                         ; A0-B9
    dw ';', '=', ',', '-', '.', '/'                         ; BA-BF
    dw '`'                                                  ; C0
    times 0x1A dw 0                                         ; C1-DA
    dw '[', '\', ']', "'", 0                                ; DB-DF
VK_MAP_N equ ($ - vk_map) / 2

section .bss
alignb 8
hinst:      resq 1
hwnd:       resq 1
hdc:        resq 1
hglrc:      resq 1
arrow:      resq 1
wndclass:   resb 80                 ; WNDCLASSEXA
pfd:        resb 40                 ; PIXELFORMATDESCRIPTOR
msg:        resb 48                 ; MSG
rect:       resd 4
point:      resd 2

section .text

; a call into Windows from System V code (as in winabi.asm)
%macro WIN_ENTER 1
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

; TRACE string - a line for the debugger (System V write, any registers kept
; that the caller needs are its own business: rax, rcx, rdx, rsi, rdi, r8-r11)
%macro TRACE 1
    lea rdi, [%1]
    call trace_line
%endmacro

; trace_line(rdi zero-terminated text) - write(2, text, length)
trace_line:
    xor edx, edx
.len:
    cmp byte [rdi + rdx], 0
    je .go
    inc edx
    jmp .len
.go:
    mov rsi, rdi
    mov edi, 2
    jmp write

; ---------------------------------------------------------------------------
; the program starts here: find the DLL functions, run the game
start:
    sub rsp, 40
    call win_imports_init
    TRACE s_t_start
    mov edi, 1
    lea rsi, [argv]
    call main
    mov ecx, eax
    call [rel __imp_ExitProcess]

; int init_window(void) - 1 when the window and OpenGL are up
init_window:
    WIN_ENTER 64
    TRACE s_t_window
    xor ecx, ecx
    call [rel __imp_GetModuleHandleA]
    mov [hinst], rax
    xor ecx, ecx
    mov edx, IDC_ARROW
    call [rel __imp_LoadCursorA]
    mov [arrow], rax
    lea rcx, [wndclass]
    mov dword [rcx], 80             ; cbSize
    mov dword [rcx + 4], CS_OWNDC
    lea rax, [wndproc]
    mov [rcx + 8], rax
    mov rax, [hinst]
    mov [rcx + 24], rax
    mov rax, [arrow]
    mov [rcx + 40], rax
    lea rax, [s_class]
    mov [rcx + 64], rax
    call [rel __imp_RegisterClassExA]
    ; the whole screen
    xor ecx, ecx                    ; SM_CXSCREEN
    call [rel __imp_GetSystemMetrics]
    mov [win_w], eax
    mov ecx, 1                      ; SM_CYSCREEN
    call [rel __imp_GetSystemMetrics]
    mov [win_h], eax
    mov ecx, WS_EX_APPWINDOW
    lea rdx, [s_class]
    lea r8, [s_title]
    mov r9d, WS_POPUP_VISIBLE
    mov qword [rsp + 32], 0         ; x
    mov qword [rsp + 40], 0         ; y
    mov eax, [win_w]
    mov [rsp + 48], rax
    mov eax, [win_h]
    mov [rsp + 56], rax
    mov qword [rsp + 64], 0         ; parent
    mov qword [rsp + 72], 0         ; menu
    mov rax, [hinst]
    mov [rsp + 80], rax
    mov qword [rsp + 88], 0
    call [rel __imp_CreateWindowExA]
    mov [hwnd], rax
    test rax, rax
    jz .fail
    mov rcx, rax
    call [rel __imp_GetDC]
    mov [hdc], rax
    ; double-buffered RGBA, 24-bit depth
    lea rdx, [pfd]
    mov word [rdx], 40
    mov word [rdx + 2], 1
    mov dword [rdx + 4], 0x25       ; DRAW_TO_WINDOW | SUPPORT_OPENGL | DOUBLEBUFFER
    mov byte [rdx + 8], 0           ; RGBA
    mov byte [rdx + 9], 32
    mov byte [rdx + 23], 24         ; depth bits
    mov rcx, [hdc]
    call [rel __imp_ChoosePixelFormat]
    test eax, eax
    jz .fail
    mov rcx, [hdc]
    mov edx, eax
    lea r8, [pfd]
    call [rel __imp_SetPixelFormat]
    test eax, eax
    jz .fail
    mov rcx, [hdc]
    call wgl_create
    mov [hglrc], rax
    test rax, rax
    jz .fail
    mov rcx, [hdc]
    mov rdx, [hglrc]
    call wgl_make_current
    test eax, eax
    jz .fail
    mov rcx, [hwnd]
    mov edx, 5                      ; SW_SHOW
    call [rel __imp_ShowWindow]
    mov rcx, [hwnd]
    call [rel __imp_SetForegroundWindow]
    mov rcx, [hwnd]
    call [rel __imp_SetFocus]
    TRACE s_t_gl
    mov eax, 1
    WIN_LEAVE
.fail:
    xor ecx, ecx
    lea rdx, [s_noctx]
    lea r8, [s_title]
    mov r9d, 0x10                   ; MB_ICONERROR
    call [rel __imp_MessageBoxA]
    xor eax, eax
    WIN_LEAVE

; void poll_events(void) - hand every waiting message to wndproc
poll_events:
    WIN_ENTER 16
.next:
    lea rcx, [msg]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp + 32], 1         ; PM_REMOVE
    call [rel __imp_PeekMessageA]
    test eax, eax
    jz .done
    cmp dword [msg + 8], WM_QUIT
    jne .disp
    call ev_close
    jmp .next
.disp:
    lea rcx, [msg]
    call [rel __imp_DispatchMessageA]
    jmp .next
.done:
    WIN_LEAVE

; void swap_buffers(void)
swap_buffers:
    WIN_ENTER 0
    mov rcx, [hdc]
    call [rel __imp_SwapBuffers]
    WIN_LEAVE

; void close_window(void)
close_window:
    WIN_ENTER 0
    xor ecx, ecx
    xor edx, edx
    call wgl_make_current
    mov rcx, [hglrc]
    call wgl_delete
    mov rcx, [hwnd]
    mov rdx, [hdc]
    call [rel __imp_ReleaseDC]
    mov rcx, [hwnd]
    call [rel __imp_DestroyWindow]
    WIN_LEAVE

; the mouse to the middle of the window
plat_warp:
    WIN_ENTER 0
    mov eax, [win_w]
    shr eax, 1
    mov [point], eax
    mov eax, [win_h]
    shr eax, 1
    mov [point + 4], eax
    mov rcx, [hwnd]
    lea rdx, [point]
    call [rel __imp_ClientToScreen]
    mov ecx, [point]
    mov edx, [point + 4]
    call [rel __imp_SetCursorPos]
    WIN_LEAVE

; mouse look: keep the pointer in the window, hidden
plat_grab:
    WIN_ENTER 0
    mov rcx, [hwnd]
    call [rel __imp_SetCapture]
    mov rcx, [hwnd]
    lea rdx, [rect]
    call [rel __imp_GetWindowRect]
    lea rcx, [rect]
    call [rel __imp_ClipCursor]
    xor ecx, ecx
    call [rel __imp_SetCursor]
    WIN_LEAVE

plat_release:
    WIN_ENTER 0
    xor ecx, ecx
    call [rel __imp_ClipCursor]
    call [rel __imp_ReleaseCapture]
    mov rcx, [arrow]
    call [rel __imp_SetCursor]
    WIN_LEAVE

; ---------------------------------------------------------------------------
; LRESULT wndproc(hwnd, msg, wparam, lparam) - called by Windows
; r12 hwnd, r13d msg, r14 wparam, r15 lparam
wndproc:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160 + 40
    and rsp, -16
%assign k 6
%rep 10
    movdqu [rbp - 56 - (k - 5) * 16], xmm %+ k
%assign k k + 1
%endrep
    mov r12, rcx
    mov r13d, edx
    mov r14, r8
    mov r15, r9
    cmp r13d, WM_KEYDOWN
    je .keydown
    cmp r13d, WM_SYSKEYDOWN
    je .syskeydown
    cmp r13d, WM_KEYUP
    je .keyup
    cmp r13d, WM_SYSKEYUP
    je .keyup
    cmp r13d, WM_MOUSEMOVE
    je .move
    cmp r13d, WM_LBUTTONDOWN
    je .ldown
    cmp r13d, WM_LBUTTONUP
    je .lup
    cmp r13d, WM_RBUTTONDOWN
    je .rdown
    cmp r13d, WM_RBUTTONUP
    je .rup
    cmp r13d, WM_MBUTTONDOWN
    je .mdown
    cmp r13d, WM_MOUSEWHEEL
    je .wheel
    cmp r13d, WM_SIZE
    je .size
    cmp r13d, WM_KILLFOCUS
    je .focus
    cmp r13d, WM_CLOSE
    je .close
    cmp r13d, WM_SETCURSOR
    je .cursor
    cmp r13d, WM_ERASEBKGND
    je .one
    cmp r13d, WM_SYSCOMMAND
    je .syscmd
    jmp .default

.syskeydown:
    cmp r14d, VK_F4                 ; Alt+F4 closes as usual
    je .default
.keydown:
    call keysym
    test eax, eax
    jz .zero
    mov edi, eax
    call ev_key_down
    jmp .zero
.keyup:
    call keysym
    test eax, eax
    jz .zero
    mov edi, eax
    call ev_key_up
    jmp .zero
.move:
    movsx edi, r15w
    mov rax, r15
    shr rax, 16
    movsx esi, ax
    call ev_motion
    jmp .zero
.ldown:
    mov edi, 1
    jmp .down
.rdown:
    mov edi, 3
    jmp .down
.mdown:
    mov edi, 2
.down:
    movsx esi, r15w
    mov rax, r15
    shr rax, 16
    movsx edx, ax
    call ev_button_down
    jmp .zero
.lup:
    mov edi, 1
    call ev_button_up
    jmp .zero
.rup:
    mov edi, 3
    call ev_button_up
    jmp .zero
.wheel:
    ; up: button 4, down: 5 (where the pointer already is)
    mov rax, r14
    shr rax, 16
    movsx eax, ax
    mov edi, 4
    test eax, eax
    jg .wh
    mov edi, 5
.wh:
    mov esi, [mouse_x]
    mov edx, [mouse_y]
    call ev_button_down
    jmp .zero
.size:
    movzx edi, r15w
    mov rax, r15
    shr rax, 16
    movzx esi, ax
    test edi, edi
    jz .zero                        ; minimised
    test esi, esi
    jz .zero
    call ev_resize
    jmp .zero
.focus:
    call ev_focus_out
    jmp .zero
.close:
    call ev_close                   ; the main loop closes the window
    jmp .zero
.cursor:
    ; no pointer over the game while looking around
    cmp dword [grabbed], 0
    je .default
    cmp r15w, HTCLIENT
    jne .default
    xor ecx, ecx
    call [rel __imp_SetCursor]
    jmp .one
.syscmd:
    mov rax, r14
    and eax, 0xfff0
    cmp eax, SC_KEYMENU             ; Alt alone: no window menu
    je .zero
.default:
    mov rcx, r12
    mov edx, r13d
    mov r8, r14
    mov r9, r15
    call [rel __imp_DefWindowProcA]
    jmp .ret
.one:
    mov eax, 1
    jmp .ret
.zero:
    xor eax, eax
.ret:
%assign k 6
%rep 10
    movdqu xmm %+ k, [rbp - 56 - (k - 5) * 16]
%assign k k + 1
%endrep
    lea rsp, [rbp - 56]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; eax = X11 keysym for the virtual key r14 (lparam r15: right-hand shift,
; ctrl and alt have their own keysyms), 0 if the game has no use for it
keysym:
    xor eax, eax
    cmp r14, VK_MAP_N
    jae .out
    lea rcx, [vk_map]
    movzx eax, word [rcx + r14*2]
    cmp eax, 0xffe1                 ; shift: the right one by its scan code
    jne .ctrl
    mov rcx, r15
    shr rcx, 16
    and ecx, 0xff
    cmp ecx, 0x36
    jne .out
    mov eax, 0xffe2
    ret
.ctrl:
    cmp eax, 0xffe3                 ; ctrl and alt: the right ones are "extended"
    je .ext
    cmp eax, 0xffe9
    jne .out
.ext:
    bt r15, 24
    jnc .out
    inc eax
.out:
    ret

%endif

NOEXECSTACK
