; ui.asm - menus: home screen, new world, settings, pause, death.
;
; Immediate-mode UI: every frame each screen draws its buttons, and a
; button reports the mouse click that landed on it this frame (1 = left,
; 3 = right). Settings step forward on left click and back on right click.

%include "common.inc"

global ui_frame, ui_button, delete_pending

extern state, settings_return, mouse_x, mouse_y, mouse_click, running
extern world_active, seed, win_w, win_h
extern start_world, end_world, resume_game, respawn
extern hud_begin, hud_rect, hud_text, hud_text_center, hud_tile, text_width
extern settings_label, settings_change, settings_count
extern snprintf, mapgen_flat, worlds_scan, world_info, load_world
extern new_world_slot
extern binds, bind_wait, bind_labels, key_name, binds_reset, world_delete

BTN_H       equ 38
BTN_GAP     equ 46

section .rodata
align 4
f_half:     dd 0.5
f_two:      dd 2.0
f_three:    dd 3.0
f_four:     dd 4.0
f_eight:    dd 8.0
f_sixteen:  dd 16.0
f_64:       dd 64.0
f_200:      dd 200.0
f_400:      dd 400.0
f_300:      dd 300.0
f_305:      dd 305.0
f_310:      dd 310.0
f_btn_h:    dd 38.0
f_btn_gap:  dd 46.0
f_set_h:    dd 30.0
f_set_gap:  dd 34.0
f_y_title:  dd 0.14
f_y_sub:    dd 0.30
f_y_menu:   dd 0.40
f_24:       dd 24.0
f_60:       dd 60.0
f_hint_y:   dd 330.0
f_done_y:   dd 352.0
f_1_5:      dd 1.5
f_5:        dd 5.0
f_del_x:    dd 264.0                ; DEL button: right of the 520-wide row
f_del_w:    dd 52.0
f_c_hint1:  dd 262.0
f_c_hint2:  dd 286.0

s_title:    db "VOXASM", 0
s_sub:      db "LUANTI V7 TERRAIN IN X86-64 ASSEMBLY", 0
s_play:     db "PLAY", 0
s_settings: db "SETTINGS", 0
s_quit:     db "QUIT", 0
s_newworld: db "NEW WORLD", 0
s_survival: db "SURVIVAL", 0
s_creative: db "CREATIVE", 0
s_seedfmt:  db "SEED %d  (CLICK FOR NEW)", 0
s_back:     db "BACK", 0
s_superflat: db "CREATIVE: SUPER FLAT", 0
s_controls: db "CONTROLS", 0
s_reset:    db "RESET DEFAULTS", 0
s_bindfmt:  db "%s: %s", 0
s_presskey: db "PRESS A KEY", 0
s_chint1:   db "CLICK AN ACTION, THEN PRESS ITS NEW KEY  (ESC CANCELS)", 0
s_chint2:   db "ALWAYS: MOUSE DIG / PLACE, 1-9 OR WHEEL HOTBAR, ESC PAUSE", 0
s_done:     db "DONE", 0
s_hint:     db "LEFT CLICK: NEXT VALUE    RIGHT CLICK: PREVIOUS", 0
s_paused:   db "PAUSED", 0
s_resume:   db "RESUME", 0
s_mainmenu: db "MAIN MENU", 0
s_help1:    db "WASD MOVE  SPACE JUMP  CTRL SPRINT  F FLY (CREATIVE)", 0
s_help2:    db "HOLD LMB DIG  RMB PLACE / USE  1-9 / WHEEL SELECT  Q DROP", 0
s_help3:    db "E INVENTORY: 2X2 CRAFTING  -  RMB A CRAFTING TABLE OR FURNACE TO USE IT", 0
s_died:     db "YOU DIED", 0
s_worlds:   db "SELECT WORLD", 0
s_wfmt:     db "WORLD %d: %s %s  SEED %d", 0
s_wempty:   db "WORLD %d: EMPTY - NEW WORLD", 0
s_msurv:    db "SURVIVAL", 0
s_mcrea:    db "CREATIVE", 0
s_tnorm:    db "", 0
s_tflat:    db "FLAT", 0
s_saved:    db "WORLDS ARE SAVED AUTOMATICALLY", 0
f_500:      dd 520.0
f_y_list:   dd 0.26
s_respawn:  db "RESPAWN", 0
s_del:      db "DEL", 0
s_delq:     db "DELETE WORLD %d?", 0
s_delsub:   db "IT CANNOT BE UNDONE", 0
s_delyes:   db "YES, DELETE IT", 0
s_delno:    db "NO, KEEP IT", 0

