; astar.inc.asm - on-demand A* pathfinder + per-entity path storage
;----------------------------------------------------------------
; standard A* on the tile grid with manhattan heuristic,
; called on-demand only when an npc enters ENGAGE or its current
; path goes stale
;
; reusing pathing_tile_walkable as the walk predicate so the
; rules (closed doors are walkable, chairs are walkable, etc)
; stay consistent with the flow map
;
; storage:
;	astar_g				u16 per tile, best known dist from start
;						0xFFFF = unvisited
;	astar_came_from		u8 per tile, AI_DIR_* "step back toward
;						parent" (same convention as pathing_dir)
;	astar_open			u32 per slot, min-heap of (f<<16 | idx)
;						2x map size to comfortably hold dupes
;	astar_open_count	current heap size
;
; entity-side path storage (side tables, like entity_last_tx/ty):
;	entity_path_tx/ty	PATH_MAX_LEN waypoints per entity
;	entity_path_len		how many waypoints we computed
;	entity_path_idx		next waypoint index to walk toward.  we
;						write the path in goal->start order and
;						start with idx = len-1, decrementing each
;						time we reach a waypoint
;	entity_path_epoch	value of pathing_epoch when planned.
;						if the world changed since, the path is
;						stale and we replan
;----------------------------------------------------------------
%ifndef ASTAR_INC
%define ASTAR_INC

; -- max waypoints stored per npc --
; aggro radius is 8 tiles by sightline, but a wiggly path around
; long wall segments can easily go 50-100 steps it seems
%define PATH_MAX_LEN			96	

%define ASTAR_OPEN_CAP			(MAP_WIDTH * MAP_HEIGHT * 2)
%define ASTAR_MAX_EXPANSIONS	8000; safety cap, lots of headroom

; how close (px) we have to be to a waypoint tile centre before
; considered reached
; half a tile enough that fractional-speed npcs don't orbit it but
; tight enough that diagonal shortcuts don't accumulate
%define PATH_WAYPOINT_REACH_PX	(TILE_SIZE / 2)

section .bss
	; A* scratch.shared across all calls-only one in flight at a time
	alignb 2
	astar_g				resw MAP_WIDTH * MAP_HEIGHT
	alignb 1
	astar_came_from		resb MAP_WIDTH * MAP_HEIGHT
	alignb 4
	astar_open			resd ASTAR_OPEN_CAP
	astar_open_count	resd 1

	; per-entity path side tables
	alignb 1
	entity_path_tx		resb ENT_MAX * PATH_MAX_LEN
	entity_path_ty		resb ENT_MAX * PATH_MAX_LEN
	entity_path_len		resb ENT_MAX
	entity_path_idx		resb ENT_MAX
	entity_path_epoch	resb ENT_MAX

section .text

;================================================================
; astar_heap_push: push (f, idx) onto the min-heap
;----------------------------------------------------------------
; in:	edi = f, esi = tile idx (both 16-bit-fitting)
; out:	eax = 1 if pushed, 0 if heap overflowed
;================================================================
astar_heap_push:
	mov eax, [astar_open_count]
	cmp eax, ASTAR_OPEN_CAP
	jge .full

	; pack key = (f << 16) | idx
	shl edi, 16
	or edi, esi					; edi = packed key

	mov ecx, eax				; ecx = i (current slot)
	lea r8, [astar_open]
	mov [r8 + rcx*4], edi
	inc dword [astar_open_count]

	;while i>0 and heap[(i-1)/2] > heap[i], swap up
.siftup:
	test ecx, ecx
	jz .done
	mov edx, ecx
	dec edx
	shr edx, 1					; edx = parent slot
	mov r9d, [r8 + rdx*4]
	cmp r9d, edi
	jbe .done					; parent <= ours
	mov [r8 + rcx*4], r9d
	mov [r8 + rdx*4], edi
	mov ecx, edx
	jmp .siftup
.done:
	mov eax, 1
	ret
.full:
	xor eax, eax
	ret
 
