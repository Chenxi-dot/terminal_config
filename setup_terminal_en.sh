#!/bin/bash

# ==============================================================================
# Terminal Lightweight Deployment Script (Enterprise Robust Edition)
# Architecture: WezTerm + Zsh (Native) + Starship + Core Plugins
# Core Goals: Extreme Robustness, Idempotency, Fault Tolerance
# ==============================================================================

# Do not exit immediately on error, let the script handle it
set +e

# Ensure local bin directory is in PATH (Critical: fixes command not found after install)
export PATH="$HOME/.local/bin:$PATH"

# --- 0. Basic Configuration & Helper Functions ---

# Get script directory
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

# Error handling function
handle_error() {
    log_error "Step failed: $1"
    echo "Suggestion: Please check your network connection or permissions, then re-run the script."
    exit 1
}

# Interactive Proxy Configuration (Smart Git Config Reading)
configure_proxy() {
    echo "--------------------------------------------------------"
    log_info "Network Environment Configuration"
    
    # 1. Try to automatically read Git proxy config
    local git_proxy=$(git config --global http.proxy)
    local default_proxy="http://127.0.0.1:7890"
    local prompt_msg="👉 Please enter proxy address (Default: $default_proxy): "
    
    if [ -n "$git_proxy" ]; then
        log_info "Detected Git proxy config: $git_proxy"
        log_warn "Note: Git proxy is not automatically applied to font downloads (curl), must enable here to take effect."
        default_proxy="$git_proxy"
        prompt_msg="👉 Please enter proxy address (Press Enter to use Git proxy: $default_proxy): "
    else
        echo "If your network access to GitHub is slow, it is recommended to configure an HTTP proxy."
    fi

    read -r -p "❓ Enable proxy to accelerate downloads? (y/N) " response
    if [[ "$response" =~ ^[yY]$ ]]; then
        read -r -p "$prompt_msg" proxy_url
        proxy_url=${proxy_url:-$default_proxy}
        
        # Critical: Apply proxy to environment variables so curl can recognize it
        export http_proxy="$proxy_url"
        export https_proxy="$proxy_url"
        export all_proxy="$proxy_url"
        export HTTP_PROXY="$proxy_url"
        export HTTPS_PROXY="$proxy_url"
        
        log_success "Global temporary proxy enabled: $proxy_url"
        
        log_info "Testing connectivity..."
        if curl -I -s --connect-timeout 5 https://www.github.com >/dev/null; then
            log_success "GitHub connection test successful!"
        else
            log_warn "GitHub connection test failed, please check if the proxy address is correct."
            read -r -p "Continue? (y/N) " cont
            if [[ ! "$cont" =~ ^[yY]$ ]]; then exit 1; fi
        fi
    else
        log_info "Not using proxy, connecting directly (may be slow)."
    fi
    echo "--------------------------------------------------------"
}

# Check if command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then return 1; else return 0; fi
}

# Ensure directory exists
ensure_dir() {
    if [ ! -d "$1" ]; then 
        mkdir -p "$1" || handle_error "Unable to create directory $1"
    fi
}

# Backup file (with timestamp, no overwrite)
backup_file() {
    local file="$1"
    if [ -f "$file" ] || [ -d "$file" ]; then
        ensure_dir "$BACKUP_DIR"
        local filename=$(basename "$file")
        cp -rf "$file" "$BACKUP_DIR/$filename"
        log_info "Backed up $file -> $BACKUP_DIR/$filename"
    fi
}

# Network retry mechanism (Critical robustness optimization)
retry() {
    local retries=3
    local count=0
    local delay=2
    
    # Use "$@" to execute command directly, preserving spaces and quotes in arguments
    until "$@"; do
        exit_code=$?
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            log_warn "Command failed, retrying ($count/$retries)..."
            sleep $delay
        else
            log_error "Command failed, reached maximum retries."
            return $exit_code
        fi
    done
    return 0
}

