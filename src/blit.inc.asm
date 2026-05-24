; blit.inc.asm - for copying rects to FB
; 
; the main workhorse for tile drawing
; 
; copy an axis-aligned rect from a texture into the fb
; no rotation/filtering/UV interp, just fast rect-to-rect copy
;
; should be much faster for our tilemaps than going thrrough
; sample_texture pixel by pixel bc no need for fixed-point mult/idiv
; shenanigans per texel, just memcpy per row
;
; clipping: dest coords are clipped to fb bounds so we can blit
; partially offscreen tiles (hopefully).  source coords ASSUMED VALID

%ifndef BLIT_INC
%define BLIT_INC

section .text
;================================================================
; blit_texture_rect: copy a rect from texture to framebuffer
;----------------------------------------------------------------
; C equiv:
; void blit_texture_rect( tex_struct *tex,
;						  int src_x, int src_y,
;						  int src_w, int src_h,
;						  int dst_x, int dst_y) {
;	// clip dst to screen, adjusting src to match
;	if (dst_x < 0) { src_x -= dst_x; src_w += dst_x; dst_x = 0; }
;	if (dst_y < 0) { src_y -= dst_y; src_h += dst_y; dst_y = 0; }
;	if (dst_x + src_w > WINDOW_W) src_w = WINDOW_W  - dst_x;
;	if (dst_y + src_h > WINDOW_H) src_h = WINDOW_H - dst_y;
;	if (src_w <= 0 || src_h <= 0) return;
;
;	uint32_t *src = tex->pixels + src_y * tex->width + src_x;
;	uint32_t *dst = framebuffer + dst_y * WINDOW_W + dst_x;
;	for (int row = 0; row < src_h; row++) {
;		memcpy(dst, src, src_w * 4);
;		src += tex->width;
;		dst += WINDOW_W;
;		}
;   }
;----------------------------------------------------------------
; in's:
;----------------------------------------------------------------
; rdi |  tex_ptr	(ptr to texture struct - see texture.inc.asm)
; esi |  src_x	(texel x in source texture)
; edx |  src_y	(texel y in source texture)
; ecx |  src_w	(width in texels)
; r8d |  src_h	(height in texels)
; r9d |  dst_x	(pixel x on framebuffer)
; [rsp+8] | dst_y	(pixel y on fb - on stack cos no more regs)
;================================================================
blit_texture_rect:
	push rbp
	mov rbp, rsp
	sub rsp, 64
	push rbx
	push r12
	push r13
	push r14
	push r15

	; stash all args into stack locals so we can modify them
	; during clipping without losing the originals
	;	[rbp-4]  src_x	[rbp-8]  src_y
	;	[rbp-12] src_w	[rbp-16] src_h
	;	[rbp-20] dst_x	[rbp-24] dst_y
	;	[rbp-32] tex_ptr (qword, aligned)
	mov [rbp-4],  esi
	mov [rbp-8],  edx
	mov [rbp-12], ecx
	mov [rbp-16], r8d
	mov [rbp-20], r9d
	; dst_y was passed on the stack. before our prologue it was at
	; [rsp+8] (above ret addr). after push rbp + sub rsp,64 + 5
	; pushes (40 bytes), it's at [rbp+16] (caller's [rsp+8] relative
	; to original rsp, which is rbp+8, so caller's [rsp+8] = [rbp+16])
	mov eax, [rbp+16]
	mov [rbp-24], eax
	mov [rbp-32], rdi			; save tex ptr

	; --- clip left edge ---
	; if dst_x<0, the tile starts offscreen to the left
	; skip the first -dst_x columns of the source rect and shrink
	; the width by the same amount
	mov eax, [rbp-20]		; dst_x
	test eax, eax
	jns .no_clip_left
	;add [rbp-4], eax		; src_x += dst_x (negative, shifts right)
	; ^bug! oops, never caused a crash bc we didn't have cameras
	sub [rbp-4], eax ; src_x -= dst_x (dst_x is -ve, so src_x grows)
	add [rbp-12], eax		; src_w += dst_x (shrinks width)
	mov dword [rbp-20], 0	; dst_x = 0
