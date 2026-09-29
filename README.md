# Threads / 抖音 / X / YouTube 视频下载器

一个 macOS 本地小工具。把链接粘贴或拖进窗口，点「解析链接」。清晰度和字幕直接在窗口里选，再点「开始下载」。支持 Threads、抖音、X、YouTube。YouTube 字幕保存为旁边的 SRT 文件。窗口可以缩放，下载记录会留在下方列表里，双击可在访达中显示。

这个仓库从 OgdenBasicEnglish 的 `tools/threads-video-downloader` 拆出，工程在仓库根目录。需求记录在 `docs/需求文档/REQ-20260828-001-threads视频下载工具/`。

Threads、抖音和 X 不需要额外安装。YouTube 依赖本机的 [yt-dlp](https://github.com/yt-dlp/yt-dlp) 和 ffmpeg：

```bash
brew install yt-dlp ffmpeg
```

## 构建与运行

要求 macOS 13+、Xcode Command Line Tools 和 Swift 6：

```bash
swift test
./build_app.sh
open 'build/Threads视频下载器.app'
```

也可以直接运行命令行构建产物：

```bash
swift run ThreadsVideoDownloader
```

## 工作方式

- 接受 `threads.com` / `threads.net`，`v.douyin.com` / `douyin.com`，`x.com` / `twitter.com`，以及 `youtube.com` / `youtu.be` 的 HTTPS 链接。
- YouTube 链接需要能解析出 11 位视频 ID，例如 `https://www.youtube.com/watch?v=...`、`youtu.be/...`、`/shorts/`、`/embed/`。从 Finder 打开时也会去 Homebrew 路径查找 `yt-dlp` 和 `ffmpeg`。
- YouTube 若提示人机验证，会依次尝试本机 Safari、Chrome、Firefox、Edge、Brave 里已有的 YouTube 登录会话。不另存账号密码。同一分辨率优先直接可播放的 MP4；更高清晰度是分开的视频轨和音频轨，下载时用 ffmpeg 合成一个 MP4。文件名类似 `youtube_QW_jlUn4gA8_1280x720.mp4`。字幕可选人工字幕或自动生成字幕，默认优先简体中文，文件名类似 `youtube_QW_jlUn4gA8_1280x720.zh-Hans.srt`。
- X 链接必须包含数字帖子 ID，例如 `https://x.com/user/status/123`；也接受 `twitter.com`、`/i/status/`、`/i/web/status/`。
- 将公开帖子 URL 发给对应的公开媒体解析服务，获取 CDN 视频地址后下载到本地。X 帖子先走 `api.fxtwitter.com`，失败再试 `api.vxtwitter.com`，并列出全部 MP4 清晰度供选择（默认最高档）；只有一档时直接下载。文件名会带分辨率，如 `x_2096370988728369381_1280x720.mp4`。
- 默认保存到 macOS“下载”目录，也可以通过“选择目录…”修改。
- 不保存社交账号密码，不绕过登录、验证码或权限限制。
- 解析服务是外部依赖；如果服务不可用，界面会显示失败原因。

抖音解析会先向解析服务获取一次性会话，再提交短链或视频链接获取 MP4 媒体地址；会话令牌只在本次运行中使用，不写入磁盘。

## 限制

私密帖子、仅登录可见的帖子、已删除内容和没有可用视频资源的帖子无法下载。YouTube 会员专属、年龄限制且本机浏览器未登录、或有地区限制的视频也无法下载。下载内容请确保拥有相应使用权，并遵守 Threads、抖音、X、YouTube 及相关内容的服务条款。
