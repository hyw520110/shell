# Python 环境管理脚本

> Python 开发环境的自动化安装和管理工具集合

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `analyze_python_projects.py` | Python项目版本分析工具 | ✅ | ✅ |
| `analyze_python_projects.sh` | Python项目版本分析脚本 | ✅ | ✅ |
| `install-conda.sh` | Miniconda 安装脚本 | ❌ | ❌ |
| `install-pyenv.sh` | pyenv Python版本管理工具安装 | ❌ | ❌ |
| `install-uv.sh` | uv 快速包管理器安装 | ✅ | ✅ |
| `pydf.sh` | pydf 数据分析工具安装 | ❌ | ❌ |
| `python_process_check.sh` | Python进程检查和监控 | ❌ | ❌ |
| `uninstall_pip_package.sh` | 批量卸载pip包 | ❌ | ❌ |

## 🚀 快速开始

### 一键安装 Python 环境

#### 方式1: 使用 Conda（推荐新手）

```bash
cd python
./install-conda.sh
```

#### 方式2: 使用 pyenv（推荐开发者）

```bash
cd python
./install-pyenv.sh
pyenv install 3.11.0
pyenv global 3.11.0
```

#### 方式3: 使用 uv（推荐性能优先）

```bash
cd python
./install-uv.sh
uv venv myenv
source myenv/bin/activate
```

## 🔧 详细说明

### analyze_python_projects.py - Python项目版本分析

**功能**：分析指定目录下所有Python项目及其Python版本要求，评估升级兼容性

**使用方式**：
```bash
# 使用Python脚本
python3 analyze_python_projects.py [目录] [选项]

# 使用Shell脚本（推荐）
./analyze_python_projects.sh [目录] [选项]
```

**参数选项**：
- `目录`: 要分析的目录路径（默认：当前目录）
- `-v, --target-version VERSION`: 目标升级版本（默认：3.11.11）
- `-j, --json`: 输出JSON格式
- `-o, --output FILE`: 输出到文件
- `-d, --max-depth N`: 最大搜索深度（默认：5）

**使用示例**：
```bash
# 分析当前目录
./analyze_python_projects.sh

# 分析指定目录
./analyze_python_projects.sh /path/to/projects

# 输出JSON格式到文件
./analyze_python_projects.sh -j -o report.json

# 指定目标版本和搜索深度
./analyze_python_projects.sh -v 3.12.0 -d 3
```

**分析内容**：
- 🔍 自动识别Python项目（纯Python、混合项目）
- 📋 检查版本配置文件（.python-version、pyproject.toml、setup.py等）
- 🔗 识别项目类型（Flask、FastAPI、Django、ML等）
- 📦 提取主要依赖列表
- ✅ 评估升级到目标版本的兼容性
- 📊 生成详细的分析报告

**支持的版本配置文件**：
- `.python-version` (pyenv)
- `pyproject.toml` (poetry/setuptools)
- `setup.py` / `setup.cfg`
- `requirements.txt`
- `Pipfile` (pipenv)
- `runtime.txt` (Heroku)
- `.tool-versions` (asdf)
- `tox.ini`
- `.github/workflows/*.yml` (GitHub Actions)

**输出示例**：
```
================================================================================
Python项目版本分析报告
目标升级版本: 3.11.11
================================================================================

## 统计摘要
- 总项目数: 51
- 明确指定版本: 15
- 可安全升级: 49
- 需要评估: 2

## 项目类型分布
- pure-python: 43
- flask: 3
- java-python: 3
- ml: 1
- fastapi: 1
```

### install-conda.sh - Miniconda 安装

**功能**：安装 Miniconda（Anaconda 的轻量版本）

**安装方式**：
```bash
./install-conda.sh
```

**验证安装**：
```bash
conda --version
```

**常用命令**：
```bash
# 创建环境
conda create -n myenv python=3.11

# 激活环境
conda activate myenv

# 安装包
conda install numpy pandas

# 列出环境
conda env list

# 删除环境
conda remove -n myenv --all
```

### install-pyenv.sh - pyenv 安装

**功能**：安装 pyenv Python 版本管理工具

**安装方式**：
```bash
./install-pyenv.sh
```

**验证安装**：
```bash
pyenv --version
```

**常用命令**：
```bash
# 列出可用版本
pyenv install --list

# 安装特定版本
pyenv install 3.11.0

# 设置全局版本
pyenv global 3.11.0

# 设置当前目录版本
pyenv local 3.10.0

# 查看当前版本
pyenv version

# 查看已安装版本
pyenv versions
```

### install-uv.sh - uv 包管理器安装

**功能**：安装 uv（极快的 Python 包和项目管理器）

**安装方式**：
```bash
./install-uv.sh
```

**验证安装**：
```bash
uv --version
```

**常用命令**：
```bash
# 创建虚拟环境
uv venv myenv

# 安装包
uv pip install numpy

# 从requirements.txt安装
uv pip install -r requirements.txt

# 创建新项目
uv init myproject

# 运行脚本
uv run python script.py
```

**特性**：
- 极快的包安装速度（比pip快10-100倍）
- Rust 编写，内存占用低
- 支持依赖解析和锁定
- 兼容 PyPI 和其他包索引

### pydf.sh - pydf 工具安装

**功能**：安装 pydf（Python 数据框架工具）

**安装方式**：
```bash
./pydf.sh
```

**使用方式**：
```bash
# pydf 是一个数据分析工具
# 具体使用方式请查看官方文档
```

### python_process_check.sh - Python进程监控

**功能**：监控和管理 Python 进程

**安装方式**：
```bash
# 需要root权限
sudo ./python_process_check.sh
```

**功能说明**：
- 定时检查Python进程状态
- 自动重启异常进程
- 记录进程运行日志
- 配置检查时间窗口（默认晚上10点到早上8点）

