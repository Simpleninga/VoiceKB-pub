# 词库 / 语料来源

- `Keyboard/Resources/pinyin.dat`：雾凇拼音 rime-ice（GPL-3.0）8105 + base，加 `tools/extra_words.txt`（手写补词）、`tools/boost.txt`（口语词校正）、
  `tools/extra_domain.txt`（领域词补全：清华开放中文词库 THUOCL 的成语 / 医学 / 财经 / 法律 / 食品 / 动物 / 汽车 / 地名，仅供学术与个人使用，
  词频折算成权重，生成脚本 `tools/build_domain_words.py`）。
- `Keyboard/Resources/lm.dat`：词对统计 = OpenSubtitles 中文字幕（权重 ×2）+ LCCC 中文对话语料（MIT，微博 / 贴吧一类口语对话，权重 ×1），`tools/lm/count_bigrams.py` → `merge_counts.py` → `export_lm.py`（最少出现 6 次）；2026-10-25 加入 LCCC 后聊天句首选 84.5%→91.8%、用户句 59.2%→61.5%。
- `Keyboard/Resources/enwords.txt`：英文词频（wordfreq，CC-BY-SA 4.0）。
- `Keyboard/Resources/emoji.txt`：Unicode CLDR 中文表情名（Unicode 许可）+ `tools/emoji_aliases.txt` 手写的口语叫法，`tools/build_emoji.py` 生成。
