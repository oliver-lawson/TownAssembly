; titlescreen.inc.asm - title/F1 help screen
;
; the world is fully initialised before the main loop starts, so the
; title just sits on top of an already-running sim.  F1 toggles help
; from anywhere (title or playing), SPACE on title starts the game,
; ESC on help returns to whatever opened it
;
;= FUNCTIONS: =======================================================
;	- title_is_playing()				eax=1 if state == GS_PLAYING
;	- title_is_help()					eax=1 if state == GS_HELP
;	- title_handle_input()			  consume one-shot keys per state
;	- title_draw()						draw title or help overlay
;	- draw_text_centred(y,col,ptr)		helper, 1x font
;	- draw_text_2x_centred(y,col,ptr)	helper, 2x scaled font
;====================================================================

%ifndef TITLESCREEN_INC
%define TITLESCREEN_INC
; states
%define GS_TITLE	0
%define GS_HELP		1
%define GS_PLAYING	2

section .data
	game_state			db GS_TITLE;GS_PLAYING
	help_return_state	db GS_TITLE

	; --- title screen text ---
	title_str_big		db "TOWN ASSEMBLY", 0
	title_str_sub		db "", 0
	title_str_start		db "press SPACE to begin", 0
	title_str_help		db "F1 for help", 0
	title_str_quit		db "ESC to quit", 0

	; --- help screen text - keep each under ~36 chars to fit nicely
	help_str_title		db "HOW TO PLAY", 0
	help_str_l01		db "you're a weak doggy", 0
	help_str_l02		db "don't try to fight alone", 0
	help_str_l03		db "build rooms swith beds and chairs to", 0
	help_str_l04		db "attract heroes to fight for you", 0
	help_str_l05		db "WASD/arrows  -  move", 0
	help_str_l06		db "E -  chop, mine, hit", 0
	help_str_l07		db "I -  inventory/craft", 0
	help_str_l08		db "1-6 / wheel - hotbar", 0
	help_str_l09		db "left click  -  place", 0
	help_str_l10		db "     ` - console    ", 0
	help_str_l11		db "F3 hud  F4 iterate world F5 restart", 0
	help_str_l12		db "F6 zone  F7 paths F8 room preview", 0
	help_str_back		db "press F1 to return", 0

section .text
;================================================================
; title_is_playing:
;----------------------------------------------------------------
;out:  eax = 1 if GS_PLAYING, else 0
;================================================================
title_is_playing:
	xor eax, eax
	cmp byte [game_state], GS_PLAYING
	sete al
	ret

;================================================================
; title_is_help:
;----------------------------------------------------------------
;out:  eax = 1 if GS_HELP, else 0
;================================================================
title_is_help:
	xor eax, eax
	cmp byte [game_state], GS_HELP
	sete al
	ret

;================================================================
; title_handle_input: consume one-shot keys from input.inc.asm
;================================================================
title_handle_input:
	push rbp
	mov rbp, rsp

	; --- F1 toggle help ---
	cmp byte [key_help_pressed], 0
	je .no_help
	mov byte [key_help_pressed], 0
	mov al, [game_state]
	cmp al, GS_HELP
	je .help_close
	; opening help - remember the state we came from
	mov [help_return_state], al
	mov byte [game_state], GS_HELP
	jmp .no_help
.help_close:
	mov al, [help_return_state]
	mov [game_state], al
.no_help:

	; --- SPACE: start game (title only) ---
	cmp byte [key_start_pressed], 0
	je .no_start
	mov byte [key_start_pressed], 0
	cmp byte [game_state], GS_TITLE
	jne .no_start
	mov byte [game_state], GS_PLAYING
.no_start:

	pop rbp
	ret

;================================================================
; draw_text_centred: draw a null-terminated string horizontally
;----------------------------------------------------------------
; in:  edi = y, esi = ARGB colour, rdx = string ptr
;================================================================
draw_text_centred:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	sub rsp, 8	; align

	mov r12d, edi		; y
	mov r13d, esi		; colour
	mov rbx, rdx		; str

	mov rdi, rbx
	call strlen_simple	; eax = len in chars

	imul eax, DEBUG_GLYPH_W
	mov ecx, WINDOW_W
	sub ecx, eax
	shr ecx, 1			; ecx = centred x

	mov edi, ecx
	mov esi, r12d
	mov edx, r13d
	mov rcx, rbx
	call debug_print

	add rsp, 8
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; draw_glyph_2x: draw one 8x8 glyph at 2x scale (16x16 pixels)
;----------------------------------------------------------------
; in: edi = x, esi = y, edx = ARGB colour, ecx = char
;================================================================
draw_glyph_2x:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8	; align

	; bail if char out of range
	cmp ecx, font_first_char
	jl .out
	cmp ecx, font_last_char
	jg .out

	sub ecx, font_first_char
	shl ecx, 3		; *8 bytes per glyph
	lea rax, [font_8x8]
	add rax, rcx
	mov rbx, rax	; rbx = glyph row ptr (advances per row)

	mov r12d, edi	; r12 = base x
	mov r13d, esi	; r13 = current y (advances 2px per row)
	mov r14d, edx	; r14 = colour
	mov r15d, 8		; rows remaining
