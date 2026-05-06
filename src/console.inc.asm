; console.inc.asm - top-of-screen status line + drop-down console

%ifndef CONSOLE_INC
%define CONSOLE_INC

%define STATUS_TTL_FRAMES	120
%define STATUS_BUF_LEN		LOG_LINE_LENGTH

%define CONSOLE_LINES_VISIBLE 8	; log lines shown above the input line
%define CONSOLE_INPUT_MAX	63	; chars
%define CONSOLE_PANEL_H	(DEBUG_GLYPH_H*(CONSOLE_LINES_VISIBLE+1)+6)

section .data
	; --- command names (also shown by 'help') ---
	cmd_name_restart	db "restart", 0
	cmd_name_hud		db "hud", 0
	cmd_name_quit		db "quit", 0
	cmd_name_set		db "set", 0
	cmd_name_help		db "help", 0

	; command table: pairs of (name_ptr, handler_ptr),NULL-terminated
	; the order is the order 'help' lists them in
	align 8
	cmd_table:
		dq cmd_name_help,		cmd_handler_help_fn
		dq cmd_name_restart,	cmd_handler_restart_fn
		dq cmd_name_hud,		cmd_handler_hud_fn
		dq cmd_name_set,		cmd_handler_set_fn
		dq cmd_name_quit,		cmd_handler_quit_fn
		dq 0, 0	; sentinel

	; set <field> <value> field table:(name,ptr,max),NULL-terminated
	; all fields are u16 atm so no need of size column..yet
	; refs to player_* in main.asm should resolve at assemble time
	set_field_hp		db "hp", 0
	set_field_hp_max	db "hp_max", 0
	set_field_wood		db "wood", 0
	set_field_stone		db "stone", 0
	set_field_food		db "food", 0
	set_field_gold		db "gold", 0

	align 8
	set_field_table:
		dq set_field_hp,		player_hp,			9999
		dq set_field_hp_max,	player_hp_max,		9999
		dq set_field_wood,		player_res_wood,	9999
		dq set_field_stone,		player_res_stone,	9999
		dq set_field_food,		player_res_food,	9999
		dq set_field_gold,		player_res_gold,	9999
		dq 0, 0, 0	; sentinel

	cmd_unknown_msg		db "unknown command", 0
	cmd_help_header		db "commands:", 0
	cmd_set_usage		db "usage: set [field] [value]", 0
	cmd_set_unknown		db "unknown field", 0
	cmd_set_bad_value	db "bad value", 0
	cmd_prompt			db "> ", 0
	cmd_help_hint		db "type help for commands", 0

section .bss
	alignb 4
	; status
	status_active		resb 1
	alignb 2
	status_ttl			resw 1
	status_buf			resb STATUS_BUF_LEN

	; console
	console_open		resb 1
	; set after we've shown the "type help" hint once
	; bss zero-init means it prompts on first open!
	console_help_shown	resb 1
	alignb 4
	console_input_len	resd 1
	console_input_buf	resb CONSOLE_INPUT_MAX + 1

	; scratch buffer used by 'set' to log "ok: wood = 12" etc
	console_log_scratch resb 64

section .text

;================================================================
; status_set: copy string into the status slot and reset its TTL
; called from debug_log so any logged line shows at the top
;----------------------------------------------------------------
; in: rdi = src null-terminated string
;================================================================
status_set:
	mov rsi, rdi
	lea rdi, [status_buf]
	mov ecx, STATUS_BUF_LEN - 1
.cp:
	test ecx, ecx
	jz .cp_done
	movzx eax, byte [rsi]
	mov [rdi], al
	test al, al
	jz .cp_done
	inc rsi
	inc rdi
	dec ecx
	jmp .cp
.cp_done:
	mov byte [rdi], 0
	mov word [status_ttl], STATUS_TTL_FRAMES
	mov byte [status_active], 1
	ret

; status_tick: countdown + expire, called per frame in main.asm
status_tick:
	cmp byte [status_active], 0
	je .out
	movzx eax, word [status_ttl]
	test eax, eax
	jz .expire
	dec eax
	mov word [status_ttl], ax
	ret
.expire:
	mov byte [status_active], 0
.out:
	ret

;================================================================
; status_draw: draw at top-left, modulated by ttl
;----------------------------------------------------------------
; skipped if console open
;================================================================
status_draw:
	cmp byte [console_open], 0
	jne .out
	cmp byte [status_active], 0
	je .out

	; intensity = ttl * 255 / TTL -> 0..255
	movzx eax, word [status_ttl]
	imul eax, 255
	mov ecx, STATUS_TTL_FRAMES
	xor edx, edx
	div ecx
	; build greyscale colour 0xFF<aa><aa><aa>
	mov ecx, eax
	mov edx, eax
	shl edx, 8
	or ecx, edx
	mov edx, eax
	shl edx, 16
	or ecx, edx
	or ecx, 0xFF000000

	mov edi, 4		; x
	mov esi, 4		; y (top of screen, 4px margin)
	mov edx, ecx	; colour
	lea rcx, [status_buf]
	call debug_print
