; settings.asm - user settings: table, config file, change flags.
;
; Settings live in $XDG_CONFIG_HOME/voxasm.conf (or ~/.config/voxasm.conf),
; one "name value" pair per line. Because the path comes from $HOME, an
; AppImage portable home folder (VoxASM-x86_64.AppImage.home) keeps them
; next to the AppImage.

%include "common.inc"

global settings_table, settings_count, settings_load, settings_save, rend_loaded
global binds, bind_fwd, bind_back, bind_left, bind_right, bind_jump, bind_down
global bind_sprint, bind_inv, bind_drop, bind_fly, bind_wait, bind_labels
global key_name, binds_reset, controls_key
global settings_change, settings_label, settings_pending
global set_range, set_lod, set_renderer, set_textures, set_leaves
global set_clouds, set_fog, set_vsync, set_fov, set_mouse, set_window
global set_showfps, set_horizon, set_daycycle, set_difficulty

extern getenv, snprintf, fopen, fclose, fprintf, fscanf, strcmp, mkdir, state

; what a change needs (settings_pending bits)
APPLY_SPIRAL    equ 1
APPLY_ATLAS     equ 2
APPLY_REMESH    equ 4               ; rebuild every mesh (same renderer)
APPLY_RENDERER  equ 8               ; drop every mesh and re-upload
APPLY_VSYNC     equ 16
APPLY_WINDOW    equ 32
APPLY_LEAVES    equ 64
APPLY_HORIZON   equ 128
SHOW_OFF_AT_0   equ 0x100           ; numeric value 0 shows as OFF

; table entry
SE_NAME     equ 0                   ; config key
SE_LABEL    equ 8                   ; text in the menu
SE_VALUE    equ 16                  ; -> int
SE_NAMES    equ 24                  ; -> array of value names, or 0
SE_MIN      equ 32
SE_MAX      equ 36
SE_STEP     equ 40
SE_FLAGS    equ 44
SE_SIZE     equ 48
NUM_SETTINGS equ 15

%macro SETTING 8                    ; key, label, var, names, min, max, step, flags
    dq %1, %2, %3, %4
    dd %5, %6, %7, %8
%endmacro

section .data
set_range:      dd 6
set_lod:        dd 0
set_horizon:    dd 1
set_daycycle:   dd 1
set_renderer:   dd 0
rend_loaded:    dd 0                ; 1 = renderer came from the file
set_textures:   dd 0
set_leaves:     dd 0
set_clouds:     dd 1
set_fog:        dd 1
set_vsync:      dd 1
set_fov:        dd 70
set_mouse:      dd 5
set_window:     dd 2
set_showfps:    dd 1
set_difficulty: dd 1                ; 0 peaceful (no zombies), 1 normal
settings_pending: dd 0
; key bindings: key index (letters and symbols by their lower-case
; character, other keys 256 + the low byte of their X keysym)
align 4
binds:
bind_fwd:       dd 'w'
bind_back:      dd 's'
bind_left:      dd 'a'
bind_right:     dd 'd'
bind_jump:      dd ' '
bind_down:      dd 256 + 0xe1       ; left shift
bind_sprint:    dd 256 + 0xe3       ; left ctrl
bind_inv:       dd 'e'
bind_drop:      dd 'q'
bind_fly:       dd 'f'
NUM_BINDS       equ ($ - binds) / 4
bind_wait:      dd -1               ; action waiting for its new key
settings_count: dd NUM_SETTINGS

align 8
bind_cfg:   dq kb_fwd, kb_back, kb_left, kb_right, kb_jump, kb_down, kb_sprint
            dq kb_inv, kb_drop, kb_fly
bind_labels: dq bl_fwd, bl_back, bl_left, bl_right, bl_jump, bl_down, bl_sprint
            dq bl_inv, bl_drop, bl_fly
