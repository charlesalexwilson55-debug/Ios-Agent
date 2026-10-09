"""Refresh bundled official model branding and the OFL-licensed Archivo font."""
from io import BytesIO
import json
from pathlib import Path
import urllib.parse
import urllib.request
from PIL import Image

root = Path(__file__).resolve().parents[1]
assets = root / 'App/Resources/Assets.xcassets'

def read(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Conduit-assets'})
    with urllib.request.urlopen(request, timeout=30) as response: return response.read()

brands = {
    'Qwen': ('https://avatars.githubusercontent.com/u/141221163?v=4', 'https://github.com/QwenLM/Qwen3'),
    'MiniCPM': ('https://raw.githubusercontent.com/OpenBMB/MiniCPM/main/assets/minicpm_logo.png', 'https://github.com/OpenBMB/MiniCPM'),
    'Edge0': (json.loads(read('https://huggingface.co/api/organizations/Edge0/overview'))['avatarUrl'], 'https://huggingface.co/Edge0'),
}
for name, (url, source) in brands.items():
    folder = assets / f'ModelBrand{name}.imageset'
    folder.mkdir(exist_ok=True)
    image = Image.open(BytesIO(read(url))).convert('RGBA')
    image.thumbnail((256, 256), Image.Resampling.LANCZOS)
    image.save(folder / 'brand.png')
    (folder / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'brand.png', 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    print('Bundled', name)
fonts = root / 'App/Resources/Fonts'
fonts.mkdir(exist_ok=True)
url = 'https://raw.githubusercontent.com/google/fonts/main/ofl/archivo/'
(fonts / 'Archivo.ttf').write_bytes(read(url + urllib.parse.quote('Archivo[wdth,wght].ttf')))
(fonts / 'Archivo-OFL.txt').write_bytes(read(url + 'OFL.txt'))
(root / 'docs/UI-ASSETS.md').write_text('# Bundled UI assets\n\n' + '\n'.join(f'- {name} branding: {source} ({url}). Branding belongs to its owner and is used to identify imported models; no endorsement is implied.' for name, (url, source) in brands.items()) + '\n- Archivo: https://github.com/google/fonts/tree/main/ofl/archivo; SIL Open Font License bundled alongside the font.\n- Chrome conduit: existing project startup artwork.\n', encoding='utf-8')
