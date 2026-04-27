# FlClash 接入 V2Board 记录

更新时间：2026-03-09

## 目标

在尽量少改动 FlClash 源码的前提下，为软件增加一个 V2Board 登录入口，并把登录后的订阅自动接入现有配置导入流程。

## 当前结论

最小改动方案不是直接重做启动页或全局鉴权，而是在现有“添加配置”入口中增加一个 `V2Board 登录` 选项。

登录成功后，走下面这条复用链路：

1. 调用 V2Board 登录接口获取 `token` 和 `auth_data`
2. 使用 `auth_data` 调用用户订阅信息接口
3. 从返回结果中拿到 `subscribe_url`
4. 将订阅地址强制追加或改写为 `flag=meta`
5. 把这个 URL 交给 FlClash 现有的 `Profile.normal(url).update()` 流程

这样可以直接复用：

- 现有 URL 导入逻辑
- 现有 Profile 存储与更新逻辑
- 现有自动更新订阅逻辑
- 现有订阅流量信息展示

## 已确认的 FlClash 接入点

- `lib/application.dart`
  - 当前入口是 `MaterialApp(home: const HomePage())`
  - 后续如果要升级为“启动先登录”，这里是最安全的总入口
- `lib/views/profiles/add.dart`
  - 当前“添加配置”页只有二维码、文件、URL 三种方式
  - 这是最适合增加 `V2Board 登录` 入口的位置
- `lib/controller.dart`
  - 已有 `addProfileFormURL(String url)` 可直接复用
- `lib/models/profile.dart`
  - `Profile.update()` 会下载 URL 并校验 Clash 配置
  - 适合直接吃 `flag=meta` 后的 V2Board 订阅地址

## 已确认的 V2Board 接口

基于 `D:\v2board` 当前源码确认：

- 登录接口
  - `POST /api/v1/passport/auth/login`
- 用户登录态校验
  - `GET /api/v1/user/checkLogin`
- 获取订阅信息
  - `GET /api/v1/user/getSubscribe`
- 客户端订阅入口
  - `GET /api/v1/client/subscribe?token=...`

## V2Board 鉴权方式

`POST /api/v1/passport/auth/login` 返回：

- `token`
- `auth_data`
- `is_admin`

其中：

- 访问 `/api/v1/user/*` 接口时，应在请求头中使用 `Authorization: <auth_data>`
- 访问 `/api/v1/client/subscribe` 时，使用 `token` 作为查询参数

## 一个关键兼容点

V2Board 默认订阅不一定返回 Clash YAML，可能返回通用 base64 订阅。

但当前 V2Board 源码已内置 `ClashMeta` 协议输出，触发方式是给订阅接口传入 `flag=meta`。

因此 FlClash 侧不能直接无脑使用返回的原始 `subscribe_url`，而应改成：

- `原 subscribe_url + &flag=meta`
  或
- `原 subscribe_url + ?flag=meta`

具体按 URL 是否已有查询参数决定。

## 第一阶段建议实现

第一阶段只做最小可用版本：

1. 在 `lib/views/profiles/add.dart` 增加 `V2Board 登录`
2. 新增一个轻量登录表单
3. 新增一个小型 V2Board API Client
4. 登录成功后自动创建或更新一个受管订阅 Profile
5. 使用 `SharedPreferences` 保存少量元数据

建议保存的内容：

- `panelBaseUrl`
- `email`
- `managedProfileId`
- `lastSubscribeUrl`

第一阶段不建议保存密码。

## 第二阶段可选演进

如果后续确定要做“启动先登录”，可以在 `lib/application.dart` 外围增加一个登录 Gate：

- 未登录时显示登录页
- 已登录时显示原有 `HomePage`

这一阶段再考虑：

- 自动续签
- 登录态失效处理
- 退出登录
- 多面板账户支持

## 本地联调环境记录

当前机器情况：

- `D:\v2board` 已克隆 `https://github.com/wyx2685/v2board`
- WSL 可用：`Ubuntu-24.04`
- WSL 内暂未安装 `php / composer / mysql / redis`
- Windows 侧已安装 Docker Desktop
- WSL 内可直接调用 `docker.exe` 和 `docker.exe compose`

因此联调优先顺序建议：

1. 先找可复用的 Docker 部署方案，把 V2Board 跑起来
2. 如果 Docker 方案不顺，再在 WSL 内手动安装 Laravel 运行环境

## 后续待办

- 检查是否存在可直接用于 V2Board 的 Docker 方案
- 如果 Docker 方案可用，优先在 WSL/Docker Desktop 上部署
- 部署后验证登录接口和订阅接口
- 再回到 FlClash 实现最小接入版本

## 官方部署验证结果

验证时间：2026-03-09

已验证内容：

- 官方仓库已成功拉取到 `D:\v2board-official`
- 已使用官方仓库源码完成 `composer install`
- 已在宝塔站点目录 `/www/wwwroot/v2bord.com` 部署源码
- 已执行官方安装命令 `php artisan v2board:install`
- 数据库导入成功
- 站点首页返回 `HTTP 200`
- 管理后台入口路径返回 `HTTP 200`

当前使用的实际部署条件：

- Web 服务器：宝塔 Nginx
- 站点根目录：`/www/wwwroot/v2bord.com/public`
- 数据库：系统 MariaDB
- Redis：系统 Redis
- 代码来源：官方仓库 `v2board/v2board`

本次部署中发现的问题：

1. 宝塔自带 PHP 8.4 缺少 `fileinfo`，导致官方安装流程中的 `composer install` 无法直接通过。
2. 通过恢复系统 PHP 8.3 后，官方依赖安装可以正常完成。
3. 宝塔站点默认未配置 Laravel 的伪静态规则，导致后台入口最初返回 404，补充 `try_files $uri $uri/ /index.php?$query_string;` 后恢复正常。
4. 当前页面仍会输出大量 Laravel 8 在较新 PHP 版本上的 `Deprecated` 提示，说明运行时 PHP 版本仍然偏新，不是最理想组合。

结论：

- 官方部署方式可以跑通。
- 但当前宝塔运行时环境并不是最优。
- 更稳妥的正式运行方案应优先使用 PHP 8.1 或 PHP 8.2，而不是当前这套较新的 PHP 版本。