section .bss
label_buf:  resb 96
key_buf:    resb 32
delete_pending: resd 1              ; world asked to be deleted (0 = none)

section .text

; int ui_button(x, y, w, h in xmm0..3, rdi label)
; locals: [0] x, [4] y, [8] w, [12] h, [16] hover, [20] text scale, [24] text x
ui_button:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    mov r12, rdi
    ; hover test
    xor ebx, ebx
    cvtsi2ss xmm4, dword [mouse_x]
    cvtsi2ss xmm5, dword [mouse_y]
    comiss xmm4, xmm0
    jb .nohover
    comiss xmm5, xmm1
    jb .nohover
    addss xmm0, xmm2
    comiss xmm4, xmm0
    ja .nohover
    addss xmm1, xmm3
    comiss xmm5, xmm1
    ja .nohover
    mov ebx, 1
.nohover:
    ; frame and face
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, [rsp]
    addss xmm2, [rsp + 8]
    movss xmm3, [rsp + 4]
    addss xmm3, [rsp + 12]
    mov edi, 0xf0101010
    call hud_rect
    movss xmm0, [rsp]
    addss xmm0, [f_two]
    movss xmm1, [rsp + 4]
    addss xmm1, [f_two]
    movss xmm2, [rsp]
    addss xmm2, [rsp + 8]
    subss xmm2, [f_two]
    movss xmm3, [rsp + 4]
    addss xmm3, [rsp + 12]
    subss xmm3, [f_two]
    mov edi, 0xe0505050
    test ebx, ebx
    jz .face
    mov edi, 0xf0a07850
.face:
    call hud_rect
    ; centred label, smaller when it would not fit
    movss xmm0, [f_two]
    movss [rsp + 20], xmm0          ; scale
    mov rdi, r12
    call text_width
    movss xmm1, [rsp + 8]
    subss xmm1, [f_eight]
    comiss xmm0, xmm1
    jbe .fits
    movss xmm0, [f_1_5]
    movss [rsp + 20], xmm0
    mov rdi, r12
    call text_width
.fits:
    movss xmm1, [rsp + 8]
    subss xmm1, xmm0
    mulss xmm1, [f_half]
    addss xmm1, [rsp]
    movss [rsp + 24], xmm1
    movss xmm2, [rsp + 20]
    mulss xmm2, [f_eight]           ; text height
    movss xmm1, [rsp + 12]
    subss xmm1, xmm2
    mulss xmm1, [f_half]
    addss xmm1, [rsp + 4]
    movss xmm0, [rsp + 24]
    movss xmm2, [rsp + 20]
    mov rdi, r12
    mov esi, 0xffffffff
    call hud_text
    ; click
    xor eax, eax
    test ebx, ebx
    jz .out
    mov eax, [mouse_click]
    test eax, eax
    jz .out
    mov dword [mouse_click], 0
.out:
    LEAVE_FN

; button centred horizontally: xmm1 = y, xmm2 = width, rdi label
; -> eax click
center_button:
    sub rsp, 8
    cvtsi2ss xmm0, dword [win_w]
    subss xmm0, xmm2
    mulss xmm0, [f_half]
    movss xmm3, [f_btn_h]
    call ui_button
    add rsp, 8
    ret

; y of menu row eax (0, 1, ...) below the y fraction in xmm0 -> xmm1
row_y:
    cvtsi2ss xmm1, dword [win_h]
    mulss xmm1, xmm0
    cvtsi2ss xmm2, eax
    mulss xmm2, [f_btn_gap]
    addss xmm1, xmm2
    ret

