import Foundation
import TouchFlowCore

/// Built-in catalogue of common apps and services with their real primary domains.
///
/// Domains are the ones the vendor actually operates (CDN/API hosts included where
/// they are stable and well known). Entries where a shared domain would be misleading
/// keep an empty domain list rather than a guess.
public enum AppCatalog {
    private static func app(_ name: String, _ domains: [String], bundle: String? = nil) -> LearnedApp {
        LearnedApp(name: name, bundleID: bundle, domains: domains, source: "catalog")
    }

    public static let builtin: [LearnedApp] = [
        // China
        app("微信", ["weixin.qq.com", "wx.qq.com", "wechat.com"], bundle: "com.tencent.xinWeChat"),
        app("QQ", ["qq.com", "im.qq.com", "qpic.cn"], bundle: "com.tencent.qq"),
        app("淘宝", ["taobao.com", "tmall.com", "alicdn.com"]),
        app("天猫", ["tmall.com"]),
        app("支付宝", ["alipay.com", "alipayobjects.com"]),
        app("抖音", ["douyin.com", "douyinvod.com", "douyinpic.com"]),
        app("小红书", ["xiaohongshu.com", "xhscdn.com"]),
        app("哔哩哔哩", ["bilibili.com", "b23.tv", "hdslb.com"]),
        app("网易云音乐", ["music.163.com", "163.com", "126.net"]),
        app("微博", ["weibo.com", "weibo.cn", "sinaimg.cn"]),
        app("知乎", ["zhihu.com", "zhimg.com"]),
        app("京东", ["jd.com", "360buyimg.com"]),
        app("美团", ["meituan.com", "meituan.net"]),
        app("饿了么", ["ele.me"]),
        app("百度", ["baidu.com", "bdstatic.com"]),
        app("百度网盘", ["pan.baidu.com", "baidupcs.com"]),
        app("高德地图", ["amap.com", "autonavi.com"]),
        app("钉钉", ["dingtalk.com", "dingtalkapps.com"]),
        app("飞书", ["feishu.cn", "larksuite.com", "feishucdn.com"]),
        app("腾讯视频", ["v.qq.com", "video.qq.com"]),
        app("爱奇艺", ["iqiyi.com", "qiyipic.com"]),
        app("优酷", ["youku.com", "ykimg.com"]),
        app("网易", ["163.com", "netease.com"]),

        // Global social & messaging
        app("Telegram", ["telegram.org", "t.me", "telesco.pe", "cdn-telegram.org"]),
        app("WhatsApp", ["whatsapp.com", "whatsapp.net"]),
        app("Instagram", ["instagram.com", "cdninstagram.com", "fbcdn.net"]),
        app("X", ["x.com", "twitter.com", "twimg.com"]),
        app("Discord", ["discord.com", "discordapp.com", "discord.gg"], bundle: "com.hnc.Discord"),
        app("Slack", ["slack.com", "slack-edge.com", "slack-imgs.com"], bundle: "com.tinyspeck.slackmacgap"),
        app("Zoom", ["zoom.us", "zoom.com.cn"]),
        app("Line", ["line.me", "line-scdn.net"]),

        // Media
        app("Spotify", ["spotify.com", "scdn.co", "spotifycdn.com"], bundle: "com.spotify.client"),
        app("YouTube", ["youtube.com", "googlevideo.com", "ytimg.com", "youtu.be"]),
        app("Netflix", ["netflix.com", "nflxvideo.net", "nflximg.net"]),
        app("Apple Music", ["music.apple.com", "apple.com"]),
        app("Twitch", ["twitch.tv", "ttvnw.net"]),

        // Productivity & developer
        app("GitHub", ["github.com", "githubusercontent.com", "githubassets.com"]),
        app("Notion", ["notion.so", "notionusercontent.com", "notion.site"]),
        app("Steam", ["steampowered.com", "steamcommunity.com", "steamstatic.com"]),
        app("Docker Hub", ["docker.com", "docker.io", "dockerhub.com"]),
        app("npm", ["npmjs.com", "npmjs.org", "registry.npmjs.org"]),
        app("PyPI", ["pypi.org", "pythonhosted.org", "files.pythonhosted.org"]),
        app("ChatGPT", ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]),
        app("Claude", ["claude.ai", "anthropic.com"]),
        app("Gemini", ["gemini.google.com", "bard.google.com"]),
        app("Figma", ["figma.com", "figstatic.com"]),
        app("Dropbox", ["dropbox.com", "dropboxapi.com", "dropboxusercontent.com"]),
        app("Google Drive", ["drive.google.com", "googleusercontent.com", "docs.google.com"]),
        app("Gmail", ["mail.google.com", "gmail.com"]),
        app("Outlook", ["outlook.com", "outlook.office365.com", "live.com"]),
        app("Microsoft Teams", ["teams.microsoft.com", "teams.cdn.office.net"]),
        app("iCloud", ["icloud.com", "icloud-content.com", "apple.com"]),
        app("Google", ["google.com", "gstatic.com", "googleapis.com"]),
        app("Amazon", ["amazon.com", "media-amazon.com", "ssl-images-amazon.com"]),
        app("Wikipedia", ["wikipedia.org", "wikimedia.org"]),
    ]

    /// Aliases used for fuzzy matching of hand-written / OCR'd lists.
    static let aliases: [String: String] = [
        "wechat": "微信", "weixin": "微信", "weixinapp": "微信",
        "qq": "QQ", "tencentqq": "QQ",
        "taobao": "淘宝", "alipay": "支付宝", "douyin": "抖音", "tiktok": "抖音",
        "xiaohongshu": "小红书", "redbook": "小红书", "bilibili": "哔哩哔哩", "b站": "哔哩哔哩",
        "neteasecloudmusic": "网易云音乐", "netease": "网易云音乐", "cloudmusic": "网易云音乐",
        "weibo": "微博", "zhihu": "知乎", "jingdong": "京东", "jd": "京东",
        "meituan": "美团", "eleme": "饿了么", "baidu": "百度", "baidunetdisk": "百度网盘",
        "amap": "高德地图", "dingtalk": "钉钉", "feishu": "飞书", "lark": "飞书",
        "iqiyi": "爱奇艺", "youku": "优酷", "tencentvideo": "腾讯视频",
        "twitter": "X", "x": "X", "line": "Line", "ms teams": "Microsoft Teams",
        "googlemail": "Gmail", "gdrive": "Google Drive", "googledrive": "Google Drive",
        "openai": "ChatGPT", "anthropic": "Claude", "youtube": "YouTube",
    ]
}
