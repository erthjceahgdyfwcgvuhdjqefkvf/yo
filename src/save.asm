; save.asm - worlds on disk.
;
; Layout under $XDG_DATA_HOME (or ~/.local/share), which follows an
; AppImage portable home folder:
;   voxasm/worlds/world<N>/world.dat     player, inventory, furnaces, time
;   voxasm/worlds/world<N>/c<cx>_<cz>.bin   chunks that were changed
; Unchanged chunks are not stored: they regenerate from the seed. Chunk
; files are run-length encoded ("VXC1", then count/value byte pairs).
;
; chunk_fill runs on the world-gen thread too, so it reads files with raw
; system calls and only touches the buffer it is given.

%include "common.inc"

global save_init, cur_world, world_dir, chunk_path, chunk_fill, save_chunk
global save_meta, load_meta, save_all, worlds_scan, world_info
global world_create_dir, world_delete, dimension

extern getenv, snprintf, mkdir, fopen, fclose, fwrite, fread
extern opendir, readdir, closedir, unlink, rmdir, strcmp, strlen
%ifdef VOXASM_WIN
D_NAME      equ 44                  ; WIN32_FIND_DATAA.cFileName (winabi.asm readdir)
%elifidn __OUTPUT_FORMAT__, elf64
D_NAME      equ 19                  ; glibc struct dirent: name after ino, off, reclen, type
%else
D_NAME      equ 8                   ; macOS legacy struct dirent (tests)
%endif
%ifidn __OUTPUT_FORMAT__, elf64
%else
extern open, read, close
%endif
extern chunk_blocks, chunk_hmap, chunk_info, mapgen_chunk, mapgen_finish
extern nether_chunk, nether_finish, portal_link
extern mapgen_flat, seed, game_mode, world_time, pos, yaw, pitch, hp
extern breath, sel_slot, spawn_pos, inv, furnaces, spawn_bed, armor, boats

NUM_WORLDS  equ 5
META_SIZE   equ 2560
OLD_META    equ 1752                ; before armour and boats
RLE_MAX     equ CHUNK_VOX * 2 + 16
NUM_INV     equ 36
FURN_BYTES  equ 32 * 48

; world.dat
M_MAGIC     equ 0
M_SEED      equ 8
M_FLAT      equ 12
M_MODE      equ 16
M_TIME      equ 20
M_POS       equ 24
M_YAW       equ 36
M_PITCH     equ 40
M_HP        equ 44
M_BREATH    equ 48
M_SEL       equ 52
M_SPAWN     equ 56
M_BED       equ 68                  ; 1 = spawn_pos is a bed (old saves: 0)
M_INV       equ 72
M_FURN      equ 216
M_ARMOR     equ 1752                ; 4 slots
M_BOATS     equ 1768                ; 16 boats x 48 bytes
BOAT_BYTES  equ 16 * 48
M_DIM       equ 2536                ; 1 = the player is in the nether
M_LINK      equ 2540                ; portal_link (5 dwords)

; world_info record: exists, seed, mode, flat
WI_SIZE     equ 16

section .rodata
s_xdg:      db "XDG_DATA_HOME", 0
s_home:     db "HOME", 0
s_fmt_s:    db "%s", 0
s_local:    db "%s/.local", 0
s_share:    db "%s/.local/share", 0
s_vox:      db "%s/voxasm", 0
s_worlds:   db "%s/voxasm/worlds", 0
s_wdir:     db "%s/world%d", 0
s_meta:     db "%s/world.dat", 0
s_chunk:    db "%s/c%d_%d.bin", 0
s_nchunk:   db "%s/n%d_%d.bin", 0       ; nether chunks
s_file:     db "%s/%s", 0
s_worldfile: db "world.dat", 0
s_binext:   db ".bin", 0
s_wb:       db "wb", 0
s_rb:       db "rb", 0
magic_w:    db "VXW1"
magic_c:    db "VXC1"

section .bss
alignb 16
data_base:  resb 512                ; .../voxasm/worlds
world_dir:  resb 512                ; .../worlds/world<N>, "" = no saving
path_buf:   resb 512
meta_buf:   resb META_SIZE
dimension:  resd 1                  ; 0 the overworld, 1 the nether
rle_buf:    resb RLE_MAX
cur_world:  resd 1
world_info: resb NUM_WORLDS * WI_SIZE
tmp_base:   resb 512

section .text

