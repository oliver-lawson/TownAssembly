; ai.inc.asm - utility-AI macro/micro tier for hero & monster NPCs
;----------------------------------------------------------------
; each NPC has:
; 3 randomised stat bytes, set at spawn:
;	hp_max
;	bravery	- 0..255, how willing to engage instead of flee
;	speed	- movement % vs base (50 = half speed, 150 = 1.5x)
;
; & AI state:
;	ai_mode			- IDLE/WANDER/ENGAGING/FIGHTING/FLEEING
;	ai_target		- entity index of enemy, AI_TARGET_NONE = none
;	decision_ticks 	- per-frame countdown to next macro decision
;	attack_ticks	- per-frame countdown to next melee attack
; ---
; macro/micro decision split:
; the macro tier picks ai_mode state every DECISION_PERIOD frames by
; scoring each candidate goal
; the micro tier (called from entity_tick_all) drives the per-frame
; behaviour for current mode
;----------------------------------------------------------------
%ifndef AI_INC
%define AI_INC

%define DECISION_PERIOD			30	; frames between macro decisions
%define AGGRO_RADIUS_TILES		8	; sight range
%define ENGAGE_DAMAGE			2	; damage per melee attack
%define ATTACK_PERIOD			30	; frames between attacks
%define FIGHT_RANGE_PX			18	; AABB-ish range for "adjacent"
%define ENGAGE_STEP				1	; px per AI tick when chasing
%define FLEE_STEP				1	; px per AI tick when fleeing

; pose-render timers (read by draw_entities):
%define HIT_FLASH_FRAMES		8
%define ATTACK_POSE_FRAMES		10 ; both frames together

; -- stuck-detection (ai_move_in_dir): --
; how many consecutive frames of being still on the same tile
%define STUCK_BREAKOUT_FRAMES	120
; how long to stay in WANDER after breakout
%define STUCK_RECOVER_FRAMES	120

section .text

;================================================================
; ai_is_enemy: do entity types A and B fight each other?
;----------------------------------------------------------------
; in:	dil = type a, sil = type b
; out:	eax = 1 if enemies, 0 otherwise
;================================================================
ai_is_enemy:
	; hero <-> monster
	cmp dil, ENT_TYPE_HERO
	jne .not_hero_first
	cmp sil, ENT_TYPE_MONSTER
	je .yes
	jmp .no
.not_hero_first:
	cmp dil, ENT_TYPE_MONSTER
	jne .check_player
	cmp sil, ENT_TYPE_HERO
	je .yes
	cmp sil, ENT_TYPE_PLAYER
	je .yes
	jmp .no
.check_player:
	xor eax, eax
	ret
.yes:
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; ai_find_nearest_enemy: scan the entity table for the closest
; alive enemy of the given type, within AGGRO_RADIUS_TILES
;----------------------------------------------------------------
; using chebyshev distance in pixels (px/TILE_SIZE for tile range)
; in:	edi = self entity index
; out:	eax = enemy entity idx, or -1 if none in range
;----------------------------------------------------------------
; locals on stack (3 pushes + sub 8 = 32, aligned):
;	[rsp+0]  self idx
;	[rsp+4]  self type
;	[rsp+8]  best distance so far
;	[rsp+12] best idx
;================================================================
ai_find_nearest_enemy:
	push rbx
	push r12
	push r13
	sub rsp,16

	mov [rsp + 0], edi			; self idx
	call entity_ptr
	movzx eax, byte [rax + ENT_TYPE_OFFSET]
	mov [rsp + 4], eax			; self type
	; self x,y stashed in callee-saved regs so we don't have to
	; reload each iter
	mov edi, [rsp + 0]
	call entity_ptr
	mov r12d, [rax + ENT_X_OFFSET]
	mov r13d, [rax + ENT_Y_OFFSET]

	mov dword [rsp + 8], 0x7FFFFFFF; init best distance @ infinity
	mov dword [rsp + 12], -1

	xor ebx, ebx				; idx walker
.loop:
	mov ecx, [entity_count]
	cmp ebx, ecx
	jge .done

	; skip self
	cmp ebx, [rsp + 0]
	je .next

	mov edi, ebx
	call entity_ptr

	; alive?
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .next

	; enemy of self?
	movzx edi, byte [rsp + 4]
	movzx esi, byte [rax + ENT_TYPE_OFFSET]
	push rax					; preserve entity ptr across call
	push rcx					; align
	call ai_is_enemy
	pop rcx
	pop rdx						; entity ptr restored to rdx
	test eax, eax
	jz .next

	; chebyshev distance = max(|dx|, |dy|), in pixels
	mov eax, [rdx + ENT_X_OFFSET]
	sub eax, r12d
	test eax, eax
	jns .dx_pos
	neg eax
.dx_pos:
	mov ecx, [rdx + ENT_Y_OFFSET]
	sub ecx, r13d
	test ecx, ecx
	jns .dy_pos
	neg ecx
.dy_pos:
	; cheb = max(eax, ecx)
	cmp eax, ecx
	jge .have_cheb
	mov eax, ecx
.have_cheb:
	; reject if beyond AGGRO_RADIUS in tiles (convert pixels)
	cmp eax, AGGRO_RADIUS_TILES * TILE_SIZE
	jg .next

	;new best?
	cmp eax, [rsp + 8]
	jge .next
	mov [rsp + 8], eax
	mov [rsp + 12], ebx