.no_clip_left:
	; --- clip top edge ---
	mov eax, [rbp-24]		; dst_y
	test eax, eax
	jns .no_clip_top
	sub [rbp-8], eax		; src_y -= dst_y
	add [rbp-16], eax		; src_h += dst_y
	mov dword [rbp-24], 0
.no_clip_top:
	; --- clip right edge ---
	; if dst_x + w > WINDOW_W, clamp w so we don't write past the edge.
	mov eax, [rbp-20]
	add eax, [rbp-12]		; eax = dst_x + src_w
	cmp eax, WINDOW_W
	jle .no_clip_right
	mov eax, WINDOW_W
	sub eax, [rbp-20]		; eax = WINDOW_W - dst_x
	mov [rbp-12], eax		; src_w = clamped width
.no_clip_right:
	; --- clip bottom edge ---
	mov eax, [rbp-24]
	add eax, [rbp-16]
	cmp eax, WINDOW_H
	jle .no_clip_bottom
	mov eax, WINDOW_H
	sub eax, [rbp-24]
	mov [rbp-16], eax
.no_clip_bottom:
	; after clipping; can leave if nothing left to draw
	cmp dword [rbp-12], 0
	jle .done
	cmp dword [rbp-16], 0
	jle .done

	; --- set up pointers for the copy loop ---

	; load tex fields once - we use W twice (initial offset + pitch)
	mov rbx, [rbp-32]		; tex ptr
	mov r15d, [rbx + TEX_WIDTH_OFF]	; r15d = tex_width

	; src base = tex->pixels + (src_y * tex_width + src_x) * 4
	mov eax, [rbp-8]		; src_y
	imul eax, r15d			; src_y * tex_width
	add eax, [rbp-4]		; + src_x
	shl rax, 2				; * 4 bytes per pixel
	add rax, [rbx + TEX_PIXELS_OFF]	; + base pointer
	mov rsi, rax			; rsi = source row pointer

	; dst base = framebuffer + (dst_y * WINDOW_W + dst_x) * 4
	mov eax, [rbp-24]		; dst_y
	imul eax, WINDOW_W
	add eax, [rbp-20]		; + dst_x
	shl rax, 2
	lea rdi, [framebuffer]
	add rdi, rax			; rdi = dest row pointer

	; row strides (bytes to advance per row)
	mov r12d, r15d
	shl r12d, 2				; src pitch = tex_width * 4
	mov r13d, FB_PITCH		; dst pitch = WINDOW_W * 4
	mov r14d, [rbp-16]		; rows remaining

	; -- row copy loop ---
	; using rep movsd to try and copy one row at a time
	; this should copy the ecx dwords from [rsi] to [rdi],
	; while advancing both ptrs (annoyingly)
	; since it advances them i'm saving/restoring row starts and
	; stepping by pitch manually
.row_loop:
	mov r10, rsi			; save row start (src)
	mov r11, rdi			; save row start (dst)
	mov ecx, [rbp-12]		; ecx = pixels per row
	rep movsd				; copy one row

	; advance to next row
	mov rsi, r10
	add rsi, r12			; src += src_pitch
	mov rdi, r11
	add rdi, r13			; dst += dst_pitch

	dec r14d
	jnz .row_loop

.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret


;================================================================
; blit_texture_rect_keyed
;----------------------------------------------------------------
; like blit_texture_rect, but skips pixels that match a colour key
; magenta = transparent
; the inner loop is per-pixel rather than rep movsd, so will be
; slower but only used for sprites
;----------------------------------------------------------------
; in: same args as blit_texture_rect plus:
;	  [rbp+32] = colour key (ARGB)
;================================================================
blit_texture_rect_keyed:
	push rbp
	mov rbp, rsp
	sub rsp, 80
	push rbx
	push r12
	push r13
	push r14
	push r15