; mkdir(path, 0755), ignoring "exists"
mk:
    sub rsp, 8
    mov esi, 0o755
    call mkdir PLT
    add rsp, 8
    ret

; void save_init(void) - find and create the data folder
save_init:
    ENTER_FN 0
    mov byte [data_base], 0
    lea rdi, [s_xdg]
    call getenv PLT
    test rax, rax
    jz .home
    cmp byte [rax], 0
    je .home
    mov rbx, rax
    lea rdi, [path_buf]
    mov esi, 512
    lea rdx, [s_vox]
    mov rcx, rbx
    xor eax, eax
    call snprintf PLT
    lea rdi, [path_buf]
    call mk
    lea rdi, [data_base]
    mov esi, 512
    lea rdx, [s_worlds]
    mov rcx, rbx
    xor eax, eax
    call snprintf PLT
    jmp .made
.home:
    lea rdi, [s_home]
    call getenv PLT
    test rax, rax
    jz .out
    mov rbx, rax
%macro MKDIR_FMT 1
    lea rdi, [path_buf]
    mov esi, 512
    lea rdx, [%1]
    mov rcx, rbx
    xor eax, eax
    call snprintf PLT
    lea rdi, [path_buf]
    call mk
%endmacro
    MKDIR_FMT s_local
    MKDIR_FMT s_share
    lea rdi, [tmp_base]
    mov esi, 512
    lea rdx, [s_share]
    mov rcx, rbx
    xor eax, eax
    call snprintf PLT
    lea rbx, [tmp_base]
    MKDIR_FMT s_vox
    lea rdi, [data_base]
    mov esi, 512
    lea rdx, [s_worlds]
    mov rcx, rbx
    xor eax, eax
    call snprintf PLT
.made:
    lea rdi, [data_base]
    call mk
.out:
    LEAVE_FN

; void world_create_dir(int n) - select world n (1-5) for saving
world_create_dir:
    ENTER_FN 0
    mov [cur_world], edi
    mov byte [world_dir], 0
    cmp byte [data_base], 0
    je .out
    mov ecx, edi
    lea rdi, [world_dir]
    mov esi, 512
    lea rdx, [s_wdir]
    mov r8d, ecx
    lea rcx, [data_base]
    xor eax, eax
    call snprintf PLT
    lea rdi, [world_dir]
    call mk
.out:
    LEAVE_FN

; void chunk_path(int cx, int cz, char *out) - "" when nothing is saved
chunk_path:
    ENTER_FN 0
    mov byte [rdx], 0
    cmp byte [world_dir], 0
    je .out
    mov r8d, edi
    mov r9d, esi
    mov rdi, rdx
    mov esi, 224
    lea rdx, [s_chunk]
    cmp dword [dimension], 0
    je .ow
    lea rdx, [s_nchunk]
.ow:
    lea rcx, [world_dir]
    xor eax, eax
    call snprintf PLT
.out:
    LEAVE_FN

; raw file reading usable from the world-gen thread
; fd = file_open(rdi path) (negative on failure)
file_open:
%ifidn __OUTPUT_FORMAT__, elf64
    mov eax, 2                      ; SYS_open
    xor esi, esi                    ; O_RDONLY
    xor edx, edx
    syscall
    ret
%else
    sub rsp, 8
    xor esi, esi
    xor eax, eax
    call open PLT
    add rsp, 8
    ret
%endif
; n = file_read(edi fd, rsi buf, edx count)
file_read:
%ifidn __OUTPUT_FORMAT__, elf64
    xor eax, eax                    ; SYS_read
    syscall
    ret
%else
    sub rsp, 8
    call read PLT
    add rsp, 8
    ret
%endif
file_close:
%ifidn __OUTPUT_FORMAT__, elf64
    mov eax, 3                      ; SYS_close
    syscall
    ret
%else
    sub rsp, 8
    call close PLT
    add rsp, 8
    ret
%endif

; int chunk_fill(int slot, int cx, int cz, int seed, char *path, u8 *buf)
; Load the chunk from its file if there is one, else generate it. buf must
; hold RLE_MAX bytes. Returns the highest non-air y index.
; locals: [0] slot, [4] cx, [8] cz, [12] seed, [16] path, [24] buf,
;         [32] fd, [36] bytes read
chunk_fill:
    ENTER_FN 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8
    mov [rsp + 24], r9
    cmp byte [r8], 0
    je .generate
    mov rdi, r8
    call file_open
    test eax, eax
    js .generate
    mov [rsp + 32], eax
    ; read the whole file
    xor r12d, r12d                  ; total
