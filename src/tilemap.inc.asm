; tilemap.inc.asm - tile-based worldmap and renderer
;
; world is a 2d grid of tile_id bytes
; each tile_id indexes into a texture atlas
; currently just a single horizontal row
; [tile 0][tile 1]etc, each tile being TILE_SIZE^2 px
; so tile n starts at (n * TILE_SIZE, 0) for now
;
; rendering: for each (tx,ty) on screen:
; look up the tile_id, compute its source rect in the atlas, blit

%ifndef TILEMAP_INC
%define TILEMAP_INC

%define TILE_SIZE 16
%define MAP_WIDTH 80	; 80*16 = 1280 px wide, 2x WINDOW_W
%define MAP_HEIGHT 60	; 60*16 = 960 px tall,  2x WINDOW_H

; tile IDs, matching the tiles.ppm atlsa
%define TILE_GRASS	0
%define TILE_WATER	1
%define TILE_STONE	2
%define TILE_DIRT	3


; atlas slot ids - the column index into atlas.ppm
; decoupled from tile IDs above so atlas can be rearranged/extended
; for tiles with variants (grass, water) these are the *base* slot
; and we pick within the "variant" block at draw time
%define ATLAS_GRASS_BASE	0	; 2 variants: 0..1
%define ATLAS_WATER_BASE	2	; 4 anim frames: 2..5
%define ATLAS_STONE			6
%define ATLAS_DIRT			7

%define ATLAS_GRASS_VARIANTS	2
%define ATLAS_WATER_FRAMES		4
%define WATER_ANIM_PERIOD		12

; per-tile movement speed (% of normal)
; 0 = blocked, 100 = full speed
; ordered same as TILE_* values: lookup by tile ID
section .data
	tile_speed_table:
		db 100		; grass
		db 50		; water - slow
		db 0		; stone - blocked
		db 100		; dirt

	; tile_id -> base atlas slot. multi-variant tiles (grass, water)
	; resolve to a specific slot in draw_tilemap,
	; this table just gives the starting offset
	tile_atlas_base:
		db ATLAS_GRASS_BASE	; grass
		db ATLAS_WATER_BASE	; water
		db ATLAS_STONE		; stone
		db ATLAS_DIRT		; dirt


section .bss
	alignb 8
	; -- tilemap --
	; the map itself
	; one byte per cell, MAP_WIDTH * MAP_HEIGHT bytes.
	tilemap resb MAP_WIDTH * MAP_HEIGHT

	; camera offset in pixels for later, keeping to 0 for now
	camera_x resd 1
	camera_y resd 1

	; global frame counter used to drive the tile animation
	; (bumped once per frame in main)
	tile_anim_ticks resd 1

section .text
;================================================================
; init_tilemap_test: fill map with a test pattern TEMP
;----------------------------------------------------------------
; for testing atlas+blitter+tilemap all working together
;================================================================
init_tilemap_test:
	push rbx
	push r12		; y
	push r13		; x

	xor r12d, r12d	; y=0
.y_loop:
	cmp r12d, MAP_HEIGHT
	jge .done

	xor r13d, r13d	; x=0
.x_loop:
	cmp r13d, MAP_WIDTH
	jge .x_done

	mov eax, TILE_GRASS	;default tile

	;stone edges
	test r13d, r13d
	jz .pick_stone
	test r12d, r12d
	jz .pick_stone
	cmp r13d, MAP_WIDTH-1
	je .pick_stone
	cmp r12d, MAP_HEIGHT-1
	je .pick_stone

	;water blob
	cmp r13d, 16
	jl .check_dirt
	cmp r13d, 22
	jg .check_dirt
	cmp r12d, 12
	jl .check_dirt
	cmp r12d, 16
	jg .check_dirt
	mov eax, TILE_WATER
	jmp .write

.check_dirt:
	mov r14, rax		; save tile
	call rng_next
	and eax, 7
	jnz .keep_grass
	mov rax, r14
	mov eax, TILE_DIRT
	jmp .write
	
.keep_grass:
	mov rax, r14
	jmp .write

.pick_dirt:
	mov eax, TILE_DIRT
	jmp .write

.pick_stone:
	mov eax, TILE_STONE
	jmp .write

.pick_water:
	mov eax, TILE_WATER
	jmp .write

.write:
	; tilemap[y * MAP_WIDTH + x] = tile_id
	mov ecx, r12d
	imul ecx, MAP_WIDTH
	add ecx, r13d
	lea rbx, [tilemap]
	mov [rbx + rcx], al

	inc r13d
	jmp .x_loop
.x_done:
	inc r12d
	jmp .y_loop
.done:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; tile_at: read tile id @(tx,ty) tile coords
;----------------------------------------------------------------
; off-grid returns stone so collision queries treat outside the
; map as a solid wall - keeps the player penned in without
; needing extra clamping logic in try_move
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
;out:	eax = tile id (or TILE_STONE if out of bounds)
;================================================================
tile_at:
	test edi, edi
	js .oob
	cmp edi, MAP_WIDTH
	jge .oob
	test esi, esi
	js .oob
	cmp esi, MAP_HEIGHT
	jge .oob
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [tilemap]
	movzx eax, byte [rdx + rax]
	ret
.oob:
	mov eax, TILE_STONE
	ret

