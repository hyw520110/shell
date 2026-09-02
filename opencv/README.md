# OpenCV 计算机视觉

> OpenCV 计算机视觉库的安装和配置脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install_opencv.sh` | OpenCV 安装脚本 | ❌ | ❌ |

## 🚀 快速开始

### 安装 OpenCV

```bash
cd opencv
./install_opencv.sh
```

## 🔧 详细说明

### install_opencv.sh - OpenCV 安装脚本

**功能**: 安装 OpenCV 计算机视觉库

**OpenCV 功能**:
- 图像处理
- 视频处理
- 机器学习
- 计算机视觉算法

**应用场景**:
- 图像识别
- 人脸识别
- 物体检测
- 图像分割
- 视频分析

**Python 示例**:
```python
import cv2

# 读取图像
image = cv2.imread('image.jpg')

# 显示图像
cv2.imshow('Image', image)
cv2.waitKey(0)

# 转换为灰度图
gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)

# 人脸检测
face_cascade = cv2.CascadeClassifier('haarcascade_frontalface_default.xml')
faces = face_cascade.detectMultiScale(gray, 1.1, 4)
```

## 🔗 相关链接

- [OpenCV 官方网站](https://opencv.org/)
- [OpenCV 文档](https://docs.opencv.org/)

## 📝 使用场景

- **图像处理**: 图像滤波、增强、变换
- **计算机视觉**: 人脸识别、物体检测、图像分割
- **视频分析**: 运动检测、视频跟踪
- **机器学习**: 特征提取、模型训练
