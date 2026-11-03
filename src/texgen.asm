; texgen.asm - procedural RGBA texture atlas.
;
; No image files or decoders: every tile is a base colour plus hashed
; per-pixel variation and a small pattern (stripes, rings, bricks...).
; Tiles are drawn at 16x16, reduced to the chosen resolution (16, 8, 4 or
; 1 = flat colour), then repeated 8 x 8 so a merged quad of up to 8 nodes
; tiles correctly. Layout: 16 tiles per row, 4 rows, each tile res*8
; pixels square, so the atlas is (res*128) x (res*32) - 2048 x 512 at most.
; Item icons (tools, ingots...) live in a separate 256x32 texture.

%include "common.inc"

global texgen_atlas, atlas_rgba, atlas_w, atlas_h, block_tiles
global icons_build, icons_rgba

; tile record: r, g, b, variation, pattern, alpha, r2, g2, b2, pad x3
TL_SIZE equ 12
P_NOISE   equ 0
P_TOPSTRIP equ 1
P_VSTRIPE equ 2
P_RINGS   equ 3
P_LEAVES  equ 4
P_GLASS   equ 5
P_PLANKS  equ 6
P_COBBLE  equ 7
P_BRICK   equ 8
P_WATER   equ 9
P_CRACK   equ 10                    ; digging cracks; stage in the r2 field
P_ORE     equ 11                    ; stone with specks of colour 2
P_TABLETOP equ 12
P_TABLESIDE equ 13
P_FURNACE equ 14                    ; front with an opening in colour 2
P_TORCH   equ 15
P_SMOOTH  equ 16                    ; noise with a darker rim
P_FARMLAND equ 17                   ; furrows: darker every fourth row
P_PLANT   equ 18                    ; blades up to a height (byte 9); byte 10:
                                    ; 1 = grain head, 2 = root tops (colour 2)
P_WOOL    equ 19                    ; knitted: faint diagonal stitches
P_FLOWER  equ 20                    ; stem (colour 1) and a flower head (colour 2)
P_TNT     equ 21                    ; byte 9: 0 side (white band), 1 top (fuse), 2 bottom
P_FLAME   equ 22                    ; tongues of fire, colour 2 (yellow) at the bottom
P_SGLASS  equ 23                    ; stained glass: see-through tint, solid rim
P_BEACON  equ 24                    ; glass shell (colour 2) round a bright core
NUM_TILES equ 122


%macro TILE 6-11 0, 0, 0, 0, 0
    db %1, %2, %3, %4, %5, %6, %7, %8, %9, %10, %11, 0
%endmacro