settings_table:
    SETTING k_range,  l_range,  set_range,    0,         2, MAX_RANGE, 1, APPLY_SPIRAL
    SETTING k_horiz,  l_horiz,  set_horizon,  n_horiz,   0, 3,   1,  APPLY_HORIZON
    SETTING k_lod,    l_lod,    set_lod,      0,         0, MAX_RANGE, 1, SHOW_OFF_AT_0
    SETTING k_rend,   l_rend,   set_renderer, n_rend,    0, 2,   1,  APPLY_RENDERER
    SETTING k_tex,    l_tex,    set_textures, n_tex,     0, 3,   1,  APPLY_ATLAS
    SETTING k_leaves, l_leaves, set_leaves,   n_leaves,  0, 1,   1,  APPLY_ATLAS | APPLY_LEAVES
    SETTING k_clouds, l_clouds, set_clouds,   n_onoff,   0, 1,   1,  0
    SETTING k_fog,    l_fog,    set_fog,      n_onoff,   0, 1,   1,  0
    SETTING k_vsync,  l_vsync,  set_vsync,    n_onoff,   0, 1,   1,  APPLY_VSYNC
    SETTING k_fov,    l_fov,    set_fov,      0,         50, 110, 10, 0
    SETTING k_mouse,  l_mouse,  set_mouse,    0,         1, 10,  1,  0
    SETTING k_window, l_window, set_window,   n_window,  0, 3,   1,  APPLY_WINDOW
    SETTING k_fps,    l_fps,    set_showfps,  n_onoff,   0, 1,   1,  0
    SETTING k_day,    l_day,    set_daycycle, n_onoff,   0, 1,   1,  0
    SETTING k_diff,   l_diff,   set_difficulty, n_diff,  0, 1,   1,  0

n_rend:     dq s_vbo, s_dlist, s_varr
n_tex:      dq s_t16, s_t8, s_t4, s_tflat
n_leaves:   dq s_fancy, s_opaque
n_onoff:    dq s_off, s_on
n_window:   dq s_w0, s_w1, s_w2, s_w3
n_horiz:    dq s_off, s_h32, s_h48, s_h64
n_diff:     dq s_peaceful, s_normal

section .rodata
k_range:    db "range", 0
k_lod:      db "coarse_from", 0
k_rend:     db "renderer", 0
k_tex:      db "textures", 0
k_leaves:   db "leaves", 0
k_clouds:   db "clouds", 0
k_fog:      db "fog", 0
k_vsync:    db "vsync", 0
k_fov:      db "fov", 0
k_mouse:    db "mouse", 0
k_window:   db "window", 0
k_fps:      db "show_fps", 0
k_horiz:    db "horizon", 0
k_day:      db "day_cycle", 0
k_diff:     db "difficulty", 0
l_diff:     db "DIFFICULTY", 0
s_peaceful: db "PEACEFUL", 0
s_normal:   db "NORMAL", 0
l_range:    db "REAL CHUNKS", 0
l_lod:      db "COARSE TERRAIN FROM", 0
l_rend:     db "RENDERER", 0
l_tex:      db "TEXTURES", 0
l_leaves:   db "LEAVES", 0
l_clouds:   db "CLOUDS", 0
l_fog:      db "FOG", 0
l_vsync:    db "VSYNC", 0
l_fov:      db "FIELD OF VIEW", 0
l_mouse:    db "MOUSE SPEED", 0
%ifdef VOXASM_WIN
l_window:   db "RESOLUTION", 0           ; (Windows: drawn at, then stretched)
%else
l_window:   db "WINDOW", 0
%endif
l_fps:      db "SHOW FPS", 0
l_horiz:    db "HORIZON", 0
l_day:      db "DAY/NIGHT CYCLE", 0
s_h32:      db "32 CHUNKS", 0
s_h48:      db "48 CHUNKS", 0
s_h64:      db "64 CHUNKS", 0
s_vbo:      db "VBO (GL 1.5)", 0
s_dlist:    db "DISPLAY LISTS (GL 1.0)", 0
s_varr:     db "VERTEX ARRAYS (GL 1.1)", 0
s_t16:      db "16 PX", 0
s_t8:       db "8 PX", 0
s_t4:       db "4 PX", 0
s_tflat:    db "FLAT COLOUR", 0
s_fancy:    db "FANCY", 0
s_opaque:   db "OPAQUE (FAST)", 0
s_off:      db "OFF", 0
s_on:       db "ON", 0
s_w0:       db "640 X 400", 0
s_w1:       db "800 X 500", 0
s_w2:       db "1024 X 640", 0
s_w3:       db "1280 X 800", 0
s_fmt_str:  db "%s: %s", 0
s_fmt_int:  db "%s: %d", 0
s_fmt_chk:  db "%s: %d CHUNKS", 0
s_xdg:      db "XDG_CONFIG_HOME", 0
s_home:     db "HOME", 0
s_cfgdir:   db "%s/.config", 0
s_cfgfile:  db "%s/voxasm.conf", 0
s_r:        db "r", 0
s_w:        db "w", 0
s_scan:     db "%63s %d", 0
bind_default: dd 'w', 's', 'a', 'd', ' ', 256 + 0xe1, 256 + 0xe3, 'e', 'q', 'f'
kb_fwd:     db "key_forward", 0
kb_back:    db "key_back", 0
kb_left:    db "key_left", 0
kb_right:   db "key_right", 0
kb_jump:    db "key_jump", 0
kb_down:    db "key_fly_down", 0
kb_sprint:  db "key_sprint", 0
kb_inv:     db "key_inventory", 0
kb_drop:    db "key_drop", 0
kb_fly:     db "key_fly", 0
bl_fwd:     db "FORWARD", 0
bl_back:    db "BACK", 0
bl_left:    db "LEFT", 0
bl_right:   db "RIGHT", 0
bl_jump:    db "JUMP / SWIM UP", 0
bl_down:    db "FLY DOWN", 0
bl_sprint:  db "SPRINT", 0
bl_inv:     db "INVENTORY", 0
bl_drop:    db "DROP ITEM", 0
bl_fly:     db "TOGGLE FLY", 0
kn_space:   db "SPACE", 0
kn_ffmt:    db "F%d", 0
kn_nfmt:    db "KEY %d", 0
; names of keys that are not a printable character: code, name (16 bytes)
%macro KN 2
    dw %1
    db %2
    times 14 - %strlen(%2) db 0
