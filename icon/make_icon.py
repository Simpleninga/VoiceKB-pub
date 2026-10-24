# 生成「芽音」App 图标（小芽式半调叶 + 点茎 + 声波柱，深绿底）：python3 make_icon.py 输出.png
# 源图 yayin-app-icon.svg（「点茎」方案，整幅方块不带圆角，iOS 自己裁）
import io, os, sys
import cairosvg
from PIL import Image

svg = os.path.join(os.path.dirname(os.path.abspath(__file__)), "yayin-app-icon.svg")
png = cairosvg.svg2png(url=svg, output_width=1024, output_height=1024)
Image.open(io.BytesIO(png)).convert("RGB").save(sys.argv[1])   # 去掉 alpha：App 图标不许透明