; locals (rbp-relative):
;	[rbp-4]  src_x
;	[rbp-8]  src_y
;	[rbp-12] src_w
;	[rbp-16] src_h
;	[rbp-20] dst_x
;	[rbp-24] dst_y
;	[rbp-32] tex ptr
;	[rbp-36] flip_x
;	[rbp-40] colour key
;
; stack args from caller (above rbp):
;	[rbp+16] = dst_y
;	[rbp+24] = flip_x
;	[rbp+32] = colour key

	mov [rbp-32], rdi
	mov [rbp-4],  esi
	mov [rbp-8],  edx
	mov [rbp-12], ecx
	mov [rbp-16], r8d
	mov [rbp-20], r9d
	mov eax, [rbp+16]
	mov [rbp-24], eax
	mov eax, [rbp+24]
	mov [rbp-36], eax
	mov eax, [rbp+32]
	mov [rbp-40], eax

	; --- clip dst to framebuffer (same as solid blit) ---
	mov eax, [rbp-20]
	test eax, eax
	jns .k_no_clip_left
	cmp dword [rbp-36], 0
	jne .k_clip_left_flipped
	sub [rbp-4], eax
	add [rbp-12], eax
	mov dword [rbp-20], 0
	jmp .k_no_clip_left
.k_clip_left_flipped:
	add [rbp-12], eax
	mov dword [rbp-20], 0
.k_no_clip_left:

	mov eax, [rbp-24]
	test eax, eax
	jns .k_no_clip_top
	sub [rbp-8], eax
	add [rbp-16], eax
	mov dword [rbp-24], 0
.k_no_clip_top:

	mov eax, [rbp-20]
	add eax, [rbp-12]
	cmp eax, WINDOW_W
	jle .k_no_clip_right
	mov eax, WINDOW_W
	sub eax, [rbp-20]
	mov [rbp-12], eax
.k_no_clip_right:

	mov eax, [rbp-24]
	add eax, [rbp-16]
	cmp eax, WINDOW_H
	jle .k_no_clip_bottom
	mov eax, WINDOW_H
	sub eax, [rbp-24]
	mov [rbp-16], eax
.k_no_clip_bottom:

	cmp dword [rbp-12], 0
	jle .k_done
	cmp dword [rbp-16], 0
	jle .k_done

	; src/dst pointer setup - same as solid blit
	mov rax, [rbp-32]
	mov r15, [rax + TEX_PIXELS_OFF]
	mov r12d, [rax + TEX_WIDTH_OFF]

	mov eax, [rbp-8]
	imul eax, r12d
	cmp dword [rbp-36], 0
	jne .k_src_flipped_init
	add eax, [rbp-4]
	jmp .k_src_init_done
.k_src_flipped_init:
	add eax, [rbp-4]
	add eax, [rbp-12]
	dec eax
.k_src_init_done:
	shl rax, 2
	add rax, r15
	mov rsi, rax

	mov eax, [rbp-24]
	imul eax, WINDOW_W
	add eax, [rbp-20]
	shl rax, 2
	lea rdi, [framebuffer]
	add rdi, rax

	mov r13d, r12d
	shl r13d, 2

	mov r14d, [rbp-16]		; rows remaining
	mov ebx, [rbp-40]		; colour key in ebx for fast compare

.k_row_loop:
	mov r10, rsi
	mov r11, rdi
	mov ecx, [rbp-12]		; pixel count

	cmp dword [rbp-36], 0
	jne .k_flip_copy

.k_normal_pixel:
	mov eax, [rsi]
	cmp eax, ebx
	je .k_skip_pixel_n
	mov [rdi], eax
.k_skip_pixel_n:
	add rsi, 4
	add rdi, 4
	dec ecx
	jnz .k_normal_pixel
	jmp .k_row_done

.k_flip_copy:
.k_flip_pixel:
	mov eax, [rsi]
	cmp eax, ebx
	je .k_skip_pixel_f
	mov [rdi], eax
.k_skip_pixel_f:
	sub rsi, 4
	add rdi, 4
	dec ecx
	jnz .k_flip_pixel

.k_row_done:
	mov rsi, r10
	add rsi, r13
	mov rdi, r11
	add rdi, FB_PITCH

	dec r14d
	jnz .k_row_loop