%endmacro
kn_table:
    KN 256 + 0xe1, "LEFT SHIFT"
    KN 256 + 0xe2, "RIGHT SHIFT"
    KN 256 + 0xe3, "LEFT CTRL"
    KN 256 + 0xe4, "RIGHT CTRL"
    KN 256 + 0xe9, "LEFT ALT"
    KN 256 + 0xea, "RIGHT ALT"
    KN 256 + 0xe5, "CAPS LOCK"
    KN 256 + 0x09, "TAB"
    KN 256 + 0x0d, "ENTER"
    KN 256 + 0x08, "BACKSPACE"
    KN 256 + 0xff, "DELETE"
    KN 256 + 0x63, "INSERT"
    KN 256 + 0x50, "HOME"
    KN 256 + 0x57, "END"
    KN 256 + 0x55, "PAGE UP"
    KN 256 + 0x56, "PAGE DOWN"
    KN 256 + 0x51, "LEFT ARROW"
    KN 256 + 0x52, "UP ARROW"
    KN 256 + 0x53, "RIGHT ARROW"
    KN 256 + 0x54, "DOWN ARROW"
    KN 256 + 0x8d, "KEYPAD ENTER"
    dw 0
s_print:    db "%s %d", 10, 0

section .bss
cfg_dir:    resb 512
cfg_path:   resb 512
key_buf:    resb 64
val_buf:    resd 1

section .text

; build cfg_path; eax = 0 when there is no home directory
config_path:
    sub rsp, 8
    lea rdi, [s_xdg]
    call getenv PLT
    test rax, rax
    jz .home
    cmp byte [rax], 0
    je .home
    mov rcx, rax
    lea rdi, [cfg_dir]
    mov esi, 512
    lea rdx, [s_fmt_dir_copy]
    xor eax, eax
    call snprintf PLT
    jmp .file
.home:
    lea rdi, [s_home]
    call getenv PLT
    test rax, rax
    jz .none
    mov rcx, rax
    lea rdi, [cfg_dir]
    mov esi, 512
    lea rdx, [s_cfgdir]
    xor eax, eax
    call snprintf PLT
.file:
    lea rdi, [cfg_dir]
    mov esi, 0o755
    call mkdir PLT                  ; fine if it already exists
    lea rdi, [cfg_path]
    mov esi, 512
    lea rdx, [s_cfgfile]
    lea rcx, [cfg_dir]
    xor eax, eax
    call snprintf PLT
    mov eax, 1
    add rsp, 8
    ret
