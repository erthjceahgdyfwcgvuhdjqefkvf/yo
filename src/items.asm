; items.asm - inventory, item and tool properties, dig rules, crafting,
; furnaces and dropped-item entities.
;
; An inventory slot is a dword: byte 0 item id, byte 1 count, bytes 2-3
; tool or armour damage. Slots 0-8 are the hotbar, 9-35 the main inventory;
; the 4 armour slots (helmet, chestplate, leggings, boots) are apart. Item ids
; below 128 are blocks (placeable), 128 and up are items (see common.inc).
;
; Dig rules follow Minecraft 1.6: each block has a hardness, a preferred
; tool and sometimes a minimum pickaxe tier to drop anything. Digging takes
; hardness x 1.5 seconds with a usable tool (x 5 without), divided by the
; tool's speed when it is the right kind (wood 2, stone 4, iron 6,
; diamond 8). Tools wear out.

%include "common.inc"

global inv, cursor, craft_grid, craft_out, craft_size
global inv_clear, inv_add, inv_add_slot, dig_time, can_harvest, block_drop
global tool_wear, item_stack, item_name, craft_update, craft_take
global craft_return, smelt_result, fuel_time, tool_info, wool_rgb, dye_rgb
global furnaces, furnace_find, furnace_add, furnace_remove, furnace_tick
global ents, ent_count, ent_spawn, ent_update, ent_clear, drop_slot
global ent_drop_all, item_valid, tool_of, solid_at, food_heal
global armor, armor_piece, armor_points, armor_wear, armor_rgb

extern world_get, world_set, block_flags, pos, dt, snprintf

NUM_INV     equ 36
NUM_FURNACES equ 32
MAX_ENTS    equ 256
SMELT_TIME  equ 10                  ; seconds per item

; furnace record
FU_X        equ 0
FU_Y        equ 4
FU_Z        equ 8
FU_IN       equ 12                  ; slots (dword each)
FU_FUEL     equ 16
FU_OUT      equ 20
FU_BURN     equ 24                  ; seconds of fuel left (float)
FU_BURNMAX  equ 28
FU_COOK     equ 32                  ; seconds cooked of the current item
FU_USED     equ 36
FU_SIZE     equ 48

; entity record
EN_X        equ 0
EN_Y        equ 4
EN_Z        equ 8
EN_VX       equ 12
EN_VY       equ 16
EN_VZ       equ 20
EN_SLOT     equ 24                  ; item, count, damage like a slot
EN_AGE      equ 28
EN_SIZE     equ 32

T_NONE      equ 0
T_PICK      equ 1
T_AXE       equ 2
T_SHOVEL    equ 3
T_SWORD     equ 4
T_HOE       equ 5

section .rodata
align 4
f_zero:     dd 0.0
f_one:      dd 1.0
f_half:     dd 0.5
f_x15:      dd 1.5
f_x5:       dd 5.0
f_grav:     dd 20.0
f_fric:     dd 0.85
f_pickup:   dd 2.6                  ; squared pickup distance
f_pickage:  dd 0.6
f_despawn:  dd 300.0
f_eyeoff:   dd 0.8
f_smelt:    dd 10.0
f_box:      dd 0.125

; tool speed by tier 1-4
tier_speed: dd 1.0, 2.0, 4.0, 6.0, 8.0
tier_durab: dw 0, 59, 131, 250, 1561
s_toolinfo: db "+%d DAMAGE  DURABILITY %d/%d", 0
s_armorinfo: db "+%d ARMOR  DURABILITY %d/%d", 0
s_flintinfo: db "DURABILITY %d/%d", 0

; armour (Minecraft numbers): points per piece, each 4% less damage, and
; durability; material (leather, iron, diamond) x helmet, chestplate,
; leggings, boots
armor_pts:  db 1, 3, 2, 1,  2, 6, 5, 2,  3, 8, 6, 3
armor_dur:  dw 55, 80, 75, 65,  165, 240, 225, 195,  363, 528, 495, 429
armor_rgb:  db 160, 100, 58,  210, 210, 214,  90, 220, 215

; per block: hardness (float, -1 = cannot be dug), tool kind, needed pick
; tier, drop, drop count
%macro BLK 5
    dd %1
    db %2, %3, %4, %5
%endmacro
BLK_SIZE    equ 8
blk_rules:
    BLK  0.0, T_NONE,   0, 0, 0                 ; air
    BLK  1.5, T_PICK,   1, B_COBBLE, 1          ; stone
    BLK  0.5, T_SHOVEL, 0, B_DIRT, 1            ; dirt
    BLK  0.6, T_SHOVEL, 0, B_DIRT, 1            ; grass
    BLK  0.5, T_SHOVEL, 0, B_SAND, 1            ; sand
    BLK -1.0, T_NONE,   0, 0, 0                 ; water
    BLK  2.0, T_AXE,    0, B_LOG, 1             ; log
    BLK  0.2, T_NONE,   0, 0, 0                 ; leaves
    BLK  0.6, T_SHOVEL, 0, B_DIRT, 1            ; dirt with snow
    BLK  0.5, T_SHOVEL, 0, B_DSAND, 1           ; desert sand
    BLK  0.8, T_PICK,   1, B_DSTONE, 1          ; desert stone
    BLK  0.6, T_SHOVEL, 0, B_DIRT, 1            ; dry grass
    BLK  2.0, T_PICK,   1, B_COBBLE, 1          ; cobble
    BLK  2.0, T_AXE,    0, B_PLANKS, 1          ; planks
    BLK  0.3, T_NONE,   0, 0, 0                 ; glass
    BLK  0.6, T_SHOVEL, 0, B_GRAVEL, 1          ; gravel
    BLK  0.4, T_NONE,   0, B_CACTUS, 1          ; cactus
    BLK  0.2, T_NONE,   0, 0, 0                 ; pine needles
    BLK  0.2, T_SHOVEL, 0, B_SNOW, 1            ; snow block
    BLK  2.0, T_AXE,    0, B_PINELOG, 1         ; pine log
    BLK  2.0, T_PICK,   1, B_BRICK, 1           ; brick
    times 7 dd -1.0, 0                          ; flowing water
    BLK -1.0, T_NONE,   0, 0, 0                 ; bedrock
    BLK  3.0, T_PICK,   1, I_COAL, 1            ; coal ore
    BLK  3.0, T_PICK,   2, B_IRON_ORE, 1        ; iron ore
    BLK  3.0, T_PICK,   3, B_GOLD_ORE, 1        ; gold ore
    BLK  3.0, T_PICK,   3, I_DIAMOND, 1         ; diamond ore
    BLK  2.5, T_AXE,    0, B_CRAFTTABLE, 1      ; crafting table
    BLK  3.5, T_PICK,   1, B_FURNACE, 1         ; furnace
    BLK  3.5, T_PICK,   1, B_FURNACE, 1         ; furnace, burning
    BLK  0.0, T_NONE,   0, B_TORCH, 1           ; torch
    BLK  0.6, T_SHOVEL, 0, I_CLAYBALL, 4        ; clay
    BLK  5.0, T_PICK,   2, B_IRONBLOCK, 1       ; block of iron
    BLK  3.0, T_PICK,   3, B_GOLDBLOCK, 1       ; block of gold
    BLK  5.0, T_PICK,   3, B_DIAMONDBLOCK, 1    ; block of diamond
    BLK  5.0, T_PICK,   1, B_COALBLOCK, 1       ; block of coal
    BLK  0.6, T_SHOVEL, 0, B_DIRT, 1            ; farmland
    BLK  0.0, T_NONE,   0, 0, 0                 ; tall grass (seeds: see dig)
    times 7 dd 0.0, (I_SEEDS << 16) | (1 << 24) ; wheat, growing: a seed back
    BLK  0.0, T_NONE,   0, I_WHEAT, 1           ; wheat, ripe (+ seeds)
    times 4 dd 0.0, (I_CARROT << 16) | (1 << 24); carrots (ripe: + 1..3)
    BLK  2.0, T_AXE,    0, B_FENCE, 1           ; fence
    times 4 dd 2.0, T_AXE | (B_GATE_X << 16) | (1 << 24) ; fence gates
    BLK  0.8, T_NONE,   0, B_WOOL + 0, 1      ; white wool
    BLK  0.8, T_NONE,   0, B_WOOL + 1, 1      ; orange wool
    BLK  0.8, T_NONE,   0, B_WOOL + 2, 1      ; magenta wool
    BLK  0.8, T_NONE,   0, B_WOOL + 3, 1      ; light blue wool
    BLK  0.8, T_NONE,   0, B_WOOL + 4, 1      ; yellow wool
    BLK  0.8, T_NONE,   0, B_WOOL + 5, 1      ; lime wool
    BLK  0.8, T_NONE,   0, B_WOOL + 6, 1      ; pink wool
    BLK  0.8, T_NONE,   0, B_WOOL + 7, 1      ; gray wool
    BLK  0.8, T_NONE,   0, B_WOOL + 8, 1      ; light gray wool
    BLK  0.8, T_NONE,   0, B_WOOL + 9, 1      ; cyan wool
    BLK  0.8, T_NONE,   0, B_WOOL + 10, 1      ; purple wool
    BLK  0.8, T_NONE,   0, B_WOOL + 11, 1      ; blue wool
    BLK  0.8, T_NONE,   0, B_WOOL + 12, 1      ; brown wool
    BLK  0.8, T_NONE,   0, B_WOOL + 13, 1      ; green wool
    BLK  0.8, T_NONE,   0, B_WOOL + 14, 1      ; red wool
    BLK  0.8, T_NONE,   0, B_WOOL + 15, 1      ; black wool
    BLK  1.8, T_PICK,   1, B_CONCRETE + 0, 1  ; white concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 1, 1  ; orange concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 2, 1  ; magenta concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 3, 1  ; light blue concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 4, 1  ; yellow concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 5, 1  ; lime concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 6, 1  ; pink concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 7, 1  ; gray concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 8, 1  ; light gray concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 9, 1  ; cyan concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 10, 1  ; purple concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 11, 1  ; blue concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 12, 1  ; brown concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 13, 1  ; green concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 14, 1  ; red concrete
    BLK  1.8, T_PICK,   1, B_CONCRETE + 15, 1  ; black concrete
    BLK  0.0, T_NONE,   0, B_FLOWER_Y, 1        ; yellow flower
    BLK  0.0, T_NONE,   0, B_FLOWER_R, 1        ; red flower
    BLK  0.2, T_NONE,   0, I_BED, 1             ; bed, foot
    BLK  0.2, T_NONE,   0, I_BED, 1             ; bed, head
    BLK  2.5, T_AXE,    0, B_DYEMAKER, 1        ; dye maker
    times 4 dd -1.0, 0                          ; lava, still and flowing
    BLK 50.0, T_PICK,   4, B_OBSIDIAN, 1        ; obsidian (diamond pickaxe)
    BLK  0.0, T_NONE,   0, B_TNT, 1             ; TNT
    BLK  0.0, T_NONE,   0, 0, 0                 ; fire (punched out)
    BLK  0.4, T_PICK,   1, B_NETHERRACK, 1      ; netherrack
    BLK -1.0, T_NONE,   0, 0, 0                 ; nether portal
    BLK  0.0, T_NONE,   0, B_SLIME, 1           ; slime block
