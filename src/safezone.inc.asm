; safezone.inc.asm - world-space "safe zone" mask
;----------------------------------------------------------------
; bytewise mask, 1 byte per world tile.  1 = lit by at least one
; torch, 0 = dark.  used by:
;	- monster spawn rules later (skip lit tiles)
;	- F6 debug overlay (tint dark tiles)
;
; this is a gameplay mask, not the visual lightmap.  the daynight
; module's lightmap is screen-space, viewport-clipped, and includes
; entity-cast shadows which flicker as the player moves.  for
; gameplay we want stability: only world state (tiles + objects)
; influences the mask, and we recompute on event (placement, tile
; removal, world regen atm) - never per frame
;
; the world fits comfortably in a Bresenham-per-target scan
; seems fast enough.  can add some kind of chunking/lazy updates
; later if needed for massive maps
;
; rule for opacity (matches the visual lighting):
;	- object empty or torch		-> pass
;	- object with speed 100		-> pass (open doors, chairs)
;	- everything else			-> block (walls, trees, beds, ...)
;	- entities do NOT occlude	-> player/NPCs don't flicker safe
;								   zones as they walk past
%ifndef SAFEZONE_INC
%define SAFEZONE_INC

%define SAFEZONE_RADIUS		6				; light reach in tiles
%define SAFEZONE_RADIUS_SQ	(SAFEZONE_RADIUS * SAFEZONE_RADIUS)

section .data
	log_msg_safezone	db "safezone overlay toggled", 0

section .bss
	safezone_mask		resb MAP_WIDTH * MAP_HEIGHT
	safezone_debug_view	resb 1				; F6 toggle

section .text

;================================================================
; safezone_toggle_debug: flip the overlay on/off (F6)
;================================================================
safezone_toggle_debug:
	xor byte [safezone_debug_view], 1
	lea rdi, [log_msg_safezone]
	call debug_log
	ret

;================================================================
; safezone_tile_blocks: does the cell at (tx, ty) stop torchlight?
;----------------------------------------------------------------
; matches the daynight occluder rule: anything non-empty in the
; objectmap blocks, unless it's a torch or its movement speed is
; 100 (walkable through - open doors etc).  oob counts as blocking
; so torch reach naturally clips at edges
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 1 if blocking, 0 otherwise
;================================================================
safezone_tile_blocks:
	test edi, edi
	js .yes
	cmp edi, MAP_WIDTH
	jge .yes
	test esi, esi
	js .yes
	cmp esi, MAP_HEIGHT
	jge .yes

	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [objectmap]
	movzx eax, byte [rdx + rax]
	test eax, eax
	jz .no						; empty - light passes
	cmp eax, TILE_TORCH
	je .no						; torches don't occlude
	lea rdx, [tile_speed_table]
	movzx edx, byte [rdx + rax]
	cmp edx, 100
	je .no						; walkable - transparent to light
.yes:
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; safezone_mark_tile: set safezone_mask[ty*W + tx] = 1.  oob no-op
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
;================================================================
safezone_mark_tile:
	test edi, edi
	js .out
	cmp edi, MAP_WIDTH
	jge .out
	test esi, esi
	js .out
	cmp esi, MAP_HEIGHT
	jge .out
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [safezone_mask]
	mov byte [rdx + rax], 1
.out:
	ret

;================================================================
; safezone_raycast: walk a Bresenham line from (sx,sy) to (tx,ty)
; marking each cell safe until the first blocker (inclusive)
;----------------------------------------------------------------
; the source cell is marked but never tested for blocking (a torch
; in a wall would otherwise self-block).  the FIRST stepped cell
; is tested, so a torch flush against a wall lights only the wall
;----------------------------------------------------------------
; in:	edi = sx, esi = sy, edx = tx, ecx = ty
;----------------------------------------------------------------
; rsp-relative locals after prologue (push rbx,r12-r15 + sub 24):
;	[rsp+0]  target tx
;	[rsp+4]  target ty
;	[rsp+8]  err (Bresenham accumulator)
;	[rsp+12] dx (positive)
;	[rsp+16] dy (negative form)
;	[rsp+20] (alignment slack)
; r12 = cx (cur), r13 = cy, r14 = sx_step, r15 = sy_step.  ebx
; holds sx briefly during setup, then is freed.  sy lives in a
; reg long enough that we just keep it in esi via re-reads
;================================================================
safezone_raycast:
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 24					; 5 pushes + 24 = 64 = 16-aligned

	mov [rsp + 0], edx			; tx
	mov [rsp + 4], ecx			; ty
	; r12 = current x, r13 = current y - seeded from source
	mov r12d, edi
	mov r13d, esi

	; mark source (edi=sx, esi=sy already in regs)
	call safezone_mark_tile
	; sx/sy live in r12/r13 across calls (callee-saved), so we
	; don't depend on edi/esi being preserved by mark_tile

	; sx_step: +1 if sx < tx, else -1
	mov r14d, 1
	cmp r12d, [rsp + 0]
	jle .sx_set
	mov r14d, -1