.none:
    xor eax, eax
    add rsp, 8
    ret

; void settings_load(void)
settings_load:
    ENTER_FN 0
    call config_path
    test eax, eax
    jz .out
    lea rdi, [cfg_path]
    lea rsi, [s_r]
    call fopen PLT
    test rax, rax
    jz .out
    mov r12, rax
.line:
    mov rdi, r12
    lea rsi, [s_scan]
    lea rdx, [key_buf]
    lea rcx, [val_buf]
    xor eax, eax
    call fscanf PLT
    cmp eax, 2
    jne .close
    lea rbx, [settings_table]
    xor r13d, r13d
.find:
    mov rdi, [rbx + SE_NAME]
    lea rsi, [key_buf]
    call strcmp PLT
    test eax, eax
    jz .found
    add rbx, SE_SIZE
    inc r13d
    cmp r13d, NUM_SETTINGS
    jb .find
    ; not a setting: a key binding?
    xor r13d, r13d
.findkey:
    lea rax, [bind_cfg]
    mov rdi, [rax + r13*8]
    lea rsi, [key_buf]
    call strcmp PLT
    test eax, eax
    jz .foundkey
    inc r13d
    cmp r13d, NUM_BINDS
    jb .findkey
    jmp .line
.foundkey:
    mov eax, [val_buf]
    cmp eax, 512
    jae .line
    lea rcx, [binds]
    mov [rcx + r13*4], eax
    jmp .line
.found:
    mov eax, [val_buf]
    cmp eax, [rbx + SE_MIN]
    jl .line
    cmp eax, [rbx + SE_MAX]
    jg .line
    mov rcx, [rbx + SE_VALUE]
    mov [rcx], eax
    lea rdx, [set_renderer]
    cmp rcx, rdx
    jne .line
    mov dword [rend_loaded], 1      ; the player picked a renderer
    jmp .line
.close:
    mov rdi, r12
    call fclose PLT
.out:
    LEAVE_FN

; void settings_save(void)
settings_save:
    ENTER_FN 0
    call config_path
    test eax, eax
    jz .out
    lea rdi, [cfg_path]
    lea rsi, [s_w]
    call fopen PLT
    test rax, rax
    jz .out
    mov r12, rax
    lea rbx, [settings_table]
    xor r13d, r13d
.e:
    mov rdi, r12
    lea rsi, [s_print]
    mov rdx, [rbx + SE_NAME]
    mov rcx, [rbx + SE_VALUE]
    mov ecx, [rcx]
    xor eax, eax
    call fprintf PLT
    add rbx, SE_SIZE
    inc r13d
    cmp r13d, NUM_SETTINGS
    jb .e
    xor r13d, r13d
.ek:
    mov rdi, r12
    lea rsi, [s_print]
    lea rax, [bind_cfg]
    mov rdx, [rax + r13*8]
    lea rax, [binds]
    mov ecx, [rax + r13*4]
    xor eax, eax
    call fprintf PLT
    inc r13d
    cmp r13d, NUM_BINDS
    jb .ek
    mov rdi, r12
    call fclose PLT
.out:
    LEAVE_FN

; void settings_change(int index, int direction) - step a setting up (+1)
; or down (-1), wrapping; records what needs applying and saves the file
settings_change:
    ENTER_FN 0
    imul eax, edi, SE_SIZE
    lea rbx, [settings_table]
    add rbx, rax
    mov rcx, [rbx + SE_VALUE]
    mov eax, [rcx]
    mov edx, [rbx + SE_STEP]
    test esi, esi
    jns .up
    sub eax, edx
    cmp eax, [rbx + SE_MIN]
    jge .set
    mov eax, [rbx + SE_MAX]
    jmp .set
.up:
    add eax, edx
    cmp eax, [rbx + SE_MAX]
    jle .set
    mov eax, [rbx + SE_MIN]
.set:
    mov [rcx], eax
    mov eax, [rbx + SE_FLAGS]
    and eax, 0xff
    or [settings_pending], eax
    call settings_save
    LEAVE_FN

