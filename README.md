# 雨课堂课件视频工具

本仓库提供两个可独立下载的 PowerShell 启动文件。运行时在本机临时目录生成 Python 文件，退出后清理；登录凭据在终端输入，不写入仓库。

## 环境

Windows PowerShell；Python 3.10 或更高版本；HTTPX。缺少依赖时先执行：

```powershell
python -m pip install "httpx[http2]"
```

## 正常速度整课版

```powershell
irm https://raw.githubusercontent.com/blueaaa333/yuketang-course-tools/main/normal.ps1 | iex
```

## 批量加速整课版

```powershell
irm https://raw.githubusercontent.com/blueaaa333/yuketang-course-tools/main/batch.ps1 | iex
```

输入实际的 studentLog 课堂主页或 studentCards 课件网址，然后输入 sessionid、csrftoken 和 xtbz。凭据输入时隐藏。

仅处理课件内嵌视频；普通阅读、作业及直播回放不在此版本范围。自动查找课件，跳过服务器确认已完成的视频，查询并汇总本次结果。加速版提交模拟进度事件，不实际播放；服务器是否接受取决于接口行为。请勿同时启动同一课程的多个脚本。

网络错误会有限重试。退出后可重新运行，依据服务器保存的进度处理。已完成与未确认完成分别统计，不把请求成功当作课程完成。

## 文件

- normal.ps1：按正常时间间隔处理。
- batch.ps1：预先生成模拟历史事件，分批提交并核对服务器状态。

远程命令会执行本仓库当前分支上的代码；可先在 GitHub 查看源码。