.out:
	ret

;================================================================
; console_is_open: rets 1 or 0
;----------------------------------------------------------------
; main.asm checks this to suspend player movement/action handling
;================================================================
console_is_open:
	movzx eax, byte [console_open]
	ret

;================================================================
; console_toggle: open <-> close
;----------------------------------------------------------------
; on open, enables SDL text input & clears any previous input
; on close, disables text input
;================================================================
console_toggle:
	push rbp
	mov rbp, rsp
	mov al, [console_open]
	xor al, 1
	mov [console_open], al
	test al, al
	jz .close
	; opening: clear input, start text input
	mov dword [console_input_len], 0
	mov byte [console_input_buf], 0
	call SDL_StartTextInput
	; show the help hint on the very first open
	cmp byte [console_help_shown], 0
	jne .out
	mov byte [console_help_shown], 1
	lea rdi, [cmd_help_hint]
	mov esi, 0xFFFFD060 ; colour
	call debug_log_col
	jmp .out
.close:
	call SDL_StopTextInput
.out:
	pop rbp
	ret

;================================================================
; console_handle_text:
;----------------------------------------------------------------
; appends UTF-8 bytes from an SDL_TEXTINPUT event to the input
; buffer.  filters out `
;----------------------------------------------------------------
; in: rdi = pointer to UTF-8 bytes (null-terminated, max 32)
;================================================================
console_handle_text:
	cmp byte [console_open], 0
	jne .open
	; closed - nothing to do.. don't jmp into .out, ecx is uninit
	; here and .out would write console_input_buf[ecx] = 0 with garbage.. learnt this the hard way!
	ret
.open:
	mov rsi, rdi
	mov ecx, [console_input_len]
.loop:
	movzx eax, byte [rsi]
	test al, al
	jz .out
	cmp al, '`'
	je .skip
	cmp ecx, CONSOLE_INPUT_MAX
	jge .out	; buffer full
	lea rdi, [console_input_buf]
	mov [rdi + rcx], al
	inc ecx
.skip:
	inc rsi
	jmp .loop
.out:
	mov [console_input_len], ecx
	; ensure null terminator after the last typed byte
	lea rdi, [console_input_buf]
	mov byte [rdi + rcx], 0
	ret

;================================================================
; console_backspace: pops the last char from the input buffer
;================================================================
console_backspace:
	cmp byte [console_open], 0
	je .out
	mov ecx, [console_input_len]
	test ecx, ecx
	jz .out
	dec ecx
	mov [console_input_len], ecx
	lea rdi, [console_input_buf]
	mov byte [rdi + rcx], 0
.out:
	ret

; ---------- utiliies ----------

;================================================================
; skip_ws: advance rdi past any space/tab characters
;----------------------------------------------------------------
; in/out: rdi
;================================================================
skip_ws:
.loop:
	mov al, [rdi]
	cmp al, ' '
	je .step
	cmp al, 9 ; tab
	je .step
	ret
.step:
	inc rdi
	jmp .loop

;================================================================
; word_match: is rsi (a c-string) a prefix of rdi (input), with rdi's
; next char being a word boundary (null/space/tab)?
;----------------------------------------------------------------
; in:  rdi = input string, rsi = candidate command name
; out: eax = 1 on match, 0 otherwise
;	if matched, rdi is left pointing at the char after the match
;	(still inside the input).  on miss rdi is preserved
;================================================================
word_match:
	push rdi
	push rsi
.loop:
	mov al, [rsi]
	test al, al
	jz .at_end	; candidate exhausted - check boundary
	mov cl, [rdi]
	cmp al, cl
	jne .neq
	inc rdi
	inc rsi
	jmp .loop
.at_end:
	mov al, [rdi]
	test al, al
	jz .ok
	cmp al, ' '
	je .ok
	cmp al, 9
	je .ok
	; longer input -> no match
.neq:
	pop rsi
	pop rdi
	xor eax, eax
	ret
.ok:
	add rsp, 16	; drop saved rdi/rsi..(we keep advanced rdi)
	mov eax, 1
	ret

;================================================================
; atoi_word:parse a positive decimal num from rdi until 1st non-digit
;----------------------------------------------------------------
; on success returns eax = value, sets cl != 0
; on no digits at all, sets cl = 0
;----------------------------------------------------------------
; in: rdi = ptr (modified)
;out: eax = parsed value, cl= 1 ok / 0 fail; rdi advanced past digits
;================================================================
atoi_word:
	xor eax, eax
	xor ecx, ecx ; ecx= "saw at least one digit"
