; main.asm - VoxASM entry point: X11 window, event handling, screens,
; game loop, chunk streaming with far-terrain detail levels.
;
; Screens: home -> new world (survival / creative) -> game, with settings
; and pause menus (ui.asm). The world is drawn by render.asm, the player
; simulated by player.asm, terrain made on a second core by worker.asm.

%include "common.inc"

%ifdef VOXASM_TEST
; headless test build (tests/test_game.c drives the frame functions)
global init_spiral, update_chunks, apply_settings, game_frame
%elifdef VOXASM_WIN
global main, ev_key_down, ev_key_up, ev_button_down, ev_button_up
global ev_motion, ev_resize, ev_close, ev_focus_out
%else
global _start, main
%endif
global state, settings_return, mouse_x, mouse_y, mouse_click, running
global mouse_wheel, menu_lmb
global world_active, seed, win_w, win_h, keys, dt, acc_x, acc_y, grabbed
global lmb_down, warp_center, cur_pcx, cur_pcz, spiral, spiral_n, fps
global t_now, errmsg, start_world, end_world, resume_game, respawn, threaded
global world_time, sunlight, tod, new_world_slot, load_world, spiral_r2

; libc
extern exit, clock_gettime, strtol, strcmp, time, printf, write, fflush, usleep
%ifdef VOXASM_WIN
; the window, input and OpenGL context (win32.asm)
extern init_window, poll_events, swap_buffers, close_window
extern plat_warp, plat_grab, plat_release
%else
; Xlib / GLX
extern XOpenDisplay, XDefaultScreen, XRootWindow, XCreateColormap
extern XCreateWindow, XMapWindow, XStoreName, XInternAtom, XSetWMProtocols
extern XPending, XNextEvent, XLookupKeysym, XWarpPointer, XGrabPointer
extern XUngrabPointer, XDefineCursor, XUndefineCursor, XCreateBitmapFromData
extern XCreatePixmapCursor, XFreePixmap, XkbSetDetectableAutoRepeat
extern XDestroyWindow, XCloseDisplay, XResizeWindow
extern glXChooseVisual, glXCreateContext, glXMakeCurrent, glXSwapBuffers
extern glXDestroyContext
%endif
extern glGetString, glClearColor, glClear
; modules
extern settings_load, settings_pending, set_range, set_lod, set_leaves
extern set_window
extern init_gl, rebuild_atlas, apply_vsync, renderer_reset, upload_slot
extern render_world, draw_hud, ui_frame
extern world_find, world_gen_sync, world_slot_of, chunk_info
extern mesh_chunk, mesh_set_leaves_opaque
extern worker_start, worker_submit, worker_collect, worker_wait_idle
extern worker_set_seed
extern liquid_step, liquid_reset
extern pos, player_new, player_spawn, update_look, update_player
extern flying, sprinting, vel, knock_x, knock_z, mob_update, mob_clear, crop_tick
extern spawn_bed
extern update_survival, update_target, update_digging, do_place
extern toggle_fly, select_slot, sel_slot, player_dead, player_use
extern drop_selected, spawn_pos
extern save_init, world_create_dir, load_meta, save_all, save_meta, save_chunk
extern world_dir, cur_world
extern horizon_update, horizon_reset, horizon_remesh
extern furnace_tick, ent_update, ent_clear, furnaces
extern invui_frame, invui_open, invui_close, invui_qpress
extern boat_update, boat_clear, riding, tnt_update, tnt_clear
extern fire_update, fire_clear, portal_update, dimension, save_all
extern beacon_update, beacon_clear
global dim_enter
extern bind_inv, bind_drop, bind_fly, controls_key, delete_pending
extern light_chunk, mapgen_base_height, mapgen_flat, set_daycycle

MAX_SPIRAL      equ 2048
NETHER_RANGE    equ 4               ; view range (chunks) in the nether
LIQUID_BUDGET   equ 4000            ; nodes per water step
FURNACE_BYTES   equ 32 * 48

; X11
KeyPress        equ 2
KeyRelease      equ 3
ButtonPress     equ 4
ButtonRelease   equ 5
MotionNotify    equ 6
FocusOut        equ 10
ConfigureNotify equ 22
ClientMessage   equ 33
EVENT_MASK      equ 0x1 | 0x2 | 0x4 | 0x8 | 0x40 | 0x8000 | 0x20000 | 0x200000
GRAB_MASK       equ 0x4 | 0x8 | 0x40
CW_FLAGS        equ 0x2000 | 0x800  ; CWColormap | CWEventMask
XK_Escape       equ 0xff1b
GL_RENDERER     equ 0x1F01
GL_VERSION      equ 0x1F02
GL_COLOR_BUFFER_BIT equ 0x4000

section .data
win_w:      dd 1024
win_h:      dd 640
running:    dd 1
state:      dd GS_MAIN
settings_return: dd GS_MAIN