; void settings_label(int index, char *out, int size) - "LABEL: VALUE"
settings_label:
    ENTER_FN 0
    imul eax, edi, SE_SIZE
    lea rbx, [settings_table]
    add rbx, rax
    mov rdi, rsi
    mov esi, edx
    mov rcx, [rbx + SE_LABEL]
    mov rax, [rbx + SE_VALUE]
    mov r8d, [rax]
    mov rax, [rbx + SE_NAMES]
    test rax, rax
    jz .num
    sub r8d, [rbx + SE_MIN]
    mov r8, [rax + r8*8]
    lea rdx, [s_fmt_str]
    jmp .print
.num:
    test r8d, r8d
    jnz .n1
    test dword [rbx + SE_FLAGS], SHOW_OFF_AT_0
    jz .n1
    lea r8, [s_off]
    lea rdx, [s_fmt_str]
    jmp .print
.n1:
    lea rdx, [s_fmt_int]
    ; the two distance settings read better with a unit
    lea rax, [settings_table]
    cmp rbx, rax
    je .chunks
    lea rax, [settings_table + 2 * SE_SIZE]
    cmp rbx, rax
    jne .print
.chunks:
    lea rdx, [s_fmt_chk]
.print:
    xor eax, eax
    call snprintf PLT
    LEAVE_FN

section .rodata
s_fmt_dir_copy: db "%s", 0

section .text

; ---------------------------------------------------------------------------
; key bindings

; void key_name(int key, char *out, int size) - "W", "SPACE", "LEFT SHIFT"
key_name:
    ENTER_FN 0
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    cmp ebx, ' '
    jne .print
    lea rsi, [kn_space]
    jmp .copy
.print:
    cmp ebx, 0x21
    jb .table
    cmp ebx, 0x7e
    ja .table
    mov eax, ebx
    cmp eax, 'a'
    jb .ch
    cmp eax, 'z'
    ja .ch
    sub eax, 'a' - 'A'
.ch:
    mov [r12], al
    mov byte [r12 + 1], 0
    jmp .out
.table:
    lea rsi, [kn_table]
.t:
    movzx eax, word [rsi]
    test eax, eax
    jz .fkey
    cmp eax, ebx
    je .found
    add rsi, 16
    jmp .t
.found:
    add rsi, 2
    jmp .copy
.fkey:
    cmp ebx, 256 + 0xbe             ; F1 .. F12
    jb .num
    cmp ebx, 256 + 0xc9
    ja .num
    lea ecx, [rbx - 256 - 0xbe + 1]
    mov rdi, r12
    mov esi, r13d
    lea rdx, [kn_ffmt]
    xor eax, eax
    call snprintf PLT
    jmp .out
.num:
    mov rdi, r12
    mov esi, r13d
    lea rdx, [kn_nfmt]
    mov ecx, ebx
    xor eax, eax
    call snprintf PLT
    jmp .out
.copy:
    xor ecx, ecx
.cl:
    mov al, [rsi + rcx]
    mov [r12 + rcx], al
    test al, al
    jz .out
    inc ecx
    jmp .cl
.out:
    LEAVE_FN

; void binds_reset(void) - the default keys, saved
binds_reset:
    lea rsi, [bind_default]
    lea rdi, [binds]
    mov ecx, NUM_BINDS
    rep movsd
    mov dword [bind_wait], -1
    jmp settings_save

; void controls_key(int key) - a key pressed on the controls screen: the
; new key of the action waiting for one (an action already on that key
; takes the old one); Esc cancels, or leaves the screen
controls_key:
    cmp edi, 256 + 0x1b             ; Esc
    jne .key
    cmp dword [bind_wait], 0
    jl .leave
    mov dword [bind_wait], -1
    ret
.leave:
    mov dword [state], GS_SETTINGS
    ret
.key:
    mov eax, [bind_wait]
    test eax, eax
    js .out
    lea rcx, [binds]
    mov edx, [rcx + rax*4]          ; its old key
    xor r8d, r8d
.swap:
    cmp [rcx + r8*4], edi
    jne .sn
    mov [rcx + r8*4], edx
.sn:
    inc r8d
    cmp r8d, NUM_BINDS
    jb .swap
    mov [rcx + rax*4], edi
    mov dword [bind_wait], -1
    jmp settings_save
.out:
    ret

NOEXECSTACK
