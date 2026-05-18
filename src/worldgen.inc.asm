; worldgen.inc.asm - generates a world through iterative CA

%ifndef WORLDGEN_INC
%define WORLDGEN_INC

%define CA_WALL_PERCENT 40		; initial wall density
%define CA_BASE_ITERATIONS	3		; smoothing passes

; intermediate cell types used during CA
%define CA_FLOOR 0
%define CA_WALL  1

section .data
	; runtime-tunable iteration count (was %define)
	ca_iterations_count dd CA_BASE_ITERATIONS ; default 4 seems good

section .bss
	alignb 8
	; scratch buffer for double-buffer, same size as tilemap
	ca_scratch resb MAP_WIDTH * MAP_HEIGHT

section .text
;================================================================
; generate_world:
;
; cellular automata-driven world sculpting for fun and learning:
;
; 1: noise - fill the map randomly. 45% wall 55% floor
; 2: smooth - run CA iterations of:
;	a) for each cell, count wall neighbours in 3x3 area (inc self)
;	b) cell becomes wll if that count >= 5, else floor
;	   - this is double buffered, next state is written to scratch
;		 buffer then copied back, so the cell visit order won't matter
;	(off-grid cells count as wall)
; 3: paint - convert the cells (wall/floor) into tile IDs;
;================================================================
generate_world:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15

	; re-seed from current_seed so the same seed reproduces the
	; same noise stream. this is what lets iterate_world replay
	; the world with one extra smoothing pass
	mov eax, [current_seed]
	mov [rng_state], rax
	; guard against zero seed (xorshift gets stuck on 0)
	test rax, rax
	jnz .seed_ok
	mov qword [rng_state], 1
.seed_ok:

	; clear objectmap to OBJ_NONE.  trees later get painted into
	; it during step 3; without this clear, restarts would inherit
	; objects from the previous world
	xor eax, eax
	mov ecx, MAP_WIDTH * MAP_HEIGHT / 8
	lea rdi, [objectmap]
	rep stosq

	; --- step 1: fill tilemap with random walls/floors ---
	; just a linear list of tiles
	xor r12d, r12d				; tile_index = 0
.fill_loop:
	cmp r12d, MAP_WIDTH * MAP_HEIGHT
	jge .stamp_start

	; convert linear index to (x, y) to check borders
	mov eax, r12d
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = y, edx = x

	; any border cell is always wall (keeps our map enclosed)
	test eax, eax
	jz .force_wall
	test edx, edx
	jz .force_wall
	cmp eax, MAP_HEIGHT-1
	je .force_wall
	cmp edx, MAP_WIDTH-1
	je .force_wall

	; interior cell, randomly turn wall or not
	mov edi, CA_WALL_PERCENT	; % chance of wall
	call rng_percent			; eax = 1 if wall, 0 if floor
	jmp .write_cell
.force_wall:
	mov eax, CA_WALL
.write_cell:
	lea rbx, [tilemap]
	mov [rbx + r12], al
	inc r12d
	jmp .fill_loop

	; --- step 1b: stamp a 3x3 floor patch at the map centre ---
	; gives the hub a guaranteed seed of open ground.  the CA pass
	; below will smooth around it, eroding edges sometimes but the
	; centre cell of a 3x3 of floor has 8 floor neighbours so always
	; survives the >=5-walls-becomes-wall rule.  doing this BEFORE
	; CA so the result feels natural rather than stamped on
.stamp_start:
	mov r12d, MAP_HEIGHT
	shr r12d, 1					; cy
	dec r12d					; start one row up
	mov r13d, 3					; rows to write
.stamp_row:
	test r13d, r13d
	jz .fill_done
	mov r14d, MAP_WIDTH
	shr r14d, 1					; cx
	dec r14d					; start one col left
	mov r15d, 3					; cols this row
.stamp_col:
	test r15d, r15d
	jz .stamp_row_next

	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, r14d
	lea rbx, [tilemap]
	mov byte [rbx + rax], CA_FLOOR

	inc r14d
	dec r15d
	jmp .stamp_col
.stamp_row_next:
	inc r12d
	dec r13d
	jmp .stamp_row

	; --- step 2: run CA iterations to smooth the noise ---
.fill_done:
	mov r12d, [ca_iterations_count]
.ca_iter:
	test r12d, r12d
	jz .paint

	call ca_step	; one smoothing pass
	dec r12d
	jmp .ca_iter ; feels like 4-6 is the sweet spot, but it's cheap
				 ; (atm, 2 tile type, on small world - TODO: profile)
				 ; that higher is fine too if wanted

	; --- step 3: convert CA cells to tile ids ---
	;
	; CA_WALL  -> TILE_STONE
	; CA_FLOOR -> TILE_GRASS (85%) else TILE_DIRT
