; room.inc.asm - detect enclosed rooms via 8-connected floodfill
;----------------------------------------------------------------
; a room is any connected region of interior tiles whose boundary
; is entirely walls or doors.  any gap (cardinal OR diagonal) means
; the region merges with the exterior and isn't a room!
;
; algorithm:
;	1.	walk every tile.  if it's interior and unvisited, run
;		8-connected BFS through interior neighbours, assigning the
;		region a fresh id
;	2.	the biggest region is the world exterior (millions of grass
;		tiles).  every smaller region is a candidate room
;	3.	clear the exterior region's id back to 0 in roommap so the
;		"is this tile in a room" check is just "is roommap != 0"
;	4.	tally bed/chair/floor-space counts per surviving region and
;	compute capacity=min(beds,chairs,floor_spaces/TILES_PER_RESIDENT)
;
; classification:
;	interior tile	walkable ground (grass/dirt/wood floor), AND
;					object slot is empty OR bed OR chair OR torch
;	boundary tile	wall,tree,door(any state),water - anything else
%ifndef ROOM_INC
%define ROOM_INC

; max distinct regions we'll bother tracking.  exterior takes one,
; rest are real rooms.  more than this -> we just stop assigning
; new ids and treat leftovers as exterior
%define MAX_ROOMS				254

; capacity formula: each "resident slot" needs a bed, a chair, and
; this many empty floor tiles
%define TILES_PER_RESIDENT		3

; room overlay tint, applied always on (room tiles read brighter)
%define ROOM_BRIGHTEN_R			42
%define ROOM_BRIGHTEN_G			36
%define ROOM_BRIGHTEN_B			24

section .bss
	; primary output - per-tile region id.  0 = not in a room
	; (exterior, walls, doors, etc).  1..room_count = room id
	alignb 1
	roommap				resb MAP_WIDTH * MAP_HEIGHT

	; how many rooms (not counting exterior).  also = highest id used
	alignb 4
	room_count			resd 1

	; per-room capacity (residents this room can house).  index by
	; room id 1..room_count.  slot 0 unused
	alignb 1
	room_capacity		resb MAX_ROOMS + 1
	; per-room tally counters used by the recompute pass.  kept
	; static to avoid reallocating each call
	room_tally_beds		resb MAX_ROOMS + 1
	room_tally_chairs	resb MAX_ROOMS + 1
	; floor spaces is a u16 since a big room might hit thousands
	alignb 2
	room_tally_floor	resw MAX_ROOMS + 1
	; per-region tile count, used to spot the exterior (= largest)
	alignb 4
	room_tally_size		resd MAX_ROOMS + 1

	; bfs work queue - tile linear indices, 16 bits each
	alignb 2
	room_bfs_queue		resw MAP_WIDTH * MAP_HEIGHT
	alignb 4
	room_bfs_head		resd 1
	room_bfs_tail		resd 1

	; F8 toggle for the debug overlay
	alignb 1
	room_debug_view		resb 1

section .data
	log_msg_rooms		db "room overlay toggled", 0

section .text

;================================================================
; room_tile_is_interior: passable for floodfill purposes
;----------------------------------------------------------------
; an interior tile is anything we'd consider "inside the room":
;	- ground walks (grass, dirt, wood floor - NOT stone, NOT water)
;	- object slot empty, or bed, or chair, or torch
;
; walls, trees, doors, and water are boundaries.  closed doors are
; treated as walls here so they form room edges
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 1 if interior, 0 otherwise.  trashes ecx, edx
;================================================================
room_tile_is_interior:
	test edi, edi
	js .no
	cmp edi, MAP_WIDTH
	jge .no
	test esi, esi
	js .no
	cmp esi, MAP_HEIGHT
	jge .no

	mov edx, esi
	imul edx, MAP_WIDTH
	add edx, edi			; edx = linear idx

	; ground check - below tiles pass; everything else
	; (stone, water, tree-as-ground, etc) bounds the region
	lea rcx, [tilemap]
	movzx eax, byte [rcx + rdx]
	cmp eax, TILE_GRASS
	je .ground_ok
	cmp eax, TILE_DIRT
	je .ground_ok
	cmp eax, TILE_WOOD_FLOOR
	je .ground_ok
	jmp .no