section .rodata
align 8
d_1e9:      dq 1.0e-9
d_one:      dq 1.0
d_tick:     dq 0.2                  ; seconds between water steps
f_dtmax:    dd 0.05
f_zero:     dd 0.0
f_genbudget:  dd 0.012              ; single-threaded world gen per frame (s)
f_meshbudget: dd 0.008              ; meshing per frame (s)
f_lightbudget: dd 0.006             ; relighting per frame (s)
f_daylen:   dd 1200.0               ; seconds per day (20 minutes)
f_inv_daylen: dd 0.000833333333
f_2pi:      dd 6.28318531
f_day_lo:   dd 0.14                 ; darkest night
f_day_hi:   dd 1.0
f_day_off:  dd 0.2
f_day_mul:  dd 1.4
f_morning:  dd 60.0                 ; new worlds start a minute after sunrise
f_noon:     dd 0.25
d_autosave: dq 120.0
window_sizes: dd 640, 400, 800, 500, 1024, 640, 1280, 800
glx_attr24: dd 4, 5, 12, 24, 0      ; GLX_RGBA, GLX_DOUBLEBUFFER, DEPTH 24
glx_attr16: dd 4, 5, 12, 16, 0
s_title:    db "VoxASM", 0
s_wmdel:    db "WM_DELETE_WINDOW", 0
s_seed:     db "--seed", 0
s_range:    db "--range", 0
s_glinfo:   db "VoxASM: %s / OpenGL %s / %s", 10, 0
s_thr1:     db "world gen on 2nd core", 0
s_thr0:     db "single-threaded world gen", 0
s_errdpy:   db "VoxASM: cannot open X display (is $DISPLAY set?)", 10
s_errdpy_len equ $ - s_errdpy
s_errvis:   db "VoxASM: no OpenGL visual with RGBA + double buffer + depth", 10
s_errvis_len equ $ - s_errvis
s_usage:    db "usage: voxasm [--seed N] [--range 2-12]", 10
            db "  Settings are in the in-game menu and saved to", 10
            db "  ~/.config/voxasm.conf (or $XDG_CONFIG_HOME/voxasm.conf).", 10
s_usage_len equ $ - s_usage

section .bss
alignb 16
view_range: resd 1                  ; chunks loaded round the player (set_range,
                                    ; less in the nether)
dpy:        resq 1
win:        resq 1
glctx:      resq 1
visinfo:    resq 1
wm_delete:  resq 1
blank_cur:  resq 1
t_now:      resq 1
t_last:     resq 1
t_title:    resq 1
t_liquid:   resq 1
t_save:     resq 1
world_time: resd 1                  ; seconds into the current day
sunlight:   resd 1                  ; 0.14 (night) .. 1 (day)
tod:        resd 1                  ; time of day 0..1, 0 = sunrise
new_world_slot: resd 1              ; world number a new world is made in
seed:       resd 1
grabbed:    resd 1
threaded:   resd 1
world_active: resd 1
mouse_x:    resd 1
mouse_y:    resd 1
mouse_click: resd 1
mouse_wheel: resd 1                 ; wheel steps not yet used by a menu
menu_lmb:   resd 1                  ; left button held down in a menu (dragging)
lmb_down:   resd 1
acc_x:      resd 1
acc_y:      resd 1
dt:         resd 1
cur_pcx:    resd 1
cur_pcz:    resd 1
frames:     resd 1
fps:        resd 1
keys:       resb 512
alignb 4
spiral:     resd MAX_SPIRAL * 2         ; dx, dz
spiral_n:   resd 1
spiral_r2:  resd 1

section .text

%ifndef VOXASM_TEST
%ifndef VOXASM_WIN
; Own entry point instead of crt1's __libc_start_main, so the binary only
; needs symbol versions from glibc 2.2.5 and runs on old and new distros.
_start:
    xor ebp, ebp
    mov rdi, [rsp]
    lea rsi, [rsp + 8]
    and rsp, -16
    call main
    mov edi, eax
    call exit PLT
%endif
%endif

; double now(void) - monotonic seconds
now:
    sub rsp, 24
%ifidn __OUTPUT_FORMAT__, elf64
    mov edi, 1                      ; CLOCK_MONOTONIC on Linux
%else
    mov edi, 6                      ; CLOCK_MONOTONIC on macOS (unit tests)
%endif
    mov rsi, rsp
    call clock_gettime PLT
    cvtsi2sd xmm0, qword [rsp]
    cvtsi2sd xmm1, qword [rsp + 8]
    mulsd xmm1, [d_1e9]
    addsd xmm0, xmm1
    add rsp, 24
    ret

; write(2, rdi, esi)
errmsg:
    sub rsp, 8
    mov edx, esi
    mov rsi, rdi
    mov edi, 2
    call write PLT
    add rsp, 8
    ret

%ifndef VOXASM_TEST
; int main(int argc, char **argv)
main:
    ENTER_FN 32
    mov r12d, edi
    mov r13, rsi
    call settings_load
    call save_init
    xor edi, edi
    call time PLT
    and eax, 0x7fffffff
    mov [seed], eax
    mov ebx, 1
.arg:
    cmp ebx, r12d
    jge .args_done
    mov r14, [r13 + rbx*8]
    mov rdi, r14
    lea rsi, [s_seed]
    call strcmp PLT
    test eax, eax
    jz .a_seed
    mov rdi, r14
    lea rsi, [s_range]
    call strcmp PLT
    test eax, eax
    jz .a_range
    jmp .usage
.a_seed:
    inc ebx
    cmp ebx, r12d
    jge .usage
    mov rdi, [r13 + rbx*8]
    xor esi, esi
    mov edx, 10
    call strtol PLT
    mov [seed], eax
    inc ebx
    jmp .arg
.a_range:
    inc ebx
    cmp ebx, r12d
    jge .usage
    mov rdi, [r13 + rbx*8]
    xor esi, esi
    mov edx, 10
    call strtol PLT
    cmp eax, 2
    jge .r1
    mov eax, 2
.r1:
    cmp eax, MAX_RANGE
    jle .r2
    mov eax, MAX_RANGE
.r2:
    mov [set_range], eax
    inc ebx
    jmp .arg
.usage:
    mov edi, 1
    lea rsi, [s_usage]
    mov edx, s_usage_len
    call write PLT
    xor eax, eax
    LEAVE_FN

.args_done:
    mov eax, [set_window]
    lea rcx, [window_sizes]
    mov edx, [rcx + rax*8]
    mov [win_w], edx
    mov edx, [rcx + rax*8 + 4]
    mov [win_h], edx
    call init_window
    test eax, eax
    jz .fail
    call init_gl
    test eax, eax
    jz .fail
    mov edi, [set_leaves]
    call mesh_set_leaves_opaque
    call init_spiral
    mov edi, [seed]
    call worker_start
    mov [threaded], eax

    ; banner
    mov edi, GL_RENDERER
    call glGetString PLT
    mov r14, rax
    mov edi, GL_VERSION
    call glGetString PLT
    mov rdx, rax
    mov rsi, r14
    lea rdi, [s_glinfo]
    lea rcx, [s_thr1]
    cmp dword [threaded], 0
    jne .thr
    lea rcx, [s_thr0]