.sx_set:
	mov r15d, 1
	cmp r13d, [rsp + 4]
	jle .sy_set
	mov r15d, -1
.sy_set:
	; dx = abs(tx - sx)
	mov eax, [rsp + 0]
	sub eax, r12d
	test eax, eax
	jns .dx_pos
	neg eax
.dx_pos:
	mov [rsp + 12], eax			; dx
	; dy = -abs(ty - sy)
	mov eax, [rsp + 4]
	sub eax, r13d
	test eax, eax
	jns .dy_pos
	neg eax
.dy_pos:
	neg eax
	mov [rsp + 16], eax			; dy (negative)
	; err = dx + dy
	mov ebx, [rsp + 12]
	add ebx, eax
	mov [rsp + 8], ebx			; err

	;trivial out: source == target?
	cmp r12d, [rsp + 0]
	jne .loop
	cmp r13d, [rsp + 4]
	je .out

.loop:
	; e2= 2 * err
	mov eax, [rsp + 8]
	add eax, eax
	; if e2 >= dy: err += dy; cx += sx_step
	cmp eax, [rsp + 16]
	jl .skip_x
	mov ecx, [rsp + 16]
	add [rsp + 8], ecx
	add r12d, r14d
.skip_x:
	; if e2 <= dx: err += dx; cy += sy_step
	cmp eax, [rsp + 12]
	jg .skip_y
	mov ecx, [rsp + 12]
	add [rsp + 8], ecx
	add r13d, r15d
.skip_y:

	; we've moved to (r12d, r13d).  test for blocker then mark.
	; mark unconditionally so the blocker cell itself reads safe
	mov edi, r12d
	mov esi, r13d
	call safezone_tile_blocks
	; eax is the blocker flag.  stash on stack briefly so it
	; survives the mark call
	push rax					; -8: misaligns
	sub rsp, 8					; pad back to aligned
	mov edi, r12d
	mov esi, r13d
	call safezone_mark_tile
	add rsp, 8
	pop rax

	test eax, eax
	jnz .out					; first blocker -> stop

	; reached target?
	cmp r12d, [rsp + 0]
	jne .loop
	cmp r13d, [rsp + 4]
	jne .loop

.out:
	add rsp, 24
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; safezone_stamp_torch: cast rays from a torch to every tile in
; its radius, marking lit tiles via the raycaster
;----------------------------------------------------------------
; in:	edi = torch tx, esi = torch ty
;----------------------------------------------------------------
; rsp-relative locals after prologue (5 callee saves + sub 24):
;	[rsp+0]  torch tx
;	[rsp+4]  torch ty
;	[rsp+8]  x0 bbox left
;	[rsp+12] x1 bbox right
;	[rsp+16] y1 bbox bottom
;	[rsp+20] (alignment)
; r12 = y walker, r13 = x walker
;================================================================
safezone_stamp_torch:
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 24

	mov [rsp + 0], edi			; torch tx
	mov [rsp + 4], esi			; torch ty

	; x0 = max(0, tx - R)
	mov eax, edi
	sub eax, SAFEZONE_RADIUS
	test eax, eax
	jns .x0_ok
	xor eax, eax
.x0_ok:
	mov [rsp + 8], eax
	; x1 = min(MAP_WIDTH-1, tx + R)
	mov eax, edi
	add eax, SAFEZONE_RADIUS
	cmp eax, MAP_WIDTH - 1
	jle .x1_ok
	mov eax, MAP_WIDTH - 1