; full-screen backdrop: dirt tiles when no world is loaded, else a dim
; overlay of colour edi over the world
backdrop:
    ENTER_FN 16
    mov r12d, edi
    cmp dword [world_active], 0
    jne .overlay
    xor ebx, ebx                    ; y
.ty:
    cmp ebx, [win_h]
    jge .tdone
    xor r13d, r13d                  ; x
.tx:
    cmp r13d, [win_w]
    jge .tyn
    cvtsi2ss xmm0, r13d
    cvtsi2ss xmm1, ebx
    movss xmm2, [f_64]
    mov edi, 1                      ; dirt
    call hud_tile
    add r13d, 64
    jmp .tx
.tyn:
    add ebx, 64
    jmp .ty
.tdone:
    mov r12d, 0xa0000000
.overlay:
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [win_w]
    cvtsi2ss xmm3, dword [win_h]
    mov edi, r12d
    call hud_rect
    LEAVE_FN

; title text at fraction xmm0 of the height, scale xmm1, rdi text, esi colour
title_at:
    sub rsp, 8
    cvtsi2ss xmm2, dword [win_h]
    mulss xmm0, xmm2
    call hud_text_center
    add rsp, 8
    ret

; ---------------------------------------------------------------------------
; void ui_frame(void) - draw and run the current menu screen
ui_frame:
    ENTER_FN 16
    call hud_begin
    mov eax, [state]
    cmp eax, GS_MAIN
    je scr_main
    cmp eax, GS_PLAY
    je scr_play
    cmp eax, GS_SETTINGS
    je scr_settings
    cmp eax, GS_PAUSE
    je scr_pause
    cmp eax, GS_DEAD
    je scr_dead
    cmp eax, GS_WORLDS
    je scr_worlds
    cmp eax, GS_CONTROLS
    je scr_controls
ui_done:
    LEAVE_FN

scr_main:
    mov edi, 0x60000000
    call backdrop
    movss xmm0, [f_y_title]
    movss xmm1, [f_eight]
    lea rdi, [s_title]
    mov esi, 0xffffffff
    call title_at
    movss xmm0, [f_y_sub]
    movss xmm1, [f_two]
    lea rdi, [s_sub]
    mov esi, 0xffc8c8c8
    call title_at
    movss xmm0, [f_y_menu]
    xor eax, eax
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_play]
    call center_button
    test eax, eax
    jz .m1
    call worlds_scan
    mov dword [state], GS_WORLDS
.m1:
    movss xmm0, [f_y_menu]
    mov eax, 1
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_settings]
    call center_button
    test eax, eax
    jz .m2
    mov dword [settings_return], GS_MAIN
    mov dword [state], GS_SETTINGS
.m2:
    movss xmm0, [f_y_menu]
    mov eax, 2
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_quit]
    call center_button
    test eax, eax
    jz ui_done
    mov dword [running], 0
    jmp ui_done

scr_play:
    mov edi, 0x60000000
    call backdrop
    movss xmm0, [f_y_title]
    movss xmm1, [f_four]
    lea rdi, [s_newworld]
    mov esi, 0xffffffff
    call title_at
    movss xmm0, [f_y_menu]
    xor eax, eax
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_survival]
    call center_button
    test eax, eax
    jz .p1
    mov dword [mapgen_flat], 0
    xor edi, edi
    call start_world
    jmp ui_done
.p1:
    movss xmm0, [f_y_menu]
    mov eax, 1
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_creative]
    call center_button
    test eax, eax
    jz .p1f
    mov dword [mapgen_flat], 0
    mov edi, 1
    call start_world
    jmp ui_done
.p1f:
    ; super flat (bedrock, 2 dirt, grass) is for building: creative only
    movss xmm0, [f_y_menu]
    mov eax, 2
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_superflat]
    call center_button
    test eax, eax
    jz .p2
    mov dword [mapgen_flat], 1
    mov edi, 1
    call start_world
    jmp ui_done