.thr:
    xor eax, eax
    call printf PLT
    xor edi, edi
    call fflush PLT

    call now
    movsd [t_last], xmm0
    movsd [t_title], xmm0
.loop:
    call poll_events
    cmp dword [running], 0
    je .quit
    call game_frame
    call swap_buffers
    call update_fps
    ; menus need no more than about 60 frames a second: let the CPU rest
    cmp dword [world_active], 0
    jne .loop
    mov edi, 15000
    call usleep PLT
    jmp .loop

.quit:
    cmp dword [world_active], 0
    je .q
    call save_all
.q:
    call release_mouse
    call close_window
    xor eax, eax
    LEAVE_FN
.fail:
    mov eax, 1
    LEAVE_FN
%endif

; One frame: simulate, stream, apply settings, draw.
game_frame:
    ENTER_FN 0
    call now
    movsd [t_now], xmm0
    movsd xmm1, xmm0
    subsd xmm0, [t_last]
    movsd [t_last], xmm1
    cvtsd2ss xmm0, xmm0
    minss xmm0, [f_dtmax]
    maxss xmm0, [f_zero]
    movss [dt], xmm0
    call apply_settings
    cmp dword [world_active], 0
    je .menu
    call day_clock
    mov eax, [state]
    cmp eax, GS_GAME
    je .play
    cmp eax, GS_INVENTORY
    jb .stream
    cmp eax, GS_DYE
    ja .stream
    ; an inventory screen is open: the world keeps going around the player
    call update_player
    call update_survival
    jmp .world
.play:
    call update_look
    call update_player
    call update_survival
    call update_target
    call update_digging
    call portal_update
.world:
    movss xmm0, [dt]
    call furnace_tick
    call ent_update
    call mob_update
    call boat_update
    call tnt_update
    call fire_update
    call beacon_update
    call crop_tick
    ; water a few times per second
    movsd xmm0, [t_now]
    subsd xmm0, [t_liquid]
    comisd xmm0, [d_tick]
    jb .nowater
    movsd xmm0, [t_now]
    movsd [t_liquid], xmm0
    mov edi, LIQUID_BUDGET
    call liquid_step
.nowater:
    ; autosave
    movsd xmm0, [t_now]
    subsd xmm0, [t_save]
    comisd xmm0, [d_autosave]
    jb .nosave
    movsd xmm0, [t_now]
    movsd [t_save], xmm0
    call save_all
.nosave:
    cmp dword [player_dead], 0
    je .stream
    cmp dword [state], GS_DEAD
    je .stream
    cmp dword [state], GS_GAME
    je .died
    call invui_close
.died:
    mov dword [state], GS_DEAD
    call release_mouse
.stream:
    call update_chunks
    call render_world
    mov eax, [state]
    cmp eax, GS_GAME
    je .hud
    cmp eax, GS_INVENTORY
    jb .ui
    cmp eax, GS_DYE
    ja .ui
    call draw_hud
    call invui_frame
    jmp .out
.hud:
    call draw_hud
    jmp .out
.menu:
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glClearColor PLT
    mov edi, GL_COLOR_BUFFER_BIT
    call glClear PLT
.ui:
    call ui_frame
.out:
    mov dword [mouse_click], 0
    LEAVE_FN

; day_clock - advance the time of day; daylight and tod for the renderer
; (sunrise at tod 0, noon 0.25, sunset 0.5, midnight 0.75)
day_clock:
    sub rsp, 24
    cmp dword [set_daycycle], 0
    jne .cycle
    mov dword [sunlight], 0x3f800000
    mov eax, [f_noon]
    mov [tod], eax
    add rsp, 24
    ret
.cycle:
    movss xmm0, [world_time]
    addss xmm0, [dt]
    comiss xmm0, [f_daylen]
    jb .wrap
    subss xmm0, [f_daylen]
.wrap:
    movss [world_time], xmm0
    mulss xmm0, [f_inv_daylen]
    movss [tod], xmm0
    mulss xmm0, [f_2pi]
    movss [rsp], xmm0
    fld dword [rsp]
    fsin
    fstp dword [rsp]
    movss xmm0, [rsp]               ; sun height -1..1
    addss xmm0, [f_day_off]
    mulss xmm0, [f_day_mul]
    addss xmm0, [f_day_lo]
    maxss xmm0, [f_day_lo]
    minss xmm0, [f_day_hi]
    movss [sunlight], xmm0
    add rsp, 24
    ret

update_fps:
    ENTER_FN 0
    inc dword [frames]
    call now
    movsd xmm1, xmm0
    subsd xmm1, [t_title]
    comisd xmm1, [d_one]
    jb .out
    movsd [t_title], xmm0
    mov eax, [frames]
    mov [fps], eax
    mov dword [frames], 0
.out:
    LEAVE_FN

; Apply settings changed in the menu (needs the GL context).
apply_settings:
    ENTER_FN 0
    mov ebx, [settings_pending]
    test ebx, ebx
    jz .out
    mov dword [settings_pending], 0
    test ebx, 1                     ; view distance
    jz .a1
    call init_spiral
    call horizon_remesh
.a1:
    test ebx, 2                     ; textures
    jz .a2
    call rebuild_atlas
.a2:
    test ebx, 64                    ; leaves: also changes face culling
    jz .a3
    mov edi, [set_leaves]
    call mesh_set_leaves_opaque
    lea rax, [chunk_info]
    mov ecx, NUM_SLOTS
.dirty:
    mov byte [rax + CI_DIRTY], 1
    add rax, CI_SIZE
    dec ecx
    jnz .dirty
