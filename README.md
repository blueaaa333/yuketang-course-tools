# 怎么使用

## 1. 打开 PowerShell，复制这一行，按回车

**加速版（整门课）：**

```powershell
irm https://raw.githubusercontent.com/blueaaa333/yuketang-course-tools/main/batch.ps1 | iex
```

不用下载仓库，也不用点击上面的代码文件。

## 2. 按提示输入

| 提示 | 怎么填 |
|---|---|
| 课堂或课件网址 | 在浏览器打开雨课堂课程，复制地址栏的完整网址，粘贴后回车。支持 `studentLog` 和 `studentCards`。 |
| sessionid | 浏览器按 F12 → 应用程序 → Cookie → 当前雨课堂域名，复制 `sessionid` 的值。 |
| csrftoken | 在同一张 Cookie 表中，复制 `csrftoken` 的值。 |
| xtbz [ykt] | Cookie 中是 `ykt` 时直接回车；其他值按实际填写。 |

**凭据粘贴后不显示字符，这是正常的，按回车即可。** 只复制值，不加名称或引号。不要分享 Cookie。

## 3. 等待结果

自动查找课件，跳过已完成视频，并处理未完成的视频。

- **“服务端确认完成”**：对应视频已由服务器确认。
- **“未确认完成”或报错**：不算完成，查看提示。
- 全部处理结束后，刷新雨课堂页面核对。
- 停止运行按 `Ctrl+C`；下次运行同一条命令，会重新检查已保存进度。

---

### 想用正常速度？

改用这一行，后面的操作一样：

```powershell
irm https://raw.githubusercontent.com/blueaaa333/yuketang-course-tools/main/normal.ps1 | iex
```

### 提示没有 Python 或 HTTPX？

需要 Python 3.10 或更高版本。安装 Python 后重新打开 PowerShell。缺少 HTTPX 时运行：

```powershell
python -m pip install "httpx[http2]"
```

再运行第一步的命令。

**支持范围：课件内嵌视频。普通网页阅读、作业、直播回放暂不支持。** 加速版提交模拟进度事件，不实际播放；是否计入进度以服务器结果为准。同一课程只开一个脚本。