.p2:
    lea rdi, [label_buf]
    mov esi, 96
    lea rdx, [s_seedfmt]
    mov ecx, [seed]
    xor eax, eax
    call snprintf PLT
    movss xmm0, [f_y_menu]
    mov eax, 3
    call row_y
    movss xmm2, [f_400]
    lea rdi, [label_buf]
    call center_button
    test eax, eax
    jz .p3
    ; new random seed from the time stamp counter
    rdtsc
    imul eax, eax, 0x2c1b3c6d
    mov ecx, eax
    shr ecx, 15
    xor eax, ecx
    and eax, 0x7fffffff
    mov [seed], eax
.p3:
    movss xmm0, [f_y_menu]
    mov eax, 4
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_back]
    call center_button
    test eax, eax
    jz ui_done
    mov dword [state], GS_WORLDS
    jmp ui_done

; the five world slots
scr_worlds:
    mov edi, 0x60000000
    call backdrop
    cmp dword [delete_pending], 0
    jne .confirm
    movss xmm0, [f_y_title]
    movss xmm1, [f_four]
    lea rdi, [s_worlds]
    mov esi, 0xffffffff
    call title_at
    xor ebx, ebx
.w:
    mov eax, ebx
    shl eax, 4
    lea r12, [world_info]
    add r12, rax
    lea rdi, [label_buf]
    mov esi, 96
    lea ecx, [rbx + 1]
    cmp dword [r12], 0
    je .empty
    lea rdx, [s_wfmt]
    lea r8, [s_msurv]
    cmp dword [r12 + 8], 0
    je .m
    lea r8, [s_mcrea]
.m:
    lea r9, [s_tnorm]
    cmp dword [r12 + 12], 0
    je .t
    lea r9, [s_tflat]
.t:
    sub rsp, 16
    movsxd rax, dword [r12 + 4]
    mov [rsp], rax
    xor eax, eax
    call snprintf PLT
    add rsp, 16
    jmp .label
.empty:
    lea rdx, [s_wempty]
    xor eax, eax
    call snprintf PLT
.label:
    movss xmm0, [f_y_list]
    mov eax, ebx
    call row_y
    movss xmm2, [f_500]
    lea rdi, [label_buf]
    call center_button
    test eax, eax
    jz .next
    lea edi, [rbx + 1]
    cmp dword [r12], 0
    je .new
    call load_world
    jmp ui_done
.new:
    mov [new_world_slot], edi
    mov dword [state], GS_PLAY
    jmp ui_done
.next:
    ; a saved world can be deleted (after asking)
    cmp dword [r12], 0
    je .nodel
    movss xmm0, [f_y_list]
    mov eax, ebx
    call row_y
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    addss xmm0, [f_del_x]
    movss xmm2, [f_del_w]
    movss xmm3, [f_btn_h]
    lea rdi, [s_del]
    call ui_button
    test eax, eax
    jz .nodel
    lea eax, [rbx + 1]
    mov [delete_pending], eax
    jmp ui_done
.nodel:
    inc ebx
    cmp ebx, 5
    jb .w
    movss xmm0, [f_y_list]
    mov eax, 5
    call row_y
    movss [rsp], xmm1
    movss xmm2, [f_400]
    lea rdi, [s_back]
    call center_button
    test eax, eax
    jz .hint
    mov dword [state], GS_MAIN
    jmp ui_done
.hint:
    movss xmm0, [rsp]
    addss xmm0, [f_60]
    movss xmm1, [f_1_5]
    lea rdi, [s_saved]
    mov esi, 0xffc8c8c8
    call hud_text_center
    jmp ui_done
