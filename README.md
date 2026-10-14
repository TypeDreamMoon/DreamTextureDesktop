# DreamTexture Desktop

[DreamTexture](https://github.com/TypeDreamMoon/DreamTexture) 的 Web 控制台，和把它装进原生窗口的
Windows 桌面版。

DreamTexture 把一句提示词变成一整套能直接进虚幻引擎的 PBR 材质，底层跑本机 ComfyUI，
上层是一个自带界面的 Go 后端。**这个仓库管的是界面和桌面安装包，后端在
[DreamTexture](https://github.com/TypeDreamMoon/DreamTexture)。**

> 开发中。想看它能做什么、配置怎么写、各条管线的细节，去后端仓库的 README 和 `docs/`。

## 里面有什么

| | |
|---|---|
| `web/` | Web 界面源码：Vue 3 + Vite + TypeScript + Naive UI。生成台、素材库、3D 材质预览、模型/节点/工作流管理、控制台、设置 |
| `src-tauri/` | Tauri 2 外壳（Rust）：把后端作为 sidecar 拉起来，等它监听，再把窗口导航过去 |
| `backend/` | **Git 子模块**，指向后端仓库。桌面版的 sidecar 就是从它编出来的 |
| `scripts/build-sidecar.ps1` | 构建 sidecar：本仓库的界面 + 子模块里的后端 → 一个 exe |
| `docs/` | [前端说明](docs/frontend.md)、[桌面外壳](docs/desktop-shell.md) |

## 和后端的关系

后端提供界面：Go 二进制 `go:embed` 了一份构建好的界面，在 `http://127.0.0.1:8777` 上提供。
所以界面和后端是两个仓库、一条约定：

- 界面源码在**这里**，构建产物固定在 `web/dist`（别改 `vite.config.ts` 的 `outDir`）。
- 后端仓库提交了一份界面的构建产物（`internal/web/dist`），用它自己的
  `tools/sync-web-ui.ps1` 从本仓库构建并同步——所以只拿后端仓库的人不装 node 也能 `go build`，
  拿到的是可用的界面。前端有改动、想让单独跑后端的人也看到，就去后端那边同步一次。
- 桌面安装包不用后端自带的那份：`scripts/build-sidecar.ps1` 每次都用本仓库当前源码
  重建界面，临时放进 `backend/` 子模块编出 sidecar，再把子模块还原干净。

桌面版的后端版本由子模块钉住的那个提交决定。要带上后端的新改动，进 `backend/` 拉到想要的提交，
回到本仓库提交子模块指针的变化。

## 开发

先把子模块检出来：

```bash
git clone --recurse-submodules https://github.com/TypeDreamMoon/DreamTextureDesktop.git
# 已经 clone 过：git submodule update --init
```

### 改界面

需要 Node 与 pnpm（版本见 `packageManager`）。开发服务器把 `/api`（含 WebSocket）代理到
`127.0.0.1:8777`，所以**先让一个后端在 8777 上跑着**——装好的桌面版、后端仓库的 exe，
或者 `backend/` 里 `go run ./cmd/dreamtexture` 都行：

```bash
pnpm -C web install --frozen-lockfile
pnpm -C web dev          # http://127.0.0.1:5173
```

改完即刷，不用重启后端。类型检查加构建：

```bash
pnpm -C web build        # vue-tsc + vite build，产物在 web/dist
```

### 改外壳

```bash
pnpm install
pnpm sidecar             # 先造一个 sidecar（只需一次；改了界面/后端要重造）
pnpm tauri dev
```

`tauri dev` 不会自动构建 sidecar，`src-tauri/binaries/` 里要已经有一个。

## 打安装包

需要 pwsh 7、Node、pnpm、Go、Rust（Windows 上，NSIS 由 Tauri 自己下载）：

```bash
pnpm install
pnpm build               # = pnpm sidecar && tauri build
```

产物：`src-tauri/target/release/bundle/nsis/DreamTexture_<版本>_x64-setup.exe`（约 7 MB）。
安装包**不含 ComfyUI**——装完由用户自己走「设置 → ComfyUI 环境 → 一键部署」。
它带的资源（工作流模板、默认配置、自有 ComfyUI 节点）和 sidecar 的构建细节见
[desktop-shell.md](docs/desktop-shell.md)。

## 发布

推一个 `v*` 的 tag，GitHub Actions（`.github/workflows/release.yml`）会在 Windows 上检出子模块、
把版本号从 tag 同步进 `tauri.conf.json` / `Cargo.toml` / `Cargo.lock` 与后端的
`main.version`、跑后端的 `go vet` / `go test`、构建界面和 sidecar、打 NSIS 安装包，
并发布到 Release。也可以在 Actions 页手动跑（`workflow_dispatch`），那时只上传产物、不发布。

打 tag 之前：先把 `backend/` 子模块 bump 到想发的后端提交并提交，再 bump 版本号。

## 许可

代码本身还没定许可证，和后端仓库一致。

**注意产物的可商用性**：写实管线用的 CHORD 是 Ubisoft 的 **research-only**
许可，用它分解出来的材质不可商用。界面上会标出来，`manifest.json` 里也有
`license_flags`。PBR 估计那一段是按"可整段替换"设计的，换掉就没有这个限制。
