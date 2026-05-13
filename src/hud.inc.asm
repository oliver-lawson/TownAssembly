; hud.inc.asm

%ifndef HUD_INC
%define HUD_INC

; -- layout constants --
; bar can span diffrent WINDOW_Hs tho icons would need readjusting
%define HUD_BAR_H			16
%define HUD_ICON			8
%define HUD_BG_COLOUR		0xFF343434
%define HUD_BORDER_COLOUR	0xFF000000
%define HUD_TEXT_COLOUR		0xFFCECEAC
%define HUD_Y				(WINDOW_H-12) ; y mid for icons/text

; -- hotbar layout --
; row of placeable items, sitting just above the hud strip
; one slot per real ITEM_* (1..ITEM_COUNT-1)
%define HOTBAR_SLOTS		(ITEM_COUNT - 1)
%define HOTBAR_SLOT_W		20
%define HOTBAR_SLOT_H		20
%define HOTBAR_PITCH		22 ; slot + 2px gap
%define HOTBAR_TOTAL_W		(HOTBAR_SLOTS*HOTBAR_PITCH-2)
%define HOTBAR_X			((WINDOW_W - HOTBAR_TOTAL_W)/2)
%define HOTBAR_Y			(WINDOW_H - HUD_BAR_H - HOTBAR_SLOT_H - 2)
%define HOTBAR_BG			0xC0202830
%define HOTBAR_BORDER		0xFF000000
%define HOTBAR_BORDER_SEL	0xFFFFEE88
%define HOTBAR_NUM_COLOUR	0xFFCECEAC
%define HOTBAR_DIM_COLOUR	0xFF606060 ; tile/text when count is 0

section .text

;================================================================
; draw_hud_bar: bottom-of-screen status strip
;================================================================
draw_hud_bar:
	push rbp
	mov rbp, rsp
	; 1 push (rbp) + return = 16 bytes -> aligned for inner calls

	; --- background strip ---
	xor edi, edi
	mov esi, WINDOW_H - HUD_BAR_H
	mov edx, WINDOW_W
	mov ecx, HUD_BAR_H
	mov r8d, HUD_BG_COLOUR
	call fill_rect
	; border on top edge
	xor edi, edi
	mov esi, WINDOW_H - HUD_BAR_H
	mov edx, WINDOW_W
	mov ecx, 1
	mov r8d, HUD_BORDER_COLOUR
	call fill_rect

	; --- entries: icon at icon_x, number 10px to its right ---
	; HP - icon slot 0
	mov edi, 2
	xor esi, esi
	call hud_blit_icon
	mov edi, 12
	movzx ecx, word [player_hp]
	call hud_print_int

	; wood - icon slot 1
	mov edi, 64
	mov esi, 1
	call hud_blit_icon
	mov edi, 74
	movzx ecx, word [player_res_wood]
	call hud_print_int

	; stone - icon slot 2
	mov edi, 128
	mov esi, 2
	call hud_blit_icon
	mov edi, 138
	movzx ecx, word [player_res_stone]
	call hud_print_int

	; food - icon slot 3
	mov edi, 192
	mov esi, 3
	call hud_blit_icon
	mov edi, 202
	movzx ecx, word [player_res_food]
	call hud_print_int

	; gold - icon slot 4
	mov edi, 256
	mov esi, 4
	call hud_blit_icon
	mov edi, 266
	movzx ecx, word [player_res_gold]
	call hud_print_int

	pop rbp
	ret

;================================================================
; hud_blit_icon: stamp an 8x8 icon from icons_tex at (edi, HUD_Y)
;----------------------------------------------------------------
; in: edi = dst_x, esi = icon slot index (0..N)
;================================================================
hud_blit_icon:
	push rbp
	mov rbp, rsp
	; entry rsp%16 = 8; +rbp = aligned
	; 2 push args below = aligned at call

	; src_x = slot * 8
	mov eax, esi
	imul eax, HUD_ICON

	mov r9d, edi			; dst_x
	lea rdi, [icons_tex]
	mov esi, eax			; src_x
	xor edx, edx			; src_y
	mov ecx, HUD_ICON		; src_w
	mov r8d, HUD_ICON		; src_h

	push 0					; flip = 0
	push HUD_Y				; dst_y
	call blit_texture_rect
	add rsp, 16

	pop rbp
	ret

;================================================================
; hud_print_int: print a number at (edi, HUD_Y) in HUD text colour
;----------------------------------------------------------------
; in: edi = x, ecx = value
;================================================================
hud_print_int:
	mov esi, HUD_Y
	mov edx, HUD_TEXT_COLOUR
	jmp debug_print_int