;================================================================
; astar_heap_pop: pop the min element from the heap
;----------------------------------------------------------------
; in:	(none)
; out:	eax = 1 if popped, 0 if empty.  edi = popped tile idx
;================================================================
astar_heap_pop:
	mov eax, [astar_open_count]
	test eax, eax
	jz .empty

	lea r8, [astar_open]
	mov edx, [r8]				; edx = packed top
	movzx edi, dx				; edi = idx

	dec eax
	mov [astar_open_count], eax
	test eax, eax
	jz .return_ok
	mov ecx, [r8 + rax*4]		; last element key
	mov [r8], ecx				; root <- last

	; sift-down
	xor edx, edx				; edx = i (=0)
	mov r9d, [astar_open_count]
.siftdown:
	mov esi, edx
	shl esi, 1
	inc esi						; esi = left child
	cmp esi, r9d
	jge .return_ok				; no children,done

	mov r10d, esi				; r10 = chosen child
	mov r11d, esi
	inc r11d					; right child
	cmp r11d, r9d 
	jge .have_child				; no right child, left is chosen
	mov eax, [r8 + r11*4]
	mov ecx, [r8 + rsi*4]
	cmp eax, ecx
	jae .have_child
	mov r10d, r11d
.have_child:
	mov eax, [r8 + rdx*4]
	mov ecx, [r8 + r10*4]
	cmp eax, ecx
	jbe .return_ok;heap ok

	mov [r8 + rdx*4], ecx
	mov [r8 + r10*4], eax
	mov edx, r10d
	jmp .siftdown

.return_ok:
	mov eax, 1
	ret
.empty:
	xor eax, eax
	ret

