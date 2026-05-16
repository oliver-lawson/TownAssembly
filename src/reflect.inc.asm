; reflect.inc.asm - water reflections for entities
;
; second-pass renderer that draws each entity's sprite vertically
; flipped, slightly offset below the entity's feet, masked against
; water-blue pixels in the framebuffer.  blit_texture_rect_reflect
; does the masking + 50/50 blend per pixel; this file picks
; the right source rect and dest position per entity
;
; pose has to be picked again, is currently just the default pose
; TODO: rethink this

%ifndef REFLECT_INC
%define REFLECT_INC

; vertical gap, 0 seems best
%define REFLECT_Y_OFF 0

section .text

;================================================================
; draw_reflections: per-entity flipped reflection pass
;----------------------------------------------------------------
; iterates every alive entity, picks its current walk-row sprite
; slot, and calls blit_texture_rect_reflect at the mirrored
; position below the entity
;================================================================
draw_reflections:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8					; align

	mov r14d, [entity_count]
	xor r15d, r15d				; idx
.next:
	cmp r15d, r14d
	jge .done

	mov edi, r15d
	call entity_ptr
	mov r13, rax				; r13 = entity ptr

	; skip dead
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .skip

	; -- pose pick (walk row only) --
	; mirrors the walk-row branch of draw_entities: facing picks
	; the column within the 4-frame block, phase animates leg pose
	movzx r12d, byte [r13 + ENT_SLOT_OFFSET]; r12 = base slot
	movzx eax, byte [r13 + ENT_FACING_OFFSET]

	cmp eax, FACE_DOWN
	je .pp_down
	cmp eax, FACE_UP
	je .pp_up
	cmp eax, FACE_LEFT
	je .pp_left
	; right
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	mov ecx, 1
	jmp .pose_done
.pp_left:
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	xor ecx, ecx
	jmp .pose_done
.pp_down:
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	jmp .pose_done
.pp_up:
	add r12d, 1
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
.pose_done:
	; r12d = atlas slot, ecx = flip_x

	; -- dest position --
	; entity (x,y) is the centre of sprite.  draw_entities subtracts
	; SPRITE_SIZE/2 to get top-left of the upright sprite.  the
	; reflection's top is at (entity_y + SPRITE_SIZE/2) + offset,
	; so its mirror line sits right at the entity's feet
	push rcx					; save flip across the call
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [camera_x]
	sub eax, SPRITE_SIZE/2
	mov ebx, eax				; ebx = dst_x

	mov eax, [r13 + ENT_Y_OFFSET]
	sub eax, [camera_y]
	add eax, SPRITE_SIZE/2
	add eax, REFLECT_Y_OFF		; eax = dst_y

	pop rdi
	movzx edi, dil				; clear upper bits

	; same arg shape as the keyed blit
	sub rsp, 8					; align (3 pushes = 24, +8 = 32)
	mov rcx, SPRITE_COLOR_KEY
	push rcx					; key
	push rdi					; flip
	cdqe
	push rax					; dst_y

	lea rdi, [sprites_tex]
	mov esi, r12d
	imul esi, SPRITE_SIZE		; src_x
	xor edx, edx				; src_y = 0 (walk row)
	mov ecx, SPRITE_SIZE
	mov r8d, SPRITE_SIZE
	mov r9d, ebx				; dst_x

	call blit_texture_rect_reflect
	add rsp, 32

.skip:
	inc r15d
	jmp .next
.done:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

%endif