.next:
	inc ebx
	jmp .loop
.done:
	mov eax, [rsp + 12]
	add rsp, 16
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_decide: pick the AI mode based on stats + world state
;----------------------------------------------------------------
; called every DECISION_PERIOD frames per NPC
; scores 3 candidate modes (WANDER/ENGAGING/FLEEING), picks the max
;
; scoring (all yield small int values):
;	WANDER	= 30 baseline + 1d10 random jitter
;	ENGAGE	= (bravery + hp_pct) - 0  if no enemy in range
;			  else (bravery + hp_pct) - dist_tiles*5
;	FLEE	= enemy_in_range
;			  ? (1.5*missing_hp_pct + (255-bravery)/2) +close_bonus
;			  : 0
;
; missing_hp_pct = (1 - hp/hp_max) * 100
; hp_pct = hp/hp_max * 100
;
; assigns ai_mode and ai_target.  if entering fighting range
; while engaging, ai_decide instead picks FIGHTING - micro tier
; will keep us there so long as the target's alive + close
;----------------------------------------------------------------
; in:	edi = entity index
;----------------------------------------------------------------
; locals on stack after prologue (4 pushes + sub 32 = 64 aligned):
;	[rsp+0]  self idx
;	[rsp+4]  hp_pct (0..100)
;	[rsp+8]  bravery
;	[rsp+12] enemy idx (-1 if none)
;	[rsp+16] enemy dist in pixels
;	[rsp+20] score wander
;	[rsp+24] score engage
;	[rsp+28] score flee
;================================================================
ai_decide:
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 40		; 4 pushes (32) + 40 = 72 -> aligned

	mov [rsp + 0], edi

	; self ptr -> r12
	call entity_ptr
	mov r12, rax

	; hp_pct = hp * 100 / hp_max (saturated to >=1 hp_max)
	movzx eax, byte [r12 + ENT_HP_OFFSET]
	imul eax, 100
	movzx ecx, byte [r12 + ENT_HP_MAX_OFFSET]
	test ecx, ecx
	jnz .hpmax_ok
	mov ecx, 1
.hpmax_ok:
	xor edx, edx
	div ecx
	mov [rsp + 4], eax			; hp_pct
	mov ebx, eax				; ebx = hp_pct for arithmetic

	movzx eax, byte [r12 + ENT_BRAVERY_OFFSET]
	mov [rsp + 8], eax			; bravery
	mov r13d, eax				; r13 = bravery

	; find nearest enemy
	mov edi, [rsp + 0]
	call ai_find_nearest_enemy
	mov [rsp + 12], eax
	mov r14d, eax				; r14 = enemy idx (-1 = none)

	; compute enemy distance in pixels (only valid if r14 != -1)
	test r14d, r14d
	js .no_enemy
	mov edi, r14d
	call entity_ptr
	mov ecx, [rax + ENT_X_OFFSET]
	sub ecx, [r12 + ENT_X_OFFSET]
	test ecx, ecx
	jns .ed_dx_pos
	neg ecx
.ed_dx_pos:
	mov edx, [rax + ENT_Y_OFFSET]
	sub edx, [r12 + ENT_Y_OFFSET]
	test edx, edx
	jns .ed_dy_pos
	neg edx
.ed_dy_pos:
	cmp ecx, edx
	jge .ed_have
	mov ecx, edx
.ed_have:
	mov [rsp + 16], ecx			; enemy_dist_px
	jmp .compute_scores
.no_enemy:
	mov dword [rsp + 16], 0x7FFFFFFF

.compute_scores:
	; --- WANDER ---
	; 30 + rng(10)
	mov edi, 10
	push rax	; align
	call rng_range
	pop rcx
	add eax, 30
	mov [rsp + 20], eax

	; --- ENGAGE ---
	; needs an enemy.  base = bravery + hp_pct
	; penalty = dist_tiles * 5  (distance in pixels / TILE_SIZE)
	test r14d, r14d
	js .engage_zero
	mov eax, r13d				; bravery
	add eax, ebx				; + hp_pct
	mov ecx, [rsp + 16]
	; ecx = dist px.  convert to tiles
	shr ecx, 4					; / 16 (TILE_SIZE)
	imul ecx, 5
	sub eax, ecx
	test eax, eax
	jns .engage_store
	xor eax, eax
.engage_store:
	mov [rsp + 24], eax
	jmp .flee_score
.engage_zero:
	mov dword [rsp + 24], 0

.flee_score:
	; --- FLEE ---
	; needs an enemy too.  more compelling when low hp + low bravery
	; missing_hp = 100 - hp_pct.  contribution = missing_hp * 3/2
	; bravery contribution = (255 - bravery) / 2
	test r14d, r14d
	js .flee_zero
	mov eax, 100
	sub eax, ebx	; missing_hp_pct
	imul eax, 3
	shr eax, 1		; * 1.5
	mov ecx, 255
	sub ecx, r13d
	shr ecx, 1
	add eax, ecx
	; close bonus: if enemy within 3 tiles, +30, seems good
	mov ecx, [rsp + 16]
	cmp ecx, 3 * TILE_SIZE
	jg .flee_save
	add eax, 30
