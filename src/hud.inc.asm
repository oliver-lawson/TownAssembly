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

%endif
