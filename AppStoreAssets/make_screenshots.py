from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import glob

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "Screenshots" / "01-batch-rename.png"
IMAGE_SETTINGS = ROOT / "Screenshots" / "04-image-settings.png"
IMAGE_SETTINGS_FINAL = ROOT / "Screenshots" / "04-final-composite.png"
OUT = ROOT / "Final"
OUT.mkdir(parents=True, exist_ok=True)

font_candidates = glob.glob("/System/Library/Fonts/*角* W6.ttc")
regular_candidates = glob.glob("/System/Library/Fonts/*角* W3.ttc")
FONT_BOLD = font_candidates[0]
FONT_REGULAR = regular_candidates[0]

W, H = 2880, 1800

def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size)

def gradient(top, bottom):
    image = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(image)
    for y in range(H):
        t = y / (H - 1)
        color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        draw.line((0, y, W, y), fill=color)
    return image

def centered(draw, text, y, fnt, color):
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text(((W - (box[2] - box[0])) / 2, y), text, font=fnt, fill=color)

def rounded_card(base, screenshot, slot, radius=44):
    """Place a screenshot inside a slot without ever changing its aspect ratio."""
    slot_x, slot_y, max_width, max_height = slot
    source_width, source_height = screenshot.size
    scale = min(max_width / source_width, max_height / source_height)
    width = round(source_width * scale)
    height = round(source_height * scale)
    x = slot_x + (max_width - width) // 2
    y = slot_y + (max_height - height) // 2

    if x < 0 or y < 0 or x + width > W or y + height > H:
        raise ValueError(f"Card is outside the canvas: {(x, y, width, height)}")

    screenshot = screenshot.resize((width, height), Image.Resampling.LANCZOS)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), radius=radius, fill=255)

    shadow = Image.new("RGBA", (width + 120, height + 120), (0, 0, 0, 0))
    shadow_shape = Image.new("L", (width, height), 0)
    ImageDraw.Draw(shadow_shape).rounded_rectangle(
        (0, 0, width - 1, height - 1), radius=radius, fill=150
    )
    shadow.paste((0, 0, 0, 135), (60, 35), shadow_shape)
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    base.paste(shadow, (x - 60, y - 35), shadow)
    base.paste(screenshot, (x, y), mask)

    # A quiet one-pixel edge keeps glass and white windows distinct from light backgrounds.
    edge = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (0, 0, width - 1, height - 1), radius=radius, outline=(60, 80, 96, 45), width=2
    )
    base.paste(edge, (x, y), edge)
    return x, y, width, height

def transparent_capture(base, screenshot, slot):
    """Place a native macOS window capture, preserving its transparent shadow."""
    slot_x, slot_y, max_width, max_height = slot
    screenshot = screenshot.convert("RGBA")
    scale = min(max_width / screenshot.width, max_height / screenshot.height)
    size = (round(screenshot.width * scale), round(screenshot.height * scale))
    screenshot = screenshot.resize(size, Image.Resampling.LANCZOS)
    x = slot_x + (max_width - size[0]) // 2
    y = slot_y + (max_height - size[1]) // 2
    if x < 0 or y < 0 or x + size[0] > W or y + size[1] > H:
        raise ValueError(f"Capture is outside the canvas: {(x, y, *size)}")
    base.paste(screenshot, (x, y), screenshot.getchannel("A"))

def make_full_ui():
    source = Image.open(SOURCE).convert("RGB")
    source.save(OUT / "01_一括リネーム.png", optimize=True)

def make_before_after():
    base = gradient((232, 242, 250), (248, 251, 253))
    d = ImageDraw.Draw(base)
    centered(d, "変更前と変更後を、一画面で確認", 80, font(100, True), (16, 42, 67))
    centered(d, "実行前にすべての名前をプレビュー", 215, font(45), (72, 101, 129))
    source = Image.open(SOURCE).convert("RGB")
    focus = source.crop((0, 110, 2880, 1050))
    rounded_card(base, focus, (180, 410, 2520, 820))
    d = ImageDraw.Draw(base)
    d.rounded_rectangle((545, 1370, 2335, 1545), radius=88, fill=(255, 255, 255))
    centered(d, "DSC_1842.jpg    →    20260813_Event_001.jpg", 1412, font(47, True), (30, 62, 91))
    base.save(OUT / "02_変更前と変更後.png", optimize=True)

def make_rule():
    base = gradient((255, 247, 237), (250, 252, 255))
    d = ImageDraw.Draw(base)
    centered(d, "命名ルールは、見えるブロックで", 90, font(100, True), (61, 44, 30))
    centered(d, "日付・固定文字・連番を直感的に組み立て", 225, font(44), (118, 88, 60))
    source = Image.open(SOURCE).convert("RGB")
    focus = source.crop((0, 1170, 2880, 1800))
    rounded_card(base, focus, (170, 485, 2540, 560))
    labels = [("日付", (246, 166, 35)), ("固定文字", (48, 105, 152)), ("連番", (235, 87, 87))]
    x = 690
    for label, color in labels:
        d.rounded_rectangle((x, 1205, x + 430, 1375), radius=85, fill=color)
        box = d.textbbox((0, 0), label, font=font(48, True))
        d.text((x + (430 - (box[2]-box[0]))/2, 1255), label, font=font(48, True), fill="white")
        x += 520
    centered(d, "並び順を変えると、連番もすぐ更新", 1505, font(55, True), (61, 44, 30))
    base.save(OUT / "03_命名ルール.png", optimize=True)

def make_image_processing():
    if IMAGE_SETTINGS_FINAL.exists():
        Image.open(IMAGE_SETTINGS_FINAL).convert("RGB").save(
            OUT / "04_画像変換とリサイズ.png", optimize=True
        )
        return
    base = gradient((228, 243, 250), (245, 248, 252))
    d = ImageDraw.Draw(base)
    centered(d, "画像変換と長辺統一も、まとめて", 75, font(98, True), (13, 50, 75))
    centered(d, "長辺を指定して、意図しない拡大も防止", 205, font(43), (55, 91, 116))
    capture = Image.open(IMAGE_SETTINGS).convert("RGBA")
    alpha = capture.getchannel("A")
    visible_bounds = alpha.point(lambda value: 255 if value >= 40 else 0).getbbox()
    if visible_bounds is None:
        raise ValueError("Image-settings capture has no visible pixels")
    capture = capture.crop(visible_bounds)
    transparent_capture(base, capture, (240, 315, 2400, 1430))
    base.save(OUT / "04_画像変換とリサイズ.png", optimize=True)

def make_safety():
    base = gradient((19, 45, 72), (39, 74, 104))
    d = ImageDraw.Draw(base)
    centered(d, "大切なファイルを、安全に変更", 75, font(100, True), "white")
    centered(d, "衝突検知・二段階リネーム・Undo・失敗時の復元", 210, font(44), (211, 228, 242))
    source = Image.open(SOURCE).convert("RGB")
    rounded_card(base, source, (368, 390, 2144, 1340), radius=48)
    base.save(OUT / "05_安全なファイル操作.png", optimize=True)

make_full_ui()
make_before_after()
make_rule()
make_image_processing()
make_safety()
