# 安全与隐私

## 数据处理

- 会话用量在本机解析：只读取 `~/.dsh/sessions/**/session*.jsonl.zstd` 里的 `assistant/message` 事件，取出 token 数量、模型名和时间戳。**聊天内容既不解析也不外发。**
- 唯一的外发请求是余额查询：如果 `~/.dsh/.credentials.yaml` 里配置了 `DEEPSEEK_API_KEY`，该 Key 会以 `Authorization: Bearer` 发送给 DeepSeek 官方接口 `https://api.deepseek.com/user/balance`。没有 Key 时本地统计照常工作，只是不显示余额。
- 快照与配置保存在 `~/Library/Application Support/DeepSeekSpend/`，没有其他落盘位置。
- 构建时会把一份官方 Node.js 运行时及其许可证打进 App，运行期间不下载、不执行来自网络的脚本。

## 签名边界

当前构建使用 ad-hoc 签名（`codesign --sign -`）。构建脚本不会创建证书、私钥、钥匙串条目或系统信任根，也不会修改 macOS 安全设置。首次打开时需要由用户在「系统设置 → 隐私与安全性」中确认，或右键 App 选择「打开」。

## 报告漏洞

请不要公开提交包含 API Key、日志内容或私人路径的 Issue。优先使用本仓库的 [Private vulnerability reporting](../../security/advisories/new) 私密报告。