.rd:
    mov edi, [rsp + 32]
    mov rsi, [rsp + 24]
    add rsi, r12
    mov edx, RLE_MAX
    sub edx, r12d
    jle .rd_done
    call file_read
    test eax, eax
    jle .rd_done
    add r12d, eax
    jmp .rd
.rd_done:
    mov edi, [rsp + 32]
    call file_close
    ; check the header and decode
    mov rsi, [rsp + 24]
    cmp r12d, 6
    jb .generate
    mov eax, [magic_c]
    cmp [rsi], eax
    jne .generate
    mov eax, [rsp]
    shl rax, 16
    lea rdi, [chunk_blocks]
    add rdi, rax                    ; destination
    xor r13d, r13d                  ; nodes written
    mov r14d, 4                     ; read position
.dec:
    lea eax, [r14 + 1]
    cmp eax, r12d
    jae .dec_done
    movzx ecx, byte [rsi + r14]     ; count
    movzx eax, byte [rsi + r14 + 1] ; value
    add r14d, 2
    lea edx, [r13 + rcx]
    cmp edx, CHUNK_VOX
    ja .generate                    ; corrupt
.fill:
    test ecx, ecx
    jz .dec
    mov [rdi + r13], al
    inc r13d
    dec ecx
    jmp .fill
.dec_done:
    cmp r13d, CHUNK_VOX
    jne .generate
    mov eax, [rsp]
    mov rdi, rax
    shl rdi, 16
    lea rcx, [chunk_blocks]
    add rdi, rcx
    mov rsi, rax
    shl rsi, 9
    lea rcx, [chunk_hmap]
    add rsi, rcx
    cmp dword [dimension], 0
    jne .nfinish
    call mapgen_finish
    LEAVE_FN
.nfinish:
    call nether_finish
    LEAVE_FN
.generate:
    mov eax, [rsp]
    mov rdi, rax
    shl rdi, 16
    lea rcx, [chunk_blocks]
    add rdi, rcx
    mov rsi, rax
    shl rsi, 9
    lea rcx, [chunk_hmap]
    add rsi, rcx
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    cmp dword [dimension], 0
    jne .nether
    call mapgen_chunk
    LEAVE_FN
.nether:
    call nether_chunk
    LEAVE_FN

; void save_chunk(int slot) - write a changed chunk (main thread)
save_chunk:
    ENTER_FN 16
    mov ebx, edi
    mov eax, ebx
    shl rax, CI_SHIFT
    lea r12, [chunk_info]
    add r12, rax
    cmp byte [r12 + CI_MODIFIED], 0
    je .out
    cmp byte [world_dir], 0
    je .out
    mov byte [r12 + CI_MODIFIED], 0
    ; encode
    mov eax, [magic_c]
    mov [rle_buf], eax
    mov eax, ebx
    shl rax, 16
    lea rsi, [chunk_blocks]
    add rsi, rax
    lea rdi, [rle_buf + 4]
    xor ecx, ecx                    ; node
.run:
    cmp ecx, CHUNK_VOX
    jae .encoded
    mov al, [rsi + rcx]
    mov edx, 1
.same:
    lea r8d, [rcx + rdx]
    cmp r8d, CHUNK_VOX
    jae .emit
    cmp edx, 255
    jae .emit
    cmp [rsi + r8], al
    jne .emit
    inc edx
    jmp .same
.emit:
    mov [rdi], dl
    mov [rdi + 1], al
    add rdi, 2
    add ecx, edx
    jmp .run
.encoded:
    lea rax, [rle_buf]
    sub rdi, rax
    mov r13, rdi                    ; bytes
    mov edi, [r12 + CI_CX]
    mov esi, [r12 + CI_CZ]
    lea rdx, [path_buf]
    call chunk_path
    lea rdi, [path_buf]
    lea rsi, [s_wb]
    call fopen PLT
    test rax, rax
    jz .out
    mov r14, rax
    lea rdi, [rle_buf]
    mov esi, 1
    mov rdx, r13
    mov rcx, r14
    call fwrite PLT
    mov rdi, r14
    call fclose PLT
.out:
    LEAVE_FN

