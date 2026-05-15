; pathing.inc.asm - dijkstra/bfs flow map from a single hub tile
;----------------------------------------------------------------
; breath first stearch over a djikstra flowmap thing, rather than
; a bunch of A* for potentially hundreds of NPCs.  as the hub
; seems like a fixed singular point.  should hopefully be a good
; cheap foundation to ai pathfinding.
; only ONE bfs needs to be run then stored, and updated only on
; world state change, same as the safezone calc
; NPCs can read this cached "flow map" on their ticks
;
; walkability rule:
;	- any tile with non-zero tile_speed_table speed	-> walkable
;	- CLOSED DOORS (speed 0) are treated as walkable too so npcs
;	  route through them and bump them open via try_open_door
;	- everything else (stone, trees, beds, walls) -> wall
;----------------------------------------------------------------
; storage:
;	pathing_dir		1 byte per tile (AI_DIR_*; AI_DIR_IDLE = no
;					path / unreachable)
;	hub_tx, hub_ty	int32 each
;
; queue is a flat ring of u16 tile indices
%ifndef PATHING_INC
%define PATHING_INC

section .bss
	; flow map: AI_DIR_* per tile.  AI_DIR_IDLE = unreachable
	alignb 1
	pathing_dir			resb MAP_WIDTH * MAP_HEIGHT
	; bfs scratch: distance in tiles from hub
	; u16 is plenty for now with this sized map, TODO: test bigger
	; 
	; 0xFFFF = unvisited sentinel
	alignb 2
	pathing_dist		resw MAP_WIDTH * MAP_HEIGHT
	; bfs queue of tile indices
	alignb 2
	pathing_queue		resw MAP_WIDTH * MAP_HEIGHT

	alignb 4
	pathing_qhead		resd 1
	pathing_qtail		resd 1

	; hub location in tile coords.  set once at world regen by
	; pathing_init_default_hub
	alignb 4
	hub_tx				resd 1
	hub_ty				resd 1

	; F7 toggle for flow map debug overlay
	alignb 1
	pathing_debug_view	resb 1

section .text

;================================================================
; pathing_tile_walkable: can an npc step onto tile (tx, ty)
;----------------------------------------------------------------
; matches the bfs walkability rule:
;	- in-bounds
;	- ground speed > 0
;	- object slot is empty, OR a door (open or closed), OR
;	  speed > 0
;	closed doors are explicitly walkable cos NPCs can open
;	will need to revisit when team locks/door breakages added
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 1 if walkable, 0 otherwise.trashes ecx, edx
;================================================================
pathing_tile_walkable:
	test edi, edi
	js .no
	cmp edi, MAP_WIDTH
	jge .no
	test esi, esi
	js .no
	cmp esi, MAP_HEIGHT
	jge .no

	; linear idx
	mov edx, esi
	imul edx, MAP_WIDTH
	add edx, edi	; edx = idx (kept across reads)

	; ground speed. zero = blocked outright
	lea rcx, [tilemap]
	movzx eax, byte [rcx + rdx]
	lea rcx, [tile_speed_table]
	movzx eax, byte [rcx + rax]
	test eax, eax
	jz .no

	; object overlay.  empty = walkable; door = walkable; non-door
	; with speed > 0 = walkable; everything else blocks
	lea rcx, [objectmap]
	movzx eax, byte [rcx + rdx]
	test eax, eax
	jz .yes			; OBJ_NONE - light passes too here

	; eax = obj id.  is it a door?
	push rdi		; tile_is_door reads eax, but we want
	push rsi		; to preserve our caller args
	push rdx
	call tile_is_door
	mov ecx, eax	; ecx = is_door
	pop rdx
	pop rsi
	pop rdi
	test ecx, ecx
	jnz .yes

	; non-door object: walkable iff speed > 0 (chairs etc)
	lea rcx, [objectmap]
	movzx eax, byte [rcx + rdx]
	lea rcx, [tile_speed_table]
	movzx eax, byte [rcx + rax]
	test eax, eax
	jz .no