.paint:
	xor r12d, r12d
.paint_loop:
	cmp r12d, MAP_WIDTH * MAP_HEIGHT
	jge .paint_done

	lea rbx, [tilemap]
	movzx eax, byte [rbx + r12]
	cmp eax, CA_WALL
	je .paint_wall

	; floor cell: 10% chance of tree/dirt, otherwise grass
	mov edi, 10
	call rng_percent
	test eax, eax
	jz .paint_grass
	; % chance of trees vs dirt
	mov edi, 20
	call rng_percent
	test eax, eax
	jz .paint_dirt
	; tree: ground stays grass, tree goes in object overlay
	mov al, TILE_GRASS
	lea rbx, [tilemap]
	mov [rbx + r12], al
	mov al, OBJ_TREE
	lea rbx, [objectmap]
	mov [rbx + r12], al
	jmp .paint_cell_done

.paint_dirt:
	; natural dirt patch: just set the ground tile to TILE_DIRT.
	mov al, TILE_DIRT
	lea rbx, [tilemap]
	mov [rbx + r12], al
	jmp .paint_cell_done

.paint_grass:
	mov al, TILE_GRASS
	jmp .paint_write

.paint_wall:
	; CA wall cell: stone wall sits in the object overlay, dirt
	; underneath as the ground.  the wall blocks movement, chopping
	; it later justclears the overlay, leaving the dirt floor exposed
	mov al, TILE_DIRT
	lea rbx, [tilemap]
	mov [rbx + r12], al
	mov al, OBJ_STONE_WALL
	lea rbx, [objectmap]
	mov [rbx + r12], al
	jmp .paint_cell_done

.paint_write:
	lea rbx, [tilemap]
	mov [rbx + r12], al
.paint_cell_done:
	inc r12d
	jmp .paint_loop
.paint_done:

	; --- step 4: scatter water tiles ---
	;
	; for each interior cell, some % chance water's considered
	; if yes, check the full 3x3 neighbourhood: if all cells are
	; non-stone (aka open floor), place water at the centre
	mov r13d, 1			; y (skip border row)
.water_y:
	cmp r13d, MAP_HEIGHT-1
	jge .water_done
	mov r14d, 1			; x (skip border column)
.water_x:
	cmp r14d, MAP_WIDTH-1
	jge .water_next_y
	; % of tiles to consider
	mov edi, 5
	call rng_percent
	test eax, eax
	jz .water_next

	; check 3x3 around (r14, r13) - all must be non-stone
	mov r15d, -1		; dy
.water_check_y:
	cmp r15d, 1
	jg .water_place		; survived all checks: place water!
	mov ecx, -1			; dx
.water_check_x:
	cmp ecx, 1
	jg .water_check_y_next

	; read tilemap[(y+dy) * MAP_WIDTH + (x+dx)]
	mov eax, r13d
	add eax, r15d		; y + dy
	imul eax, MAP_WIDTH
	mov edx, r14d
	add edx, ecx		; x + dx
	add eax, edx
	; check objectmap for a stone wall
	lea rbx, [objectmap]
	movzx edi, byte [rbx + rax]
	cmp edi, OBJ_STONE_WALL
	je .water_next		; wall found - leave, no water here

	inc ecx
	jmp .water_check_x
.water_check_y_next:
	inc r15d
	jmp .water_check_y

.water_place:
	; all 9 cells were open - put water at the centre
	mov eax, r13d
	imul eax, MAP_WIDTH
	add eax, r14d
	lea rbx, [tilemap]
	mov byte [rbx + rax], TILE_WATER
.water_next:
	inc r14d
	jmp .water_x
.water_next_y:
	inc r13d
	jmp .water_y