# Secure file download
download_file() {
    local url="$1"
    local dest="$2"
    log_info "Downloading: $url"
    
    if command -v wget &> /dev/null; then
        # Use wget (supports resume and better progress bar)
        retry wget -q --show-progress -c -O "$dest" "$url" || handle_error "Download failed: $url"
    else
        # Fallback to curl
        retry curl -L -# -C - --connect-timeout 20 --retry 3 -o "$dest" "$url" || handle_error "Download failed: $url"
    fi
}

# Secure Git clone (Shallow clone)
git_clone_safe() {
    local url="$1"
    local dest="$2"
    if [ -d "$dest" ]; then
        log_info "Updating repository: $dest"
        # Try to update, ignore if fails (might be locally modified), ensure script doesn't break
        (cd "$dest" && git pull --quiet) || log_warn "Unable to update repository $dest, using existing version."
    else
        log_info "Cloning repository: $url"
        retry git clone --depth=1 "$url" "$dest" || handle_error "Clone failed: $url"
    fi
}

# --- 1. Configuration Generator (Atomic Write) ---

# Write file helper function
write_file() {
    local dest="$1"
    local content_func="$2"
    local temp_file="${dest}.tmp"
    
    log_info "Generating config: $dest"
    $content_func > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        backup_file "$dest"
        mv "$temp_file" "$dest"
        log_success "Config written: $dest"
    else
        rm -f "$temp_file"
        handle_error "Failed to generate config file: $dest"
    fi
}

# WezTerm Configuration Content
content_wezterm() {
    cat <<EOF
-- WezTerm Advanced Configuration (Auto-Generated - Beautiful Edition)
local wezterm = require 'wezterm'
local config = {}
local act = wezterm.action

if wezterm.config_builder then
  config = wezterm.config_builder()
end

-- 1. Fonts & Appearance
-- Automatically load locally downloaded font directory
config.font_dirs = { wezterm.home_dir .. '/.config/wezterm/fonts' }

-- Font Fallback Strategy (Critical: Ensure icons and CJK display correctly)
config.font = wezterm.font_with_fallback {
  -- Use Mono version to ensure alignment
  { family = 'JetBrainsMono Nerd Font Mono', weight = 'Regular' },
  -- Fallback: If Mono version has issues, try standard version
  { family = 'JetBrainsMono Nerd Font', weight = 'Regular' },
  -- CJK Fallback
  'PingFang SC',
  'Microsoft YaHei',
  -- Emoji Fallback
  'Apple Color Emoji'
}

config.font_size = 15.0 -- Larger font size
config.line_height = 1.2
config.color_scheme = 'Tokyo Night'

-- Fix common icon display issues
config.harfbuzz_features = { 'calt=0', 'clig=0', 'liga=0' } -- Disable ligatures, sometimes fixes icon overlap

-- 2. Background & Window Effects (Purple Frosted Glass Style)
config.macos_window_background_blur = 25
config.window_background_opacity = 0.85
config.background = {
    {
        source = {
            Color = "#301934", -- Dark Purple Background
        },
        width = "100%",
        height = "100%",
        opacity = 0.85,
    },
}

config.window_decorations = "TITLE | RESIZE"
config.window_close_confirmation = 'NeverPrompt'
config.default_cursor_style = 'BlinkingBlock'

-- Window Padding
config.window_padding = {
  left = 3,
  right = 3,
  top = 0,
  bottom = 0,
}

-- 3. Tab Bar
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = true
config.tab_bar_at_bottom = true

-- 4. Key Features: Smart Splits & Navigation (Tmux-like)
config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }
config.keys = {
  -- Vertical Split (Leader + -)
  { key = '-', mods = 'LEADER', action = act.SplitVertical { domain = 'CurrentPaneDomain' } },
  -- Horizontal Split (Leader + \)
  { key = '\\\\', mods = 'LEADER', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  -- Pane Navigation (Leader + hjkl)
  { key = 'h', mods = 'LEADER', action = act.ActivatePaneDirection 'Left' },
  { key = 'l', mods = 'LEADER', action = act.ActivatePaneDirection 'Right' },
  { key = 'k', mods = 'LEADER', action = act.ActivatePaneDirection 'Up' },
  { key = 'j', mods = 'LEADER', action = act.ActivatePaneDirection 'Down' },
  -- Close Pane (Leader + x)
  { key = 'x', mods = 'LEADER', action = act.CloseCurrentPane { confirm = true } },
  -- Maximize Pane (Leader + z)
  { key = 'z', mods = 'LEADER', action = act.TogglePaneZoomState },
}

-- Shell: Auto Detection
if wezterm.target_triple == 'x86_64-pc-windows-msvc' then
  config.default_domain = 'WSL:Ubuntu'
else
  config.default_prog = { '/bin/zsh', '-l' }
end

-- 5. Ensure full icon support
config.enable_kitty_keyboard = true
config.warn_about_missing_glyphs = false

return config
EOF
}

