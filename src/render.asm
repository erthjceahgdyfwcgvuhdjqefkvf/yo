; render.asm - OpenGL rendering: world, clouds, overlays and HUD.
;
; Three interchangeable ways to feed chunk geometry to the driver (the
; RENDERER setting), so each can be measured on old hardware:
;   0  VBO            (OpenGL 1.5) geometry in buffer objects
;   1  display lists  (OpenGL 1.0) geometry compiled into lists
;   2  vertex arrays  (OpenGL 1.1) geometry drawn from system memory
; Everything is fixed-function: no shaders. Lighting uses three texture
; units as a combiner (OpenGL 1.3 texture_env_combine):
;   unit 0: primary rgb (sky light) x constant (daylight)
;   unit 1: + primary alpha (block light)
;   unit 2: x atlas texture, alpha from the texture
; so night falls by changing one constant, without rebuilding meshes.

%include "common.inc"

global init_gl, rebuild_atlas, apply_vsync, renderer_reset, upload_slot
global render_world, draw_hud, hud_begin, hud_rect, hud_text, hud_text_center, stat_count
global hud_tile, stat_verts, vbo_ok, tex_atlas, tex_font, vis, hud_item
global combine_ok, tint_begin, world_tex_begin, world_tex_end, client_pointers, unbind_vbo
global p_bindbuf, p_bufdata, p_genbuf, frustum_box, sky_rgb, draw_figure
global fig_parts, fig_tint, name_t, hud_message, msg_t
extern draw_mobs, draw_boats, draw_tnt, boom_t, item_name, dt
extern dimension, portal_t, portal_need, draw_viewmodel, draw_fireballs, beacon_draw
%ifdef VOXASM_WIN
extern glCopyTexSubImage2D, set_window
%endif
extern armor, armor_points, armor_rgb

; main.asm
extern win_w, win_h, cur_pcx, cur_pcz, spiral, spiral_n, fps, seed, t_now
extern errmsg, sunlight, tod
; player.asm
extern pos, yaw, pitch, syaw, cyaw, eye_water, target_hit, target, dig_stage
extern game_mode, hp, breath, sel_slot, hurt_flash
; items.asm
extern inv, tool_of, ents, ent_count
; horizon.asm
extern horizon_draw, horizon_dist
; settings.asm
extern set_range, set_renderer, set_textures, set_leaves, set_clouds
extern set_fog, set_vsync, set_fov, set_showfps
; modules
extern texgen_atlas, atlas_rgba, atlas_w, atlas_h, block_tiles
extern icons_build, icons_rgba, light_get, light_curve, mesh_light_mode
extern font_build, font_rgba, text_draw, text_width
extern world_find, chunk_info, mesh_buf_surf, mesh_buf_deep, mesh_buf_wat
extern noise_fractal2d
; libc / GL
extern realloc, snprintf, strstr, glGetString, rend_loaded
extern glXGetProcAddressARB
extern glViewport, glClearColor, glClear, glEnable, glDisable, glMatrixMode
extern glLoadIdentity, glFrustum, glOrtho, glRotatef, glTranslatef, glScalef
extern glPushMatrix, glPopMatrix, glGenTextures, glBindTexture, glTexImage2D
extern glTexParameteri, glBlendFunc, glAlphaFunc, glFogi, glFogf, glFogfv
extern glDepthMask, glColor4f, glColor4ub, glBegin, glEnd, glVertex2f
extern glVertex3f, glTexCoord2f, glLineWidth, glEnableClientState
extern glVertexPointer, glTexCoordPointer, glColorPointer, glDrawArrays
extern glHint, glShadeModel, glGenLists, glNewList, glEndList, glCallList
extern glTexEnvi, glTexEnvfv, glDisableClientState, glDepthFunc

DEEP_RANGE      equ 3
MAX_SPIRAL      equ 2048
GL_RENDERER     equ 0x1F01
REND_VBO        equ 0
REND_DLIST      equ 1
REND_VARRAY     equ 2
CLOUD_Y         equ 120
CLOUD_CELL      equ 12

GL_LINES        equ 0x0001
GL_QUADS        equ 0x0007
GL_DEPTH_BUFFER_BIT equ 0x0100
GL_COLOR_BUFFER_BIT equ 0x4000
GL_CULL_FACE    equ 0x0B44
GL_FOG          equ 0x0B60
GL_FOG_START    equ 0x0B63
GL_FOG_END      equ 0x0B64
GL_FOG_MODE     equ 0x0B65
GL_FOG_COLOR    equ 0x0B66
GL_DEPTH_TEST   equ 0x0B71
GL_ALPHA_TEST   equ 0x0BC0
GL_BLEND        equ 0x0BE2
GL_FOG_HINT     equ 0x0C54
GL_TEXTURE_2D   equ 0x0DE1
GL_GREATER      equ 0x0204
GL_SRC_ALPHA    equ 0x0302
GL_ONE_MINUS_SRC_ALPHA equ 0x0303
GL_ONE_MINUS_DST_COLOR equ 0x0307
GL_COMPILE      equ 0x1300
GL_SHORT        equ 0x1402
GL_UNSIGNED_BYTE equ 0x1401
GL_RGB          equ 0x1907
GL_RGBA         equ 0x1908
GL_FASTEST      equ 0x1101
GL_MODELVIEW    equ 0x1700
GL_PROJECTION   equ 0x1701
GL_TEXTURE      equ 0x1702
GL_FLAT         equ 0x1D00
GL_LINEAR       equ 0x2601
SCALE_TEX       equ 1024            ; texture for a world drawn smaller (Windows)
GL_NEAREST      equ 0x2600
GL_TEXTURE_MAG_FILTER equ 0x2800
GL_TEXTURE_MIN_FILTER equ 0x2801
GL_VERTEX_ARRAY equ 0x8074
GL_COLOR_ARRAY  equ 0x8076
GL_TEXTURE_COORD_ARRAY equ 0x8078
GL_ARRAY_BUFFER equ 0x8892
GL_STATIC_DRAW  equ 0x88E4
GL_TEXTURE0     equ 0x84C0
GL_TEXTURE1     equ 0x84C1
GL_TEXTURE2     equ 0x84C2
GL_TEXTURE_ENV  equ 0x2300
GL_TEXTURE_ENV_MODE equ 0x2200
GL_TEXTURE_ENV_COLOR equ 0x2201
GL_MODULATE     equ 0x2100
GL_ADD          equ 0x0104
GL_REPLACE      equ 0x1E01
GL_COMBINE      equ 0x8570
GL_COMBINE_RGB  equ 0x8571
GL_COMBINE_ALPHA equ 0x8572
GL_SOURCE0_RGB  equ 0x8580
GL_SOURCE1_RGB  equ 0x8581
GL_SOURCE0_ALPHA equ 0x8588
GL_OPERAND0_RGB equ 0x8590
GL_OPERAND1_RGB equ 0x8591
GL_OPERAND0_ALPHA equ 0x8598
GL_CONSTANT     equ 0x8576
GL_PRIMARY_COLOR equ 0x8577
GL_PREVIOUS     equ 0x8578
GL_SRC_COLOR    equ 0x0300
GL_LEQUAL       equ 0x0203
GL_LESS         equ 0x0201
DAY_MIN         equ 0                ; (see main.asm for the daylight range)

section .rodata
align 16
f_absmask:  dd 0x7fffffff, 0, 0, 0
f_zero:     dd 0.0
f_one:      dd 1.0
f_half:     dd 0.5
f_eye:      dd 1.6
f_rad2deg:  dd 57.2957795
f_deg2rad_half: dd 0.00872664626   ; pi / 360
f_16:       dd 16.0
f_8:        dd 8.0
f_eighth:   dd 0.125
f_fogs:     dd 0.6
f_fogw1:    dd 20.0
f_fmargin:  dd 0.1
f_vmargin:  dd 0.1
f_outl0:    dd -0.005
f_outl1:    dd 1.005
f_crk0:     dd -0.003
f_crk1:     dd 1.003
f_inv2048:  dd 0.00048828125
f_inv1024:  dd 0.0009765625         ; atlas texels -> v (8 rows of 128)
f_tile_u:   dd 0.0625               ; one atlas tile, normalised
f_tile_v:   dd 0.125
f_rep_u:    dd 0.0078125            ; one repeat inside a tile
f_rep_v:    dd 0.03125
f_icon_u:   dd 0.0625               ; one item icon
f_icon_v:   dd 0.125
f_inv255:   dd 0.00392156863
f_ent_half: dd 0.125
f_ent_bob:  dd 0.1
f_ent_spin: dd 90.0
f_ent_lift: dd 0.25
f_sun_d:    dd 100.0
f_sun_s:    dd 12.0
f_moon_s:   dd 8.0
f_2pi:      dd 6.28318531
f_daymin:   dd 0.14
f_dayspan:  dd 1.16279070           ; 1 / (1 - 0.14)
night_sky:  dd 0.02, 0.03, 0.08
sun_rgb:    dd 1.0, 0.95, 0.6
moon_rgb:   dd 0.85, 0.88, 1.0
tier_durab: dd 1, 59, 131, 250, 1561
f_cloud_drift: dd 1.2
f_cloud_cell: dd 12.0
f_cloud_inv: dd 0.0833333333
f_cloud_thr: dd 0.25
f_cloud_y:  dd 120.0
f_cloud_a:  dd 0.75
f_hud3:     dd 3.0
f_255:      dd 255.0
f_name_t:   dd 2.0                  ; held item name shows this long
f_name_y:   dd 118.0                ; this far above the bottom (over the hearts)
f_msg_y:    dd 150.0                ; messages above that
f_msg_t:    dd 3.0
f_count_h:  dd 12.0                 ; count text sits this far above the slot bottom
f_hud4:     dd 4.0
f_hud10:    dd 10.0
f_hud14:    dd 14.0
f_hud16:    dd 16.0
f_hud22:    dd 22.0
f_hud32:    dd 32.0
f_hud40:    dd 40.0
f_hud43:    dd 43.0
f_hud48:    dd 48.0
f_hud56:    dd 56.0
f_hud212:   dd 212.0
f_armor_dy: dd 18.0                 ; the armour row over the hearts
f_two:      dd 2.0
sky_col:    dd 0.62, 0.78, 1.0, 1.0
water_col:  dd 0.10, 0.22, 0.45, 1.0
lava_col:   dd 0.95, 0.35, 0.05, 1.0
nether_col: dd 0.22, 0.04, 0.03, 1.0
f_nfog0:    dd 4.0                  ; nether haze: starts and ends (nodes)
f_nfog1:    dd 56.0
f_200:      dd 200.0
f_fogl1:    dd 2.5                  ; fog end with the eyes in lava
align 8
d_near:     dq 0.08
d_far:      dq 1600.0                 ; past the farthest horizon (1024)
d_zero:     dq 0.0
d_one:      dq 1.0
d_m1:       dq -1.0
; player figure (model units: 32 tall, feet at 0, facing +z)
f_fig_turn: dd 0.35                 ; degrees per pixel of mouse offset
f_fig_yaw:  dd 60.0
f_fig_pitch: dd 35.0
f_fig_body: dd 0.35                 ; share of the turn taken by the body
f_fig_head: dd 0.65                 ; the rest by the head
f_fig_neck: dd 24.0
d_fig_near: dq -1000.0
d_fig_far:  dq 1000.0
%macro FPART 9                      ; x0 y0 z0 x1 y1 z1 r g b
    dd %1, %2, %3, %4, %5, %6
    db %7, %8, %9, 0
    dd 0
%endmacro
align 4
fig_body:
    FPART -4.0,  0.0, -2.2,  0.0,  2.0,  2.2,  50,  44,  40   ; shoes
    FPART  0.0,  0.0, -2.2,  4.0,  2.0,  2.2,  50,  44,  40
    FPART -4.0,  2.0, -2.0,  0.0, 12.0,  2.0,  52,  64, 120   ; trousers
    FPART  0.0,  2.0, -2.0,  4.0, 12.0,  2.0,  52,  64, 120
    FPART -4.0, 12.0, -2.0,  4.0, 24.0,  2.0, 196,  92,  44   ; shirt
    FPART -8.0, 18.0, -2.0, -4.0, 24.0,  2.0, 196,  92,  44   ; sleeves
    FPART  4.0, 18.0, -2.0,  8.0, 24.0,  2.0, 196,  92,  44
    FPART -8.0, 12.0, -2.0, -4.0, 18.0,  2.0, 214, 168, 128   ; arms
    FPART  4.0, 12.0, -2.0,  8.0, 18.0,  2.0, 214, 168, 128
FIG_BODY_N equ ($ - fig_body) / 32
fig_head:
    FPART -4.0,  0.0, -4.0,  4.0,  8.0,  4.0, 214, 168, 128   ; face
    FPART -4.3,  6.0, -4.3,  4.3,  8.4,  4.3,  70,  46,  30   ; hair
    FPART -4.3,  1.0, -4.3,  4.3,  6.0, -3.0,  70,  46,  30
    FPART -3.0,  3.0,  4.0, -1.0,  4.2,  4.2, 240, 240, 240   ; eyes
    FPART  1.0,  3.0,  4.0,  3.0,  4.2,  4.2, 240, 240, 240
    FPART -2.0,  3.0,  4.0, -1.0,  4.2,  4.4,  40,  70, 140
    FPART  1.0,  3.0,  4.0,  2.0,  4.2,  4.4,  40,  70, 140
    FPART -2.0,  1.4,  4.0,  2.0,  2.0,  4.2, 150,  90,  80   ; mouth