section .rodata
tiles:
    TILE 128, 128, 128, 40, P_NOISE,    255                  ; 0 stone
    TILE 134,  96,  67, 40, P_NOISE,    255                  ; 1 dirt
    TILE  90, 150,  60, 40, P_NOISE,    255                  ; 2 grass top
    TILE 134,  96,  67, 40, P_TOPSTRIP, 255,  90, 150,  60   ; 3 grass side
    TILE 219, 207, 163, 24, P_NOISE,    255                  ; 4 sand
    TILE  40,  90, 200, 20, P_WATER,    170                  ; 5 water
    TILE 102,  80,  50, 30, P_VSTRIPE,  255                  ; 6 log side
    TILE 160, 130,  85, 20, P_RINGS,    255, 102,  80,  50   ; 7 log top
    TILE  50, 120,  40, 60, P_LEAVES,   255                  ; 8 leaves
    TILE 240, 245, 250, 12, P_NOISE,    255                  ; 9 snow
    TILE 134,  96,  67, 40, P_TOPSTRIP, 255, 240, 245, 250   ; 10 snowy dirt side
    TILE 210, 160, 110, 24, P_NOISE,    255                  ; 11 desert sand
    TILE 170, 100,  70, 36, P_NOISE,    255                  ; 12 desert stone
    TILE 170, 160,  80, 36, P_NOISE,    255                  ; 13 dry grass top
    TILE 134,  96,  67, 40, P_TOPSTRIP, 255, 170, 160,  80   ; 14 dry grass side
    TILE 120, 120, 120, 50, P_COBBLE,   255                  ; 15 cobble
    TILE 180, 140,  90, 20, P_PLANKS,   255                  ; 16 planks
    TILE 200, 230, 240,  0, P_GLASS,    255                  ; 17 glass
    TILE 130, 125, 120, 90, P_NOISE,    255                  ; 18 gravel
    TILE  60, 140,  60, 30, P_VSTRIPE,  255                  ; 19 cactus side
    TILE  80, 160,  80, 20, P_NOISE,    255                  ; 20 cactus top
    TILE  30,  80,  40, 50, P_LEAVES,   255                  ; 21 pine needles
    TILE  70,  50,  35, 30, P_VSTRIPE,  255                  ; 22 pine log side
    TILE 160,  70,  55, 30, P_BRICK,    255, 200, 200, 190   ; 23 brick
    TILE   0,   0,   0,  0, P_CRACK,    200, 0               ; 24-28 cracks
    TILE   0,   0,   0,  0, P_CRACK,    200, 1
    TILE   0,   0,   0,  0, P_CRACK,    200, 2
    TILE   0,   0,   0,  0, P_CRACK,    200, 3
    TILE   0,   0,   0,  0, P_CRACK,    200, 4
    TILE  55,  55,  55, 90, P_NOISE,    255                  ; 29 bedrock
    TILE 128, 128, 128, 40, P_ORE,      255,  25,  25,  25   ; 30 coal ore
    TILE 128, 128, 128, 40, P_ORE,      255, 215, 170, 140   ; 31 iron ore
    TILE 128, 128, 128, 40, P_ORE,      255, 250, 215,  60   ; 32 gold ore
    TILE 128, 128, 128, 40, P_ORE,      255,  90, 230, 225   ; 33 diamond ore
    TILE 180, 140,  90, 20, P_TABLETOP, 255                  ; 34 crafting table top
    TILE 180, 140,  90, 20, P_TABLESIDE, 255, 110, 110, 110  ; 35 crafting table side
    TILE 125, 125, 125, 40, P_FURNACE,  255,  20,  20,  20   ; 36 furnace front
    TILE 125, 125, 125, 40, P_FURNACE,  255, 255, 150,  40   ; 37 furnace front, lit
    TILE 140, 140, 140, 20, P_SMOOTH,   255                  ; 38 furnace top
    TILE 110,  80,  40, 10, P_TORCH,    255, 255, 220,  80   ; 39 torch
    TILE 158, 164, 178, 14, P_NOISE,    255                  ; 40 clay
    TILE 216, 216, 216, 14, P_SMOOTH,   255                  ; 41 block of iron
    TILE 245, 205,  60, 18, P_SMOOTH,   255                  ; 42 block of gold
    TILE 100, 225, 215, 18, P_SMOOTH,   255                  ; 43 block of diamond
    TILE  34,  34,  36, 14, P_SMOOTH,   255                  ; 44 block of coal
    TILE 104,  72,  46, 30, P_FARMLAND, 255                  ; 45 farmland top
    TILE  86, 156,  62, 40, P_PLANT,    255,   0,   0,   0, 13, 0   ; 46 tall grass
    TILE  76, 160,  56, 30, P_PLANT,    255,   0,   0,   0,  2, 0   ; 47-54 wheat
    TILE  76, 160,  56, 30, P_PLANT,    255,   0,   0,   0,  4, 0
    TILE  80, 158,  56, 30, P_PLANT,    255,   0,   0,   0,  6, 0
    TILE  86, 156,  56, 30, P_PLANT,    255,   0,   0,   0,  8, 0
    TILE  96, 156,  56, 30, P_PLANT,    255,   0,   0,   0, 10, 0
    TILE 120, 156,  60, 30, P_PLANT,    255, 170, 170,  70, 12, 1
    TILE 160, 156,  64, 30, P_PLANT,    255, 200, 180,  80, 14, 1
    TILE 196, 164,  70, 30, P_PLANT,    255, 226, 196,  96, 15, 1
    TILE  70, 150,  50, 30, P_PLANT,    255,   0,   0,   0,  3, 0   ; 55-58 carrots
    TILE  70, 150,  50, 30, P_PLANT,    255,   0,   0,   0,  5, 0
    TILE  70, 152,  50, 30, P_PLANT,    255,   0,   0,   0,  7, 0
    TILE  70, 152,  50, 30, P_PLANT,    255, 232, 124,  34,  9, 2
    TILE 233, 236, 236, 18, P_WOOL,     255                  ; 59 white wool
    TILE 240, 118,  19, 18, P_WOOL,     255                  ; 60 orange wool
    TILE 189,  68, 179, 18, P_WOOL,     255                  ; 61 magenta wool
    TILE  58, 175, 217, 18, P_WOOL,     255                  ; 62 light blue wool
    TILE 248, 198,  39, 18, P_WOOL,     255                  ; 63 yellow wool
    TILE 112, 185,  25, 18, P_WOOL,     255                  ; 64 lime wool
    TILE 237, 141, 172, 18, P_WOOL,     255                  ; 65 pink wool
    TILE  62,  68,  71, 18, P_WOOL,     255                  ; 66 gray wool
    TILE 142, 142, 134, 18, P_WOOL,     255                  ; 67 light gray wool
    TILE  21, 137, 145, 18, P_WOOL,     255                  ; 68 cyan wool
    TILE 121,  42, 172, 18, P_WOOL,     255                  ; 69 purple wool
    TILE  53,  57, 157, 18, P_WOOL,     255                  ; 70 blue wool
    TILE 114,  71,  40, 18, P_WOOL,     255                  ; 71 brown wool
    TILE  84, 109,  27, 18, P_WOOL,     255                  ; 72 green wool
    TILE 161,  39,  34, 18, P_WOOL,     255                  ; 73 red wool
    TILE  20,  21,  25, 18, P_WOOL,     255                  ; 74 black wool
    TILE 207, 213, 214,  3, P_NOISE,    255                  ; 75 white concrete
    TILE 224,  97,   1,  3, P_NOISE,    255                  ; 76 orange concrete
    TILE 169,  48, 159,  3, P_NOISE,    255                  ; 77 magenta concrete
    TILE  36, 137, 199,  3, P_NOISE,    255                  ; 78 light blue concrete
    TILE 241, 175,  21,  3, P_NOISE,    255                  ; 79 yellow concrete
    TILE  94, 169,  24,  3, P_NOISE,    255                  ; 80 lime concrete
    TILE 213, 101, 142,  3, P_NOISE,    255                  ; 81 pink concrete
    TILE  54,  57,  61,  3, P_NOISE,    255                  ; 82 gray concrete
    TILE 125, 125, 115,  3, P_NOISE,    255                  ; 83 light gray concrete
    TILE  21, 119, 136,  3, P_NOISE,    255                  ; 84 cyan concrete
    TILE 100,  32, 156,  3, P_NOISE,    255                  ; 85 purple concrete
    TILE  45,  47, 143,  3, P_NOISE,    255                  ; 86 blue concrete
    TILE  96,  60,  32,  3, P_NOISE,    255                  ; 87 brown concrete
    TILE  73,  91,  36,  3, P_NOISE,    255                  ; 88 green concrete
    TILE 142,  33,  33,  3, P_NOISE,    255                  ; 89 red concrete
    TILE   8,  10,  15,  3, P_NOISE,    255                  ; 90 black concrete
    TILE  60, 140,  50, 10, P_FLOWER,   255, 248, 214,  40   ; 91 yellow flower
    TILE  60, 140,  50, 10, P_FLOWER,   255, 214,  36,  36   ; 92 red flower
    TILE 166,  40,  40, 16, P_NOISE,    255                  ; 93 bed, foot (blanket)
    TILE 166,  40,  40, 16, P_TOPSTRIP, 255, 236, 236, 232   ; 94 bed, head (pillow)
    TILE 180, 140,  90, 20, P_ORE,      255, 200,  60, 190   ; 95 dye maker
    TILE 212,  84,  14, 40, P_ORE,      255, 255, 196,  56   ; 96 lava
    TILE  22,  16,  34, 30, P_ORE,      255,  62,  42,  92   ; 97 obsidian
    TILE 200,  44,  34, 16, P_TNT,      255, 232, 230, 220, 0, 0   ; 98 TNT side
    TILE 200,  44,  34, 16, P_TNT,      255, 232, 230, 220, 1, 0   ; 99 TNT top
    TILE 200,  44,  34, 16, P_TNT,      255, 232, 230, 220, 2, 0   ; 100 TNT bottom
    TILE 232,  92,  24, 30, P_FLAME,    255, 255, 214,  70   ; 101 fire
    TILE 112,  40,  38, 50, P_ORE,      255,  70,  22,  24   ; 102 netherrack
    TILE  92,  30, 168, 40, P_ORE,      200, 196, 120, 255   ; 103 nether portal
    TILE 112, 200,  92, 20, P_SMOOTH,   200                  ; 104 slime block
    TILE 233, 236, 236,  6, P_SGLASS,   140                  ; 105 white stained glass
    TILE 240, 118,  19,  6, P_SGLASS,   140                  ; 106 orange stained glass
    TILE 189,  68, 179,  6, P_SGLASS,   140                  ; 107 magenta stained glass
    TILE  58, 175, 217,  6, P_SGLASS,   140                  ; 108 light blue stained glass
    TILE 248, 198,  39,  6, P_SGLASS,   140                  ; 109 yellow stained glass
    TILE 112, 185,  25,  6, P_SGLASS,   140                  ; 110 lime stained glass
    TILE 237, 141, 172,  6, P_SGLASS,   140                  ; 111 pink stained glass
    TILE  62,  68,  71,  6, P_SGLASS,   140                  ; 112 gray stained glass
    TILE 142, 142, 134,  6, P_SGLASS,   140                  ; 113 light gray stained glass
    TILE  21, 137, 145,  6, P_SGLASS,   140                  ; 114 cyan stained glass
    TILE 121,  42, 172,  6, P_SGLASS,   140                  ; 115 purple stained glass
    TILE  53,  57, 157,  6, P_SGLASS,   140                  ; 116 blue stained glass
    TILE 114,  71,  40,  6, P_SGLASS,   140                  ; 117 brown stained glass
    TILE  84, 109,  27,  6, P_SGLASS,   140                  ; 118 green stained glass
    TILE 161,  39,  34,  6, P_SGLASS,   140                  ; 119 red stained glass
    TILE  20,  21,  25,  6, P_SGLASS,   140                  ; 120 black stained glass
    TILE 110, 236, 226, 10, P_BEACON,   255, 236, 250, 248   ; 121 beacon