;================================================================
; tile_at_pixel: like tile_at but inputs are pixel coords
;----------------------------------------------------------------
; using floor-divide here so negative pixel coords map to
; negative tile coords (caught by tile_at's bounds check)
; idiv truncates toward zero, so for negatives, if there's a
; non-zero remainder, decrement
;----------------------------------------------------------------
; in:  edi = px, esi = py
; out: eax = tile id
;================================================================
tile_at_pixel:
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov edi, eax		; tx

	mov eax, esi
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov esi, eax		; ty

	jmp tile_at 		; now get tile!

;================================================================
; tile_speed_at_pixel: per-tile speed % at pixel coords
;----------------------------------------------------------------
; in:	edi = px, esi = py
;out:	eax = speed % (0..100)
;================================================================
tile_speed_at_pixel:
	push rbp
	mov rbp, rsp
	call tile_at_pixel
	lea rcx, [tile_speed_table]
	movzx eax, byte [rcx + rax]
	pop rbp
	ret


;================================================================
; draw_tilemap: render VISIBLE map to framebuffer (+1 margin)
;----------------------------------------------------------------
; in: rdi = ptr to texture struct (the atlas/spritesheet)
;================================================================
draw_tilemap:
	push rbp
	mov rbp, rsp
	sub rsp, 48
	push rbx
	push r12
	push r13
	push r14
	push r15

	; locals:
	;	[rbp-4]		ty
	;	[rbp-8]		tx
	;	[rbp-16]	atlas tex ptr (saved)
	;	[rbp-20]	ty_min
	;	[rbp-24]	ty_max (exclusive)
	;	[rbp-28]	tx_min
	;	[rbp-32]	tx_max (exclusive)

	mov [rbp-16], rdi

	; tx_min = max(0, camera_x / TILE_SIZE - 1)
	mov eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	; floor for negatives - shouldn't happen post-clamp hopefully
	test edx, edx
	jns .tx_min_ok
	dec eax
.tx_min_ok:
	dec eax					; one-tile margin
	test eax, eax
	jns .tx_min_clamped
	xor eax, eax
.tx_min_clamped:
	mov [rbp-28], eax

	; tx_max = min(MAP_WIDTH, (camera_x + WINDOW_W) / TILE_SIZE + 2)
	mov eax, [camera_x]
	add eax, WINDOW_W
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 2				; round-up + margin
	cmp eax, MAP_WIDTH
	jle .tx_max_ok
	mov eax, MAP_WIDTH
.tx_max_ok:
	mov [rbp-32], eax

	; ty_min / ty_max, same logic
	mov eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .ty_min_ok
	dec eax
.ty_min_ok:
	dec eax
	test eax, eax
	jns .ty_min_clamped
	xor eax, eax
.ty_min_clamped:
	mov [rbp-20], eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	cdq
	idiv ecx
	add eax, 2
	cmp eax, MAP_HEIGHT
	jle .ty_max_ok
	mov eax, MAP_HEIGHT
.ty_max_ok:
	mov [rbp-24], eax

	; outer/inner loops
	mov eax, [rbp-20]
	mov [rbp-4], eax
.row:
	mov eax, [rbp-4]
	cmp eax, [rbp-24]
	jge .done

	mov eax, [rbp-28]
	mov [rbp-8], eax
.col:
	mov eax, [rbp-8]
	cmp eax, [rbp-32]
	jge .next_row

	; tile_id -> r12d
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	lea rbx, [tilemap]
	movzx r12d, byte [rbx + rax]

	; -- decide which atlas slot to blit --
	; start from the base slot for this tile ID
	lea rbx, [tile_atlas_base]
	movzx r13d, byte [rbx + r12]

	; grass: pick variant 0 or 1 by a static hash of (tx, ty)
	; alt tile is slot 1.
	cmp r12d, TILE_GRASS
	jne .not_grass
	; hash = (tx * 73) xor (ty * 31), % 100:
	mov eax, [rbp-8]
	imul eax, 73
	mov ecx, [rbp-4]
	imul ecx, 31
	xor eax, ecx
	; abs for % to stop weirdness on negatives
	cdq
	xor eax, edx
	sub eax, edx
	mov ecx, 100
	xor edx, edx
	div ecx
	cmp edx, 40
	jge .not_grass
	inc r13d	; bump from slot 0 to our variant slot 1
.not_grass:

	; water: cycle through the 4 anim frames using global tick
	cmp r12d, TILE_WATER
	jne .got_atlas_slot
	mov eax, [tile_anim_ticks]
	mov ecx, WATER_ANIM_PERIOD
	xor edx, edx
	div ecx
	; eax = step; we want step % 4
	and eax, ATLAS_WATER_FRAMES - 1
	add r13d, eax
.got_atlas_slot:

	; blit_texture_rect signature:
	;	rdi=tex ptr, esi=src_x, edx=src_y, ecx=src_w,
	;	r8d=src_h, r9d=dst_x, [stack:dst_y], [stack:flip]
	mov rdi, [rbp-16]
	mov esi, r13d
	imul esi, TILE_SIZE		; src_x
	xor edx, edx			; src_y
	mov ecx, TILE_SIZE		; src_w
	mov r8d, TILE_SIZE		; src_h
	mov r9d, [rbp-8]
	imul r9d, TILE_SIZE
	sub r9d, [camera_x]		; dst_x

	; push stack args, dst_y first
	mov eax, [rbp-4]
	imul eax, TILE_SIZE
	sub eax, [camera_y]
	push 0					; flip = 0
	push rax				; dst_y
	call blit_texture_rect
	add rsp, 16				; clean up stack args

	inc dword [rbp-8]
	jmp .col
.next_row:
	inc dword [rbp-4]
	jmp .row
.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

%endif