%rep 16
    BLK  0.3, T_NONE,   0, 0, 0                 ; stained glass (breaks, as glass)
%endrep
    BLK  3.0, T_NONE,   0, B_BEACON, 1          ; beacon

; per item id 128..158: tool kind, tier (for non-tools both 0)
item_tools:
    db 0,0, 0,0, 0,0, 0,0, 0,0                  ; stick coal iron gold diamond
    db T_PICK,1, T_PICK,2, T_PICK,3, T_PICK,4
    db T_AXE,1, T_AXE,2, T_AXE,3, T_AXE,4
    db T_SHOVEL,1, T_SHOVEL,2, T_SHOVEL,3, T_SHOVEL,4
    db T_SWORD,1, T_SWORD,2, T_SWORD,3, T_SWORD,4
    db 0,0, 0,0                                 ; clay ball, brick
    db 0,0, 0,0, 0,0, 0,0, 0,0                  ; pork, cooked, beef, steak, flesh
    db 0,0, 0,0, 0,0                            ; spawn eggs
    db T_HOE,1, T_HOE,2, T_HOE,3, T_HOE,4
    db 0,0, 0,0, 0,0, 0,0                       ; seeds, wheat, carrot, bread
    times 3 + 16 db 0,0                         ; leather, shears, bed, dyes
    db 0,0                                      ; sheep spawn egg
    times 12 + 1 db 0,0                         ; armour, boat
    times 7 db 0,0                              ; buckets, flint, flint and steel, gunpowder
    db 0,0                                      ; wither skeleton spawn egg
    times 4 db 0,0                              ; slime, ghast, giant eggs, rifle
    db 0,0                                      ; slimeball

; colours of the 16 wool, concrete and dye colours (r, g, b)
wool_rgb:
    db 233, 236, 236   ; white
    db 240, 118, 19   ; orange
    db 189, 68, 179   ; magenta
    db 58, 175, 217   ; light blue
    db 248, 198, 39   ; yellow
    db 112, 185, 25   ; lime
    db 237, 141, 172   ; pink
    db 62, 68, 71   ; gray
    db 142, 142, 134   ; light gray
    db 21, 137, 145   ; cyan
    db 121, 42, 172   ; purple
    db 53, 57, 157   ; blue
    db 114, 71, 40   ; brown
    db 84, 109, 27   ; green
    db 161, 39, 34   ; red
    db 20, 21, 25   ; black
dye_rgb:
    db 249, 255, 254   ; white
    db 249, 128, 29   ; orange
    db 199, 78, 189   ; magenta
    db 58, 179, 218   ; light blue
    db 254, 216, 61   ; yellow
    db 128, 199, 31   ; lime
    db 243, 139, 170   ; pink
    db 71, 79, 82   ; gray
    db 157, 157, 151   ; light gray
    db 22, 156, 156   ; cyan
    db 137, 50, 184   ; purple
    db 60, 68, 170   ; blue
    db 131, 84, 50   ; brown
    db 94, 124, 22   ; green
    db 176, 46, 38   ; red
    db 29, 29, 33   ; black

; raw pork, cooked pork, raw beef, steak, rotten flesh (Minecraft food points)
food_table: db 3, 8, 3, 8, 4

; recipes: width, height, output, count, 9 cells (row-major w*h), pad
%macro RECIPE 13
    db %1, %2, %3, %4, %5, %6, %7, %8, %9, %10, %11, %12, %13, 0, 0, 0
%endmacro
RC_SIZE     equ 16
P   equ B_PLANKS
S   equ I_STICK
C   equ B_COBBLE
recipes:
    RECIPE 1, 1, B_PLANKS, 4,      B_LOG, 0,0, 0,0,0, 0,0,0
    RECIPE 1, 1, B_PLANKS, 4,      B_PINELOG, 0,0, 0,0,0, 0,0,0
    RECIPE 1, 2, I_STICK, 4,       P, P, 0, 0,0,0, 0,0,0
    RECIPE 2, 2, B_CRAFTTABLE, 1,  P, P, P, P, 0,0, 0,0,0
    RECIPE 1, 2, B_TORCH, 4,       I_COAL, S, 0, 0,0,0, 0,0,0
    RECIPE 3, 3, B_FURNACE, 1,     C, C, C, C, 0, C, C, C, C
    RECIPE 2, 2, B_BRICK, 1,       I_BRICK, I_BRICK, I_BRICK, I_BRICK, 0,0, 0,0,0
    RECIPE 2, 2, B_CLAY, 1,        I_CLAYBALL, I_CLAYBALL, I_CLAYBALL, I_CLAYBALL, 0,0, 0,0,0
%macro STORAGE 2                    ; item, block: 9 make a block, a block gives 9
    RECIPE 3, 3, %2, 1,            %1, %1, %1, %1, %1, %1, %1, %1, %1
    RECIPE 1, 1, %1, 9,            %2, 0,0, 0,0,0, 0,0,0
%endmacro
    STORAGE I_IRON, B_IRONBLOCK
    STORAGE I_GOLD, B_GOLDBLOCK
    STORAGE I_DIAMOND, B_DIAMONDBLOCK
    STORAGE I_COAL, B_COALBLOCK
    RECIPE 3, 1, I_BREAD, 1,       I_WHEAT, I_WHEAT, I_WHEAT, 0,0,0, 0,0,0
    RECIPE 3, 2, B_FENCE, 2,       S, S, S, S, S, S, 0,0,0
    RECIPE 3, 2, B_GATE_X, 1,      S, P, S, S, P, S, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 0, B_WOOL + 0, B_WOOL + 0, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 1, B_WOOL + 1, B_WOOL + 1, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 2, B_WOOL + 2, B_WOOL + 2, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 3, B_WOOL + 3, B_WOOL + 3, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 4, B_WOOL + 4, B_WOOL + 4, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 5, B_WOOL + 5, B_WOOL + 5, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 6, B_WOOL + 6, B_WOOL + 6, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 7, B_WOOL + 7, B_WOOL + 7, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 8, B_WOOL + 8, B_WOOL + 8, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 9, B_WOOL + 9, B_WOOL + 9, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 10, B_WOOL + 10, B_WOOL + 10, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 11, B_WOOL + 11, B_WOOL + 11, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 12, B_WOOL + 12, B_WOOL + 12, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 13, B_WOOL + 13, B_WOOL + 13, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 14, B_WOOL + 14, B_WOOL + 14, P, P, P, 0,0,0
    RECIPE 3, 2, I_BED, 1,         B_WOOL + 15, B_WOOL + 15, B_WOOL + 15, P, P, P, 0,0,0
    RECIPE 2, 2, I_SHEARS, 1,      0, I_IRON, I_IRON, 0, 0,0, 0,0,0
