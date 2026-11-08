# 隐私与数据

| 数据 | 位置 | 保留 |
|---|---|---|
| 录音 wav | 系统临时目录 dashvoice-<session>.wav | 转写完成即删；启动清扫 >24h 残留 |
| 转写全文 | 内存（最近一条，菜单可复制） | 退出即失 |
| API Key | 登录钥匙串 service=com.dashvoice2.app.credentials | 用户自管 |
| 日志 | ~/Library/Logs/dashvoice.log | 无转写原文/无 Key/无请求体；手动删除 |
| 配置 | ~/Library/Application Support/DashVoice/config.json | 不含 Key |

音频仅发送至 config.endpoint（默认阿里云 dashscope.aliyuncs.com，中国区），使用用户自己的
DashScope Key，按阿里云计费与条款。无遥测、无自建中转。更换 endpoint 前请确认所配 Key 与
该服务地域匹配（凭证不跨主机自动携带）。
