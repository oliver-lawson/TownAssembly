; spawn.inc.asm - periodic NPC spawning gated on the safezone mask
;----------------------------------------------------------------
; monsters spawn in dark tiles, heroes in lit tiles.  both share
; a frame counter so the world ticks them in alternation.  each
; type has its own cap and the loop just skips a side that's
; already at cap
;
; rules per attempt:
;	- tile must be walkable (speed 100)
;	- tile must be at least SPAWN_NO_SPAWN_RADIUS from player
;	- monsters: tile must be dark	(safezone_at == 0)
;	- heroes:   tile must be 		(safezone_at != 0)
;
; timing: SPAWN_TICK_PERIOD frames between attempts.  each
; period rolls one side on ticks: evens try monsters, odds try heroes

%ifndef SPAWN_INC
%define SPAWN_INC

%define MONSTER_CAP				64
%define HERO_CAP				8
%define SPAWN_TICK_PERIOD		40;120
%define SPAWN_RETRIES			16	; per attempt
%define SPAWN_NO_SPAWN_RADIUS	6	; tiles from player

; sprite base slots (must match what setup_world_entities used)
%define HERO_SPRITE_BASE		4
%define MONSTER_SPRITE_BASE		8

section .data
	log_msg_monster_spawn	db "a monster emerged from the dark!", 0
	log_msg_hero_spawn		db "a hero arrived!", 0

section .bss
	alignb 4
	spawn_tick_counter		resd 1	; counts up to SPAWN_TICK_PERIOD
	spawn_alternator		resd 1	; 0 = monsters, 1 = heroes

section .text

;================================================================
; spawn_reset: zero counters (call from world regen)
;================================================================
spawn_reset:
	mov dword [spawn_tick_counter], 0
	mov dword [spawn_alternator], 0
	ret

;================================================================
; count_alive_of_type: walk entity table, count alive of given type
;----------------------------------------------------------------
; in:  edi = ENT_TYPE_*
; out: eax = count
;================================================================
count_alive_of_type:
	push rbx
	push r12
	push r13
	; 3 pushes (24) = aligned for inner calls
	mov r13d, edi				; target type
	xor r12d, r12d				; count
	xor ebx, ebx				; idx
.loop:
	mov ecx, [entity_count]
	cmp ebx, ecx
	jge .done
	mov edi, ebx
	call entity_ptr				; rax = ent ptr
	movzx edx, byte [rax + ENT_FLAGS_OFFSET]
	test edx, ENT_FLAG_ALIVE
	jz .next
	movzx edx, byte [rax + ENT_TYPE_OFFSET]
	cmp edx, r13d
	jne .next
	inc r12d
.next:
	inc ebx
	jmp .loop
.done:
	mov eax, r12d
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; try_spawn_in_zone: find a valid tile and spawn an entity there
;----------------------------------------------------------------
; common logic for both monster and hero spawning.  the want_lit
; flag inverts the safezone test
;
; in:	edi = ENT_TYPE_*, esi = sprite base slot, edx = want_lit
;		(0 = need dark tile, 1 = need lit tile)
; out:	eax = entity idx on success, -1 on fail
;----------------------------------------------------------------
; locals after prologue (3 pushes + sub 16 = aligned):
;	[rsp+0]  retries left
;	[rsp+4]  ENT_TYPE_ arg saved
;	[rsp+8]  sprite slot saved
;	[rsp+12] want_lit saved
;================================================================
try_spawn_in_zone:
	push rbx
	push r12
	push r13
	sub rsp, 16

	mov [rsp + 4], edi			; type
	mov [rsp + 8], esi			; slot
	mov [rsp + 12], edx			; want_lit
	mov dword [rsp + 0], SPAWN_RETRIES

