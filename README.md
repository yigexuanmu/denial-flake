# denial-flake

[Denial](https://github.com/denialwm/denial)(Flutter 原生 Wayland 合成器)的 Nix 打包 flake。

本仓库**只包含打包文件**——Denial 源码树(compositor、`dart_shell`、
`settings_app`、打包元数据等)并不内置在此,所有源码引用都指向上游
`github:denialwm/denial` flake input,构建时使用 `flake.lock` / `flake.nix`
中固定的那个 revision。

## 快速开始

```sh
# 官方预编译 release(推荐——无需编译 Rust/Dart)
nix run .#officialRelease

# 源码构建 compositor + dart shell profile AOT bundle
nix build .#sourceProfile

# 版本检查:新 release 发布时打印需要更新的字段
nix run .#update-check
```

默认包(`nix build .`)是 `officialRelease`。

## NixOS 模块

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    denial.url = "github:yigexuanmu/denial-flake";
  };

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
    user = "youruser";          # 必须是已存在的用户;会被加入 video/input/render/seat 组
    # useOfficialRelease = false;  # 从源码构建 Rust + Dart shell
    # settings.enable = true;      # 独立设置应用
    # uiDevelopment.enable = true; # Flutter UI 实时开发工具
  };
}
```

## 更新源码固定版本

Denial 源码与 release 固定版本分开管理:

- 源码固定版本:`nix flake update denial-src`(或手动改 `flake.lock` 里的
  revision)。该 input 提供给 `package.nix` 的 `denial` 参数。
- release 固定版本(`versions.nix`):运行 `nix run .#update-check`,它会对比
  上游最新 release 并打印需要更新的字段(含新算好的哈希)。

NixOS 模块的完整参数说明见 `FLAKE.md`。

## 文件说明

- `flake.nix` — inputs(`nixpkgs`、`denial-src`、`rust-overlay`)、packages、
  NixOS 模块
- `package.nix` — 打包实现(官方预编译 release、源码 profile、设置应用、
  update-check)
- `module.nix` — NixOS 模块
- `versions.nix` — release 产物的固定版本与哈希
- `update-check.sh` — release 更新脚本模板
- `LICENSE` — GPL-3.0-or-later
