; input.inc.asm - SDL event polling and one-shot key dispatch
;----------------------------------------------------------------
; process_sdl_events drains the SDL queue once a frame, latching
; one-shot flags and forwarding text/keys to the console as needed.
; dispatch_input consumes those latched flags (and the mouse wheel)
; in a defined order, so the main loop body stays slim
;----------------------------------------------------------------
; sustained vs one-shot:
;	one-shot = keys whose key_*_pressed flag is set on keydown
;			   and cleared after the consumer fires once
;	sustained = polled via SDL_GetKeyboardState in the place it
;			    matters (eg update_player_input)
%ifndef INPUT_INC
%define INPUT_INC

section .data
	log_msg_itered		db "iterated cellular automata", 0
	log_msg_hud_toggles	db "hud toggled", 0

section .bss
	; input state - one shots, set in process_sdl_events
	; cleared in dispatch_input as they fire
	key_quit			resb 1
	key_toggle_pressed	resb 1
	key_iterateworld_pressed resb 1
	key_restart_pressed	resb 1
	key_action_pressed	resb 1
	key_inv_pressed		resb 1
	key_close_pressed	resb 1
	key_bloom_pressed	resb 1	; F2: toggle bloom post-fx
	key_safezone_pressed	resb 1	; F6: toggle safezone debug overlay
	key_pathing_pressed		resb 1	; F7: toggle flow-field debug overlay
	key_rooms_pressed		resb 1	; F8: toggle room debug overlay
	; F1 toggles the help screen, SPACE starts the game from the title.
	; both consumed by title_handle_input rather than dispatch_input
	key_help_pressed	resb 1
	key_start_pressed	resb 1
	; hotbar select: 0 means nothing pressed, otherwise the digit
	; pressed (1..N).  cleared after consumed
	key_hotbar_digit	resb 1

	alignb 8
	event_buf			resb SDL_EVENT_SIZE

section .text

;================================================================
; process_sdl_events: drain SDL queue, update one-shot flags
;----------------------------------------------------------------
; called once at the top of every frame
;================================================================
process_sdl_events:
	push rbp
	mov rbp, rsp
.poll:
	lea rdi, [event_buf]
	call SDL_PollEvent
	test eax, eax
	jz .done				; queue empty

	mov eax, [event_buf + SDL_EVENT_TYPE_OFF]
	cmp eax, SDL_QUIT_EVENT
	je .got_quit
	cmp eax, SDL_KEYDOWN_EVENT
	je .got_keydown
	cmp eax, SDL_TEXTINPUT_EVENT
	je .got_textinput
	cmp eax, SDL_MOUSEBUTTONDOWN
	je .got_mousedown
	cmp eax, SDL_MOUSEWHEEL_EVENT
	je .got_mousewheel
	jmp .poll

.got_quit:
	mov byte [key_quit], 1
	jmp .poll

.got_textinput:
	; SDL hands us already-shifted UTF-8 in event.text.text. when the
	; console isn't open this is harmless (console_handle_text checks
	; first)
	lea rdi, [event_buf + SDL_EVENT_TEXT_OFF]
	call console_handle_text
	jmp .poll