.a3:
    test ebx, 8                     ; renderer
    jz .a4
    call renderer_reset
.a4:
    test ebx, 16
    jz .a5
    call apply_vsync
.a5:
    test ebx, 128                   ; horizon distance
    jz .a6
    call horizon_reset
.a6:
    test ebx, 32                    ; window size
    jz .out
%ifdef VOXASM_WIN
    jmp .out                        ; (Windows: always the whole screen)
%endif
    cmp qword [dpy], 0
    je .out
    mov eax, [set_window]
    lea rcx, [window_sizes]
    mov edx, [rcx + rax*8]
    mov ecx, [rcx + rax*8 + 4]
%ifndef VOXASM_WIN
    mov rdi, [dpy]
    mov rsi, [win]
    call XResizeWindow PLT
%endif
.out:
    LEAVE_FN

; ---------------------------------------------------------------------------
; worlds

; close the current world's chunks (waits for the generator)
world_reset:
    ENTER_FN 0
    cmp dword [threaded], 0
    je .clear
    call worker_wait_idle
.clear:
    lea rdi, [chunk_info]
    xor eax, eax
    mov ecx, NUM_SLOTS * CI_SIZE
    rep stosb
    call liquid_reset
    LEAVE_FN

; first column near the origin that is dry land (like Luanti's spawn
; search), into spawn_pos
find_spawn:
    ENTER_FN 0
    mov dword [spawn_pos], 8
    mov dword [spawn_pos + 4], 0
    mov dword [spawn_pos + 8], 8
    cmp dword [mapgen_flat], 0
    jne .out
    xor ebx, ebx                    ; attempt
.try:
    ; walk outwards along a square-ish spiral of 24-node steps
    mov eax, ebx
    and eax, 7
    sub eax, 3
    imul r12d, eax, 24
    add r12d, 8
    mov eax, ebx
    shr eax, 3
    sub eax, 3
    imul r13d, eax, 24
    add r13d, 8
    mov edi, r12d
    mov esi, r13d
    mov edx, [seed]
    call mapgen_base_height
    cmp eax, WATER_LEVEL + 3
    jl .next
    cmp eax, 90
    jg .next
    mov [spawn_pos], r12d
    mov [spawn_pos + 8], r13d
    jmp .out
.next:
    inc ebx
    cmp ebx, 64
    jb .try
.out:
    LEAVE_FN

; pregen(edi chunk x, esi chunk z) - make the chunks right around a point
; on this thread so the player has ground to stand on
pregen:
    ENTER_FN 0
    mov r12d, edi
    mov r13d, esi
    xor ebx, ebx
.p:
    cmp ebx, [spiral_n]
    jae .done
    lea rax, [spiral]
    mov edi, [rax + rbx*8]
    mov esi, [rax + rbx*8 + 4]
    mov eax, edi
    imul eax, eax
    mov ecx, esi
    imul ecx, ecx
    add eax, ecx
    cmp eax, 2
    ja .done
    add edi, r12d
    add esi, r13d
    mov edx, [seed]
    call world_gen_sync
    inc ebx
    jmp .p
.done:
    LEAVE_FN

; things every world starts without
fresh_world_state:
    ENTER_FN 0
    ; nothing about how the player moved carries over from another world
    mov dword [flying], 0
    mov dword [sprinting], 0
    mov dword [vel], 0
    mov dword [vel + 4], 0
    mov dword [vel + 8], 0
    mov dword [knock_x], 0
    mov dword [knock_z], 0
    mov dword [riding], 0
    call tnt_clear
    call fire_clear
    call beacon_clear
    call mob_clear
    call world_reset
    call horizon_reset
    call ent_clear
    mov edi, [seed]
    call worker_set_seed
    call now
    movsd [t_liquid], xmm0
    movsd [t_save], xmm0
    LEAVE_FN

; void dim_enter(int x, int z, int dim) - into dimension dim (0 overworld,
; 1 nether): an empty world with its view range, the chunks round node
; (x, z) made. Save the old one first.
dim_enter:
    ENTER_FN 0
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call world_reset                ; (waits for the generator first)
    mov [dimension], r14d
    call fresh_world_state
    call init_spiral
    mov edi, r12d
    sar edi, 4
    mov esi, r13d
    sar esi, 4
    call pregen
    LEAVE_FN

; void start_world(int mode) - 0 survival, 1 creative, in world slot
; new_world_slot
start_world:
    ENTER_FN 0
    mov r12d, edi
    mov dword [dimension], 0
    call init_spiral
    call fresh_world_state
    mov dword [spawn_bed], 0        ; a new world: no bed yet
    call boat_clear
    lea rdi, [furnaces]
    xor eax, eax
    mov ecx, FURNACE_BYTES
    rep stosb
    mov edi, [new_world_slot]
    call world_create_dir
    call find_spawn
    mov edi, [spawn_pos]
    sar edi, 4
    mov esi, [spawn_pos + 8]
    sar esi, 4
    call pregen
    mov edi, r12d
    call player_new
    call player_spawn
    mov eax, [f_morning]
    mov [world_time], eax
    call save_meta
    mov dword [world_active], 1
    mov dword [state], GS_GAME
    call grab_mouse
    LEAVE_FN

; int load_world(int n) - continue a saved world
load_world:
    ENTER_FN 0
    mov r12d, edi
    call world_reset
    mov edi, r12d
    call load_meta
    test eax, eax
    jz .out
    call fresh_world_state
    call init_spiral                ; (the nether sees less far)
    movss xmm0, [pos]
    cvttss2si edi, xmm0
    sar edi, 4
    movss xmm0, [pos + 8]
    cvttss2si esi, xmm0
    sar esi, 4
    call pregen
    mov dword [player_dead], 0
    mov dword [world_active], 1
    mov dword [state], GS_GAME
    call grab_mouse
    mov eax, 1
.out:
    LEAVE_FN