**配置参数**：
```bash
START_HOUR=8    # 开始检查时间
END_HOUR=22     # 结束检查时间
```

### uninstall_pip_package.sh - 批量卸载包

**功能**：批量卸载指定的 pip 包

**使用方式**：
```bash
# 卸载当前目录环境的包
./uninstall_pip_package.sh

# 指定目录
./uninstall_pip_package.sh /path/to/project

# 指定日志文件
./uninstall_pip_package.sh /path/to/project /var/log/uninstall.log
```

**忽略列表**：
脚本会自动忽略基础包（如pip、setuptools、wheel等），避免破坏环境。

## 📊 Python开发环境分析

| 类别 | 工具 | 状态 | 脚本路径 |
|------|------|------|----------|
| **运行环境** | Python解释器 | ✅ | - |
| | pyenv | ✅ | python/install-pyenv.sh |
| | conda | ✅ | python/install-conda.sh |
| | uv | ✅ | python/install-uv.sh |
| | venv | ⚠️ | Python内置 |
| **包管理** | pip | ✅ | Python内置 |
| | uv | ✅ | python/install-uv.sh |
| | poetry | ❌ | - |
| | pipenv | ❌ | - |
| **开发工具** | black | ❌ | - |
| | flake8 | ❌ | - |
| | pylint | ❌ | - |
| | mypy | ❌ | - |
| **测试框架** | pytest | ❌ | - |
| | unittest | ⚠️ | Python内置 |
| | nose | ❌ | - |
| **IDE** | VS Code | ✅ | ../ide/install-vscode.sh |
| | PyCharm | ❌ | - |
| | Jupyter | ❌ | - |
| **数据分析** | pandas | ⚠️ | pydf.sh |
| | numpy | ⚠️ | pydf.sh |
| | matplotlib | ⚠️ | pydf.sh |
| | scipy | ❌ | - |
| **Web框架** | Django | ❌ | - |
| | Flask | ❌ | - |
| | FastAPI | ❌ | - |
| **监控工具** | python_process_check | ✅ | python/python_process_check.sh |

## ⚙️ 环境配置

### 常用环境变量

```bash
# Python 路径
export PYTHONPATH=/path/to/project

# pip 镜像源
export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# uv 配置
export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# conda 配置
export CONDA_CHANNELS=conda-forge
```

### 国内镜像源配置

**pip 配置**：
```bash
mkdir -p ~/.pip
cat > ~/.pip/pip.conf << EOF
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
```

**conda 配置**：
```bash
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free/
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/
conda config --set show_channel_urls yes
```

## ❓ 常见问题

### Q: 如何选择 Python 环境管理工具？

**A**: 根据需求选择：

- **新手/数据科学**: 使用 Conda，预装了科学计算包
- **开发者**: 使用 pyenv，可以管理多个 Python 版本
- **性能优先**: 使用 uv，包安装速度极快
- **轻量级**: 使用 Python 内置的 venv

### Q: 如何切换不同的 Python 版本？

**A**: 使用 pyenv 管理：

```bash
# 安装多个版本
pyenv install 3.8.0 3.9.0 3.10.0 3.11.0

# 全局设置
pyenv global 3.11.0

# 当前目录设置
cd myproject
pyenv local 3.10.0

# 临时设置
pyenv shell 3.9.0
```

### Q: 如何解决包安装速度慢的问题？

**A**: 使用国内镜像源或 uv：

```bash
# 使用 pip 镜像源
pip install -i https://pypi.tuna.tsinghua.edu.cn/simple package

# 使用 uv（推荐）
uv pip install package
```

### Q: 如何清理 Python 环境中的无用包？

**A**: 使用提供的脚本：

```bash
./uninstall_pip_package.sh
```

或者手动清理：

```bash
# 查看已安装包
pip list

# 批量卸载
pip uninstall package1 package2 package3
```

### Q: 如何设置 Jupyter Notebook？

**A**: 使用 Conda 或 pip 安装：

```bash
# Conda 方式
conda install jupyter

# pip 方式
pip install jupyter

# 启动
jupyter notebook
```

## 🔗 相关链接

- [Python 官方网站](https://www.python.org/)
- [Anaconda 官方网站](https://www.anaconda.com/)
- [pyenv 官方文档](https://github.com/pyenv/pyenv)
- [uv 官方文档](https://github.com/astral-sh/uv)
- [PyPI 官方网站](https://pypi.org/)

## 📝 最佳实践

### 项目结构

```
myproject/
├── .python-version       # pyenv版本锁定
├── requirements.txt      # 依赖列表
├── pyproject.toml        # 项目配置
├── src/                  # 源代码
└── tests/                # 测试代码
```

### 依赖管理

```bash
# 导出依赖
pip freeze > requirements.txt

# 安装依赖
pip install -r requirements.txt

# 使用 uv（推荐）
uv pip install -r requirements.txt
```

### 虚拟环境

```bash
# 创建虚拟环境
python -m venv venv

# 激活虚拟环境
source venv/bin/activate  # Linux/macOS
venv\Scripts\activate     # Windows

# 退出虚拟环境
deactivate
```

## 🚧 TODO

- [ ] 添加 Poetry 包管理工具安装脚本
- [ ] 添加 pipenv 包管理工具安装脚本
- [ ] 添加 Jupyter Notebook 安装脚本
- [ ] 添加常用开发工具（black、flake8、pylint）
- [ ] 添加测试框架（pytest）安装脚本
- [ ] 完善 Web 框架脚手架（Django、Flask、FastAPI）
- [ ] 添加 Docker 化 Python 应用模板
- [ ] 添加 CI/CD 配置模板

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本仓库采用 MIT 许可证，详见根目录 LICENSE 文件。