# Zsh Configuration Content
content_zshrc() {
    cat <<EOF
# ====================================================
# Zsh Clean Configuration (Generated by setup_terminal.sh)
# Path: ~/.zshrc
# ====================================================

# 0. Load local private config (API Keys, etc.)
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local

# 1. Basic Environment Configuration
export LANG=en_US.UTF-8
# Ensure local bin directory is in PATH
export PATH="\$HOME/.local/bin:\$PATH"

# Homebrew Path Auto-Correction (Mac)
if [[ "\$(uname)" == "Darwin" ]]; then
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "\$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "\$(/usr/local/bin/brew shellenv)"
    fi
fi

# Enable Colors
autoload -U colors && colors

# Initialize Completion System
autoload -Uz compinit
# For security, ignore insecure directory checks
compinit -u

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory

# 2. Initialize Starship (Moved to end to avoid being overridden by Conda)
# (Moved to end of file)

# 3. Tool Initialization (Zoxide & FZF)
# Zoxide (Smart Jump)
if command -v zoxide &> /dev/null; then
    eval "\$(zoxide init zsh)"
    alias cd="z"
fi

# FZF (Fuzzy Finder - Auto Path Detection)
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

# 4. Load Plugins
PLUGIN_DIR="\$HOME/.zsh/plugins"
if [ -f "\$PLUGIN_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]; then
    source "\$PLUGIN_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
if [ -f "\$PLUGIN_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh" ]; then
    source "\$PLUGIN_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# 5. Aliases
alias cls='clear'
alias reload='source ~/.zshrc'

# Modern Replacements (Eza & Bat)
if command -v eza &> /dev/null; then
    # Enable Icon Mode (Requires Nerd Font)
    # --classify: Add / after directories, * after executables
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

# 6. Utility Aliases & Functions
alias shutdown='sudo shutdown -h now'

# 7. Python/Conda Environment Auto-Activation
# Try to automatically find and initialize Conda
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

# Greet user on terminal entry
greet_user() {
    current_time=\$(date +"%Y-%m-%d %H:%M:%S")
    echo "👋 Welcome Back, \$USER"
    echo "🕒 Current Time: \$current_time"
}

# Call greeting function
greet_user

# 8. Initialize Starship (Load last to ensure it overrides Conda's (base) prompt)
if command -v starship &> /dev/null; then
    eval "\$(starship init zsh)"
fi

echo "🚀 Terminal Ready."
EOF
}

# --- Main Logic ---

echo "========================================================"
echo "   Terminal Lightweight Deployment (Enterprise Robust Edition)"
echo "========================================================"
echo "Backup Directory: $BACKUP_DIR"

# 2. Identify Operating System
OS="$(uname -s)"
case "${OS}" in
    Linux*)     
        MACHINE=Linux
        if grep -q Microsoft /proc/version 2>/dev/null || grep -q microsoft /proc/version 2>/dev/null; then
            IS_WSL=true
            log_info "Environment: WSL"
        else
            IS_WSL=false
            log_info "Environment: Linux"
        fi
        ;;
    Darwin*)    
        MACHINE=Mac
        IS_WSL=false
        log_info "Environment: macOS"
        ;;
    *)          
        handle_error "Unsupported Operating System: $OS"
        ;;