.flee_save:
	mov [rsp + 28], eax
	jmp .pick
.flee_zero:
	mov dword [rsp + 28], 0

.pick:
	; pick the max-scoring mode
	mov eax, [rsp + 20]	; wander
	mov ecx, AI_MODE_WANDER

	cmp [rsp + 24], eax
	jle .skip_engage
	mov eax, [rsp + 24]
	mov ecx, AI_MODE_ENGAGING
.skip_engage:

	cmp [rsp + 28], eax
	jle .skip_flee
	mov eax, [rsp + 28]
	mov ecx, AI_MODE_FLEEING
.skip_flee:

	; --- promote to FIGHTING if engaging and close enough ---
	; ai_decide is called periodically while the entity is already
	; in a mode, so thi sshould stick.  if we'd pick ENGAGE,
	; AND the enemy is close, jump to FIGHTING instead
	cmp ecx, AI_MODE_ENGAGING
	jne .write_mode
	mov edx, [rsp + 16]
	cmp edx, FIGHT_RANGE_PX
	jg .write_mode
	mov ecx, AI_MODE_FIGHTING

.write_mode:
	mov byte [r12 + ENT_AI_MODE_OFFSET], cl

	; target idx (low byte of r14 or sentinel).  if the target
	; changed, invalidate any cached path - it points at the old
	; enemy and would lead us nowhere useful
	movzx eax, byte [r12 + ENT_AI_TARGET_OFFSET]
	test r14d, r14d 
	js .clear_target
	cmp eax, r14d
	je .target_same
	mov byte [r12 + ENT_AI_TARGET_OFFSET], r14b
	mov edi, [rsp + 0]
	call entity_path_clear
	jmp .ticks
.target_same:
	jmp .ticks
