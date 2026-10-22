# 本地菜单背景

将用户提供的图片放在此目录，命名为 `MenuBackground-iPhone.png`
和 `MenuBackground-iPad.png`。两张图片必须同时存在。PNG 已被 Git 忽略，
只能保存在本地。

`build_shell.py` 会将现有的两张图片复制进 App，并单独记录 SHA-256，
不将图片计入可执行文件的源码指纹。公共 CI 未提供图片时使用纯色装饰背景。
从公共 CI 宿主组装本地 IPA 时，也要在签名前将这两张图片复制进
`Payload/P5RMobile.app/`。

启动菜单按设备类型选图，居中等比铺满整个屏幕，不拉伸，并在文字和底部按钮
所在区域加暗色遮罩。
