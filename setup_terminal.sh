#!/bin/bash

# ==============================================================================
# 终端轻量化部署脚本 (Enterprise Robust Edition)
# 架构: WezTerm + Zsh (原生) + Starship + 核心插件
# 核心目标: 极致稳健、幂等性、容错处理
# ==============================================================================

# 遇到错误不立即退出，由脚本捕获处理
set +e

# 确保本地 bin 目录在 PATH 中 (关键: 解决安装后找不到命令的问题)
export PATH="$HOME/.local/bin:$PATH"

# --- 0. 基础配置与辅助函数 ---

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$HOME/.terminal_backup_$TIMESTAMP"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 错误处理函数
handle_error() {
    log_error "步骤失败: $1"
    echo "建议: 请检查网络连接或权限，然后重新运行脚本。"
    exit 1
}

# 交互式代理配置 (智能读取 Git 配置)
configure_proxy() {
    echo "--------------------------------------------------------"
    log_info "网络环境配置"
    
    # 1. 尝试自动读取 Git 的代理配置
    local git_proxy=$(git config --global http.proxy)
    local default_proxy="http://127.0.0.1:7890"
    local prompt_msg="👉 请输入代理地址 (默认: $default_proxy): "
    
    if [ -n "$git_proxy" ]; then
        log_info "检测到 Git 代理配置: $git_proxy"
        log_warn "注意: Git 代理不会自动应用于字体下载 (curl)，必须在此处启用才能生效。"
        default_proxy="$git_proxy"
        prompt_msg="👉 请输入代理地址 (回车使用 Git 代理: $default_proxy): "
    else
        echo "如果您的网络访问 GitHub 较慢，建议配置 HTTP 代理。"
    fi

    read -r -p "❓ 是否启用代理以加速下载? (y/N) " response
    if [[ "$response" =~ ^[yY]$ ]]; then
        read -r -p "$prompt_msg" proxy_url
        proxy_url=${proxy_url:-$default_proxy}
        
        # 关键: 将代理应用到环境变量，这样 curl 也能识别
        export http_proxy="$proxy_url"
        export https_proxy="$proxy_url"
        export all_proxy="$proxy_url"
        export HTTP_PROXY="$proxy_url"
        export HTTPS_PROXY="$proxy_url"
        
        log_success "已启用全局临时代理: $proxy_url"
        
        log_info "正在测试连通性..."
        if curl -I -s --connect-timeout 5 https://www.github.com >/dev/null; then
            log_success "GitHub 连接测试成功！"
        else
            log_warn "GitHub 连接测试失败，请检查代理地址是否正确。"
            read -r -p "是否继续? (y/N) " cont
            if [[ ! "$cont" =~ ^[yY]$ ]]; then exit 1; fi
        fi
    else
        log_info "不使用代理，直接连接 (可能会慢)。"
    fi
    echo "--------------------------------------------------------"
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then return 1; else return 0; fi
}

# 确保目录存在
ensure_dir() {
    if [ ! -d "$1" ]; then 
        mkdir -p "$1" || handle_error "无法创建目录 $1"
    fi
}

# 备份文件 (带时间戳，不覆盖)
backup_file() {
    local file="$1"
    if [ -f "$file" ] || [ -d "$file" ]; then
        ensure_dir "$BACKUP_DIR"
        local filename=$(basename "$file")
        cp -rf "$file" "$BACKUP_DIR/$filename"
        log_info "已备份 $file -> $BACKUP_DIR/$filename"
    fi
}

# 网络重试机制 (关键稳健性优化)
retry() {
    local retries=3
    local count=0
    local delay=2
    
    # 使用 "$@" 直接执行命令，保留参数中的空格和引号
    until "$@"; do
        exit_code=$?
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            log_warn "命令执行失败，正在重试 ($count/$retries)..."
            sleep $delay
        else
            log_error "命令执行失败，已达到最大重试次数。"
            return $exit_code
        fi
    done
    return 0
}

# 安全下载文件
download_file() {
    local url="$1"
    local dest="$2"
    log_info "下载: $url"
    
    if command -v wget &> /dev/null; then
        # 使用 wget (支持断点续传和更好的进度条)
        retry wget -q --show-progress -c -O "$dest" "$url" || handle_error "下载失败: $url"
    else
        # 回退到 curl
        retry curl -L -# -C - --connect-timeout 20 --retry 3 -o "$dest" "$url" || handle_error "下载失败: $url"
    fi
}

