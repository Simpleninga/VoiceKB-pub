# 芽音（VoiceKB）

iOS 语音输入法键盘。本仓库是用来云编的公开镜像，服务密钥和服务器地址不在源码里（发版时才写进安装包）。

## 第三方组件
- 本机语音识别：sherpa-onnx（Apache-2.0）https://github.com/k2-fsa/sherpa-onnx ，模型 X-ASR-zh-en（Apache-2.0）https://huggingface.co/GilgameshWind/X-ASR-zh-en 。框架由 CI 下载，模型由 App 下载，都不在本仓库里

## 第三方数据
- `Keyboard/Resources/pinyin.dat`：词库取自 rime-ice（雾凇拼音，GPL-3.0）https://github.com/iDvel/rime-ice
- `Keyboard/Resources/enwords.txt`：英文词频来自 wordfreq（数据 CC-BY-SA 4.0）
- `Keyboard/Resources/lm.dat`：由 OpenSubtitles 中文字幕语料和 LCCC（MIT）中文对话语料统计的词对计数
- `Keyboard/Resources/pinyin.dat` 另含清华 THUOCL 领域词（成语 / 医学 / 地名等，仅供学术与个人使用）；`emoji.txt` 来自 Unicode CLDR 中文表情名
