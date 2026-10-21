import os
from PIL import Image, ImageDraw

OUTPUT_DIR = os.path.join("assets", "icon")
os.makedirs(OUTPUT_DIR, exist_ok=True)
ICON_PATH = os.path.join(OUTPUT_DIR, "app_icon.png")

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Background
draw.rounded_rectangle([(0, 0), (SIZE, SIZE)], radius=220, fill=(11, 27, 43, 255))

# Aksen Geometris Luar
draw.ellipse([(140, 140), (884, 884)], outline=(212, 175, 55, 60), width=8)

# Simbol Buku
draw.polygon([(240, 720), (512, 760), (784, 720), (784, 760), (512, 800), (240, 760)], fill=(212, 175, 55, 255))

# Cincin Emas Utama
draw.ellipse([(302, 240), (722, 660)], outline=(212, 175, 55, 255), width=36)
draw.ellipse([(377, 315), (647, 585)], outline=(245, 222, 130, 200), width=12)

# Titik Berlian
draw.polygon([(512, 150), (555, 195), (512, 240), (469, 195)], fill=(252, 224, 130, 255))

img.save(ICON_PATH, "PNG")