;================================================================
; draw_hotbar
;----------------------------------------------------------------
; one slot per real ITEM_* id
; (1..ITEM_COUNT-1)
;
; slots with 0 draw but icon and count dim, selection still
; highlights even on an empty slot - it's just a "no item" hint
;================================================================
draw_hotbar:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee-saves + ret + rbp = 56 = 8 mod 16, sub 8 to align
	sub rsp, 8

	; ebx = slot index 0..HOTBAR_SLOTS-1
	xor ebx, ebx
.slot_loop:
	cmp ebx, HOTBAR_SLOTS
	jge .done

	; r12d = slot screen x = HOTBAR_X + ebx * HOTBAR_PITCH
	mov r12d, ebx
	imul r12d, HOTBAR_PITCH
	add r12d, HOTBAR_X
	; r13d = item id for this slot = ebx + 1
	mov r13d, ebx
	inc r13d
	; r14d = count we own
	movzx r14d, word [inv_item_count + r13*2]

	; --- background ---
	mov edi, r12d
	mov esi, HOTBAR_Y
	mov edx, HOTBAR_SLOT_W
	mov ecx, HOTBAR_SLOT_H
	mov r8d, HOTBAR_BG
	call fill_rect

	; --- border ---
	; pick colour: bright if selected, else default
	mov r15d, HOTBAR_BORDER
	movzx eax, byte [hotbar_selected]
	cmp eax, r13d
	jne .border_pick_done
	mov r15d, HOTBAR_BORDER_SEL
.border_pick_done:
	; top
	mov edi, r12d
	mov esi, HOTBAR_Y
	mov edx, HOTBAR_SLOT_W
	mov ecx, 1
	mov r8d, r15d
	call fill_rect
	; bottom
	mov edi, r12d
	mov esi, HOTBAR_Y + HOTBAR_SLOT_H - 1
	mov edx, HOTBAR_SLOT_W
	mov ecx, 1
	mov r8d, r15d
	call fill_rect
	; left
	mov edi, r12d
	mov esi, HOTBAR_Y
	mov edx, 1
	mov ecx, HOTBAR_SLOT_H
	mov r8d, r15d
	call fill_rect
	; right
	mov edi, r12d
	add edi, HOTBAR_SLOT_W - 1
	mov esi, HOTBAR_Y
	mov edx, 1
	mov ecx, HOTBAR_SLOT_H
	mov r8d, r15d
	call fill_rect

	; --- number key label "1".."N" in top-left ---
	; build a single-char string on the stack (cheap and avoids
	; needing a string table).. use [rbp-...] slot for it
	; ascii '0' = 0x30,ie digit = '0' + slot+1
	mov al, bl
	add al, '1'			; ebx is 0..N-1, label is "1".."N"
	mov [rbp-8], al
	mov byte [rbp-7], 0
	mov edi, r12d
	add edi, 2
	mov esi, HOTBAR_Y + 2
	mov edx, HOTBAR_NUM_COLOUR
	lea rcx, [rbp-8]
	call debug_print

	; --- tile graphic ---
	; only worth drawing if we own at least one - otherwise slot
	; is just an empty placeholder
	test r14d, r14d
	jz .next_slot

	; resolve item id -> tile id -> atlas slot
	mov eax, r13d
	lea rcx, [item_tile_id]
	movzx eax, byte [rcx + rax]
	lea rcx, [tile_atlas_base]
	movzx eax, byte [rcx + rax]
	; eax = atlas slot.  row = slot / COLS, col = slot % COLS
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx
	; eax = row, edx = col
	mov r10d, edx
	imul r10d, TILE_SIZE	; src_x
	mov r11d, eax
	imul r11d, TILE_SIZE	; src_y

	; centre 16px tile in 20px slot-> +2,+2 from slot origin
	lea rdi, [atlas_tex]
	mov esi, r10d
	mov edx, r11d
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE
	mov r9d, r12d
	add r9d, 2				; dst_x
	mov r10, 0xFFFF00FF		; magenta key
	sub rsp, 8				; pad - 3 pushes would land us at 8mod16
	push r10
	push 0					; flip
	push HOTBAR_Y + 2		; dst_y
	call blit_texture_rect_keyed
	add rsp, 32				; 24 stack args + 8 pad

	; --- count in bottom-right corner ---
	; only show if > 1 (1 is implied by the icon being there)
	cmp r14d, 1
	jle .next_slot
	mov edi, r12d
	add edi, HOTBAR_SLOT_W - 9 ; 8px digit + 1px pad
	mov esi, HOTBAR_Y + HOTBAR_SLOT_H - 9
	mov edx, HOTBAR_NUM_COLOUR
	mov ecx, r14d
	call debug_print_int

.next_slot:
	inc ebx
	jmp .slot_loop
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