%macro DYEMAKER 1                   ; leather and a flower, side by side or stacked
    RECIPE 2, 1, B_DYEMAKER, 1,    I_LEATHER, %1, 0, 0,0,0, 0,0,0
    RECIPE 1, 2, B_DYEMAKER, 1,    I_LEATHER, %1, 0, 0,0,0, 0,0,0
    RECIPE 1, 2, B_DYEMAKER, 1,    %1, I_LEATHER, 0, 0,0,0, 0,0,0
%endmacro
    DYEMAKER B_FLOWER_Y
    DYEMAKER B_FLOWER_R
%macro TOOLSET 2                    ; material, tier offset
    RECIPE 3, 3, I_PICK + %2, 1,   %1, %1, %1, 0, S, 0, 0, S, 0
    RECIPE 2, 3, I_AXE + %2, 1,    %1, %1, %1, S, 0, S, 0,0,0
    RECIPE 1, 3, I_SHOVEL + %2, 1, %1, S, S, 0,0,0, 0,0,0
    RECIPE 1, 3, I_SWORD + %2, 1,  %1, %1, S, 0,0,0, 0,0,0
    RECIPE 2, 3, I_HOE + %2, 1,    %1, %1, 0, S, 0, S, 0,0,0
%endmacro
    TOOLSET B_PLANKS, 0
    TOOLSET B_COBBLE, 1
    TOOLSET I_IRON, 2
    TOOLSET I_DIAMOND, 3
%macro ARMORSET 2                   ; material, armour id offset
    RECIPE 3, 2, I_ARMOR + %2, 1,     %1, %1, %1, %1, 0, %1, 0,0,0
    RECIPE 3, 3, I_ARMOR + %2 + 1, 1, %1, 0, %1, %1, %1, %1, %1, %1, %1
    RECIPE 3, 3, I_ARMOR + %2 + 2, 1, %1, %1, %1, %1, 0, %1, %1, 0, %1
    RECIPE 3, 2, I_ARMOR + %2 + 3, 1, %1, 0, %1, %1, 0, %1, 0,0,0
%endmacro
    ARMORSET I_LEATHER, 0
    ARMORSET I_IRON, 4
    ARMORSET I_DIAMOND, 8
    RECIPE 3, 2, I_BOAT, 1,        P, 0, P, P, P, P, 0,0,0
    RECIPE 3, 2, I_BUCKET, 1,      I_IRON, 0, I_IRON, 0, I_IRON, 0, 0,0,0
%macro PAIR 4                       ; output, count, two items side by side or stacked
    RECIPE 2, 1, %1, %2,           %3, %4, 0, 0,0,0, 0,0,0
    RECIPE 1, 2, %1, %2,           %3, %4, 0, 0,0,0, 0,0,0
    RECIPE 1, 2, %1, %2,           %4, %3, 0, 0,0,0, 0,0,0
%endmacro
    PAIR I_FLINTSTEEL, 1, I_IRON, I_FLINT
G   equ I_GUNPOWDER
    RECIPE 3, 3, B_TNT, 1,         G, B_SAND, G, B_SAND, G, B_SAND, G, B_SAND, G
SB  equ I_SLIMEBALL
    RECIPE 3, 3, B_SLIME, 1,       SB, SB, SB, SB, SB, SB, SB, SB, SB
    RECIPE 1, 1, I_SLIMEBALL, 9,   B_SLIME, 0, 0, 0,0,0, 0,0,0
GL  equ B_GLASS
%assign c 0
%rep 16                             ; 8 glass round a dye: 8 stained glass
    RECIPE 3, 3, B_SGLASS + c, 8,  GL, GL, GL, GL, I_DYE + c, GL, GL, GL, GL
%assign c c + 1
%endrep
    RECIPE 3, 3, B_BEACON, 1,      GL, GL, GL, GL, I_DIAMOND, GL, B_OBSIDIAN, B_OBSIDIAN, B_OBSIDIAN
    db 0

; item names for tooltips
%macro NAME 1
    db %1, 0
%endmacro
name_table:
n_air:      NAME "AIR"
n_stone:    NAME "STONE"
n_dirt:     NAME "DIRT"
n_grass:    NAME "GRASS BLOCK"
n_sand:     NAME "SAND"
n_water:    NAME "WATER"
n_log:      NAME "LOG"
n_leaves:   NAME "LEAVES"
n_snowdirt: NAME "SNOWY DIRT"
n_dsand:    NAME "DESERT SAND"
n_dstone:   NAME "DESERT STONE"
n_drygrass: NAME "DRY GRASS"
n_cobble:   NAME "COBBLESTONE"
n_planks:   NAME "PLANKS"
n_glass:    NAME "GLASS"
n_gravel:   NAME "GRAVEL"
n_cactus:   NAME "CACTUS"
n_needles:  NAME "PINE NEEDLES"
n_snow:     NAME "SNOW BLOCK"
n_pinelog:  NAME "PINE LOG"
n_brick:    NAME "BRICKS"
n_bedrock:  NAME "BEDROCK"
n_coalore:  NAME "COAL ORE"
n_ironore:  NAME "IRON ORE"
n_goldore:  NAME "GOLD ORE"
n_diaore:   NAME "DIAMOND ORE"
n_table:    NAME "CRAFTING TABLE"
n_furnace:  NAME "FURNACE"
n_torch:    NAME "TORCH"
n_clay:     NAME "CLAY"
n_ironblk:  NAME "BLOCK OF IRON"
n_goldblk:  NAME "BLOCK OF GOLD"
n_diablk:   NAME "BLOCK OF DIAMOND"
n_coalblk:  NAME "BLOCK OF COAL"
n_farmland: NAME "FARMLAND"
n_tallgrass: NAME "TALL GRASS"
n_wheatcrop: NAME "WHEAT CROP"
n_carrotcrop: NAME "CARROTS"
n_fence:    NAME "FENCE"
n_gate:     NAME "FENCE GATE"
n_stick:    NAME "STICK"
n_coal:     NAME "COAL"
n_iron:     NAME "IRON INGOT"
n_gold:     NAME "GOLD INGOT"
n_diamond:  NAME "DIAMOND"
n_wpick:    NAME "WOODEN PICKAXE"
n_spick:    NAME "STONE PICKAXE"
n_ipick:    NAME "IRON PICKAXE"
n_dpick:    NAME "DIAMOND PICKAXE"
n_waxe:     NAME "WOODEN AXE"
n_saxe:     NAME "STONE AXE"
n_iaxe:     NAME "IRON AXE"
n_daxe:     NAME "DIAMOND AXE"
n_wshovel:  NAME "WOODEN SHOVEL"
n_sshovel:  NAME "STONE SHOVEL"
n_ishovel:  NAME "IRON SHOVEL"
n_dshovel:  NAME "DIAMOND SHOVEL"
n_wsword:   NAME "WOODEN SWORD"
n_ssword:   NAME "STONE SWORD"
n_isword:   NAME "IRON SWORD"
n_dsword:   NAME "DIAMOND SWORD"
n_clayball: NAME "CLAY BALL"
n_brickitem: NAME "BRICK"
n_pork:     NAME "RAW PORKCHOP"
n_cpork:    NAME "COOKED PORKCHOP"
n_beef:     NAME "RAW BEEF"
n_steak:    NAME "STEAK"
n_flesh:    NAME "ROTTEN FLESH"
n_eggpig:   NAME "PIG SPAWN EGG"
n_eggcow:   NAME "COW SPAWN EGG"
n_eggzomb:  NAME "ZOMBIE SPAWN EGG"
n_eggsheep: NAME "SHEEP SPAWN EGG"
n_whoe:     NAME "WOODEN HOE"
n_shoe:     NAME "STONE HOE"
n_ihoe:     NAME "IRON HOE"
n_dhoe:     NAME "DIAMOND HOE"
n_seeds:    NAME "WHEAT SEEDS"
n_wheat:    NAME "WHEAT"
n_carrot:   NAME "CARROT"
n_bread:    NAME "BREAD"
n_wool_white: NAME "WHITE WOOL"
n_conc_white: NAME "WHITE CONCRETE"
n_dye_white: NAME "WHITE DYE"
n_wool_orange: NAME "ORANGE WOOL"
n_conc_orange: NAME "ORANGE CONCRETE"
n_dye_orange: NAME "ORANGE DYE"
n_wool_magenta: NAME "MAGENTA WOOL"
n_conc_magenta: NAME "MAGENTA CONCRETE"
n_dye_magenta: NAME "MAGENTA DYE"
n_wool_light_blue: NAME "LIGHT BLUE WOOL"
n_conc_light_blue: NAME "LIGHT BLUE CONCRETE"
n_dye_light_blue: NAME "LIGHT BLUE DYE"
n_wool_yellow: NAME "YELLOW WOOL"
n_conc_yellow: NAME "YELLOW CONCRETE"
n_dye_yellow: NAME "YELLOW DYE"
n_wool_lime: NAME "LIME WOOL"
n_conc_lime: NAME "LIME CONCRETE"
n_dye_lime: NAME "LIME DYE"
n_wool_pink: NAME "PINK WOOL"
n_conc_pink: NAME "PINK CONCRETE"
n_dye_pink: NAME "PINK DYE"
n_wool_gray: NAME "GRAY WOOL"
n_conc_gray: NAME "GRAY CONCRETE"
n_dye_gray: NAME "GRAY DYE"
n_wool_light_gray: NAME "LIGHT GRAY WOOL"
n_conc_light_gray: NAME "LIGHT GRAY CONCRETE"
n_dye_light_gray: NAME "LIGHT GRAY DYE"
n_wool_cyan: NAME "CYAN WOOL"
n_conc_cyan: NAME "CYAN CONCRETE"
n_dye_cyan: NAME "CYAN DYE"
n_wool_purple: NAME "PURPLE WOOL"
n_conc_purple: NAME "PURPLE CONCRETE"
n_dye_purple: NAME "PURPLE DYE"
n_wool_blue: NAME "BLUE WOOL"
n_conc_blue: NAME "BLUE CONCRETE"
n_dye_blue: NAME "BLUE DYE"
n_wool_brown: NAME "BROWN WOOL"
n_conc_brown: NAME "BROWN CONCRETE"
n_dye_brown: NAME "BROWN DYE"
n_wool_green: NAME "GREEN WOOL"
n_conc_green: NAME "GREEN CONCRETE"
n_dye_green: NAME "GREEN DYE"
n_wool_red: NAME "RED WOOL"
n_conc_red: NAME "RED CONCRETE"
n_dye_red: NAME "RED DYE"
n_wool_black: NAME "BLACK WOOL"
n_conc_black: NAME "BLACK CONCRETE"
n_dye_black: NAME "BLACK DYE"
n_yflower:  NAME "YELLOW FLOWER"
n_rflower:  NAME "RED FLOWER"
n_bed:      NAME "BED"
n_dyemaker: NAME "DYE MAKER"
n_leather:  NAME "LEATHER"
n_shears:   NAME "SHEARS"
n_armor:
    NAME "LEATHER CAP"
    NAME "LEATHER TUNIC"
    NAME "LEATHER PANTS"
    NAME "LEATHER BOOTS"
    NAME "IRON HELMET"
    NAME "IRON CHESTPLATE"
    NAME "IRON LEGGINGS"
    NAME "IRON BOOTS"
    NAME "DIAMOND HELMET"
    NAME "DIAMOND CHESTPLATE"
    NAME "DIAMOND LEGGINGS"
    NAME "DIAMOND BOOTS"