.k_done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; blit_texture_rect_keyed_into: like blit_texture_rect_keyed, but
; writes into an arbitrary destination tex_struct rather than the
; global framebuffer.  used to bake blood splats into the world-
; sized blood_fb at splat-time
;----------------------------------------------------------------
; clipping uses the destination tex's width/height (not WINDOW_*).
; no flip - the blood sprite is symmetric enough that we don't
; need it and skipping it shrinks the inner loop
;----------------------------------------------------------------
; in:
;	rdi |  src tex_ptr
;	rsi |  dst tex_ptr
;	edx |  src_x
;	ecx |  src_y
;	r8d |  src_w
;	r9d |  src_h
;	[rsp+8]  | dst_x
;	[rsp+16] | dst_y
;	[rsp+24] | colour key (ARGB)
;================================================================
blit_texture_rect_keyed_into:
	push rbp
	mov rbp, rsp
	sub rsp, 96
	push rbx
	push r12
	push r13
	push r14
	push r15

; locals (rbp-relative):
;	[rbp-4]  src_x
;	[rbp-8]  src_y
;	[rbp-12] src_w
;	[rbp-16] src_h
;	[rbp-20] dst_x
;	[rbp-24] dst_y
;	[rbp-32] src tex ptr
;	[rbp-40] dst tex ptr
;	[rbp-44] colour key
;	[rbp-48] dst width (cached)
;	[rbp-52] dst height (cached)
;	[rbp-56] dst pitch bytes (= width*4)

	mov [rbp-32], rdi
	mov [rbp-40], rsi
	mov [rbp-4],  edx
	mov [rbp-8],  ecx
	mov [rbp-12], r8d
	mov [rbp-16], r9d

	mov eax, [rbp+16]			; dst_x
	mov [rbp-20], eax
	mov eax, [rbp+24]			; dst_y
	mov [rbp-24], eax
	mov eax, [rbp+32]			; key
	mov [rbp-44], eax

	; cache dst width/height/pitch
	mov rax, [rbp-40]
	mov ecx, [rax + TEX_WIDTH_OFF]
	mov [rbp-48], ecx
	mov ecx, [rax + TEX_HEIGHT_OFF]
	mov [rbp-52], ecx
	mov ecx, [rbp-48]
	shl ecx, 2					; pitch bytes
	mov [rbp-56], ecx

	; --- clip dst rect against the destination tex bounds ---
	mov eax, [rbp-20]
	test eax, eax
	jns .ki_no_clip_left
	sub [rbp-4], eax
	add [rbp-12], eax
	mov dword [rbp-20], 0
.ki_no_clip_left:

	mov eax, [rbp-24]
	test eax, eax
	jns .ki_no_clip_top
	sub [rbp-8], eax
	add [rbp-16], eax
	mov dword [rbp-24], 0
.ki_no_clip_top:

	mov eax, [rbp-20]
	add eax, [rbp-12]
	cmp eax, [rbp-48]
	jle .ki_no_clip_right
	mov eax, [rbp-48]
	sub eax, [rbp-20]
	mov [rbp-12], eax
.ki_no_clip_right:

	mov eax, [rbp-24]
	add eax, [rbp-16]
	cmp eax, [rbp-52]
	jle .ki_no_clip_bottom
	mov eax, [rbp-52]
	sub eax, [rbp-24]
	mov [rbp-16], eax
.ki_no_clip_bottom:

	cmp dword [rbp-12], 0
	jle .ki_done
	cmp dword [rbp-16], 0
	jle .ki_done

	; --- src pointer setup ---
	mov rax, [rbp-32]
	mov r15, [rax + TEX_PIXELS_OFF]
	mov r12d, [rax + TEX_WIDTH_OFF]

	mov eax, [rbp-8]
	imul eax, r12d
	add eax, [rbp-4]
	shl rax, 2
	add rax, r15
	mov rsi, rax

; --- dst pointer setup (= dst_tex->pixels + dst_y*dst_w + dst_x) ---
	mov rax, [rbp-40]
	mov rdi, [rax + TEX_PIXELS_OFF]
	mov eax, [rbp-24]
	imul eax, [rbp-48]
	add eax, [rbp-20]
	shl rax, 2;
	add rdi, rax

	mov r13d, r12d
	shl r13d, 2					; src pitch bytes

	mov r14d, [rbp-16]			; rows remaining
	mov ebx, [rbp-44]			; key in ebx for inner-loop compare

.ki_row:
	mov r10, rsi
	mov r11, rdi
	mov ecx, [rbp-12]			; cols
.ki_pixel:
	mov eax, [rsi]
	cmp eax, ebx
	je .ki_skip
	mov [rdi], eax