; COPY dst, src, bytes - small memory copy
%macro COPY 3
    lea rdi, %1
    lea rsi, %2
    mov ecx, %3
    rep movsb
%endmacro

; void save_meta(void) - world.dat for the current world
save_meta:
    ENTER_FN 0
    cmp byte [world_dir], 0
    je .out
    lea rdi, [meta_buf]
    xor eax, eax
    mov ecx, META_SIZE
    rep stosb
    mov eax, [magic_w]
    mov [meta_buf + M_MAGIC], eax
    mov dword [meta_buf + 4], 1
    mov eax, [seed]
    mov [meta_buf + M_SEED], eax
    mov eax, [mapgen_flat]
    mov [meta_buf + M_FLAT], eax
    mov eax, [game_mode]
    mov [meta_buf + M_MODE], eax
    mov eax, [world_time]
    mov [meta_buf + M_TIME], eax
    COPY [meta_buf + M_POS], [pos], 12
    mov eax, [yaw]
    mov [meta_buf + M_YAW], eax
    mov eax, [pitch]
    mov [meta_buf + M_PITCH], eax
    mov eax, [hp]
    mov [meta_buf + M_HP], eax
    mov eax, [breath]
    mov [meta_buf + M_BREATH], eax
    mov eax, [sel_slot]
    mov [meta_buf + M_SEL], eax
    COPY [meta_buf + M_SPAWN], [spawn_pos], 12
    COPY [meta_buf + M_BED], [spawn_bed], 4
    COPY [meta_buf + M_INV], [inv], NUM_INV * 4
    COPY [meta_buf + M_FURN], [furnaces], FURN_BYTES
    COPY [meta_buf + M_ARMOR], [armor], 16
    COPY [meta_buf + M_BOATS], [boats], BOAT_BYTES
    mov eax, [dimension]
    mov [meta_buf + M_DIM], eax
    COPY [meta_buf + M_LINK], [portal_link], 20
    lea rdi, [path_buf]
    mov esi, 512
    lea rdx, [s_meta]
    lea rcx, [world_dir]
    xor eax, eax
    call snprintf PLT
    lea rdi, [path_buf]
    lea rsi, [s_wb]
    call fopen PLT
    test rax, rax
    jz .out
    mov rbx, rax
    lea rdi, [meta_buf]
    mov esi, 1
    mov edx, META_SIZE
    mov rcx, rbx
    call fwrite PLT
    mov rdi, rbx
    call fclose PLT
.out:
    LEAVE_FN

; read world<n>/world.dat into meta_buf: eax 1 if it exists and is valid
read_meta:
    ENTER_FN 0
    mov ebx, edi
    cmp byte [data_base], 0
    je .no
    lea rdi, [tmp_base]
    mov esi, 512
    lea rdx, [s_wdir]
    lea rcx, [data_base]
    mov r8d, ebx
    xor eax, eax
    call snprintf PLT
    lea rdi, [path_buf]
    mov esi, 512
    lea rdx, [s_meta]
    lea rcx, [tmp_base]
    xor eax, eax
    call snprintf PLT
    lea rdi, [path_buf]
    lea rsi, [s_rb]
    call fopen PLT
    test rax, rax
    jz .no
    mov r12, rax
    lea rdi, [meta_buf]             ; an older, shorter file: the rest is 0
    xor eax, eax
    mov ecx, META_SIZE
    rep stosb
    lea rdi, [meta_buf]
    mov esi, 1
    mov edx, META_SIZE
    mov rcx, r12
    call fread PLT
    mov r13, rax
    mov rdi, r12
    call fclose PLT
    cmp r13, OLD_META               ; older saves are shorter: the rest is 0
    jb .no
    mov eax, [magic_w]
    cmp [meta_buf], eax
    jne .no
    mov eax, 1
    LEAVE_FN
.no:
    xor eax, eax
    LEAVE_FN