.yes:
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; pathing_init_default_hub: set hub to map centre, nearest walkable
;----------------------------------------------------------------
; called once at startup and on world regen.  if the exact centre
; is walkable use it; else linear-scan the whole map and pick the
; walkable tile closest (chebyshev) to centre. mb a spiral is better?
;================================================================
pathing_init_default_hub:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 8				; align

	mov r13d, MAP_WIDTH
	shr r13d, 1				; r13 = cx
	mov r14d, MAP_HEIGHT
	shr r14d, 1				; r14 = cy

	;trivial: is (cx, cy) walkable?
	mov edi, r13d
	mov esi, r14d
	call pathing_tile_walkable
	test eax, eax
	jz .scan
	mov [hub_tx], r13d
	mov [hub_ty], r14d
	jmp .out

.scan:
	; ebx = best dist^2 so far, r12 = best idx.  -1 if none found
	mov ebx, 0x7FFFFFFF
	mov r12d, -1
	xor edi, edi			; edi = idx walker
.scan_loop:
	cmp edi, MAP_WIDTH * MAP_HEIGHT
	jge .scan_done

	; idx -> tx, ty
	mov eax, edi
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx					; eax = ty, edx = tx
	push rdi
	sub rsp, 8				; align for the call
	mov edi, edx
	mov esi, eax
	call pathing_tile_walkable
	add rsp, 8
	pop rdi
	test eax, eax
	jz .scan_next

	; chebyshev dist^2 to centre.  any reasonable distance metric
	; works here i think; we just want close-to-middle
	mov eax, edi
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx					; eax = ty, edx = tx
	sub edx, r13d
	sub eax, r14d
	imul edx, edx
	imul eax, eax
	add eax, edx
	cmp eax, ebx
	jge .scan_next
	mov ebx, eax
	mov r12d, edi
.scan_next:
	inc edi
	jmp .scan_loop
.scan_done:
	; if nothing walkable, leave hub at centre as a fallback so
	; recompute will hit the early-out and leave the field empty
	test r12d, r12d
	js .fallback
	mov eax, r12d
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx
	mov [hub_tx], edx
	mov [hub_ty], eax
	jmp .out
.fallback:
	mov [hub_tx], r13d
	mov [hub_ty], r14d
.out:
	add rsp, 8
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; pathing_recompute: rebuild the flow map via BFS from the hub
;----------------------------------------------------------------
; call after any event that could change walkability or hub:
;	- world regen
;	- placement / removal of walls, trees, etc
;	- door toggle (we treat doors as walkable here so this is
;	  technically a no-op, but call it anyway for consistency/future)
;	- hub move?
;----------------------------------------------------------------
; algorithm:
;	1. fill pathing_dist with 0xFFFF (unvisited), pathing_dir with
;	   AI_DIR_IDLE
;	2. mark the hub tile dist=0, push onto queue
;	3. while queue not empty: pop tile, visit 4 neighbours
;	   for each unvisited walkable neighbour:
;	     - set its dist = current+1 
;	     - set its dir to point BACK toward us (the parent)
;	     - push it
;================================================================
pathing_recompute:
	push rbx
	push r12
	push r13
	push r14
	push r15
	;5 pushes (40) + ret (8) = 48 bytes -> 16-aligned for inner calls

	; --- clear dir to AI_DIR_IDLE and dist to 0xFFFF ---
	lea rdi, [pathing_dir]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax	; AI_DIR_IDLE = 0
	rep stosb

	lea rdi, [pathing_dist]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	mov ax, 0xFFFF
	rep stosw

	; --- seed: hub tile at dist 0, push onto queue ---
	mov dword [pathing_qhead], 0
	mov dword [pathing_qtail], 0

	; verify hub is in-bounds and walkable.  if not, bail
	mov edi, [hub_tx]
	mov esi, [hub_ty]
	call pathing_tile_walkable
	test eax, eax
	jz .done

	; hub idx = hub_ty * W + hub_tx
	mov eax, [hub_ty]
	imul eax, MAP_WIDTH
	add eax, [hub_tx]
	mov ebx, eax		; ebx = hub idx (kept around)

	; pathing_dist[hub] = 0
	lea rcx, [pathing_dist]
	mov word [rcx + rbx*2], 0
	; pathing_dir[hub] stays AI_DIR_IDLE - the hub itself has no
	; "next step", bit crappy, TODO: make this a larger room or so

	; enqueue hub
	lea rcx, [pathing_queue]
	mov word [rcx], bx
	mov dword [pathing_qtail], 1

	; --- BFS loop ---
