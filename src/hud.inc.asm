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
	; 6 entries packed at 46px stride to fit on a 320-wide bar
	;	2, 48, 94, 140, 186, 232 - last is pop/cap with 2 numbers
	; HP - icon slot 0
	mov edi, 2
	xor esi, esi
	call hud_blit_icon
	mov edi, 12
	movzx ecx, word [player_hp]
	call hud_print_int

	; wood - icon slot 1
	mov edi, 48
	mov esi, 1
	call hud_blit_icon
	mov edi, 58
	movzx ecx, word [player_res_wood]
	call hud_print_int

	; stone - icon slot 2
	mov edi, 94
	mov esi, 2
	call hud_blit_icon
	mov edi, 104
	movzx ecx, word [player_res_stone]
	call hud_print_int

	; food - icon slot 3
	mov edi, 140
	mov esi, 3
	call hud_blit_icon
	mov edi, 150
	movzx ecx, word [player_res_food]
	call hud_print_int

	; gold - icon slot 4
	mov edi, 186
	mov esi, 4
	call hud_blit_icon
	mov edi, 196
	movzx ecx, word [player_res_gold]
	call hud_print_int

	; housing pop/cap - icon slot 5.  pop = live hero count,
	; cap = sum of room capacities.  HUD reads "3/5" style
	mov edi, 232
	mov esi, 5
	call hud_blit_icon
	mov edi, 242
	call hud_print_housing

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
; hud_print_housing: print "<pop>/<cap>" at (edi, HUD_Y)
;----------------------------------------------------------------
; in:	edi = x
;----------------------------------------------------------------
; stack: rbp frame + rbx + r12 = 24 + sub 48 + ret 8 = 80, aligned.
; the 48-byte locals area holds:
;	[rsp+0..11]		pop value as 12-byte int_to_str buf
;	[rsp+12..23]	cap value as 12-byte int_to_str buf
;	[rsp+24..25]	"/" + null
;	[rsp+32..35]	stashed text colour
;	the int_to_str routine writes right-justified ending at offset
;	+11 of its passed buffer pointer
;================================================================
hud_print_housing:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	sub rsp, 48					; rbp+rbx+r12=24 +48 +ret 8 = 80, aligned

	mov ebx, edi				; starting x

	; --- pop = live hero count ---
	mov edi, ENT_TYPE_HERO
	call count_alive_of_type
	mov r12d, eax				; stash pop

	; --- cap = sum of room capacities ---
	call room_total_capacity
	; eax = cap, r12d = pop

	; pick colour
	mov edx, HUD_TEXT_COLOUR
	cmp r12d, eax
	jle .colour_ok
	mov edx, 0xFFFF6060			; red
.colour_ok:
	mov [rsp + 32], edx			; stash colour for the calls below

	; --- print pop ---
	mov edi, r12d
	lea rsi, [rsp + 0]
	call int_to_str
	; rax = first char of pop's string.  compute digit count heere
	; before debug_print clobbers rax.  null is at rsp+11
	lea rcx, [rsp + 11]
	sub rcx, rax				; rcx = digit count
	imul ecx, DEBUG_GLYPH_W
	mov r12d, ecx ; stash pixel advance (r12 free)
	mov edi, ebx
	mov esi, HUD_Y
	mov edx, [rsp + 32]
	mov rcx, rax
	call debug_print
	add ebx, r12d				; advance ebx

	; --- '/' separator ---
	; build a 2-char string / + null at [rsp + 24]
	mov byte [rsp + 24], '/'
	mov byte [rsp + 25], 0
	mov edi, ebx
	mov esi, HUD_Y
	mov edx, [rsp + 32]
	lea rcx, [rsp + 24]
	call debug_print
	add ebx, DEBUG_GLYPH_W

	; --- print cap ---
	call room_total_capacity
	mov edi, eax
	lea rsi, [rsp + 12]
	call int_to_str
	mov edi, ebx
	mov esi, HUD_Y
	mov edx, [rsp + 32]
	mov rcx, rax
	call debug_print

	add rsp, 48
	pop r12
	pop rbx
	pop rbp
	ret

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