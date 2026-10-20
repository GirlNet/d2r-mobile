"""Generate the P5R shell app icon from the game's bundled control icon."""

from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent / "icons"
SOURCE = OUT / "official-icon.jpg"
SIZES = {
    "AppIcon.png": 1024,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
}


def render(size: int) -> Image.Image:
    if not SOURCE.exists():
        raise SystemExit(f"missing game icon source: {SOURCE}")
    with Image.open(SOURCE) as image:
        image = image.convert("RGB")
        if image.width != image.height:
            raise SystemExit(f"game icon must be square, got {image.size}")
        return image.copy() if size == image.width else image.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    base = render(1024)
    for name, size in SIZES.items():
        icon = base if size == 1024 else base.resize((size, size), Image.LANCZOS)
        icon.save(OUT / name, "PNG", optimize=True)
        print(name, icon.size)


if __name__ == "__main__":
    main()