end_world:
    ENTER_FN 0
    call release_mouse
    call save_all
    call world_reset
    call horizon_reset
    call ent_clear
    mov byte [world_dir], 0
    mov dword [cur_world], 0
    mov dword [world_active], 0
    mov dword [state], GS_MAIN
    LEAVE_FN

resume_game:
    ENTER_FN 0
    mov dword [state], GS_GAME
    call grab_mouse
    LEAVE_FN

respawn:
    ENTER_FN 0
    ; dead in the nether: back to the overworld first
    cmp dword [dimension], 0
    je .here
    call save_all
    mov edi, [spawn_pos]
    mov esi, [spawn_pos + 8]
    xor edx, edx
    call dim_enter
.here:
    call player_spawn
    mov dword [state], GS_GAME
    call grab_mouse
    LEAVE_FN

; ---------------------------------------------------------------------------
%ifndef VOXASM_TEST
%ifndef VOXASM_WIN
; present the frame
swap_buffers:
    sub rsp, 8
    mov rdi, [dpy]
    mov rsi, [win]
    call glXSwapBuffers PLT
    add rsp, 8
    ret

; close the window and the GL context
close_window:
    sub rsp, 8
    mov rdi, [dpy]
    xor esi, esi
    xor edx, edx
    call glXMakeCurrent PLT
    mov rdi, [dpy]
    mov rsi, [glctx]
    call glXDestroyContext PLT
    mov rdi, [dpy]
    mov rsi, [win]
    call XDestroyWindow PLT
    mov rdi, [dpy]
    call XCloseDisplay PLT
    add rsp, 8
    ret

; int init_window(void)
; locals: [0..47] stack args, [64] XSetWindowAttributes (112),
;         [192] XColor (16), [208] bitmap bits (8)
init_window:
    ENTER_FN 224
    xor edi, edi
    call XOpenDisplay PLT
    test rax, rax
    jz .nodpy
    mov [dpy], rax
    mov rdi, rax
    call XDefaultScreen PLT
    mov r12d, eax
    mov rdi, [dpy]
    mov esi, r12d
    call XRootWindow PLT
    mov r13, rax                    ; root
    mov rdi, [dpy]
    mov esi, r12d
    lea rdx, [glx_attr24]
    call glXChooseVisual PLT
    test rax, rax
    jnz .vis_ok
    mov rdi, [dpy]
    mov esi, r12d
    lea rdx, [glx_attr16]
    call glXChooseVisual PLT
    test rax, rax
    jz .novis
.vis_ok:
    mov [visinfo], rax
    mov r14, rax
    ; zero XSetWindowAttributes, XColor and the cursor bitmap
    lea rdi, [rsp + 64]
    xor eax, eax
    mov ecx, 152
    rep stosb
    mov rdi, [dpy]
    mov rsi, r13
    mov rdx, [r14]                  ; vi->visual
    xor ecx, ecx                    ; AllocNone
    call XCreateColormap PLT
    mov [rsp + 64 + 96], rax
    mov qword [rsp + 64 + 72], EVENT_MASK
    mov rdi, [dpy]
    mov rsi, r13
    xor edx, edx
    xor ecx, ecx
    mov r8d, [win_w]
    mov r9d, [win_h]
    mov qword [rsp], 0              ; border
    movsxd rax, dword [r14 + 20]
    mov [rsp + 8], rax              ; depth
    mov qword [rsp + 16], 1         ; InputOutput
    mov rax, [r14]
    mov [rsp + 24], rax             ; visual
    mov qword [rsp + 32], CW_FLAGS
    lea rax, [rsp + 64]
    mov [rsp + 40], rax
    call XCreateWindow PLT
    mov [win], rax
    mov rdi, [dpy]
    mov rsi, [win]
    lea rdx, [s_title]
    call XStoreName PLT
    mov rdi, [dpy]
    lea rsi, [s_wmdel]
    xor edx, edx
    call XInternAtom PLT
    mov [wm_delete], rax
    mov rdi, [dpy]
    mov rsi, [win]
    lea rdx, [wm_delete]
    mov ecx, 1
    call XSetWMProtocols PLT
    mov rdi, [dpy]
    mov rsi, [win]
    call XMapWindow PLT
    mov rdi, [dpy]
    mov esi, 1
    xor edx, edx
    call XkbSetDetectableAutoRepeat PLT
    ; invisible cursor for mouse look
    mov rdi, [dpy]
    mov rsi, [win]
    lea rdx, [rsp + 208]
    mov ecx, 8
    mov r8d, 8
    call XCreateBitmapFromData PLT
    mov r15, rax
    mov rdi, [dpy]
    mov rsi, r15
    mov rdx, r15
    lea rcx, [rsp + 192]
    lea r8, [rsp + 192]
    xor r9d, r9d
    mov qword [rsp], 0
    call XCreatePixmapCursor PLT
    mov [blank_cur], rax
    mov rdi, [dpy]
    mov rsi, r15
    call XFreePixmap PLT
    mov rdi, [dpy]
    mov rsi, r14
    xor edx, edx
    mov ecx, 1                      ; direct rendering
    call glXCreateContext PLT
    mov [glctx], rax
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [glctx]
    call glXMakeCurrent PLT
    mov eax, 1
    LEAVE_FN
.nodpy:
    lea rdi, [s_errdpy]
    mov esi, s_errdpy_len
    call errmsg
    xor eax, eax
    LEAVE_FN
.novis:
    lea rdi, [s_errvis]
    mov esi, s_errvis_len
    call errmsg
    xor eax, eax
    LEAVE_FN
%endif
%endif

; Chunk offsets within the view range, nearest first.
init_spiral:
    mov eax, [set_range]
    cmp dword [dimension], 0
    je .r
    mov ecx, NETHER_RANGE           ; the nether is all caves: see less of it
    cmp eax, ecx
    cmova eax, ecx
