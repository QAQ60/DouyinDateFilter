# DouyinDateFilter

独立版抖音插件：在**个人主页的「作品」标签**按发布时间过滤，输入规则与 ReelsDateFilter 一致。

- `10` → 只加载最近 10 天
- `0.5` → 只加载 12 小时内
- `-10` → 只加载 10 天以前
- `0` 或清除 → 关闭

## 安装

**TrollFools / 自签注入（推荐）**

把 `DouyinDateFilter.dylib` 注入抖音的 IPA。启动后右侧会出现一个可拖动的「过滤」悬浮球，点它就能设置天数，不依赖具体页面。

**越狱**

```bash
scp DouyinDateFilter.dylib root@device:/var/jb/Library/MobileSubstrate/DynamicLibraries/
scp DouyinDateFilter.plist root@device:/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

`killall Aweme`。rootful 设备把 `/var/jb` 换成 `/`。

## 实现

抖音主页作品列表由 `AWEUserPostsDataManager`（继承 `AWEListDataController`）驱动：

- hook `AWEListDataController -calculateFilteredDataSource`
- 原方法会从 `dataSource` 重新生成 `filteredDataSource`，之后再按 `AWEAwemeModel.createTime` 过滤 `filteredDataSource`
- 只改渲染列表，不动 `dataSource`，所以把 10 天改成 30 天、或改成 0 关闭，都能完整还原
- 只处理类名含 `UserPosts` / `PostWork` / `UserWork` 的控制器，首页推荐、喜欢列表不受影响
- 取不到 `createTime` 的条目一律保留

入口是窗口级悬浮球，挂在 key window 上，所以无论抖音怎么改页面结构都能看见；点开后的「诊断」会打印当前页面层级到日志。

日志前缀 `[DDF]`：

```
[DDF] floating ball installed on UIWindow
[DDF] hooked AWEListDataController calculateFilteredDataSource
[DDF] AWEUserPostsDataManager: 40 -> 17 (days=10)
```

## 已知限制

- **没有在真机上验证过。** 类名和字段来自公开的 class-dump 头文件（`yudun1989/Headers` 的 aweme 分支），抖音版本更新后可能改名。编译通过不代表 hook 命中，先看日志。
- 如果 `filteredDataSource` 不是网格实际使用的数组，列表不会变化；日志里会看到 `[DDF] ... -> ...`，但界面不动，这种就需要换 hook 点。
- 悬浮球默认在右侧中部，可拖动，重启后回到默认位置。
- 分页到「全是过滤掉的」那一段时可能不再自动加载下一页。

## 构建

GitHub Actions，推送到 `main` 或手动 `Run workflow`：

https://github.com/QAQ60/DouyinDateFilter/actions

本地：

```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
make
```

## 文件

| 文件 | 说明 |
| --- | --- |
| `Tweak.mm` | runtime hook、过滤、入口按钮、提示与输入弹窗 |
| `rg_date_filter.c/.h` | 输入解析与时间判断，纯 C |
| `DouyinDateFilter.plist` | 越狱加载过滤（仅 `com.ss.iphone.ugc.Aweme`） |
| `Makefile` | Theos，arm64 + arm64e，library 形式，无 substrate 依赖 |