.got_keydown:
	mov eax, [event_buf + SDL_EVENT_SCANCODE_OFF]
	cmp eax, SCANCODE_ESCAPE	; TMP - too easy to press w/ console open
	je .key_escape				; TMP
	; backtick toggles the console regardless of state, and matches
	; before anything else so it can close the console mid-typing
	cmp eax, SCANCODE_BACKTICK
	je .key_backtick
	; if console is open, route enter/backspace to it/eat everything
	; else (so movement/action keys don't fire while typing)
	cmp byte [console_open], 0
	je .console_closed_keys
	cmp eax, SCANCODE_RETURN
	je .key_return
	cmp eax, SCANCODE_BACKSPACE
	je .key_backspace
	jmp .poll
.console_closed_keys:
	cmp eax, SCANCODE_F1
	je .key_f1
	cmp eax, SCANCODE_SPACE
	je .key_space
	cmp eax, SCANCODE_F2
	je .key_f2
	cmp eax, SCANCODE_F3
	je .key_f3
	cmp eax, SCANCODE_F4
	je .key_f4
	cmp eax, SCANCODE_F5
	je .key_f5
	cmp eax, SCANCODE_F6
	je .key_f6
	cmp eax, SCANCODE_F7
	je .key_f7
	cmp eax, SCANCODE_F8
	je .key_f8
	cmp eax, SCANCODE_E
	je .key_e
	cmp eax, SCANCODE_I
	je .key_i
	cmp eax, SCANCODE_Q
	je .key_q
	; SDL has SCANCODE_1..9 as 30..38 (contiguous), pick up the whole
	; range and stash the digit (1..9) for the hotbar to consume
	cmp eax, SCANCODE_1
	jl .poll
	cmp eax, SCANCODE_9
	jg .poll
	sub eax, SCANCODE_1 - 1		; 30 -> 1, 38 -> 9
	mov byte [key_hotbar_digit], al
	jmp .poll

.key_escape:	; TMP - too easy to press when console open
	mov byte [key_quit], 1
	jmp .poll
.key_f1:
	mov byte [key_help_pressed], 1
	jmp .poll
.key_f2:
	mov byte [key_bloom_pressed], 1
	jmp .poll
.key_space:
	mov byte [key_start_pressed], 1
	jmp .poll
.key_f3:
	mov byte [key_toggle_pressed], 1
	jmp .poll
.key_f4:
	mov byte [key_iterateworld_pressed], 1
	jmp .poll
.key_f5:
	mov byte [key_restart_pressed], 1
	jmp .poll
.key_f6:
	mov byte [key_safezone_pressed], 1
	jmp .poll
.key_f7:
	mov byte [key_pathing_pressed], 1
	jmp .poll
.key_f8:
	mov byte [key_rooms_pressed], 1
	jmp .poll
.key_e:
	mov byte [key_action_pressed], 1
	jmp .poll
.key_i:
	mov byte [key_inv_pressed], 1
	jmp .poll
.key_q:
	mov byte [key_close_pressed], 1
	jmp .poll
.key_backtick:
	call console_toggle
	jmp .poll
.key_return:
	call console_submit
	jmp .poll
.key_backspace:
	call console_backspace
	jmp .poll

.got_mousedown:
	; SDL_MouseButtonEvent has button index at offset 16 (Uint8)
	; 1=left, 3=right.  middle ignored atm
	movzx eax, byte [event_buf + 16]
	cmp eax, SDL_BUTTON_LEFT
	je .mb_left
	cmp eax, SDL_BUTTON_RIGHT
	je .mb_right
	jmp .poll
.mb_left:
	mov byte [mouse_l_clicked], 1
	jmp .poll
.mb_right:
	mov byte [mouse_r_clicked], 1
	jmp .poll

.got_mousewheel:
	; SDL_MouseWheelEvent.y at offset 20, Sint32.  positive = wheel
	; rolled up (away from user), negative = down.  we accumulate so
	; a fast spin doesn't lose ticks - the main loop reads the sign
	; and resets to 0
	mov eax, [event_buf + SDL_EVENT_WHEEL_Y_OFF]
	add [mouse_wheel_dy], eax
	jmp .poll

.done:
	pop rbp
	ret

;================================================================
; dispatch_input: consume all one-shot flags + mouse wheel/clicks
; in a defined order, after process_sdl_events has run
;----------------------------------------------------------------
; order matters!: inventory toggle is checked before action so
; pressing I + E together doesn't trigger both
; hotbar digits and wheel are ignored when the inventory is open
;================================================================
dispatch_input:
	push rbp
	mov rbp, rsp

	; --- F2: toggle bloom ---
	cmp byte [key_bloom_pressed], 0
	je .no_bloom
	mov byte [key_bloom_pressed], 0
	call bloom_toggle
.no_bloom:

	; --- F4: iterate worldgen CA ---
	cmp byte [key_iterateworld_pressed], 0
	je .no_iterateworld
	mov byte [key_iterateworld_pressed], 0
	call iterate_world
	lea rdi, [log_msg_itered]
	call debug_log
.no_iterateworld:

	; --- F5: restart game ---
	cmp byte [key_restart_pressed], 0
	je .no_restart
	mov byte [key_restart_pressed], 0
	call restart_world
.no_restart:

	; --- F3: toggle debug HUD ---
	cmp byte [key_toggle_pressed], 0
	je .no_toggle
	mov byte [key_toggle_pressed], 0
	call debug_toggle
	lea rdi, [log_msg_hud_toggles]
	call debug_log
.no_toggle:

	; --- F6: toggle safezone debug overlay ---
	cmp byte [key_safezone_pressed], 0
	je .no_safezone
	mov byte [key_safezone_pressed], 0
	call safezone_toggle_debug
.no_safezone:

	; --- F7: toggle flow-field debug overlay ---
	cmp byte [key_pathing_pressed], 0
	je .no_pathing
	mov byte [key_pathing_pressed], 0
	call pathing_toggle_debug
.no_pathing:

	; --- F8: toggle room debug overlay ---
	cmp byte [key_rooms_pressed], 0
	je .no_rooms
	mov byte [key_rooms_pressed], 0
	call rooms_toggle_debug
.no_rooms:

	; --- I: toggle inventory screen ---
	; handled before action to avoid clash
	cmp byte [key_inv_pressed], 0
	je .no_inv
	mov byte [key_inv_pressed], 0
	call inv_toggle
.no_inv:

	; --- hotbar digit (1..9) ---
	; ignored if the inventory is open so 1..9 typing in the console
	; doesn't trigger placement
	movzx eax, byte [key_hotbar_digit]
	test eax, eax
	jz .no_hotbar_digit
	; consume the one-shot before any calls clobber regs
	mov byte [key_hotbar_digit], 0
	push rax					; stash the digit
	call inv_is_open
	pop rcx						; rcx = the digit
	test eax, eax
	jnz .no_hotbar_digit		; inv up - drop the press
	; map digit (1..N) -> ITEM_* (1..ITEM_COUNT-1).  hotbar slot n
	; == item id n, simple as that for now
	mov al, cl
	call hotbar_set_select
.no_hotbar_digit:

	; --- mouse wheel: cycle hotbar selection ---
	; consumed once per frame, sign-only
	mov eax, [mouse_wheel_dy]
	test eax, eax
	jz .no_wheel
	mov dword [mouse_wheel_dy], 0
	push rax
	call inv_is_open
	pop rcx
	test eax, eax
	jnz .no_wheel				; inv might want it later
	mov edi, ecx
	call hotbar_cycle
.no_wheel:

	; --- Q: close inventory if open, else cancel placement ---
	cmp byte [key_close_pressed], 0
	je .no_close
	mov byte [key_close_pressed], 0
	call inv_is_open
	test eax, eax
	jz .close_try_place
	call inv_toggle 	; close inventory
	jmp .no_close
.close_try_place:
	call place_is_active
	test eax, eax
	jz .no_close
	call place_cancel
.no_close:

	; --- E: gather/kill the tile or mob in front ---
	; eaten by inventory (mouse-driven), also eaten in placement mode
	; (placement is mouse-driven too)
	cmp byte [key_action_pressed], 0
	je .no_action
	mov byte [key_action_pressed], 0
	call inv_is_open
	test eax, eax
	jnz .no_action
	call place_is_active
	test eax, eax
	jnz .no_action
	call try_player_action
.no_action:

	pop rbp
	ret

%endif