.qloop:
	mov eax, [pathing_qhead]
	cmp eax, [pathing_qtail]
	jge .done

	; pop tile idx
	lea rcx, [pathing_queue]
	movzx ebx, word [rcx + rax*2]
	inc dword [pathing_qhead]

	; current dist
	lea rcx, [pathing_dist]
	movzx r12d, word [rcx + rbx*2] ; r12 = cur dist

	; current (tx, ty) from idx
	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx				; eax = ty, edx = tx
	mov r13d, edx		; r13 = tx
	mov r14d, eax		; r14 = ty

	; --- visit 4 neighbours.  new_dist = cur dist + 1 passed in r8d,
	; back-pointer dir (the direction we'd step FROM the neighbour TO
	; reach the parent) passed in edx....  the dir we store at the
	; neighbour points back toward the hub via the parent
	mov r15d, r12d
	inc r15d			; new_dist
	; clamp at 0xFFFE so 0xFFFF stays as our "unvisited" sentinel
	cmp r15d, 0xFFFE
	jle .nd_ok
	mov r15d, 0xFFFE
.nd_ok:

	; neighbour = (tx, ty-1). step from neighbour to parent goes DOWN
	mov edi, r13d
	mov esi, r14d
	dec esi
	mov edx, AI_DIR_DOWN
	mov r8d, r15d
	call pathing_relax
	; neighbour = (tx, ty+1).  step UP to parent
	mov edi, r13d
	mov esi, r14d
	inc esi
	mov edx, AI_DIR_UP
	mov r8d, r15d
	call pathing_relax
	; neighbour = (tx-1, ty).  step RIGHT to parent
	mov edi, r13d
	dec edi
	mov esi, r14d
	mov edx, AI_DIR_RIGHT
	mov r8d, r15d
	call pathing_relax
	; neighbour = (tx+1, ty).  step LEFT to parent
	mov edi, r13d
	inc edi
	mov esi, r14d
	mov edx, AI_DIR_LEFT
	mov r8d, r15d
	call pathing_relax

	jmp .qloop

.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; pathing_relax: visit one neighbour during BFS
; if it's walkable and unvisited, set its dir/dist and enqueue it
;----------------------------------------------------------------
; the dir we store at the neighbour is the cardinal step FROM the
; neighbour TOWARD the parent - ie one step closer to the hub
;----------------------------------------------------------------
; in:	edi = nbr tx, esi = nbr ty, edx = AI_DIR_* back-pointer,
;		r8d = new distance to write (parent dist + 1, clamped)
;================================================================
pathing_relax:
	; --- bounds + walkability ---
	test edi, edi
	js .out
	cmp edi, MAP_WIDTH
	jge .out
	test esi, esi
	js .out
	cmp esi, MAP_HEIGHT
	jge .out

	push rbx
	; 1 push (8) + 8 ret = 16 - aligned for inner calls

	; nbr idx = ty * W + tx
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi 
	mov ebx, eax				; ebx = nbr idx 

	; unvisited?
	lea rcx, [pathing_dist]
	movzx eax, word [rcx + rbx*2]
	cmp eax, 0xFFFF
	jne .pop_out				; already has a (shorter) dist

	;is walkable?  the call trashes eax/ecx/edx but preserves edi/esi
	; (its push/pop set restores them)
	; save edx (back-dir) and r8d (new dist) ourselves.
	; pushing 2 keeps alignment (sub 16 total from this point's
	; already-aligned rsp)
	push rdx
	push r8
	call pathing_tile_walkable
	pop r8
	pop rdx
	test eax, eax
	jz .pop_out

	; --- relax: dist = new_dist (r8d), dir = back-pointer, enqueue
	lea rcx, [pathing_dist]
	mov [rcx + rbx*2], r8w

	lea rcx, [pathing_dir]
	mov [rcx + rbx], dl

	; enqueue
	mov eax, [pathing_qtail]
	lea rcx, [pathing_queue]
	mov [rcx + rax*2], bx
	inc dword [pathing_qtail]

.pop_out:
	pop rbx
.out:
	ret

;================================================================
; pathing_dir_at_tile: read the flow map dir at (tx, ty)
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = AI_DIR_* (AI_DIR_IDLE if unreachable / oob / at hub)
;================================================================
pathing_dir_at_tile:
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
	lea rdx, [pathing_dir]
	movzx eax, byte [rdx + rax]
	ret
.none:
	xor eax, eax
	ret