; "TNT" on the side band, rows 6-9: bit x = column x
tnt_glyph:  dw 0x3A5C, 0x12C8, 0x1348, 0x1248

; fixed icon colours for codes 6-11 (rainbow) and 12-13, 0xAABBGGRR
rainbow:    dd 0xff2828e0, 0xff1c8cf4, 0xff2cd8f8, 0xff30b848, 0xffd86030, 0xffb03c90
            dd 0xfff4f4f4, 0xff302c2c   ; 12 white, 13 near black

; per block: top, side, bottom tile
block_tiles:
    db 0, 0, 0, 0           ; air
    db 0, 0, 0, 0           ; stone
    db 1, 1, 1, 0           ; dirt
    db 2, 3, 1, 0           ; grass
    db 4, 4, 4, 0           ; sand
    db 5, 5, 5, 0           ; water
    db 7, 6, 7, 0           ; log
    db 8, 8, 8, 0           ; leaves
    db 9, 10, 1, 0          ; dirt with snow
    db 11, 11, 11, 0        ; desert sand
    db 12, 12, 12, 0        ; desert stone
    db 13, 14, 1, 0         ; dry grass
    db 15, 15, 15, 0        ; cobble
    db 16, 16, 16, 0        ; planks
    db 17, 17, 17, 0        ; glass
    db 18, 18, 18, 0        ; gravel
    db 20, 19, 20, 0        ; cactus
    db 21, 21, 21, 0        ; pine needles
    db 9, 9, 9, 0           ; snow block
    db 7, 22, 7, 0          ; pine log
    db 23, 23, 23, 0        ; brick
    times 7 db 5, 5, 5, 0   ; flowing water
    db 29, 29, 29, 0        ; bedrock
    db 30, 30, 30, 0        ; coal ore
    db 31, 31, 31, 0        ; iron ore
    db 32, 32, 32, 0        ; gold ore
    db 33, 33, 33, 0        ; diamond ore
    db 34, 35, 16, 0        ; crafting table
    db 38, 36, 38, 0        ; furnace
    db 38, 37, 38, 0        ; furnace, burning
    db 39, 39, 39, 0        ; torch
    db 40, 40, 40, 0        ; clay
    db 41, 41, 41, 0        ; block of iron
    db 42, 42, 42, 0        ; block of gold
    db 43, 43, 43, 0        ; block of diamond
    db 44, 44, 44, 0        ; block of coal
    db 45, 1, 1, 0          ; farmland
    db 46, 46, 46, 0        ; tall grass