.x1_ok:
	mov [rsp + 12], eax
	; y0 (start of y walker) = max(0, ty - R)
	mov eax, esi
	sub eax, SAFEZONE_RADIUS
	test eax, eax
	jns .y0_ok
	xor eax, eax
.y0_ok:
	mov r12d, eax
	; y1 = min(MAP_HEIGHT-1, ty + R)
	mov eax, esi
	add eax, SAFEZONE_RADIUS
	cmp eax, MAP_HEIGHT - 1
	jle .y1_ok
	mov eax, MAP_HEIGHT - 1
.y1_ok:
	mov [rsp + 16], eax

.row:
	cmp r12d, [rsp + 16]
	jg .out
	mov r13d, [rsp + 8]			; x = x0
.col:
	cmp r13d, [rsp + 12]
	jg .row_done

	; radius^2 check
	mov eax, r13d
	sub eax, [rsp + 0]
	imul eax, eax				; dx^2
	mov r14d, eax
	mov eax, r12d
	sub eax, [rsp + 4]
	imul eax, eax				; dy^2
	add r14d, eax
	cmp r14d, SAFEZONE_RADIUS_SQ
	jg .col_next

	; cast a ray from torch to (r13d, r12d)
	mov edi, [rsp + 0]
	mov esi, [rsp + 4]
	mov edx, r13d
	mov ecx, r12d
	call safezone_raycast

.col_next:
	inc r13d
	jmp .col
.row_done:
	inc r12d
	jmp .row
.out:
	add rsp, 24
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; safezone_recompute: rebuild safezone_mask from scratch
;----------------------------------------------------------------
; call after any event that could change torch positions or
; occluder layout: placement, removal, door toggle, world regen.
; NEVER call from per-frame paths - we explicitly want this
; gameplay mask to stay stable as entities walk around
;================================================================
safezone_recompute:
	push rbx
	sub rsp, 8					; align
	; clear mask
	lea rdi, [safezone_mask]
	mov ecx, MAP_WIDTH * MAP_HEIGHT
	xor eax, eax
	rep stosb

	; walk objectmap, stamp each torch
	xor ebx, ebx
.scan:
	cmp ebx, MAP_WIDTH * MAP_HEIGHT
	jge .done
	lea rcx, [objectmap]
	movzx eax, byte [rcx + rbx]
	cmp eax, TILE_TORCH
	jne .next
	; idx -> (tx, ty)
	mov eax, ebx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx						; eax = ty, edx = tx
	mov edi, edx
	mov esi, eax
	call safezone_stamp_torch
.next:
	inc ebx
	jmp .scan
.done:
	add rsp, 8
	pop rbx
	ret

;================================================================
; safezone_at: 1 if tile is lit, 0 otherwise.  oob reads as 0
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 0 or 1
;================================================================
safezone_at:
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
	lea rdx, [safezone_mask]
	movzx eax, byte [rdx + rax]
	ret
.none:
	xor eax, eax
	ret

;================================================================
; safezone_draw_debug: tint every dark tile to expose the mask
;----------------------------------------------------------------
; F6 toggle. reads ws mask so the overlay is stable as entities move
; iterates visible tiles only
;================================================================
safezone_draw_debug:
	cmp byte [safezone_debug_view], 0
	je .out

	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8					; align + tx0 stash

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

	; stash tx0 at [rsp]; r15 = ty walker
	mov [rsp], ebx
	mov r15d, r12d
.row:
	cmp r15d, r14d
	jg .done

	mov ebx, [rsp]
.col:
	cmp ebx, r13d
	jg .row_done

	; safe?
	mov eax, r15d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rdx, [safezone_mask]
	movzx eax, byte [rdx + rax]
	test eax, eax
	jnz .col_next

	; dark - tint
	mov edi, ebx
	imul edi, TILE_SIZE
	sub edi, [camera_x]
	mov esi, r15d
	imul esi, TILE_SIZE
	sub esi, [camera_y]
	mov edx, TILE_SIZE
	mov ecx, TILE_SIZE
	mov r8d, 0x60FF0000 ; danger colour
	call fill_rect

.col_next:
	inc ebx
	jmp .col
.row_done:
	inc r15d
	jmp .row
.done:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out:
	ret

%endif