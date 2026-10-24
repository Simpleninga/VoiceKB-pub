# 词库 / 语料来源

- `Keyboard/Resources/pinyin.dat`：雾凇拼音 rime-ice（GPL-3.0）8105 + base，加 `tools/extra_words.txt`（手写补词）、`tools/boost.txt`（口语词校正）、
  `tools/extra_domain.txt`（领域词补全：清华开放中文词库 THUOCL 的成语 / 医学 / 财经 / 法律 / 食品 / 动物 / 汽车 / 地名，仅供学术与个人使用，
  词频折算成权重，生成脚本 `tools/build_domain_words.py`）。
- `Keyboard/Resources/lm.dat`：OpenSubtitles 中文字幕语料的词对统计（`tools/lm/`）。
- `Keyboard/Resources/enwords.txt`：英文词频（wordfreq，CC-BY-SA 4.0）。
- `Keyboard/Resources/emoji.txt`：Unicode CLDR 中文表情名（Unicode 许可）+ `tools/emoji_aliases.txt` 手写的口语叫法，`tools/build_emoji.py` 生成。