n_boat:     NAME "BOAT"
n_lava:     NAME "LAVA"
n_obsidian: NAME "OBSIDIAN"
n_tnt:      NAME "TNT"
n_bucket:   NAME "BUCKET"
n_wbucket:  NAME "WATER BUCKET"
n_lbucket:  NAME "LAVA BUCKET"
n_milk:     NAME "MILK BUCKET"
n_flint:    NAME "FLINT"
n_fsteel:   NAME "FLINT AND STEEL"
n_gunpowder: NAME "GUNPOWDER"
n_fire:     NAME "FIRE"
n_netherrack: NAME "NETHERRACK"
n_portal:   NAME "NETHER PORTAL"
n_eggwither: NAME "WITHER SKELETON SPAWN EGG"
n_eggslime: NAME "SLIME SPAWN EGG"
n_eggghast: NAME "GHAST SPAWN EGG"
n_egggiant: NAME "GIANT SPAWN EGG"
n_rifle:    NAME "ASSAULT RIFLE"
n_slime:    NAME "SLIME BLOCK"
n_slimeball: NAME "SLIMEBALL"
n_sglass_white: NAME "WHITE STAINED GLASS"
n_sglass_orange: NAME "ORANGE STAINED GLASS"
n_sglass_magenta: NAME "MAGENTA STAINED GLASS"
n_sglass_light_blue: NAME "LIGHT BLUE STAINED GLASS"
n_sglass_yellow: NAME "YELLOW STAINED GLASS"
n_sglass_lime: NAME "LIME STAINED GLASS"
n_sglass_pink: NAME "PINK STAINED GLASS"
n_sglass_gray: NAME "GRAY STAINED GLASS"
n_sglass_light_gray: NAME "LIGHT GRAY STAINED GLASS"
n_sglass_cyan: NAME "CYAN STAINED GLASS"
n_sglass_purple: NAME "PURPLE STAINED GLASS"
n_sglass_blue: NAME "BLUE STAINED GLASS"
n_sglass_brown: NAME "BROWN STAINED GLASS"
n_sglass_green: NAME "GREEN STAINED GLASS"
n_sglass_red: NAME "RED STAINED GLASS"
n_sglass_black: NAME "BLACK STAINED GLASS"
n_beacon:   NAME "BEACON"

section .data
align 8
; name pointer for every id (0 = no name: not a real item)
item_name:
    dq n_air, n_stone, n_dirt, n_grass, n_sand, n_water, n_log, n_leaves
    dq n_snowdirt, n_dsand, n_dstone, n_drygrass, n_cobble, n_planks
    dq n_glass, n_gravel, n_cactus, n_needles, n_snow, n_pinelog, n_brick
    times 7 dq n_water
    dq n_bedrock, n_coalore, n_ironore, n_goldore, n_diaore, n_table
    dq n_furnace, n_furnace, n_torch, n_clay
    dq n_ironblk, n_goldblk, n_diablk, n_coalblk
    dq n_farmland, n_tallgrass
    times 8 dq n_wheatcrop
    times 4 dq n_carrotcrop
    dq n_fence
    times 4 dq n_gate
    dq n_wool_white
    dq n_wool_orange
    dq n_wool_magenta
    dq n_wool_light_blue
    dq n_wool_yellow
    dq n_wool_lime
    dq n_wool_pink
    dq n_wool_gray
    dq n_wool_light_gray
    dq n_wool_cyan
    dq n_wool_purple
    dq n_wool_blue
    dq n_wool_brown
    dq n_wool_green
    dq n_wool_red
    dq n_wool_black
    dq n_conc_white
    dq n_conc_orange
    dq n_conc_magenta
    dq n_conc_light_blue
    dq n_conc_yellow
    dq n_conc_lime
    dq n_conc_pink
    dq n_conc_gray
    dq n_conc_light_gray
    dq n_conc_cyan
    dq n_conc_purple
    dq n_conc_blue
    dq n_conc_brown
    dq n_conc_green
    dq n_conc_red
    dq n_conc_black
    dq n_yflower, n_rflower, n_bed, n_bed, n_dyemaker
    times 4 dq n_lava
    dq n_obsidian, n_tnt, n_fire, n_netherrack, n_portal, n_slime
    dq n_sglass_white
    dq n_sglass_orange
    dq n_sglass_magenta
    dq n_sglass_light_blue
    dq n_sglass_yellow
    dq n_sglass_lime
    dq n_sglass_pink
    dq n_sglass_gray
    dq n_sglass_light_gray
    dq n_sglass_cyan
    dq n_sglass_purple
    dq n_sglass_blue
    dq n_sglass_brown
    dq n_sglass_green
    dq n_sglass_red
    dq n_sglass_black
    dq n_beacon
    times 128 - NUM_BLOCKS dq 0
    dq n_stick, n_coal, n_iron, n_gold, n_diamond
    dq n_wpick, n_spick, n_ipick, n_dpick, n_waxe, n_saxe, n_iaxe, n_daxe
    dq n_wshovel, n_sshovel, n_ishovel, n_dshovel
    dq n_wsword, n_ssword, n_isword, n_dsword
    dq n_clayball, n_brickitem
    dq n_pork, n_cpork, n_beef, n_steak, n_flesh
    dq n_eggpig, n_eggcow, n_eggzomb
    dq n_whoe, n_shoe, n_ihoe, n_dhoe, n_seeds, n_wheat, n_carrot, n_bread
    dq n_leather, n_shears, n_bed
    dq n_dye_white
    dq n_dye_orange
    dq n_dye_magenta
    dq n_dye_light_blue
    dq n_dye_yellow
    dq n_dye_lime
    dq n_dye_pink
    dq n_dye_gray
    dq n_dye_light_gray
    dq n_dye_cyan
    dq n_dye_purple
    dq n_dye_blue
    dq n_dye_brown
    dq n_dye_green
    dq n_dye_red
    dq n_dye_black
    dq n_eggsheep
    times 12 dq 0                   ; armour: filled in by init_tables
    dq n_boat
    dq n_bucket, n_wbucket, n_lbucket, n_milk, n_flint, n_fsteel, n_gunpowder
    dq n_eggwither, n_eggslime, n_eggghast, n_egggiant, n_rifle
    dq n_slimeball
    times 256 - I_END dq 0