.ki_skip:
	add rsi, 4
	add rdi, 4
	dec ecx
	jnz .ki_pixel

	mov rsi, r10
	add rsi, r13				; next src row
	mov rdi, r11
	mov eax, [rbp-56]	; load dst pitch as DWORD (zero-extends 
						; rax).  did `add rdi, [rbp-56]` which
						; read an 8-byte qword, sweeping in the 
						; dst_height field stored at [rbp-52..-49]
						; as the high half - produced bogus ptrs
	add rdi, rax

	dec r14d
	jnz .ki_row

.ki_done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

; ================================================================
; blit_texture_rect_reflect
; ----------------------------------------------------------------
; like blit_texture_rect_keyed but:
;	- source is read bottom-up (vertical flip)
;	- dest pixel must already be one of our two water blue
;	  colours (0xFF80C0FF or 0xFF60A0FF), otherwise the src pixel
;	  is skipped
;	- when we do write, we blend 50% with water colour
;
; magenta source pixels are still skipped
; ----------------------------------------------------------------
; in: same args as blit_texture_rect_keyed.  flip_x and key honoured
;	  identically; only the y axis is inverted
; ================================================================
%define WATER_REFLECT_C0	0xFF80C0FF
%define WATER_REFLECT_C1	0xFF60A0FF

blit_texture_rect_reflect:
	push rbp
	mov rbp, rsp
	sub rsp, 80
	push rbx
	push r12
	push r13
	push r14
	push r15

; locals (rbp-relative):
;	[rbp-4]  src_x
;	[rbp-8]  src_y
;	[rbp-12] src_w
;	[rbp-16] src_h
;	[rbp-20] dst_x
;	[rbp-24] dst_y
;	[rbp-32] tex ptr
;	[rbp-36] flip_x
;	[rbp-40] colour key
;
; stack args from caller (above rbp):
;	[rbp+16] = dst_y
;	[rbp+24] = flip_x
;	[rbp+32] = colour key

	mov [rbp-32], rdi
	mov [rbp-4],  esi
	mov [rbp-8],  edx
	mov [rbp-12], ecx
	mov [rbp-16], r8d
	mov [rbp-20], r9d
	mov eax, [rbp+16]
	mov [rbp-24], eax
	mov eax, [rbp+24]
	mov [rbp-36], eax
	mov eax, [rbp+32]
	mov [rbp-40], eax

	; --- clip left edge (horizontal, same as keyed) ---
	mov eax, [rbp-20]
	test eax, eax
	jns .r_no_clip_left
	cmp dword [rbp-36], 0
	jne .r_clip_left_flipped
	sub [rbp-4], eax
	add [rbp-12], eax
	mov dword [rbp-20], 0
	jmp .r_no_clip_left
.r_clip_left_flipped:
	add [rbp-12], eax
	mov dword [rbp-20], 0
.r_no_clip_left:

	; --- clip right edge ---
	mov eax, [rbp-20]
	add eax, [rbp-12]
	cmp eax, WINDOW_W
	jle .r_no_clip_right
	mov eax, WINDOW_W
	sub eax, [rbp-20]
	mov [rbp-12], eax
.r_no_clip_right:

	; --- clip TOP edge (dst_y < 0) ---
	; cutting the top of the output/BOTTOM of the source
	; leave src_y alone, just shrink h
	mov eax, [rbp-24]
	test eax, eax
	jns .r_no_clip_top
	add [rbp-16], eax		; src_h += dst_y (dst_y negative)
	mov dword [rbp-24], 0
.r_no_clip_top:

	; --- clip BOTTOM edge ---
	; cutting the bottom of the output cuts the TOP of source
	; advance src_y forward AND shrink h by the overflow
	mov eax, [rbp-24]
	add eax, [rbp-16]
	cmp eax, WINDOW_H
	jle .r_no_clip_bottom
	mov eax, [rbp-24]
	add eax, [rbp-16]
	sub eax, WINDOW_H		; eax = overflow
	add [rbp-8], eax		; src_y += overflow (skip top rows)
	sub [rbp-16], eax		; src_h -= overflow