;================================================================
; astar_find_path: run A* from (start_tx, start_ty) to
; (goal_tx, goal_ty).  on success writes the path into the given
; entity's path side table, in goal->start order, and sets
; entity_path_len/entity_path_idx accordingly
;----------------------------------------------------------------
; "goal->start order" means slot 0 holds the goal tile and slot
; len-1 holds the tile right next to start.  the entity walks
; from entity_path_idx = len-1 down to 0, picking the NEXT tile
; to head toward at each step.  this avoids a reverse-copy at
; the end of path reconstruction
;
; manhattan heuristic.  4-connected grid
;----------------------------------------------------------------
; in:	edi	= self entity idx (path target)
;		esi	= start_tx, edx = start_ty 
;		ecx = goal_tx,  r8d = goal_ty
; out:	eax = 1 if path found, 0 otherwise
;----------------------------------------------------------------
; locals after prologue (ret 8 + 5 push 40 + sub 32 = 80, aligned):
;	[rsp+0]  self idx
;	[rsp+4]  start_idx
;	[rsp+8]  goal_idx
;	[rsp+12] expansion counter
;	[rsp+16] ctx (current expansion x)
;	[rsp+20] cty (current expansion y)
;	[rsp+24..31] pad for 16-byte alignment
;
; callee-saved regs used through the loop:
;	r12 = goal_tx	r13 = goal_ty
;	r14 = path target entity idx (== [rsp+0], for fast slot calcs)
;================================================================
astar_find_path:
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 32 ; ret (8) + 5 pushes (40) + 32 = 80, 16-aligned

	mov [rsp + 0], edi			; self idx
	mov r12d, ecx				; r12 = goal_tx
	mov r13d, r8d				; r13 = goal_ty
	mov r14d, edi				; r14 = self idx (for slot maths)

	; clear path up-front - any bail leaves entity with no path
	lea rcx, [entity_path_len]
	mov byte [rcx + r14], 0

	; --- bounds: start + goal in range ---
	test esi, esi
	js .fail
	cmp esi, MAP_WIDTH
	jge .fail
	test edx, edx
	js .fail
	cmp edx, MAP_HEIGHT
	jge .fail
	test r12d, r12d
	js .fail
	cmp r12d, MAP_WIDTH
	jge .fail
	test r13d, r13d
	js .fail
	cmp r13d, MAP_HEIGHT
	jge .fail

	; start_idx = sty*W + stx, goal_idx = gty*W + gtx
	mov eax, edx
	imul eax, MAP_WIDTH
	add eax, esi
	mov [rsp + 4], eax			; start_idx
	mov eax, r13d
	imul eax, MAP_WIDTH
	add eax, r12d
	mov [rsp + 8], eax			; goal_idx

	; trivial already-at-goal: leave len=0, fail (no walking needed)
	mov eax, [rsp + 4]
	cmp eax, [rsp + 8]
	je .fail

	; goal walkable?  (start is implicitly walkable- we're on it!)
	mov edi, r12d
	mov esi, r13d
	call pathing_tile_walkable
	test eax, eax
	jz .fail

	; --- clear g to 0xFFFF, came_from to IDLE, heap empty ---
	lea rdi, [astar_g]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	mov ax, 0xFFFF
	rep stosw

	lea rdi, [astar_came_from]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax
	rep stosb

	mov dword [astar_open_count], 0
	mov dword [rsp + 12], 0

	; --- seed: g[start]=0, push (h, start) ---
	mov ebx, [rsp + 4]
	lea rcx, [astar_g]
	mov word [rcx + rbx*2], 0

	;  start tx,ty from idx
	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = sty, edx = stx

	; h = |stx - goal_tx| + |sty - goal_ty|
	mov edi, r12d
	sub edi, edx
	test edi, edi
	jns .h0_dxp
	neg edi
.h0_dxp:
	mov esi, r13d
	sub esi, eax
	test esi, esi
	jns .h0_dyp
	neg esi
.h0_dyp:
	add edi, esi				; edi = h
	mov esi, ebx				; esi = start idx
	call astar_heap_push 

	; --- main loop ---
.loop:
	call astar_heap_pop
	test eax, eax
	jz .fail					; open empty - unreachable

	mov ebx, edi				; ebx = popped idx

	cmp ebx, [rsp + 8]
	je .reached

	; expansion cap
	inc dword [rsp + 12]
	mov eax, [rsp + 12]
	cmp eax, ASTAR_MAX_EXPANSIONS
	jge .fail

	; g_cur, ctx, cty
	lea rcx, [astar_g]
	movzx r15d, word [rcx + rbx*2]	; r15 = g_cur

	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = cty, edx = ctx

	; we need cty around for neighbours - stash both
	mov [rsp + 16], edx			; ctx
	mov [rsp + 20], eax			; cty

	; tentative_g = g_cur + 1, clamped at 0xFFFE
	inc r15d
	cmp r15d, 0xFFFE
	jle .ng_ok
	mov r15d, 0xFFFE
.ng_ok:

	; --- relax 4 neighbours.  back-pointer dir at the neighbour
	; is the direction FROM the neighbour TO the parent (us),
	; same convention as pathing_dir ---

	; nbr = (ctx, cty-1).  step back = DOWN
	mov edi, [rsp + 16]
	mov esi, [rsp + 20]
	dec esi
	mov edx, AI_DIR_DOWN
	mov ecx, r15d
	mov r8d, r12d
	mov r9d, r13d
	call astar_relax
	; nbr = (ctx, cty+1).  step back = UP
	mov edi, [rsp + 16]
	mov esi, [rsp + 20]
	inc esi
	mov edx, AI_DIR_UP
	mov ecx, r15d
	mov r8d, r12d
	mov r9d, r13d
	call astar_relax
	; nbr = (ctx-1, cty).  step back = RIGHT
	mov edi, [rsp + 16]
	dec edi
	mov esi, [rsp + 20]
	mov edx, AI_DIR_RIGHT
	mov ecx, r15d
	mov r8d, r12d
	mov r9d, r13d
	call astar_relax
	; nbr = (ctx+1,cty).  step back = LEFT
	mov edi, [rsp + 16]
	inc edi
	mov esi, [rsp + 20]
	mov edx, AI_DIR_LEFT
	mov ecx, r15d
	mov r8d, r12d
	mov r9d, r13d
	call astar_relax

	jmp .loop

.reached:
	; reconstruct: walk came_from from goal back to start
	;
	; write each tile(tx,ty) to entity path arrays in goal->start
	; order.  the entity starts at idx = len-1 (= start side)
	; and decrements toward 0 (= goal side)
	xor r15d, r15d				; r15 = waypoints written

	; r12/r13 still hold goal_tx/ty but we'll be moving through the
	; chain so use rbx and a fresh tx/ty pair
	mov ebx, [rsp + 8]			; ebx = current idx (goal)

.recon:
	cmp ebx, [rsp + 4]			; reached start idx?
	je .recon_done

	cmp r15d, PATH_MAX_LEN
	jge .fail					; path too long? treat as no path

	; cur tx, ty
	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = cty, edx = ctx

	; write into slot (r14 * PATH_MAX_LEN + r15)
	mov ecx, r14d
	imul ecx, PATH_MAX_LEN
	add ecx, r15d
	lea r8, [entity_path_tx]
	mov [r8 + rcx], dl
	lea r8, [entity_path_ty]
	mov [r8 + rcx], al

	; step back via came_from[ebx]
	lea r8, [astar_came_from]
	movzx ecx, byte [r8 + rbx]	; ecx = back-dir
	test ecx, ecx
	jz .fail					; chain broken (shouldn't happen)

	; apply step from (ctx,cty) in dir ecx -> (ptx,pty)
	cmp ecx, AI_DIR_UP
	jne .cf_not_up
	dec eax
	jmp .cf_have
.cf_not_up:
	cmp ecx, AI_DIR_DOWN
	jne .cf_not_down
	inc eax
	jmp .cf_have
.cf_not_down:
	cmp ecx, AI_DIR_LEFT
	jne .cf_not_left
	dec edx
	jmp .cf_have
.cf_not_left:
	inc edx						; AI_DIR_RIGHT
.cf_have:
	; ebx = pty * W + ptx
	mov ecx, eax
	imul ecx, MAP_WIDTH
	add ecx, edx
	mov ebx, ecx

	inc r15d
	jmp .recon

.recon_done:
	; commit: path_len = r15, path_idx = r15-1
	test r15d, r15d
	jz .fail					; 0-length, shouldn't happen but ok

	lea rcx, [entity_path_len]
	mov byte [rcx + r14], r15b
	lea rcx, [entity_path_idx]
	dec r15d
	mov byte [rcx + r14], r15b

	movzx eax, byte [pathing_epoch]
	lea rcx, [entity_path_epoch]
	mov byte [rcx + r14], al

	mov eax, 1
	jmp .out

.fail:
	; stamp the epoch even on failure so callers (via
	; entity_path_is_stale) rerequest every frame for some
	; possibly unreacahble target.  the next time the
	; world changes (pathing_recompute bumps the epoch), the path
	; goes stale again and we'll retry
	; ai_decide also re-evals macro state every DECISION_PERIOD 
	; frames so a moving target eventually gets another shot
	movzx eax, byte [pathing_epoch]
	lea rcx, [entity_path_epoch]
	mov byte [rcx + r14], al
	xor eax, eax
.out:
	add rsp, 32
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; astar_relax: visit one neighbour during A* expansion
;----------------------------------------------------------------
; if walkable and tentative_g < g[nbr], update g, came_from, and
; push (f, nbr) on the open heap.  f = g + manhattan(nbr -> goal)
;----------------------------------------------------------------
; in:	edi	= nbr tx, esi = nbr ty
;		edx = AI_DIR_* back-pointer
;		ecx = tentative g (parent g + 1)
;		r8d = goal_tx, r9d = goal_ty
;================================================================
astar_relax:
	; --- bounds ---
	test edi, edi
	js .out
	cmp edi, MAP_WIDTH
	jge .out
	test esi, esi
	js .out
	cmp esi, MAP_HEIGHT
	jge .out

	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 pushes (40) + ret (8) = 48 - aligned

	mov r12d, edx			; r12 = back-dir
	mov r13d, ecx			; r13 = tentative g
	mov r14d, edi			; r14 = nbr tx
	mov r15d, esi			; r15 = nbr ty
	; r8d/r9d still hold goal_tx/ty but pathing_tile_walkable may
	; clobber them..hold goal copies in callee-saved over the call
	; via a stack stash.  layout after the two pushes below:
	;	[rsp+0] = goal_ty (r9, pushed last)
	;	[rsp+8] = goal_tx (r8)
	push r8
	push r9					; align preserved (2 pushes -> 16)

	; nbr idx
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, r14d
	mov ebx, eax				; ebx = nbr idx

	; existing g - skip if not better
	lea rcx, [astar_g]
	movzx eax, word [rcx + rbx*2]
	cmp r13d, eax
	jge .pop_out

	; walkable?
	mov edi, r14d
	mov esi, r15d
	call pathing_tile_walkable
	test eax, eax
	jz .pop_out

	; relax: write g, came_from
	lea rcx, [astar_g]
	mov [rcx + rbx*2], r13w
	lea rcx, [astar_came_from]
	mov [rcx + rbx], r12b

	; f = g + manhattan(nbr -> goal).  pull the stashed goal coords
	; back off the stack (see layout note above)
	mov edi, [rsp + 8]		; goal_tx
	sub edi, r14d
	test edi, edi
	jns .hdxp
	neg edi
.hdxp:
	mov esi, [rsp + 0]		; goal_ty
	sub esi, r15d
	test esi, esi
	jns .hdyp
	neg esi
.hdyp:
	add edi, esi			; edi = h
	add edi, r13d			; f = g + h

	cmp edi, 0xFFFF
	jle .f_ok
	mov edi, 0xFFFF
.f_ok:

	mov esi, ebx
	call astar_heap_push
	; if heap full we already set g/came_from

.pop_out:
	pop r9
	pop r8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out:
	ret

;================================================================
; entity_path_clear: wipe the path for one entity
;----------------------------------------------------------------
; in:	edi = entity idx
;================================================================
entity_path_clear:
	lea rcx, [entity_path_len]
	mov byte [rcx + rdi], 0
	lea rcx, [entity_path_epoch]
	mov byte [rcx + rdi], 0
	ret

;================================================================
; entity_path_clear_all: wipe all entity paths
; called from entity_clear_all + on world regen
;================================================================
entity_path_clear_all:
	lea rdi, [entity_path_len]
	mov ecx, ENT_MAX
	xor eax, eax
	rep stosb
	ret

;================================================================
; entity_path_current_waypoint: read this entity's next waypoint
;----------------------------------------------------------------
; in:	edi = entity idx
; out:	eax = 1 if entity has a live waypoint, 0 otherwise
;		ecx = waypoint tx (only valid when eax=1)
;		edx = waypoint ty
;================================================================
entity_path_current_waypoint:
	lea rax, [entity_path_len]
	movzx ecx, byte [rax + rdi]
	test ecx, ecx
	jz .none

	lea rax, [entity_path_idx]
	movzx edx, byte [rax + rdi]
	cmp edx, ecx
	jge .none ; idx walked past end (shouldn't happen)

	; slot = entity*PATH_MAX_LEN + idx
	mov ecx, edi
	imul ecx, PATH_MAX_LEN
	add ecx, edx

	lea rax, [entity_path_tx]
	movzx r8d, byte [rax + rcx]
	lea rax, [entity_path_ty]
	movzx edx, byte [rax + rcx]
	mov ecx, r8d
	mov eax, 1
	ret
.none:
	xor eax, eax
	ret

;================================================================
; entity_path_advance: bump the waypoint cursor
; called after the entity reaches its current waypoint
;----------------------------------------------------------------
; in:	edi = entity idx
; out:	eax = 1 if more waypoints remain, 0 if path exhausted
;================================================================
entity_path_advance:
	lea rax, [entity_path_idx]
	movzx ecx, byte [rax + rdi]
	test ecx, ecx
	jz .exhausted ; already at slot 0 - that was the last
	dec ecx
	mov byte [rax + rdi], cl
	mov eax, 1
	ret
.exhausted:
	; mark path empty AND zero the epoch.  this drives is_stale to
	; "stale" so the next ENGAGE micro tick replans for an enemy
	; that's still alive but moved off the planned goal tile
	lea rax, [entity_path_len]
	mov byte [rax + rdi], 0
	lea rax, [entity_path_epoch]
	mov byte [rax + rdi], 0
	xor eax, eax
	ret

;================================================================
; entity_path_is_stale: 1 if path needs replanning, 0 otherwise
;----------------------------------------------------------------
; epoch differs from pathing_epoch (world changed), OR there's
; never been a plan attempt for this entity (epoch still 0 from
; clear).  if len==0 but epoch matches, that means a recent plan
; tried and failed - leave it alone until the world changes or the
; entity wanders elsewhere to stop it thrashing retries on an
; unreachable traget
;----------------------------------------------------------------
; in:	edi = entity idx
; out:	eax = 1 if stale, 0 if fresh
;================================================================
entity_path_is_stale:
	lea rax, [entity_path_epoch]
	movzx ecx, byte [rax + rdi]
	movzx edx, byte [pathing_epoch]
	cmp ecx, edx
	jne .stale
	xor eax, eax
	ret
.stale:
	mov eax, 1
	ret
; ----------- DEBUG/UTILITIES ------------

;================================================================
; astar_draw_paths_debug: render the arrows
;----------------------------------------------------------------
; locals after prologue (5 push 40 + sub 16 + ret 8 = 64, aligned):
;	[rsp+0]	entity idx walker
;	[rsp+4]	path len
;	[rsp+8] entity colour (ARGB)
;	[rsp+12] pad
;================================================================
astar_draw_paths_debug:
	cmp byte [pathing_debug_view], 0
	je .out_early

	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 16
	; locals after prologue: ret 8 + 5 push 40 + sub 16 = 64, 16-aligned
	;	[rsp+0]	entity idx walker (loop counter)
	;	[rsp+4]	path len (cached)
	;	[rsp+8]	colour (ARGB)
	;	[rsp+12] pad
	mov dword [rsp + 0], 0
.ent_loop:
	mov eax, [rsp + 0]
	cmp eax, [entity_count]
	jge .done

	mov edi, eax
	call entity_ptr
	mov r12, rax

	movzx ecx, byte [r12 + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .ent_next

	mov ebx, [rsp + 0]			; ebx = entity idx
	lea rcx, [entity_path_len]
	movzx eax, byte [rcx + rbx]
	test eax, eax
	jz .ent_next
	mov [rsp + 4], eax

	; colour by type
	movzx ecx, byte [r12 + ENT_TYPE_OFFSET]
	cmp ecx, ENT_TYPE_HERO
	jne .col_chk_mon
	mov dword [rsp + 8], 0xC040FFFF	; hero colour
	jmp .col_done
.col_chk_mon:
	cmp ecx, ENT_TYPE_MONSTER
	jne .col_other
	mov dword [rsp + 8], 0xC0FF4040	; monster olour
	jmp .col_done
.col_other:
	mov dword [rsp + 8], 0xC0FFFFFF
.col_done:

	; pass 1: line segments between consecutive waypoints.
	xor r13d, r13d		; r13 = wp slot index
.seg_loop:
	mov eax, [rsp + 4]
	dec eax
	cmp r13d, eax
	jge .seg_done		; no "next" past the last slot

	; current waypoint (tx, ty) -> r14, r15
	mov ecx, ebx
	imul ecx, PATH_MAX_LEN
	add ecx, r13d
	lea r8, [entity_path_tx]
	movzx r14d, byte [r8 + rcx]
	lea r8, [entity_path_ty]
	movzx r15d, byte [r8 + rcx]

	; next waypoint (ntx, nty)
	mov ecx, ebx
	imul ecx, PATH_MAX_LEN
	add ecx, r13d
	inc ecx
	lea r8, [entity_path_tx]
	movzx edi, byte [r8 + rcx]	; edi = ntx
	lea r8, [entity_path_ty]
	movzx esi, byte [r8 + rcx]	; esi = nty

	; min_tx, min_ty (whichever pair is on the lower side)
	mov edx, r14d
	cmp edx, edi
	jle .mx_ok
	mov edx, edi
.mx_ok:
	mov ecx, r15d
	cmp ecx, esi
	jle .my_ok
	mov ecx, esi
.my_ok:
	; edx = min_tx, ecx = min_ty

	; |dx|, |dy| - exactly one is 1, the other is 0
	mov r8d, r14d
	sub r8d, edi
	test r8d, r8d
	jns .ddx_p
	neg r8d
.ddx_p:
	mov r9d, r15d
	sub r9d, esi
	test r9d, r9d
	jns .ddy_p
	neg r9d
.ddy_p:
	; w = |dx| * TILE_SIZE + 1, h = |dy| * TILE_SIZE + 1
	imul r8d, TILE_SIZE
	inc r8d	; w
	imul r9d, TILE_SIZE
	inc r9d	; h

	; sx = min_tx * TILE_SIZE + TILE_SIZE/2 - camera_x
	imul edx, TILE_SIZE
	add edx, TILE_SIZE / 2
	sub edx, [camera_x]
	; sy = min_ty * TILE_SIZE + TILE_SIZE/2 - camera_y
	imul ecx, TILE_SIZE
	add ecx, TILE_SIZE / 2
	sub ecx, [camera_y]

	; fill_rect(edi=x, esi=y, edx=w, ecx=h, r8d=col)
	mov edi, edx
	mov esi, ecx
	mov edx, r8d
	mov ecx, r9d
	mov r8d, [rsp + 8]
	call fill_rect

	inc r13d
	jmp .seg_loop
.seg_done:

	; --- pass 2: dot per waypoint, current waypoint a bit larger ---
	xor r13d, r13d
.dot_loop:
	mov eax, [rsp + 4]
	cmp r13d, eax
	jge .dot_done

	mov ecx, ebx
	imul ecx, PATH_MAX_LEN
	add ecx, r13d
	lea r8, [entity_path_tx]
	movzx r14d, byte [r8 + rcx]
	lea r8, [entity_path_ty]
	movzx r15d, byte [r8 + rcx]

	mov eax, r14d
	imul eax, TILE_SIZE
	add eax, TILE_SIZE / 2
	sub eax, [camera_x]
	mov edi, eax
	mov eax, r15d
	imul eax, TILE_SIZE
	add eax, TILE_SIZE / 2
	sub eax, [camera_y]
	mov esi, eax

	; current waypoint? bigger dot
	lea rcx, [entity_path_idx]
	movzx eax, byte [rcx + rbx]
	cmp r13d, eax
	jne .small_dot
	sub edi, 1
	sub esi, 1
	mov edx, 3
	mov ecx, 3
	mov r8d, [rsp + 8]
	call fill_rect
	jmp .dot_next
.small_dot:
	mov edx, 2
	mov ecx, 2
	mov r8d, [rsp + 8]
	call fill_rect

.dot_next:
	inc r13d
	jmp .dot_loop
.dot_done:

	; entity marker - 3x3 in path colour on top of the npc
	mov eax, [r12 + ENT_X_OFFSET]
	sub eax, [camera_x]
	sub eax, 1
	mov edi, eax
	mov eax, [r12 + ENT_Y_OFFSET]
	sub eax, [camera_y]
	sub eax, 1
	mov esi, eax
	mov edx, 3
	mov ecx, 3
	mov r8d, [rsp + 8]
	call fill_rect

.ent_next:
	inc dword [rsp + 0]
	jmp .ent_loop

.done:
	add rsp, 16
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out_early:
	ret

%endif
