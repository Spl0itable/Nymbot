#!/usr/bin/env python3
"""Regenerates every icon in the repository from images/nymbot-icon.png — the
site's favicons, the web app's PWA icons, and the Android and iOS app icons.

Run when the source artwork changes:  python3 tools/app-icons.py
"""
import glob
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'images', 'nymbot-icon.png')
FLUTTER = os.path.join(ROOT, 'flutter')

src = Image.open(SOURCE).convert('RGBA')


def square(size, scale=1.0):
    """The mark at `size`, optionally inset so an adaptive icon's mask does not
    crop it."""
    out = Image.new('RGBA', (size, size), (10, 10, 15, 255))
    inner = max(1, int(size * scale))
    out.paste(src.resize((inner, inner), Image.LANCZOS),
              ((size - inner) // 2, (size - inner) // 2))
    return out


written = 0
for path in glob.glob(os.path.join(FLUTTER, 'android/app/src/main/res/mipmap-*/ic_launcher.png')):
    size = Image.open(path).size[0]
    square(size).save(path)
    written += 1

# The adaptive foreground is masked and then scaled up by the launcher, so the
# mark sits inside the 66/108 safe zone rather than filling the canvas.
for path in glob.glob(os.path.join(FLUTTER, 'android/app/src/main/res/drawable-*/ic_launcher_foreground.png')):
    size = Image.open(path).size[0]
    square(size, scale=0.62).save(path)
    written += 1

for path in glob.glob(os.path.join(FLUTTER, 'ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png')):
    size = Image.open(path).size[0]
    # iOS masks the corners itself and rejects alpha, so this is the flat mark.
    square(size).convert('RGB').save(path)
    written += 1

# The site's favicons and the web app's PWA icons, from the same mark.
for rel, size in [
    ('images/favicon-16x16.png', 16),
    ('images/favicon-32x32.png', 32),
    ('images/apple-touch-icon.png', 192),
    ('images/android-chrome-192x192.png', 192),
    ('images/android-chrome-512x512.png', 512),
    ('app/icons/nymbot-192.png', 192),
    ('app/icons/nymbot-512.png', 512),
]:
    square(size).convert('RGB').save(os.path.join(ROOT, rel))
    written += 1

ico = os.path.join(ROOT, 'images/favicon.ico')
square(64).convert('RGB').save(ico, sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
written += 1

print(f'wrote {written} icons from {os.path.relpath(SOURCE, ROOT)}')