.r_no_clip_bottom:

	cmp dword [rbp-12], 0
	jle .r_done
	cmp dword [rbp-16], 0
	jle .r_done

	; src/dst pointer setup - source row pointer starts at the
	; LAST row of the rect and walks UP each iteration
	mov rax, [rbp-32]
	mov r15, [rax + TEX_PIXELS_OFF]
	mov r12d, [rax + TEX_WIDTH_OFF] ; tex width in pixels

	; src base = pixels + ((src_y + src_h - 1) * tex_w + src_x_init)
	; * 4, where src_x_init differs for flipped
	mov eax, [rbp-8]
	add eax, [rbp-16]
	dec eax					; eax = src_y + src_h - 1
	imul eax, r12d
	cmp dword [rbp-36], 0
	jne .r_src_flipped_init
	add eax, [rbp-4]
	jmp .r_src_init_done
.r_src_flipped_init:
	add eax, [rbp-4]
	add eax, [rbp-12]
	dec eax
.r_src_init_done:
	shl rax, 2
	add rax, r15
	mov rsi, rax

	mov eax, [rbp-24]
	imul eax, WINDOW_W
	add eax, [rbp-20]
	shl rax, 2
	lea rdi, [framebuffer]
	add rdi, rax

	; src pitch in bytes, held NEGATIVE since we walk upward
	mov r13d, r12d
	shl r13d, 2
	neg r13d				; r13d = -src_pitch

	mov r14d, [rbp-16]		; rows remaining
	mov ebx, [rbp-40]		; magenta key

.r_row_loop:
	mov r10, rsi
	mov r11, rdi
	mov ecx, [rbp-12]		; pixel count

	cmp dword [rbp-36], 0
	jne .r_flip_copy

.r_normal_pixel:
	mov eax, [rsi]
	cmp eax, ebx
	je .r_skip_pixel_n
	mov edx, [rdi]
	cmp edx, WATER_REFLECT_C0
	je .r_blend_n
	cmp edx, WATER_REFLECT_C1
	je .r_blend_n
	jmp .r_skip_pixel_n
.r_blend_n:
	shr eax, 1
	and eax, 0x7F7F7F7F ;halfs
	shr edx, 1
	and edx, 0x7F7F7F7F
	add eax, edx
	or eax, 0xFF000000	; restore alpha
	mov [rdi], eax
.r_skip_pixel_n:
	add rsi, 4
	add rdi, 4
	dec ecx
	jnz .r_normal_pixel
	jmp .r_row_done

.r_flip_copy:
.r_flip_pixel:
	mov eax, [rsi]
	cmp eax, ebx
	je .r_skip_pixel_f
	mov edx, [rdi]
	cmp edx, WATER_REFLECT_C0
	je .r_blend_f
	cmp edx, WATER_REFLECT_C1
	je .r_blend_f
	jmp .r_skip_pixel_f
.r_blend_f:
	shr eax, 1
	and eax, 0x7F7F7F7F
	shr edx, 1
	and edx, 0x7F7F7F7F
	add eax, edx
	or eax, 0xFF000000
	mov [rdi], eax
.r_skip_pixel_f:
	sub rsi, 4				; right-to-left for x-flip
	add rdi, 4
	dec ecx
	jnz .r_flip_pixel

.r_row_done:
	; advance: src goes UP by pitch, dst goes DOWN by pitch
	mov rsi, r10
	movsxd rax, r13d
	add rsi, rax			; src += -pitch (one row up)
	mov rdi, r11
	add rdi, FB_PITCH

	dec r14d
	jnz .r_row_loop

