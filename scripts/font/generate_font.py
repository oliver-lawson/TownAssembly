from PIL import Image, ImageDraw, ImageFont

# 8x8 font from https://int10h.org/oldschool-pc-fonts/fontlist/font?ibm_ega_8x8
font = ImageFont.truetype("PxPlus_IBM_EGA_8x8.ttf", 8)
glyphs = {}
first_char = 0
last_char = 383

for c in range(first_char, last_char + 1):
    ch = chr(c)
    img = Image.new("L", (8, 8), 0)
    draw = ImageDraw.Draw(img)
    draw.text((0, 0), ch, fill=255, font=font)
    pixels = img.load()
    # pixel write loop
    rows = []
    for y in range(8):
        byte = 0
        for x in range(8):
            if pixels[x, y] > 128:
                byte |= (1 << (7 - x)) # byte packing..msb=leftmost pixel
        rows.append(byte)
    glyphs[c] = rows

# write nasm
with open("../../src/font_data.inc.asm", "w") as f:
    f.write(f"; font_data.inc.asm - 8x8 bitmap font for ASCII {first_char}-{last_char}\n")
    f.write("; AUTO-GENERATED, DON'T EDIT\n")
    f.write("; each glyph is 8 bytes (8 rows of 8 bits).\n")
    f.write("; bit 7 (0x80) = leftmost pixel of the row.\n\n")
    f.write("section .rodata ; read-only chunk\n")
    f.write("font_8x8:\n")
    for cp in range(first_char, last_char + 1):
        rows = glyphs[cp]
        ch = chr(cp).replace("'", "\\'")
        # write a comment of what the char is.. this broke everything for
        # the weird "end line" and "SUB" char codes, doesn't draw anything
        # for them anyway in the text preview, but we need those as they're
        # the cool smiley face, arrow etc glyphs early on
        # https://int10h.org/oldschool-pc-fonts/readme/#437_charset
        comment = f"  ; {cp} '{ch}'" if cp > 31 else ""
        f.write("\tdb " + ", ".join(f"0x{b:02x}" for b in rows) + comment + "\n")
    f.write("\n")
    f.write(f"font_first_char equ {first_char}\n")
    f.write(f"font_last_char  equ {last_char}\n")
    f.write("font_glyph_size equ 8\n")

# generate preview image
chars_per_row = 16
num_chars = last_char - first_char + 1
num_rows = (num_chars + chars_per_row - 1) // chars_per_row

preview = Image.new("L", (chars_per_row * 8, num_rows * 8), 0)
for i, cp in enumerate(range(first_char, last_char + 1)):
    cell_x = (i % chars_per_row) * 8
    cell_y = (i // chars_per_row) * 8
    rows = glyphs[cp]
    for y, byte in enumerate(rows):
        for x in range(8):
            if byte & (1 << (7 - x)):
                preview.putpixel((cell_x + x, cell_y + y), 255)

preview.save("font_preview.png")
print("ok")
