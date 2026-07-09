# Windows Jetson Bootstrap

这套文件用来在一台新的 Windows 设备上快速复刻当前的 `ssh jetson` 访问方式。

## 作用

- 下载 `frpc.exe`
- 生成单独的 Jetson SSH key
- 写入 `frpc-visitor-company-ssh.ini`
- 写入 `~/.ssh/config` 中的 `Host jetson` 配置块
- 在 Windows 启动文件夹里写入 `start-frpc-company-ssh.bat`
- 首次执行时直接拉起 `frpc`

## 安全说明

仓库不会保存真实的 FRP 凭据。

在执行脚本前，先复制一份本地配置：

```powershell
Copy-Item .\config.local.ps1.example .\config.local.ps1
```

然后编辑 `config.local.ps1`，填入你自己的：

- `FrpServerAddr`
- `FrpToken`
- `FrpSecretKey`

`config.local.ps1` 已被 `.gitignore` 忽略，不会被提交。

## 仍然需要手动做的一步

脚本可以把新 Windows 设备上的公钥打印出来并复制到剪贴板，但 **不能自动把这把公钥加入 Jetson**。

原因很简单：新设备在被 Jetson 信任之前，本来就还不能 SSH 上去。

所以首次执行后，仍然需要你用一台已经能登录 Jetson 的机器，把新生成的公钥追加到：

```text
~/.ssh/authorized_keys
```

## 用法

在 Windows PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\bootstrap-jetson.ps1
```

默认写入：

- `C:\tools\frp\frpc.exe`
- `C:\tools\frp\frpc-visitor-company-ssh.ini`
- `%USERPROFILE%\.ssh\id_ed25519_jetson`
- `%USERPROFILE%\.ssh\config`
- 启动文件夹中的 `start-frpc-company-ssh.bat`

## 常用参数

指定 FRP 版本：

```powershell
.\bootstrap-jetson.ps1 -FrpVersion 0.69.1
```

只写配置，不重新下载：

```powershell
.\bootstrap-jetson.ps1 -SkipDownload
```

只做本地配置，不立刻启动：

```powershell
.\bootstrap-jetson.ps1 -SkipLaunch
```

## 完成后验证

```powershell
netstat -ano | findstr 6000
ssh -vvv jetson
```