section .bss
alignb 16
smelt_result: resb 256              ; result of smelting each id (filled once)
fuel_time:  resb 256                ; seconds of fuel each id gives
inv:        resd NUM_INV
armor:      resd 4                  ; worn: helmet, chestplate, leggings, boots
armor_frac: resd 1                  ; damage x 25 not yet taken (rounding)
cursor:     resd 1
craft_grid: resd 9
craft_out:  resd 1
craft_size: resd 1
furnaces:   resb NUM_FURNACES * FU_SIZE
ents:       resb MAX_ENTS * EN_SIZE
ent_count:  resd 1
tables_ready: resd 1

section .text

; fill the smelting and fuel tables once
init_tables:
    cmp dword [tables_ready], 0
    jne .out
    mov dword [tables_ready], 1
    ; armour names, one after the other in n_armor
    lea rcx, [n_armor]
    lea rdx, [item_name]
    mov eax, I_ARMOR
.an:
    mov [rdx + rax*8], rcx
.anc:
    inc rcx
    cmp byte [rcx - 1], 0
    jne .anc
    inc eax
    cmp eax, I_ARMOR + 12
    jb .an
    ; logs, ores (coal and diamond drop as items), cobblestone, sand, clay
    ; and raw meat
    lea rax, [smelt_result]
    mov byte [rax + B_SAND], B_GLASS
    mov byte [rax + B_DSAND], B_GLASS
    mov byte [rax + I_CLAYBALL], I_BRICK
    mov byte [rax + I_PORK], I_COOKEDPORK
    mov byte [rax + I_BEEF], I_STEAK
    mov byte [rax + B_COBBLE], B_STONE
    mov byte [rax + B_IRON_ORE], I_IRON
    mov byte [rax + B_GOLD_ORE], I_GOLD
    mov byte [rax + B_LOG], I_COAL
    mov byte [rax + B_PINELOG], I_COAL
    lea rax, [fuel_time]
    mov byte [rax + I_COAL], 80
    mov byte [rax + B_COALBLOCK], 240
    mov byte [rax + B_FENCE], 15
    mov byte [rax + B_GATE_X], 15
    mov byte [rax + I_HOE], 10
    mov byte [rax + B_LOG], 15
    mov byte [rax + B_PINELOG], 15
    mov byte [rax + B_PLANKS], 15
    mov byte [rax + B_CRAFTTABLE], 15
    mov byte [rax + I_STICK], 5
    mov byte [rax + I_PICK], 10
    mov byte [rax + I_AXE], 10
    mov byte [rax + I_SHOVEL], 10
    mov byte [rax + I_SWORD], 10
.out:
    ret

; int item_valid(int id) - a real item or block someone can hold
item_valid:
    mov edi, edi                    ; int argument: clear the upper half
    xor eax, eax
    cmp edi, 255
    ja .out
    lea rcx, [item_name]
    cmp qword [rcx + rdi*8], 0
    je .out
    test edi, edi
    jz .out
    cmp edi, B_WATER
    je .out
    lea ecx, [rdi - B_WFLOW1]
    cmp ecx, B_WFLOW7 - B_WFLOW1
    jbe .out
    lea ecx, [rdi - B_LAVA]
    cmp ecx, B_LFLOW3 - B_LAVA
    jbe .out                        ; lava comes in a bucket
    cmp edi, B_FIRE
    je .out
    cmp edi, B_PORTAL
    je .out
    cmp edi, B_FURNACE_LIT
    je .out
    cmp edi, B_FARMLAND
    je .out
    lea ecx, [rdi - B_WHEAT0]
    cmp ecx, B_CARROT3 - B_WHEAT0
    jbe .out                        ; crops come from seeds and carrots
    lea ecx, [rdi - B_GATE_Z]
    cmp ecx, B_GATEOPEN_Z - B_GATE_Z
    jbe .out                        ; one gate item, placed facing the player
    cmp edi, B_BED_FOOT
    je .out
    cmp edi, B_BED_HEAD
    je .out                         ; the bed item places both halves
    mov eax, 1
.out:
    ret

; int item_stack(int id) - stack limit: 1 for tools, 64 otherwise
item_stack:
    mov eax, 64
    cmp edi, I_PICK
    jb .out
    cmp edi, I_SWORD + 4
    jb .tool
    cmp edi, I_HOE
    jb .out
    cmp edi, I_HOE + 4
    jb .tool
    cmp edi, I_SHEARS
    je .tool
    cmp edi, I_ARMOR
    jb .bed
    cmp edi, I_BOAT
    jbe .tool                       ; armour and boats
    mov eax, 16
    cmp edi, I_BUCKET
    je .out                         ; empty buckets: 16
    mov eax, 1
    cmp edi, I_MILK
    jbe .out                        ; full buckets
    cmp edi, I_FLINTSTEEL
    je .out
    cmp edi, I_RIFLE
    je .out
    mov eax, 64
.bed:
    cmp edi, I_BED
    jne .out
.tool:
    mov eax, 1
.out:
    ret

; tool kind (ecx) and tier (eax) of item edi
tool_of:
    xor eax, eax
    xor ecx, ecx
    cmp edi, I_FIRST
    jb .out
    cmp edi, I_END
    jae .out
    lea rdx, [item_tools]
    lea r8d, [rdi - I_FIRST]
    movzx ecx, byte [rdx + r8*2]
    movzx eax, byte [rdx + r8*2 + 1]
.out:
    ret

; int tool_info(u32 slot, char *out, int size) - for a tool: "+3 DAMAGE
; DURABILITY 52/59" (damage above a bare hand, as in mob_attack; uses
; left of all). Returns the length, 0 (nothing written) for other items.
tool_info:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    movzx edi, bl
    call armor_piece
    test eax, eax
    jns .armor
    cmp bl, I_FLINTSTEEL
    je .flint
    movzx edi, bl
    call tool_of                    ; ecx kind, eax tier
    test ecx, ecx
    jz .none
    mov edx, 1
    cmp ecx, T_SWORD
    jne .d1
    lea edx, [rax + 3]
.d1:
    cmp ecx, T_AXE
    jne .d2
    lea edx, [rax + 2]
.d2:
    cmp ecx, T_PICK
    jne .d3
    lea edx, [rax + 1]
.d3:
    cmp ecx, T_SHOVEL
    jne .d4
    mov edx, eax
.d4:
    lea ecx, [rdx - 1]              ; above a bare hand
    lea rdx, [tier_durab]
    movzx r9d, word [rdx + rax*2]   ; durability
    mov r8d, ebx
    shr r8d, 16                     ; used
    neg r8d
    add r8d, r9d                    ; left
    mov rdi, r12
    mov esi, r13d
    lea rdx, [s_toolinfo]
    xor eax, eax
    call snprintf PLT
    jmp .out
.armor:
    movzx eax, bl
    sub eax, I_ARMOR
    lea rdx, [armor_pts]
    movzx ecx, byte [rdx + rax]
    lea rdx, [armor_dur]
    movzx r9d, word [rdx + rax*2]
    mov r8d, ebx
    shr r8d, 16
    neg r8d
    add r8d, r9d
    mov rdi, r12
    mov esi, r13d
    lea rdx, [s_armorinfo]
    xor eax, eax
    call snprintf PLT
    jmp .out
.flint:
    mov ecx, ebx
    shr ecx, 16
    neg ecx
    add ecx, FLINT_USES             ; left
    mov r8d, FLINT_USES
    mov rdi, r12
    mov esi, r13d
    lea rdx, [s_flintinfo]
    xor eax, eax
    call snprintf PLT
    jmp .out
.none:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; int food_heal(int item) - half hearts eating it gives back (0: not food)
food_heal:
    mov eax, 3
    cmp edi, I_CARROT
    je .out
    mov eax, 5
    cmp edi, I_BREAD
    je .out
    xor eax, eax
    cmp edi, I_PORK
    jb .out
    cmp edi, I_FLESH
    ja .out
    lea rcx, [food_table]
    movzx eax, byte [rcx + rdi - I_PORK]
.out:
    ret

; void inv_clear(void)
inv_clear:
    call init_tables
    lea rdi, [inv]
    xor eax, eax
    mov ecx, NUM_INV + 1 + 9 + 1
    rep stosd
    lea rdi, [armor]
    mov ecx, 4 + 1
    rep stosd
    ret

; int armor_piece(int id) - 0 helmet, 1 chestplate, 2 leggings, 3 boots,
; -1 for anything that is not armour
armor_piece:
    lea eax, [rdi - I_ARMOR]
    cmp eax, 12
    jae .no
    and eax, 3
    ret
.no:
    mov eax, -1
    ret

; int armor_points(void) - armour worn (0-20)
armor_points:
    xor eax, eax
    xor ecx, ecx
    lea r8, [armor]
    lea r9, [armor_pts]
.p:
    movzx edx, byte [r8 + rcx*4]
    sub edx, I_ARMOR
    cmp edx, 12
    jae .n
    movzx edx, byte [r9 + rdx]
    add eax, edx
.n:
    inc ecx
    cmp ecx, 4
    jb .p
    ret