# 安全克隆 Git 仓库 (浅克隆)
git_clone_safe() {
    local url="$1"
    local dest="$2"
    if [ -d "$dest" ]; then
        log_info "更新仓库: $dest"
        # 尝试更新，如果失败则忽略（可能是本地修改过），保证脚本不中断
        (cd "$dest" && git pull --quiet) || log_warn "无法更新仓库 $dest，将使用现有版本。"
    else
        log_info "克隆仓库: $url"
        retry git clone --depth=1 "$url" "$dest" || handle_error "克隆失败: $url"
    fi
}

# --- 1. 配置文件生成器 (原子写入) ---

# 写入文件辅助函数
write_file() {
    local dest="$1"
    local content_func="$2"
    local temp_file="${dest}.tmp"
    
    log_info "生成配置: $dest"
    $content_func > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        backup_file "$dest"
        mv "$temp_file" "$dest"
        log_success "配置已写入: $dest"
    else
        rm -f "$temp_file"
        handle_error "生成配置文件失败: $dest"
    fi
}

# WezTerm 配置内容
content_wezterm() {
    cat <<EOF
-- WezTerm 高级配置文件 (Auto-Generated - Beautiful Edition)
local wezterm = require 'wezterm'
local config = {}
local act = wezterm.action

if wezterm.config_builder then
  config = wezterm.config_builder()
end

-- 1. 字体与外观
-- 自动加载本地下载的字体目录
config.font_dirs = { wezterm.home_dir .. '/.config/wezterm/fonts' }

-- 字体回退策略 (关键: 确保图标和中文优先显示)
config.font = wezterm.font_with_fallback {
  -- 使用 Mono 版本以确保对齐
  { family = 'JetBrainsMono Nerd Font Mono', weight = 'Regular' },
  -- 备用：如果 Mono 版本有问题，尝试标准版
  { family = 'JetBrainsMono Nerd Font', weight = 'Regular' },
  -- 中文回退
  'PingFang SC',
  'Microsoft YaHei',
  -- Emoji 回退
  'Apple Color Emoji'
}

config.font_size = 15.0 -- 进一步调大字体
config.line_height = 1.2
config.color_scheme = 'Tokyo Night'

-- 解决常见图标显示问题
config.harfbuzz_features = { 'calt=0', 'clig=0', 'liga=0' } -- 禁用连字，有时能修复图标重叠

-- 2. 背景与窗口效果 (紫色磨砂玻璃风格)
config.macos_window_background_blur = 25
config.window_background_opacity = 0.85
config.background = {
    {
        source = {
            Color = "#301934", -- 深紫色背景
        },
        width = "100%",
        height = "100%",
        opacity = 0.85,
    },
}

config.window_decorations = "TITLE | RESIZE"
config.window_close_confirmation = 'NeverPrompt'
config.default_cursor_style = 'BlinkingBlock'

-- 窗口边距
config.window_padding = {
  left = 3,
  right = 3,
  top = 0,
  bottom = 0,
}

-- 3. 标签栏
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = true
config.tab_bar_at_bottom = true

-- Shell: 自动识别
if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  config.default_domain = 'WSL:Ubuntu'
else
  config.default_prog = { '/bin/zsh', '-l' }
end

-- 4. 确保启用完整图标支持
config.enable_kitty_keyboard = true
config.warn_about_missing_glyphs = false

return config
EOF
}

# Starship 配置内容
# 使用目录下的文档：

