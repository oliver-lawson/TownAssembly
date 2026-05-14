; fps.inc.asm - rolling frames-per-second counter, sampled every
; 500ms.  the main loop calls fps_tick once per frame and reads
; current_fps when it wants to display
%ifndef FPS_INC
%define FPS_INC

section .bss
	alignb 4
	frame_count			resd 1
	last_fps_ticks		resd 1	; SDL_GetTicks @ last sample
	last_fps_frame		resd 1	; frame_count @ last sample
	current_fps			resd 1	; final computed fps for display

section .text

;================================================================
; fps_init: grab the starting tick count for our first sample
; window.  call once, after SDL is up
;================================================================
fps_init:
	call SDL_GetTicks
	mov [last_fps_ticks], eax
	ret

;================================================================
; fps_tick: bump frame_count, recompute current_fps every 500ms
;----------------------------------------------------------------
; sampling every 500ms and scaling up.  C equiv:
;	uint32_t now = SDL_GetTicks();
;	uint32_t elapsed = now - last_fps_ticks;
;	if (elapsed >= 500) {
;		uint32_t frames = frame_count - last_fps_frame;
;		current_fps = frames * 1000 / elapsed;
;		last_fps_ticks = now;
;		last_fps_frame = frame_count;
;	}
;	frame_count++;
;================================================================
fps_tick:
	call SDL_GetTicks
	mov ecx, eax				; ecx = now
	mov r11d, ecx
	sub r11d, [last_fps_ticks]	; r11d = elapsed ms
	cmp r11d, 500
	jl .skip
	; enough time has passed - compute fps
	mov eax, [frame_count]
	sub eax, [last_fps_frame]	; eax = frames since last sample
	imul eax, 1000				; scale to per-second
	xor edx, edx
	div r11d					; eax = fps
	mov [current_fps], eax
	mov [last_fps_ticks], ecx	; reset sample window
	mov eax, [frame_count]
	mov [last_fps_frame], eax
.skip:
	inc dword [frame_count]
	ret

%endif