FIG_HEAD_N equ ($ - fig_head) / 32
; armour over the figure, white: drawn in the material colour
arm_helmet:                         ; on the head (from the neck)
    FPART -4.7,  4.6, -4.7,  4.7,  8.9,  4.7, 250, 250, 250
    FPART -4.7,  1.0, -4.7, -4.0,  4.6,  1.0, 230, 230, 230
    FPART  4.0,  1.0, -4.7,  4.7,  4.6,  1.0, 230, 230, 230
    FPART -4.7,  0.5, -4.7,  4.7,  4.6, -3.6, 230, 230, 230
ARM_HELMET_N equ ($ - arm_helmet) / 32
arm_chest:
    FPART -4.5, 11.5, -2.6,  4.5, 24.4,  2.6, 250, 250, 250
    FPART -8.5, 17.6, -2.5, -4.0, 24.5,  2.5, 235, 235, 235
    FPART  4.0, 17.6, -2.5,  8.5, 24.5,  2.5, 235, 235, 235
ARM_CHEST_N equ ($ - arm_chest) / 32
arm_legs:
    FPART -4.4,  3.0, -2.4,  0.0, 12.4,  2.4, 240, 240, 240
    FPART  0.0,  3.0, -2.4,  4.4, 12.4,  2.4, 240, 240, 240
ARM_LEGS_N equ ($ - arm_legs) / 32
arm_boots:
    FPART -4.5, -0.2, -2.7, -0.1,  4.0,  2.7, 235, 235, 235
    FPART  0.1, -0.2, -2.7,  4.5,  4.0,  2.7, 235, 235, 235
ARM_BOOTS_N equ ($ - arm_boots) / 32
arm_tables: dq arm_helmet, arm_chest, arm_legs, arm_boots
arm_counts: dd ARM_HELMET_N, ARM_CHEST_N, ARM_LEGS_N, ARM_BOOTS_N

np_clouds:  dd 0.0, 1.0, 8.0, 8.0, 8.0, 2210, 2, 0.5, 2.0, 1

outline_edges:
    db 0,0,0, 1,0,0,  1,0,0, 1,0,1,  1,0,1, 0,0,1,  0,0,1, 0,0,0
    db 0,1,0, 1,1,0,  1,1,0, 1,1,1,  1,1,1, 0,1,1,  0,1,1, 0,1,0
    db 0,0,0, 0,1,0,  1,0,0, 1,1,0,  1,0,1, 1,1,1,  0,0,1, 0,1,1
; crack overlay: 6 quads x 4 corners of (x, y, z, u, v)
crack_quads:
    db 1,0,1,0,1, 1,0,0,1,1, 1,1,0,1,0, 1,1,1,0,0
    db 0,0,0,0,1, 0,0,1,1,1, 0,1,1,1,0, 0,1,0,0,0
    db 0,1,0,0,1, 0,1,1,1,1, 1,1,1,1,0, 1,1,0,0,0
    db 0,0,0,0,1, 1,0,0,1,1, 1,0,1,1,0, 0,0,1,0,0
    db 0,0,1,0,1, 1,0,1,1,1, 1,1,1,1,0, 0,1,1,0,0
    db 1,0,0,0,1, 0,0,0,1,1, 0,1,0,1,0, 1,1,0,0,0

s_genbuf:   db "glGenBuffers", 0
s_bindbuf:  db "glBindBuffer", 0
s_bufdata:  db "glBufferData", 0
s_genbufa:  db "glGenBuffersARB", 0
s_bindbufa: db "glBindBufferARB", 0
s_bufdataa: db "glBufferDataARB", 0
s_swapmesa: db "glXSwapIntervalMESA", 0
s_acttex:   db "glActiveTexture", 0
s_acttexa:  db "glActiveTextureARB", 0
s_clacttex: db "glClientActiveTexture", 0
s_clacttexa: db "glClientActiveTextureARB", 0
s_nocomb:   db "VoxASM: no multitexture: plain lighting, no day/night shading", 10
s_nocomb_len equ $ - s_nocomb
s_swapsgi:  db "glXSwapIntervalSGI", 0
s_count:    db "%d", 0
s_fpsfmt:   db "FPS %d   VERTS %dK   XYZ %d %d %d", 0
s_novbo:    db "VoxASM: no VBO support, using vertex arrays", 10
s_novbo_len equ $ - s_novbo
s_igp:      db "VoxASM: no hardware vertex processing, using display lists", 10
s_igp_len   equ $ - s_igp
s_rs4:      db "RS4", 0
s_xpress:   db "XPRESS", 0             ; ATI's own driver (Windows)
s_xpress2:  db "Xpress", 0
s_rs6:      db "RS6", 0
s_rs7:      db "RS7", 0
s_rc4:      db "RC4", 0

section .data
align 4
name_t:     dd 0.0                  ; held item name: seconds left
msg_t:      dd 0.0                  ; a message (hud_message): seconds left
align 8
msg_text:   dq 0
name_last:  dd -1                   ; slot dword (with slot number) shown
fig_tint:   dd 256, 256, 256        ; r, g, b multipliers for figure boxes (256 = 1)
align 8
; Radeon IGPs without hardware vertex processing (Xpress 200/1100/1150,
; X1200 ...): their r300 driver does it on the CPU, and keeps display
; lists in its own format, so they are the fastest path there
igp_names:  dq s_rs4, s_rs6, s_rs7, s_rc4, s_xpress, s_xpress2, 0

section .bss
alignb 8
p_genbuf:   resq 1
p_bindbuf:  resq 1
p_bufdata:  resq 1
p_swapint:  resq 1
p_swapsgi:  resq 1
p_acttex:   resq 1
p_clacttex: resq 1
vbo_ok:     resd 1
combine_ok: resd 1
tex_atlas:  resd 1
tex_font:   resd 1
tex_white:  resd 1
tex_icons:  resd 1
sky_rgb:    resd 4                  ; current sky / fog colour
env_col:    resd 4                  ; daylight constant for unit 0
white_px:   resd 1
dl_base:    resd 1
stat_verts: resd 1
stat_count: resd 1
tan_h:      resd 1
tan_v:      resd 1
vis:        resb MAX_SPIRAL
alignb 16
fr_n:       resd 16
fr_eye:     resd 4                  ; eye relative to the player chunk origin
fr_box:     resd 8
alignb 8
va_ptr:     resq NUM_SLOTS * 3
va_cap:     resd NUM_SLOTS * 3
vbo_ids:    resd NUM_SLOTS * 3
text_buf:   resb 128
view_w:     resd 1                  ; size the world is drawn at
view_h:     resd 1
scale_tex:  resd 1                  ; (Windows) the small frame, stretched
scale_u:    resd 1
scale_v:    resd 1
scale_sw:   resd 1
scale_sh:   resd 1

section .text

; rax = GL entry point named rdi, or the ARB name in rsi
gl_proc:
    push rbx
    mov rbx, rsi
    call glXGetProcAddressARB PLT
    test rax, rax
    jnz .ok
    test rbx, rbx
    jz .ok
    mov rdi, rbx
    call glXGetProcAddressARB PLT
.ok:
    pop rbx
    ret

; upload an RGBA image (rsi pixels, edx w, ecx h) to texture edi
upload_texture:
    ENTER_FN 32
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov esi, edi
    mov edi, GL_TEXTURE_2D
    call glBindTexture PLT
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_NEAREST
    call glTexParameteri PLT
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_NEAREST
    call glTexParameteri PLT
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    mov edx, GL_RGBA
    mov ecx, r13d
    mov r8d, r14d
    xor r9d, r9d
    mov qword [rsp], GL_RGBA
    mov qword [rsp + 8], GL_UNSIGNED_BYTE
    mov [rsp + 16], r12
    call glTexImage2D PLT
    LEAVE_FN

; void rebuild_atlas(void) - regenerate and upload for the texture settings
rebuild_atlas:
    ENTER_FN 0
    mov eax, [set_textures]
    lea rcx, [tex_res_table]
    mov edi, [rcx + rax*4]
    mov esi, [set_leaves]
    call texgen_atlas
    mov edi, [tex_atlas]
    lea rsi, [atlas_rgba]
    mov edx, [atlas_w]
    mov ecx, [atlas_h]
    call upload_texture
    LEAVE_FN

; void apply_vsync(void)
apply_vsync:
    ENTER_FN 0
    mov edi, [set_vsync]
    mov rax, [p_swapint]
    test rax, rax
    jz .sgi
    call rax
    jmp .out
.sgi:
    cmp dword [set_vsync], 0        ; SGI cannot switch it off
    je .out
    mov rax, [p_swapsgi]
    test rax, rax
    jz .out
    mov edi, 1
    call rax
.out:
    LEAVE_FN

; int init_gl(void)
init_gl:
    ENTER_FN 32
    lea rdi, [s_genbuf]
    lea rsi, [s_genbufa]
    call gl_proc
    mov [p_genbuf], rax
    lea rdi, [s_bindbuf]
    lea rsi, [s_bindbufa]
    call gl_proc
    mov [p_bindbuf], rax
    lea rdi, [s_bufdata]
    lea rsi, [s_bufdataa]
    call gl_proc
    mov [p_bufdata], rax
    lea rdi, [s_swapmesa]
    xor esi, esi
    call gl_proc
    mov [p_swapint], rax
    lea rdi, [s_swapsgi]
    xor esi, esi
    call gl_proc
    mov [p_swapsgi], rax
    lea rdi, [s_acttex]
    lea rsi, [s_acttexa]
    call gl_proc
    mov [p_acttex], rax
    lea rdi, [s_clacttex]
    lea rsi, [s_clacttexa]
    call gl_proc
    mov [p_clacttex], rax
    xor eax, eax
    cmp qword [p_acttex], 0
    je .comb
    cmp qword [p_clacttex], 0
    je .comb
    mov eax, 1
.comb:
    mov [combine_ok], eax
    xor eax, 1
    mov [mesh_light_mode], eax
    test eax, eax
    jz .comb_ok
    lea rdi, [s_nocomb]
    mov esi, s_nocomb_len
    call errmsg
.comb_ok:
    xor eax, eax
    cmp qword [p_genbuf], 0
    je .vbo
    cmp qword [p_bindbuf], 0
    je .vbo
    cmp qword [p_bufdata], 0
    je .vbo
    mov eax, 1
.vbo:
    mov [vbo_ok], eax
    call pick_renderer
    mov eax, [vbo_ok]
    test eax, eax
    jz .novbo
    mov edi, NUM_SLOTS * 3
    lea rsi, [vbo_ids]
    call [p_genbuf]
    jmp .lists
.novbo:
    cmp dword [set_renderer], REND_VBO
    jne .lists
    mov dword [set_renderer], REND_VARRAY
    lea rdi, [s_novbo]
    mov esi, s_novbo_len
    call errmsg
.lists:
    mov edi, NUM_SLOTS * 8
    call glGenLists PLT
    mov [dl_base], eax

    mov edi, 1
    lea rsi, [tex_atlas]
    call glGenTextures PLT
    mov edi, 1
    lea rsi, [tex_font]
    call glGenTextures PLT
    call font_build
    mov edi, [tex_font]
    lea rsi, [font_rgba]
    mov edx, 128
    mov ecx, 64
    call upload_texture
    mov edi, 1
    lea rsi, [tex_icons]
    call glGenTextures PLT
    call icons_build
    mov edi, [tex_icons]
    lea rsi, [icons_rgba]
    mov edx, ICONS_W
    mov ecx, ICONS_H
    call upload_texture
    mov edi, 1
    lea rsi, [tex_white]
    call glGenTextures PLT
    mov dword [white_px], 0xffffffff
    mov edi, [tex_white]
    lea rsi, [white_px]
    mov edx, 1
    mov ecx, 1
    call upload_texture
    call rebuild_atlas

    mov edi, GL_VERTEX_ARRAY
    call glEnableClientState PLT
    mov edi, GL_COLOR_ARRAY
    call glEnableClientState PLT
    mov edi, GL_TEXTURE_COORD_ARRAY
    call glEnableClientState PLT
    ; with the combiner only unit 2 reads texture coordinates from arrays
    cmp dword [combine_ok], 0
    je .nocomb
    call setup_combiners
.nocomb:
    mov edi, GL_FLAT
    call glShadeModel PLT
    mov edi, GL_GREATER
    movss xmm0, [f_half]
    call glAlphaFunc PLT
    mov edi, GL_FOG_HINT
    mov esi, GL_FASTEST
    call glHint PLT
    mov edi, GL_FOG_MODE
    mov esi, GL_LINEAR
    call glFogi PLT
    call apply_vsync
    mov eax, 1
    LEAVE_FN

; pick_renderer - display lists by default on IGPs without hardware vertex
; processing, unless the settings file chose a renderer
pick_renderer:
    ENTER_FN 0
    cmp dword [rend_loaded], 0
    jne .out
    mov edi, GL_RENDERER
    call glGetString PLT
    test rax, rax
    jz .out
    mov rbx, rax
    lea r12, [igp_names]
.n:
    mov rsi, [r12]
    test rsi, rsi
    jz .out
    mov rdi, rbx
    call strstr PLT
    test rax, rax
    jnz .dl
    add r12, 8
    jmp .n
.dl:
%ifdef VOXASM_WIN
    jmp .out                        ; ATI's Windows driver: VBOs are fastest there
%endif
    mov dword [set_renderer], REND_DLIST
    lea rdi, [s_igp]
    mov esi, s_igp_len
    call errmsg
.out:
    LEAVE_FN

; act(edi unit 0-2) / clact(edi unit) - select the (client) texture unit
act:
    sub rsp, 8
    add edi, GL_TEXTURE0
    call [p_acttex]
    add rsp, 8
    ret
clact:
    sub rsp, 8
    add edi, GL_TEXTURE0
    call [p_clacttex]
    add rsp, 8
    ret

; ENV pname, value - glTexEnvi on the active unit
%macro ENV 2
    mov edi, GL_TEXTURE_ENV
    mov esi, %1
    mov edx, %2
    call glTexEnvi PLT