# Zsh 配置内容
content_zshrc() {
    cat <<EOF
# ====================================================
# Zsh 纯净配置文件 (Generated by setup_terminal.sh)
# Path: ~/.zshrc
# ====================================================

# 0. 加载本地私有配置 (API Key 等敏感信息)
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local

# 1. 基础环境配置
export LANG=en_US.UTF-8
# 确保本地 bin 目录在 PATH 中
export PATH="\$HOME/.local/bin:\$PATH"

# Homebrew 路径自动修正 (Mac)
if [[ "\$(uname)" == "Darwin" ]]; then
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "\$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "\$(/usr/local/bin/brew shellenv)"
    fi
fi

# 开启颜色
autoload -U colors && colors

# 初始化补全系统 (Git 等命令补全依赖此项)
autoload -Uz compinit
# 为了安全，忽略不安全目录的检查 (避免 compinit 报错)
compinit -u

# 历史记录
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory

# 2. 初始化 Starship (移动到最后以避免被 Conda 覆盖)
# (Moved to end of file)

# 3. 工具初始化 (Zoxide & FZF)
# Zoxide (智能跳转)
if command -v zoxide &> /dev/null; then
    eval "\$(zoxide init zsh)"
    alias cd="z"
fi

# FZF (模糊搜索 - 自动识别路径)
if command -v fzf &> /dev/null; then
    # 1. Mac Homebrew
    if [[ -f /opt/homebrew/opt/fzf/shell/key-bindings.zsh ]]; then
        source /opt/homebrew/opt/fzf/shell/key-bindings.zsh
        source /opt/homebrew/opt/fzf/shell/completion.zsh
    # 2. Linux/Manual Install (~/.fzf)
    elif [[ -f "$HOME/.fzf/shell/key-bindings.zsh" ]]; then
        source "$HOME/.fzf/shell/key-bindings.zsh"
        source "$HOME/.fzf/shell/completion.zsh"
    # 3. Legacy/Fallback
    elif [[ -f ~/.fzf.zsh ]]; then
        source ~/.fzf.zsh
    fi
    
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --color='header:italic'"
fi

# 4. 加载插件
PLUGIN_DIR="\$HOME/.zsh/plugins"
if [ -f "\$PLUGIN_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]; then
    source "\$PLUGIN_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
if [ -f "\$PLUGIN_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh" ]; then
    source "\$PLUGIN_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# 5. 别名 (Alias)
alias cls='clear'
alias reload='source ~/.zshrc'

# 现代化替代品 (Eza & Bat)
if command -v eza &> /dev/null; then
    # 启用图标模式 (需要 Nerd Font 支持)
    # --classify: 目录后加 /, 可执行文件后加 *
    alias ls='eza --icons --classify'
    alias ll='eza -lh --icons --classify --git'
    alias la='eza -a --icons --classify'
else
    alias ll='ls -alF'
    alias la='ls -A'
    alias l='ls -CF'
fi

if command -v bat &> /dev/null; then
    alias cat='bat'
fi

# 6. 实用别名与函数
alias shutdown='sudo shutdown -h now'

# 7. Python/Conda 环境自动激活
# 尝试自动寻找并初始化 Conda
__conda_setup=""
if [ -f "\$HOME/anaconda3/bin/conda" ]; then
    __conda_setup="\$("\$HOME/anaconda3/bin/conda" 'shell.zsh' 'hook' 2> /dev/null)"
elif [ -f "\$HOME/miniconda3/bin/conda" ]; then
    __conda_setup="\$("\$HOME/miniconda3/bin/conda" 'shell.zsh' 'hook' 2> /dev/null)"
elif [ -f "/opt/homebrew/anaconda3/bin/conda" ]; then
    __conda_setup="\$("/opt/homebrew/anaconda3/bin/conda" 'shell.zsh' 'hook' 2> /dev/null)"
elif [ -f "/opt/homebrew/Caskroom/miniconda/base/bin/conda" ]; then
    __conda_setup="\$("/opt/homebrew/Caskroom/miniconda/base/bin/conda" 'shell.zsh' 'hook' 2> /dev/null)"
fi

if [ -n "\$__conda_setup" ]; then
    eval "\$__conda_setup"
else
    if [ -f "\$HOME/anaconda3/etc/profile.d/conda.sh" ]; then
        . "\$HOME/anaconda3/etc/profile.d/conda.sh"
    elif [ -f "\$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
        . "\$HOME/miniconda3/etc/profile.d/conda.sh"
    fi
fi
unset __conda_setup

# 每次进入终端时显示问候信息
greet_user() {
    current_time=\$(date +"%Y-%m-%d %H:%M:%S")
    echo "👋 Welcome Back, \$USER"
    echo "🕒 Current Time: \$current_time"
}

# 调用问候函数
greet_user

# 8. 初始化 Starship (最后加载，确保覆盖 Conda 的 (base) 提示)
if command -v starship &> /dev/null; then
    eval "\$(starship init zsh)"
fi

echo "🚀 Terminal Ready."
EOF
}

# --- 主逻辑 ---

echo "========================================================"
echo "   终端轻量化部署 (Enterprise Robust Edition)"
echo "========================================================"
echo "备份目录: $BACKUP_DIR"

# 2. 识别操作系统
OS="$(uname -s)"
case "${OS}" in
    Linux*)     
        MACHINE=Linux
        if grep -q Microsoft /proc/version 2>/dev/null || grep -q microsoft /proc/version 2>/dev/null; then
            IS_WSL=true
            log_info "环境: WSL"
        else
            IS_WSL=false
            log_info "环境: Linux"
        fi
        ;;
    Darwin*)    
        MACHINE=Mac
        IS_WSL=false
        log_info "环境: macOS"
        ;;
    *)          
        handle_error "不支持的操作系统: $OS"
        ;;