; int armor_wear(int damage) - a hit of damage half hearts on the armour:
; returns what gets through (4% less per point, fractions carried to the
; next hit); each piece worn loses damage / 4 (at least 1) durability
armor_wear:
    push rbx
    mov ebx, edi
    call armor_points
    mov ecx, 25
    sub ecx, eax
    mov eax, ebx
    imul eax, ecx
    add eax, [armor_frac]
    xor edx, edx
    mov ecx, 25
    div ecx
    mov [armor_frac], edx
    mov r10d, eax                   ; what gets through
    mov r11d, ebx
    shr r11d, 2
    mov eax, 1
    cmp r11d, eax
    cmovb r11d, eax                 ; wear per piece
    lea r8, [armor]
    lea r9, [armor_dur]
    xor ecx, ecx
.w:
    movzx edx, byte [r8 + rcx*4]
    sub edx, I_ARMOR
    cmp edx, 12
    jae .wn
    movzx edx, word [r9 + rdx*2]
    movzx eax, word [r8 + rcx*4 + 2]
    add eax, r11d
    cmp eax, edx
    jae .broken
    mov [r8 + rcx*4 + 2], ax
    jmp .wn
.broken:
    mov dword [r8 + rcx*4], 0
.wn:
    inc ecx
    cmp ecx, 4
    jb .w
    mov eax, r10d
    pop rbx
    ret

; int inv_add_slot(int slotdword) - add a stack to the inventory: first
; onto matching stacks, then into empty slots (hotbar first). Returns the
; slot dword of what did not fit (0 if everything did).
inv_add_slot:
    push rbx
    push r12
    push r13
    mov r12d, edi
    movzx edi, r12b
    call item_stack
    mov r13d, eax                   ; stack limit
    lea rbx, [inv]
    cmp r13d, 1
    je .empty                       ; tools never merge
    xor ecx, ecx
.merge:
    movzx eax, byte [rbx + rcx*4]
    cmp al, r12b
    jne .mn
    movzx eax, byte [rbx + rcx*4 + 1]
    mov edx, r12d
    shr edx, 8
    and edx, 0xff                   ; wanted
    mov r8d, r13d
    sub r8d, eax                    ; room
    jle .mn
    cmp edx, r8d
    jbe .fits
    mov edx, r8d
.fits:
    add [rbx + rcx*4 + 1], dl
    mov eax, r12d
    shr eax, 8
    and eax, 0xff
    sub eax, edx
    jz .done
    and r12d, 0xffff00ff
    shl eax, 8
    or r12d, eax
.mn:
    inc ecx
    cmp ecx, NUM_INV
    jb .merge
.empty:
    xor ecx, ecx
.e:
    cmp dword [rbx + rcx*4], 0
    jne .en
    ; as much as one stack holds
    mov eax, r12d
    shr eax, 8
    and eax, 0xff                   ; still to place
    mov edx, eax
    cmp edx, r13d
    jbe .efit
    mov edx, r13d
.efit:
    mov r8d, r12d
    and r8d, 0xffff00ff
    mov r9d, edx
    shl r9d, 8
    or r8d, r9d
    mov [rbx + rcx*4], r8d
    sub eax, edx
    jz .done
    and r12d, 0xffff00ff
    shl eax, 8
    or r12d, eax
.en:
    inc ecx
    cmp ecx, NUM_INV
    jb .e
    mov eax, r12d                   ; full: hand it back
    jmp .out
.done:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; int inv_add(int item, int count) - returns how many did not fit
inv_add:
    sub rsp, 8
    shl esi, 8
    or edi, esi
    call inv_add_slot
    shr eax, 8
    and eax, 0xff
    add rsp, 8
    ret

; float dig_time(int block, int held_item) - seconds, -1 = cannot be dug
dig_time:
    push rbx
    call init_tables
    mov ebx, edi
    cmp ebx, NUM_BLOCKS
    jae .never
    imul eax, ebx, BLK_SIZE
    lea r9, [blk_rules]
    add r9, rax
    movss xmm0, [r9]                ; hardness
    comiss xmm0, [f_zero]
    jb .out
    mov edi, esi
    call tool_of                    ; ecx kind, eax tier
    movss xmm1, [f_one]             ; speed
    movzx edx, byte [r9 + 4]        ; preferred tool
    test edx, edx
    jz .speed_done
    cmp ecx, edx
    jne .speed_done
    lea r8, [tier_speed]
    movss xmm1, [r8 + rax*4]
.speed_done:
    ; usable tool: needs the right pick tier when one is required
    movzx edx, byte [r9 + 5]
    mulss xmm0, [f_x15]
    test edx, edx
    jz .div
    cmp ecx, T_PICK
    jne .slow
    cmp eax, edx
    jae .div
.slow:
    movss xmm0, [r9]
    mulss xmm0, [f_x5]
.div:
    divss xmm0, xmm1
.out:
    pop rbx
    ret
.never:
    mov eax, 0xbf800000             ; -1.0
    movd xmm0, eax
    pop rbx
    ret

; int can_harvest(int block, int held_item) - 1 if digging drops something
can_harvest:
    xor eax, eax
    cmp edi, NUM_BLOCKS
    jae .out
    imul eax, edi, BLK_SIZE
    lea r9, [blk_rules]
    movzx r10d, byte [r9 + rax + 5]
    mov eax, 1
    test r10d, r10d
    jz .out
    mov edi, esi
    call tool_of
    cmp ecx, T_PICK
    jne .no
    cmp eax, r10d
    jae .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
.out:
    ret

; int block_drop(int block) - slot dword of what digging it gives
block_drop:
    xor eax, eax
    cmp edi, NUM_BLOCKS
    jae .out
    imul eax, edi, BLK_SIZE
    lea r9, [blk_rules]
    movzx ecx, byte [r9 + rax + 6]
    movzx eax, byte [r9 + rax + 7]
    shl eax, 8
    or eax, ecx
    test ecx, ecx
    jnz .out
    xor eax, eax
.out:
    ret

; void tool_wear(int slot) - one use of the tool in an inventory slot
tool_wear:
    mov edi, edi
    lea r8, [inv]
    movzx ecx, byte [r8 + rdi*4]
    cmp ecx, I_PICK
    jb .out
    cmp ecx, I_END
    jae .out
    push rdi
    mov edi, ecx
    call tool_of                    ; clobbers r8
    pop rdi
    test ecx, ecx
    jz .out                         ; not a tool: nothing wears
    lea r8, [inv]
    lea r9, [tier_durab]
    movzx edx, word [r9 + rax*2]
    movzx eax, word [r8 + rdi*4 + 2]
    inc eax
    cmp eax, edx
    jae .broken
    mov [r8 + rdi*4 + 2], ax
    ret
.broken:
    mov dword [r8 + rdi*4], 0
.out:
    ret

; ---------------------------------------------------------------------------
; crafting

; eax = result of the recipes that are not a fixed shape, or 0:
;   concrete: a dye in the middle, 4 sand and 4 gravel round it -> 8
;   wool: one white wool and one dye, nothing else -> 1 of that colour
craft_special:
    xor ecx, ecx                    ; filled cells
    xor edx, edx                    ; sand
    xor r8d, r8d                    ; gravel
    xor r9d, r9d                    ; dyes
    xor r10d, r10d                  ; white wool
    mov r11d, -1                    ; dye colour
    lea rsi, [craft_grid]
    xor edi, edi
.c:
    movzx eax, byte [rsi + rdi*4]
    test eax, eax
    jz .n
    inc ecx
    cmp eax, B_SAND
    je .sand
    cmp eax, B_DSAND
    je .sand
    cmp eax, B_GRAVEL
    je .gravel
    cmp eax, B_WOOL
    je .wool
    sub eax, I_DYE
    cmp eax, 15
    ja .n
    inc r9d
    mov r11d, eax
    jmp .n
.sand:
    inc edx
    jmp .n
.gravel:
    inc r8d
    jmp .n
.wool:
    inc r10d
.n:
    inc edi
    cmp edi, 9
    jb .c
    cmp r9d, 1
    jne .none                       ; both need exactly one dye
    cmp ecx, 9
    jne .woolq
    cmp edx, 4
    jne .none
    cmp r8d, 4
    jne .none
    movzx eax, byte [rsi + 4 * 4]   ; the dye in the middle
    sub eax, I_DYE
    cmp eax, 15
    ja .none
    lea eax, [r11 + B_CONCRETE + (8 << 8)]
    ret
.woolq:
    cmp ecx, 2
    jne .none
    cmp r10d, 1
    jne .none
    lea eax, [r11 + B_WOOL + (1 << 8)]
    ret
.none:
    xor eax, eax
    ret

; void craft_update(void) - craft_out from craft_grid (craft_size 2 or 3)
; locals: [0] minx, [4] maxx, [8] miny, [12] maxy
craft_update:
    ENTER_FN 16
    mov dword [craft_out], 0
    call craft_special
    test eax, eax
    jz .shaped
    mov [craft_out], eax
    LEAVE_FN