.confirm:
    ; "delete world N?" - yes removes its files, no goes back
    lea rdi, [label_buf]
    mov esi, 96
    lea rdx, [s_delq]
    mov ecx, [delete_pending]
    xor eax, eax
    call snprintf PLT
    movss xmm0, [f_y_title]
    movss xmm1, [f_four]
    lea rdi, [label_buf]
    mov esi, 0xffffffff
    call title_at
    movss xmm0, [f_y_sub]
    movss xmm1, [f_two]
    lea rdi, [s_delsub]
    mov esi, 0xffc8c8c8
    call title_at
    movss xmm0, [f_y_menu]
    xor eax, eax
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_delyes]
    call center_button
    test eax, eax
    jz .keep
    mov edi, [delete_pending]
    mov dword [delete_pending], 0
    call world_delete
    jmp ui_done
.keep:
    movss xmm0, [f_y_menu]
    mov eax, 1
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_delno]
    call center_button
    test eax, eax
    jz ui_done
    mov dword [delete_pending], 0
    jmp ui_done

; two columns of settings buttons
scr_settings:
    mov edi, 0x90000000
    call backdrop
    movss xmm0, [f_24]
    movss xmm1, [f_three]
    lea rdi, [s_settings]
    mov esi, 0xffffffff
    call hud_text_center
    xor ebx, ebx
.row:
    cmp ebx, [settings_count]
    jae .rows_done
    mov edi, ebx
    lea rsi, [label_buf]
    mov edx, 96
    call settings_label
    ; column = i / 8, row = i % 8
    mov eax, ebx
    xor edx, edx
    mov ecx, 8
    div ecx
    mov r12d, eax
    mov r13d, edx
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    subss xmm0, [f_305]
    cvtsi2ss xmm1, r12d
    mulss xmm1, [f_310]
    addss xmm0, xmm1
    cvtsi2ss xmm1, r13d
    mulss xmm1, [f_set_gap]
    addss xmm1, [f_60]
    movss xmm2, [f_300]
    movss xmm3, [f_set_h]
    lea rdi, [label_buf]
    call ui_button
    test eax, eax
    jz .next
    mov esi, 1
    cmp eax, 1
    je .chg
    mov esi, -1
.chg:
    mov edi, ebx
    call settings_change
.next:
    inc ebx
    jmp .row
.rows_done:
    movss xmm0, [f_hint_y]
    movss xmm1, [f_1_5]
    lea rdi, [s_hint]
    mov esi, 0xffc8c8c8
    call hud_text_center
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    subss xmm0, [f_305]
    movss xmm1, [f_done_y]
    movss xmm2, [f_300]
    movss xmm3, [f_btn_h]
    lea rdi, [s_controls]
    call ui_button
    test eax, eax
    jz .sdone
    mov dword [bind_wait], -1
    mov dword [state], GS_CONTROLS
    jmp ui_done
.sdone:
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    addss xmm0, [f_5]
    movss xmm1, [f_done_y]
    movss xmm2, [f_300]
    movss xmm3, [f_btn_h]
    lea rdi, [s_done]
    call ui_button
    test eax, eax
    jz ui_done
    mov eax, [settings_return]
    mov [state], eax
    jmp ui_done

; key bindings: click an action, press its new key
scr_controls:
    mov edi, 0x90000000
    call backdrop
    movss xmm0, [f_24]
    movss xmm1, [f_three]
    lea rdi, [s_controls]
    mov esi, 0xffffffff
    call hud_text_center
    xor ebx, ebx
.row:
    cmp ebx, 10
    jae .rows_done
    lea r8, [s_presskey]
    cmp ebx, [bind_wait]
    je .label
    lea rax, [binds]
    mov edi, [rax + rbx*4]
    lea rsi, [key_buf]
    mov edx, 32
    call key_name
    lea r8, [key_buf]
.label:
    lea rdi, [label_buf]
    mov esi, 96
    lea rdx, [s_bindfmt]
    lea rax, [bind_labels]
    mov rcx, [rax + rbx*8]
    xor eax, eax
    call snprintf PLT
    ; column = i / 5, row = i % 5
    mov eax, ebx
    xor edx, edx
    mov ecx, 5
    div ecx
    mov r12d, eax
    mov r13d, edx
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    subss xmm0, [f_305]
    cvtsi2ss xmm1, r12d
    mulss xmm1, [f_310]
    addss xmm0, xmm1
    cvtsi2ss xmm1, r13d
    mulss xmm1, [f_set_gap]
    addss xmm1, [f_60]
    movss xmm2, [f_300]
    movss xmm3, [f_set_h]
    lea rdi, [label_buf]
    call ui_button
    test eax, eax
    jz .next
    mov [bind_wait], ebx
