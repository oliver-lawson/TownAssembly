; framebuffer.inc.asm - cpu-side pixel buffer for our window
;
; flat array of 32-bit ARGB pixels laid out row-by-row
; in memory. pixel at x,y lives @ bytes offset:
;               (y * FB_WIDTH + x) * 4
;
; we write to this from our rendering code each frame, then
; SDL_UpdateTexture uploads it to GPU

%ifndef FRAMEBUFFER_INC
%define FRAMEBUFFER_INC

; TODO: extract from main.asm

%endif
