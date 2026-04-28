# FlClash 登录门控实施记录

更新时间：2026-04-28

## 目标

为 FlClash 增加启动即登录的功能——用户必须先登录 V2Board 面板才能使用程序。

- 面板地址硬编码：`https://gettakeoff.cc`
- 未登录时不允许进入主界面，按返回键直接退出程序
- 登录成功后自动导入订阅 Profile
- 已登录用户再次启动时自动验证 session，有效则直接进入

## 最终方案

**单 MaterialApp + Navigator.push 登录页**——不修改 `main.dart`，在主应用首帧渲染后，用 `Navigator.push` 将全屏登录页覆盖在已有 UI 之上。

```
main()
  → globalState.init()     ← 正常初始化（数据库、配置、ProviderContainer）
  → runApp(Application)    ← 正常启动主应用、窗口创建
     → 首帧渲染完毕
        → initState 回调:
           1. appController.attach()   ← 先 attach，管理器需要 _ref
           2. 检查 SharedPreferences 是否有有效 session
           3. 无效 → Navigator.push(LoginPage)  ← 全屏覆盖
               └─ 用户登录 → Navigator.pop → 继续
           4. 导入订阅 URL → 主应用就绪
```

## 失败尝试记录

### 尝试 1：Consumer 中切换 MaterialApp（❌）

在 `application.dart` 的 `build()` 中，用 `Consumer` 根据 authState 返回不同的 `MaterialApp`。

**失败原因**：Windows 平台上反复重建 `MaterialApp` 导致原生窗口无法初始化。

### 尝试 2：在 `main()` 中用双 runApp（❌）

登录时先 `runApp(极简 MaterialApp(LoginPage))`，`await Completer` 等待登录完成后，再 `runApp(主应用)`。

**失败原因**：第一个 `runApp` 在 Windows 上不创建窗口。经测试，必须用 `Future.delayed` 而非 `Completer.future` 才能让窗口有机会初始化。但 `Completer.future` 又必须用于等待用户操作，两者矛盾。

### 尝试 3：在 main.dart 之前插入登录判断（❌）

在 `main()` 函数开头，`globalState.init()` 之前，用极简 SharedPreferences 检查登录状态。

**失败原因**：如果存在旧的 session 数据，`checkLogin()` HTTP 请求可能在 `FlClashHttpOverrides` 设置之前执行（该 Override 依赖 `appController`）。另外 `globalState.init()` 之后的管理器初始化时序问题依然存在。

### 尝试 4：_isReady 门控延迟管理器创建（❌）

添加 `_isReady` 状态变量，在 `appController.attach()` 完成后才创建 CoreManager 等管理器。

**失败原因**：`setState` 触发重建时管理器重新创建，而 `attach()` 是异步的，形成循环依赖。最终窗口无法出现。

## 最终文件清单

### 修改的文件（3个）

| 文件 | 改动 | 说明 |
|---|---|---|
| `lib/application.dart` | +36 行 | `initState` 首帧回调中插入登录检查 |
| `lib/features/v2board/client.dart` | +21 行 | 增加 `checkLogin()` 方法 + `lastAuthData`/`lastToken` 字段 |
| `lib/main.dart` | 不变 | 完全恢复原始版本 |

### 新增的文件（2个）

| 文件 | 说明 |
|---|---|
| `lib/features/v2board/auth_store.dart` | 独立 SharedPreferences 封装，用于保存/读取/清除登录凭证 |
| `lib/features/v2board/login_page.dart` | 全屏登录页，网址硬编码，无返回按钮，按返回键退出程序 |

### 未修改的文件

所有其他源文件完全未动，包括：
- `lib/state.dart`、`lib/controller.dart`
- `lib/models/`、`lib/providers/`
- `lib/common/`、`lib/views/`、`lib/widgets/`
- `lib/pages/`、`lib/manager/`

## 关键技术点

### 1. appController.attach() 必须最先执行

`CoreManager`、`ConnectivityManager` 等管理器在 `builder` 回调中创建，首帧渲染后通过 Riverpod 触发操作时依赖 `appController._ref`。因此 `attach()` 必须在 `initState` 的 `addPostFrameCallback` 中第一个执行。

### 2. Navigator.push 覆盖而非替换 MaterialApp

用 `Navigator.push` 将登录页作为全屏路由推到主应用之上，避免了重建 `MaterialApp` 导致的窗口初始化问题。登录成功后 `pop` 即可。

### 3. PopScope 拦截返回键

用 `PopScope(canPop: false)` 拦截系统返回键，未登录时按返回键直接 `exit(0)` 退出程序。已登录时正常 `pop`。

### 4. SharedPreferences 独立封装

`AuthStore` 完全独立，不依赖项目的 `lib/common/preferences.dart`，避免循环依赖。

## V2Board API 对接

基于 `D:\yuanma\v2board` 源码确认：

| 接口 | 方法 | 用途 |
|---|---|---|
| `/api/v1/passport/auth/login` | POST | 登录，获取 `auth_data` + `token` |
| `/api/v1/user/checkLogin` | GET | 验证 session 是否有效 |
| `/api/v1/user/getSubscribe` | GET | 获取订阅 URL（加 `flag=meta` 确保 ClashMeta 格式） |

鉴权方式：请求头 `Authorization: <auth_data>`