%endmacro

; The three-unit combiner (state is kept per unit, so set once).
setup_combiners:
    ENTER_FN 0
    xor edi, edi
    call act
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_white]
    call glBindTexture PLT
    ENV GL_TEXTURE_ENV_MODE, GL_COMBINE
    ENV GL_COMBINE_RGB, GL_MODULATE
    ENV GL_SOURCE0_RGB, GL_PRIMARY_COLOR
    ENV GL_OPERAND0_RGB, GL_SRC_COLOR
    ENV GL_SOURCE1_RGB, GL_CONSTANT
    ENV GL_OPERAND1_RGB, GL_SRC_COLOR
    ENV GL_COMBINE_ALPHA, GL_REPLACE
    ENV GL_SOURCE0_ALPHA, GL_PRIMARY_COLOR
    ENV GL_OPERAND0_ALPHA, GL_SRC_ALPHA
    mov edi, 1
    call act
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_white]
    call glBindTexture PLT
    ENV GL_TEXTURE_ENV_MODE, GL_COMBINE
    ENV GL_COMBINE_RGB, GL_ADD
    ENV GL_SOURCE0_RGB, GL_PREVIOUS
    ENV GL_OPERAND0_RGB, GL_SRC_COLOR
    ENV GL_SOURCE1_RGB, GL_PRIMARY_COLOR
    ENV GL_OPERAND1_RGB, GL_SRC_ALPHA
    ENV GL_COMBINE_ALPHA, GL_REPLACE
    ENV GL_SOURCE0_ALPHA, GL_PREVIOUS
    ENV GL_OPERAND0_ALPHA, GL_SRC_ALPHA
    mov edi, 2
    call act
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_atlas]
    call glBindTexture PLT
    ENV GL_TEXTURE_ENV_MODE, GL_COMBINE
    ENV GL_COMBINE_RGB, GL_MODULATE
    ENV GL_SOURCE0_RGB, GL_PREVIOUS
    ENV GL_OPERAND0_RGB, GL_SRC_COLOR
    ENV GL_SOURCE1_RGB, GL_TEXTURE
    ENV GL_OPERAND1_RGB, GL_SRC_COLOR
    ENV GL_COMBINE_ALPHA, GL_REPLACE
    ENV GL_SOURCE0_ALPHA, GL_TEXTURE
    ENV GL_OPERAND0_ALPHA, GL_SRC_ALPHA
    ; world texture coordinates are in 1/16 node units
    mov edi, GL_TEXTURE
    call glMatrixMode PLT
    call glLoadIdentity PLT
    movss xmm0, [f_inv2048]
    movss xmm1, [f_inv1024]
    movss xmm2, [f_one]
    call glScalef PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    mov edi, 2
    call clact
    mov edi, GL_TEXTURE_COORD_ARRAY
    call glEnableClientState PLT
    xor edi, edi
    call clact
    mov edi, GL_TEXTURE_COORD_ARRAY
    call glDisableClientState PLT
    xor edi, edi
    call act
    ; unit 0 stays plain until world_tex_begin: menus and text drawn
    ; before the first world frame need it (the daylight constant is unset)
    ENV GL_TEXTURE_ENV_MODE, GL_MODULATE
    LEAVE_FN

; world_tex_begin - texturing for chunk meshes (combiner or plain)
world_tex_begin:
    ENTER_FN 0
    cmp dword [combine_ok], 0
    je .plain
    xor edi, edi
    call act
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_white]
    call glBindTexture PLT
    ENV GL_TEXTURE_ENV_MODE, GL_COMBINE
    mov edi, GL_TEXTURE_ENV
    mov esi, GL_TEXTURE_ENV_COLOR
    lea rdx, [env_col]
    call glTexEnvfv PLT
    mov edi, 1
    call act
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, 2
    call act
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_atlas]
    call glBindTexture PLT
    xor edi, edi
    call act
    LEAVE_FN
.plain:
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_atlas]
    call glBindTexture PLT
    mov edi, GL_TEXTURE
    call glMatrixMode PLT
    call glLoadIdentity PLT
    movss xmm0, [f_inv2048]
    movss xmm1, [f_inv1024]
    movss xmm2, [f_one]
    call glScalef PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    LEAVE_FN

; world_tex_end - back to one plain unit with an identity texture matrix
world_tex_end:
    ENTER_FN 0
    cmp dword [combine_ok], 0
    je .plain
    mov edi, 2
    call act
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, 1
    call act
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    xor edi, edi
    call act
    ENV GL_TEXTURE_ENV_MODE, GL_MODULATE
    LEAVE_FN
.plain:
    mov edi, GL_TEXTURE
    call glMatrixMode PLT
    call glLoadIdentity PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    LEAVE_FN

; tint_begin - untextured geometry: vertex colour x daylight (horizon,
; clouds); finish with world_tex_end
tint_begin:
    ENTER_FN 0
    cmp dword [combine_ok], 0
    je .plain
    xor edi, edi
    call act
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_white]
    call glBindTexture PLT
    ENV GL_TEXTURE_ENV_MODE, GL_COMBINE
    mov edi, GL_TEXTURE_ENV
    mov esi, GL_TEXTURE_ENV_COLOR
    lea rdx, [env_col]
    call glTexEnvfv PLT
    LEAVE_FN
.plain:
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    LEAVE_FN

; void renderer_reset(void) - after a renderer change: every mesh goes and
; is rebuilt through the new path
renderer_reset:
    cmp dword [set_renderer], REND_VBO
    jne .ok
    cmp dword [vbo_ok], 0
    jne .ok
    mov dword [set_renderer], REND_VARRAY
.ok:
    lea rax, [chunk_info]
    mov ecx, NUM_SLOTS
.c:
    cmp byte [rax + CI_STATE], ST_READY
    jne .n
    mov byte [rax + CI_MESHED], 0
    mov byte [rax + CI_DIRTY], 1
.n:
    add rax, CI_SIZE
    dec ecx
    jnz .c
    ret

; client-memory vertex pointers at rdi
client_pointers:
    push rbx
    mov rbx, rdi
    mov edi, 3
    mov esi, GL_SHORT
    mov edx, VERT_SIZE
    mov rcx, rbx
    call glVertexPointer PLT
    cmp dword [combine_ok], 0
    je .tc
    mov edi, GL_TEXTURE2
    call [p_clacttex]
.tc:
    mov edi, 2
    mov esi, GL_SHORT
    mov edx, VERT_SIZE
    lea rcx, [rbx + 8]
    call glTexCoordPointer PLT
    cmp dword [combine_ok], 0
    je .tc0
    mov edi, GL_TEXTURE0
    call [p_clacttex]
.tc0:
    mov edi, 4
    mov esi, GL_UNSIGNED_BYTE
    mov edx, VERT_SIZE
    lea rcx, [rbx + 12]
    call glColorPointer PLT
    pop rbx
    ret

unbind_vbo:
    sub rsp, 8
    cmp dword [vbo_ok], 0
    je .out
    mov edi, GL_ARRAY_BUFFER
    xor esi, esi
    call [p_bindbuf]
.out:
    add rsp, 8
    ret

; void upload_slot(int slot) - hand the freshly built meshes to the driver
; locals: [0] slot
upload_slot:
    ENTER_FN 16
    mov [rsp], edi
    mov eax, edi
    shl rax, CI_SHIFT
    lea r13, [chunk_info]
    add r13, rax
    mov eax, [set_renderer]
    cmp eax, REND_DLIST
    je .dlist
    cmp eax, REND_VARRAY
    je .varray
    ; ---- VBO
    lea r14, [vbo_ids]
    imul eax, [rsp], 12
    add r14, rax
%macro UPLOAD 3                     ; part, count field, buffer
    mov edi, GL_ARRAY_BUFFER
    mov esi, [r14 + %1*4]
    call [p_bindbuf]
    mov edi, GL_ARRAY_BUFFER
    movsxd rsi, dword [r13 + %2]
    shl rsi, 4
    lea rdx, [%3]
    mov ecx, GL_STATIC_DRAW
    call [p_bufdata]
%endmacro
    UPLOAD 0, CI_NSURF, mesh_buf_surf
    UPLOAD 1, CI_NDEEP, mesh_buf_deep
    UPLOAD 2, CI_NWAT, mesh_buf_wat
    call unbind_vbo
    LEAVE_FN

.varray:
    ; copy each part into its own growable block of system memory
%macro VACOPY 3
    mov eax, [rsp]
    imul eax, eax, 3
    add eax, %1
    mov r12d, eax                   ; part index
    movsxd r15, dword [r13 + %2]
    shl r15, 4                      ; bytes
    lea rax, [va_cap]
    cmp [rax + r12*4], r15d
    jae %%copy
    lea rsi, [r15 + r15]
    add rsi, 4096
    mov rbx, rsi
    lea rax, [va_ptr]
    mov rdi, [rax + r12*8]
    call realloc PLT
    test rax, rax
    jz %%skip
    lea rcx, [va_ptr]
    mov [rcx + r12*8], rax
    lea rcx, [va_cap]
    mov [rcx + r12*4], ebx
%%copy:
    lea rax, [va_ptr]
    mov rdi, [rax + r12*8]
    test rdi, rdi
    jz %%skip
    lea rsi, [%3]
    mov rcx, r15
    rep movsb
%%skip:
%endmacro
    VACOPY 0, CI_NSURF, mesh_buf_surf
    VACOPY 1, CI_NDEEP, mesh_buf_deep
    VACOPY 2, CI_NWAT, mesh_buf_wat
    LEAVE_FN

.dlist:
    call unbind_vbo
    ; one list per surface face direction, then deep and water
    xor r12d, r12d                  ; face
    xor r15d, r15d                  ; first vertex
.df:
    mov ebx, [r13 + CI_FACECNT + r12*4]
    mov edi, [rsp]
    shl edi, 3
    add edi, [dl_base]
    add edi, r12d
    mov esi, GL_COMPILE
    call glNewList PLT
    test ebx, ebx
    jz .dfe
    lea rdi, [mesh_buf_surf]
    mov rax, r15
    shl rax, 4
    add rdi, rax
    call client_pointers
    mov edi, GL_QUADS
    xor esi, esi
    mov edx, ebx
    call glDrawArrays PLT
.dfe:
    call glEndList PLT
    add r15d, ebx
    inc r12d
    cmp r12d, 6
    jb .df
%macro DLPART 3                     ; list, count field, buffer
    mov edi, [rsp]
    shl edi, 3
    add edi, [dl_base]
    add edi, %1
    mov esi, GL_COMPILE
    call glNewList PLT
    mov ebx, [r13 + %2]
    test ebx, ebx
    jz %%e
    lea rdi, [%3]
    call client_pointers
    mov edi, GL_QUADS
    xor esi, esi
    mov edx, ebx
    call glDrawArrays PLT
%%e:
    call glEndList PLT
%endmacro
    DLPART 6, CI_NDEEP, mesh_buf_deep
    DLPART 7, CI_NWAT, mesh_buf_wat
    LEAVE_FN

; draw_part(edi slot, esi part 0 surf / 1 deep / 2 water, edx first, ecx count)
draw_part:
    ENTER_FN 16
    add [stat_verts], ecx
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov eax, [set_renderer]
    cmp eax, REND_DLIST
    je .dl
    cmp eax, REND_VARRAY
    je .va
    imul eax, r12d, 3
    add eax, r13d
    lea rcx, [vbo_ids]
    mov esi, [rcx + rax*4]
    mov edi, GL_ARRAY_BUFFER
    call [p_bindbuf]
    xor edi, edi
    call client_pointers            ; offsets into the bound buffer
    jmp .draw
.va:
    imul eax, r12d, 3
    add eax, r13d
    lea rcx, [va_ptr]
    mov rdi, [rcx + rax*8]
    test rdi, rdi
    jz .out
    call client_pointers
.draw:
    mov edi, GL_QUADS
    mov esi, r14d
    mov edx, r15d
    call glDrawArrays PLT
    jmp .out
.dl:
    ; deep -> list 6, water -> list 7 (surface faces use draw_surface)
    mov edi, r12d
    shl edi, 3
    add edi, [dl_base]
    add edi, 5
    add edi, r13d
    call glCallList PLT
.out:
    LEAVE_FN