.shaped:
    mov dword [rsp], 9
    mov dword [rsp + 4], -1
    mov dword [rsp + 8], 9
    mov dword [rsp + 12], -1
    lea rbx, [craft_grid]
    xor ecx, ecx
.bb:
    movzx eax, byte [rbx + rcx*4]
    test eax, eax
    jz .bbn
    mov eax, ecx
    xor edx, edx
    mov r8d, 3
    div r8d                         ; eax row, edx column
    cmp edx, [rsp]
    jge .b1
    mov [rsp], edx
.b1:
    cmp edx, [rsp + 4]
    jle .b2
    mov [rsp + 4], edx
.b2:
    cmp eax, [rsp + 8]
    jge .b3
    mov [rsp + 8], eax
.b3:
    cmp eax, [rsp + 12]
    jle .bbn
    mov [rsp + 12], eax
.bbn:
    inc ecx
    cmp ecx, 9
    jb .bb
    cmp dword [rsp + 4], 0
    jl .out                         ; empty grid
    mov r12d, [rsp + 4]
    sub r12d, [rsp]
    inc r12d                        ; width
    mov r13d, [rsp + 12]
    sub r13d, [rsp + 8]
    inc r13d                        ; height
    lea r14, [recipes]
.rec:
    movzx eax, byte [r14]
    test eax, eax
    jz .out
    cmp eax, r12d
    jne .rnext
    movzx eax, byte [r14 + 1]
    cmp eax, r13d
    jne .rnext
    xor r15d, r15d                  ; 0 = as is, 1 = mirrored
.try:
    xor r8d, r8d                    ; row
.row:
    xor r9d, r9d                    ; column
.col:
    ; grid cell (miny + row, minx + col)
    mov eax, [rsp + 8]
    add eax, r8d
    imul eax, eax, 3
    add eax, [rsp]
    add eax, r9d
    movzx edx, byte [rbx + rax*4]
    ; recipe cell (row, col or mirrored col)
    mov eax, r9d
    test r15d, r15d
    jz .nm
    mov eax, r12d
    dec eax
    sub eax, r9d
.nm:
    mov ecx, r8d
    imul ecx, r12d
    add eax, ecx
    movzx eax, byte [r14 + 4 + rax]
    cmp eax, edx
    jne .fail
    inc r9d
    cmp r9d, r12d
    jb .col
    inc r8d
    cmp r8d, r13d
    jb .row
    ; match
    movzx eax, byte [r14 + 2]
    movzx ecx, byte [r14 + 3]
    shl ecx, 8
    or eax, ecx
    mov [craft_out], eax
    jmp .out
.fail:
    inc r15d
    cmp r15d, 2
    jb .try
.rnext:
    add r14, RC_SIZE
    jmp .rec
.out:
    LEAVE_FN

; void craft_take(void) - use up one of each ingredient
craft_take:
    lea rax, [craft_grid]
    xor ecx, ecx
.c:
    movzx edx, byte [rax + rcx*4]
    test edx, edx
    jz .n
    dec byte [rax + rcx*4 + 1]
    jnz .n
    mov dword [rax + rcx*4], 0
.n:
    inc ecx
    cmp ecx, 9
    jb .c
    jmp craft_update

; void craft_return(void) - grid and cursor back into the inventory; what
; does not fit is dropped at the player's feet
craft_return:
    push rbx
    push r12
    sub rsp, 8
    lea rbx, [craft_grid]
    xor r12d, r12d
.g:
    mov edi, [rbx + r12*4]
    test edi, edi
    jz .gn
    mov dword [rbx + r12*4], 0
    call inv_add_slot
    test eax, eax
    jz .gn
    mov edi, eax
    call drop_slot
.gn:
    inc r12d
    cmp r12d, 9
    jb .g
    mov edi, [cursor]
    test edi, edi
    jz .done
    mov dword [cursor], 0
    call inv_add_slot
    test eax, eax
    jz .done
    mov edi, eax
    call drop_slot
.done:
    mov dword [craft_out], 0
    add rsp, 8
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; furnaces

; int furnace_find(int x, int y, int z) - index or -1
furnace_find:
    lea rax, [furnaces]
    xor ecx, ecx
.f:
    cmp byte [rax + FU_USED], 0
    je .n
    cmp [rax + FU_X], edi
    jne .n
    cmp [rax + FU_Y], esi
    jne .n
    cmp [rax + FU_Z], edx
    jne .n
    mov eax, ecx
    ret
.n:
    add rax, FU_SIZE
    inc ecx
    cmp ecx, NUM_FURNACES
    jb .f
    mov eax, -1
    ret

; int furnace_add(int x, int y, int z) - index or -1 when all are used
furnace_add:
    lea r8, [furnaces]
    xor ecx, ecx
.f:
    cmp byte [r8 + FU_USED], 0
    jne .n
    xor eax, eax
    mov [r8], rax
    mov [r8 + 8], rax
    mov [r8 + 16], rax
    mov [r8 + 24], rax
    mov [r8 + 32], rax
    mov [r8 + 40], rax
    mov [r8 + FU_X], edi
    mov [r8 + FU_Y], esi
    mov [r8 + FU_Z], edx
    mov byte [r8 + FU_USED], 1
    mov eax, ecx
    ret
.n:
    add r8, FU_SIZE
    inc ecx
    cmp ecx, NUM_FURNACES
    jb .f
    mov eax, -1
    ret

; void furnace_remove(int x, int y, int z) - drop its contents and forget it
furnace_remove:
    push rbx
    push r12
    sub rsp, 8
    call furnace_find
    test eax, eax
    js .out
    imul eax, eax, FU_SIZE
    lea rbx, [furnaces]
    add rbx, rax
    mov byte [rbx + FU_USED], 0
    xor r12d, r12d
.s:
    mov edi, [rbx + FU_IN + r12*4]
    test edi, edi
    jz .sn
    call drop_slot
.sn:
    inc r12d
    cmp r12d, 3
    jb .s
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; can the furnace at rbx smelt its input into its output? ZF clear = yes,
; eax = result id
can_smelt:
    movzx eax, byte [rbx + FU_IN]
    test eax, eax
    jz .no
    lea rcx, [smelt_result]
    movzx eax, byte [rcx + rax]
    test eax, eax
    jz .no
    movzx ecx, byte [rbx + FU_OUT]
    test ecx, ecx
    jz .yes
    cmp ecx, eax
    jne .no
    cmp byte [rbx + FU_OUT + 1], 64
    jae .no
.yes:
    test eax, eax                   ; eax != 0: ZF clear
    ret
.no:
    xor eax, eax
    ret

; void furnace_tick(float dt in xmm0) - burn fuel, cook, light up
; locals: [0] dt
furnace_tick:
    ENTER_FN 16
    call init_tables
    movss [rsp], xmm0
    lea rbx, [furnaces]
    xor r12d, r12d
.f:
    cmp byte [rbx + FU_USED], 0
    je .next
    movss xmm0, [rbx + FU_BURN]
    comiss xmm0, [f_zero]
    ja .burning
    ; not burning: light new fuel if there is something to smelt
    call can_smelt
    jz .idle
    movzx eax, byte [rbx + FU_FUEL]
    lea rcx, [fuel_time]
    movzx eax, byte [rcx + rax]
    test eax, eax
    jz .idle
    cvtsi2ss xmm0, eax
    movss [rbx + FU_BURN], xmm0
    movss [rbx + FU_BURNMAX], xmm0
    dec byte [rbx + FU_FUEL + 1]
    jnz .burning
    mov dword [rbx + FU_FUEL], 0
.burning:
    movss xmm0, [rbx + FU_BURN]
    subss xmm0, [rsp]
    maxss xmm0, [f_zero]
    movss [rbx + FU_BURN], xmm0
    call can_smelt
    jz .nocook
    mov r13d, eax                   ; result
    movss xmm0, [rbx + FU_COOK]
    addss xmm0, [rsp]
    movss [rbx + FU_COOK], xmm0
    comiss xmm0, [f_smelt]
    jb .lit
    mov dword [rbx + FU_COOK], 0
    dec byte [rbx + FU_IN + 1]
    jnz .in_left
    mov dword [rbx + FU_IN], 0
.in_left:
    cmp byte [rbx + FU_OUT], 0
    jne .more
    mov [rbx + FU_OUT], r13b
    mov byte [rbx + FU_OUT + 1], 1
    jmp .lit
.more:
    inc byte [rbx + FU_OUT + 1]
    jmp .lit
.nocook:
    mov dword [rbx + FU_COOK], 0
.lit:
    movss xmm0, [rbx + FU_BURN]
    comiss xmm0, [f_zero]
    mov r13d, B_FURNACE_LIT
    ja .setblock
.idle:
    mov dword [rbx + FU_COOK], 0
    mov r13d, B_FURNACE
