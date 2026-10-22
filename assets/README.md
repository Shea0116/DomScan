# DomScan identity

DomScan 的标志由三个部分组成：紫色字母 **D**、薄荷绿扫描框，以及 D 内部的三个 DOM 树节点。

- `domscan-mark.svg`：透明背景矢量标志，适合界面和文档。
- `domscan-icon.svg`：带深色圆角底板的矢量应用图标。
- `domscan-mark.png`：1024 × 1024 透明 PNG。
- `domscan-icon.png`：1024 × 1024 应用图标预览。
- `../Resources/AppIcon.icns`：macOS 图标，包含 16–1024 像素尺寸。

主色：紫色 `#AE8CFF`；扫描与节点色：薄荷绿 `#70E6CE`；底板：`#202640` → `#0C1020`。

SVG 是可编辑的矢量源。`scripts/make-icon.swift` 使用同一组路径生成 PNG 和 ICNS；修改路径时请保持两者一致。重新生成：

```sh
rtk proxy xcrun swift scripts/make-icon.swift .
```