esac

# 3. Proxy Configuration
configure_proxy

# 4. Dependency Installation (With retry and error checking)
log_info ">>> [1/6] Checking and installing basic dependencies..."
if [ "$MACHINE" == "Mac" ]; then
    if ! check_command brew; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || handle_error "Homebrew installation failed"
        if [ -f "/opt/homebrew/bin/brew" ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    fi
    # Add zoxide, fzf, eza, bat, starship, unzip
    for tool in git wget zsh curl zoxide fzf eza bat starship unzip; do
        if ! check_command $tool; then 
            log_info "Installing $tool..."
            retry brew install $tool || handle_error "Failed to install $tool"
        fi
    done
    # Install fzf key bindings (if brew didn't handle it)
    if [ -f "$(brew --prefix)/opt/fzf/install" ]; then
        "$(brew --prefix)/opt/fzf/install" --all --no-bash --no-fish --key-bindings --completion --update-rc 2>/dev/null
    fi

elif [ "$MACHINE" == "Linux" ]; then
    if check_command apt-get; then
        # Try passwordless sudo, prompt if failed
        if sudo -n true 2>/dev/null; then
            sudo apt-get update && sudo apt-get install -y git zsh curl wget bat unzip || handle_error "apt installation failed"
        else
            log_info "Please enter sudo password to install dependencies:"
            sudo apt-get update && sudo apt-get install -y git zsh curl wget bat unzip || handle_error "apt installation failed"
        fi
        # Ubuntu bat command might be batcat
        if ! check_command bat && check_command batcat; then
            mkdir -p ~/.local/bin
            ln -s /usr/bin/batcat ~/.local/bin/bat
        fi
    elif check_command yum; then
        sudo yum install -y git zsh curl wget unzip || handle_error "yum installation failed"
    fi

    # Manual install zoxide on Linux (ensure version)
    if ! check_command zoxide; then
        log_info "Installing zoxide..."
        curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Manual install eza on Linux (gpg is complex, try direct binary or prompt user)
    # Simplified: if apt source doesn't have eza (old Ubuntu), skip or prompt
    if ! check_command eza; then
        log_warn "Installing eza on Linux is complex, recommend manual installation later: https://github.com/eza-community/eza"
    fi

    # Manual install fzf on Linux (ensure version)
    if ! check_command fzf; then
        log_info "Installing fzf..."
        git_clone_safe "https://github.com/junegunn/fzf.git" "$HOME/.fzf"
        # --no-update-rc: Do not modify .zshrc (we manage it)
        "$HOME/.fzf/install" --bin --no-bash --no-fish --key-bindings --completion --no-update-rc
    fi
fi

# 4. Install Starship
log_info ">>> [2/6] Installing Starship..."
if ! check_command starship; then
    # Try installing to ~/.local/bin to avoid permission issues (Mac/Linux robust solution)
    ensure_dir "$HOME/.local/bin"
    log_info "Attempting to install to ~/.local/bin using official script..."
    retry curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" || handle_error "Starship installation failed"
else
    log_info "Starship is already installed."
fi

ensure_dir "$HOME/.config"
# Use starship.toml from the script's directory
if [ -f "$SCRIPT_DIR/starship.toml" ]; then
    log_info "Found local starship.toml, applying..."
    backup_file "$HOME/.config/starship.toml"
    cp "$SCRIPT_DIR/starship.toml" "$HOME/.config/starship.toml"
    log_success "Starship configuration updated."
else
    log_warn "Did not find $SCRIPT_DIR/starship.toml, skipping Starship configuration update."
fi

# 5. Font Deployment
log_info ">>> [3/6] Deploying Fonts (JetBrainsMono Nerd Font)..."
WEZTERM_FONT_DIR="$HOME/.config/wezterm/fonts"
ensure_dir "$WEZTERM_FONT_DIR"

# Check if font already exists
if [ ! -f "$WEZTERM_FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf" ]; then
    log_info "Downloading JetBrainsMono Nerd Font..."
    
    # Download Zip from GitHub Releases (v3.3.0)
    FONT_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/JetBrainsMono.zip"
    ZIP_FILE="$WEZTERM_FONT_DIR/JetBrainsMono.zip"
    
    download_file "$FONT_ZIP_URL" "$ZIP_FILE"
    
    if check_command unzip; then
        log_info "Unzipping fonts..."
        # -o: overwrite, -q: quiet, -d: destination
        unzip -o -q "$ZIP_FILE" -d "$WEZTERM_FONT_DIR"
        rm "$ZIP_FILE"
        log_success "JetBrainsMono Nerd Font deployment complete."
    else
        log_warn "unzip command not found, cannot automatically unzip fonts."
        log_warn "Please manually unzip $ZIP_FILE to $WEZTERM_FONT_DIR"
    fi
else
    log_info "JetBrainsMono Nerd Font already exists, skipping download."
fi

# 5.1 Extra Install Symbols Nerd Font (Icon Fallback Support)
if [ ! -f "$WEZTERM_FONT_DIR/SymbolsNerdFontMono-Regular.ttf" ]; then
    log_info "Downloading Symbols Nerd Font (Icon Fallback Support)..."
    SYMBOLS_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/NerdFontsSymbolsOnly.zip"
    SYMBOLS_ZIP_FILE="$WEZTERM_FONT_DIR/Symbols.zip"
    
    download_file "$SYMBOLS_ZIP_URL" "$SYMBOLS_ZIP_FILE"
    
    if check_command unzip; then
        unzip -o -q "$SYMBOLS_ZIP_FILE" -d "$WEZTERM_FONT_DIR"
        rm "$SYMBOLS_ZIP_FILE"
        log_success "Symbols Nerd Font deployment complete."
    fi
fi

if [ "$MACHINE" == "Mac" ]; then
    # Try to copy fonts to system directory so other apps can use them
    log_info "Installing fonts to system directory ($HOME/Library/Fonts/)..."
    cp "$WEZTERM_FONT_DIR"/*.ttf "$HOME/Library/Fonts/"
    
    # Prompt user to manually install if auto-load fails
    log_info "Opening font directory..."
    open "$WEZTERM_FONT_DIR"
    log_warn "【IMPORTANT】If icons still don't show after restarting terminal, please double-click 'JetBrainsMonoNerdFont-Regular.ttf' in the directory and click 'Install Font'."
elif [ "$MACHINE" == "Linux" ]; then
    # Linux refresh font cache
    if check_command fc-cache; then
        log_info "Refreshing font cache..."
        mkdir -p "$HOME/.local/share/fonts"
        cp "$WEZTERM_FONT_DIR"/*.ttf "$HOME/.local/share/fonts/" 2>/dev/null
        fc-cache -fv >/dev/null 2>&1
    fi
fi

# 6. WezTerm Configuration
log_info ">>> [4/6] Deploying WezTerm Configuration..."
# Change to XDG standard directory ~/.config/wezterm/wezterm.lua
WEZTERM_CONF_DIR="$HOME/.config/wezterm"
ensure_dir "$WEZTERM_CONF_DIR"
write_file "$WEZTERM_CONF_DIR/wezterm.lua" content_wezterm

if [ "$IS_WSL" = true ]; then
    log_info "Attempting to sync WezTerm config to Windows..."
    if check_command wslpath && check_command cmd.exe; then
        WIN_USER_PROFILE=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
        if [ -n "$WIN_USER_PROFILE" ]; then
            WSL_WIN_HOME=$(wslpath "$WIN_USER_PROFILE")
            if [ -d "$WSL_WIN_HOME" ]; then
                # Windows also recommends .config/wezterm
                WIN_CONFIG_DIR="$WSL_WIN_HOME/.config/wezterm"
                ensure_dir "$WIN_CONFIG_DIR"
                write_file "$WIN_CONFIG_DIR/wezterm.lua" content_wezterm
                log_success "WezTerm config synced to Windows (.config/wezterm)."
            else
                log_warn "Windows user directory does not exist: $WSL_WIN_HOME"
            fi
        else
            log_warn "Unable to get Windows user profile path."
        fi
    else
        log_warn "wslpath or cmd.exe unavailable, skipping Windows sync."
    fi
fi

# 7. Install Plugins
log_info ">>> [5/6] Installing Plugins..."
PLUGIN_DIR="$HOME/.zsh/plugins"
ensure_dir "$PLUGIN_DIR"

git_clone_safe "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$PLUGIN_DIR/zsh-syntax-highlighting"
git_clone_safe "https://github.com/zsh-users/zsh-autosuggestions" "$PLUGIN_DIR/zsh-autosuggestions"

# 8. Generate Zsh Configuration
log_info ">>> [6/6] Generating Zsh Configuration..."

# 8.1 Generate .zshrc (Directly in Home directory)
write_file "$HOME/.zshrc" content_zshrc

# 9. Final Check & Switch Shell
log_info ">>> Performing Final Self-Check..."
[ -f "$HOME/.zshrc" ] || handle_error ".zshrc generation failed"
[ -f "$HOME/.config/starship.toml" ] || handle_error "Starship config generation failed"
[ -f "$HOME/.config/wezterm/wezterm.lua" ] || handle_error "WezTerm config generation failed"

if [ "$SHELL" != "$(which zsh)" ] && [ "$SHELL" != "/bin/zsh" ]; then
    log_info "Switching default Shell to Zsh..."
    chsh -s "$(which zsh)" || log_warn "Failed to switch Shell, please run manually: chsh -s \$(which zsh)"
fi

# 10. Cleanup Temporary Files & Old Config
log_info ">>> [7/7] Cleaning up temporary files & old config..."
rm -f "$HOME/.wget-hsts"
rm -f "$HOME/.zcompdump"*
rm -f "$HOME/.zshrc.tmp"
rm -f "$HOME/.config/wezterm/wezterm.lua.tmp"

# Cleanup old .zshenv (if exists)
if [ -f "$HOME/.zshenv" ]; then
    log_info "Cleanup: Removing ~/.zshenv (No longer using redirection)..."
    rm -f "$HOME/.zshenv"
fi

# Migration Cleanup: Remove old config files (if exist)
if [ -f "$HOME/.wezterm.lua" ]; then
    log_info "Migration: Removing old ~/.wezterm.lua (Moved to ~/.config/wezterm/)..."
    rm -f "$HOME/.wezterm.lua"
fi
if [ -f "$HOME/.fzf.zsh" ]; then
    log_info "Cleanup: Removing ~/.fzf.zsh (Config integrated into .zshrc)..."
    rm -f "$HOME/.fzf.zsh"
fi
# If .config/zsh/.zshrc was generated before, remove it
if [ -f "$HOME/.config/zsh/.zshrc" ]; then
    log_info "Cleanup: Removing ~/.config/zsh/.zshrc (Moved to ~/.zshrc)..."
    rm -f "$HOME/.config/zsh/.zshrc"
fi

echo "========================================================"
log_success "Deployment Completed Successfully!"
echo "--------------------------------------------------------"
echo "1. Backup saved to: $BACKUP_DIR"
echo "2. Zsh config generated at: ~/.zshrc"
echo "3. Please restart your terminal to apply changes."
echo ""
echo "⚠️  【Font Settings Reminder】"
echo "1. macOS Terminal.app / iTerm2:"
echo "   Please manually go to Preferences -> Profiles -> Text -> Font"
echo "   Select 'JetBrainsMono Nerd Font Mono' to display icons."
echo ""
echo "2. VS Code Integrated Terminal:"
echo "   Search for 'terminal.integrated.fontFamily' in Settings (Cmd+,)"
echo "   Enter: 'JetBrainsMono Nerd Font Mono'"
echo "========================================================"