; ---------------------------------------------------------------------------
; Frustum culling: vis[i] = chunk i of the spiral is ready and its bounding
; box (16 x used height x 16) is inside all four side planes of the view.
; locals: [0] cos p, [4] sin p, [16] f, [32] r, [48] u, [64] eye,
;         [80] box min, [96] box size
cull_chunks:
    ENTER_FN 112
    fld dword [pitch]
    fsincos
    fstp dword [rsp]
    fstp dword [rsp + 4]
    movss xmm0, [syaw]
    mulss xmm0, [rsp]
    movss [rsp + 16], xmm0
    xorps xmm0, xmm0
    subss xmm0, [rsp + 4]
    movss [rsp + 20], xmm0
    xorps xmm0, xmm0
    movss xmm1, [cyaw]
    mulss xmm1, [rsp]
    subss xmm0, xmm1
    movss [rsp + 24], xmm0
    mov dword [rsp + 28], 0
    movss xmm0, [cyaw]
    movss [rsp + 32], xmm0
    mov dword [rsp + 36], 0
    movss xmm0, [syaw]
    movss [rsp + 40], xmm0
    mov dword [rsp + 44], 0
    movss xmm0, [syaw]
    mulss xmm0, [rsp + 4]
    movss [rsp + 48], xmm0
    movss xmm0, [rsp]
    movss [rsp + 52], xmm0
    xorps xmm0, xmm0
    movss xmm1, [cyaw]
    mulss xmm1, [rsp + 4]
    subss xmm0, xmm1
    movss [rsp + 56], xmm0
    mov dword [rsp + 60], 0
    movaps xmm0, [rsp + 16]
    movaps xmm1, [rsp + 32]
    movaps xmm2, [rsp + 48]
    movss xmm3, [tan_h]
    addss xmm3, [f_fmargin]
    shufps xmm3, xmm3, 0
    movss xmm4, [tan_v]
    addss xmm4, [f_vmargin]
    shufps xmm4, xmm4, 0
    movaps xmm5, xmm0
    mulps xmm5, xmm3
    movaps xmm6, xmm5
    subps xmm6, xmm1
    movaps [fr_n], xmm6
    addps xmm5, xmm1
    movaps [fr_n + 16], xmm5
    movaps xmm5, xmm0
    mulps xmm5, xmm4
    movaps xmm6, xmm5
    subps xmm6, xmm2
    movaps [fr_n + 32], xmm6
    addps xmm5, xmm2
    movaps [fr_n + 48], xmm5
    mov eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [pos]
    subss xmm1, xmm0
    movss [rsp + 64], xmm1
    movss xmm1, [pos + 4]
    addss xmm1, [f_eye]
    movss [rsp + 68], xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [pos + 8]
    subss xmm1, xmm0
    movss [rsp + 72], xmm1
    mov dword [rsp + 76], 0
    movss xmm0, [rsp + 64]
    movss [fr_eye], xmm0
    movss xmm0, [rsp + 68]
    movss [fr_eye + 4], xmm0
    movss xmm0, [rsp + 72]
    movss [fr_eye + 8], xmm0
    lea r13, [spiral]
    lea r14, [vis]
    xor ebx, ebx
.c:
    cmp ebx, [spiral_n]
    jae .out
    mov byte [r14 + rbx], 0
    mov r12d, [r13 + rbx*8]
    mov r15d, [r13 + rbx*8 + 4]
    mov edi, [cur_pcx]
    add edi, r12d
    mov esi, [cur_pcz]
    add esi, r15d
    call world_find
    test eax, eax
    js .next
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    add rcx, rax
    cmp byte [rcx + CI_MESHED], 0
    je .next
    ; box bottom: lowest surface face, or the world floor near the player
    mov edx, [rcx + CI_MINY]
    mov eax, r12d
    imul eax, eax
    mov esi, r15d
    imul esi, esi
    add eax, esi
    cmp eax, DEEP_RANGE * DEEP_RANGE + DEEP_RANGE
    ja .lowok
    mov edx, WORLD_YMIN
.lowok:
    mov eax, [rcx + CI_MAXY]
    add eax, WORLD_YMIN + 1
    sub eax, edx
    cvtsi2ss xmm0, eax
    movss [rsp + 100], xmm0
    mov [rsp + 92], edx
    mov eax, 16
    cvtsi2ss xmm0, eax
    movss [rsp + 96], xmm0
    movss [rsp + 104], xmm0
    mov dword [rsp + 108], 0
    mov eax, r12d
    shl eax, 4
    cvtsi2ss xmm0, eax
    subss xmm0, [rsp + 64]
    movss [rsp + 80], xmm0
    cvtsi2ss xmm0, dword [rsp + 92]
    subss xmm0, [rsp + 68]
    movss [rsp + 84], xmm0
    mov eax, r15d
    shl eax, 4
    cvtsi2ss xmm0, eax
    subss xmm0, [rsp + 72]
    movss [rsp + 88], xmm0
    mov dword [rsp + 92], 0
    movaps xmm0, [rsp + 80]
    movaps xmm1, xmm0
    addps xmm1, [rsp + 96]
    lea rax, [fr_n]
    mov ecx, 4
.plane:
    movaps xmm2, [rax]
    movaps xmm3, xmm2
    mulps xmm3, xmm0
    mulps xmm2, xmm1
    maxps xmm2, xmm3
    movaps xmm3, xmm2
    shufps xmm3, xmm3, 0x55
    movaps xmm4, xmm2
    movhlps xmm4, xmm2
    addss xmm2, xmm3
    addss xmm2, xmm4
    comiss xmm2, [f_zero]
    jb .next
    add rax, 16
    dec ecx
    jnz .plane
    mov byte [r14 + rbx], 1
.next:
    inc ebx
    jmp .c
.out:
    LEAVE_FN

; int frustum_box(float minx, miny, minz, sx, sy, sz) - box given relative
; to the player chunk origin (nodes); 1 if it may be on screen
frustum_box:
    subss xmm0, [fr_eye]
    subss xmm1, [fr_eye + 4]
    subss xmm2, [fr_eye + 8]
    movss [fr_box], xmm0
    movss [fr_box + 4], xmm1
    movss [fr_box + 8], xmm2
    mov dword [fr_box + 12], 0
    movss [fr_box + 16], xmm3
    movss [fr_box + 20], xmm4
    movss [fr_box + 24], xmm5
    mov dword [fr_box + 28], 0
    movaps xmm0, [fr_box]
    movaps xmm1, xmm0
    addps xmm1, [fr_box + 16]
    lea rax, [fr_n]
    mov ecx, 4
.plane:
    movaps xmm2, [rax]
    movaps xmm3, xmm2
    mulps xmm3, xmm0
    mulps xmm2, xmm1
    maxps xmm2, xmm3
    movaps xmm3, xmm2
    shufps xmm3, xmm3, 0x55
    movaps xmm4, xmm2
    movhlps xmm4, xmm2
    addss xmm2, xmm3
    addss xmm2, xmm4
    comiss xmm2, [f_zero]
    jb .no
    add rax, 16
    dec ecx
    jnz .plane
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; push the modelview and move to chunk (r12d, r13d) relative to the player
; chunk, in 1/8 node units
push_chunk:
    sub rsp, 8
    call glPushMatrix PLT
    mov eax, r12d
    shl eax, 7
    cvtsi2ss xmm0, eax
    xorps xmm1, xmm1
    mov eax, r13d
    shl eax, 7
    cvtsi2ss xmm2, eax
    call glTranslatef PLT
    add rsp, 8
    ret

; Surface part of chunk slot r14d at offset (r12d, r13d): draw only the
; face directions that can face the camera.
; locals: [0] eye x in chunk, [4] eye z in chunk, [8] run start,
;         [12] run length, [16] offset
draw_surface:
    ENTER_FN 32
    mov eax, r14d
    shl rax, CI_SHIFT
    lea r15, [chunk_info]
    add r15, rax
    mov eax, [cur_pcx]
    add eax, r12d
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [pos]
    subss xmm1, xmm0
    movss [rsp], xmm1
    mov eax, [cur_pcz]
    add eax, r13d
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [pos + 8]
    subss xmm1, xmm0
    movss [rsp + 4], xmm1
    mov dword [rsp + 8], 0
    mov dword [rsp + 12], 0
    mov dword [rsp + 16], 0
    xor ebx, ebx
.f:
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    cmp ebx, 0
    je .px
    cmp ebx, 1
    je .nx
    cmp ebx, 4
    je .pz
    cmp ebx, 5
    je .nz
    jmp .vis
.px:
    comiss xmm0, [f_zero]
    ja .vis
    jmp .hidden
.nx:
    comiss xmm0, [f_16]
    jb .vis
    jmp .hidden
.pz:
    comiss xmm1, [f_zero]
    ja .vis
    jmp .hidden
.nz:
    comiss xmm1, [f_16]
    jb .vis
    jmp .hidden
.vis:
    mov eax, [r15 + CI_FACECNT + rbx*4]
    cmp dword [set_renderer], REND_DLIST
    jne .run
    test eax, eax
    jz .adv
    add [stat_verts], eax
    mov edi, r14d
    shl edi, 3
    add edi, [dl_base]
    add edi, ebx
    call glCallList PLT
    jmp .adv
.run:
    cmp dword [rsp + 12], 0
    jne .extend
    mov ecx, [rsp + 16]
    mov [rsp + 8], ecx
.extend:
    add [rsp + 12], eax
    jmp .adv
.hidden:
    call .flush
.adv:
    mov eax, [r15 + CI_FACECNT + rbx*4]
    add [rsp + 16], eax
    inc ebx
    cmp ebx, 6
    jb .f
    call .flush
    LEAVE_FN
.flush:                             ; locals are at +8 inside this call
    mov ecx, [rsp + 8 + 12]
    test ecx, ecx
    jz .fl_out
    sub rsp, 8
    mov edi, r14d
    xor esi, esi
    mov edx, [rsp + 16 + 8]
    call draw_part
    add rsp, 8
    mov dword [rsp + 8 + 12], 0
.fl_out:
    ret

; Clouds: a flat layer of 12-node cells from 2D noise, drifting east,
; merged into strips per row. Drawn in node units.
; locals: [0] drift whole cells, [4] drift fraction (nodes), [8] radius,
;         [12] player cell x, [16] player cell z, [20] row j, [24] run start,
;         [28] i, [32] x0, [36] x1, [40] z0, [44] z1
draw_clouds:
    ENTER_FN 48
    cmp dword [set_clouds], 0
    je .out
    cmp dword [dimension], 0
    jne .out                        ; no clouds in the nether
    movsd xmm0, [t_now]
    cvtsd2ss xmm0, xmm0
    mulss xmm0, [f_cloud_drift]
    movaps xmm1, xmm0
    mulss xmm1, [f_cloud_inv]
    cvttss2si eax, xmm1
    mov [rsp], eax
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_cloud_cell]
    subss xmm0, xmm1
    movss [rsp + 4], xmm0
    mov eax, [set_range]
    shl eax, 4
    xor edx, edx
    mov ecx, CLOUD_CELL
    div ecx
    add eax, 2
    mov [rsp + 8], eax
    movss xmm0, [pos]
    mulss xmm0, [f_cloud_inv]
    cvttss2si eax, xmm0
    mov [rsp + 12], eax
    movss xmm0, [pos + 8]
    mulss xmm0, [f_cloud_inv]
    cvttss2si eax, xmm0
    mov [rsp + 16], eax

    call tint_begin
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_BLEND
    call glEnable PLT
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc PLT
    xor edi, edi
    call glDepthMask PLT
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_cloud_a]
    call glColor4f PLT
    mov edi, GL_QUADS
    call glBegin PLT
    mov eax, [rsp + 8]
    neg eax
    mov [rsp + 20], eax
.row:
    mov eax, [rsp + 20]
    cmp eax, [rsp + 8]
    jg .rows_done
    mov dword [rsp + 24], 0x7fffffff    ; no run
    mov eax, [rsp + 8]
    neg eax
    mov [rsp + 28], eax
.col:
    mov eax, [rsp + 28]
    xor ebx, ebx                    ; present?
    cmp eax, [rsp + 8]
    jg .have
    ; sample cell (player cell + i + drift, player cell z + j)
    add eax, [rsp + 12]
    add eax, [rsp]
    cvtsi2ss xmm0, eax
    mov eax, [rsp + 16]
    add eax, [rsp + 20]
    cvtsi2ss xmm1, eax
    lea rdi, [np_clouds]
    mov esi, [seed]
    call noise_fractal2d
    comiss xmm0, [f_cloud_thr]
    jbe .have
    mov ebx, 1
.have:
    cmp dword [rsp + 24], 0x7fffffff
    jne .inrun
    test ebx, ebx
    jz .cnext
    mov eax, [rsp + 28]
    mov [rsp + 24], eax
    jmp .cnext
.inrun:
    test ebx, ebx
    jnz .cnext
    ; emit cells [run start, i)
    mov eax, [rsp + 12]
    add eax, [rsp + 24]
    imul eax, eax, CLOUD_CELL
    mov ecx, [cur_pcx]
    shl ecx, 4
    sub eax, ecx
    cvtsi2ss xmm0, eax
    subss xmm0, [rsp + 4]
    movss [rsp + 32], xmm0
    mov eax, [rsp + 12]
    add eax, [rsp + 28]
    imul eax, eax, CLOUD_CELL
    sub eax, ecx
    cvtsi2ss xmm0, eax
    subss xmm0, [rsp + 4]
    movss [rsp + 36], xmm0
    mov eax, [rsp + 16]
    add eax, [rsp + 20]
    imul eax, eax, CLOUD_CELL
    mov ecx, [cur_pcz]
    shl ecx, 4
    sub eax, ecx
    cvtsi2ss xmm0, eax
    movss [rsp + 40], xmm0
    addss xmm0, [f_cloud_cell]
    movss [rsp + 44], xmm0
%macro CVERT 2
    movss xmm0, [rsp + %1]
    movss xmm1, [f_cloud_y]
    movss xmm2, [rsp + %2]
    call glVertex3f PLT
%endmacro
    CVERT 32, 40
    CVERT 36, 40
    CVERT 36, 44
    CVERT 32, 44
    add dword [stat_verts], 4
    mov dword [rsp + 24], 0x7fffffff
.cnext:
    mov eax, [rsp + 28]
    inc eax
    mov [rsp + 28], eax
    mov ecx, [rsp + 8]
    inc ecx
    cmp eax, ecx
    jle .col
    inc dword [rsp + 20]
    jmp .row
.rows_done:
    call glEnd PLT
    mov edi, 1
    call glDepthMask PLT
    mov edi, GL_BLEND
    call glDisable PLT
    call world_tex_end
    mov edi, GL_CULL_FACE
    call glEnable PLT
.out:
    LEAVE_FN

