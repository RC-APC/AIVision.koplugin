# AIVision for KOReader

在 Kindle 上**长按选中一段文字 → 直接生成配图**，画面对比电子墨水屏优化，存本地随时翻看。

**Kindle 直连国内生图 API，不需要电脑、不需要中继、不需要翻墙。**

---

## 特点

- **零中继**：Kindle 直接用 `ssl.https` 调用国内 API（智谱 / 豆包），电脑关机也能用
- **国内后端**：智谱 CogView、字节豆包 Seedream，服务器在国内，不受网络封锁影响
- **墨水屏优化**：自动追加「黑白水墨 / 高对比 / 无文字」风格后缀，e-ink 上看得清
- **记录画廊**：所有生成过的图存在本地，随时翻看
- **多个入口**：选区按钮、手势绑定，任选其一

---

## 安装

1. 下载本仓库的 `AIVision.koplugin` 整个目录
2. 通过 USB / 网络传输放到 Kindle 的 `koreader/plugins/` 下（若已有同名目录，直接覆盖）
3. 重启 KOReader


---

## 配置 API Key

插件需要至少一个后端的 API Key，在任一入口里配置：

> 手势设置里绑定对应动作 →「AI 生图」→「设置智谱 Key」 /「设置豆包 Key」

Key 保存在 `koreader/data/aivision/config.json`，**不会写入插件源码**。

### 推荐：智谱 CogView（免费）

1. 前往 [bigmodel.cn 开放平台](https://open.bigmodel.cn/) 注册
2. 在「API 密钥」中新建一个 Key
3. 填入本插件的「设置智谱 Key」

使用模型 `cogview-3-flash`，免费档。**默认带 AI 水印**；如需去水印，可在 bigmodel.cn 个人中心 → 安全管理签署免责声明后开启。

### 可选：豆包 Seedream（兜底，200 张免费）

1. 前往 [火山方舟](https://www.volcengine.com/product/ark) 注册
2. 开通图片生成，创建推理接入点，获取 API Key
3. 填入「设置豆包 Key」

作为智谱失败时的自动兜底后端。填了才启用。

---

## 使用

**方式一（推荐）：长按选段**
在阅读界面长按选中文字 → 弹出的菜单里点 **「AI 生图」** → 等待约 10–30 秒 → 自动弹出成品图。


**方式二：手势**
在 KOReader 手势设置中，把「AI 生图记录」绑定到你顺手的轻点/滑动位置。

> 生成过程中 Kindle 主线程会短暂等待（同步请求），属正常现象。

---

## 工作原理

```
长按选中文字
   ↓
拼接提示词 = 选中文字 + 墨水屏风格后缀
   ↓
POST https://open.bigmodel.cn/api/paas/v4/images/generations   （智谱 CogView）
   │ 失败则降级
   ↓
POST https://ark.cn-beijing.volces.com/api/v3/images/generations （豆包 Seedream）
   ↓
下载 data[1].url → 存为本地 PNG → 弹出看图
```

图片和记录都存在 Kindle 本地（`koreader/data/aivision/`），**不上传任何数据到第三方服务器**；唯一的外部请求是把你选中的那段文字发送给所选生图后端。

---

## 常见问题

**Q：长按选段没看到「AI 生图」？**
先重启 KOReader。若仍无，检查 手势绑定是否存在「AI 生图」子菜单——有菜单说明插件已加载，只是选区按钮注入需要进入一次正文页面才会生效。

**Q：提示「还没配置 Key」？**
去「AI 生图记录」里填写智谱或豆包 Key。

**Q：一直显示「生成中」或提示网络错误？**
确认 Kindle 能正常访问公网（家宽 WiFi 或手机热点均可，国内站点畅通）。若之前生成的失败记录卡在「生成中」，重新生成即可。

**Q：图上有 AI 水印？**
`cogview-3-flash` 免费档自带水印，去水印需在 bigmodel.cn 个人中心签署免责声明。

---

## 安全说明

- 本插件源码**不包含任何 API Key**，请务必在插件内自行填写，切勿把 Key 提交进仓库
- 仓库已配置 `.gitignore` 忽略 `config.json` 等本地配置文件
- 所有网络请求均为 HTTPS 直连，不经过任何第三方中继

---

## 兼容性

在 **KOReader v2026.07.x** 实测可用（Kindle Plain OS / Paperwhite 等墨水屏设备）。

> ⚠️ 若设备上混装了多个第三方插件，全局 gettext（`_`）函数可能被覆盖。本插件已规避依赖该函数，因此不受影响。

---

## License

MIT