.loop:
	movzx edx, byte [rdi]
	cmp dl, '0'
	jl .done
	cmp dl, '9'
	jg .done
	sub edx, '0'
	imul eax, eax, 10
	add eax, edx
	mov ecx, 1
	inc rdi
	jmp .loop
.done:
	ret

;================================================================
; console_submit: parse + dispatch the input
;----------------------------------------------------------------
;	- skip leading whitespace
;	- walk cmd_table; first matching name wins
;	- call its handler with rdi pointing at the args
;	- log "unknown command" if nothing matched
; clears the input regardless
;================================================================
console_submit:
	push rbx
	push r12
	; 2 callee saves + ret = 24 -> rsp%16 = 8
	; add a pad so calls inside align
	sub rsp, 8
	cmp dword [console_input_len], 0
	je .clear

	lea rdi, [console_input_buf]
	call skip_ws
	cmp byte [rdi], 0
	je .clear 

	mov r12, rdi	; r12 = ptr to first non-ws char of input

	lea rbx, [cmd_table]
.scan:
	mov rsi, [rbx]	; name
	test rsi, rsi
	jz .unknown
	mov rdi, r12
	call word_match
	test eax, eax
	jnz .matched
	add rbx,16
	jmp .scan

.matched:
	; advance r12 past command name, then args = r12 after skip_ws
	mov rsi, [rbx]
.skip_name:
	mov al, [rsi]
	test al, al
	jz .name_done
	inc r12
	inc rsi
	jmp .skip_name
.name_done:
	mov rdi, r12
	call skip_ws
	; rdi now points at the args (or null terminator), dispatch!
	mov rax, [rbx + 8]
	call rax

.clear:
	mov dword [console_input_len], 0
	mov byte [console_input_buf], 0
	add rsp, 8
	pop r12
	pop rbx
	ret

.unknown:
	lea rdi, [cmd_unknown_msg]
	call debug_log
	jmp .clear

;================================================================
; built-in command handlers. all take rdi = args ptr (may be empty)
;================================================================

; restart
cmd_handler_restart_fn:
	jmp restart_world

; hud
cmd_handler_hud_fn:
	jmp debug_toggle

; quit
cmd_handler_quit_fn:
	mov byte [key_quit], 1
	ret

; help - list all commands available
cmd_handler_help_fn:
	push rbx
	; header
	lea rdi, [cmd_help_header]
	mov esi, 0xFFFFD060
	call debug_log_col
	lea rbx, [cmd_table]
.loop:
	mov rdi, [rbx]
	test rdi, rdi
	jz .done
	; each command name
	mov esi, 0xFF80D0FF
	call debug_log_col
	add rbx, 16
	jmp .loop
.done:
	pop rbx
	ret

; set <field> <value>
cmd_handler_set_fn:
	push rbx
	push r12
	push r13
	; rdi = args, parse field name first
	call skip_ws
	cmp byte [rdi], 0
	je .usage

	; remember start of field name 
	mov r12, rdi

	; walk the set_field_table looking for a word match against rdi
	lea rbx, [set_field_table]
.scan:
	mov rsi, [rbx]
	test rsi, rsi
	jz .unknown_field
	mov rdi, r12
	call word_match
	test eax, eax
	jnz .matched_field
	add rbx, 24		; next row (24 bytes per row)
	jmp .scan

.matched_field:
	; rdi now points just past the matched name,
	; skip whitespace, parse value
	call skip_ws
	cmp byte [rdi], 0
	je .usage
	call atoi_word
	test cl, cl
	jz .bad_value
	mov r13d, eax 		; r13 = value
	; clamp to max
	mov eax, [rbx + 16]	; max
	cmp r13d, eax
	jle .ok_value
	mov r13d, eax
.ok_value:
	mov rax, [rbx + 8]	; field ptr
	mov [rax], r13w		; write u16
	; log "ok: <name> = <value>"
	mov rsi, [rbx]
	call cmd_log_set_ok
	jmp .done

.usage:
	lea rdi, [cmd_set_usage]
	call debug_log
	jmp .done
.unknown_field:
	lea rdi, [cmd_set_unknown]
	call debug_log
	jmp .done
.bad_value:
	lea rdi, [cmd_set_bad_value]
	call debug_log