%assign st 0
%rep 8
    db 47 + st, 47 + st, 47 + st, 0   ; wheat stages
%assign st st + 1
%endrep
%assign st 0
%rep 4
    db 55 + st, 55 + st, 55 + st, 0   ; carrot stages
%assign st st + 1
%endrep
    times 5 db 16, 16, 16, 0          ; fence, gates: planks
%assign c 0
%rep 16
    db 59 + c, 59 + c, 59 + c, 0      ; wool
%assign c c + 1
%endrep
%assign c 0
%rep 16
    db 75 + c, 75 + c, 75 + c, 0      ; concrete
%assign c c + 1
%endrep
    db 91, 91, 91, 0        ; yellow flower
    db 92, 92, 92, 0        ; red flower
    db 93, 93, 93, 0        ; bed, foot
    db 94, 94, 94, 0        ; bed, head
    db 95, 95, 95, 0        ; dye maker
    times 4 db 96, 96, 96, 0  ; lava, still and flowing
    db 97, 97, 97, 0        ; obsidian
    db 99, 98, 100, 0       ; TNT
    db 101, 101, 101, 0     ; fire
    db 102, 102, 102, 0     ; netherrack
    db 103, 103, 103, 0     ; nether portal
    db 104, 104, 104, 0     ; slime block
%assign c 0
%rep 16
    db 105 + c, 105 + c, 105 + c, 0   ; stained glass
%assign c c + 1
%endrep
    db 121, 121, 121, 0     ; beacon
    times (256 - NUM_BLOCKS) * 4 db 0

%include "items_data.inc"

section .bss
alignb 16
atlas_rgba: resb ATLAS_W * ATLAS_H * 4
tilebuf:    resb 16 * 16 * 4
atlas_w:    resd 1
atlas_h:    resd 1
tex_res:    resd 1
tex_opaque: resd 1
alignb 16
icons_rgba: resb ICONS_W * ICONS_H * 4

section .text

; u32 phash(edi a, esi b, edx c) -> eax ; clobbers ecx
phash:
    imul eax, edi, 0x1f1f
    imul ecx, esi, 0x3797
    add eax, ecx
    imul ecx, edx, 0x2b9d
    add eax, ecx
    add eax, 0x5bd1e995
    mov ecx, eax
    shr ecx, 15
    xor eax, ecx
    imul eax, eax, 0x2c1b3c6d
    mov ecx, eax
    shr ecx, 12
    xor eax, ecx
    imul eax, eax, 0x297a2d39
    mov ecx, eax
    shr ecx, 15
    xor eax, ecx
    ret

; void texgen_atlas(int res, int leaves_opaque) - res 16, 8, 4 or 1
; r12 tile, r13 tile record, r14 py, r15 px, ebx factor f (x/256)
; locals: [rsp] colour index (0/1), [rsp+4] alpha
texgen_atlas:
    ENTER_FN 16
    mov [tex_res], edi
    mov [tex_opaque], esi
    mov eax, edi
    shl eax, 7
    mov [atlas_w], eax
    mov eax, edi
    shl eax, 6                      ; 8 rows of tiles
    mov [atlas_h], eax
    xor r12d, r12d
.tile:
    imul eax, r12d, TL_SIZE
    lea r13, [tiles]
    add r13, rax
    xor r14d, r14d
.py:
    xor r15d, r15d
