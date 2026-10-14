# 桌面外壳（Tauri）

`src-tauri/` 是一层 Tauri 外壳，把界面装进一个原生窗口，不用再开浏览器输地址。

**它只做三件事**：把 Go 后端作为 sidecar 拉起来、等它开始监听、把窗口导航过去。
界面仍然由后端在 `127.0.0.1:8777` 上提供——外壳里没有第二份前端，也没有 IPC。

这么分是因为后端已经是这个应用的主体了：ComfyUI 子进程、任务队列、SQLite、
WebSocket 都在它那儿。外壳再管一遍只会多一条要对齐的进程链。

## 构建

后端不在本仓库里，而是 `backend/` 子模块（`.gitmodules` 指向
`https://github.com/TypeDreamMoon/DreamTexture.git`）。第一次要把它检出来：

```bash
git clone --recurse-submodules https://github.com/TypeDreamMoon/DreamTextureDesktop.git
# 已经 clone 过：git submodule update --init
```

然后两步（需要 pwsh 7、pnpm、Go、Rust）：

```bash
pnpm install
pnpm build      # = pnpm sidecar && tauri build
```

`pnpm sidecar`（`scripts/build-sidecar.ps1`）负责造出 sidecar，依次：

1. 构建 `web/`（`pnpm install --frozen-lockfile` + `pnpm build`，含 vue-tsc）→ `web/dist`
2. 把 `web/dist` 拷进 `backend/internal/web/dist`（先清空）——那是后端 `go:embed` 的目标
3. `go build` 后端的 `cmd/dreamtexture` → `src-tauri/binaries/dreamtexture-<目标三元组>.exe`
   （`-trimpath`、`-s -w`、`-X main.version=<tauri.conf.json 的版本>`、`CGO_ENABLED=0`）
4. 无论成败，把 `backend/internal/web/dist` 还原成子模块提交的状态，让 `backend/` 保持干净

所以**安装包里的界面永远是本仓库当前源码重建的那份**，不是后端仓库自己提交的那份
（那份是后端的 `tools/sync-web-ui.ps1` 同步过去、给单独构建后端用的）。
`internal/web/dist` 里有未提交改动时脚本会拒绝运行，免得还原时把它们抹掉；
`-SkipWebBuild` 跳过前端构建、直接用现成的 `web/dist`（只调后端时省时间）。

产物是 `src-tauri/target/release/bundle/nsis/DreamTexture_<版本>_x64-setup.exe`（约 7 MB）。
开发外壳用 `pnpm tauri dev`——它**不会**自动构建 sidecar，`src-tauri/binaries/` 里
要已经有一个（先跑一次 `pnpm sidecar`）。

sidecar 的文件名必须带目标三元组，这是 Tauri 的约定；`binaries/` 已经 gitignore，
它是编译产物，不进仓库。

> 为什么不把 sidecar 构建塞进 `tauri.conf.json` 的 `beforeBuildCommand`：`tauri dev`
> 不走它，行为不一致；CI 里又要单独传版本号。显式的 `pnpm sidecar` 一步看得见，
> 也能单独重跑。

## 安装包带的资源

`tauri.conf.json` 的 `bundle.resources` 都取自 `backend/`，装完落在程序（外壳 exe）旁边：

| 源 | 装到 | 为什么要带 |
|---|---|---|
| `backend/workflows` | `workflows/` | 工作流模板；配置里的 `workflows_dir` 相对配置文件所在目录的上一级解析 |
| `backend/configs/dreamtexture.default.json` | `configs/dreamtexture.default.json` | 首次启动时铺成 `configs/dreamtexture.json`，升级不覆盖 |
| `backend/comfy_nodes` | `comfy_nodes/` | 一键部署 ComfyUI 时要把 DreamTexture 自有节点（CHORD 平铺包装等）接入新环境，后端在「工作目录或 exe 旁边的 `comfy_nodes`」里找它；不带的话部署会在这一步报找不到 |

`externalBin` 仍是 `binaries/dreamtexture`。

## 两条启动路径

**端口没人占** → 拉起 sidecar，等端口通了再显示窗口。

