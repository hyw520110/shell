# kkidc.com（厦门快快网络）自有资产手工分析报告

- 目标：`www.kkidc.com` 及同族自有资产
- 目标来源：`~/nuclei_scan/butian-public-src-targets.tsv`（补天公益 SRC 在册目标）
- 分析日期：2026-10-16
- 方法：`urls.txt` 清单梳理 + ProjectDiscovery `httpx` 低影响指纹（限速 2 req/s）+ 标准文件/重定向探测
- 边界：仅探测自有资产（`*.kkidc.com` / `kuaikuaicloud.com` / `kuaikuaidun.com` / `kuaikuaiglobal.com`）；爬取结果中混入的第三方域（toutiao/douyin/baidu/b.qq.com 等）已剔除；未做任何注入/爆破/利用payload

---

## 1. 资产清单（来自 urls.txt）

原始 35,150 行，**去重后仅 720 条 URL**，其中约 5,549 条为 js/css/图片等静态资源。

| 主机 | 用途推断 | 行数 |
| --- | --- | --- |
| www.kkidc.com | 主站（PHP 伪静态 CMS） | 27,970 |
| www.kuaikuaicloud.com | 快快云 | 845 |
| kws.kkidc.com | 快卫士 EDR | 677 |
| my.kkidc.com | 客户中心 / 通行证 | 527 |
| yunjiasu.kkidc.com | 云加速 | 338 |
| kkhr.kkidc.com | 招聘 | 338 |
| www.kuaikuaidun.com | 快快盾 | 338 |
| www.kuaikuaiglobal.com | 海外站 | 338 |

伪静态路径形态：`/helpcenter/detail/hcid/{n}/id/{n}.html`、`/about/index/hcid/{n}/id/{n}.html`、`/report_center/newlist/pid/{n}/id/{n}.html`（数字 ID 可遍历）。

## 2. httpx 指纹（PD httpx v1.12.0）

| 目标 | 状态 | 标题 | 技术栈 |
| --- | --- | --- | --- |
| www.kkidc.com | 200 | 快快云安全 | openresty, PHP, jQuery, Swiper, CNZZ |
| my.kkidc.com | 200 | 快快云安全 | openresty, **PHP**, crypto-js, GSAP, Marked |
| kws.kkidc.com | 200 | 快卫士-终端安全 | openresty, jQuery, Swiper |
| yunjiasu.kkidc.com | 200 | 快快云加速 | openresty, HSTS |
| kuaikuaidun.com | 200 | 快快盾 | openresty, PHP |
| kuaikuaicloud.com | 200 | 快快云 | openresty, PHP |
| kuaikuaiglobal.com | 200 | 游戏盾 | **Cloudflare**, Vue.js, Google Analytics |

服务器头仅暴露 `openresty`，无版本号泄露；`.well-known/security.txt` 返回 nginx 默认 404。

## 3. 端点地图补全

- `robots.txt`（www）：`Disallow: /preview`；探测 `/preview/` → 返回 JS 跳转 `/nofind.html`，实为占位页（**非真实模块**，排除）。
- `sitemap.xml`：**19,212 条 URL**（全部 `www.kkidc.com`；一级路径 `/market/*` 13,910、`/about/*` 5,099、`/helpcenter/*` 201，19,170 条为 `.html`）。已落成可直接喂给 httpx/nuclei 的目标文件：`kkidc-sitemap-urls.txt`（与本报告同目录）。
- 跳转链：
  - `jump/official_console.html` → 302 → 302 → `my.kkidc.com/passport/login.html`（仅跳登录）
  - `ai/index` → 301 → `/ai/index/`（快快 AI 大模型聚合平台）
  - `search/index?keywords=` → 301 → `search/index/?keywords=`（补斜杠）
  - `kkhr.kkidc.com/` → 302 → 第三方招聘平台 `/social-recruitment/kkidc/142901`

## 4. 候选深挖线索

| # | 线索 | 说明 |
| --- | --- | --- |
| 1 | `GET /search/index/?keywords=` 及 `/helpcenter/search.html?keywords=` | **良性回显已确认**：唯一 token 被原样写入 HTML 属性 `value="..."`，属 HTML 属性上下文反射，XSS 验证首选点（见下） |
| 2 | `my.kkidc.com`：`passport/login.html`、`index.php/passport/policy.html`、`finance/index.html` | 客户中心/通行证/财务，登录态下越权、IDOR、逻辑缺陷重点区 |
| 3 | `/ai/index`、`/ai/create` | AI 功能接口，值得查看参数与鉴权 |
| 4 | 伪静态数字 ID：`/helpcenter/detail/hcid/{n}/id/{n}.html`、`/about/index/hcid/{n}/id/{n}.html` | 改 ID 对比响应差异，越权/信息泄露候选 |
| 5 | `/jump/official_console.html` | 302 跳转链，确认是否携带可篡改的跳转参数 |

## 5. 回显确认结论（线索 1）

发唯一 token `zzqprobe7f3a91`（纯字母数字，无注入字符）：

- `search/index/?keywords=zzqprobe7f3a91` →
  `... placeholder="..." value="zzqprobe7f3a91">`（HTML 双引号属性内）
- `helpcenter/search.html?keywords=zzqprobe7f3a91` →
  `<input type="text" name="keywords" value="zzqprobe7f3a91" ... id="keyword"/>`（HTML 双引号属性内）

**转义验证**（追加探测 `%22`=`"`、`%3C`=`<`，均为非执行字符）：

| 端点 | 输入 `"` 的反射 | 输入 `<` 的反射 | 结论 |
| --- | --- | --- | --- |
| `search/index/?keywords=` | `value="…&quot;"` | `value="…&lt;"` | 单次 HTML 转义 |
| `helpcenter/search.html?keywords=` | `value="…&amp;quot;"` | `value="…&amp;lt;"` | 双重 HTML 转义 |

**结论**：参数确实被原样反射进 `value` 属性，但两处都对 `"` 与 `<` 做了 HTML 转义（`helpcenter` 还是双重转义），**无法属性逃逸，不构成 XSS** —— 线索 1 **证伪（false positive）**。

## 6. 下一步

- [已完成] 线索 1 转义边界验证 → 两处均已 HTML 转义，**证伪**。
- [已完成] sitemap → `kkidc-sitemap-urls.txt`（19,212 条）目标文件。
- [待做] 线索 2/4：用**两个不同权限账号**对比响应判断越权（需登录态，勿触发风控）。
- [待做] 用 `kkidc-sitemap-urls.txt` 做端点补全，重点覆盖 `.php`、`/api`、参数化路径。
- [前置] 复核补天公益 SRC 当前活动范围与测试规范，确认目标在授权内再执行主动步骤。