; int load_meta(int n) - make world n current and restore its state
load_meta:
    ENTER_FN 0
    mov r12d, edi
    call read_meta
    test eax, eax
    jz .out
    mov edi, r12d
    call world_create_dir
    mov eax, [meta_buf + M_SEED]
    mov [seed], eax
    mov eax, [meta_buf + M_FLAT]
    mov [mapgen_flat], eax
    mov eax, [meta_buf + M_MODE]
    mov [game_mode], eax
    mov eax, [meta_buf + M_TIME]
    mov [world_time], eax
    COPY [pos], [meta_buf + M_POS], 12
    mov eax, [meta_buf + M_YAW]
    mov [yaw], eax
    mov eax, [meta_buf + M_PITCH]
    mov [pitch], eax
    mov eax, [meta_buf + M_HP]
    mov [hp], eax
    mov eax, [meta_buf + M_BREATH]
    mov [breath], eax
    mov eax, [meta_buf + M_SEL]
    mov [sel_slot], eax
    COPY [spawn_pos], [meta_buf + M_SPAWN], 12
    COPY [spawn_bed], [meta_buf + M_BED], 4
    COPY [inv], [meta_buf + M_INV], NUM_INV * 4
    COPY [furnaces], [meta_buf + M_FURN], FURN_BYTES
    COPY [armor], [meta_buf + M_ARMOR], 16      ; (zero in older saves)
    COPY [boats], [meta_buf + M_BOATS], BOAT_BYTES
    mov eax, [meta_buf + M_DIM]
    mov [dimension], eax
    COPY [portal_link], [meta_buf + M_LINK], 20
    mov eax, 1
.out:
    LEAVE_FN

; void worlds_scan(void) - fill world_info for the world list
worlds_scan:
    ENTER_FN 0
    xor ebx, ebx
.w:
    lea edi, [rbx + 1]
    call read_meta
    mov ecx, ebx
    shl ecx, 4
    lea rdx, [world_info]
    add rdx, rcx
    mov [rdx], eax
    test eax, eax
    jz .n
    mov eax, [meta_buf + M_SEED]
    mov [rdx + 4], eax
    mov eax, [meta_buf + M_MODE]
    mov [rdx + 8], eax
    mov eax, [meta_buf + M_FLAT]
    mov [rdx + 12], eax
.n:
    inc ebx
    cmp ebx, NUM_WORLDS
    jb .w
    LEAVE_FN

; void save_all(void) - every changed chunk, then world.dat
save_all:
    ENTER_FN 0
    xor ebx, ebx
.s:
    mov eax, ebx
    shl rax, CI_SHIFT
    lea rcx, [chunk_info]
    cmp byte [rcx + rax + CI_STATE], ST_READY
    jne .n
    mov edi, ebx
    call save_chunk
.n:
    inc ebx
    cmp ebx, NUM_SLOTS
    jb .s
    call save_meta
    LEAVE_FN

; void world_delete(int n) - remove world n (1-5): its world.dat and chunk
; files (c*.bin), then the folder if nothing else is in it
world_delete:
    ENTER_FN 16
    cmp byte [data_base], 0
    je .out
    mov ecx, edi
    lea rdi, [tmp_base]
    mov esi, 512
    lea rdx, [s_wdir]
    mov r8d, ecx
    lea rcx, [data_base]
    xor eax, eax
    call snprintf PLT
.pass:
    ; deleting while reading a folder may skip names: repeat until a pass
    ; deletes nothing
    xor r14d, r14d
    lea rdi, [tmp_base]
    call opendir PLT
    test rax, rax
    jz .rmdir
    mov r12, rax
.entry:
    mov rdi, r12
    call readdir PLT
    test rax, rax
    jz .done
    lea r13, [rax + D_NAME]
    ; only the game's own files
    mov rdi, r13
    lea rsi, [s_worldfile]
    call strcmp PLT
    test eax, eax
    jz .remove
    cmp byte [r13], 'c'
    je .chunkfile
    cmp byte [r13], 'n'             ; nether chunks too
    jne .entry
.chunkfile:
    mov rdi, r13
    call strlen PLT
    cmp rax, 5
    jb .entry
    lea rdi, [r13 + rax - 4]
    lea rsi, [s_binext]
    call strcmp PLT
    test eax, eax
    jnz .entry
.remove:
    lea rdi, [path_buf]
    mov esi, 512
    lea rdx, [s_file]
    lea rcx, [tmp_base]
    mov r8, r13
    xor eax, eax
    call snprintf PLT
    lea rdi, [path_buf]
    call unlink PLT
    test eax, eax
    jnz .entry                      ; could not: do not try again forever
    inc r14d
    jmp .entry
.done:
    mov rdi, r12
    call closedir PLT
    test r14d, r14d
    jnz .pass
.rmdir:
    lea rdi, [tmp_base]
    call rmdir PLT
    call worlds_scan
.out:
    LEAVE_FN

NOEXECSTACK