esac

# 3. 代理配置
configure_proxy

# 4. 依赖安装 (带重试和错误检查)
log_info ">>> [1/6] 检查并安装基础依赖..."
if [ "$MACHINE" == "Mac" ]; then
    if ! check_command brew; then
        log_info "安装 Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || handle_error "Homebrew 安装失败"
        if [ -f "/opt/homebrew/bin/brew" ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    fi
    # 新增 zoxide, fzf, eza, bat, starship, unzip
    for tool in git wget zsh curl zoxide fzf eza bat starship unzip; do
        if ! check_command $tool; then 
            log_info "安装 $tool..."
            retry brew install $tool || handle_error "安装 $tool 失败"
        fi
    done
    # 安装 fzf 快捷键绑定 (如果 brew 没自动处理)
    if [ -f "$(brew --prefix)/opt/fzf/install" ]; then
        "$(brew --prefix)/opt/fzf/install" --all --no-bash --no-fish --key-bindings --completion --update-rc 2>/dev/null
    fi

elif [ "$MACHINE" == "Linux" ]; then
    if check_command apt-get; then
        # 尝试无密码 sudo，如果失败则提示
        if sudo -n true 2>/dev/null; then
            sudo apt-get update && sudo apt-get install -y git zsh curl wget bat unzip || handle_error "apt 安装失败"
        else
            log_info "请输入 sudo 密码以安装依赖:"
            sudo apt-get update && sudo apt-get install -y git zsh curl wget bat unzip || handle_error "apt 安装失败"
        fi
        # Ubuntu 下 bat 命令可能是 batcat
        if ! check_command bat && check_command batcat; then
            mkdir -p ~/.local/bin
            ln -s /usr/bin/batcat ~/.local/bin/bat
        fi
    elif check_command yum; then
        sudo yum install -y git zsh curl wget unzip || handle_error "yum 安装失败"
    fi

    # Linux 下手动安装 zoxide (保证版本)
    if ! check_command zoxide; then
        log_info "安装 zoxide..."
        curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Linux 下手动安装 eza (需要 gpg 比较麻烦，这里尝试直接下载二进制或提示用户)
    # 简化处理：如果 apt 源里没有 eza (旧版 Ubuntu)，则跳过或提示
    if ! check_command eza; then
        log_warn "Linux 下 eza 安装较为复杂，建议后续手动安装: https://github.com/eza-community/eza"
    fi

    # Linux 下手动安装 fzf (保证版本)
    if ! check_command fzf; then
        log_info "安装 fzf..."
        git_clone_safe "https://github.com/junegunn/fzf.git" "$HOME/.fzf"
        # --no-update-rc: 不修改 .zshrc (我们自己管理)
        "$HOME/.fzf/install" --bin --no-bash --no-fish --key-bindings --completion --no-update-rc
    fi
fi

# 4. 安装 Starship
log_info ">>> [2/6] 安装 Starship..."
if ! check_command starship; then
    # 尝试安装到 ~/.local/bin 以避免权限问题 (Mac/Linux 通用稳健方案)
    ensure_dir "$HOME/.local/bin"
    log_info "尝试使用官方脚本安装到 ~/.local/bin ..."
    retry curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" || handle_error "Starship 安装失败"
else
    log_info "Starship 已安装。"
fi

ensure_dir "$HOME/.config"
# 使用脚本同级目录下的 starship.toml
if [ -f "$SCRIPT_DIR/starship.toml" ]; then
    log_info "发现本地 starship.toml，正在应用..."
    backup_file "$HOME/.config/starship.toml"
    cp "$SCRIPT_DIR/starship.toml" "$HOME/.config/starship.toml"
    log_success "Starship 配置已更新。"
else
    log_warn "未找到 $SCRIPT_DIR/starship.toml，跳过 Starship 配置更新。"
fi

# 5. 字体部署
log_info ">>> [3/6] 部署字体 (JetBrainsMono Nerd Font)..."
WEZTERM_FONT_DIR="$HOME/.config/wezterm/fonts"
ensure_dir "$WEZTERM_FONT_DIR"

# 检查字体是否已存在
if [ ! -f "$WEZTERM_FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf" ]; then
    log_info "正在下载 JetBrainsMono Nerd Font..."
    
    # 使用 GitHub Releases 下载 Zip 包 (v3.3.0)
    FONT_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/JetBrainsMono.zip"
    ZIP_FILE="$WEZTERM_FONT_DIR/JetBrainsMono.zip"
    
    download_file "$FONT_ZIP_URL" "$ZIP_FILE"
    
    if check_command unzip; then
        log_info "正在解压字体..."
        # -o: 覆盖, -q: 安静模式, -d: 目标目录
        unzip -o -q "$ZIP_FILE" -d "$WEZTERM_FONT_DIR"
        rm "$ZIP_FILE"
        log_success "JetBrainsMono Nerd Font 部署完成。"
    else
        log_warn "未找到 unzip 命令，无法自动解压字体。"
        log_warn "请手动解压 $ZIP_FILE 到 $WEZTERM_FONT_DIR"
    fi
else
    log_info "JetBrainsMono Nerd Font 已存在，跳过下载。"
fi

# 5.1 额外安装 Symbols Nerd Font (作为图标回退，确保所有图标都能显示)
if [ ! -f "$WEZTERM_FONT_DIR/SymbolsNerdFontMono-Regular.ttf" ]; then
    log_info "正在下载 Symbols Nerd Font (图标回退支持)..."
    SYMBOLS_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/NerdFontsSymbolsOnly.zip"
    SYMBOLS_ZIP_FILE="$WEZTERM_FONT_DIR/Symbols.zip"
    
    download_file "$SYMBOLS_ZIP_URL" "$SYMBOLS_ZIP_FILE"
    
    if check_command unzip; then
        unzip -o -q "$SYMBOLS_ZIP_FILE" -d "$WEZTERM_FONT_DIR"
        rm "$SYMBOLS_ZIP_FILE"
        log_success "Symbols Nerd Font 部署完成。"
    fi
fi

if [ "$MACHINE" == "Mac" ]; then
    # 尝试将字体复制到系统目录，以便其他应用也能使用
    log_info "正在安装字体到系统目录 ($HOME/Library/Fonts/)..."
    cp "$WEZTERM_FONT_DIR"/*.ttf "$HOME/Library/Fonts/"
    
    # 提示用户手动安装（如果自动加载失败）
    log_info "正在打开字体目录..."
    open "$WEZTERM_FONT_DIR"
    log_warn "【重要】如果重启终端后图标仍不显示，请双击打开目录中的 'JetBrainsMonoNerdFont-Regular.ttf' 并点击'安装字体'。"
elif [ "$MACHINE" == "Linux" ]; then
    # Linux 刷新字体缓存
    if check_command fc-cache; then
        log_info "刷新字体缓存..."
        mkdir -p "$HOME/.local/share/fonts"
        cp "$WEZTERM_FONT_DIR"/*.ttf "$HOME/.local/share/fonts/" 2>/dev/null
        fc-cache -fv >/dev/null 2>&1
    fi
fi

# 6. WezTerm 配置
log_info ">>> [4/6] 部署 WezTerm 配置..."
# 更改为 XDG 标准目录 ~/.config/wezterm/wezterm.lua，避免污染 Home 目录
WEZTERM_CONF_DIR="$HOME/.config/wezterm"
ensure_dir "$WEZTERM_CONF_DIR"
write_file "$WEZTERM_CONF_DIR/wezterm.lua" content_wezterm

if [ "$IS_WSL" = true ]; then
    log_info "尝试同步 WezTerm 配置到 Windows..."
    if check_command wslpath && check_command cmd.exe; then
        WIN_USER_PROFILE=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
        if [ -n "$WIN_USER_PROFILE" ]; then
            WSL_WIN_HOME=$(wslpath "$WIN_USER_PROFILE")
            if [ -d "$WSL_WIN_HOME" ]; then
                # Windows 下也建议放在 .config/wezterm (WezTerm 支持)
                # 但为了兼容性，如果用户习惯放在 Home，我们先检查
                # 这里我们统一推送到 Windows 的 .config/wezterm
                WIN_CONFIG_DIR="$WSL_WIN_HOME/.config/wezterm"
                ensure_dir "$WIN_CONFIG_DIR"
                write_file "$WIN_CONFIG_DIR/wezterm.lua" content_wezterm
                log_success "WezTerm 配置已同步到 Windows (.config/wezterm)。"
            else
                log_warn "Windows 用户目录不存在: $WSL_WIN_HOME"
            fi
        else
            log_warn "无法获取 Windows 用户配置路径。"
        fi
    else
        log_warn "wslpath 或 cmd.exe 不可用，跳过 Windows 同步。"
    fi
fi

# 7. 插件安装
log_info ">>> [5/6] 安装插件..."
PLUGIN_DIR="$HOME/.zsh/plugins"
ensure_dir "$PLUGIN_DIR"

git_clone_safe "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$PLUGIN_DIR/zsh-syntax-highlighting"
git_clone_safe "https://github.com/zsh-users/zsh-autosuggestions" "$PLUGIN_DIR/zsh-autosuggestions"

# 8. 生成 Zsh 配置
log_info ">>> [6/6] 生成 Zsh 配置..."

# 8.1 生成 .zshrc (直接在 Home 目录)
write_file "$HOME/.zshrc" content_zshrc

# 9. 最终检查与切换 Shell
log_info ">>> 执行最终自检..."
[ -f "$HOME/.zshrc" ] || handle_error ".zshrc 生成失败"
[ -f "$HOME/.config/starship.toml" ] || handle_error "Starship 配置生成失败"
[ -f "$HOME/.config/wezterm/wezterm.lua" ] || handle_error "WezTerm 配置生成失败"

if [ "$SHELL" != "$(which zsh)" ] && [ "$SHELL" != "/bin/zsh" ]; then
    log_info "切换默认 Shell 为 Zsh..."
    chsh -s "$(which zsh)" || log_warn "切换 Shell 失败，请手动运行: chsh -s \$(which zsh)"
fi

# 10. 清理临时文件与旧配置
log_info ">>> [7/7] 清理临时文件与旧配置..."
rm -f "$HOME/.wget-hsts"
rm -f "$HOME/.zcompdump"*
rm -f "$HOME/.zshrc.tmp"
rm -f "$HOME/.config/wezterm/wezterm.lua.tmp"

# 清理旧的 .zshenv (如果存在)
if [ -f "$HOME/.zshenv" ]; then
    log_info "清理: 删除 ~/.zshenv (不再使用重定向)..."
    rm -f "$HOME/.zshenv"
fi

# 迁移清理: 删除旧位置的配置文件 (如果存在)
if [ -f "$HOME/.wezterm.lua" ]; then
    log_info "迁移: 删除旧的 ~/.wezterm.lua (已移动到 ~/.config/wezterm/)..."
    rm -f "$HOME/.wezterm.lua"
fi
if [ -f "$HOME/.fzf.zsh" ]; then
    log_info "清理: 删除 ~/.fzf.zsh (配置已集成到 .zshrc)..."
    rm -f "$HOME/.fzf.zsh"
fi
# 如果之前生成了 .config/zsh/.zshrc，也清理掉
if [ -f "$HOME/.config/zsh/.zshrc" ]; then
    log_info "清理: 删除 ~/.config/zsh/.zshrc (已移动到 ~/.zshrc)..."
    rm -f "$HOME/.config/zsh/.zshrc"
fi

echo "========================================================"
log_success "部署全部完成！"
echo "--------------------------------------------------------"
echo "1. 备份已保存至: $BACKUP_DIR"
echo "2. Zsh 配置已生成至: ~/.zshrc"
echo "3. 请重启终端以应用更改。"
echo ""
echo "⚠️  【字体设置提醒】"
echo "1. macOS 自带终端 (Terminal.app) / iTerm2："
echo "   请手动进入 偏好设置 -> 描述文件 -> 文本 -> 字体"
echo "   选择 'JetBrainsMono Nerd Font Mono' 以显示图标。"
echo ""
echo "2. VS Code 集成终端："
echo "   请在设置 (Cmd+,) 中搜索 'terminal.integrated.fontFamily'"
echo "   填入: 'JetBrainsMono Nerd Font Mono'"
echo "========================================================"