;================================================================
; pathing_dir_at_pixel: like above but with pixel coords
;----------------------------------------------------------------
; in:	edi = px, esi = py
; out:	eax = AI_DIR_*
;================================================================
pathing_dir_at_pixel:
	; floor-divide each by TILE_SIZE.  same convention as
	; tile_at_pixel for sub-tile coords on negatives, except we
	; reject oob via pathing_dir_at_tile
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov edi, eax
	mov eax, esi
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov esi, eax
	jmp pathing_dir_at_tile

;================================================================
; pathing_hub_dist_at_tile: read the cached BFS distance
;----------------------------------------------------------------
; useful for "am i far enough from the hub to bother heading back"
; kinda checks etc.  returns 0xFFFF for unvisited / oob
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = distance in tiles, or 0xFFFF
;================================================================
pathing_hub_dist_at_tile:
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
	lea rdx, [pathing_dist]
	movzx eax, word [rdx + rax*2]
	ret
.none:
	mov eax, 0xFFFF ; 
	ret

;================================================================
; pathing_toggle_debug: flip the F7 overlay on/off
;================================================================
section .data
	log_msg_pathing	db "pathing overlay toggled", 0
section .text

pathing_toggle_debug:
	xor byte [pathing_debug_view], 1
	lea rdi, [log_msg_pathing]
	call debug_log
	ret

;================================================================
; pathing_draw_debug: tint/arrows like our safezone map
;----------------------------------------------------------------
; F7 toggle.  iterates only visible tiles
;----------------------------------------------------------------
; locals after prologue (5 pushes + sub 16 = 64 -> aligned):
;	[rsp+0]	tx0 stash
;	[rsp+4]	tile origin screen sx
;	[rsp+8]	tile origin screen sy
;	[rsp+12]	tile centre screen cx (for arrow drawing)
;----------------------------------------------------------------
; r12d carries scratch (dir or colour) across fill_rect calls -
; safe because fill_rect saves r12 in its prologue!
;================================================================
pathing_draw_debug:
	cmp byte [pathing_debug_view], 0
	je .out

	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 16				; 5 pushes (40) + 16 + ret (8)= 64

	; --- visible tile range (same calc as safezone_draw_debug) ---
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
	mov r13d, eax				; tx1
	cmp r13d, MAP_WIDTH - 1
	jle .tx1_ok
	mov r13d, MAP_WIDTH - 1
.tx1_ok:

	mov eax, [camera_y]
	add eax, WINDOW_H - 1
	xor edx, edx
	div ecx
	mov r14d, eax				; ty1
	cmp r14d, MAP_HEIGHT - 1
	jle .ty1_ok
	mov r14d, MAP_HEIGHT - 1
.ty1_ok:

	mov [rsp], ebx				; tx0
	mov r15d, r12d				; ty walker = ty0
.row:
	cmp r15d, r14d
	jg .done

	mov ebx, [rsp]
.col:
	cmp ebx, r13d
	jg .row_done

	; --- look up dir + dist at (ebx, r15d) ---
	mov eax, r15d
	imul eax, MAP_WIDTH;
	add eax, ebx
	mov r12d, eax				; r12 = tile linear idx
	lea rcx, [pathing_dir]
	movzx eax, byte [rcx + r12]	; eax = dir
	lea rcx, [pathing_dist]
	movzx ecx, word [rcx + r12*2] ; ecx = dist

	; skip unreachable tiles entirely (dist == 0xFFFF, dir == IDLE).
	; the hub itself also has dir == IDLE but dist == 0 anyway
	jnz .reachable
	test ecx, ecx
	jz .reachable				; hub
	jmp .col_next

.reachable:
	; cache tile screen origin (sx, sy) and centre (cx, cy)
	mov edx, ebx
	imul edx, TILE_SIZE
	sub edx, [camera_x]
	mov [rsp + 4], edx			; sx
	mov esi, r15d
	imul esi, TILE_SIZE
	sub esi, [camera_y]
	mov [rsp + 8], esi			; sy
	add edx, TILE_SIZE / 2
	mov [rsp + 12], edx			; cx (sy + TILE_SIZE/2 used inline)

	; stash dir in r12 across the colour-build + fill_rect calls
	; (caller-saved across fill_rect: r12 is preserved by callee)
	mov r12d, eax

	; --- build the tint colour from dist (ecx) ---
	; r = clamp(dist * 10, 0, 255), g = 255 - r, b = 0, a = 0x30
	mov eax, ecx
	imul eax, 10
	cmp eax, 255
	jle .r_ok
	mov eax, 255