.ground_ok:
	; object check.  empty = pass.  any of below = pass (they
	; live inside rooms).  everything else = boundary
	lea rcx, [objectmap]
	movzx eax, byte [rcx + rdx]
	test eax, eax
	jz .yes
	cmp eax, OBJ_BED
	je .yes
	cmp eax, OBJ_CHAIR
	je .yes
	cmp eax, OBJ_TORCH
	je .yes
	jmp .no
.yes:
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; room_floodfill_region: 8-connected BFS from a seed tile,
; marking every reachable interior tile with the given region id.
; tallies size into r9d (returned)
;----------------------------------------------------------------
; in:	edi = seed tx, esi = seed ty, edx = region id (1..255)
; out:	eax = tile count for this region
;----------------------------------------------------------------
; stack (4 pushes + sub 24 = 56 + ret 8 = 64, aligned):
;	[rsp+0]  region id
;	[rsp+4]  size counter
;	[rsp+8]  current cx (popped tile x)
;	[rsp+12] current cy
;	[rsp+16] dx, dy neighbour walker
;================================================================
room_floodfill_region:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 24

	mov [rsp + 0], edx		; region id
	mov dword [rsp + 4], 0	; size

	; seed: stamp the start tile, push it onto the queue
	mov ebx, esi
	imul ebx, MAP_WIDTH
	add ebx, edi			; ebx = seed linear idx
	lea rcx, [roommap]
	mov al, dl
	mov [rcx + rbx], al
	inc dword [rsp + 4]

	mov dword [room_bfs_head], 0
	lea rcx, [room_bfs_queue]
	mov [rcx], bx
	mov dword [room_bfs_tail], 1

.bfs:
	mov eax, [room_bfs_head]
	cmp eax, [room_bfs_tail]
	jge .done

	; pop tile idx
	lea rcx, [room_bfs_queue]
	movzx ebx, word [rcx + rax*2]
	inc dword [room_bfs_head]

	; idx -> (cx, cy)
	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx					; eax = cy, edx = cx
	mov [rsp + 8], edx		; cx
	mov [rsp + 12], eax		; cy

	; iterate 8 neighbours (dy=-1..1, dx=-1..1, skip 0,0)
	mov r14d, -1			; dy
.ny:
	cmp r14d, 1
	jg .bfs
	mov r13d, -1			; dx
.nx:
	cmp r13d, 1
	jg .ny_next
	mov eax, r13d
	or eax, r14d
	test eax, eax
	jnz .check_neighbour	; (0,0) is self
	jmp .nx_step
.check_neighbour:
	; compute (nx, ny)
	mov r12d, [rsp + 8]
	add r12d, r13d			; nx
	mov edi, [rsp + 12]
	add edi, r14d			; ny

	; bounds
	test r12d, r12d
	js .nx_step
	cmp r12d, MAP_WIDTH
	jge .nx_step
	test edi, edi
	js .nx_step
	cmp edi, MAP_HEIGHT
	jge .nx_step

	; already visited?
	mov eax, edi
	imul eax, MAP_WIDTH
	add eax, r12d		; n_idx
	lea rcx, [roommap]
	movzx edx, byte [rcx + rax]
	test edx, edx
	jnz .nx_step		; non-zero = already assigned

	; interior?
	push rax
	sub rsp, 8			; align for the call
	mov esi, edi		; ny -> esi for the call
	mov edi, r12d
	call room_tile_is_interior
	add rsp, 8
	pop rdx				; rdx = n_idx
	test eax, eax
	jz .nx_step

	; mark + enqueue 
	lea rcx, [roommap]
	mov al, [rsp + 0]	; region id
	mov [rcx + rdx], al
	inc dword [rsp+4]
	mov eax, [room_bfs_tail]
	lea rcx, [room_bfs_queue]
	mov [rcx + rax*2], dx
	inc dword [room_bfs_tail]

.nx_step:
	inc r13d
	jmp .nx
.ny_next:
	inc r14d
	jmp .ny