.clear_target:
	mov byte [r12 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov edi, [rsp + 0]
	call entity_path_clear

.ticks:
	; reset the decision countdown.  add a tiny jitter so all npcs
	; don't tick on the same frame
	mov edi, 8
	push rax
	call rng_range
	pop rcx
	add eax, DECISION_PERIOD
	cmp eax, 255
	jle .ticks_ok
	mov eax, 255
.ticks_ok:
	mov byte [r12 + ENT_DECISION_TICKS_OFFSET], al

	add rsp, 40
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_step_toward: pick the cardinal AI_DIR_ that closes distance
; to (target_x, target_y) most.  used by ENGAGING
;----------------------------------------------------------------
; in:	edi = self entity idx, esi = target entity idx
; sets self.ai_dir + self.facing
; returns no value
;================================================================
ai_step_toward:
	push rbx
	push r12
	push r13
	; 3 pushes (24) + ret = aligned
	mov ebx, edi
	mov r12d, esi

	; self ptr
	mov edi, ebx
	call entity_ptr
	mov r13, rax

	; tgt ptr
	mov edi, r12d
	call entity_ptr

	; dx, dy = target - self (signed)
	mov edx, [rax + ENT_X_OFFSET]
	sub edx, [r13 + ENT_X_OFFSET]
	mov ecx, [rax + ENT_Y_OFFSET]
	sub ecx, [r13 + ENT_Y_OFFSET]

	; |dx|, |dy|
	mov eax, edx
	test eax, eax
	jns .ax_pos
	neg eax
.ax_pos:
	mov edi, ecx
	test edi, edi
	jns .ay_pos
	neg edi
.ay_pos:

	; try and stop diagonal movement from flippflopping by making
	; axis changes a bit sticky
	movzx r8d, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp r8d, AI_DIR_LEFT
	je .cur_x
	cmp r8d, AI_DIR_RIGHT
	je .cur_x
	cmp r8d, AI_DIR_UP
	je .cur_y
	cmp r8d, AI_DIR_DOWN
	je .cur_y
	; current ai_dir is IDLE - no bias, pick the larger axis
	jmp .pick_larger
.cur_x:
	; currently moving on x.  switch to y only if |dy|*4 > |dx|*5
	mov r8d, edi
	imul r8d, 4
	mov r9d, eax
	imul r9d, 5
	cmp r8d, r9d
	jg .pick_y
	jmp .pick_x
.cur_y:
	; currently moving on y.  switch to x only if |dx|*4 > |dy|*5
	mov r8d, eax
	imul r8d, 4
	mov r9d, edi
	imul r9d, 5
	cmp r8d, r9d
	jg .pick_x
	jmp .pick_y

.pick_larger:
	cmp eax, edi
	jl .pick_y	; |dy| > |dx| -> step y

.pick_x:
	; step x: by sign of dx
	test edx, edx
	jns .step_right
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_LEFT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_LEFT
	jmp .out
.step_right:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_RIGHT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_RIGHT
	jmp .out

.pick_y:
	test ecx, ecx
	jns .step_down
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_UP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_UP
	jmp .out
.step_down:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_DOWN
	mov byte [r13 + ENT_FACING_OFFSET], FACE_DOWN

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_plan_path_to_target: run A* from this npc to its current
; ai_target.  on success the entity's path side table is filled
; in goal->start order, ready for ai_step_toward_waypoint to walk
;----------------------------------------------------------------
; in:	edi = self entity idx
; out:	eax = 1 if a path was planned, 0 otherwise (caller can
;		drop to wander, or just let the greedy step-toward run
;		this frame and try again next time)
;----------------------------------------------------------------
; stack frame (ret 8 + 3 push 24 + sub 16 = 48, 16-aligned):
;	[rsp+0]  start_tx
;	[rsp+4]  start_ty
;	[rsp+8]  goal_tx
;	[rsp+12] goal_ty
;================================================================
ai_plan_path_to_target:
	push rbx
	push r12
	push r13
	sub rsp, 16

	mov ebx, edi				; ebx = self idx

	mov edi, ebx
	call entity_ptr
	mov r12, rax				; r12 = self ptr

	movzx eax, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp eax, AI_TARGET_NONE
	je .fail
	mov edi, eax
	call entity_ptr
	mov r13, rax				; r13 = target ptr

	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .fail

	; tile coords for both ends.  px / TILE_SIZE with floor-for-neg
	mov eax, [r12 + ENT_X_OFFSET]
	call .px_to_tile
	mov [rsp + 0], eax			; start_tx

	mov eax, [r12 + ENT_Y_OFFSET]
	call .px_to_tile
	mov [rsp + 4], eax			; start_ty

	mov eax, [r13 + ENT_X_OFFSET]
	call .px_to_tile
	mov [rsp + 8], eax			; goal_tx

	mov eax, [r13 + ENT_Y_OFFSET]
	call .px_to_tile
	mov [rsp + 12], eax			; goal_ty

	mov edi, ebx
	mov esi, [rsp + 0]
	mov edx, [rsp + 4]
	mov ecx, [rsp + 8]
	mov r8d, [rsp + 12]
	call astar_find_path
	jmp .out

.fail:
	xor eax, eax
.out:
	add rsp, 16
	pop r13
	pop r12
	pop rbx
	ret

; tiny tail: floor(eax / TILE_SIZE).  trashes ecx/edx
.px_to_tile:
	mov ecx, TILE_SIZE
	cdq
	idiv ecx
	test edx, edx
	jns .pt_ok
	dec eax
.pt_ok:
	ret

;================================================================
; ai_step_toward_waypoint: pick the cardinal AI_DIR_ that closes
; distance to the entity's current path waypoint.  if we're close
; enough to the waypoint, advance to the next one first.  if the
; path is exhausted, eax=0 returned so the caller can replan
;----------------------------------------------------------------
; in:	edi = self entity idx
; out:	eax = 1 if a waypoint direction was set, 0 if path empty
;		(no direction set in the entity when 0)
;================================================================
ai_step_toward_waypoint:
	push rbx
	push r12
	push r13
	; 3 pushes (24) + ret (8) = 32 - aligned for inner calls

	mov ebx, edi
	call entity_ptr
	mov r12, rax				; r12 = self ptr

	mov edi, ebx
	call entity_path_current_waypoint
	test eax, eax
	jz .none
	; ecx = wp_tx, edx = wp_ty - pack into r13 (both fit u8)
	shl edx, 16
	or ecx, edx
	mov r13d, ecx				; r13 low16=tx, upper16=ty

	; waypoint centre in pixels
	movzx eax, r13w
	imul eax, TILE_SIZE
	add eax, TILE_SIZE / 2
	mov ecx, eax				; wp_cx
	mov eax, r13d
	shr eax, 16
	imul eax, TILE_SIZE
	add eax, TILE_SIZE / 2
	mov edx, eax				; wp_cy

	; reached? chebyshev to centre
	mov eax, ecx
	sub eax, [r12 + ENT_X_OFFSET]
	test eax, eax
	jns .wp_dxp
	neg eax
.wp_dxp:
	mov r8d, eax
	mov eax, edx
	sub eax, [r12 + ENT_Y_OFFSET]
	test eax, eax
	jns .wp_dyp
	neg eax
.wp_dyp:
	cmp eax, r8d
	jge .wp_have_cheb
	mov eax, r8d
.wp_have_cheb:
	cmp eax, PATH_WAYPOINT_REACH_PX
	jg .pick_dir				; not close enough yet

	; close enough - advance to the next waypoint and refetch
	mov edi, ebx
	call entity_path_advance
	mov edi, ebx
	call entity_path_current_waypoint
	test eax, eax
	jz .none					; path consumed
	shl edx, 16
	or ecx, edx
	mov r13d, ecx
	movzx eax, r13w
	imul eax, TILE_SIZE
	add eax, TILE_SIZE / 2
	mov ecx, eax
	mov eax, r13d
	shr eax, 16
	imul eax, TILE_SIZE
	add eax, TILE_SIZE / 2
	mov edx, eax

.pick_dir:
	; signed dx, dy = wp_centre - self
	mov esi, ecx
	sub esi, [r12 + ENT_X_OFFSET]
	mov edi, edx
	sub edi, [r12 + ENT_Y_OFFSET]

	mov eax, esi
	test eax, eax
	jns .ax_pos
	neg eax
.ax_pos:
	mov ecx, edi
	test ecx, ecx
	jns .ay_pos
	neg ecx
.ay_pos:
	; pick larger axis
	cmp eax, ecx
	jl .pick_y

.pick_x:
	test esi, esi
	jns .px_right
	mov byte [r12 + ENT_AI_DIR_OFFSET], AI_DIR_LEFT
	mov byte [r12 + ENT_FACING_OFFSET], FACE_LEFT
	jmp .ok
.px_right:
	mov byte [r12 + ENT_AI_DIR_OFFSET], AI_DIR_RIGHT
	mov byte [r12 + ENT_FACING_OFFSET], FACE_RIGHT
	jmp .ok

.pick_y:
	test edi, edi
	jns .py_down
	mov byte [r12 + ENT_AI_DIR_OFFSET], AI_DIR_UP
	mov byte [r12 + ENT_FACING_OFFSET], FACE_UP
	jmp .ok
.py_down:
	mov byte [r12 + ENT_AI_DIR_OFFSET], AI_DIR_DOWN
	mov byte [r12 + ENT_FACING_OFFSET], FACE_DOWN

.ok:
	mov eax, 1
	jmp .out_wp
.none:
	xor eax, eax
.out_wp:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_step_away: mirror of ai_step_toward, picks the dir that
; increases distance from target.  used by FLEEING
;----------------------------------------------------------------
; in:	edi = self entity idx, esi = target entity idx
;================================================================
ai_step_away:
	push rbx
	push r12
	push r13
	mov ebx, edi
	mov r12d, esi

	mov edi, ebx
	call entity_ptr
	mov r13, rax

	mov edi, r12d
	call entity_ptr

	; flee dir is the opposite of step-toward: target - self, then
	; pick the axis to flee on, then step AWAY from target along it
	mov edx, [rax + ENT_X_OFFSET]
	sub edx, [r13 + ENT_X_OFFSET]
	mov ecx, [rax + ENT_Y_OFFSET]
	sub ecx, [r13 + ENT_Y_OFFSET]

	mov eax, edx
	test eax, eax
	jns .ax_pos
	neg eax
.ax_pos:
	mov edi, ecx
	test edi, edi
	jns .ay_pos
	neg edi
.ay_pos:

	;sticky axis (see ai_step_toward)
	movzx r8d, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp r8d, AI_DIR_LEFT
	je .cur_x
	cmp r8d, AI_DIR_RIGHT
	je .cur_x
	cmp r8d, AI_DIR_UP
	je .cur_y
	cmp r8d, AI_DIR_DOWN
	je .cur_y
	jmp .pick_larger
.cur_x:
	mov r8d, edi
	imul r8d, 4
	mov r9d, eax
	imul r9d, 5
	cmp r8d, r9d
	jg .pick_y
	jmp .pick_x
.cur_y:
	mov r8d, eax
	imul r8d, 4
	mov r9d, edi
	imul r9d, 5
	cmp r8d, r9d
	jg .pick_x
	jmp .pick_y

.pick_larger:
	cmp eax, edi
	jl .pick_y

.pick_x:
	; flee along x: opposite sign of dx
	test edx, edx
	jns .away_left	; target is to our right -> we go left
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_RIGHT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_RIGHT
	jmp .out
.away_left:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_LEFT
	mov byte [r13 + ENT_FACING_OFFSET], FACE_LEFT
	jmp .out

.pick_y:
	test ecx, ecx
	jns .away_up
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_DOWN
	mov byte [r13 + ENT_FACING_OFFSET], FACE_DOWN
	jmp .out
.away_up:
	mov byte [r13 + ENT_AI_DIR_OFFSET], AI_DIR_UP
	mov byte [r13 + ENT_FACING_OFFSET], FACE_UP

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_move_in_dir: take one move step using the entity's current
; ai_dir.  same animation tick logic as wander.  used by ENGAGING
; and FLEEING which both want to keep walking once a dir is set
;----------------------------------------------------------------
; in:	edi = entity idx
;================================================================
ai_move_in_dir:
	push rbx
	push r12
	push r13
	; 3 pushes = aligned
	mov ebx, edi
	call entity_ptr
	mov r13, rax

	mov esi, 0	; dx
	mov edx, 0	; dy
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	jne .not_up
	mov edx, -ENGAGE_STEP
	jmp .have
.not_up:
	cmp eax, AI_DIR_DOWN
	jne .not_down
	mov edx, ENGAGE_STEP
	jmp .have
.not_down:
	cmp eax, AI_DIR_LEFT
	jne .not_left
	mov esi, -ENGAGE_STEP
	jmp .have
.not_left:
	cmp eax, AI_DIR_RIGHT
	jne .have
	mov esi, ENGAGE_STEP
.have:
	; if dx=dy=0 we're idle; no move
	mov eax, esi
	or eax, edx
	jz .idle

	mov edi, ebx
	call entity_try_move
	test eax, eax 
	jz .blocked

	; moved: anim tick
	movzx eax, byte [r13 + ENT_TIMER_OFFSET]
	inc eax
	cmp eax, ANIM_PERIOD
	jl .save_timer
	xor eax, eax
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	xor ecx, 1
	mov byte [r13 + ENT_PHASE_OFFSET], cl
.save_timer:
	mov byte [r13 + ENT_TIMER_OFFSET], al
	jmp .check_stuck

.blocked:
	; nudge: try opening a door in front if it's closed
	; recompute the (dx, dy) from ai_dir; entity_try_move trashed it
	xor esi, esi
	xor edx, edx
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	jne .ba_not_up
	mov edx, -ENGAGE_STEP
	jmp .ba_have
.ba_not_up:
	cmp eax, AI_DIR_DOWN
	jne .ba_not_down
	mov edx, ENGAGE_STEP
	jmp .ba_have
.ba_not_down:
	cmp eax, AI_DIR_LEFT
	jne .ba_not_left
	mov esi, -ENGAGE_STEP
	jmp .ba_have
.ba_not_left:
	cmp eax, AI_DIR_RIGHT
	jne .ba_have
	mov esi, ENGAGE_STEP
.ba_have:
	mov edi, ebx
	call entity_try_open_door_in_dir
	test eax, eax
	jnz .check_stuck	; door swung - try moving next tick,
						; counts as progress (no stuck)

; --- perpendicular slide: cardinal step blocked, try sidestep ---
	mov edi, 2
	call rng_range
	mov ecx, eax					; ecx = 0 or 1 - slide-order bit
	movzx eax, byte [r13 + ENT_AI_DIR_OFFSET]
	cmp eax, AI_DIR_UP
	je .perp_xaxis
	cmp eax, AI_DIR_DOWN
	je .perp_xaxis
	; left/right blocked -> try y axis
	test ecx, ecx
	jnz .slide_yp_first
	; up first, then down
	mov esi, 0
	mov edx, -ENGAGE_STEP
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	mov esi, 0
	mov edx, ENGAGE_STEP
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	jmp .check_stuck
.slide_yp_first:
	; down first, then up
	mov esi, 0
	mov edx, ENGAGE_STEP
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	mov esi, 0
	mov edx, -ENGAGE_STEP
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	jmp .check_stuck
.perp_xaxis:
	; up/down blocked -> try x axis
	test ecx, ecx
	jnz .slide_xp_first
	; left first, then right
	mov esi, -ENGAGE_STEP
	mov edx, 0
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	mov esi, ENGAGE_STEP
	mov edx, 0
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	jmp .check_stuck
.slide_xp_first:
	; right first, then left
	mov esi, ENGAGE_STEP
	mov edx, 0
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	mov esi, -ENGAGE_STEP
	mov edx, 0
	mov edi, ebx
	call entity_try_move
	test eax, eax
	jnz .check_stuck
	jmp .check_stuck

.idle:
	mov byte [r13 + ENT_TIMER_OFFSET], 0
	mov byte [r13 + ENT_PHASE_OFFSET], 0
	jmp .out					; idle isn't stuck - we chose not to move

.check_stuck:
	; we made some attempt to move - might or might not have actually
	; changed tile(the sideways slide doesn't change our tile))
	; compare current tile vs the stored "last sampled tile" in the
	;s ide table.  if same, stuck_ticks rises.  if different, reset
	; and store the new tile
	mov eax, [r13 + ENT_X_OFFSET]
	mov ecx, TILE_SIZE
	cdq
	idiv ecx					; eax = current tx
	mov r8d, eax
	mov eax, [r13 + ENT_Y_OFFSET]
	cdq
	idiv ecx
	mov r9d, eax				; r9d = current ty

	lea rcx, [entity_last_tx]
	movzx edx, byte [rcx + rbx]	; stored tx
	cmp edx, r8d
	jne .tile_changed
	lea rcx, [entity_last_ty]
	movzx edx, byte [rcx + rbx]
	cmp edx, r9d
	jne .tile_changed

	; same tile as last sample - bump stuck_ticks
	movzx eax, byte [r13 + ENT_STUCK_TICKS_OFFSET]
	inc eax
	cmp eax, STUCK_BREAKOUT_FRAMES
	jl .save_stuck

	; --- breakout! ---
	; we've been on this tile for STUCK_BREAKOUT_FRAMES despite
	; attempting moves every frame. try these options in order:
	;
	; 1) re-scan for the nearest enemy.the original target might be
	;    unreachable while a different one is now in sight
	; 2) if step 1 fails (no enemy or no path), demote to wander
	;    + use the hub flow field
	mov edi, ebx
	call ai_find_nearest_enemy
	test eax, eax
	js .breakout_wander
	; got an enemy - set it and try planning a path
	mov byte [r13 + ENT_AI_TARGET_OFFSET], al
	mov edi, ebx
	call ai_plan_path_to_target
	test eax, eax
	jz .breakout_wander		; no path - fall through to wander

	; path found - stay engaged.  reset stuck counter, leave
	; ai_mode untouched if already engaging (caller may have us
	; in FIGHTING; let ai_decide sort that out next macro tick)
	mov byte [r13 + ENT_AI_MODE_OFFSET], AI_MODE_ENGAGING
	mov byte [r13 + ENT_DECISION_TICKS_OFFSET], DECISION_PERIOD
	xor eax, eax				; clear stuck counter
	jmp .save_stuck