; selection box and digging cracks around the target, in node units
; locals: [0] target x, y, z relative, [16] vertex
draw_target:
    ENTER_FN 32
    cmp dword [target_hit], 0
    je .out
    mov eax, [cur_pcx]
    shl eax, 4
    mov ecx, [target]
    sub ecx, eax
    cvtsi2ss xmm0, ecx
    movss [rsp], xmm0
    cvtsi2ss xmm0, dword [target + 4]
    movss [rsp + 4], xmm0
    mov eax, [cur_pcz]
    shl eax, 4
    mov ecx, [target + 8]
    sub ecx, eax
    cvtsi2ss xmm0, ecx
    movss [rsp + 8], xmm0

    ; cracks
    mov eax, [dig_stage]
    test eax, eax
    js .outline
    cmp eax, 4
    jle .stage
    mov eax, 4
.stage:
    add eax, TILE_CRACK
    mov r12d, eax
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_atlas]
    call glBindTexture PLT
    mov edi, GL_BLEND
    call glEnable PLT
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc PLT
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_one]
    call glColor4f PLT
    mov edi, GL_QUADS
    call glBegin PLT
    lea r13, [crack_quads]
    xor ebx, ebx
.cv:
    ; texture coordinates in 1/16 node units (world texture matrix)
    movzx eax, byte [r13 + 3]
    shl eax, 4
    mov ecx, r12d
    and ecx, 15
    shl ecx, 7
    add eax, ecx
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_inv2048]
    movzx eax, byte [r13 + 4]
    shl eax, 4
    mov ecx, r12d
    shr ecx, 4
    shl ecx, 7
    add eax, ecx
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_inv1024]
    call glTexCoord2f PLT
    xor r14d, r14d
.ca:
    movzx eax, byte [r13 + r14]
    movss xmm0, [f_crk0]
    test eax, eax
    jz .c0
    movss xmm0, [f_crk1]
.c0:
    addss xmm0, [rsp + r14*4]
    movss [rsp + 16 + r14*4], xmm0
    inc r14d
    cmp r14d, 3
    jb .ca
    movss xmm0, [rsp + 16]
    movss xmm1, [rsp + 20]
    movss xmm2, [rsp + 24]
    call glVertex3f PLT
    add r13, 5
    inc ebx
    cmp ebx, 24
    jb .cv
    call glEnd PLT
    mov edi, GL_BLEND
    call glDisable PLT

.outline:
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    movss xmm3, [f_one]
    call glColor4f PLT
    movss xmm0, [f_two]
    call glLineWidth PLT
    mov edi, GL_LINES
    call glBegin PLT
    lea r12, [outline_edges]
    xor ebx, ebx
.v:
    xor r13d, r13d
.c:
    movzx eax, byte [r12 + r13]
    movss xmm0, [f_outl0]
    test eax, eax
    jz .e0
    movss xmm0, [f_outl1]
.e0:
    addss xmm0, [rsp + r13*4]
    movss [rsp + 16 + r13*4], xmm0
    inc r13d
    cmp r13d, 3
    jb .c
    movss xmm0, [rsp + 16]
    movss xmm1, [rsp + 20]
    movss xmm2, [rsp + 24]
    call glVertex3f PLT
    add r12, 3
    inc ebx
    cmp ebx, 24
    jb .v
    call glEnd PLT
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_one]
    call glColor4f PLT
.out:
    LEAVE_FN

; sky_colour - sky_rgb (and fog) from daylight, env_col = daylight
sky_colour:
    cmp dword [dimension], 0
    je .ow
    ; the nether: a dark red haze, nothing from daylight
    mov eax, 0x3f800000
    mov [env_col], eax
    mov [env_col + 4], eax
    mov [env_col + 8], eax
    mov [env_col + 12], eax
    mov [sky_rgb + 12], eax
    lea rax, [nether_col]
    cmp dword [eye_water], 2
    jne .nc
    lea rax, [lava_col]
.nc:
    mov ecx, [rax]
    mov [sky_rgb], ecx
    mov ecx, [rax + 4]
    mov [sky_rgb + 4], ecx
    mov ecx, [rax + 8]
    mov [sky_rgb + 8], ecx
    ret
.ow:
    movss xmm0, [sunlight]
    movss [env_col], xmm0
    movss [env_col + 4], xmm0
    movss [env_col + 8], xmm0
    mov dword [env_col + 12], 0x3f800000
    subss xmm0, [f_daymin]
    mulss xmm0, [f_dayspan]
    maxss xmm0, [f_zero]
    minss xmm0, [f_one]             ; k: 0 night .. 1 day
    xor ecx, ecx
.c:
    lea rax, [sky_col]
    movss xmm1, [rax + rcx*4]
    lea rax, [night_sky]
    movss xmm2, [rax + rcx*4]
    subss xmm1, xmm2
    mulss xmm1, xmm0
    addss xmm1, xmm2
    cmp dword [eye_water], 0
    je .st
    lea rax, [water_col]
    cmp dword [eye_water], 2
    jne .wc
    lea rax, [lava_col]
.wc:
    movss xmm1, [rax + rcx*4]
    movss xmm2, xmm0
    mulss xmm2, [f_half]
    addss xmm2, [f_half]
    mulss xmm1, xmm2
.st:
    lea rax, [sky_rgb]
    movss [rax + rcx*4], xmm1
    inc ecx
    cmp ecx, 3
    jb .c
    mov dword [sky_rgb + 12], 0x3f800000
    ret

; draw_sky - sun and moon on the east-west arc, before the camera moves
; locals: [0] cos t, [4] sin t, [8] size, [16] centre xyz, [32] colour ptr
draw_sky:
    ENTER_FN 48
    cmp dword [eye_water], 0
    jne .out
    cmp dword [dimension], 0
    jne .out                        ; no sun or moon in the nether
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, GL_DEPTH_TEST
    call glDisable PLT
    mov edi, GL_FOG
    call glDisable PLT
    movss xmm0, [tod]
    mulss xmm0, [f_2pi]
    movss [rsp + 8], xmm0
    fld dword [rsp + 8]
    fsincos
    fstp dword [rsp]
    fstp dword [rsp + 4]
    ; sun at +dir, moon at -dir
    mov r12d, 0
.body:
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    lea rax, [sun_rgb]
    movss xmm2, [f_sun_s]
    test r12d, r12d
    jz .pick
    xorps xmm3, xmm3
    subss xmm3, xmm0
    movaps xmm0, xmm3
    xorps xmm3, xmm3
    subss xmm3, xmm1
    movaps xmm1, xmm3
    lea rax, [moon_rgb]
    movss xmm2, [f_moon_s]
.pick:
    mov [rsp + 32], rax
    movss [rsp + 8], xmm2
    mulss xmm0, [f_sun_d]
    mulss xmm1, [f_sun_d]
    movss [rsp + 16], xmm0          ; centre x
    movss [rsp + 20], xmm1          ; centre y
    mov rax, [rsp + 32]
    movss xmm0, [rax]
    movss xmm1, [rax + 4]
    movss xmm2, [rax + 8]
    movss xmm3, [f_one]
    call glColor4f PLT
    mov edi, GL_QUADS
    call glBegin PLT
    ; corners: centre + up*(+-s) + z*(+-s); up = (-sin t, cos t, 0)
%macro SKYV 2                       ; up sign, z sign
    movss xmm0, [rsp + 4]
    mulss xmm0, [rsp + 8]
%if %1 > 0
    xorps xmm3, xmm3
    subss xmm3, xmm0
    movaps xmm0, xmm3
%endif
    addss xmm0, [rsp + 16]
    movss xmm1, [rsp]
    mulss xmm1, [rsp + 8]
%if %1 < 0
    xorps xmm3, xmm3
    subss xmm3, xmm1
    movaps xmm1, xmm3
%endif
    addss xmm1, [rsp + 20]
    movss xmm2, [rsp + 8]
%if %2 < 0
    xorps xmm3, xmm3
    subss xmm3, xmm2
    movaps xmm2, xmm3
%endif
    call glVertex3f PLT
%endmacro
    SKYV -1, -1
    SKYV -1, 1
    SKYV 1, 1
    SKYV 1, -1
    call glEnd PLT
    inc r12d
    cmp r12d, 2
    jb .body
    mov edi, GL_DEPTH_TEST
    call glEnable PLT
.out:
    LEAVE_FN

; draw_entities - dropped items, in node units relative to the player chunk
; locals: [0] size, [4] u0, [8] v0, [12] u1, [16] v1, [20] brightness,
;         [24] corner
draw_entities:
    ENTER_FN 48
    cmp dword [ent_count], 0
    je .out
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_ALPHA_TEST
    call glEnable PLT
    xor r12d, r12d
.e:
    cmp r12d, [ent_count]
    jae .done
    mov eax, r12d
    shl eax, 5
    lea rbx, [ents]
    add rbx, rax
    ; brightness from the light where it lies
    movss xmm0, [rbx]
    cvttss2si edi, xmm0
    movss xmm0, [rbx + 4]
    addss xmm0, [f_ent_lift]
    cvttss2si esi, xmm0
    movss xmm0, [rbx + 8]
    cvttss2si edx, xmm0
    call light_get
    mov ecx, eax
    and eax, 15
    shr ecx, 4
    lea rdx, [light_curve]
    movzx eax, byte [rdx + rax]
    movzx ecx, byte [rdx + rcx]
    cvtsi2ss xmm0, eax
    mulss xmm0, [sunlight]
    cvtsi2ss xmm1, ecx
    maxss xmm0, xmm1
    mulss xmm0, [f_inv255]
    movss [rsp + 20], xmm0
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    movss xmm3, [f_one]
    call glColor4f PLT
    call glPushMatrix PLT
    mov eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm0, [rbx]
    subss xmm0, xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm1, eax
    movss xmm2, [rbx + 8]
    subss xmm2, xmm1
    movss xmm1, [rbx + 4]
    addss xmm1, [f_ent_lift]
    call glTranslatef PLT
    movzx r13d, byte [rbx + 24]     ; item
    ; fences and gates show their picture (icons after the items)
    cmp r13d, B_FENCE
    jne .ngate
    mov r13d, I_END
    jmp .icon
.ngate:
    cmp r13d, B_GATE_X
    jne .ndyem
    mov r13d, I_END + 1
    jmp .icon
.ndyem:
    cmp r13d, B_DYEMAKER
    jne .nfence
    mov r13d, I_END + 2
    jmp .icon
.nfence:
    cmp r13d, I_FIRST
    jae .icon
    ; ---- block: a small spinning cube
    movss xmm0, [rbx + 28]
    mulss xmm0, [f_ent_spin]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_atlas]
    call glBindTexture PLT
    lea rax, [block_tiles]
    movzx eax, byte [rax + r13*4 + 1]
    mov ecx, eax
    and ecx, 15
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_tile_u]
    movss [rsp + 4], xmm0
    addss xmm0, [f_rep_u]
    movss [rsp + 12], xmm0
    shr eax, 4
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_tile_v]
    movss [rsp + 8], xmm0
    addss xmm0, [f_rep_v]
    movss [rsp + 16], xmm0
    mov edi, GL_QUADS
    call glBegin PLT
    lea r14, [crack_quads]
    xor r15d, r15d
.cv:
    movss xmm0, [rsp + 4]
    cmp byte [r14 + 3], 0
    je .cu
    movss xmm0, [rsp + 12]
.cu:
    movss xmm1, [rsp + 8]
    cmp byte [r14 + 4], 0
    je .cvv
    movss xmm1, [rsp + 16]
.cvv:
    call glTexCoord2f PLT
%macro ECOORD 2                     ; byte offset, xmm register
    movss %2, [f_ent_half]
    cmp byte [r14 + %1], 0
    jne %%p
    xorps xmm7, xmm7
    subss xmm7, %2
    movaps %2, xmm7
%%p:
%endmacro
    ECOORD 0, xmm0
    ECOORD 1, xmm1
    ECOORD 2, xmm2
    call glVertex3f PLT
    add r14, 5
    inc r15d
    cmp r15d, 24
    jb .cv
    call glEnd PLT
    jmp .pop
.icon:
    ; ---- item: a flat icon turned to face the camera
    movss xmm0, [yaw]
    mulss xmm0, [f_rad2deg]
    xorps xmm3, xmm3
    subss xmm3, xmm0
    movaps xmm0, xmm3
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_icons]
    call glBindTexture PLT
    lea eax, [r13 - I_FIRST]
    mov ecx, eax
    and ecx, 15
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_icon_u]
    movss [rsp + 4], xmm0
    addss xmm0, [f_icon_u]
    movss [rsp + 12], xmm0
    shr eax, 4
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_icon_v]
    movss [rsp + 8], xmm0
    addss xmm0, [f_icon_v]
    movss [rsp + 16], xmm0
    mov edi, GL_QUADS
    call glBegin PLT
%macro IVERT 4                      ; u, v offsets, x sign, y sign
    movss xmm0, [rsp + %1]
    movss xmm1, [rsp + %2]
    call glTexCoord2f PLT
    movss xmm0, [f_ent_lift]
%if %3 < 0
    xorps xmm7, xmm7
    subss xmm7, xmm0
    movaps xmm0, xmm7
%endif
    movss xmm1, [f_ent_lift]
%if %4 < 0
    xorps xmm7, xmm7
    subss xmm7, xmm1
    movaps xmm1, xmm7
%endif
    xorps xmm2, xmm2
    call glVertex3f PLT
%endmacro
    IVERT 4, 16, -1, -1
    IVERT 12, 16, 1, -1
    IVERT 12, 8, 1, 1
    IVERT 4, 8, -1, 1
    call glEnd PLT
.pop:
    call glPopMatrix PLT
    inc r12d
    jmp .e
.done:
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_CULL_FACE
    call glEnable PLT
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_one]
    call glColor4f PLT
.out:
    LEAVE_FN

