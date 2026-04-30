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
%define MAP_WIDTH 40 ; fixed to 40*16=640=WINDOW_W for now
%define MAP_HEIGHT 30 ; until we add camera

; tile IDs, matching the tiles.ppm atlsa
%define TILE_GRASS	0
%define TILE_WATER	1
%define TILE_STONE	2
%define TILE_DIRT	3

section .bss
	alignb 8
	; -- tilemap --
	; the map itself
	; one byte per cell, MAP_WIDTH * MAP_HEIGHT bytes.
	tilemap resb MAP_WIDTH * MAP_HEIGHT

	; camera offset in pixels for later, keeping to 0 for now
	camera_x resd 1
	camera_y resd 1

section .text
;================================================================
; init_tilemap_test: fill map with a test pattern TEMP
;----------------------------------------------------------------
; for testing atlas+blitter+tilemap all working together
;================================================================
init_tilemap_test:
	call rng_seed_from_time
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
; draw_tilemap: render entire map to framebuffer
;----------------------------------------------------------------
; for each tile (tx, ty) in map:
; 1. look up its tile_id from tilemap array
; 2. compute the source rect in the atlas:
;		src_x = tile_id * TILE_SIZE, src_y = 0
; 3. compute the dest position on screen:
;		dst_x = tx * TILE_SIZE - camera_x
;		dst_y = ty * TILE_SIZE - camera_y
; 4. blit it!
;
; the blitter handles the clipping, so tiles that are partially
; or fully offscreen should just work.. TODO: test
; for big scrollable maps we'll prob need to just iterate the
; visible range, but for small map for now i'm not bothering
;================================================================
draw_tilemap:
	push rbp
	mov rbp, rsp
	sub rsp, 32
	push rbx
	push r12
	push r13
	push r14
	push r15

	; locals: [rbp-4]:ty, [rbp-8]:tx
	xor eax, eax
	mov [rbp-4], eax	; ty = 0
.row:
	cmp dword [rbp-4], MAP_HEIGHT
	jge .done

	xor eax, eax
	mov [rbp-8], eax	; tx = 0
.col:
	cmp dword [rbp-8], MAP_WIDTH
	jge .next_row

	; -- look up tile ID --
	; index = ty * MAP_WIDTH + tx
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	lea rbx, [tilemap]
	movzx r12d, byte [rbx + rax]	; r12d = tile_ID

	; -- compute blit args --
	; ref (copied from blit.inc.asm:)
	; 	edi |  src_x	(texel x in )
	; 	edi |  src_x	(texel x in source texture)
	;	esi |  src_y	(texel y in source texture)
	; 	edx |  src_w	(width in texels)
	; 	ecx |  src_h	(height in texels)
	; 	r8d |  dst_x	(pixel x on framebuffer)
	; 	r9d |  dst_y	(pixel y on framebuffer)
	; src_x = tile_ID * TILE_SIZE (aka column)
	mov edi, r12d
	imul edi, TILE_SIZE
	; src_y = 0 (TMP, just one row for now)
	xor esi, esi
	; src_w, src_h = one tile
	mov edx, TILE_SIZE
	mov ecx, TILE_SIZE
	; dst_x = tx * TILE_SIZE - camera_x
	mov r8d, [rbp-8]
	imul r8d, TILE_SIZE
	sub r8d, [camera_x] ; even if no real offset yet
	; dst_y = ty * TILE_SIZE - camera_y
	mov r9d, [rbp-4]
	imul r9d, TILE_SIZE
	sub r9d, [camera_y]

	call blit_texture_rect

	inc dword [rbp-8]
	jmp .col ;next
.next_row:
	inc dword [rbp-4]
	jmp .row ;next
.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

%endif