.retry:
	mov eax, [rsp + 0]
	test eax, eax
	jle .fail
	dec dword [rsp + 0]

	; random tile
	mov edi, MAP_WIDTH
	call rng_range
	mov ebx, eax				; tx
	mov edi, MAP_HEIGHT
	call rng_range
	mov r12d, eax				; ty

	; lit / dark gate
	mov edi, ebx
	mov esi, r12d
	call safezone_at
	; eax = 0 (dark) or 1 (lit).  XOR with want_lit gives "wrong":
	;	want_lit=0, lit=0 -> 0 (ok)
	;	want_lit=0, lit=1 -> 1 (wrong - we want dark)
	;	want_lit=1, lit=0 -> 1 (wrong - we want lit)
	;	want_lit=1, lit=1 -> 0 (ok)
	xor eax, [rsp + 12]
	test eax, eax
	jnz .retry			; mismatch

	; walkable?
	mov edi, ebx
	imul edi, TILE_SIZE
	add edi, TILE_SIZE / 2
	mov esi, r12d 
	imul esi, TILE_SIZE
	add esi, TILE_SIZE / 2
	call tile_speed_at_pixel
	cmp eax, 100
	jne .retry

	; min distance from player (chebyshev)
	mov eax, [player_x]
	mov ecx, TILE_SIZE
	cdq
	idiv ecx
	mov r13d, eax		; player_tx (still need it after the y div)
	sub r13d, ebx
	test r13d, r13d
	jns .dx_pos
	neg r13d
.dx_pos:
	mov eax, [player_y]
	cdq
	idiv ecx
	sub eax, r12d
	test eax, eax
	jns .dy_pos
	neg eax
.dy_pos:
	; chebyshev = max(|dx|, |dy|).  need >= SPAWN_NO_SPAWN_RADIUS
	; equivalent: BOTH must be < RADIUS to reject.  ie reject if
	; max(|dx|, |dy|) < RADIUS, accept otherwise
	cmp r13d, SPAWN_NO_SPAWN_RADIUS
	jge .far_enough
	cmp eax, SPAWN_NO_SPAWN_RADIUS
	jl .retry					; both small -> too close
.far_enough:

	; tile is good - spawn!
	mov edi, [rsp + 4]			; type
	mov esi, ebx
	imul esi, TILE_SIZE
	add esi, TILE_SIZE / 2
	mov edx, r12d
	imul edx, TILE_SIZE
	add edx, TILE_SIZE / 2
	mov ecx, [rsp + 8]			; sprite slot
	call entity_spawn
	cmp eax, 0
	jl .fail

	; randomise stats for this new npc
	mov edi, eax
	call entity_roll_random_stats

	add rsp, 16
	pop r13
	pop r12
	pop rbx
	ret

.fail:
	mov eax, -1
	add rsp, 16
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; try_spawn_monster: one attempt at finding a dark spawn tile
;================================================================
try_spawn_monster:
	mov edi, ENT_TYPE_MONSTER
	mov esi, MONSTER_SPRITE_BASE
	xor edx, edx				; want_lit = 0 (need dark)
	call try_spawn_in_zone
	cmp eax, 0
	jl .out
	lea rdi, [log_msg_monster_spawn]
	call debug_log
.out:
	ret

;================================================================
; try_spawn_hero: one attempt at finding a lit spawn tile
;================================================================
try_spawn_hero:
	mov edi, ENT_TYPE_HERO
	mov esi, HERO_SPRITE_BASE
	mov edx, 1					; want_lit = 1
	call try_spawn_in_zone
	cmp eax, 0
	jl .out
	lea rdi, [log_msg_hero_spawn]
	call debug_log
.out:
	ret

;================================================================
; spawn_tick: called each frame from the main loop
;----------------------------------------------------------------
; every SPAWN_TICK_PERIOD frames, alternates between trying to
; spawn a monster (in the dark) and a hero (in the light) so both
; populations grow over time. no spawn happens if its cap reached
;================================================================
spawn_tick:
	inc dword [spawn_tick_counter]
	cmp dword [spawn_tick_counter], SPAWN_TICK_PERIOD
	jl .out
	mov dword [spawn_tick_counter], 0

	; alternate
	mov eax, [spawn_alternator]
	xor dword [spawn_alternator], 1
	test eax, eax
	jnz .try_hero

	; monsters
	mov edi, ENT_TYPE_MONSTER
	call count_alive_of_type
	cmp eax, MONSTER_CAP
	jge .out
	call try_spawn_monster
	jmp .out

.try_hero:
	mov edi, ENT_TYPE_HERO
	call count_alive_of_type
	cmp eax, HERO_CAP
	jge .out
	call try_spawn_hero

.out:
	ret

%endif