.row:
	movzx eax, byte [rbx]
	test eax, eax
	jz .skip_row

	; walk 8 bits MSB first.  use a free callee-saved-friendly slot:
	; we keep the bit index in r10 since fill_rect doesn't promise it
	; - so we re-set it each row and push/pop around the call
	xor r10d, r10d
.bit_loop:
	cmp r10d, 8
	jge .skip_row
	test eax, 0x80
	jz .nobit
	; save eax + r10 across fill_rect; fill_rect preserves rbx,r12-r15
	push rax
	push r10 
	mov edi, r10d
	shl edi, 1
	add edi, r12d
	mov esi, r13d
	mov edx, 2
	mov ecx, 2
	mov r8d, r14d
	call fill_rect
	pop r10
	pop rax
.nobit:
	shl eax, 1
	inc r10d
	jmp .bit_loop
  
.skip_row:
	inc rbx
	add r13d, 2
	dec r15d
	jnz .row

.out:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; draw_text_2x_centred: draw a string centred at y, 2x scaled
;----------------------------------------------------------------
; in: edi = y, esi = ARGB colour, rdx = string ptr
;================================================================
draw_text_2x_centred:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	sub rsp, 8

	mov r12d, edi	; y
	mov r13d, esi	; colour
	mov rbx, rdx	; str

	mov rdi, rbx
	call strlen_simple
	; 2x font = 16 px wide chars
	imul eax, DEBUG_GLYPH_W * 2
	mov ecx, WINDOW_W
	sub ecx, eax
	shr ecx, 1
	mov r14d, ecx	; r14 = running x cursor

.loop:
	movzx eax, byte [rbx]
	test al, al
	jz .done
	mov edi, r14d
	mov esi, r12d
	mov edx, r13d
	movzx ecx, al
	call draw_glyph_2x
	add r14d, DEBUG_GLYPH_W * 2
	inc rbx
	jmp .loop
.done:
	add rsp, 8
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

;================================================================
; title_draw: render either title or help screen if active.
; no-op when GS_PLAYING
;================================================================
title_draw:
	cmp byte [game_state], GS_PLAYING
	je .out
	cmp byte [game_state], GS_HELP
	je .draw_help
	; fall through to title

;------- title screen:-------
.draw_title:
	xor edi, edi
	xor esi, esi
	mov edx, WINDOW_W
	mov ecx, WINDOW_H
	mov r8d, 0xB0000000
	call fill_rect

	; big title
	mov edi, 40
	mov esi, 0xFFFFC080
	lea rdx, [title_str_big]
	call draw_text_2x_centred

	; subtitle
	mov edi, 80
	mov esi, 0xFFCCCCCC
	lea rdx, [title_str_sub]
	call draw_text_centred

	; main "press space" prompt
	mov eax, [tile_anim_ticks]
	and eax, 32 ; on/off for this many frames 
	jz .skip_start_prompt
	mov edi, 130
	mov esi, 0xFFFFFFFF
	lea rdx, [title_str_start]
	call draw_text_centred
.skip_start_prompt:

	; help + quit hints
	mov edi, 170
	mov esi, 0xFF888888
	lea rdx, [title_str_help]
	call draw_text_centred

	mov edi, 184
	mov esi, 0xFF888888
	lea rdx, [title_str_quit]
	call draw_text_centred
	jmp .out

;------- help screen: -------
.draw_help:
	xor edi, edi
	xor esi, esi
	mov edx, WINDOW_W
	mov ecx, WINDOW_H
	mov r8d, 0xE8000000
	call fill_rect

	mov edi, 12
	mov esi, 0xFFFFC080
	lea rdx, [help_str_title]
	call draw_text_2x_centred

	%define HELP_Y0  44
	%define HELP_DY  10
	%define HELP_COL 0xFFC0C0C0
	%define HELP_CTL 0xFFA080FF

	; instructions
	mov edi, HELP_Y0 + HELP_DY * 0
	mov esi, HELP_COL
	lea rdx, [help_str_l01]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 1
	mov esi, HELP_COL
	lea rdx, [help_str_l02]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 3
	mov esi, HELP_COL
	lea rdx, [help_str_l03]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 4
	mov esi, HELP_COL
	lea rdx, [help_str_l04]
	call draw_text_centred

	; controls
	mov edi, HELP_Y0 + HELP_DY * 6
	mov esi, HELP_CTL
	lea rdx, [help_str_l05]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 7
	mov esi, HELP_CTL
	lea rdx, [help_str_l06]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 8
	mov esi, HELP_CTL
	lea rdx, [help_str_l07]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 9
	mov esi, HELP_CTL
	lea rdx, [help_str_l08]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 10
	mov esi, HELP_CTL
	lea rdx, [help_str_l09]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 11
	mov esi, HELP_CTL
	lea rdx, [help_str_l10]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 12
	mov esi, HELP_CTL
	lea rdx, [help_str_l11]
	call draw_text_centred
	mov edi, HELP_Y0 + HELP_DY * 13
	mov esi, HELP_CTL
	lea rdx, [help_str_l12]
	call draw_text_centred
 
	; footer prompt
	mov edi, WINDOW_H - 14
	mov esi, 0xFFFFFFFF
	lea rdx, [help_str_back]
	call draw_text_centred

.out:
	ret

%endif