.breakout_wander:
	; use hub flow field to go somewhere, 
	; wander for STUCK_RECOVER_FRAMES so we don't snap right back
	; into the same crevice
	mov edi, [r13 + ENT_X_OFFSET]
	mov esi, [r13 + ENT_Y_OFFSET]
	call pathing_dir_at_pixel
	test eax, eax
	jnz .breakout_have_dir
	mov edi, 4
	call rng_range
	inc eax			; [0,4) -> AI_DIR_UP..RIGHT
.breakout_have_dir:
	mov byte [r13 + ENT_AI_DIR_OFFSET], al
	mov byte [r13 + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
	mov byte [r13 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov byte [r13 + ENT_DECISION_TICKS_OFFSET], STUCK_RECOVER_FRAMES
	mov word [r13 + ENT_AI_TICKS_OFFSET], STUCK_RECOVER_FRAMES
	; also clear any cached path now that we're going off plan
	mov edi, ebx
	call entity_path_clear
	xor eax, eax	; clear stuck counter after breakout
.save_stuck:
	mov byte [r13 + ENT_STUCK_TICKS_OFFSET], al
	jmp .out

.tile_changed:
	; we crossed a tile boundary since last sample - clear the
	; counter, store the new tile, and continue.  no breakout needed
	lea rcx, [entity_last_tx]
	mov [rcx + rbx], r8b
	lea rcx, [entity_last_ty]
	mov [rcx + rbx], r9b
	mov byte [r13 + ENT_STUCK_TICKS_OFFSET], 0

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_attack_tick: in FIGHTING mode, drain attack_ticks and deal
; damage to target on each melee attack.  kills target if hp drops
;----------------------------------------------------------------
; in:	edi = self idx
;================================================================
ai_attack_tick:
	push rbx
	push r12
	push r13
	mov ebx, edi
	call entity_ptr
	mov r12, rax	; self ptr

	; tick the attack cooldown
	movzx eax, byte [r12 + ENT_ATTACK_TICKS_OFFSET]
	test eax, eax
	jz .meleeattack
	dec eax
	mov byte [r12 + ENT_ATTACK_TICKS_OFFSET], al
	jmp .out

.meleeattack:
	; reload cooldown
	mov byte [r12 + ENT_ATTACK_TICKS_OFFSET], ATTACK_PERIOD

	; target?
	movzx eax, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp eax, AI_TARGET_NONE
	je .out
	mov edi, eax
	call entity_ptr
	mov r13, rax

	; target alive?
	movzx ecx, byte [r13 + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .out

	; in range? (chebyshev distance in px <= FIGHT_RANGE_PX))
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [r12 + ENT_X_OFFSET]
	test eax, eax
	jns .att_dx_pos
	neg eax
.att_dx_pos:
	mov ecx, [r13 + ENT_Y_OFFSET]
	sub ecx, [r12 + ENT_Y_OFFSET]
	test ecx, ecx
	jns .att_dy_pos
	neg ecx
.att_dy_pos:
	cmp eax, ecx
	jge .att_have
	mov eax, ecx
.att_have:
	cmp eax, FIGHT_RANGE_PX
	jg .out	; nope, out of range, skip meleeattack

	; deal damage
	movzx eax, byte [r13 + ENT_HP_OFFSET]
	sub eax, ENGAGE_DAMAGE
	jg .alive_after
	mov byte [r13 + ENT_HP_OFFSET], 0
	; death - splat a single blood mark at this tile
	; push rdi/rsi for the call args (recomputed-then-discarded so
	; we don't need them back)
	mov edi, [r13 + ENT_X_OFFSET]
	mov esi, [r13 + ENT_Y_OFFSET]
	sub rsp, 8 ; keepaligned
	call blood_splat_at_pixel
	add rsp, 8
	; pop the damage number over the corpse before we kill it (kill
	; clears flags, but we read x/y from r13 which is still valid)
	mov edi, [r13 + ENT_X_OFFSET]
	mov esi, [r13 + ENT_Y_OFFSET]
	mov edx, ENGAGE_DAMAGE
	call spawn_dmgfloat
	movzx edi, byte [r12 + ENT_AI_TARGET_OFFSET]
	call entity_kill
	; clear our target
	mov byte [r12 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	; drop to wander
	mov byte [r12 + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
	mov byte [r12 + ENT_DECISION_TICKS_OFFSET], 0
	jmp .out
.alive_after:
	mov byte [r13 + ENT_HP_OFFSET], al
	; flash the hit pose for HIT_FLASH_FRAMES + splat blood
	mov byte [r13 + ENT_HIT_TIMER_OFFSET], HIT_FLASH_FRAMES
	mov edi, [r13 + ENT_X_OFFSET]
	mov esi, [r13 + ENT_Y_OFFSET]
	call blood_splat_at_pixel
	; damage number floats above the victim
	mov edi, [r13 + ENT_X_OFFSET]
	mov esi, [r13 + ENT_Y_OFFSET]
	mov edx, ENGAGE_DAMAGE
	call spawn_dmgfloat

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; ai_tick: per-frame entry for one NPC
;----------------------------------------------------------------
; drives a small state machine:
;	- decision_ticks > 0?  decrement and continue micro behaviour
;	- else: ai_decide picks a new mode
;
; the per-mode micro behaviour is dispatched at the end
;----------------------------------------------------------------
; in:	edi = entity index
;================================================================
ai_tick:
	push rbx
	push r12
	; 2 pushes (16) + ret (8) = misaligned; pad with sub 8
	sub rsp, 8

	mov ebx, edi
	call entity_ptr
	mov r12, rax

	; --- decay the hit-flash pose timer ---
	movzx eax, byte [r12 + ENT_HIT_TIMER_OFFSET]
	test eax, eax
	jz .ht_done
	dec eax
	mov byte [r12 + ENT_HIT_TIMER_OFFSET], al
.ht_done:

; --- slow hp regen: +1 every REGEN_PERIOD frames if below max ---
	; staggered per entity by adding our index to the global frame
	; counter so we don't get all-at-once regen spikes across the table.
	; we trickle up regardless of mode - fleeing npcs especially need
	; this so they don't stay retreating forever.  mb turn this off
	; while FIGHTING?
	mov eax, [frame_count]
	add eax, ebx
	xor edx, edx
	mov ecx, REGEN_PERIOD
	div ecx
	test edx, edx
	jnz .regen_done
	movzx eax, byte [r12 + ENT_HP_OFFSET]
	movzx ecx, byte [r12 + ENT_HP_MAX_OFFSET]
	cmp eax, ecx
	jge .regen_done
	inc eax
	mov byte [r12 + ENT_HP_OFFSET], al
.regen_done:

	; --- macro tier: re-decide if countdown elapsed ---
	movzx eax, byte [r12 + ENT_DECISION_TICKS_OFFSET]
	test eax, eax
	jnz .tick_dec
	mov edi, ebx
	call ai_decide
	jmp .post_decide
.tick_dec:
	dec eax
	mov byte [r12 + ENT_DECISION_TICKS_OFFSET], al

.post_decide:
	; --- target sanity: if we have a target that died, clear it
	; and downgrade to wander so we don't keep chasing a corpse
	movzx eax, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp eax, AI_TARGET_NONE
	je .no_target_check
	mov edi, eax
	call entity_ptr
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jnz .no_target_check
	; dead - clear and downgrade.  also wipe any cached path since
	; it pointed at where the corpse fell
	mov byte [r12 + ENT_AI_TARGET_OFFSET], AI_TARGET_NONE
	mov byte [r12 + ENT_AI_MODE_OFFSET], AI_MODE_WANDER
	mov edi, ebx
	call entity_path_clear
.no_target_check:

	; --- micro tier: dispatch by mode ---
	movzx eax, byte [r12 + ENT_AI_MODE_OFFSET]
	cmp eax, AI_MODE_WANDER
	je .m_wander
	cmp eax, AI_MODE_ENGAGING
	je .m_engage
	cmp eax, AI_MODE_FIGHTING
	je .m_fight
	cmp eax, AI_MODE_FLEEING
	je .m_flee
	; IDLE: do nothing!
	jmp .out

.m_wander:
	mov edi, ebx
	call entity_wander_tick
	jmp .out

.m_engage:
	; new pathing-aware engage:
	; 1) if no target, bail (ai_decide will clear mode next tick)
	; 2) if the path is stale (world changed) or missing, try a
	;    replan.  on success carry on to follow it.  on fail, fall
	;    back to greedy step_toward for this frame - we'll try
	;    again next decision tick
	; 3) follow the waypoint chain.  if it runs out, replan
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp esi, AI_TARGET_NONE
	je .out

	mov edi, ebx
	call entity_path_is_stale
	test eax, eax
	jz .have_path
	mov edi, ebx
	call ai_plan_path_to_target
	; either way (success or fail) try walking the path - on fail
	; the path is empty so ai_step_toward_waypoint returns 0 and
	; we fall through to greedy step

.have_path:
	mov edi, ebx
	call ai_step_toward_waypoint
	test eax, eax
	jnz .engage_move

	; no waypoint - either we just consumed the last one, or the
	; replan failed.  greedy step_toward is the safety net so we at
	; least try to make progress this frame
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	mov edi, ebx
	call ai_step_toward

.engage_move:
	mov edi, ebx
	call ai_move_in_dir
	jmp .out

.m_fight:
	; while in fight range, the attack_tick swings.  if the target
	; slipped out of range, fall back to ENGAGING immediately so we
	; chase rather than attack nothing for some frames
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp esi, AI_TARGET_NONE
	je .out
	; distance check
	mov edi, esi
	call entity_ptr
	; eax = target ptr
	mov ecx, [rax + ENT_X_OFFSET]
	sub ecx, [r12 + ENT_X_OFFSET]
	test ecx, ecx
	jns .mf_dx_pos
	neg ecx
.mf_dx_pos:
	mov edx, [rax + ENT_Y_OFFSET]
	sub edx, [r12 + ENT_Y_OFFSET]
	test edx, edx
	jns .mf_dy_pos
	neg edx
.mf_dy_pos:
	cmp ecx, edx
	jge .mf_have
	mov ecx, edx
.mf_have:
	cmp ecx, FIGHT_RANGE_PX
	jle .do_attack
	; out of range - go chase
	mov byte [r12 + ENT_AI_MODE_OFFSET], AI_MODE_ENGAGING
	mov edi, ebx
	call ai_step_toward
	mov edi, ebx
	call ai_move_in_dir
	jmp .out
.do_attack:
	mov edi, ebx
	call ai_attack_tick
	jmp .out

.m_flee:
	movzx esi, byte [r12 + ENT_AI_TARGET_OFFSET]
	cmp esi, AI_TARGET_NONE
	je .out
	mov edi, ebx
	call ai_step_away
	mov edi, ebx
	call ai_move_in_dir

.out:
	add rsp, 8
	pop r12
	pop rbx
	ret

%endif