.done:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; cmd_log_set_ok:
;----------------------------------------------------------------
; "ok: <name> = <value>" into scratch buffer and emit via debug_log
;----------------------------------------------------------------
; in: rsi = field name string ptr, r13d = value (caller already has
; it in r13, which is callee-saved so don't need to stash)
;================================================================
cmd_log_set_ok:
	push rbx
	push r12
	push r14		; alignment pad (3 pushes -> aligned)
	mov r12, rsi	; save name ptr

	lea rbx, [console_log_scratch]
	; "ok: "
	mov byte [rbx + 0], 'o'
	mov byte [rbx + 1], 'k'
	mov byte [rbx + 2], ':'
	mov byte [rbx + 3], ' '
	add rbx, 4

	; copy field name
	mov rsi, r12
.cp_name:
	mov al, [rsi]
	test al, al
	jz .cp_name_done
	mov [rbx], al
	inc rbx
	inc rsi
	jmp .cp_name
.cp_name_done:
	; " = "
	mov byte [rbx + 0], ' '
	mov byte [rbx + 1], '='
	mov byte [rbx + 2], ' '
	add rbx, 3

	; convert r13 (value) to ascii via int_to_str
	mov edi, r13d
	lea rsi, [int_buf]
	call int_to_str

	; copy ascii into the scratch
.cp_num:
	mov cl, [rax]
	test cl, cl
	jz .cp_num_done
	mov [rbx], cl
	inc rbx
	inc rax
	jmp .cp_num
.cp_num_done:
	mov byte [rbx], 0

	lea rdi, [console_log_scratch]
	call debug_log
	pop r14
	pop r12
	pop rbx
	ret

; console_draw - actual rendering of it all (when opened)
console_draw:
	cmp byte [console_open], 0
	je .out
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee saves + ret = 48 -> aligned

	; -- bg panel --
	xor edi, edi
	xor esi, esi
	mov edx, WINDOW_W
	mov ecx, CONSOLE_PANEL_H
	mov r8d, 0xB3000000	; translucent black
	call fill_rect
	; 1px bottom edge border
	xor edi, edi
	mov esi, CONSOLE_PANEL_H-1
	mov edx, WINDOW_W
	mov ecx, 1
	mov r8d, 0xFF606060
	call fill_rect

	; --- log lines ---
	; show the last CONSOLE_LINES_VISIBLE entries from log buffer
	mov r12d, [log_count]
	; cap visile count
	cmp r12d, CONSOLE_LINES_VISIBLE
	jle .have_count
	mov r12d, CONSOLE_LINES_VISIBLE
.have_count:
	test r12d, r12d
	jz .skip_log

	; first slot to render = (head - r12 + LOG_LINES) % LOG_LINES
	mov eax, [log_head]
	sub eax, r12d
	add eax, LOG_LINES
	xor edx, edx
	mov ecx, LOG_LINES
	div ecx
	mov r13d, edx	; r13 = current slot
	mov r14d, 3		; y starts a few px below top
	mov r15d, r12d	; remaining lines
.line:
	test r15d, r15d
	jz .skip_log

	mov eax, r13d
	mov ecx, LOG_LINE_LENGTH
	mul ecx
	lea rbx, [log_buffer]
	add rbx, rax

	; pick up colour for this slot from the parallel array
	lea rax, [log_colors]
	mov edx, [rax + r13*4]

	mov edi, 4
	mov esi, r14d
	mov rcx, rbx
	call debug_print

	add r14d, DEBUG_GLYPH_H
	inc r13d
	cmp r13d, LOG_LINES
	jl .no_wrap
	xor r13d, r13d
.no_wrap:
	dec r15d
	jmp .line
.skip_log:

	; --- input line: "> typed" with a blinking cursor ---
	mov edi, 4
	mov esi, CONSOLE_PANEL_H - DEBUG_GLYPH_H - 3
	mov edx, 0xFFFFFFFF
	lea rcx, [cmd_prompt]
	call debug_print
	; typed text starts after the "> " prompt (16 px in)
	mov edi, 4 + 2 * DEBUG_GLYPH_H
	mov esi, CONSOLE_PANEL_H - DEBUG_GLYPH_H - 3
	mov edx, 0xFFFFFFFF
	lea rcx, [console_input_buf]
	call debug_print 

	; cursor block (using tile anim ticker TEMP)
	mov eax, [tile_anim_ticks]
	and eax, 32	; on for 32 frames, off for 32
	jz .no_cursor
	mov edi, 4 + 2 * DEBUG_GLYPH_H
	mov eax, [console_input_len]
	imul eax, DEBUG_GLYPH_W
	add edi, eax
	mov esi, CONSOLE_PANEL_H - DEBUG_GLYPH_H - 3
	mov edx, DEBUG_GLYPH_W
	mov ecx, DEBUG_GLYPH_H
	mov r8d, 0xFFFFFFFF
	call fill_rect
.no_cursor:

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
.out:
	ret

%endif