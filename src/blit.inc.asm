; blit.inc.asm - for copying rects to FB
; 
; the main workhorse for tile drawing
; 
; copy an axis-aligned rect from loaded texture into the fb
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
; void blit_texture_rect( int src_x, int src_y,
;						  int src_w, int src_h,
;						  int dst_x, int dst_y) {
;	// clip dst to screen, adjusting src to match
;	if (dst_x < 0) { src_x -= dst_x; src_w += dst_x; dst_x = 0; }
;	if (dst_y < 0) { src_y -= dst_y; src_h += dst_y; dst_y = 0; }
;	if (dst_x + src_w > WINDOW_W) src_w = WINDOW_W  - dst_x;
;	if (dst_y + src_h > WINDOW_H) src_h = WINDOW_H - dst_y;
;	if (src_w <= 0 || src_h <= 0) return;
;
;	uint32_t *src = tex_pixels + src_y * tex_width + src_x;
;	uint32_t *dst = framebuffer + dst_y * WINDOW_W + dst_x;
;	for (int row = 0; row < src_h; row++) {
;		memcpy(dst, src, src_w * 4);
;		src += tex_width;
;		dst += WINDOW_W;
;		}
;   }
;----------------------------------------------------------------
; in's:
;----------------------------------------------------------------
; edi |  src_x	(texel x in )
; edi |  src_x	(texel x in source texture)
; esi |  src_y	(texel y in source texture)
; edx |  src_w	(width in texels)
; ecx |  src_h	(height in texels)
; r8d |  dst_x	(pixel x on framebuffer)
; r9d |  dst_y	(pixel y on framebuffer)
;
; the source texture is whatever's in tex_pixels (via load_ppm atm)
; not passing a texture pointer atm with just one texture
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

	; stash all six args into stack locals so we can modify them
	; during clipping without losing the originals
	;   [rbp-4]  src_x     [rbp-8]  src_y
	;   [rbp-12] src_w     [rbp-16] src_h
	;   [rbp-20] dst_x     [rbp-24] dst_y
	mov [rbp-4],  edi
	mov [rbp-8],  esi
	mov [rbp-12], edx
	mov [rbp-16], ecx
	mov [rbp-20], r8d
	mov [rbp-24], r9d

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

	; src base = tex_pixels + (src_y * tex_width + src_x) * 4
	mov eax, [rbp-8]		; src_y
	imul eax, [tex_width]	; src_y * tex_width
	add eax, [rbp-4]		; + src_x
	shl rax, 2				; * 4 bytes per pixel
	add rax, [tex_pixels]	; + base pointer
	mov rsi, rax			; rsi = source row pointer

	; dst base = framebuffer + (dst_y * WINDOW_W + dst_x) * 4
	mov eax, [rbp-24]		; dst_y
	imul eax, WINDOW_W
	add eax, [rbp-20]		; + dst_x
	shl rax, 2
	lea rdi, [framebuffer]
	add rdi, rax			; rdi = dest row pointer

	; row strides (bytes to advance per row)
	mov r12d, [tex_width]
	shl r12d, 2				; src pitch = tex_width * 4
	mov r13d, FB_PITCH		; dst pitch = WINDOW_W * 4
	mov r14d, [rbp-16]		; rows remaining%endif

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

%endif
