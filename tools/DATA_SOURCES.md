# 词库 / 语料来源

## 词库 `Keyboard/Resources/pinyin.dat`（2026-11-06 重做）
- 基础：白霜拼音 rime-frost（GPL-3.0）8105 + base，词频由 7.45 亿字语料重新统计（线上以前用的雾凇 rime-ice 词频是网页语料：江泽民 19260817、版权 1320 万、三国群英传 12345678，单字母候选被这些词占满）。
- 新词：287 万个候选（白霜 ext、万象基础词库 CC-BY-4.0、中文维基 / 维基词典 fcitx5-pinyin-zhwiki 2026-10、萌娘百科 mw2fcitx 2026-10 CC-BY-NC-SA、web-slang）在知乎 + B 站语料里数真实出现次数，
  过内聚度（PMI）和碎片检测（几乎总是某个更长的词的一部分就丢掉），留下 11.7 万条，权重按出现率折算。
- 口语词频：词频 = 0.5 × 白霜 + 0.5 × 口语语料（字幕 / 对话 / B 站评论），多音字按白霜里各读音的比例分。白霜偏书面（打 f 出「发现 方式」），混入后短输入才像平常说话。
- 手写补充：`tools/extra_words.txt`、`tools/boost.txt`；领域词 `tools/extra_domain.txt`（清华 THUOCL，MIT，`tools/build_domain_words.py` 生成）。这两个文件的权重是雾凇尺度，build_dict.py 里除以 10。

## 语言模型 `Keyboard/Resources/lm.dat`（2026-11-06 重做）
词对统计，权重：OpenSubtitles 中文字幕 ×2（1433 万行）、LCCC 中文对话（MIT，3257 万行）×1、B 站评论区（2023，479 万条）×4、知乎问答（ODC-BY，2026-10，4 个分片 1881 万句）×1；
词表 10 万，`tools/lm/count_bigrams.py` 分别计数，合并后 `tools/lm/export_lm.py … 8`（最少出现 8 次）。
不要加 GPT 生成的指令语料（2026-10-25 试过 BELLE，分数掉）。

## 其它
- `Keyboard/Resources/enwords.txt`：英文词频（wordfreq，CC-BY-SA 4.0）。
- `Keyboard/Resources/emoji.txt`：Unicode CLDR 中文表情名（Unicode 许可）+ `tools/emoji_aliases.txt` 手写的口语叫法，`tools/build_emoji.py` 生成。

## 2026-11-06 跑分（整句首选全对；句子都没进训练，B 站句是留出的 2%）
| | 聊天 | 打错一键 | 日常 | 用户句 | B 站手打 | 知乎热榜 |
|---|---|---|---|---|---|---|
| 雾凇词库 + 旧模型 | 91.8% | 79.1% | 85.4% | 61.5% | 41.8% | 46.6% |
| 现在 | 96.4% | 90.0% | 95.1% | 63.5% | 61.0% | 59.3% |
