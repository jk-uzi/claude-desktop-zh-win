# macOS 说明

本仓库以 Windows 的 `ion-dist.asar` 与第三方推理设置窗口为主要验证目标，但保留了上游的 macOS 运行时注入代码（菜单自动化、CDP、辅助功能权限）。macOS 路径在当前仓库中**未重新验收**，仅作为上游实现保留。

macOS 使用前至少需要：

1. Claude Desktop 配置为第三方 Gateway 模式，Node.js 22+ 可用。
2. 正常退出 Claude 后运行 `runtime-setup`，备份并开启 `allowDevTools`。
3. 给 magpie 授予辅助功能/设备控制权限。
4. 准备兼容的官方语言目录，默认位于 `~/Library/Application Support/claude-desktop-zh/catalogs`。
5. 从原入口打开 Claude，并由插件自动加载。

相关实现位于 `lib/macos.mjs`、`lib/macos-browser.mjs` 与 `lib/runtime-localization.mjs`。上游项目：<https://github.com/liwenjinchn/claude-desktop-zh>。当前仓库不为 macOS 行为作保证。