.water_done:

	; --- step 5: dress the hub - 3x3 wood floor + a torch ---
	; the CA-stamped 3x3 floor at the centre survives as grass/dirt,
	; which is functional but doesn't read as "this is the safe hub".
	; overwrite those 9 cells with wood floor (and clear any object
	; so nothing's blocking spawn) so the player has a visible base.
	; one torch goes to the left-of-centre cell to light the area
	mov r12d, MAP_HEIGHT
	shr r12d, 1
	dec r12d					; ty walker start = cy - 1
	mov r13d, 3					; rows left
.hub_row:
	test r13d, r13d
	jz .hub_torch
	mov r14d, MAP_WIDTH
	shr r14d, 1
	dec r14d					; tx walker start = cx - 1
	mov r15d, 3					; cols left this row
.hub_col:
	test r15d, r15d
	jz .hub_row_next

	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, r14d
	; tilemap = TILE_WOOD_FLOOR
	lea rbx, [tilemap]
	mov byte [rbx + rax], TILE_WOOD_FLOOR
	; objectmap = OBJ_NONE: clear any tree etc that might have landed
	lea rbx, [objectmap]
	mov byte [rbx + rax], OBJ_NONE

	inc r14d
	dec r15d
	jmp .hub_col
.hub_row_next:
	inc r12d
	dec r13d
	jmp .hub_row

.hub_torch:
	; torch at (cx - 1, cy) - left-of-centre cell of the patch
	mov r12d, MAP_HEIGHT
	shr r12d, 1					; cy
	mov r14d, MAP_WIDTH
	shr r14d, 1
	dec r14d					; cx - 1
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, r14d
	lea rbx, [objectmap]
	mov byte [rbx + rax], OBJ_TORCH
	; roll a stable variant byte for the torch as the placement code
	; does,so any per-variant animation stays consistent across regen
	; probably overkill..
	push rax
	call rng_next
	pop rcx
	lea rbx, [object_variant]
	mov byte [rbx + rcx], al

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; ca_step: a single iteration of cellular automata "smoothing"
;----------------------------------------------------------------
; for each cell, count how many of its neighbours are walls
; if count >= 5, or if cell is off-grid, cell becomes WALL
; else becomes FLOOR
; double buffered to avoid neighbours affecting each other
;================================================================
ca_step:
	push rbx
	push r12
	push r13
	push r14
	push r15

	xor r12d, r12d		; y = 0
.row:
	cmp r12d, MAP_HEIGHT
	jge .write_back

	xor r13d, r13d		; x = 0
.col:
	cmp r13d, MAP_WIDTH
	jge .next_row

	; -- count wall neighbours in 3x3 --
	xor r14d, r14d		; count = 0
	mov r15d, -1		; dy = -1
.cy:
	cmp r15d, 1
	jg .count_done
	mov ecx, -1			; dx = -1
.cx:
	cmp ecx, 1
	jg .cy_next

	; compute neighbour coords (nx, ny)
	mov eax, r13d
	add eax, ecx		; nx = x + dx
	mov edx, r12d
	add edx, r15d		; ny = y + dy

	; bounds check - if off-grid, count as wall
	test eax, eax
	js .is_wall			; nx < 0
	cmp eax, MAP_WIDTH
	jge .is_wall		; nx >= MAP_WIDTH
	test edx, edx
	js .is_wall			; ny < 0
	cmp edx, MAP_HEIGHT
	jge .is_wall		; ny >= MAP_HEIGHT

	; in-grid: add the cell value (CA_WALL= +1, CA_FLOOR= +0)
	imul edx, MAP_WIDTH
	add edx, eax
	lea rbx, [tilemap]
	movzx eax, byte [rbx + rdx]
	add r14d, eax
	jmp .next_neighbour
.is_wall:
	inc r14d			; off-grid = one more wall
.next_neighbour:
	inc ecx
	jmp .cx
.cy_next:
	inc r15d
	jmp .cy
.count_done:

	; -- apply threshold: --
	; >= 5 walls: this cell becomes wall
	mov eax, CA_FLOOR
	; r14d=4 and the world implodes, 6 and it converges on all floors
	cmp r14d, 5
	jl .write
	mov eax, CA_WALL
.write:
	mov edx, r12d
	imul edx, MAP_WIDTH
	add edx, r13d
	lea rbx, [ca_scratch]
	mov [rbx + rdx], al

	inc r13d
	jmp .col
.next_row:
	inc r12d
	jmp .row

.write_back:
	; copy scratch buffer back over the tilemap
	; rep movsb copies rcx bytes from [rsi] to [rdi]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	lea rsi, [ca_scratch]
	lea rdi, [tilemap]
	rep movsb

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; iterate_world: bump CA iteration count and regenerate world
;----------------------------------------------------------------
; could convert the grass, dirt, water back to walls,floors,
; but for ease i'm just redoing the worldgen with the same seed
; and differing smoothing iters.  this is just for demoing anyway
;
; caller is responsible for clearing any future entities before
; calling this, since this rebuilds the world under their feet
;================================================================
global iterate_world
iterate_world:
	inc dword [ca_iterations_count]
	call generate_world
	ret

global reset_world_iterations
reset_world_iterations:
	mov dword [ca_iterations_count], CA_BASE_ITERATIONS
	ret

;================================================================
; tree_regrowth_tick
;----------------------------------------------------------------
; called once per frame from main.asm
; an attempt:
;   - pick a random tile in the map
;   - if it's grass AND has at least one adjacent tree (4-neighbour),
;	  replace it with a tree
;================================================================
%define TREE_REGROW_PERIOD 20;60	; frames between attempts

section .data
	tree_regrow_counter dd 0

section .text
;================================================================
; tile_has_entity
;----------------------------------------------------------------
; is any alive entity (player or NPC) standing on tile (tx, ty)?
; used for tree growth etc
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 1 if occupied by an alive entity, else 0
;================================================================
tile_has_entity:
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee-saves + ret = 48, 16-aligned

	mov r14d, edi			; tx
	mov r15d, esi			; ty
	xor ebx, ebx			; loop index
	mov r12d, [entity_count]
.loop:
	cmp ebx, r12d
	jge .no

	mov edi, ebx
	call entity_ptr
	mov r13, rax

	; alive?
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .next

	; entity tile = (x / TILE_SIZE, y / TILE_SIZE), floor-style
	mov eax, [r13 + ENT_X_OFFSET]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .ex_ok
	dec eax
.ex_ok:
	cmp eax, r14d
	jne .next

	mov eax, [r13 + ENT_Y_OFFSET]
	cdq
	idiv ecx
	test edx, edx
	jns .ey_ok
	dec eax
.ey_ok:
	cmp eax, r15d
	jne .next

	mov eax, 1
	jmp .out
.next:
	inc ebx
	jmp .loop
.no:
	xor eax, eax
.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

tree_regrowth_tick:
	push rbx
	push r12
	; throttle - only consider regrowing once per period
	mov eax, [tree_regrow_counter]
	inc eax
	cmp eax, TREE_REGROW_PERIOD
	jl .save_only
	xor eax, eax				; reset
	mov [tree_regrow_counter], eax

	; pick a random interior tile (avoid the border ring)
	mov edi, MAP_WIDTH - 2
	call rng_range
	inc eax						; in [1, MAP_WIDTH-1)
	mov ebx, eax				; tx
	mov edi, MAP_HEIGHT - 2
	call rng_range
	inc eax						; ty in [1, MAP_HEIGHT-1)
	mov r12d, eax

	; current cell must be grass ground with no blocking object.
	; trees and other furniture in the object slot block regrowth
	mov edi, ebx
	mov esi, r12d
	call tile_at
	cmp eax, TILE_GRASS
	jne .out
	mov edi, ebx
	mov esi, r12d
	call object_at
	test eax, eax
	jnz .out					; something there - blocked
.check_neighbours:

	; need at least one adjacent tree (NESW).  on first hit, jump
	; to .check_occupied which gates on entity occupancy before
	; actually growing - this is what stops trees from boxing
	; the player or NPCs in
	mov edi, ebx
	mov esi, r12d
	dec esi
	call object_at
	cmp eax, OBJ_TREE
	je .check_occupied

	mov edi, ebx
	mov esi, r12d
	inc esi
	call object_at
	cmp eax, OBJ_TREE
	je .check_occupied

	mov edi, ebx
	dec edi
	mov esi, r12d
	call object_at
	cmp eax, OBJ_TREE
	je .check_occupied

	mov edi, ebx
	inc edi
	mov esi, r12d
	call object_at
	cmp eax, OBJ_TREE
	je .check_occupied

	jmp .out

.check_occupied:
	; one of the 4 cardinal neighbours is a tree - this tile is a
	; regrowth candidate.  bail if a player or NPC is standing on
	; it, otherwise we trap them in their own room
	mov edi, ebx
	mov esi, r12d
	call tile_has_entity
	test eax, eax
	jnz .out

.grow:
	; write tree into objectmap at (ebx, r12d) - ground stays grass
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [objectmap]
	mov byte [rcx + rax], OBJ_TREE
	; a tree is both an occluder and a wall - rebuild the lazy
	; world-state masks so the new obstacle is visible to spawn rules
	; and to npc routing this same frame.
	; rsp is misaligned by 8 here (2 callee-saves + ret = 24) so we
	; sub 8 to align for the heavy recompute calls
	sub rsp, 8
	call safezone_recompute
	call pathing_recompute
	call rooms_recompute
	add rsp, 8
	jmp .out

.save_only:
	mov [tree_regrow_counter], eax
.out:
	pop r12
	pop rbx
	ret

%endif