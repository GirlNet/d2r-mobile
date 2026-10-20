"""Generate the P5R shell app icon at the sizes the bundle declares."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent / "icons"
SIZES = {
    "AppIcon.png": 1024,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
}


def render(size: int) -> Image.Image:
    image = Image.new("RGB", (size, size), (14, 12, 16))
    draw = ImageDraw.Draw(image)
    # diagonal red band
    draw.polygon([(0, size * 0.62), (size, size * 0.18), (size, size * 0.46), (0, size * 0.9)],
                 fill=(196, 22, 32))
    draw.polygon([(0, size * 0.72), (size, size * 0.28), (size, size * 0.34), (0, size * 0.78)],
                 fill=(245, 243, 240))
    # thick outline
    inset = max(2, size // 64)
    draw.rectangle([inset, inset, size - 1 - inset, size - 1 - inset],
                   outline=(245, 243, 240), width=max(2, size // 48))
    text = "P5R"
    font_size = int(size * 0.42)
    try:
        font = ImageFont.truetype("arialbd.ttf", font_size)
    except OSError:
        font = ImageFont.load_default(size=font_size)
    box = draw.textbbox((0, 0), text, font=font, stroke_width=max(1, size // 300))
    width, height = box[2] - box[0], box[3] - box[1]
    draw.text(((size - width) / 2 - box[0], size * 0.5 - height / 2 - box[1]), text,
              font=font, fill=(250, 248, 244), stroke_width=max(1, size // 300),
              stroke_fill=(14, 12, 16))
    return image


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    base = render(1024)
    for name, size in SIZES.items():
        icon = base if size == 1024 else base.resize((size, size), Image.LANCZOS)
        icon.save(OUT / name, "PNG", optimize=True)
        print(name, icon.size)


if __name__ == "__main__":
    main()