.px:
    mov edi, r15d
    mov esi, r14d
    mov edx, r12d
    call phash
    movzx eax, al                   ; h 0..255
    movzx ecx, byte [r13 + 3]       ; variation
    mov ebx, 256
    sub ebx, ecx
    imul ecx, eax
    shr ecx, 7                      ; var*2*h/256
    add ebx, ecx
    mov dword [rsp], 0
    movzx ecx, byte [r13 + 5]
    mov [rsp + 4], ecx
    movzx ecx, byte [r13 + 4]
    cmp ecx, P_TOPSTRIP
    je .topstrip
    cmp ecx, P_VSTRIPE
    je .vstripe
    cmp ecx, P_RINGS
    je .rings
    cmp ecx, P_LEAVES
    je .leaves
    cmp ecx, P_GLASS
    je .glass
    cmp ecx, P_PLANKS
    je .planks
    cmp ecx, P_COBBLE
    je .cobble
    cmp ecx, P_BRICK
    je .brick
    cmp ecx, P_CRACK
    je .crack
    cmp ecx, P_ORE
    je .ore
    cmp ecx, P_TABLETOP
    je .tabletop
    cmp ecx, P_TABLESIDE
    je .tableside
    cmp ecx, P_FURNACE
    je .furnace
    cmp ecx, P_TORCH
    je .torch
    cmp ecx, P_SMOOTH
    je .smooth
    cmp ecx, P_FARMLAND
    je .farmland
    cmp ecx, P_PLANT
    je .plant
    cmp ecx, P_WOOL
    je .wool
    cmp ecx, P_FLOWER
    je .flower
    cmp ecx, P_TNT
    je .tnt
    cmp ecx, P_FLAME
    je .flame
    cmp ecx, P_SGLASS
    je .sglass
    cmp ecx, P_BEACON
    je .beacon
    jmp .write

; RECT x0, x1, y0, y1, target - jump if px in [x0,x1] and py in [y0,y1]
%macro INRECT 5
    cmp r15d, %1
    jb %%no
    cmp r15d, %2
    ja %%no
    cmp r14d, %3
    jb %%no
    cmp r14d, %4
    jbe %5
%%no:
%endmacro

.ore:
    ; clumps of 2x2 pixel cells, ragged at the edges
    mov edi, r15d
    shr edi, 1
    mov esi, r14d
    shr esi, 1
    lea edx, [r12 + 50]
    call phash
    movzx eax, al
    cmp eax, 70
    jae .write
    mov edi, r15d
    mov esi, r14d
    lea edx, [r12 + 9]
    call phash
    test eax, 3
    jz .write
    mov dword [rsp], 1
    jmp .write

.border_dark:
    mov ebx, 140
    jmp .write
.tabletop:
    INRECT 0, 15, 0, 0, .border_dark
    INRECT 0, 15, 15, 15, .border_dark
    INRECT 0, 0, 0, 15, .border_dark
    INRECT 15, 15, 0, 15, .border_dark
    INRECT 7, 8, 0, 15, .tt_line
    INRECT 0, 15, 7, 8, .tt_line
    mov eax, r14d
    and eax, 3
    cmp eax, 3
    jne .write
    mov ebx, 200
    jmp .write
.tt_line:
    mov ebx, 165
    jmp .write

.tableside:
    INRECT 0, 15, 0, 1, .border_dark
    INRECT 3, 4, 4, 12, .ts_tool
    INRECT 2, 5, 4, 5, .ts_tool
    INRECT 11, 12, 4, 12, .ts_tool
    INRECT 10, 13, 11, 12, .ts_tool
    mov eax, r14d
    and eax, 3
    cmp eax, 3
    jne .write
    mov ebx, 185
    jmp .write
.ts_tool:
    mov dword [rsp], 1
    jmp .write

.furnace:
    INRECT 4, 11, 8, 13, .fu_hole
    INRECT 3, 12, 7, 14, .fu_frame
    INRECT 0, 15, 0, 1, .fu_frame
    jmp .write
.fu_hole:
    mov dword [rsp], 1
    mov ebx, 256
    jmp .write
.fu_frame:
    mov ebx, 150
    jmp .write

.torch:
    mov dword [rsp + 4], 0
    INRECT 7, 8, 3, 5, .to_flame
    INRECT 7, 8, 6, 15, .to_stick
    jmp .write
.to_flame:
    mov dword [rsp], 1
    mov dword [rsp + 4], 255
    mov ebx, 256
    jmp .write
.to_stick:
    mov dword [rsp + 4], 255
    jmp .write

.farmland:
    test r14d, 3
    jnz .write
    mov ebx, 150                    ; a furrow
    jmp .write

.plant:
    ; blades: every third column, leaning a little with height, from the
    ; bottom up to the height in byte 9; transparent elsewhere
    mov dword [rsp + 4], 0
    movzx eax, byte [r13 + 9]
    mov ecx, 16
    sub ecx, eax                    ; first row with blades
    cmp r14d, ecx
    jb .write
    mov eax, r14d
    shr eax, 2
    add eax, r15d
    xor edx, edx
    push rcx
    mov ecx, 3
    div ecx
    pop rcx
    test edx, edx
    jnz .write
    mov dword [rsp + 4], 255
    movzx eax, byte [r13 + 10]
    cmp eax, 1
    jne .pl_root
    ; grain head: the top 4 rows of the blades
    lea eax, [rcx + 4]
    cmp r14d, eax
    jae .write
    mov dword [rsp], 1
    jmp .write