.setblock:
    ; switch the block between lit and unlit only when it changes
    mov edi, [rbx + FU_X]
    mov esi, [rbx + FU_Y]
    mov edx, [rbx + FU_Z]
    call world_get
    cmp eax, B_FURNACE
    je .isf
    cmp eax, B_FURNACE_LIT
    jne .gone
.isf:
    cmp eax, r13d
    je .next
    mov edi, [rbx + FU_X]
    mov esi, [rbx + FU_Y]
    mov edx, [rbx + FU_Z]
    mov ecx, r13d
    call world_set
    jmp .next
.gone:
    cmp eax, B_UNKNOWN              ; chunk not loaded: keep it
    je .next
    mov byte [rbx + FU_USED], 0     ; block replaced somehow
.next:
    add rbx, FU_SIZE
    inc r12d
    cmp r12d, NUM_FURNACES
    jb .f
    LEAVE_FN

; ---------------------------------------------------------------------------
; dropped items

; void ent_clear(void)
ent_clear:
    mov dword [ent_count], 0
    ret

; void ent_spawn(float x, y, z, vx, vy, vz in xmm0..5, int slotdword)
ent_spawn:
    mov eax, [ent_count]
    cmp eax, MAX_ENTS
    jb .room
    ; full: overwrite the oldest (index 0) by shifting is costly, so reuse 0
    xor eax, eax
    jmp .put
.room:
    inc dword [ent_count]
.put:
    shl eax, 5
    lea rcx, [ents]
    add rcx, rax
    movss [rcx + EN_X], xmm0
    movss [rcx + EN_Y], xmm1
    movss [rcx + EN_Z], xmm2
    movss [rcx + EN_VX], xmm3
    movss [rcx + EN_VY], xmm4
    movss [rcx + EN_VZ], xmm5
    mov [rcx + EN_SLOT], edi
    mov dword [rcx + EN_AGE], 0
    ret

; void drop_slot(int slotdword) - toss a stack from the player
drop_slot:
    sub rsp, 8
    movss xmm0, [pos]
    movss xmm1, [pos + 4]
    addss xmm1, [f_one]
    movss xmm2, [pos + 8]
    xorps xmm3, xmm3
    movss xmm4, [f_x5]
    xorps xmm5, xmm5
    call ent_spawn
    add rsp, 8
    ret

; void ent_drop_all(void) - death: the whole inventory falls out
ent_drop_all:
    push rbx
    push r12
    sub rsp, 8
    lea rbx, [inv]
    xor r12d, r12d
.s:
    mov edi, [rbx + r12*4]
    test edi, edi
    jz .n
    mov dword [rbx + r12*4], 0
    ; spread them a little using the slot number
    movss xmm0, [pos]
    movss xmm1, [pos + 4]
    addss xmm1, [f_one]
    movss xmm2, [pos + 8]
    mov eax, r12d
    and eax, 7
    sub eax, 4
    cvtsi2ss xmm3, eax
    mulss xmm3, [f_half]
    movss xmm4, [f_x5]
    mov eax, r12d
    shr eax, 3
    sub eax, 2
    cvtsi2ss xmm5, eax
    call ent_spawn
.n:
    inc r12d
    cmp r12d, NUM_INV + 4           ; the armour slots follow inv
    jb .s
    add rsp, 8
    pop r12
    pop rbx
    ret

; is the node at (xmm0, xmm1, xmm2) solid? ZF clear = solid
%macro FLOORF 3
    cvttss2si %1, %2
    cvtsi2ss %3, %1
    comiss %3, %2
    jbe %%ok
    dec %1
%%ok:
%endmacro
; (the lower half of the node above a fence or closed gate counts as
; solid: they are 1.5 nodes tall)
; locals: [0] y, [4] x, [8] y node, [12] z
solid_at:
    sub rsp, 24
    movss [rsp], xmm1
    FLOORF edi, xmm0, xmm7
    FLOORF esi, xmm1, xmm7
    FLOORF edx, xmm2, xmm7
    mov [rsp + 4], edi
    mov [rsp + 8], esi
    mov [rsp + 12], edx
    call world_get
    lea rcx, [block_flags]
    movzx eax, byte [rcx + rax]
    test eax, F_HALF                ; a bed: solid below half a node
    jz .nothalf
    cvtsi2ss xmm7, dword [rsp + 8]
    movss xmm6, [rsp]
    subss xmm6, xmm7
    xor eax, eax
    comiss xmm6, [f_half]
    jae .done
    mov eax, F_SOLID
    jmp .done
.nothalf:
    and eax, F_SOLID
    jnz .done
    mov edi, [rsp + 4]
    mov esi, [rsp + 8]
    dec esi
    mov edx, [rsp + 12]
    call world_get
    lea rcx, [block_flags]
    movzx eax, byte [rcx + rax]
    and eax, F_SOLID | F_FENCE
    cmp eax, F_SOLID | F_FENCE
    mov eax, 0
    jne .done
    cvtsi2ss xmm7, dword [rsp + 8]
    movss xmm6, [rsp]
    subss xmm6, xmm7
    comiss xmm6, [f_half]
    jae .done
    mov eax, F_SOLID
.done:
    add rsp, 24
    test eax, eax                   ; last: the flags are the result
    ret

; void ent_update(void) - gravity, ground, pickup, despawn
; r12 index, rbx record
ent_update:
    ENTER_FN 16
    xor r12d, r12d
.e:
    cmp r12d, [ent_count]
    jae .out
    mov eax, r12d
    shl eax, 5
    lea rbx, [ents]
    add rbx, rax
    ; age
    movss xmm0, [rbx + EN_AGE]
    addss xmm0, [dt]
    movss [rbx + EN_AGE], xmm0
    comiss xmm0, [f_despawn]
    ja .remove
    ; fall
    movss xmm0, [rbx + EN_VY]
    movss xmm1, [dt]
    mulss xmm1, [f_grav]
    subss xmm0, xmm1
    movss [rbx + EN_VY], xmm0
    ; try y
    movss xmm1, [rbx + EN_VY]
    mulss xmm1, [dt]
    addss xmm1, [rbx + EN_Y]
    movss xmm0, [rbx + EN_X]
    movss xmm2, [rbx + EN_Z]
    movss [rsp], xmm1
    call solid_at
    jz .yfree
    ; landed: sit on top of that node, lose sideways speed
    movss xmm1, [rsp]
    FLOORF eax, xmm1, xmm7
    inc eax
    cvtsi2ss xmm1, eax
    movss [rbx + EN_Y], xmm1
    mov dword [rbx + EN_VY], 0
    movss xmm0, [rbx + EN_VX]
    mulss xmm0, [f_fric]
    movss [rbx + EN_VX], xmm0
    movss xmm0, [rbx + EN_VZ]
    mulss xmm0, [f_fric]
    movss [rbx + EN_VZ], xmm0
    jmp .xz
.yfree:
    movss xmm1, [rsp]
    movss [rbx + EN_Y], xmm1
.xz:
    ; x
    movss xmm0, [rbx + EN_VX]
    mulss xmm0, [dt]
    addss xmm0, [rbx + EN_X]
    movss [rsp], xmm0
    movss xmm1, [rbx + EN_Y]
    addss xmm1, [f_box]
    movss xmm2, [rbx + EN_Z]
    call solid_at
    jnz .xstop
    movss xmm0, [rsp]
    movss [rbx + EN_X], xmm0
    jmp .z
.xstop:
    mov dword [rbx + EN_VX], 0
.z:
    movss xmm2, [rbx + EN_VZ]
    mulss xmm2, [dt]
    addss xmm2, [rbx + EN_Z]
    movss [rsp], xmm2
    movss xmm0, [rbx + EN_X]
    movss xmm1, [rbx + EN_Y]
    addss xmm1, [f_box]
    call solid_at
    jnz .zstop
    movss xmm0, [rsp]
    movss [rbx + EN_Z], xmm0
    jmp .pick
.zstop:
    mov dword [rbx + EN_VZ], 0
.pick:
    ; close enough to the player and old enough: pick up
    movss xmm0, [rbx + EN_AGE]
    comiss xmm0, [f_pickage]
    jb .next
    movss xmm0, [rbx + EN_X]
    subss xmm0, [pos]
    mulss xmm0, xmm0
    movss xmm1, [rbx + EN_Y]
    subss xmm1, [pos + 4]
    subss xmm1, [f_eyeoff]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rbx + EN_Z]
    subss xmm1, [pos + 8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [f_pickup]
    ja .next
    mov edi, [rbx + EN_SLOT]
    call inv_add_slot
    mov [rbx + EN_SLOT], eax
    test eax, eax
    jnz .next
.remove:
    ; move the last entity into this place
    mov eax, [ent_count]
    dec eax
    mov [ent_count], eax
    shl eax, 5
    lea rcx, [ents]
    add rcx, rax
    movdqu xmm0, [rcx]
    movdqu [rbx], xmm0
    movdqu xmm0, [rcx + 16]
    movdqu [rbx + 16], xmm0
    jmp .e                          ; same index again
.next:
    inc r12d
    jmp .e
.out:
    LEAVE_FN

NOEXECSTACK
