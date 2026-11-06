# 芽音（VoiceKB）

iOS 语音输入法键盘。本仓库是用来云编的公开镜像，服务密钥和服务器地址不在源码里（发版时才写进安装包）。

## 第三方组件
- 本机语音识别：sherpa-onnx（Apache-2.0）https://github.com/k2-fsa/sherpa-onnx ，模型 X-ASR-zh-en（Apache-2.0）https://huggingface.co/GilgameshWind/X-ASR-zh-en 。框架由 CI 下载，模型由 App 下载，都不在本仓库里

## 第三方数据
- `Keyboard/Resources/pinyin.dat`：基础词库和词频取自 rime-frost（白霜拼音，GPL-3.0）https://github.com/gaboolic/rime-frost ，它又源自 rime-ice（雾凇拼音，GPL-3.0）https://github.com/iDvel/rime-ice
- `pinyin.dat` 另含：rime-wanxiang（CC-BY-4.0）https://github.com/amzxyz/rime-wanxiang-data 、中文维基 / 维基词典词条（fcitx5-pinyin-zhwiki，CC BY-SA）https://github.com/felixonmars/fcitx5-pinyin-zhwiki 、萌娘百科词条（mw2fcitx，CC BY-NC-SA）https://github.com/outloudvi/mw2fcitx 、清华 THUOCL 领域词（MIT）https://github.com/thunlp/THUOCL
- `Keyboard/Resources/lm.dat`：由 OpenSubtitles 中文字幕、LCCC（MIT）中文对话、B 站评论语料 https://huggingface.co/datasets/Midsummra/bilibilicomment 、知乎问答语料（ODC-BY）https://huggingface.co/datasets/KrisTHL181/zhihu-qa 统计的词对计数，不含原文
- `Keyboard/Resources/enwords.txt`：英文词频来自 wordfreq（数据 CC-BY-SA 4.0）
- `Keyboard/Resources/emoji.txt`：来自 Unicode CLDR 中文表情名