.pl_root:
    cmp eax, 2
    jne .write
    ; root tops showing at the bottom 3 rows
    cmp r14d, 13
    jb .write
    mov dword [rsp], 1
    jmp .write

.wool:
    ; stitches: the diagonals (x + y) and (x - y) every 4 texels are a bit darker
    mov eax, r15d
    add eax, r14d
    test eax, 3
    jz .w_dark
    mov eax, r15d
    sub eax, r14d
    test eax, 3
    jnz .write
.w_dark:
    imul ebx, ebx, 225
    shr ebx, 8
    jmp .write

.flower:
    ; a stem in the middle (colour 1) under a round head (colour 2)
    mov dword [rsp + 4], 0
    INRECT 7, 8, 8, 15, .fl_stem
    INRECT 6, 9, 3, 7, .fl_head
    INRECT 5, 10, 4, 6, .fl_head
    INRECT 9, 11, 10, 11, .fl_stem   ; a leaf
    jmp .write
.fl_stem:
    mov dword [rsp + 4], 255
    jmp .write
.fl_head:
    mov dword [rsp + 4], 255
    mov dword [rsp], 1
    jmp .write

.tnt:
    ; red sticks; the side has a light band with "TNT" on it, the top the
    ; ends of the sticks and a fuse in the middle
    movzx eax, byte [r13 + 9]
    test eax, eax
    jnz .tnt_end
    INRECT 0, 15, 5, 10, .tnt_band
    jmp .tnt_seam
.tnt_band:
    mov dword [rsp], 1
    cmp r14d, 6
    jb .write
    cmp r14d, 9
    ja .write
    lea rax, [tnt_glyph]
    movzx eax, word [rax + r14*2 - 12]
    bt eax, r15d
    jnc .write
    mov ebx, 40                     ; a letter
    jmp .write
.tnt_end:
    cmp eax, 1
    jne .tnt_grid
    INRECT 7, 8, 7, 8, .tnt_fuse
    INRECT 6, 9, 6, 9, .tnt_ring
.tnt_grid:
    test r14d, 3
    jz .tnt_line
.tnt_seam:
    mov eax, r15d
    and eax, 3
    cmp eax, 3
    jne .write
.tnt_line:
    mov ebx, 160
    jmp .write
.tnt_fuse:
    mov dword [rsp], 1
    mov ebx, 60
    jmp .write
.tnt_ring:
    mov dword [rsp], 1
    jmp .write

.flame:
    ; each column burns up to a ragged height; yellow at the bottom
    mov dword [rsp + 4], 0
    mov edi, r15d
    mov esi, 31
    mov edx, 5
    call phash
    and eax, 7
    add eax, 2                      ; top row of this column: 2-9
    test r15d, 1
    jz .fl_h
    add eax, 2                      ; thinner tongues between
.fl_h:
    cmp r14d, eax
    jb .write
    mov dword [rsp + 4], 255
    cmp r14d, 11
    jb .write
    mov dword [rsp], 1
    jmp .write

.sglass:
    ; the tint lets light through (blended); a solid frame and a streak
    INRECT 0, 15, 0, 0, .sg_rim
    INRECT 0, 15, 15, 15, .sg_rim
    INRECT 0, 0, 0, 15, .sg_rim
    INRECT 15, 15, 0, 15, .sg_rim
    mov eax, r15d
    sub eax, r14d
    cmp eax, 4
    jb .write
    cmp eax, 5
    ja .write
    cmp r15d, 12
    jae .write
    mov ebx, 300                    ; bright streak
    jmp .write
.sg_rim:
    mov ebx, 190
    mov dword [rsp + 4], 235
    jmp .write

.beacon:
    ; a pale glass shell (colour 2) round a glowing core
    mov dword [rsp], 1
    INRECT 0, 15, 0, 0, .write
    INRECT 0, 15, 15, 15, .write
    INRECT 0, 0, 0, 15, .write
    INRECT 15, 15, 0, 15, .write
    INRECT 4, 11, 4, 11, .bc_core
    mov ebx, 200
    jmp .write
.bc_core:
    mov dword [rsp], 0
    mov ebx, 280
    jmp .write

.smooth:
    INRECT 0, 15, 0, 0, .sm_rim
    INRECT 0, 15, 15, 15, .sm_rim
    INRECT 0, 0, 0, 15, .sm_rim
    INRECT 15, 15, 0, 15, .sm_rim
    jmp .write
.sm_rim:
    mov ebx, 170
    jmp .write

.crack:
    ; blotches that spread with the stage
    mov edi, r15d
    shr edi, 1
    mov esi, r14d
    shr esi, 1
    mov edx, 77
    call phash
    movzx eax, al
    movzx ecx, byte [r13 + 6]       ; stage 0-4
    inc ecx
    imul ecx, ecx, 40
    cmp eax, ecx
    jae .crack_no
    mov edi, r15d
    mov esi, r14d
    mov edx, r12d
    call phash
    test eax, 1
    jz .crack_no
    jmp .write