.r_ok:
	; eax = r in [0,255]
	mov edx, 255
	sub edx, eax				; edx = g
	; pack 0x30RRGG00
	shl eax, 16					; R << 16
	shl edx, 8					; G << 8
	or eax, edx
	or eax, 0x30000000			; alpha

	; if this is the hub, override with a brighter green tint
	mov edx, [hub_tx]
	cmp ebx, edx
	jne .colour_done
	mov edx, [hub_ty]
	cmp r15d, edx
	jne .colour_done
	mov eax, 0x6020FF40			; hub green
.colour_done:

	; --- draw underlay tint (full tile rect) ---
	mov edi, [rsp + 4]
	mov esi, [rsp + 8]
	mov edx, TILE_SIZE
	mov ecx, TILE_SIZE
	mov r8d, eax
	call fill_rect

	; --- hub? skip arrow, draw this thing ---
	mov eax, [hub_tx]
	cmp ebx, eax
	jne .draw_arrow
	mov eax, [hub_ty]
	cmp r15d, eax
	jne .draw_arrow
	mov edi, [rsp + 12]			; cx
	sub edi, 3
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 3
	mov edx, 6
	mov ecx, 6
	mov r8d, 0xE0FFFF00
	call fill_rect
	jmp .col_next

.draw_arrow:
; r12 = dir.  arrow built from 3 fill_rects, centred at
; (cx, cy) where cy = sy + TILE_SIZE/2.  3 rects per direction:
;UP   :apex(cx,cy-3,1,1) flare(cx-1, cy-2,3,1) shaft(cx,cy-1,1,4)
;DOWN :shaft(cx,cy-2,1,4) flare(cx-1, cy+2, 3, 1) apex(cx, cy+3,1,1)
;LEFT :apex(cx-3,cy,1,1) flare(cx-2, cy-1,1,3) shaft(cx-1, cy,4,1)
;RIGHT:shaft(cx-2,cy,4,1) flare(cx+2, cy-1,1,3) apex(cx+3, cy,1,1)
	cmp r12d, AI_DIR_UP
	je .arrow_up
	cmp r12d, AI_DIR_DOWN
	je .arrow_down
	cmp r12d, AI_DIR_LEFT
	je .arrow_left
	cmp r12d, AI_DIR_RIGHT
	je .arrow_right
	jmp .col_next

.arrow_up:
	; apex
	mov edi, [rsp + 12]
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 3
	mov edx, 1
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; flare
	mov edi, [rsp + 12]
	dec edi
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 2
	mov edx, 3
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; shaft
	mov edi, [rsp + 12]
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 1
	mov edx, 1
	mov ecx, 4
	mov r8d, 0xE0FFFFFF
	call fill_rect
	jmp .col_next

.arrow_down:
	; shaft
	mov edi, [rsp + 12]
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 2
	mov edx, 1
	mov ecx, 4
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; flare
	mov edi, [rsp + 12]
	dec edi
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 + 2
	mov edx, 3
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; apex
	mov edi, [rsp + 12]
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 + 3
	mov edx, 1
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	jmp .col_next

.arrow_left:
	; apex
	mov edi, [rsp + 12]
	sub edi, 3
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2
	mov edx, 1
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; flare
	mov edi, [rsp + 12]
	sub edi, 2
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 1
	mov edx, 1
	mov ecx, 3
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; shaft
	mov edi, [rsp + 12]
	dec edi
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2
	mov edx, 4
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	jmp .col_next

.arrow_right:
	; shaft
	mov edi, [rsp + 12]
	sub edi, 2
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2
	mov edx, 4
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; flare
	mov edi, [rsp + 12]
	add edi, 2
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2 - 1
	mov edx, 1
	mov ecx, 3
	mov r8d, 0xE0FFFFFF
	call fill_rect
	; apex
	mov edi, [rsp + 12]
	add edi, 3
	mov esi, [rsp + 8]
	add esi, TILE_SIZE/2
	mov edx, 1
	mov ecx, 1
	mov r8d, 0xE0FFFFFF
	call fill_rect

.col_next:
	inc ebx
	jmp .col
.row_done:
	inc r15d
	jmp .row
.done: ; messy, i should have just done a sprite
	add rsp, 16
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out:
	ret

%endif