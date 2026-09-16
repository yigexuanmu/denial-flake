# Denial 的 Nix flake 打包

本仓库是 [Denial](https://github.com/denialwm/denial)(Flutter 原生 Wayland
合成器)的**独立打包 flake**。flake 不再嵌在 Denial 源码树内；本仓库只保留
打包相关文件（nix 文件、update-check.sh、LICENSE、文档），所有源码引用都
通过 `denial-src` input 指向上游 `github:denialwm/denial`。

打包方案以 **0.4.1** 为准,改编自
[BeyondtheApex/nixos-denial-compositor-flake-config](https://github.com/BeyondtheApex/nixos-denial-compositor-flake-config)
和 [YeFaDa/denial.nix](https://github.com/YeFaDa/denial.nix)(两者均为 0.4.0)。

> 仅支持 x86_64-linux:上游只为 x86_64 发布预编译 Flutter 引擎,dart shell
> 也必须用这份预编译 fork 工具链编译。

## 包列表

| 属性 | 说明 |
| --- | --- |
| `.#` / `.#officialRelease` | Denial **官方预编译 release**(合成器 + shell AOT bundle + Settings + 引擎),解包并修补到 nix store,无需编译 |
| `.#withUiDevelopment` | 官方 release 加上 `denialctl`/`denial-ui`/`denial-session` 包装脚本,支持 Flutter UI 实时热更新开发 |
| `.#sourceProfile` | **从上游源码树编译 Rust 合成器**,并用预编译 fork 工具链编译 dart shell 的 profile AOT bundle |
| `.#sourceProfileWithUiDevelopment` | 源码构建版 + UI 开发工具包装脚本 |
| `.#settingsApp` | 用上游 `settings_app/` 构建的独立 GTK 设置应用 |
| `.#compositor` / `.#dartShell` / `.#uiDevRoot` | 各个中间产物 |
| `.#update-check` | 新版本发布时,打印 `versions.nix` 里所有需要更新的字段和最新哈希 |

```sh
nix run .                 # 试用官方预编译版
nix build .#sourceProfile # 从源码编译(Rust + dart AOT)
```

## NixOS 模块

```nix
# flake.nix
{
  inputs.denial.url = "github:yigexuanmu/denial-flake";
  # 或者固定某个 revision:
  # inputs.denial.url = "github:yigexuanmu/denial-flake/<rev>";

  outputs = { self, nixpkgs, denial, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ denial.nixosModules.default ./configuration.nix ];
    };
  };
}
```

```nix
# configuration.nix
{
  services.denial = {
    enable = true;
    user = "youruser";        # 已存在的用户;会加入 video/input/render/seat 组
    # useOfficialRelease = true;   # 默认:官方预编译产物
    # useOfficialRelease = false;  # 从上游源码编译 Rust 合成器
    # shellProfile = "desktop";    # 或 "mobile"
    # renderer = "impeller";       # 或 "skia"
    # startLocked = true;          # 原生 PAM 锁屏(自动登录场景)
    # settings.enable = true;      # 独立设置应用(仅源码构建路径)
    # uiDevelopment.enable = true; # Flutter UI 实时开发工具
    # outputs = [ "DP-1=0,0" "scale=DP-1,1.25" ];  # 见 outputs.conf 文档
  };
}
```

模块会:安装 Wayland 会话(`denial.desktop`)、生成
`/etc/denial/session.conf` 和输出配置模板、注册 `denial-session` 用户级
systemd target、配置 portal(Denial 自带的 Settings portal、其余走 GTK、
ScreenCast/Screenshot 走 wlr 后端),并把会话用户加入 GPU/输入设备组。

## 版本升级

```sh
nix run .#update-check
```

它会对比 `versions.nix` 与 denialwm/denial 最新 release,打印所有需要修改的
字段和刚算好的哈希(release 三件套、ui-development 工具链、flutter
tool_backend 文件)。

升级时还需要：

1. `nix flake update denial-src` —— 更新上游源码 input 的 pin。
2. 如果上游 `compositor/Cargo.lock` 的 git 依赖变了,或
   `protocol/FLATBUFFERS_VERSION` 升了,更新 `versions.nix` 的
   `cargoOutputHashes` / `flatc` 字段——否则 `package.nix` 里的求值期守卫会
   直接报错拦截。

## 文件说明

- `flake.nix` — 输入(nixpkgs + denial-src + rust-overlay)、`packages`、
  `nixosModules`
- `versions.nix` — release 固定版本与哈希(升级时唯一要改的文件)
- `package.nix` — 打包实现,带求值期守卫(Flutter 版本对
  `dart_shell/pubspec.yaml`、flatc 对 `protocol/FLATBUFFERS_VERSION`)
- `module.nix` — NixOS 模块(`services.denial`)
- `update-check.sh` — 注入当前固定值的脚本模板