.done:
	mov eax, [rsp + 4]
	add rsp, 24
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; rooms_recompute: rebuild roommap and capacities from scratch
;----------------------------------------------------------------
; called after any event that changes the world structure:
;	- world regen
;	- placement / removal of walls/floors/doors/furniture
;	- tree regrowth
;
; phases:
;	1. clear roommap, room_count, tallies
;	2. for each unvisited interior tile, floodfill -> new region
;	3. find the largest region: that's the exterior
;	4. zero the exterior region's tiles in roommap (so 0 = "not a
;	   room") and renumber remaining regions 1..N contiguously
;	5. walk the map once more to tally bed/chair/floor per room
;	6. compute capacities
;----------------------------------------------------------------
; stack: 5 callee-saves + sub 16 = 56 + ret 8 = 64, aligned
;================================================================
global rooms_recompute
rooms_recompute:
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 16
	; [rsp+0]  region id counter (1..MAX_ROOMS during pass 1)
	; [rsp+4]  exterior region id (set in pass 2)
	; [rsp+8]  highest region id assigned during pass 1

	; --- pass 0: clear ---
	lea rdi, [roommap]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax
	rep stosb

	lea rdi, [room_tally_beds]
	mov ecx, MAX_ROOMS + 1
	xor eax, eax
	rep stosb

	lea rdi, [room_tally_chairs]
	mov ecx, MAX_ROOMS + 1
	rep stosb

	lea rdi, [room_tally_floor]
	mov ecx, MAX_ROOMS + 1
	xor eax, eax
	rep stosw

	lea rdi, [room_tally_size]
	mov ecx, MAX_ROOMS + 1
	xor eax, eax
	rep stosd

	lea rdi, [room_capacity]
	mov ecx, MAX_ROOMS + 1
	xor eax, eax
	rep stosb

	mov dword [room_count], 0
	mov dword [rsp + 0], 1		; next region id to assign

	; --- pass 1: scan tiles + floodfill ---
	mov r12d, 0 ; ty
.p1_y:
	cmp r12d, MAP_HEIGHT
	jge .p1_done
	mov r13d, 0 ; tx