.r:
    mov [view_range], eax
    mov ecx, eax
    imul ecx, eax
    add ecx, eax                    ; r^2 + r: rounder disc
    mov [spiral_r2], ecx
    xor r8d, r8d                    ; count
    xor r9d, r9d                    ; d2
.d2:
    mov r10d, [view_range]
    neg r10d                        ; dz
.dz:
    mov r11d, [view_range]
    neg r11d                        ; dx
.dx:
    mov eax, r11d
    imul eax, eax
    mov edx, r10d
    imul edx, edx
    add eax, edx
    cmp eax, r9d
    jne .skip
    cmp r8d, MAX_SPIRAL
    jae .skip
    lea rcx, [spiral]
    mov [rcx + r8*8], r11d
    mov [rcx + r8*8 + 4], r10d
    inc r8d
.skip:
    inc r11d
    cmp r11d, [view_range]
    jle .dx
    inc r10d
    cmp r10d, [view_range]
    jle .dz
    inc r9d
    cmp r9d, [spiral_r2]
    jbe .d2
    mov [spiral_n], r8d
    ret

; ---------------------------------------------------------------- input --
; ecx = key slot for keysym eax, or -1
keyidx:
    mov ecx, eax
    cmp eax, 256
    jb .ok
    mov ecx, eax
    and ecx, 0xffffff00
    cmp ecx, 0xff00
    jne .no
    movzx ecx, al
    add ecx, 256
.ok:
    ret
.no:
    mov ecx, -1
    ret

warp_center:
    ENTER_FN 32
%ifdef VOXASM_WIN
    call plat_warp
%elifndef VOXASM_TEST
    mov rdi, [dpy]
    xor esi, esi
    mov rdx, [win]
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp], 0
    mov eax, [win_w]
    shr eax, 1
    mov [rsp + 8], rax
    mov eax, [win_h]
    shr eax, 1
    mov [rsp + 16], rax
    call XWarpPointer PLT
%endif
    LEAVE_FN

grab_mouse:
    ENTER_FN 32
%ifdef VOXASM_WIN
    call plat_grab
%elifndef VOXASM_TEST
    mov rdi, [dpy]
    mov rsi, [win]
    mov edx, 1
    mov ecx, GRAB_MASK
    mov r8d, 1                      ; GrabModeAsync
    mov r9d, 1
    mov rax, [win]
    mov [rsp], rax                  ; confine_to
    mov rax, [blank_cur]
    mov [rsp + 8], rax
    mov qword [rsp + 16], 0         ; CurrentTime
    call XGrabPointer PLT
    test eax, eax
    jnz .out
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [blank_cur]
    call XDefineCursor PLT
%endif
    mov dword [grabbed], 1
    mov dword [acc_x], 0
    mov dword [acc_y], 0
    call warp_center
.out:
    LEAVE_FN

release_mouse:
    ENTER_FN 0
    mov dword [lmb_down], 0
    cmp dword [grabbed], 0
    je .out
    mov dword [grabbed], 0
%ifdef VOXASM_WIN
    call plat_release
%elifndef VOXASM_TEST
    mov rdi, [dpy]
    xor esi, esi
    call XUngrabPointer PLT
    mov rdi, [dpy]
    mov rsi, [win]
    call XUndefineCursor PLT
%endif
.out:
    LEAVE_FN

; ---------------------------------------------------------------------------
; Input events, whatever the window system: the X11 loop below and the
; Win32 window procedure (win32.asm) both call these. Keys are X11 keysyms
; (win32.asm translates virtual keys to them), buttons X11 numbers (1 left,
; 3 right, 4/5 wheel up/down).

; void ev_key_down(int keysym)
ev_key_down:
    ENTER_FN 0
    mov ebx, edi
    mov eax, edi
    call keyidx
    test ecx, ecx
    js .out
    lea rdx, [keys]
    mov byte [rdx + rcx], 1
    mov eax, [state]
    cmp eax, GS_GAME
    je .k_game
    cmp eax, GS_CONTROLS
    jne .k_notctl
    mov edi, ecx                    ; a new key for an action, or Esc
    call controls_key
    jmp .out
.k_notctl:
    cmp eax, GS_INVENTORY
    jb .k_menu
    cmp eax, GS_DYE
    ja .k_menu
    ; inventory screens close with the inventory key or Esc; the drop
    ; key throws from the stack on the mouse
    cmp ecx, [bind_drop]
    jne .k_notdrop
    call invui_qpress
    jmp .out
.k_notdrop:
    cmp ecx, [bind_inv]
    je .k_close
    cmp ebx, XK_Escape
    jne .out
.k_close:
    call invui_close
    jmp .out
.k_menu:
    cmp ebx, XK_Escape
    jne .out
    cmp eax, GS_PAUSE
    je .k_resume
    cmp eax, GS_WORLDS
    je .k_worlds
    cmp eax, GS_SETTINGS
    je .k_settings_back
    cmp eax, GS_PLAY
    jne .out
    mov dword [state], GS_WORLDS
    jmp .out
.k_worlds:
    cmp dword [delete_pending], 0   ; Esc on "delete?" just says no
    je .k_main
    mov dword [delete_pending], 0
    jmp .out
.k_main:
    mov dword [state], GS_MAIN
    jmp .out
.k_resume:
    call resume_game
    jmp .out
.k_settings_back:
    mov eax, [settings_return]
    mov [state], eax
    jmp .out
.k_game:
    cmp ebx, XK_Escape
    je .pause
    cmp ecx, [bind_fly]
    je .fly
    cmp ecx, [bind_inv]
    je .inventory
    cmp ecx, [bind_drop]
    je .drop
    cmp ebx, '1'
    jb .out
    cmp ebx, '9'
    ja .out
    lea edi, [rbx - '1']
    call select_slot
    jmp .out
.pause:
    mov dword [state], GS_PAUSE
    call release_mouse
    jmp .out
.fly:
    call toggle_fly
    jmp .out