; void render_world(void)
; locals: [0] eye x local, [4] eye y, [8] eye z local, [16] aspect (double),
;         [24] scratch, [32] count
render_world:
    ENTER_FN 48
    mov dword [stat_verts], 0
    call view_size                  ; (smaller than the screen: scaled up after)
    xor edi, edi
    xor esi, esi
    mov edx, [view_w]
    mov ecx, [view_h]
    call glViewport PLT
    call sky_colour
    movss xmm0, [sky_rgb]
    movss xmm1, [sky_rgb + 4]
    movss xmm2, [sky_rgb + 8]
    movss xmm3, [f_one]
    call glClearColor PLT
    mov edi, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT
    call glClear PLT

    ; projection from the field of view setting
    cvtsi2ss xmm0, dword [set_fov]
    mulss xmm0, [f_deg2rad_half]
    movss [rsp + 24], xmm0
    fld dword [rsp + 24]
    fptan
    fstp st0
    fstp dword [tan_v]
    mov edi, GL_PROJECTION
    call glMatrixMode PLT
    call glLoadIdentity PLT
    cvtsi2sd xmm4, dword [win_w]
    mov eax, [win_h]
    test eax, eax
    jnz .h_ok
    inc eax
.h_ok:
    cvtsi2sd xmm5, eax
    divsd xmm4, xmm5
    movsd [rsp + 16], xmm4
    cvtss2sd xmm3, [tan_v]
    mulsd xmm3, [d_near]            ; top
    movsd xmm1, xmm3
    mulsd xmm1, xmm4                ; right
    movsd xmm0, [d_zero]
    subsd xmm0, xmm1
    movsd xmm2, [d_zero]
    subsd xmm2, xmm3
    movsd xmm4, [d_near]
    movsd xmm5, [d_far]
    call glFrustum PLT
    movsd xmm0, [rsp + 16]
    cvtsd2ss xmm0, xmm0
    mulss xmm0, [tan_v]
    movss [tan_h], xmm0

    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    call glLoadIdentity PLT
    movss xmm0, [pitch]
    mulss xmm0, [f_rad2deg]
    movss xmm1, [f_one]
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [yaw]
    mulss xmm0, [f_rad2deg]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    call draw_sky
    mov eax, [cur_pcx]
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [pos]
    subss xmm1, xmm0
    movss [rsp], xmm1
    movss xmm1, [pos + 4]
    addss xmm1, [f_eye]
    movss [rsp + 4], xmm1
    mov eax, [cur_pcz]
    shl eax, 4
    cvtsi2ss xmm0, eax
    movss xmm1, [pos + 8]
    subss xmm1, xmm0
    movss [rsp + 8], xmm1
    xorps xmm0, xmm0
    subss xmm0, [rsp]
    xorps xmm1, xmm1
    subss xmm1, [rsp + 4]
    xorps xmm2, xmm2
    subss xmm2, [rsp + 8]
    call glTranslatef PLT

    ; fog: fades the far edge of the world (off by setting, always on
    ; underwater); with the horizon on it reaches out to the horizon
    mov edi, GL_FOG
    call glDisable PLT
    cmp dword [eye_water], 0
    jne .fog_on
    cmp dword [dimension], 0
    jne .fog_on
    cmp dword [set_fog], 0
    je .fog_done
.fog_on:
    mov edi, GL_FOG
    call glEnable PLT
    mov edi, GL_FOG_COLOR
    lea rsi, [sky_rgb]
    call glFogfv PLT
    cvtsi2ss xmm0, dword [set_range]
    mulss xmm0, [f_16]
    movaps xmm2, xmm0               ; edge of the real chunks
    cvtsi2ss xmm1, dword [horizon_dist]
    maxss xmm0, xmm1
    movss [rsp + 24], xmm0
    movaps xmm1, xmm0
    mulss xmm1, [f_fogs]
    ; with the horizon on, haze starts where the real chunks end
    cmp dword [horizon_dist], 0
    je .fog_hz
    minss xmm1, xmm2
.fog_hz:
    cmp dword [eye_water], 0
    jne .fog_eye
    cmp dword [dimension], 0
    je .fog
    movss xmm1, [f_nfog0]
    movss xmm0, [f_nfog1]
    movss [rsp + 24], xmm0
    jmp .fog
.fog_eye:
    xorps xmm1, xmm1
    movss xmm0, [f_fogw1]
    cmp dword [eye_water], 2
    jne .fogw
    movss xmm0, [f_fogl1]
.fogw:
    movss [rsp + 24], xmm0
.fog:
    movaps xmm0, xmm1
    mov edi, GL_FOG_START
    call glFogf PLT
    movss xmm0, [rsp + 24]
    mov edi, GL_FOG_END
    call glFogf PLT
.fog_done:

    mov edi, GL_DEPTH_TEST
    call glEnable PLT
    mov edi, GL_CULL_FACE
    call glEnable PLT
    mov edi, GL_ALPHA_TEST
    call glEnable PLT
    call world_tex_begin
    movss xmm0, [f_eighth]
    movss xmm1, [f_eighth]
    movss xmm2, [f_eighth]
    call glScalef PLT
    call cull_chunks

    ; ---- opaque pass
    xor ebx, ebx
.o:
    cmp ebx, [spiral_n]
    jae .o_done
    lea rax, [vis]
    cmp byte [rax + rbx], 0
    je .o_next
    lea rax, [spiral]
    mov r12d, [rax + rbx*8]
    mov r13d, [rax + rbx*8 + 4]
    mov edi, [cur_pcx]
    add edi, r12d
    mov esi, [cur_pcz]
    add esi, r13d
    call world_find
    test eax, eax
    js .o_next
    mov r14d, eax
    call push_chunk
    call draw_surface
    ; cave geometry only close by
    mov eax, r12d
    imul eax, eax
    mov ecx, r13d
    imul ecx, ecx
    add eax, ecx
    cmp eax, DEEP_RANGE * DEEP_RANGE + DEEP_RANGE
    ja .o_pop
    mov eax, r14d
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    mov ecx, [rcx + rax + CI_NDEEP]
    test ecx, ecx
    jz .o_pop
    mov edi, r14d
    mov esi, 1
    xor edx, edx
    call draw_part
.o_pop:
    call glPopMatrix PLT
.o_next:
    inc ebx
    jmp .o
.o_done:
    call unbind_vbo
    call world_tex_end

    ; far terrain beyond the real chunks
    call horizon_draw

    ; clouds in node units
    call glPushMatrix PLT
    movss xmm0, [f_8]
    movss xmm1, [f_8]
    movss xmm2, [f_8]
    call glScalef PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    call draw_clouds
    call glPopMatrix PLT

    ; ---- water pass
    call world_tex_begin
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_BLEND
    call glEnable PLT
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc PLT
    xor edi, edi
    call glDepthMask PLT
    xor ebx, ebx
.w:
    cmp ebx, [spiral_n]
    jae .w_done
    lea rax, [vis]
    cmp byte [rax + rbx], 0
    je .w_next
    lea rax, [spiral]
    mov r12d, [rax + rbx*8]
    mov r13d, [rax + rbx*8 + 4]
    mov edi, [cur_pcx]
    add edi, r12d
    mov esi, [cur_pcz]
    add esi, r13d
    call world_find
    test eax, eax
    js .w_next
    mov r14d, eax
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    mov ecx, [rcx + rax + CI_NWAT]
    test ecx, ecx
    jz .w_next
    mov [rsp + 32], ecx
    call push_chunk
    mov edi, r14d
    mov esi, 2
    xor edx, edx
    mov ecx, [rsp + 32]
    call draw_part
    call glPopMatrix PLT
.w_next:
    inc ebx
    jmp .w
.w_done:
    mov edi, 1
    call glDepthMask PLT
    mov edi, GL_BLEND
    call glDisable PLT
    mov edi, GL_CULL_FACE
    call glEnable PLT
    call unbind_vbo
    call world_tex_end

    call glPushMatrix PLT
    movss xmm0, [f_8]
    movss xmm1, [f_8]
    movss xmm2, [f_8]
    call glScalef PLT
    call draw_entities
    call draw_mobs
    call draw_boats
    call draw_tnt
    call draw_fireballs
    call beacon_draw
    call draw_target
    call glPopMatrix PLT
    mov eax, [stat_verts]
    mov [stat_count], eax
    call draw_viewmodel             ; a rifle in the hands, over the world
    call upscale_view
    LEAVE_FN

; view_size - the size the world is drawn at: the whole window, or on
; Windows (always the whole screen) the width the WINDOW setting picks
; (640, 800, 1024; same shape as the screen), stretched to the screen
; afterwards - far fewer pixels for a slow graphics chip
view_size:
    mov eax, [win_w]
    mov ecx, [win_h]
    mov [view_w], eax
    mov [view_h], ecx
%ifdef VOXASM_WIN
    mov edx, [set_window]
    lea r8, [view_widths]
    mov r8d, [r8 + rdx*4]           ; the width wanted
    cmp r8d, eax
    jge .out                        ; that wide or more: the whole screen
    cmp r8d, SCALE_TEX
    jg .out
    mov eax, ecx                    ; height: the screen's shape
    imul eax, r8d
    cdq
    idiv dword [win_w]
    cmp eax, SCALE_TEX
    jg .out
    mov [view_w], r8d
    mov [view_h], eax
.out:
%endif
    ret

; upscale_view - the world drawn smaller than the screen: copy it into a
; texture and stretch that over the whole screen (the HUD is drawn after,
; at full size)
upscale_view:
%ifdef VOXASM_WIN
    ENTER_FN 0
    mov eax, [view_w]
    cmp eax, [win_w]
    jge .out
    cmp dword [scale_tex], 0
    jne .have
    mov edi, 1
    lea rsi, [scale_tex]
    call glGenTextures PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [scale_tex]
    call glBindTexture PLT
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_LINEAR
    call glTexParameteri PLT
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_LINEAR
    call glTexParameteri PLT
    sub rsp, 32
    mov edi, GL_TEXTURE_2D          ; empty, power of two (old chips)
    xor esi, esi
    mov edx, GL_RGB
    mov ecx, SCALE_TEX
    mov r8d, SCALE_TEX
    xor r9d, r9d
    mov qword [rsp], GL_RGB
    mov qword [rsp + 8], GL_UNSIGNED_BYTE
    mov qword [rsp + 16], 0
    call glTexImage2D PLT
    add rsp, 32
.have:
    call hud_begin                  ; the whole screen, pixels, blending
    mov edi, GL_BLEND
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [scale_tex]
    call glBindTexture PLT
    sub rsp, 16
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    mov eax, [view_w]
    mov [rsp], rax
    mov eax, [view_h]
    mov [rsp + 8], rax
    call glCopyTexSubImage2D PLT
    add rsp, 16
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_one]
    call glColor4f PLT
    ; texture corners: (0, 0) .. (w, h) of SCALE_TEX; the image is upside
    ; down to the HUD's y-down pixels
    cvtsi2ss xmm0, dword [view_w]
    mulss xmm0, [f_inv_scale]
    movss [scale_u], xmm0
    cvtsi2ss xmm0, dword [view_h]
    mulss xmm0, [f_inv_scale]
    movss [scale_v], xmm0
    mov edi, GL_QUADS
    call glBegin PLT
%macro SQV 4                        ; u, v, x, y (memory or zero)
    movss xmm0, %1
    movss xmm1, %2
    call glTexCoord2f PLT
    movss xmm0, %3
    movss xmm1, %4
    call glVertex2f PLT
%endmacro
    cvtsi2ss xmm0, dword [win_w]
    movss [scale_sw], xmm0
    cvtsi2ss xmm0, dword [win_h]
    movss [scale_sh], xmm0
    SQV [f_zero], [scale_v], [f_zero], [f_zero]
    SQV [scale_u], [scale_v], [scale_sw], [f_zero]
    SQV [scale_u], [f_zero], [scale_sw], [scale_sh]
    SQV [f_zero], [f_zero], [f_zero], [scale_sh]
    call glEnd PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
.out:
    LEAVE_FN
%else
    ret
%endif

; ---------------------------------------------------------------------------
; HUD helpers (2D, pixel coordinates, y down)

; void hud_begin(void) - ortho projection, identity texture matrix, blending
hud_begin:
    sub rsp, 8
    mov edi, GL_FOG
    call glDisable PLT
    mov edi, GL_DEPTH_TEST
    call glDisable PLT
    mov edi, GL_CULL_FACE
    call glDisable PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    xor edi, edi
    xor esi, esi
    mov edx, [win_w]
    mov ecx, [win_h]
    call glViewport PLT
    mov edi, GL_TEXTURE
    call glMatrixMode PLT
    call glLoadIdentity PLT
    mov edi, GL_PROJECTION
    call glMatrixMode PLT
    call glLoadIdentity PLT
    movsd xmm0, [d_zero]
    cvtsi2sd xmm1, dword [win_w]
    cvtsi2sd xmm2, dword [win_h]
    movsd xmm3, [d_zero]
    movsd xmm4, [d_m1]
    movsd xmm5, [d_one]
    call glOrtho PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    call glLoadIdentity PLT
    mov edi, GL_BLEND
    call glEnable PLT
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc PLT
    add rsp, 8
    ret

; hud_rect(x0, y0, x1, y1 in xmm0..3, edi rgba packed 0xAABBGGRR)
hud_rect:
    sub rsp, 24
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    mov eax, edi
    movzx edi, al
    movzx esi, ah
    shr eax, 16
    movzx edx, al
    movzx ecx, ah
    call glColor4ub PLT
    mov edi, GL_QUADS
    call glBegin PLT
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    call glVertex2f PLT
    movss xmm0, [rsp + 8]
    movss xmm1, [rsp + 4]
    call glVertex2f PLT
    movss xmm0, [rsp + 8]
    movss xmm1, [rsp + 12]
    call glVertex2f PLT
    movss xmm0, [rsp]
    movss xmm1, [rsp + 12]
    call glVertex2f PLT
    call glEnd PLT
    add rsp, 24
    ret

