# Original Omarchy icon on Osaka Jade

Uses the original project icon.png, including its original green and transparency.
The mark is 576px square on a 1024px canvas, centered at (224, 224).
This is 20% smaller in width and height than the preceding 720px Cobalt mark.
Background: #111c18, from themes/osaka-jade/colors.toml.
The background tile remains 896px square, inset 64px with a 180px corner radius.
The transparent exterior and original symbol geometry are preserved.
No generated image or recoloring of the original symbol is used.

Source SHA-256: edd69e61d711d8b423555f27a5afc64935c299f6e7f779112d2ce970ec0236e4

Regenerate:
swift compose.swift original-icon.png Omarchy-Osaka-Jade-1024.png 111c18

The iconset contains ten standard macOS sizes (16px through1024px).
Compile: iconutil -c icns OmarchyInstaller.iconset -o OmarchyInstaller.icns