.next:
    inc ebx
    jmp .row
.rows_done:
    movss xmm0, [f_c_hint1]
    movss xmm1, [f_1_5]
    lea rdi, [s_chint1]
    mov esi, 0xffc8c8c8
    call hud_text_center
    movss xmm0, [f_c_hint2]
    movss xmm1, [f_1_5]
    lea rdi, [s_chint2]
    mov esi, 0xffc8c8c8
    call hud_text_center
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    subss xmm0, [f_305]
    movss xmm1, [f_done_y]
    movss xmm2, [f_300]
    movss xmm3, [f_btn_h]
    lea rdi, [s_reset]
    call ui_button
    test eax, eax
    jz .cdone
    call binds_reset
.cdone:
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    addss xmm0, [f_5]
    movss xmm1, [f_done_y]
    movss xmm2, [f_300]
    movss xmm3, [f_btn_h]
    lea rdi, [s_done]
    call ui_button
    test eax, eax
    jz ui_done
    mov dword [bind_wait], -1
    mov dword [state], GS_SETTINGS
    jmp ui_done

scr_pause:
    mov edi, 0x80000000
    call backdrop
    movss xmm0, [f_y_title]
    movss xmm1, [f_four]
    lea rdi, [s_paused]
    mov esi, 0xffffffff
    call title_at
    movss xmm0, [f_y_sub]
    xor eax, eax
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_resume]
    call center_button
    test eax, eax
    jz .q1
    call resume_game
    jmp ui_done
.q1:
    movss xmm0, [f_y_sub]
    mov eax, 1
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_settings]
    call center_button
    test eax, eax
    jz .q2
    mov dword [settings_return], GS_PAUSE
    mov dword [state], GS_SETTINGS
    jmp ui_done
.q2:
    movss xmm0, [f_y_sub]
    mov eax, 2
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_mainmenu]
    call center_button
    test eax, eax
    jz .q3
    call end_world
    jmp ui_done
.q3:
    movss xmm0, [f_y_sub]
    mov eax, 3
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_quit]
    call center_button
    test eax, eax
    jz .help
    mov dword [running], 0
.help:
    movss xmm0, [f_y_sub]
    mov eax, 4
    call row_y
    addss xmm1, [f_24]
    movaps xmm0, xmm1
    movss [rsp], xmm1
    movss xmm1, [f_1_5]
    lea rdi, [s_help1]
    mov esi, 0xffe0e0e0
    call hud_text_center
    movss xmm0, [rsp]
    addss xmm0, [f_24]
    movss [rsp], xmm0
    movss xmm1, [f_1_5]
    lea rdi, [s_help2]
    mov esi, 0xffe0e0e0
    call hud_text_center
    movss xmm0, [rsp]
    addss xmm0, [f_24]
    movss xmm1, [f_1_5]
    lea rdi, [s_help3]
    mov esi, 0xffa0d0a0
    call hud_text_center
    jmp ui_done

scr_dead:
    mov edi, 0x700000a0
    call backdrop
    movss xmm0, [f_y_title]
    movss xmm1, [f_eight]
    lea rdi, [s_died]
    mov esi, 0xff4040ff
    call title_at
    movss xmm0, [f_y_menu]
    xor eax, eax
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_respawn]
    call center_button
    test eax, eax
    jz .d1
    call respawn
    jmp ui_done
.d1:
    movss xmm0, [f_y_menu]
    mov eax, 1
    call row_y
    movss xmm2, [f_400]
    lea rdi, [s_mainmenu]
    call center_button
    test eax, eax
    jz ui_done
    call end_world
    jmp ui_done

NOEXECSTACK