; hud_text(x, y, scale in xmm0..2, rdi text, esi rgba)
hud_text:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    mov r12, rdi
    mov eax, esi
    movzx edi, al
    movzx esi, ah
    shr eax, 16
    movzx edx, al
    movzx ecx, ah
    call glColor4ub PLT
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_font]
    call glBindTexture PLT
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, [rsp + 8]
    mov rdi, r12
    call text_draw
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    LEAVE_FN

; hud_text_center(y xmm0, scale xmm1, rdi text, esi rgba)
hud_text_center:
    ENTER_FN 16
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    mov r12, rdi
    mov r13d, esi
    movaps xmm0, xmm1
    call text_width
    cvtsi2ss xmm1, dword [win_w]
    subss xmm1, xmm0
    mulss xmm1, [f_half]
    movaps xmm0, xmm1
    movss xmm1, [rsp]
    movss xmm2, [rsp + 4]
    mov rdi, r12
    mov esi, r13d
    call hud_text
    LEAVE_FN

; hud_tile(x, y, size in xmm0..2, edi tile) - one repeat of an atlas tile
hud_tile:
    ENTER_FN 48
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    addss xmm0, xmm2
    addss xmm1, xmm2
    movss [rsp + 8], xmm0
    movss [rsp + 12], xmm1
    mov eax, edi
    and eax, 15
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_tile_u]
    movss [rsp + 16], xmm0
    addss xmm0, [f_rep_u]
    movss [rsp + 20], xmm0
    mov eax, edi
    shr eax, 4
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_tile_v]
    movss [rsp + 24], xmm0
    addss xmm0, [f_rep_v]
    movss [rsp + 28], xmm0
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_atlas]
    call glBindTexture PLT
    mov edi, GL_ALPHA_TEST
    call glEnable PLT
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_one]
    call glColor4f PLT
    mov edi, GL_QUADS
    call glBegin PLT
%macro TVERT 4                      ; u, v, x, y offsets
    movss xmm0, [rsp + %1]
    movss xmm1, [rsp + %2]
    call glTexCoord2f PLT
    movss xmm0, [rsp + %3]
    movss xmm1, [rsp + %4]
    call glVertex2f PLT
%endmacro
    TVERT 16, 24, 0, 4
    TVERT 20, 24, 8, 4
    TVERT 20, 28, 8, 12
    TVERT 16, 28, 0, 12
    call glEnd PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    LEAVE_FN

; hud_item(x, y, size in xmm0..2, edi slot dword, esi show count)
; Block items show their side texture, other items their icon; tools with
; wear get a durability bar.
; locals: [0] x, [4] y, [8] size, [12] slot, [16] show count, [20..36] uv
hud_item:
    ENTER_FN 48
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    mov [rsp + 12], edi
    mov [rsp + 16], esi
    movzx eax, dil
    test eax, eax
    jz .out
    ; fences and gates show their picture (icons after the items)
    cmp eax, B_FENCE
    jne .ngate
    mov eax, I_END
    jmp .icon
.ngate:
    cmp eax, B_GATE_X
    jne .ndyem
    mov eax, I_END + 1
    jmp .icon
.ndyem:
    cmp eax, B_DYEMAKER
    jne .nfence
    mov eax, I_END + 2
    jmp .icon
.nfence:
    cmp eax, I_FIRST
    jae .icon
    lea rcx, [block_tiles]
    movzx edi, byte [rcx + rax*4 + 1]
    call hud_tile
    jmp .count
.icon:
    sub eax, I_FIRST
    mov ecx, eax
    and ecx, 15
    cvtsi2ss xmm0, ecx
    mulss xmm0, [f_icon_u]
    movss [rsp + 20], xmm0
    addss xmm0, [f_icon_u]
    movss [rsp + 24], xmm0
    shr eax, 4
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_icon_v]
    movss [rsp + 28], xmm0
    addss xmm0, [f_icon_v]
    movss [rsp + 32], xmm0
    mov edi, GL_TEXTURE_2D
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    mov esi, [tex_icons]
    call glBindTexture PLT
    mov edi, GL_ALPHA_TEST
    call glEnable PLT
    movss xmm0, [f_one]
    movss xmm1, [f_one]
    movss xmm2, [f_one]
    movss xmm3, [f_one]
    call glColor4f PLT
    mov edi, GL_QUADS
    call glBegin PLT
%macro HVERT 4                      ; u, v offsets, x far?, y far?
    movss xmm0, [rsp + %1]
    movss xmm1, [rsp + %2]
    call glTexCoord2f PLT
    movss xmm0, [rsp]
%if %3
    addss xmm0, [rsp + 8]
%endif
    movss xmm1, [rsp + 4]
%if %4
    addss xmm1, [rsp + 8]
%endif
    call glVertex2f PLT
%endmacro
    HVERT 20, 28, 0, 0
    HVERT 24, 28, 1, 0
    HVERT 24, 32, 1, 1
    HVERT 20, 32, 0, 1
    call glEnd PLT
    mov edi, GL_ALPHA_TEST
    call glDisable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
.count:
    cmp dword [rsp + 16], 0
    je .wear
    mov ecx, [rsp + 12]
    shr ecx, 8
    and ecx, 0xff
    cmp ecx, 1
    jbe .wear
    lea rdi, [text_buf]
    mov esi, 16
    lea rdx, [s_count]
    xor eax, eax
    call snprintf PLT
    ; right-aligned in the bottom corner, with a shadow
    lea rdi, [text_buf]
    movss xmm0, [f_two]
    call text_width
    movss xmm1, [rsp]
    addss xmm1, [rsp + 8]
    addss xmm1, [f_two]
    subss xmm1, xmm0
    movss [rsp + 36], xmm1          ; x
    movss xmm1, [rsp + 4]
    addss xmm1, [rsp + 8]
    subss xmm1, [f_count_h]
    movss [rsp + 40], xmm1          ; y
    movss xmm0, [rsp + 36]
    addss xmm0, [f_two]
    movss xmm1, [rsp + 40]
    addss xmm1, [f_two]
    movss xmm2, [f_two]
    lea rdi, [text_buf]
    mov esi, 0xff3f3f3f
    call hud_text
    movss xmm0, [rsp + 36]
    movss xmm1, [rsp + 40]
    movss xmm2, [f_two]
    lea rdi, [text_buf]
    mov esi, 0xffffffff
    call hud_text
.wear:
    mov eax, [rsp + 12]
    shr eax, 16
    jz .out
    movzx edi, byte [rsp + 12]
    call tool_of
    test ecx, ecx
    jz .out
    lea rcx, [tier_durab]
    cvtsi2ss xmm1, dword [rcx + rax*4]
    mov eax, [rsp + 12]
    shr eax, 16
    cvtsi2ss xmm0, eax
    divss xmm0, xmm1
    movss xmm1, [f_one]
    subss xmm1, xmm0
    mulss xmm1, [rsp + 8]
    movss [rsp + 20], xmm1          ; bar length
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    addss xmm1, [rsp + 8]
    subss xmm1, [f_hud3]
    movaps xmm2, xmm0
    addss xmm2, [rsp + 8]
    movaps xmm3, xmm1
    addss xmm3, [f_two]
    mov edi, 0xff000000
    call hud_rect
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    addss xmm1, [rsp + 8]
    subss xmm1, [f_hud3]
    movaps xmm2, xmm0
    addss xmm2, [rsp + 20]
    movaps xmm3, xmm1
    addss xmm3, [f_two]
    mov edi, 0xff20d020
    call hud_rect
.out:
    LEAVE_FN

; void draw_hud(void) - in-game overlay
; locals: [0] centre x, [4] centre y, [8] hotbar x, [12] hotbar y, [16] x
draw_hud:
    ENTER_FN 32
    call hud_begin
    cvtsi2ss xmm0, dword [win_w]
    mulss xmm0, [f_half]
    movss [rsp], xmm0
    cvtsi2ss xmm0, dword [win_h]
    mulss xmm0, [f_half]
    movss [rsp + 4], xmm0

    ; underwater tint and damage flash
    cmp dword [eye_water], 0
    je .notint
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [win_w]
    cvtsi2ss xmm3, dword [win_h]
    mov edi, 0x5a99401a
    cmp dword [eye_water], 2
    jne .tint
    mov edi, 0xa01060f0             ; in lava: orange
.tint:
    call hud_rect
.notint:
    ; standing in a portal: the screen turns purple
    movss xmm0, [portal_t]
    comiss xmm0, [f_zero]
    jbe .noportal
    divss xmm0, [portal_need]
    minss xmm0, [f_one]
    mulss xmm0, [f_200]
    cvttss2si eax, xmm0
    shl eax, 24
    or eax, 0x00c0208c              ; purple (0xAABBGGRR)
    mov edi, eax
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [win_w]
    cvtsi2ss xmm3, dword [win_h]
    call hud_rect
.noportal:
    ; an explosion nearby: a white flash
    movss xmm0, [boom_t]
    comiss xmm0, [f_zero]
    jbe .noboom
    mulss xmm0, [f_255]
    cvttss2si eax, xmm0
    shl eax, 24
    or eax, 0x00ffffff
    mov edi, eax
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [win_w]
    cvtsi2ss xmm3, dword [win_h]
    call hud_rect
.noboom:
    movss xmm0, [hurt_flash]
    comiss xmm0, [f_zero]
    jbe .nohurt
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [win_w]
    cvtsi2ss xmm3, dword [win_h]
    mov edi, 0x500000d0
    call hud_rect
.nohurt:

    ; crosshair, colour-inverting
    mov edi, GL_ONE_MINUS_DST_COLOR
    xor esi, esi
    call glBlendFunc PLT
    movss xmm0, [rsp]
    subss xmm0, [f_hud10]
    movss xmm1, [rsp + 4]
    subss xmm1, [f_one]
    movss xmm2, [rsp]
    addss xmm2, [f_hud10]
    movss xmm3, [rsp + 4]
    addss xmm3, [f_one]
    mov edi, 0xffffffff
    call hud_rect
    movss xmm0, [rsp]
    subss xmm0, [f_one]
    movss xmm1, [rsp + 4]
    subss xmm1, [f_hud10]
    movss xmm2, [rsp]
    addss xmm2, [f_one]
    movss xmm3, [rsp + 4]
    subss xmm3, [f_one]
    mov edi, 0xffffffff
    call hud_rect
    movss xmm0, [rsp]
    subss xmm0, [f_one]
    movss xmm1, [rsp + 4]
    addss xmm1, [f_one]
    movss xmm2, [rsp]
    addss xmm2, [f_one]
    movss xmm3, [rsp + 4]
    addss xmm3, [f_hud10]
    mov edi, 0xffffffff
    call hud_rect
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc PLT

    ; hotbar
    movss xmm0, [rsp]
    subss xmm0, [f_hud212]
    movss [rsp + 8], xmm0
    cvtsi2ss xmm0, dword [win_h]
    subss xmm0, [f_hud56]
    movss [rsp + 12], xmm0
    xor ebx, ebx
.slot:
    cvtsi2ss xmm0, ebx
    mulss xmm0, [f_hud48]
    addss xmm0, [rsp + 8]
    movss [rsp + 16], xmm0
    cmp ebx, [sel_slot]
    jne .unsel
    movss xmm0, [rsp + 16]
    subss xmm0, [f_hud3]
    movss xmm1, [rsp + 12]
    subss xmm1, [f_hud3]
    movss xmm2, [rsp + 16]
    addss xmm2, [f_hud43]
    movss xmm3, [rsp + 12]
    addss xmm3, [f_hud43]
    mov edi, 0xe6ffffff
    call hud_rect
.unsel:
    movss xmm0, [rsp + 16]
    movss xmm1, [rsp + 12]
    movaps xmm2, xmm0
    addss xmm2, [f_hud40]
    movaps xmm3, xmm1
    addss xmm3, [f_hud40]
    mov edi, 0x80000000
    call hud_rect
    movss xmm0, [rsp + 16]
    addss xmm0, [f_hud4]
    movss xmm1, [rsp + 12]
    addss xmm1, [f_hud4]
    movss xmm2, [f_hud32]
    lea rax, [inv]
    mov edi, [rax + rbx*4]
    xor esi, esi
    cmp dword [game_mode], 0
    sete sil                        ; counts only matter in survival
    call hud_item
.snext:
    inc ebx
    cmp ebx, 9
    jb .slot

    ; health and breath (survival)
    cmp dword [game_mode], 0
    jne .nohealth
    xor ebx, ebx
.heart:
    cvtsi2ss xmm0, ebx
    mulss xmm0, [f_hud16]
    addss xmm0, [rsp + 8]
    movss [rsp + 16], xmm0
    movss xmm1, [rsp + 12]
    subss xmm1, [f_hud22]
    movaps xmm2, xmm0
    addss xmm2, [f_hud14]
    movss xmm3, [rsp + 12]
    subss xmm3, [f_hud10]
    subss xmm3, [f_two]
    mov edi, 0xb4000040             ; empty heart
    call hud_rect
    lea eax, [rbx*2 + 1]
    cmp [hp], eax
    jl .hnext
    movss xmm0, [rsp + 16]
    movss xmm1, [rsp + 12]
    subss xmm1, [f_hud22]
    movaps xmm2, xmm0
    addss xmm2, [f_hud14]
    lea eax, [rbx*2 + 2]
    cmp [hp], eax
    jge .full
    movaps xmm2, xmm0               ; half heart
    addss xmm2, [f_hud4]
    addss xmm2, [f_hud3]
.full:
    movss xmm3, [rsp + 12]
    subss xmm3, [f_hud10]
    subss xmm3, [f_two]
    mov edi, 0xff1e1edc
    call hud_rect