.crack_no:
    mov dword [rsp + 4], 0
    jmp .write

.topstrip:
    mov edi, r15d
    mov esi, 99
    mov edx, r12d
    call phash
    and eax, 1
    add eax, 3
    cmp r14d, eax
    jae .write
    mov dword [rsp], 1
    jmp .write

.vstripe:
    mov eax, r15d
    and eax, 3
    jnz .vs2
    sub ebx, 50
    jmp .write
.vs2:
    cmp eax, 2
    jne .write
    add ebx, 16
    jmp .write

.rings:
    lea eax, [r15*2 - 15]
    imul eax, eax
    lea ecx, [r14*2 - 15]
    imul ecx, ecx
    add eax, ecx
    cmp eax, 196
    jb .r_in
    mov dword [rsp], 1
    jmp .write
.r_in:
    xor edx, edx
    mov ecx, 24
    div ecx
    test eax, 1
    jz .write
    sub ebx, 30
    jmp .write

.leaves:
    cmp eax, 64                     ; eax = h: a quarter of the pixels are holes
    jae .write
    mov dword [rsp + 4], 0
    cmp dword [tex_opaque], 0
    je .write
    mov dword [rsp + 4], 255        ; opaque leaves: dark spots instead
    mov ebx, 150
    jmp .write

.glass:
    mov ebx, 256
    test r15d, r15d
    jz .write
    test r14d, r14d
    jz .write
    cmp r15d, 15
    je .write
    cmp r14d, 15
    je .write
    mov eax, r15d
    sub eax, r14d
    cmp eax, 4
    jb .g_no
    cmp eax, 5
    ja .g_no
    cmp r15d, 12
    jae .g_no
    mov ebx, 330                    ; bright streak
    jmp .write
.g_no:
    mov dword [rsp + 4], 0
    jmp .write

.planks:
    mov eax, r14d
    and eax, 3
    cmp eax, 3
    jne .p2
    mov ebx, 170
    jmp .write
.p2:
    mov eax, r14d
    shr eax, 2
    imul eax, eax, 5
    add eax, 3
    and eax, 15
    cmp eax, r15d
    jne .write
    mov ebx, 185
    jmp .write

.cobble:
    mov ecx, r14d
    shr ecx, 2                      ; row
    mov eax, ecx
    and eax, 1
    imul eax, eax, 3
    add eax, r15d                   ; px + offset
    mov r8d, eax
    test r14d, 3
    jz .c_mortar
    xor edx, edx
    mov r9d, 5
    div r9d
    test edx, edx
    jz .c_mortar
    ; stone cell shade: row * 8 + (px + offset) / 5
    lea edi, [rcx*8 + rax]
    mov esi, 7
    mov edx, r12d
    call phash
    and eax, 63
    add eax, 200
    mov ebx, eax
    jmp .write
.c_mortar:
    mov ebx, 150
    jmp .write

.brick:
    mov eax, r14d
    and eax, 3
    cmp eax, 3
    je .b_mortar
    mov eax, r14d
    shr eax, 2
    and eax, 1
    shl eax, 2
    add eax, r15d
    and eax, 7
    cmp eax, 7
    jne .write
.b_mortar:
    mov dword [rsp], 1
    jmp .write

.write:
    ; destination pixel in the 16x16 tile buffer
    mov eax, r14d
    shl eax, 4
    add eax, r15d
    lea rdi, [tilebuf]
    lea rdi, [rdi + rax*4]
    lea rsi, [r13]                  ; colour 1
    cmp dword [rsp], 0
    je .c1
    lea rsi, [r13 + 6]              ; colour 2
.c1:
    xor ecx, ecx
.ch:
    movzx eax, byte [rsi + rcx]
    imul eax, ebx
    sar eax, 8
    jns .nn
    xor eax, eax
.nn:
    cmp eax, 255
    jbe .nc
    mov eax, 255
.nc:
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 3
    jb .ch
    mov eax, [rsp + 4]
    mov [rdi + 3], al

    inc r15d
    cmp r15d, 16
    jb .px
    inc r14d
    cmp r14d, 16
    jb .py
    mov edi, r12d
    call place_tile
    inc r12d
    cmp r12d, NUM_TILES
    jb .tile
    LEAVE_FN

; place_tile(edi tile): reduce tilebuf to tex_res and repeat it 8 x 8
; r12 tile, r13 out y, r14 out x (pixels within one repeat), ebx block size
place_tile:
    ENTER_FN 16
    mov r12d, edi
    mov eax, 16
    xor edx, edx
    div dword [tex_res]
    mov ebx, eax                    ; source pixels per output pixel
    xor r13d, r13d
.oy:
    xor r14d, r14d
.ox:
    ; average the ebx x ebx source block
    xor r8d, r8d                    ; r
    xor r9d, r9d                    ; g
    xor r10d, r10d                  ; b
    xor r11d, r11d                  ; a
    xor ecx, ecx                    ; sy
.sy:
    xor edx, edx                    ; sx