**端口已经通了** → 直接用那个后端，不再拉一个。这顺手把单实例做掉了：
再点一次图标只会多开一个窗口，而不是抢 8777 然后双双失败。

## 外链交给系统浏览器

窗口里没有标签页，`target="_blank"` 和 `window.open` 的默认行为是**什么都不发生**
——界面上那个「打开 ComfyUI」点下去毫无反应。

**只挂 Rust 侧的钩子不够。** WebView2 的 `NewWindowRequested` 只对 `window.open`
触发，**锚点点击根本不进这个事件**。实测三路对照：

| 触发方式 | 进 on_new_window 吗 |
|---|---|
| `window.open` | ✅ |
| `<a target="_blank" rel="noreferrer">` 点击 | ❌ |
| `<a target="_blank">` 点击 | ❌ |

这是 Tauri 的已知限制（[#5931](https://github.com/tauri-apps/tauri/issues/5931)、
[#11825](https://github.com/tauri-apps/tauri/issues/11825)），官方目前给的路子
也是注入脚本拦点击。所以主窗口在 Rust 里建（配置声明的窗口没地方挂东西），
装了三样：

| | 管什么 |
|---|---|
| `initialization_script`（LINK_SHIM） | 捕获阶段拦 `a[target=_blank]` 的点击，转成 `window.open` |
| `on_new_window` | `window.open`（含上面转过来的） |
| `on_navigation` | 同窗口内跳到站外 |

判断一律看是不是我们后端的地址：

- **站外** → 交给系统浏览器并拦下。ComfyUI 的节点编辑器是个完整的应用，
  本来也不该塞进我们这个窗口里；Civitai、HuggingFace 那些页面同理
- **同域** → 落到当前窗口。丢给浏览器等于把用户请出了应用；单窗口应用里
  "另开一个"最合理的落点就是当前窗口

只放行 `http(s)`。别的协议（`file:`、自定义协议…）交给系统等于让页面有能力
拉起本机程序，不值这个风险。中键与 Ctrl+点击不拦——那本来就是"另开一个"的意思。

垫片放在外壳里而不是改前端，这样那个 Web 应用不用知道自己被套了壳，
在普通浏览器里照旧是开新标签页。

**怎么测的**记一笔，因为不好测：没法在 Tauri 窗口里模拟点击，所以在真实界面上
用 `win.eval` 造锚点并 `.click()`，同时起一个本地监听端口收请求。最终结果——
两种锚点写法都命中监听端口（走了系统浏览器），同域链接点完窗口停在 `#/library`
（留在应用里），而 `msedgewebview2` 始终连着 `127.0.0.1:8777`。

## 谁起的谁负责关

关窗口退出时，**只杀自己拉起来的那个后端**；附着到已有实例时什么都不做。

后端被杀之后会把 ComfyUI 一起收干净（Windows 上用 Job Object，见后端的
`internal/comfy`）。这条链实测验证过：关窗口 → 两个进程都没了、8777 释放、
没有孤儿；先手动起后端再开外壳 → 关窗口后那个后端还活着。

## 相对路径按配置文件的位置解析，不按 cwd

`config.finalize` 把 `output_dir` 这些相对路径补成绝对路径时，基准是
**配置文件所在目录的上一级**。

这条是做外壳时才暴露的：以前按 `cwd` 解析，从仓库根手动跑时两者恰好一样，
所以一直没事。而双击启动、被外壳拉起来、从服务里启动，cwd 各不相同——
按 cwd 解析的话 `output/` 和 `data/` 会落到谁也想不到的地方，**而且不报错**，
只是"我的素材呢"。后端的 `internal/config/config_test.go` 盯着这条。

## 起不来的时候

窗口里有个占位页，后端 90 秒内没开始监听就把原因显示在上面，并指向
`logs/dreamtexture.log`。用页面不用弹窗，是因为错误信息里有路径——弹窗里没法复制。

日志见后端文档 [backend.md](../backend/docs/backend.md)：默认落在程序旁边的 `logs/`，那儿写不了就退到
用户缓存目录。这正是外壳最需要它的地方——没有控制台，标准输出直接丢掉。