.hnext:
    inc ebx
    cmp ebx, 10
    jb .heart
    ; armour over the hearts: 10 plates of 2 points (grey; half: half)
    call armor_points
    test eax, eax
    jz .noarmor
    mov r12d, eax
    xor ebx, ebx
.plate:
    cvtsi2ss xmm0, ebx
    mulss xmm0, [f_hud16]
    addss xmm0, [rsp + 8]
    movss [rsp + 16], xmm0
    movss xmm1, [rsp + 12]
    subss xmm1, [f_hud22]
    subss xmm1, [f_armor_dy]
    movaps xmm2, xmm0
    addss xmm2, [f_hud14]
    movss xmm3, [rsp + 12]
    subss xmm3, [f_hud10]
    subss xmm3, [f_two]
    subss xmm3, [f_armor_dy]
    mov edi, 0xb4202020             ; empty
    call hud_rect
    lea eax, [rbx*2 + 1]
    cmp r12d, eax
    jl .pnext
    movss xmm0, [rsp + 16]
    movss xmm1, [rsp + 12]
    subss xmm1, [f_hud22]
    subss xmm1, [f_armor_dy]
    movaps xmm2, xmm0
    addss xmm2, [f_hud14]
    lea eax, [rbx*2 + 2]
    cmp r12d, eax
    jge .pfull
    movaps xmm2, xmm0
    addss xmm2, [f_hud4]
    addss xmm2, [f_hud3]
.pfull:
    movss xmm3, [rsp + 12]
    subss xmm3, [f_hud10]
    subss xmm3, [f_two]
    subss xmm3, [f_armor_dy]
    mov edi, 0xffd2d2d2
    call hud_rect
.pnext:
    inc ebx
    cmp ebx, 10
    jb .plate
.noarmor:
    ; breath bubbles while underwater or refilling
    cmp dword [breath], 10
    jae .nohealth
    xor ebx, ebx
.bub:
    cmp ebx, [breath]
    jae .nohealth
    mov eax, 9
    sub eax, ebx
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_hud16]
    addss xmm0, [rsp + 8]
    addss xmm0, [f_hud212]
    addss xmm0, [f_hud212]
    subss xmm0, [f_hud14]
    subss xmm0, [f_hud14]
    movss xmm1, [rsp + 12]
    subss xmm1, [f_hud22]
    movaps xmm2, xmm0
    addss xmm2, [f_hud14]
    movss xmm3, [rsp + 12]
    subss xmm3, [f_hud10]
    subss xmm3, [f_two]
    mov edi, 0xfff08c3c
    call hud_rect
    inc ebx
    jmp .bub
.nohealth:

    ; frame counter
    cmp dword [set_showfps], 0
    je .nofps
    ; "FPS n  VERTS nK  XYZ x y z": y and z go on the stack
    mov eax, [stat_count]
    add eax, 500
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov r8d, eax                    ; vertices, thousands
    movss xmm0, [pos]
    cvttss2si r9d, xmm0
    sub rsp, 16
    movss xmm0, [pos + 4]
    cvttss2si eax, xmm0
    movsxd rax, eax
    mov [rsp], rax
    movss xmm0, [pos + 8]
    cvttss2si eax, xmm0
    movsxd rax, eax
    mov [rsp + 8], rax
    lea rdi, [text_buf]
    mov esi, 128
    lea rdx, [s_fpsfmt]
    mov ecx, [fps]
    xor eax, eax
    call snprintf PLT
    add rsp, 16
    movss xmm0, [f_hud4]
    movss xmm1, [f_hud4]
    movss xmm2, [f_two]
    lea rdi, [text_buf]
    mov esi, 0xffffffff
    call hud_text
.nofps:
    ; the held item's name over the hotbar for 2 s after it changes
    ; (another slot or another item), fading out in the last second
    mov eax, [sel_slot]
    lea rcx, [inv]
    movzx edx, byte [rcx + rax*4]
    shl eax, 8
    or eax, edx
    cmp eax, [name_last]
    je .name_tick
    mov [name_last], eax
    mov ecx, [f_name_t]
    mov [name_t], ecx
.name_tick:
    movss xmm0, [name_t]
    subss xmm0, [dt]
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    movss [name_t], xmm0
    comiss xmm0, xmm1
    jbe .noname
    test edx, edx
    jz .noname
    lea rcx, [item_name]
    mov rdi, [rcx + rdx*8]
    test rdi, rdi
    jz .noname
    minss xmm0, [f_one]
    mulss xmm0, [f_255]
    cvttss2si eax, xmm0
    shl eax, 24
    mov r13d, eax                   ; fading alpha
    mov r12, rdi
    mov esi, eax                    ; a dark shadow 2 pixels lower, then red
    cvtsi2ss xmm0, dword [win_h]
    subss xmm0, [f_name_y]
    addss xmm0, [f_two]
    movss xmm1, [f_two]
    call hud_text_center
    mov rdi, r12
    mov esi, r13d
    or esi, 0x002828ff              ; red (0xAABBGGRR)
    cvtsi2ss xmm0, dword [win_h]
    subss xmm0, [f_name_y]
    movss xmm1, [f_two]
    call hud_text_center
.noname:
    ; a message (sleeping and such), 3 s, fading out at the end
    movss xmm0, [msg_t]
    subss xmm0, [dt]
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    movss [msg_t], xmm0
    comiss xmm0, xmm1
    jbe .nomsg
    mov rdi, [msg_text]
    test rdi, rdi
    jz .nomsg
    minss xmm0, [f_one]
    mulss xmm0, [f_255]
    cvttss2si eax, xmm0
    shl eax, 24
    or eax, 0x0080ffff              ; yellow
    mov esi, eax
    cvtsi2ss xmm0, dword [win_h]
    subss xmm0, [f_msg_y]
    movss xmm1, [f_two]
    call hud_text_center
.nomsg:
    mov edi, GL_BLEND
    call glDisable PLT
    LEAVE_FN

; void hud_message(const char *text) - show text over the hotbar for 3 s
hud_message:
    mov [msg_text], rdi
    mov eax, [f_msg_t]
    mov [msg_t], eax
    ret

section .rodata
tex_res_table: dd 16, 8, 4, 1
view_widths: dd 640, 800, 1024, 1280  ; WINDOW setting, Windows: width drawn at
f_inv_scale: dd 0.0009765625          ; 1 / SCALE_TEX

section .text

; ---------------------------------------------------------------------------
; The player figure in the inventory: a blocky character in its own colours,
; drawn in 3D over the HUD with the head turned toward the mouse.

; fig_box(xmm0..5 = x0, y0, z0, x1, y1, z1, edi = r, g, b bytes): a lit box
; locals: [0..23] corners, [24] colour
fig_box:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    movss [rsp + 16], xmm4
    movss [rsp + 20], xmm5
    mov [rsp + 24], edi
    mov edi, GL_QUADS
    call glBegin PLT
%define FX0 0
%define FY0 4
%define FZ0 8
%define FX1 12
%define FY1 16
%define FZ1 20
%macro FSHADE 1                     ; colour x face shade x fig_tint
    movzx edi, byte [rsp + 24]
    imul edi, edi, %1
    imul edi, [fig_tint]
    shr edi, 16
    movzx esi, byte [rsp + 25]
    imul esi, esi, %1
    imul esi, [fig_tint + 4]
    shr esi, 16
    movzx edx, byte [rsp + 26]
    imul edx, edx, %1
    imul edx, [fig_tint + 8]
    shr edx, 16
    mov ecx, 255
    call glColor4ub PLT
%endmacro
%macro FV 3
    movss xmm0, [rsp + %1]
    movss xmm1, [rsp + %2]
    movss xmm2, [rsp + %3]
    call glVertex3f PLT
%endmacro
    FSHADE 235                      ; front
    FV FX0, FY0, FZ1
    FV FX1, FY0, FZ1
    FV FX1, FY1, FZ1
    FV FX0, FY1, FZ1
    FSHADE 150                      ; back
    FV FX0, FY0, FZ0
    FV FX0, FY1, FZ0
    FV FX1, FY1, FZ0
    FV FX1, FY0, FZ0
    FSHADE 255                      ; top
    FV FX0, FY1, FZ0
    FV FX0, FY1, FZ1
    FV FX1, FY1, FZ1
    FV FX1, FY1, FZ0
    FSHADE 120                      ; bottom
    FV FX0, FY0, FZ0
    FV FX1, FY0, FZ0
    FV FX1, FY0, FZ1
    FV FX0, FY0, FZ1
    FSHADE 175                      ; +x
    FV FX1, FY0, FZ0
    FV FX1, FY1, FZ0
    FV FX1, FY1, FZ1
    FV FX1, FY0, FZ1
    FSHADE 205                      ; -x
    FV FX0, FY0, FZ0
    FV FX0, FY0, FZ1
    FV FX0, FY1, FZ1
    FV FX0, FY1, FZ0
    call glEnd PLT
    LEAVE_FN

; fig_parts(rdi table, esi count): boxes of 32 bytes (6 floats, r g b, pad)
fig_parts:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
.p:
    movss xmm0, [rbx]
    movss xmm1, [rbx + 4]
    movss xmm2, [rbx + 8]
    movss xmm3, [rbx + 12]
    movss xmm4, [rbx + 16]
    movss xmm5, [rbx + 20]
    mov edi, [rbx + 24]
    call fig_box
    add rbx, 32
    dec r12d
    jnz .p
    add rsp, 8
    pop r12
    pop rbx
    ret

; clamp xmm0 to +-xmm1
fig_clamp:
    minss xmm0, xmm1
    xorps xmm2, xmm2
    subss xmm2, xmm1
    maxss xmm0, xmm2
    ret

; fig_armor(edi piece) - the armour piece worn in that slot, if any, in
; its material's colour
fig_armor:
    push rbx
    mov ebx, edi
    lea rax, [armor]
    movzx eax, byte [rax + rbx*4]
    sub eax, I_ARMOR
    cmp eax, 12
    jae .out
    shr eax, 2                      ; material
    imul eax, eax, 3
    lea rcx, [armor_rgb]
    add rcx, rax
    movzx eax, byte [rcx]
    mov [fig_tint], eax
    movzx eax, byte [rcx + 1]
    mov [fig_tint + 4], eax
    movzx eax, byte [rcx + 2]
    mov [fig_tint + 8], eax
    lea rax, [arm_tables]
    mov rdi, [rax + rbx*8]
    lea rax, [arm_counts]
    mov esi, [rax + rbx*4]
    call fig_parts
    mov dword [fig_tint], 256
    mov dword [fig_tint + 4], 256
    mov dword [fig_tint + 8], 256
.out:
    pop rbx
    ret

; void draw_figure(float cx, float feet_y, float scale, float dx, float dy)
; dx, dy: mouse position relative to the figure's eyes, in pixels
; locals: [0] cx, [4] feet y, [8] scale, [12] head yaw, [16] head pitch
draw_figure:
    ENTER_FN 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movaps xmm0, xmm3
    mulss xmm0, [f_fig_turn]
    movss xmm1, [f_fig_yaw]
    call fig_clamp
    movss [rsp + 12], xmm0
    movaps xmm0, xmm4
    mulss xmm0, [f_fig_turn]
    movss xmm1, [f_fig_pitch]
    call fig_clamp
    movss [rsp + 16], xmm0
    ; own projection with depth for the 3D figure
    mov edi, GL_PROJECTION
    call glMatrixMode PLT
    call glPushMatrix PLT
    call glLoadIdentity PLT
    movsd xmm0, [d_zero]
    cvtsi2sd xmm1, dword [win_w]
    cvtsi2sd xmm2, dword [win_h]
    movsd xmm3, [d_zero]
    movsd xmm4, [d_fig_near]
    movsd xmm5, [d_fig_far]
    call glOrtho PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    call glPushMatrix PLT
    call glLoadIdentity PLT
    mov edi, GL_DEPTH_BUFFER_BIT
    call glClear PLT
    mov edi, GL_DEPTH_TEST
    call glEnable PLT
    mov edi, GL_TEXTURE_2D
    call glDisable PLT
    mov edi, GL_BLEND
    call glDisable PLT
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    xorps xmm2, xmm2
    call glTranslatef PLT
    movss xmm0, [rsp + 8]
    xorps xmm1, xmm1
    subss xmm1, xmm0                ; model y up
    movaps xmm2, xmm0
    call glScalef PLT
    ; the body turns a little with the head
    movss xmm0, [rsp + 12]
    mulss xmm0, [f_fig_body]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    lea rdi, [fig_body]
    mov esi, FIG_BODY_N
    call fig_parts
    mov edi, 1                      ; chestplate, leggings, boots worn
    call fig_armor
    mov edi, 2
    call fig_armor
    mov edi, 3
    call fig_armor
    ; head on the neck (y 24)
    xorps xmm0, xmm0
    movss xmm1, [f_fig_neck]
    xorps xmm2, xmm2
    call glTranslatef PLT
    movss xmm0, [rsp + 12]
    mulss xmm0, [f_fig_head]
    xorps xmm1, xmm1
    movss xmm2, [f_one]
    xorps xmm3, xmm3
    call glRotatef PLT
    movss xmm0, [rsp + 16]
    movss xmm1, [f_one]
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glRotatef PLT
    lea rdi, [fig_head]
    mov esi, FIG_HEAD_N
    call fig_parts
    xor edi, edi                    ; helmet
    call fig_armor
    mov edi, GL_DEPTH_TEST
    call glDisable PLT
    call glPopMatrix PLT
    mov edi, GL_PROJECTION
    call glMatrixMode PLT
    call glPopMatrix PLT
    mov edi, GL_MODELVIEW
    call glMatrixMode PLT
    mov edi, GL_BLEND
    call glEnable PLT
    LEAVE_FN

NOEXECSTACK