.sx:
    mov eax, r13d
    imul eax, ebx
    add eax, ecx
    shl eax, 4
    mov esi, r14d
    imul esi, ebx
    add esi, edx
    add eax, esi
    lea rsi, [tilebuf]
    lea rsi, [rsi + rax*4]
    movzx eax, byte [rsi]
    add r8d, eax
    movzx eax, byte [rsi + 1]
    add r9d, eax
    movzx eax, byte [rsi + 2]
    add r10d, eax
    movzx eax, byte [rsi + 3]
    add r11d, eax
    inc edx
    cmp edx, ebx
    jb .sx
    inc ecx
    cmp ecx, ebx
    jb .sy
    mov ecx, ebx
    imul ecx, ebx                   ; pixels averaged
    mov eax, r8d
    xor edx, edx
    div ecx
    mov r8d, eax
    mov eax, r9d
    xor edx, edx
    div ecx
    mov r9d, eax
    mov eax, r10d
    xor edx, edx
    div ecx
    mov r10d, eax
    mov eax, r11d
    xor edx, edx
    div ecx
    mov r11d, eax
    ; alpha-tested tiles stay crisp: cut-outs are either in or out
    cmp r11d, 255
    je .packed
    cmp r11d, 128
    jb .cut
    cmp r11d, 200
    jbe .packed                     ; water / cracks keep their alpha
    mov r11d, 255
    jmp .packed
.cut:
    cmp r11d, 64
    jae .packed
    xor r11d, r11d
.packed:
    shl r9d, 8
    shl r10d, 16
    shl r11d, 24
    or r8d, r9d
    or r8d, r10d
    or r8d, r11d                    ; rgba
    ; write to all 8 x 8 repeats
    xor ecx, ecx                    ; repeat y
.ry:
    xor edx, edx                    ; repeat x
.rx:
    mov eax, r12d
    shr eax, 4                      ; tile row
    shl eax, 3
    add eax, ecx
    imul eax, [tex_res]
    add eax, r13d                   ; atlas y
    imul eax, [atlas_w]
    mov esi, r12d
    and esi, 15
    shl esi, 3
    add esi, edx
    imul esi, [tex_res]
    add esi, r14d                   ; atlas x
    add eax, esi
    lea rsi, [atlas_rgba]
    mov [rsi + rax*4], r8d
    inc edx
    cmp edx, 8
    jb .rx
    inc ecx
    cmp ecx, 8
    jb .ry
    inc r14d
    cmp r14d, [tex_res]
    jb .ox
    inc r13d
    cmp r13d, [tex_res]
    jb .oy
    LEAVE_FN

; void icons_build(void) - item icons from the palette masks
; r12 icon, r13 py, r14 px; locals: [0] material r, g, b
icons_build:
    ENTER_FN 16
    xor r12d, r12d
.icon:
    imul eax, r12d, 3
    lea rcx, [icon_colors]
    add rcx, rax
    movzx eax, byte [rcx]
    mov [rsp], eax
    movzx eax, byte [rcx + 1]
    mov [rsp + 4], eax
    movzx eax, byte [rcx + 2]
    mov [rsp + 8], eax
    xor r13d, r13d
.py:
    xor r14d, r14d
.px:
    mov eax, r12d
    shl eax, 8
    mov ecx, r13d
    shl ecx, 4
    add eax, ecx
    add eax, r14d
    lea rcx, [icon_masks]
    movzx eax, byte [rcx + rax]     ; palette code
    xor r8d, r8d                    ; rgba
    test eax, eax
    jz .put
    cmp eax, 6
    jae .rainbow
    cmp eax, 4
    je .handle
    cmp eax, 5
    je .handle_dark
    ; material, scaled: 1 -> 256, 2 -> 346 (light), 3 -> 180 (dark)
    mov r9d, 256
    cmp eax, 2
    jne .nl
    mov r9d, 346
.nl:
    cmp eax, 3
    jne .nd
    mov r9d, 180
.nd:
    mov r8d, 0xff000000
    xor ecx, ecx
.ch:
    mov eax, [rsp + rcx*4]
    imul eax, r9d
    shr eax, 8
    cmp eax, 255
    jbe .cl
    mov eax, 255
.cl:
    shl ecx, 3
    shl eax, cl
    or r8d, eax
    shr ecx, 3
    inc ecx
    cmp ecx, 3
    jb .ch
    jmp .put
.handle:
    mov r8d, 0xff28506e             ; (110, 80, 40)
    jmp .put
.handle_dark:
    mov r8d, 0xff193246             ; (70, 50, 25)
    jmp .put
.rainbow:
    ; codes 6-11: red, orange, yellow, green, blue, purple (0xAABBGGRR)
    lea rcx, [rainbow]
    mov r8d, [rcx + rax*4 - 24]
.put:
    mov eax, r12d
    shr eax, 4
    shl eax, 4
    add eax, r13d                   ; texture row
    imul eax, eax, ICONS_W
    mov ecx, r12d
    and ecx, 15
    shl ecx, 4
    add eax, ecx
    add eax, r14d
    lea rcx, [icons_rgba]
    mov [rcx + rax*4], r8d
    inc r14d
    cmp r14d, 16
    jb .px
    inc r13d
    cmp r13d, 16
    jb .py
    inc r12d
    cmp r12d, ICON_COUNT
    jb .icon
    LEAVE_FN

NOEXECSTACK