.r_done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; blit_texture_additive_grey
;----------------------------------------------------------------
; blit a greyscale texture (1 byte per pixel) onto the
; framebuffer additively: for each src texel, add
; (texel * scale >> 8) to each of R, G, B in the dst pixel,
; clamping at 255.  zero texels are skipped ((free)
;----------------------------------------------------------------
; the texture is blit whole (no source-rect args).  dst is
; clipped to the framebuffer
;----------------------------------------------------------------
; in:	rdi = ptr to greyscale tex_struct
;		esi = dst_x
;		edx = dst_y
;		ecx = scale (0..256 where 256 = full intensity)
;================================================================
blit_texture_additive_grey:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8					; align

	; unpack tex struct
	mov r12, [rdi + TEX_PIXELS_OFF]	; src bytes
	mov r13d, [rdi + TEX_WIDTH_OFF]	; src_w
	mov r14d, [rdi + TEX_HEIGHT_OFF] ; src_h

	mov r8d, esi				; r8d = dst_x
	mov r9d, edx				; r9d = dst_y
	mov r15d, ecx				; r15d = scale
	; src_x/src_y track tl of the source rect after clipping
	xor r10d, r10d				; src_x0
	xor r11d, r11d				; src_y0

	; --- clip left ---
	test r8d, r8d
	jns .ag_no_clip_left
	mov eax, r8d
	neg eax						; clip amount
	add r10d, eax
	sub r13d, eax				; src_w shrinks
	xor r8d, r8d
.ag_no_clip_left:

	; --- clip top ---
	test r9d, r9d
	jns .ag_no_clip_top
	mov eax, r9d
	neg eax
	add r11d, eax
	sub r14d, eax
	xor r9d, r9d
.ag_no_clip_top:

	; --- clip right ---
	mov eax, r8d
	add eax, r13d
	cmp eax, WINDOW_W
	jle .ag_no_clip_right
	mov eax, WINDOW_W
	sub eax, r8d
	mov r13d, eax
.ag_no_clip_right:

	; --- clip bottom ---
	mov eax, r9d
	add eax, r14d
	cmp eax, WINDOW_H
	jle .ag_no_clip_bottom
	mov eax, WINDOW_H
	sub eax, r9d
	mov r14d, eax
.ag_no_clip_bottom:

	cmp r13d, 0
	jle .ag_done
	cmp r14d, 0
	jle .ag_done

	; src ptr: r12 + (src_y0 * tex_w + src_x0)
	; ebx = stride (unclipped tex width)
	; rdi still the original tex_struct ptr
	mov ebx, [rdi + TEX_WIDTH_OFF]	; ebx = src stride (tex_w)

	; row 0 src offset
	mov eax, r11d
	imul eax, ebx
	add eax, r10d
	movsxd rax, eax
	add r12, rax				; r12 = src cursor (row start)

	; dst ptr: framebuffer + (dst_y * WINDOW_W + dst_x) * 4
	mov eax, r9d
	imul eax, WINDOW_W
	add eax, r8d
	shl eax, 2
	lea rdi, [framebuffer]
	movsxd rax, eax
	add rdi, rax				; rdi = dst cursor (row start)

.ag_row_loop:
	; rsi/rdi are scratch row cursors; r12/rdi-base advance
	; by stride / FB_PITCH after each row
	mov rsi, r12				; src cursor for this row
	mov r9, rdi					; dst cursor for this row
	mov ecx, r13d				; pixel count

.ag_pixel:
	movzx eax, byte [rsi]		; grey
	test eax, eax
	jz .ag_skip					; transparent

	; effective add = (grey * scale) >> 8
	imul eax, r15d
	shr eax, 8
	test eax, eax
	jz .ag_skip
	cmp eax, 255
	jle .ag_add_ok
	mov eax, 255
.ag_add_ok:
	; eax = additive value 1..255
	; dst is ARGB; bytes at offsets 0=B, 1=G, 2=R, 3=A
	movzx r8d, byte [r9]		; B
	add r8d, eax
	cmp r8d, 255
	jle .ag_b_ok
	mov r8d, 255
.ag_b_ok:
	mov [r9], r8b

	movzx r8d, byte [r9 + 1]	; G
	add r8d, eax
	cmp r8d, 255
	jle .ag_g_ok
	mov r8d, 255
.ag_g_ok:
	mov [r9 + 1], r8b

	movzx r8d, byte [r9 + 2]	; R
	add r8d, eax
	cmp r8d, 255
	jle .ag_r_ok
	mov r8d, 255
.ag_r_ok:
	mov [r9 + 2], r8b

.ag_skip:
	inc rsi
	add r9, 4
	dec ecx
	jnz .ag_pixel

	; advance row anchors: src by stride, dst by FB_PITCH
	movsxd rax, ebx				; sign-extend stride
	add r12, rax
	add rdi, FB_PITCH

	dec r14d
	jnz .ag_row_loop

.ag_done:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

%endif
