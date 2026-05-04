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
	add [rbp-4], eax		; src_x += dst_x (negative, shifts right)
	add [rbp-12], eax		; src_w += dst_x (shrinks width)
	mov dword [rbp-20], 0	; dst_x = 0
.no_clip_left:
	; --- clip top edge ---
	mov eax, [rbp-24]		; dst_y
	test eax, eax
	jns .no_clip_top
	add [rbp-8], eax		; src_y += dst_y
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
; in: sam args as blit_texture_rect plus:
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

%endif
