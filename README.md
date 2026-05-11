# Nura.ai (MVP v0.1)

独立新产品，和 NuraLogix 无关。

## 目标
先跑通初版：
- iOS 文字聊天
- 匿名登录
- 情绪识别（文本）
- 后端部署在 Hostinger VPS
- 本地 Xcode 编译运行

## 目录
- `backend/` FastAPI 服务
- `ios/NuraAI/` SwiftUI 源码骨架（可直接拷进 Xcode 新建工程）

---

## Backend 本地运行
```bash
cd backend
./run_local.sh
```

健康检查：
```bash
curl http://127.0.0.1:8010/healthz
```

## Backend API
- `POST /api/v1/auth/anonymous`
- `POST /api/v1/chat/message`
- `POST /api/v1/emotion/analyze`
- `GET /healthz`

---

## VPS 部署（Hostinger）
1. 把 `backend/` 上传到 VPS
2. 创建 venv，安装 requirements
3. 配置 `.env`（复制 `.env.example`）
4. `uvicorn app.main:app --host 0.0.0.0 --port 8010`
5. 用 systemd 挂常驻（建议）

---

## iOS 接入方式（参考 AI Stock Assistant）
1. 本地 Xcode 新建 App：`NuraAI`
2. 将 `ios/NuraAI/*.swift` 拖入工程
3. 把 `AppState.apiBaseURL` 改成你的 VPS 地址（例如 `http://100.99.145.120:8010/api/v1`）
4. 真机运行测试

---

## Day1-Day7 压缩版交付状态
- [x] Day1: 后端骨架、DB、健康检查
- [x] Day2: 匿名登录、token
- [x] Day3: 聊天接口 + LLM/fallback
- [x] Day4: 文本情绪分析
- [x] Day5: iOS 聊天 UI 骨架
- [x] Day6: iOS-Backend 打通（代码已就绪）
- [x] Day7: 文档与部署说明

> 说明：语音 STT/TTS 可在下一迭代直接接入（你已有现成链路经验）。