.inventory:
    mov edi, GS_INVENTORY
    call invui_open
    call release_mouse
    jmp .out
.drop:
    call drop_selected
.out:
    LEAVE_FN

; void ev_key_up(int keysym)
ev_key_up:
    mov eax, edi
    call keyidx
    test ecx, ecx
    js .out
    lea rdx, [keys]
    mov byte [rdx + rcx], 0
.out:
    ret

; void ev_button_down(int button, int x, int y)
ev_button_down:
    ENTER_FN 0
    mov [mouse_x], esi
    mov [mouse_y], edx
    mov eax, edi
    cmp dword [state], GS_GAME
    je .b_game
    cmp eax, 4                      ; wheel up / down: scroll lists
    jne .b_wd
    dec dword [mouse_wheel]
    jmp .out
.b_wd:
    cmp eax, 5
    jne .b_btn
    inc dword [mouse_wheel]
    jmp .out
.b_btn:
    cmp eax, 1
    jne .b_r
    mov dword [menu_lmb], 1
    jmp .b_click
.b_r:
    cmp eax, 3
    jne .out
.b_click:
    mov [mouse_click], eax
    jmp .out
.b_game:
    cmp dword [grabbed], 0
    jne .b_play
    call grab_mouse
    jmp .out
.b_play:
    cmp eax, 1
    je .dig
    cmp eax, 3
    je .place
    cmp eax, 4
    je .wheel_up
    cmp eax, 5
    je .wheel_down
    jmp .out
.dig:
    mov dword [lmb_down], 1
    jmp .out
.place:
    call player_use
    cmp dword [state], GS_GAME
    je .out
    call release_mouse              ; a crafting table or furnace opened
    jmp .out
.wheel_up:
    mov eax, [sel_slot]
    add eax, 8
    jmp .wheel
.wheel_down:
    mov eax, [sel_slot]
    inc eax
.wheel:
    xor edx, edx
    mov ecx, 9
    div ecx
    mov edi, edx
    call select_slot
.out:
    LEAVE_FN

; void ev_button_up(int button)
ev_button_up:
    cmp edi, 1
    jne .out
    mov dword [lmb_down], 0
    mov dword [menu_lmb], 0
.out:
    ret

; void ev_motion(int x, int y) - window coordinates; while the mouse is
; grabbed (and kept at the centre) the distance from the centre turns
; the view
ev_motion:
    cmp dword [grabbed], 0
    je .free
    mov eax, edi
    mov ecx, [win_w]
    shr ecx, 1
    sub eax, ecx
    add [acc_x], eax
    mov eax, esi
    mov ecx, [win_h]
    shr ecx, 1
    sub eax, ecx
    add [acc_y], eax
    ret
.free:
    mov [mouse_x], edi
    mov [mouse_y], esi
    ret

; void ev_resize(int w, int h)
ev_resize:
    mov [win_w], edi
    mov [win_h], esi
    ret

; void ev_close(void)
ev_close:
    mov dword [running], 0
    ret

; void ev_focus_out(void) - keys let go, the game paused
ev_focus_out:
    ENTER_FN 0
    mov dword [menu_lmb], 0
    call release_mouse
    lea rdi, [keys]
    xor eax, eax
    mov ecx, 512
    rep stosb
    cmp dword [state], GS_GAME
    jne .out
    mov dword [state], GS_PAUSE
.out:
    LEAVE_FN

%ifndef VOXASM_TEST
%ifndef VOXASM_WIN
; XEvent (192 bytes) at [rsp]
poll_events:
    ENTER_FN 208
.next:
    mov rdi, [dpy]
    call XPending PLT
    test eax, eax
    jz .done
    mov rdi, [dpy]
    mov rsi, rsp
    call XNextEvent PLT
    mov eax, [rsp]
    cmp eax, KeyPress
    je .kpress
    cmp eax, KeyRelease
    je .krelease
    cmp eax, ButtonPress
    je .button
    cmp eax, ButtonRelease
    je .brelease
    cmp eax, MotionNotify
    je .motion
    cmp eax, ConfigureNotify
    je .configure
    cmp eax, ClientMessage
    je .client
    cmp eax, FocusOut
    je .focusout
    jmp .next
.kpress:
    mov rdi, rsp
    xor esi, esi
    call XLookupKeysym PLT
    mov edi, eax
    call ev_key_down
    jmp .next
.krelease:
    mov rdi, rsp
    xor esi, esi
    call XLookupKeysym PLT
    mov edi, eax
    call ev_key_up
    jmp .next
.button:
    mov edi, [rsp + 84]
    mov esi, [rsp + 64]
    mov edx, [rsp + 68]
    call ev_button_down
    jmp .next
.brelease:
    mov edi, [rsp + 84]
    call ev_button_up
    jmp .next
.motion:
    mov edi, [rsp + 64]
    mov esi, [rsp + 68]
    call ev_motion
    jmp .next
.configure:
    mov edi, [rsp + 56]
    mov esi, [rsp + 60]
    call ev_resize
    jmp .next
.client:
    mov rax, [rsp + 56]
    cmp rax, [wm_delete]
    jne .next
    call ev_close
    jmp .next
.focusout:
    call ev_focus_out
    jmp .next
.done:
    LEAVE_FN
%endif
%endif

; ------------------------------------------------------------- streaming --
; FLOORF dst32, src xmm, tmp xmm
%macro FLOORF 3
    cvttss2si %1, %2
    cvtsi2ss %3, %1
    comiss %3, %2
    jbe %%ok
    dec %1
%%ok:
%endmacro

; eax = mesh detail wanted at chunk offset (edi, esi): 1, 2 or 4
; (COARSE TERRAIN FROM = L: 2x beyond L chunks, 4x beyond 2L, 0 = off)
want_scale:
    mov eax, 1
    mov ecx, [set_lod]
    test ecx, ecx
    jz .out
    imul edi, edi
    imul esi, esi
    add edi, esi                    ; d^2
    mov edx, ecx
    imul edx, ecx                   ; L^2
    cmp edi, edx
    jbe .out
    mov eax, 2
    shl edx, 2                      ; (2L)^2
    cmp edi, edx
    jbe .out
    mov eax, 4
