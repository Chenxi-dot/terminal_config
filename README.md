# Terminal Lightweight Deployment Script (Enterprise Robust Edition)

[中文文档](#中文说明) | [English Documentation](#english-documentation)

---

## 中文说明

这是一个用于快速部署现代化终端环境的脚本，旨在提供极致稳健、幂等性和容错处理的终端配置体验。

### 核心架构
- **终端模拟器**: WezTerm (配置生成)
- **Shell**: Zsh (原生配置，不依赖 Oh My Zsh)
- **提示符**: Starship (高性能、可定制)
- **核心插件**: zsh-syntax-highlighting, zsh-autosuggestions, zoxide, fzf, eza, bat
- **字体**: JetBrainsMono Nerd Font (自动下载与安装)

### 特性
- **一键部署**: 自动化安装所有依赖、字体和配置文件。
- **稳健性**: 包含网络重试机制、错误捕获和环境检查。
- **本地配置**: 优先使用当前目录下的 `starship.toml` 作为 Starship 配置。
- **多系统支持**: 支持 macOS 和 Linux (Ubuntu/Debian/CentOS) 以及 WSL。
- **备份机制**: 自动备份旧的配置文件，防止数据丢失。

### 快速开始

1. **克隆仓库或下载文件**
   确保 `setup_terminal.sh` 和 `starship.toml` 在同一目录下。

2. **赋予执行权限**
   ```bash
   chmod +x setup_terminal.sh
   ```

3. **运行脚本**
   ```bash
   ./setup_terminal.sh
   ```

4. **重启终端**
   脚本执行完成后，请重启终端以应用所有更改。

### 注意事项
- **字体设置**: 脚本会自动下载并尝试安装字体。如果图标显示异常，请手动检查终端字体设置是否为 `JetBrainsMono Nerd Font Mono`。
- **代理配置**: 脚本支持交互式配置代理，以加速 GitHub 资源的下载。

---

## English Documentation

This is a script for rapidly deploying a modern terminal environment, designed to provide an extremely robust, idempotent, and fault-tolerant terminal configuration experience.

### Core Architecture
- **Terminal Emulator**: WezTerm (Config generation)
- **Shell**: Zsh (Native config, no Oh My Zsh dependency)
- **Prompt**: Starship (High performance, customizable)
- **Core Plugins**: zsh-syntax-highlighting, zsh-autosuggestions, zoxide, fzf, eza, bat
- **Fonts**: JetBrainsMono Nerd Font (Auto download & install)

### Features
- **One-Click Deployment**: Automates installation of all dependencies, fonts, and config files.
- **Robustness**: Includes network retry mechanisms, error catching, and environment checks.
- **Local Config**: Prioritizes using `starship.toml` in the current directory for Starship configuration.
- **Multi-System Support**: Supports macOS, Linux (Ubuntu/Debian/CentOS), and WSL.
- **Backup Mechanism**: Automatically backs up old config files to prevent data loss.

### Quick Start

1. **Clone Repo or Download Files**
   Ensure `setup_terminal_en.sh` and `starship.toml` are in the same directory.

2. **Grant Execution Permissions**
   ```bash
   chmod +x setup_terminal_en.sh
   ```

3. **Run Script**
   ```bash
   ./setup_terminal_en.sh
   ```

4. **Restart Terminal**
   After the script finishes, please restart your terminal to apply all changes.

### Notes
- **Font Settings**: The script will automatically download and attempt to install fonts. If icons do not display correctly, please manually check if your terminal font is set to `JetBrainsMono Nerd Font Mono`.
- **Proxy Configuration**: The script supports interactive proxy configuration to accelerate GitHub resource downloads.
