"""Package the rendered chrome conduit artwork as an opaque 1024px iOS icon."""
import json
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
out = root / 'App/Resources/Assets.xcassets/AppIcon.appiconset'

def main():
    out.mkdir(parents=True, exist_ok=True)
    image = Image.open(root / 'Support/AppIconArtwork.png').convert('RGB')
    image.resize((1024, 1024), Image.Resampling.LANCZOS).save(out / 'icon-1024.png')
    contents = {'images': [{'filename': 'icon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
                'info': {'author': 'xcode', 'version': 1}}
    (out / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n')
    print('Packaged rendered chrome app icon (1024x1024 RGB)')

if __name__ == '__main__': main()
