; worldgen.inc.asm - generates a world through iterative CA

%ifndef WORLDGEN_INC
%define WORLDGEN_INC

%define CA_WALL_PERCENT 40		; initial wall density
%define CA_BASE_ITERATIONS	0		; smoothing passes

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

	; --- step 1: fill tilemap with random walls/floors ---
	; just a linear list of tiles
	xor r12d, r12d				; tile_index = 0
.fill_loop:
	cmp r12d, MAP_WIDTH * MAP_HEIGHT
	jge .fill_done

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

	; --- step 2: run CA iterations to smooth the noise ---
.fill_done:
	mov r12d, [ca_iterations_count]
.ca_iter:
	test r12d, r12d
	jz .paint

	call ca_step	; one smoothing pass
	dec r12d
	jmp .ca_iter ; feels like 4-6 is the sweet spot, but it's cheap
				 ; (atm, 2 tile type, on small world - TODO profile)
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

	; floor cell: 15% chance of dirt, otherwise grass
	mov edi, 15
	call rng_percent
	test eax, eax
	jz .paint_grass
	mov al, TILE_DIRT
	jmp .paint_write
.paint_grass:
	mov al, TILE_GRASS
	jmp .paint_write
.paint_wall:
	mov al, TILE_STONE
.paint_write:
	lea rbx, [tilemap]
	mov [rbx + r12], al
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
	mov edi, 20
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
	lea rbx, [tilemap]
	movzx edi, byte [rbx + rax]
	cmp edi, TILE_STONE
	je .water_next		; stone found - leave, no water here

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
	; copy scratch buffer back over the tilemap.
	; rep movsb copies rcx bytes from [rsi] to [rdi].
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

%endif
