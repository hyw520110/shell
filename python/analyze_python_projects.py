#!/usr/bin/env python3
"""
Python项目版本分析工具
分析指定目录下的所有Python项目及其Python版本要求
"""

import os
import re
import sys
import json
import argparse
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field, asdict
from collections import defaultdict


@dataclass
class PythonProject:
    """Python项目信息"""
    path: str
    project_type: str = "unknown"  # pure_python, mixed, web, ml, etc.
    python_version: Optional[str] = None
    version_sources: List[str] = field(default_factory=list)
    has_venv: bool = False
    dependencies: List[str] = field(default_factory=list)
    is_upgrade_safe: bool = True
    needs_upgrade: bool = True  # 是否需要升级（已满足要求则为False）
    upgrade_issues: List[str] = field(default_factory=list)


class PythonProjectAnalyzer:
    """Python项目分析器"""
    
    # Python版本配置文件
    VERSION_FILES = {
        '.python-version': 'pyenv',
        '.python-version-pre': 'pyenv-pre',
        'runtime.txt': 'Heroku/runtime.txt',
        '.tool-versions': 'asdf',
    }
    
    # Python项目标识文件
    PROJECT_FILES = [
        'pyproject.toml',
        'setup.py',
        'setup.cfg',
        'requirements.txt',
        'Pipfile',
        'poetry.lock',
        'Pipfile.lock',
        'tox.ini',
        'Makefile',
        'requirements',
        'constraints.txt',
    ]
    
    # 独立项目核心标识文件（有这些文件才是独立项目）
    ROOT_PROJECT_FILES = [
        'pyproject.toml',
        'setup.py',
        'setup.cfg',
        'Pipfile',
    ]
    
    # Python目录标识
    PYTHON_DIRS = [
        'venv', '.venv', 'env', '.env',
        '__pycache__', '.pytest_cache', '.mypy_cache',
        'src', 'lib', 'tests', 'test',
    ]
    
    def __init__(self, target_version: str = "3.11.11"):
        self.target_version = target_version
        self.projects: List[PythonProject] = []
        
    def find_python_projects(self, root_dir: str, max_depth: int = 5) -> List[str]:
        """查找所有顶级Python项目目录（合并子目录）"""
        root_path = Path(root_dir).resolve()
        
        # 这些目录名通常不是独立项目，而是子模块
        subproject_dirs = {'src', 'lib', 'tests', 'test', 'utils', 'core', 
                          'models', 'scripts', 'examples', 'kws', 'wakeword', 
                          'crawler', 'processor', 'rpa', 'scheduler', 
                          'browser', 'database', 'heal', 'logging', 'queue',
                          'stream', 'config', 'api_utils', 'browser_utils', 
                          'logging_utils', 'model_evaluation', 'tools'}
        
        # 第一步：收集所有候选项目
        candidates = {}  # path -> has_core_project_file
        
        for dirpath, dirnames, filenames in os.walk(root_dir):
            # 只跳过隐藏目录和构建/缓存目录
            dirnames[:] = [d for d in dirnames if not d.startswith('.') and 
                          d not in ['node_modules', '__pycache__', 'venv', '.venv', 
                                   'env', '.env', 'build', 'dist', 'target', 
                                   '.git', '.idea', '.vscode']]
            
            current_path = Path(dirpath)
            rel_depth = len(current_path.relative_to(root_path).parts)
            
            if rel_depth > max_depth:
                dirnames[:] = []
                continue
            
            # 检查当前目录名是否是子模块目录名
            dir_name = current_path.name
            
            # 强制排除常见的子模块目录名
            if dir_name in subproject_dirs:
                continue
            
            # 检查是否有核心项目标识文件
            has_core_project_file = any(proj_file in filenames for proj_file in self.ROOT_PROJECT_FILES)
            
            # 检查是否为Python项目
            is_python_project = False
            
            # 1. 有核心项目标识文件
            if has_core_project_file:
                is_python_project = True
            
            # 2. 有版本文件
            elif '.python-version' in filenames:
                is_python_project = True
            
            # 3. 有虚拟环境
            elif any(venv in dirnames for venv in ['venv', '.venv', 'env']):
                is_python_project = True
            
            # 4. 有requirements.txt + Python文件
            elif 'requirements.txt' in filenames:
                py_files = [f for f in filenames if f.endswith('.py')]
                if len(py_files) >= 1:
                    is_python_project = True
            
            if is_python_project:
                candidates[dirpath] = has_core_project_file
        
        # 第二步：合并处理，移除子项目或合并父项目
        python_projects = set()
        
        for path, has_core in sorted(candidates.items(), key=lambda x: x[0]):
            path_obj = Path(path)
            
            # 检查是否已有父项目
            has_parent_project = False
            for existing in list(python_projects):
                existing_path = Path(existing)
                try:
                    path_obj.relative_to(existing_path)
                    # 当前路径是已存在项目的子目录
                    if not has_core:
                        # 当前项目没有核心文件，不添加
                        has_parent_project = True
                        break
                    # 当前项目有核心文件，检查父项目是否有核心文件
                    if candidates.get(existing, False):
                        # 父项目也有核心文件，两个都是独立项目
                        pass
                    else:
                        # 父项目没有核心文件，移除父项目，添加当前项目
                        python_projects.remove(existing)
                except ValueError:
                    pass
            
            if not has_parent_project:
                python_projects.add(path)
        
        return sorted(list(python_projects))
    
    def extract_version_from_string(self, content: str) -> Optional[str]:
        """从字符串中提取Python版本号"""
        # 匹配各种版本格式
        patterns = [
            r'python[=\s]*(3?\.\d+\.?\d*)',  # python=3.9.0 or python 3.9
            r'[=<>]+\s*3\.\d+\.?\d*',  # >=3.8, ==3.9.0
            r'3\.\d+\.?\d*',  # 直接的版本号
            r'py3\d+',  # py39, py310
        ]
        
        for pattern in patterns:
            match = re.search(pattern, content, re.IGNORECASE)
            if match:
                version = match.group(0) if match.lastindex is None else match.group(1)
                # 标准化版本号
                version = version.replace('py', '').replace('=', '').replace('>', '').replace('<', '').strip()
                if not version.startswith('3.'):
                    version = '3.' + version if version.replace('.', '').isdigit() else version
                return version
        
        return None
    
    def check_pyproject_toml(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 pyproject.toml 文件"""
        pyproject_path = project_path / 'pyproject.toml'
        if not pyproject_path.exists():
            return None, []
        
        content = pyproject_path.read_text(encoding='utf-8', errors='ignore')
        versions = []
        sources = []
        
        # 查找 requires-python
        match = re.search(r'requires-python\s*=\s*["\']([^"\']+)["\']', content)
        if match:
            version_spec = match.group(1)
            versions.append(version_spec)
            sources.append(f'pyproject.toml (requires-python): {version_spec}')
        
        # 查找项目依赖中的Python版本
        match = re.search(r'python\s*=\s*["\']([^"\']+)["\']', content)
        if match:
            version_spec = match.group(1)
            versions.append(version_spec)
            sources.append(f'pyproject.toml (python dependency): {version_spec}')
        
        return versions[0] if versions else None, sources
    
    def check_setup_cfg(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 setup.cfg 文件"""
        setup_cfg_path = project_path / 'setup.cfg'
        if not setup_cfg_path.exists():
            return None, []
        
        content = setup_cfg_path.read_text(encoding='utf-8', errors='ignore')
        sources = []
        
        # 查找 python_requires
        match = re.search(r'python_requires\s*=\s*(.+)', content)
        if match:
            version_spec = match.group(1).strip()
            sources.append(f'setup.cfg (python_requires): {version_spec}')
            return version_spec, sources
        
        return None, sources
    
    def check_setup_py(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 setup.py 文件"""
        setup_py_path = project_path / 'setup.py'
        if not setup_py_path.exists():
            return None, []
        
        content = setup_py_path.read_text(encoding='utf-8', errors='ignore')
        sources = []
        
        # 查找 python_requires
        match = re.search(r'python_requires\s*=\s*["\']([^"\']+)["\']', content)
        if match:
            version_spec = match.group(1)
            sources.append(f'setup.py (python_requires): {version_spec}')
            return version_spec, sources
        
        return None, sources
    
    def check_runtime_txt(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 runtime.txt 文件 (Heroku)"""
        runtime_path = project_path / 'runtime.txt'
        if not runtime_path.exists():
            return None, []
        
        content = runtime_path.read_text(encoding='utf-8', errors='ignore').strip()
        sources = []
        
        # Heroku格式: python-3.9.0
        match = re.search(r'python-(\d+\.\d+\.\d+)', content)
        if match:
            version = match.group(1)
            sources.append(f'runtime.txt: {version}')
            return version, sources
        
        return None, sources
    
    def check_python_version_file(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 .python-version 文件 (pyenv)"""
        version_path = project_path / '.python-version'
        if not version_path.exists():
            return None, []
        
        content = version_path.read_text(encoding='utf-8', errors='ignore').strip()
        sources = [f'.python-version: {content}']
        
        # 提取版本号
        version = self.extract_version_from_string(content)
        return version or content, sources
    
    def check_pipfile(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 Pipfile 文件"""
        pipfile_path = project_path / 'Pipfile'
        if not pipfile_path.exists():
            return None, []
        
        content = pipfile_path.read_text(encoding='utf-8', errors='ignore')
        sources = []
        
        # 查找 python_version
        match = re.search(r'python_version\s*=\s*["\']([^"\']+)["\']', content)
        if match:
            version = match.group(1)
            sources.append(f'Pipfile: {version}')
            return version, sources
        
        return None, sources
    
    def check_tool_versions(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 .tool-versions 文件 (asdf)"""
        tool_versions_path = project_path / '.tool-versions'
        if not tool_versions_path.exists():
            return None, []
        
        content = tool_versions_path.read_text(encoding='utf-8', errors='ignore')
        sources = []
        
        # 查找 python 行
        for line in content.split('\n'):
            if line.strip().startswith('python'):
                parts = line.split()
                if len(parts) >= 2:
                    version = parts[1]
                    sources.append(f'.tool-versions: {version}')
                    return version, sources
        
        return None, sources
    
    def check_github_actions(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 GitHub Actions 配置"""
        workflows_dir = project_path / '.github' / 'workflows'
        if not workflows_dir.exists():
            return None, []
        
        versions = []
        sources = []
        
        for yaml_file in workflows_dir.glob('*.yml'):
            try:
                content = yaml_file.read_text(encoding='utf-8', errors='ignore')
                # 查找 python-version
                matches = re.findall(r'python-version:\s*["\']?([^"\'\s]+)', content)
                for match in matches:
                    sources.append(f'.github/workflows/{yaml_file.name}: {match}')
                    if match not in versions:
                        versions.append(match)
            except Exception:
                pass
        
        return versions[0] if versions else None, sources
    
    def check_tox_ini(self, project_path: Path) -> Tuple[Optional[str], List[str]]:
        """检查 tox.ini 文件"""
        tox_path = project_path / 'tox.ini'
        if not tox_path.exists():
            return None, []
        
        content = tox_path.read_text(encoding='utf-8', errors='ignore')
        sources = []
        
        # 查找 envlist 或 basepython
        match = re.search(r'basepython\s*=\s*(.+)', content)
        if match:
            version_spec = match.group(1).strip()
            sources.append(f'tox.ini (basepython): {version_spec}')
            return version_spec, sources
        
        return None, sources
    
    def analyze_project(self, project_path: str) -> PythonProject:
        """分析单个Python项目"""
        path = Path(project_path)
        project = PythonProject(path=str(path.resolve()))
        
        # 检查所有版本来源
        version_checks = [
            self.check_pyproject_toml,
            self.check_setup_cfg,
            self.check_setup_py,
            self.check_runtime_txt,
            self.check_python_version_file,
            self.check_pipfile,
            self.check_tool_versions,
            self.check_github_actions,
            self.check_tox_ini,
        ]
        
        for check_func in version_checks:
            version, sources = check_func(path)
            if version:
                if not project.python_version:
                    project.python_version = version
                project.version_sources.extend(sources)
        
        # 检查是否有虚拟环境
        for venv_dir in ['venv', '.venv', 'env']:
            if (path / venv_dir).exists():
                project.has_venv = True
                break
        
        # 判断项目类型
        project.project_type = self._determine_project_type(path)
        
        # 提取主要依赖
        project.dependencies = self._extract_dependencies(path)
        
        # 评估升级兼容性
        self._check_upgrade_compatibility(project)
        
        return project
    
    def _determine_project_type(self, path: Path) -> str:
        """判断项目类型"""
        # 检查是否为混合项目
        mixed_indicators = [
            'pom.xml', 'build.gradle', 'package.json', 'Cargo.toml',
            'go.mod', 'composer.json', 'Gemfile'
        ]
        
        for indicator in mixed_indicators:
            if (path / indicator).exists():
                if indicator == 'pom.xml':
                    return 'java-python'
                elif indicator == 'package.json':
                    return 'node-python'
                elif indicator == 'go.mod':
                    return 'go-python'
                else:
                    return 'mixed'
        
        # 检查Python项目类型
        pyproject = path / 'pyproject.toml'
        if pyproject.exists():
            content = pyproject.read_text(encoding='utf-8', errors='ignore')
            
            # 检查常见框架和工具
            if 'django' in content.lower():
                return 'django'
            elif 'flask' in content.lower():
                return 'flask'
            elif 'fastapi' in content.lower():
                return 'fastapi'
            elif 'tensorflow' in content.lower() or 'torch' in content.lower():
                return 'ml'
            elif 'pytest' in content.lower():
                return 'testing'
        
        # 检查目录结构
        if (path / 'src').exists():
            return 'src-layout'
        
        return 'pure-python'
    
    def _extract_dependencies(self, path: Path, max_deps: int = 10) -> List[str]:
        """提取主要依赖"""
        dependencies = []
        
        # 从 pyproject.toml 提取
        pyproject = path / 'pyproject.toml'
        if pyproject.exists():
            content = pyproject.read_text(encoding='utf-8', errors='ignore')
            # 查找 dependencies 部分
            in_deps = False
            for line in content.split('\n'):
                if 'dependencies' in line and '=' in line:
                    in_deps = True
                elif in_deps and line.strip().startswith('"'):
                    match = re.match(r'\s*"([^"]+)"', line)
                    if match:
                        dep = match.group(1).split('[')[0].split('=')[0].split('<')[0].split('>')[0].strip()
                        if dep and dep not in dependencies:
                            dependencies.append(dep)
                elif in_deps and line.strip() == ']':
                    break
        
        # 从 requirements.txt 提取
        req_file = path / 'requirements.txt'
        if req_file.exists() and len(dependencies) < max_deps:
            content = req_file.read_text(encoding='utf-8', errors='ignore')
            for line in content.split('\n'):
                line = line.strip()
                if line and not line.startswith('#'):
                    dep = line.split('==')[0].split('>=')[0].split('<=')[0].split('~=')[0].strip()
                    if dep and dep not in dependencies:
                        dependencies.append(dep)
        
        return dependencies[:max_deps]
    
    def _check_upgrade_compatibility(self, project: PythonProject):
        """检查升级到目标版本的兼容性"""
        target_major, target_minor, target_patch = map(int, self.target_version.split('.'))
        target_version_tuple = (target_major, target_minor, target_patch)
        
        if not project.python_version:
            project.is_upgrade_safe = True
            project.needs_upgrade = True
            project.upgrade_issues = ["未指定Python版本要求，建议明确版本"]
            return
        
        # 解析当前版本要求
        version_str = project.python_version
        
        # 处理版本范围
        if '>=' in version_str or '<=' in version_str or '>' in version_str or '<' in version_str:
            # 提取版本号
            versions = re.findall(r'(\d+)\.(\d+)(?:\.(\d+))?', version_str)
            
            min_required = None
            max_allowed = None
            
            for major, minor, patch in versions:
                major, minor = int(major), int(minor)
                patch = int(patch) if patch else 0
                version_tuple = (major, minor, patch)
                
                # 解析版本范围
                if '>=' in version_str:
                    # 查找 >= 后面的版本作为最低要求
                    match = re.search(r'>=\s*(\d+)\.(\d+)(?:\.(\d+))?', version_str)
                    if match:
                        min_required = (int(match.group(1)), int(match.group(2)), 
                                       int(match.group(3)) if match.group(3) else 0)
                
                if '<=' in version_str:
                    match = re.search(r'<=\s*(\d+)\.(\d+)(?:\.(\d+))?', version_str)
                    if match:
                        max_allowed = (int(match.group(1)), int(match.group(2)),
                                      int(match.group(3)) if match.group(3) else 0)
                
                if '>' in version_str and '=' not in version_str:
                    match = re.search(r'>\s*(\d+)\.(\d+)(?:\.(\d+))?', version_str)
                    if match:
                        v = (int(match.group(1)), int(match.group(2)),
                            int(match.group(3)) if match.group(3) else 0)
                        # 大于某版本，最低要求是v+1
                        min_required = (v[0], v[1], v[2] + 1)
                
                if '<' in version_str and '=' not in version_str:
                    match = re.search(r'<\s*(\d+)\.(\d+)(?:\.(\d+))?', version_str)
                    if match:
                        v = (int(match.group(1)), int(match.group(2)),
                            int(match.group(3)) if match.group(3) else 0)
                        # 小于某版本，最大允许是v-1
                        max_allowed = (v[0], v[1], max(0, v[2] - 1))
            
            # 检查目标版本是否在范围内
            satisfies_min = min_required is None or target_version_tuple >= min_required
            satisfies_max = max_allowed is None or target_version_tuple <= max_allowed
            
            if satisfies_min and satisfies_max:
                project.needs_upgrade = False
                project.upgrade_issues.append(f"当前版本要求 {version_str} 已满足目标版本 {self.target_version}")
            elif not satisfies_min:
                project.is_upgrade_safe = False
                project.needs_upgrade = True
                project.upgrade_issues.append(f"要求 {version_str}，目标版本不满足最低要求")
            elif not satisfies_max:
                project.is_upgrade_safe = False
                project.needs_upgrade = True
                project.upgrade_issues.append(f"要求 {version_str}，目标版本超出最大允许版本")
        
        else:
            # 单个版本要求（精确版本或最低版本）
            version = self.extract_version_from_string(version_str)
            if version:
                try:
                    parts = version.replace('py', '').split('.')
                    if len(parts) >= 2:
                        current_major = int(parts[0]) if parts[0] else 3
                        current_minor = int(parts[1])
                        current_patch = int(parts[2]) if len(parts) > 2 else 0
                        current_version_tuple = (current_major, current_minor, current_patch)
                        
                        # 如果是精确版本要求（如 3.10.13）
                        if current_version_tuple == target_version_tuple:
                            project.needs_upgrade = False
                            project.upgrade_issues.append(f"当前版本 {version} 已等于目标版本 {self.target_version}")
                        # 如果当前版本 >= 目标版本
                        elif current_version_tuple >= target_version_tuple:
                            project.needs_upgrade = False
                            project.upgrade_issues.append(f"当前版本 {version} 已满足目标版本 {self.target_version}")
                        else:
                            # 当前版本 < 目标版本，需要升级
                            project.needs_upgrade = True
                            if current_minor < 9:
                                project.upgrade_issues.append("从Python 3.8或更早版本升级，需要检查弃用的API")
                        
                        # 检查依赖兼容性
                        for dep in project.dependencies:
                            if dep.lower() in ['numpy', 'scipy', 'pandas']:
                                if project.needs_upgrade:
                                    project.upgrade_issues.append(f"检查 {dep} 的Python 3.11兼容版本")
                        
                except (ValueError, IndexError):
                    pass
        
        # 检查项目类型特定的兼容性问题
        if project.project_type == 'ml' and project.needs_upgrade:
            project.upgrade_issues.append("ML项目需要检查深度学习框架的Python 3.11支持")
        
    def analyze_directory(self, directory: str) -> List[PythonProject]:
        """分析目录下的所有Python项目"""
        print(f"正在扫描目录: {directory}")
        
        # 查找Python项目
        project_paths = self.find_python_projects(directory)
        print(f"找到 {len(project_paths)} 个Python项目\n")
        
        # 分析每个项目
        for idx, path in enumerate(project_paths, 1):
            print(f"[{idx}/{len(project_paths)}] 分析: {path}")
            project = self.analyze_project(path)
            self.projects.append(project)
        
        return self.projects
    
    def generate_report(self) -> str:
        """生成分析报告"""
        report = []
        report.append("=" * 80)
        report.append("Python项目版本分析报告")
        report.append(f"目标升级版本: {self.target_version}")
        report.append("=" * 80)
        report.append("")
        
        # 统计信息
        report.append("## 统计摘要\n")
        total = len(self.projects)
        safe_count = sum(1 for p in self.projects if p.is_upgrade_safe)
        needs_upgrade_count = sum(1 for p in self.projects if p.needs_upgrade)
        no_upgrade_count = total - needs_upgrade_count
        has_version = sum(1 for p in self.projects if p.python_version)
        
        report.append(f"- 总项目数: {total}")
        report.append(f"- 明确指定版本: {has_version}")
        report.append(f"- 无需升级: {no_upgrade_count}")
        report.append(f"- 需要升级: {needs_upgrade_count}")
        report.append(f"- 需要评估: {total - safe_count}")
        report.append("")
        
        # 项目类型分布
        type_dist = defaultdict(int)
        for p in self.projects:
            type_dist[p.project_type] += 1
        
        report.append("## 项目类型分布\n")
        for ptype, count in sorted(type_dist.items(), key=lambda x: -x[1]):
            report.append(f"- {ptype}: {count}")
        report.append("")
        
        # 详细项目列表
        report.append("## 项目详情\n")
        
        for idx, project in enumerate(self.projects, 1):
            report.append(f"### {idx}. {Path(project.path).name}\n")
            report.append(f"**路径**: `{project.path}`")
            report.append(f"**类型**: {project.project_type}")
            
            if project.python_version:
                report.append(f"**Python版本**: {project.python_version}")
            else:
                report.append("**Python版本**: 未指定")
            
            if project.version_sources:
                report.append(f"**版本来源**:")
                for source in project.version_sources:
                    report.append(f"  - {source}")
            
            if project.has_venv:
                report.append("**虚拟环境**: ✓ 存在")
            
            if project.dependencies:
                report.append(f"**主要依赖**: {', '.join(project.dependencies[:5])}")
            
            # 升级建议
            if not project.needs_upgrade:
                status = "✅ 无需升级"
            elif project.is_upgrade_safe:
                status = "⬆️ 可以升级"
            else:
                status = "⚠️ 需要评估"
            report.append(f"**升级状态**: {status}")
            
            if project.upgrade_issues:
                report.append("**注意事项**:")
                for issue in project.upgrade_issues:
                    report.append(f"  - {issue}")
            
            report.append("")
        
        # 升级建议
        report.append(f"## 升级到 Python {self.target_version} 的建议\n")
        
        # 无需升级的项目
        no_upgrade_projects = [p for p in self.projects if not p.needs_upgrade]
        if no_upgrade_projects:
            report.append(f"### 无需升级的项目 ({len(no_upgrade_projects)}个)\n")
            for project in no_upgrade_projects:
                report.append(f"- **{Path(project.path).name}**: {project.python_version or '未指定'}")
            report.append("")
        
        # 需要升级的项目
        needs_upgrade_projects = [p for p in self.projects if p.needs_upgrade]
        if needs_upgrade_projects:
            report.append(f"### 需要升级的项目 ({len(needs_upgrade_projects)}个)\n")
            for project in needs_upgrade_projects:
                issues = project.upgrade_issues[0] if project.upgrade_issues else ""
                report.append(f"- **{Path(project.path).name}**: {project.python_version or '未指定'}")
                if issues and project.is_upgrade_safe:
                    report.append(f"  - {issues}")
            report.append("")
        
        # 需要特别注意的项目
        issues_projects = [p for p in self.projects if not p.is_upgrade_safe]
        if issues_projects:
            report.append(f"### 需要特别注意的项目 ({len(issues_projects)}个)\n")
            for project in issues_projects:
                report.append(f"- **{Path(project.path).name}**: {', '.join(project.upgrade_issues[:2])}")
            report.append("")
        report.append("### 升级步骤建议")
        report.append("")
        report.append("1. **备份当前环境**")
        report.append("   - 记录当前Python版本和依赖")
        report.append("   - 导出requirements.txt或环境配置")
        report.append("")
        report.append("2. **安装Python 3.11.11**")
        report.append("   - 使用pyenv: `pyenv install 3.11.11`")
        report.append("   - 或使用conda: `conda install python=3.11.11`")
        report.append("")
        report.append("3. **重建虚拟环境**")
        report.append("   - 删除旧的venv目录")
        report.append("   - 创建新的虚拟环境: `python3.11 -m venv .venv`")
        report.append("   - 重新安装依赖: `pip install -r requirements.txt`")
        report.append("")
        report.append("4. **测试验证**")
        report.append("   - 运行单元测试")
        report.append("   - 检查弃用警告")
        report.append("   - 验证关键功能")
        report.append("")
        
        return "\n".join(report)
    
    def to_json(self) -> str:
        """导出为JSON格式"""
        data = {
            'target_version': self.target_version,
            'total_projects': len(self.projects),
            'projects': [asdict(p) for p in self.projects]
        }
        return json.dumps(data, indent=2, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(
        description='分析Python项目及其Python版本要求',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 分析当前目录
  %(prog)s
  
  # 分析指定目录
  %(prog)s /path/to/projects
  
  # 输出JSON格式
  %(prog)s --json
  
  # 指定目标版本（短参数）
  %(prog)s -t 3.12.0
  
  # 指定目标版本（长参数）
  %(prog)s --target-version 3.12.0
        """
    )
    
    parser.add_argument(
        'directory',
        nargs='?',
        default=os.getcwd(),
        help='要分析的目录路径 (默认: 当前目录)'
    )
    
    parser.add_argument(
        '-t', '--target-version',
        default='3.11.11',
        help='目标升级版本 (默认: 3.11.11)'
    )
    
    parser.add_argument(
        '--json',
        action='store_true',
        help='输出JSON格式结果'
    )
    
    parser.add_argument(
        '--output', '-o',
        help='输出文件路径'
    )
    
    parser.add_argument(
        '--max-depth',
        type=int,
        default=5,
        help='最大搜索深度 (默认: 5)'
    )
    
    args = parser.parse_args()
    
    # 验证目录
    if not os.path.isdir(args.directory):
        print(f"错误: 目录不存在: {args.directory}", file=sys.stderr)
        sys.exit(1)
    
    # 验证目标版本格式
    version_pattern = r'^\d+\.\d+(\.\d+)?$'
    if not re.match(version_pattern, args.target_version):
        print(f"错误: 无效的版本号格式: {args.target_version}", file=sys.stderr)
        print("正确格式示例: 3.11.11 或 3.12", file=sys.stderr)
        sys.exit(1)
    
    # 创建分析器
    analyzer = PythonProjectAnalyzer(target_version=args.target_version)
    
    # 执行分析
    try:
        analyzer.analyze_directory(args.directory)
        
        # 生成报告
        if args.json:
            result = analyzer.to_json()
        else:
            result = analyzer.generate_report()
        
        # 输出结果
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(result)
            print(f"报告已保存到: {args.output}")
        else:
            print(result)
            
    except KeyboardInterrupt:
        print("\n分析已取消")
        sys.exit(1)
    except Exception as e:
        print(f"分析出错: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