.p1_x:
	cmp r13d, MAP_WIDTH
	jge .p1_y_next

	; already in a region?
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, r13d
	lea rcx, [roommap]
	movzx ecx, byte [rcx + rax]
	test ecx, ecx
	jnz .p1_x_next

	; interior? 
	mov edi, r13d
	mov esi, r12d
	call room_tile_is_interior
	test eax, eax
	jz .p1_x_next

	; check capacity - if we'd overflow MAX_ROOMS, stop assigning ids
	; and leave the rest as zero (they'll behave like exterior)
	; shouldn't happen..hopefully
	mov eax, [rsp + 0]
	cmp eax, MAX_ROOMS
	jg .p1_x_next

	; new region - flood!
	mov edi, r13d
	mov esi, r12d
	mov edx, eax
	call room_floodfill_region
	; eax = tile count.  stash into room_tally_size[id]
	mov ecx, [rsp + 0]
	lea rdx, [room_tally_size]
	mov [rdx + rcx*4], eax

	inc dword [rsp + 0]

.p1_x_next:
	inc r13d
	jmp .p1_x
.p1_y_next:
	inc r12d
	jmp .p1_y
.p1_done:
	; total regions assigned = rsp+0 - 1
	mov eax, [rsp + 0]
	dec eax
	mov [rsp + 8], eax			; highest region id used

	; no regions at all? leave roommap zeroed, bail
	test eax, eax
	jz .out

	; --- pass 2: find the largest region = exterior ---
	mov ebx, 1					; region id walker
	mov r14d, 1					; best region id
	xor r15d, r15d				; best size (start at 0)
.p2_loop:
	cmp ebx, [rsp + 8]
	jg .p2_done
	lea rcx, [room_tally_size]
	mov edx, [rcx + rbx*4]
	cmp edx, r15d
	jle .p2_step
	mov r15d, edx
	mov r14d, ebx
.p2_step: 
	inc ebx
	jmp .p2_loop
.p2_done:
	mov [rsp + 4], r14d			; exterior id

	; --- pass 3: zero exterior tiles + renumber others contiguously
	; ext id might be 1 (whole open world) - the rest of ids could be
	; 2, 3, ..., N.  we want roommap to end up 0 = exterior, 1..M
	; = real rooms (contiguous).  build a small remap table!:
	;
	; remap[id] = 0 if id == exterior, else assigned-fresh

	;;
	; build remap into room_capacity slots (will overwrite right
	; before final fill).  room_capacity[id] = new id, or 0 for ext
	xor r14d, r14d	; new id counter, increments on use
	mov ebx, 1
.p3_remap:
	cmp ebx, [rsp + 8]
	jg .p3_remap_done
	mov eax, [rsp + 4]
	cmp ebx, eax
	je .p3_remap_ext
	inc r14d
	lea rcx, [room_capacity]
	mov [rcx + rbx], r14b
	jmp .p3_remap_step
.p3_remap_ext:
	lea rcx, [room_capacity]
	mov byte [rcx + rbx], 0
.p3_remap_step:
	inc ebx
	jmp .p3_remap
.p3_remap_done:
	mov [room_count], r14d		; M = real room count

	; walk roommap, rewrite each cell from old id to new id (or 0)
	xor ebx, ebx				; linear idx
.p3_walk:
	cmp ebx, MAP_WIDTH * MAP_HEIGHT
	jge .p3_walk_done
	lea rcx, [roommap]
	movzx eax, byte [rcx + rbx]
	test eax, eax
	jz .p3_walk_step
	lea rcx, [room_capacity]
	movzx eax, byte [rcx + rax]	; remap
	lea rcx, [roommap]
	mov [rcx + rbx], al
.p3_walk_step:
	inc ebx
	jmp .p3_walk
.p3_walk_done:

	; clear room_capacity now we're done with it as remap scratch
	lea rdi, [room_capacity]
	mov ecx, MAX_ROOMS + 1
	xor eax, eax
	rep stosb

	; nothing?
	mov eax, [room_count]
	test eax, eax
	jz .out

	; --- pass 4: tally bed/chair/floor per surviving room ---
	xor ebx, ebx				; tile linear idx
.p4_walk:
	cmp ebx, MAP_WIDTH * MAP_HEIGHT
	jge .p4_done
	lea rcx, [roommap]
	movzx eax, byte [rcx + rbx]
	test eax, eax
	jz .p4_step					; not in a room
	mov r12d, eax				; room id

	; bed?
	lea rcx, [objectmap]
	movzx eax, byte [rcx + rbx]
	cmp eax, OBJ_BED
	jne .p4_not_bed
	lea rcx, [room_tally_beds]
	movzx edx, byte [rcx + r12]
	cmp edx, 255
	jae .p4_step
	inc edx
	mov [rcx + r12], dl
	jmp .p4_step
.p4_not_bed:
	cmp eax, OBJ_CHAIR
	jne .p4_not_chair
	lea rcx, [room_tally_chairs]
	movzx edx, byte [rcx + r12]
	cmp edx, 255
	jae .p4_step
	inc edx
	mov [rcx + r12], dl
	jmp .p4_step
.p4_not_chair:
	; anything else inside the room counts as "floor space"
	lea rcx, [room_tally_floor]
	movzx edx, word [rcx + r12*2]
	cmp edx, 65535
	jae .p4_step
	inc edx
	mov [rcx + r12*2], dx
.p4_step:
	inc ebx
	jmp .p4_walk
.p4_done:

	; --- pass 5: compute capacities ---
	; cap[id] = min(beds, chairs, floor / TILES_PER_RESIDENT)
	mov ebx, 1
.p5_loop:
	cmp ebx, [room_count]
	jg .p5_done
	lea rcx, [room_tally_beds]
	movzx eax, byte [rcx + rbx]	; beds
	lea rcx, [room_tally_chairs]
	movzx edx, byte [rcx + rbx]	; chairs
	cmp eax, edx
	jle .p5_have_min
	mov eax, edx
.p5_have_min:
	; eax = min(beds, chairs).  now bound by floor / N
	lea rcx, [room_tally_floor]
	movzx edx, word [rcx + rbx*2]
	mov ecx, TILES_PER_RESIDENT
	xor r12d, r12d
	push rax
	mov eax, edx
	xor edx, edx
	div ecx						; eax = floor / N
	mov r12d, eax
	pop rax
	cmp eax, r12d
	jle .p5_save
	mov eax, r12d
.p5_save:
	; clamp to byte
	cmp eax, 255
	jle .p5_save_ok
	mov eax, 255
.p5_save_ok:
	lea rcx, [room_capacity]
	mov [rcx + rbx], al
	inc ebx
	jmp .p5_loop
.p5_done:

.out:
	add rsp, 16
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; room_total_capacity: sum capacity across all rooms
;----------------------------------------------------------------
; in:	(none)
; out:	eax = total habitable slots in the world
;================================================================
global room_total_capacity
room_total_capacity:
	push rbx
	xor eax, eax
	mov ebx, 1
.loop:
	cmp ebx, [room_count]
	jg .done
	lea rcx, [room_capacity]
	movzx edx, byte [rcx + rbx]
	add eax, edx
	inc ebx
	jmp .loop
.done:
	pop rbx
	ret

;================================================================
; room_at_tile: read roommap at (tx, ty).  0 = not in a room
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = room id (0 = none)
;================================================================
global room_at_tile
room_at_tile:
	test edi, edi
	js .none
	cmp edi, MAP_WIDTH
	jge .none
	test esi, esi
	js .none
	cmp esi, MAP_HEIGHT
	jge .none
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [roommap]
	movzx eax, byte [rdx + rax]
	ret
.none:
	xor eax, eax
	ret

;================================================================
; rooms_toggle_debug: flip the F8 overlay on/off
;================================================================
global rooms_toggle_debug
rooms_toggle_debug:
	xor byte [room_debug_view], 1
	lea rdi, [log_msg_rooms]
	call debug_log
	ret

;================================================================
; rooms_draw_brighten
;----------------------------------------------------------------
; per-pixel additive brighten over the framebuffer, clipped to the
; viewport-visible portion of any tile whose roommap[..] != 0
;----------------------------------------------------------------
; stack: 6 callee-saves + sub 32 = 80 + ret 8 = 88, misaligned by 8.
; pad to 16 (sub 40 instead) but we don't call out from this so
; it doesn't matter.. keeping sub 32 for the named locals
;	[rsp+0]	 tx0
;	[rsp+4]	 sx (clipped screen x)
;	[rsp+8]	 sy
;	[rsp+12] tile pixel width remaining
;	[rsp+16] tile pixel height remaining
;================================================================
global rooms_draw_brighten
rooms_draw_brighten:
	push rbx
	push r12
	push r13
	push r14
	push r15
	push rbp
	sub rsp, 32

	mov eax, [camera_x]
	xor edx, edx
	mov ecx, TILE_SIZE
	div ecx
	mov ebx, eax				; tx0

	mov eax, [camera_y]
	xor edx, edx
	div ecx
	mov r12d, eax				; ty0

	mov eax, [camera_x]
	add eax, WINDOW_W - 1
	xor edx, edx
	div ecx
	mov r13d, eax
	cmp r13d, MAP_WIDTH - 1
	jle .tx1_ok
	mov r13d, MAP_WIDTH - 1
.tx1_ok:

	mov eax, [camera_y]
	add eax, WINDOW_H - 1
	xor edx, edx
	div ecx
	mov r14d, eax
	cmp r14d, MAP_HEIGHT - 1
	jle .ty1_ok
	mov r14d, MAP_HEIGHT - 1
.ty1_ok:

	mov [rsp + 0], ebx
	mov r15d, r12d				; ty walker
.row:
	cmp r15d, r14d
	jg .done
	mov ebx, [rsp + 0]
.col:
	cmp ebx, r13d
	jg .row_done

	; room tile?
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [roommap]
	movzx eax, byte [rcx + rax]
	test eax, eax
	jz .col_next
	; only brighten when this id furnished/can house someone
	lea rcx, [room_capacity]
	movzx eax, byte [rcx + rax]
	test eax, eax
	jz .col_next

	; -- clip the tile rect to the framebuffer --
	; sx = tx*TILE_SIZE - camera_x; sy similar
	mov edi, ebx
	imul edi, TILE_SIZE
	sub edi, [camera_x]
	mov esi, r15d
	imul esi, TILE_SIZE
	sub esi, [camera_y]

	; width, height start at TILE_SIZE
	mov edx, TILE_SIZE			; w
	mov ecx, TILE_SIZE			; h

	; clip x
	test edi, edi
	jns .clip_x_done
	add edx, edi
	xor edi, edi
.clip_x_done:
	test esi, esi
	jns .clip_y_done
	add ecx, esi
	xor esi, esi
.clip_y_done:
	mov eax, edi
	add eax, edx
	cmp eax, WINDOW_W
	jle .clip_w_done
	mov edx, WINDOW_W
	sub edx, edi
.clip_w_done:
	mov eax, esi
	add eax, ecx
	cmp eax, WINDOW_H
	jle .clip_h_done
	mov ecx, WINDOW_H
	sub ecx, esi
.clip_h_done:
	test edx, edx
	jle .col_next
	test ecx, ecx
	jle .col_next

	; -- inner blit: walk h rows, each w pixels, add+saturate --
	; r10 = pixel ptr = framebuffer + (sy*WINDOW_W + sx)*4
	mov eax, esi
	imul eax, WINDOW_W
	add eax, edi
	shl eax, 2
	lea r10, [framebuffer]
	add r10, rax
	; row stride to next row = (WINDOW_W - w)*4
	mov r11d, WINDOW_W
	sub r11d, edx
	shl r11d, 2

	mov ebp, ecx				; h remaining
.b_row:
	test ebp, ebp
	jz .col_next
	mov ecx, edx				; w remaining
.b_px:
	test ecx, ecx
	jz .b_row_end
	mov eax, [r10]

	; B (low 8): add B brighten, sat
	mov r8d, eax
	and r8d, 0xFF
	add r8d, ROOM_BRIGHTEN_B
	cmp r8d, 255
	jle .b_bok
	mov r8d, 255
.b_bok:
	; G ((>>8) & FF): add G
	mov r9d, eax
	shr r9d, 8
	and r9d, 0xFF
	add r9d, ROOM_BRIGHTEN_G
	cmp r9d, 255
	jle .b_gok
	mov r9d, 255
.b_gok:
	shl r9d, 8
	or r8d, r9d
	; R ((>>16) & FF): add R
	mov r9d, eax
	shr r9d, 16
	and r9d, 0xFF
	add r9d, ROOM_BRIGHTEN_R
	cmp r9d, 255
	jle .b_rok
	mov r9d, 255
.b_rok:
	shl r9d, 16
	or r8d, r9d
	; alpha (top 8): keep
	and eax, 0xFF000000
	or r8d, eax
	mov [r10], r8d
	add r10, 4
	dec ecx
	jmp .b_px
.b_row_end:
	add r10, r11
	dec ebp
	jmp .b_row

.col_next:
	inc ebx
	jmp .col
.row_done:
	inc r15d
	jmp .row
.done:
	add rsp, 32
	pop rbp
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; rooms_draw_debug: F8 overlay - tint each room with a unique
; colour based on its id, and draw a 1px outline along every
; edge tile (where a room tile borders a non-room tile)
;----------------------------------------------------------------
; stack: 5 callee-saves + sub 32 = 72 + ret 8 = 80, aligned
;================================================================
global rooms_draw_debug
rooms_draw_debug:
	cmp byte [room_debug_view], 0
	je .out_early

	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 32

	mov eax, [camera_x]
	xor edx, edx
	mov ecx, TILE_SIZE
	div ecx
	mov ebx, eax				; tx0
	mov eax, [camera_y]
	xor edx, edx
	div ecx
	mov r12d, eax				; ty0
	mov eax, [camera_x]
	add eax, WINDOW_W - 1
	xor edx, edx
	div ecx
	mov r13d, eax
	cmp r13d, MAP_WIDTH - 1
	jle .tx1_ok
	mov r13d, MAP_WIDTH - 1
.tx1_ok:
	mov eax, [camera_y]
	add eax, WINDOW_H - 1
	xor edx, edx
	div ecx
	mov r14d, eax
	cmp r14d, MAP_HEIGHT - 1
	jle .ty1_ok
	mov r14d, MAP_HEIGHT - 1
.ty1_ok:

	mov [rsp], ebx
	mov r15d, r12d
.row:
	cmp r15d, r14d
	jg .done
	mov ebx, [rsp]
.col:
	cmp ebx, r13d
	jg .row_done

	; room id
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [roommap]
	movzx eax, byte [rcx + rax]
	test eax, eax
	jz .col_next; not a room tile

	; colour from id: cycle through a small palette so neighbours
	; differ visually.  pack 0x60RRGGBB with 0x60 alpha tint
	mov edx, eax
	imul edx, 2654435761		; knuth hash
	; take low 24 bits as RGB, OR alpha
	and edx, 0x00FFFFFF
	or edx, 0x60000000
	mov r8d, edx

	; tile origin
	mov edi, ebx
	imul edi, TILE_SIZE
	sub edi, [camera_x]
	mov [rsp + 4], edi
	mov esi, r15d
	imul esi, TILE_SIZE
	sub esi, [camera_y]
	mov [rsp + 8], esi

	; fill the tile
	mov edx, TILE_SIZE
	mov ecx, TILE_SIZE
	call fill_rect

	; draw a white edge wherever a 4-neighbour is not the same room
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [roommap]
	movzx r8d, byte [rcx + rax]	; our id (re-read - was clobbered)

	; up neighbour
	test r15d, r15d
	jz .edge_top; map edge counts as different
	mov eax, r15d
	dec eax
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [roommap]
	movzx ecx, byte [rcx + rax]
	cmp ecx, r8d
	je .skip_top
.edge_top:
	mov edi, [rsp + 4]
	mov esi, [rsp + 8]
	mov edx, TILE_SIZE
	mov ecx, 1
	push r8
	sub rsp, 8 ; align
	mov r8d, 0xC0FFFFFF
	call fill_rect
	add rsp, 8
	pop r8
.skip_top:

	; down neighbour
	mov eax, r15d
	inc eax
	cmp eax, MAP_HEIGHT
	jge .edge_bot
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [roommap]
	movzx ecx, byte [rcx + rax]
	cmp ecx, r8d
	je .skip_bot
.edge_bot:
	mov edi, [rsp + 4]
	mov esi, [rsp + 8]
	add esi, TILE_SIZE - 1
	mov edx, TILE_SIZE
	mov ecx, 1
	push r8
	sub rsp, 8
	mov r8d, 0xC0FFFFFF
	call fill_rect
	add rsp, 8
	pop r8
.skip_bot:

	; left neighbour
	test ebx, ebx
	jz .edge_left
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, ebx
	dec eax
	lea rcx, [roommap]
	movzx ecx, byte [rcx + rax]
	cmp ecx, r8d
	je .skip_left
.edge_left:
	mov edi, [rsp + 4]
	mov esi, [rsp + 8]
	mov edx, 1
	mov ecx, TILE_SIZE
	push r8
	sub rsp, 8
	mov r8d, 0xC0FFFFFF
	call fill_rect
	add rsp, 8
	pop r8
.skip_left:

	; right neighbour
	mov eax, ebx
	inc eax
	cmp eax, MAP_WIDTH
	jge .edge_right
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, ebx
	inc eax
	lea rcx, [roommap]
	movzx ecx, byte [rcx + rax]
	cmp ecx, r8d
	je .skip_right
.edge_right:
	mov edi, [rsp + 4]
	add edi, TILE_SIZE - 1
	mov esi, [rsp + 8]
	mov edx, 1
	mov ecx, TILE_SIZE
	push r8
	sub rsp, 8
	mov r8d, 0xC0FFFFFF
	call fill_rect
	add rsp, 8
	pop r8
.skip_right:

.col_next:
	inc ebx
	jmp .col
.row_done:
	inc r15d
	jmp .row
.done:
	add rsp, 32
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out_early:
	ret

%endif