.out:
    ret

; locals: [0] t0 (double), [8] count, [12] wanted scale
update_chunks:
    ENTER_FN 32
    movss xmm0, [pos]
    FLOORF eax, xmm0, xmm1
    sar eax, 4
    mov [cur_pcx], eax
    movss xmm0, [pos + 8]
    FLOORF eax, xmm0, xmm1
    sar eax, 4
    mov [cur_pcz], eax
    cmp dword [threaded], 0
    je .gen
    call worker_collect
.gen:
    call now
    movsd [rsp], xmm0
    xor ebx, ebx
.g:
    cmp ebx, [spiral_n]
    jae .mesh
    mov r12d, [cur_pcx]
    lea rax, [spiral]
    add r12d, [rax + rbx*8]
    mov r13d, [cur_pcz]
    add r13d, [rax + rbx*8 + 4]
    mov edi, r12d
    mov esi, r13d
    call world_find
    test eax, eax
    jns .gnext
    mov edi, r12d
    mov esi, r13d
    call world_slot_of
    mov r14d, eax
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    cmp byte [rcx + rax + CI_STATE], ST_PENDING
    je .gnext                       ; slot busy in the worker
    ; the chunk leaving this slot keeps its changes on disk
    cmp byte [rcx + rax + CI_STATE], ST_READY
    jne .free_slot
    cmp byte [rcx + rax + CI_MODIFIED], 0
    je .free_slot
    mov edi, r14d
    call save_chunk
.free_slot:
    mov edi, r12d
    mov esi, r13d
    cmp dword [threaded], 0
    je .sync
    call worker_submit
    test eax, eax
    jz .mesh                        ; queue full
    jmp .gnext
.sync:
    mov edx, [seed]
    call world_gen_sync
    call now
    subsd xmm0, [rsp]
    cvtsd2ss xmm0, xmm0
    comiss xmm0, [f_genbudget]
    ja .mesh
.gnext:
    inc ebx
    jmp .g

.mesh:
    ; relight chunks whose light went stale (edits), nearest first
    call now
    movsd [rsp], xmm0
    xor ebx, ebx
.l:
    cmp ebx, [spiral_n]
    jae .lit
    lea rax, [spiral]
    mov edi, [cur_pcx]
    add edi, [rax + rbx*8]
    mov esi, [cur_pcz]
    add esi, [rax + rbx*8 + 4]
    call world_find
    test eax, eax
    js .lnext
    mov r14d, eax
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    cmp byte [rcx + rax + CI_LIGHTDIRTY], 0
    je .lnext
    mov byte [rcx + rax + CI_LIGHTDIRTY], 0
    mov byte [rcx + rax + CI_DIRTY], 1
    mov edi, r14d
    mov esi, 1                      ; with light from the neighbours
    call light_chunk
    call now
    subsd xmm0, [rsp]
    cvtsd2ss xmm0, xmm0
    comiss xmm0, [f_lightbudget]
    ja .lit
.lnext:
    inc ebx
    jmp .l
.lit:
    call now
    movsd [rsp], xmm0
    mov dword [rsp + 8], 0
    xor ebx, ebx
.m:
    cmp ebx, [spiral_n]
    jae .out
    lea rax, [spiral]
    mov r12d, [rax + rbx*8]         ; dx
    mov r13d, [rax + rbx*8 + 4]     ; dz
    mov edi, [cur_pcx]
    add edi, r12d
    mov esi, [cur_pcz]
    add esi, r13d
    call world_find
    test eax, eax
    js .mnext
    mov r14d, eax
    mov edi, r12d
    mov esi, r13d
    call want_scale
    mov [rsp + 12], eax
    mov ecx, r14d
    shl rcx, CI_SHIFT
    lea rdx, [chunk_info]
    add rdx, rcx
    cmp byte [rdx + CI_LIGHTDIRTY], 0
    jne .mnext                      ; wait for the new light
    cmp byte [rdx + CI_DIRTY], 0
    jne .need
    cmp byte [rdx + CI_MESHED], 0
    je .mnext
    cmp [rdx + CI_SCALE], al
    je .mnext
.need:
    ; neighbours must be loaded unless they are outside the view range
%macro NBREADY 2
    lea edi, [r12 + %1]
    lea esi, [r13 + %2]
    call nb_ready
    test eax, eax
    jz .mnext
%endmacro
    NBREADY -1, 0
    NBREADY 1, 0
    NBREADY 0, -1
    NBREADY 0, 1
    mov edi, r14d
    mov esi, [rsp + 12]
    call mesh_chunk
    mov edi, r14d
    call upload_slot
    mov eax, r14d
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    mov byte [rcx + rax + CI_DIRTY], 0
    mov byte [rcx + rax + CI_MESHED], 1
    inc dword [rsp + 8]
    cmp dword [rsp + 8], 2
    jb .mnext
    call now
    subsd xmm0, [rsp]
    cvtsd2ss xmm0, xmm0
    comiss xmm0, [f_meshbudget]
    ja .out
.mnext:
    inc ebx
    jmp .m
.out:
    call horizon_update
    LEAVE_FN

; int nb_ready(int dx, int dz) - offset from the player chunk
nb_ready:
    sub rsp, 8
    mov eax, edi
    imul eax, eax
    mov ecx, esi
    imul ecx, ecx
    add eax, ecx
    cmp eax, [spiral_r2]
    ja .yes
    add edi, [cur_pcx]
    add esi, [cur_pcz]
    call world_find
    not eax
    shr eax, 31                     ; 1 if slot >= 0
    add rsp, 8
    ret
.yes:
    mov eax, 1
    add rsp, 8
    ret

NOEXECSTACK
