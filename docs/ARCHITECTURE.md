# 架构

```
触发层      ⌥Space(Carbon) / 菜单栏 / 悬浮按钮(nonactivating panel)
会话层      RecordingSession(幂等终态) × DeliveryQueue(有界FIFO,按序整段)
权限层      MicPermission 四态一次处理
转写层      ASRProvider 协议 → DashScopeProvider(compatible-mode SSE)
交付层      TextSanitizer(控制字符净化) → Injector(逐批键入+每批 AX 校验) → 预览/剪贴板兜底
凭证层      KeychainStore(service=com.dashvoice2.app.credentials)
配置层      ConfigLoader(版本化/坏文件备份/HTTPS 强制)
可观测      AppLog(无转写/凭证/请求体)
```

## 状态机（RecordingSession.State）
recording → transcribing → delivering → delivered / deliveredPartial / preview
任何态可 → cancelled / failed。终态迁移全部幂等（markRecordingFinished/markUploadStarted/
markDeliveryDone 只赢一次），迟到回调无副作用。

## 顺序保证
DeliveryQueue 串行：同一时刻只有一个 session 在转写/交付；录音不受限。
因此"多段交错"在结构上被排除。

## 交付语义（DV-034）
- 生成完成：ASRResult.isComplete（协议 finish_reason/[DONE]）
- 交付完成：Injector 返回 submitted（**已提交输入事件**，CGEvent 无接收回执，不称已写入）
- 中途停止：deliveredPartial + 已提交字数 + 剩余全文复制到剪贴板
